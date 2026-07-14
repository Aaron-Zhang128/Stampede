--[[
	Main - Bullrush round orchestrator.
	Loops forever: WAITING -> INTERMISSION -> ACTIVE (waves) -> WINNER/ROUNDOVER.

	Each round runs one MODE from Config.MODES (weighted random, no immediate
	repeat, modes needing more players skipped): the mode sets the starting
	window size on the 11x11 physical grid (Mega 11x11 / Classic 9x9 / Small 7x7),
	the shrink schedule, the bull difficulty (Stampede), and whether players
	fight as Red/Blue teams (Team Rush: the last team with a member standing
	wins as a GROUP - every member gets the win, dead or not).

	During ACTIVE the window shrinks stage by stage, driven by round time OR
	eliminations (mode.shrink); bull difficulty ramps continuously with round
	time (mode.rampTime / mode.difficulty), independent of the shrink stage.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Bullrush.Config)
local GridUtil = require(ReplicatedStorage.Bullrush.GridUtil)
local BullCatalog = require(ReplicatedStorage.Bullrush.BullCatalog)
local Remotes = ReplicatedStorage.Bullrush.Remotes

-- Same ensure-on-require pattern as the other services: the Remotes folder is
-- built in edit mode, so places that predate a feature still get its remotes.
local function ensureRemote(name: string): RemoteEvent
	local remote = Remotes:FindFirstChild(name)
	if not (remote and remote:IsA("RemoteEvent")) then
		remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = Remotes
	end
	return remote
end
local VoteMode = ensureRemote("VoteMode") -- client -> server: cast/change next-mode vote
local SetAFK = ensureRemote("SetAFK") -- client -> server: toggle AFK (sit out next round)

local WaveDirector = require(script.Parent.WaveDirector)
local BullService = require(script.Parent.BullService)
local RoundService = require(script.Parent.RoundService)
local ShrinkService = require(script.Parent.ShrinkService)
local AIService = require(script.Parent.AIService)
local RevengeService = require(script.Parent.RevengeService)
local NotifyService = require(script.Parent.NotifyService)
local FriendBoostService = require(script.Parent.FriendBoostService)
local PushService = require(script.Parent.PushService)
local MonetizationService = require(script.Parent.MonetizationService)
local EconomyService = require(script.Parent.EconomyService)
local BullRollService = require(script.Parent.BullRollService)
local SpinService = require(script.Parent.SpinService)
local DailyRewardService = require(script.Parent.DailyRewardService)
local TutorialService = require(script.Parent.TutorialService)
local DataHandler = require(ServerScriptService.UserData.DataHandler)

-- Onboarding funnel logger (start/finish of a player's first game). Loaded
-- defensively like in UserData/Data.server: a missing/broken Analytics module
-- must never disrupt the round loop, so guard every call with `if Analytics`.
local Analytics do
	local mod = game.ServerScriptService:FindFirstChild("Analytics")
	if mod then
		local ok, m = pcall(require, mod)
		if ok then Analytics = m end
	end
end

FriendBoostService.init() -- friends-in-server tracking; scales all money grants
PushService.init() -- player-vs-player shove (prompts are made client-side in PushClient)
MonetizationService.init() -- Robux hub: owns ProcessReceipt + game passes; init before its registrants
EconomyService.init(RoundService.awardMoney) -- round ledger; registers "2x Rewards?" receipt
BullRollService.init() -- bull roll/equip backend; registers its Robux-roll receipts
SpinService.init() -- fortune wheel: free-spin clock + Robux spin receipts
DailyRewardService.init() -- daily login reward: 7-day loop + ready clock
TutorialService.init() -- first-session tutorial: join trigger + resume (steps advance via service hooks)

--==============================================================================
-- Per-round gravity (Low Gravity mode). workspace.Gravity replicates to every
-- client, so setting it server-side makes the whole round floaty. Captured once
-- so we always restore the place's real default, even if it was customized.
--==============================================================================

local DEFAULT_GRAVITY = workspace.Gravity

local function applyModeGravity(mode)
	workspace.Gravity = mode.gravity or DEFAULT_GRAVITY
end

local function restoreGravity()
	workspace.Gravity = DEFAULT_GRAVITY
end

-- Per-round player speed (High Speed mode). Set on each participant's humanoid
-- at round start and reset at round end; eliminated players respawn fresh at the
-- default anyway, so we only ever need to restore the ones still standing.
local DEFAULT_WALK_SPEED = 16 -- Roblox StarterHumanoid default

local function applyModeWalkSpeed(participants, mode)
	local speed = mode.walkSpeed or DEFAULT_WALK_SPEED
	for _, player in participants do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.WalkSpeed = speed
		end
	end
end

local function restoreWalkSpeed(participants)
	for _, player in participants do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.WalkSpeed = DEFAULT_WALK_SPEED
		end
	end
end

--==============================================================================
-- Round state broadcast
--==============================================================================

local currentState = "WAITING"
local currentInfo: { [string]: any } = {}

local function setRoundState(state: string, info: { [string]: any })
	currentState = state
	currentInfo = info
	-- Mirror the state (+ ACTIVE window) as attributes on the Bullrush folder
	-- for cold-booting clients: the FireClient pushes below get missed by a
	-- first join's long load (loading screen, streaming), but attributes ride
	-- the initial replication snapshot, so BullrushClient can self-sync at
	-- boot no matter when it wakes up. SetAttribute is change-detected, so
	-- the per-wave ACTIVE re-fires cost nothing here.
	local folder = Remotes.Parent
	folder:SetAttribute("RoundState", state)
	local bounds = info.bounds
	folder:SetAttribute("RoundBounds", if typeof(bounds) == "table"
		then ("%d,%d,%d,%d"):format(bounds.rowMin, bounds.rowMax, bounds.colMin, bounds.colMax)
		else nil)
	-- Tutorial join trigger reads this snapshot ("ACTIVE and wave <= 2" =
	-- a fresh joiner can start learning to throw right away).
	TutorialService.onRoundState(state, info)
	Remotes.RoundState:FireAllClients(state, info)
end

-- Late joiners get the current state so their HUD syncs; they are never
-- added to a round in progress (LobbySpawn handles their placement).
Players.PlayerAdded:Connect(function(player)
	Remotes.RoundState:FireClient(player, currentState, currentInfo)
	task.delay(3, function() -- re-fire in case their LocalScript wasn't listening yet
		if player.Parent then
			Remotes.RoundState:FireClient(player, currentState, currentInfo)
		end
	end)
end)

local function playersWithCharacters(): { Player }
	local list = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 and character:FindFirstChild("HumanoidRootPart") then
			table.insert(list, player)
		end
	end
	return list
end

-- AFK mode (Settings toggle): players who opt in sit out the NEXT round — they
-- stay in the lobby and are never added to the round roster. Stored as a
-- replicated "AFK" player attribute (so their own Settings pill can mirror it);
-- the attribute dies with the Player instance, so leaving clears it.
SetAFK.OnServerEvent:Connect(function(player, wantAfk)
	player:SetAttribute("AFK", wantAfk == true)
end)

-- The round roster: everyone alive in the lobby EXCEPT those in AFK mode. Used
-- for the min-player gate, mode/vote sizing, and the participant list.
local function activePlayers(): { Player }
	local list = {}
	for _, p in playersWithCharacters() do
		if p:GetAttribute("AFK") ~= true then
			table.insert(list, p)
		end
	end
	return list
end

--==============================================================================
-- Mode selection: weighted random among eligible modes, avoiding an
-- immediate repeat whenever there is a choice.
--==============================================================================

local lastModeId: string? = nil

local function pickMode(playerCount: number)
	local eligible = {}
	for _, mode in Config.MODES do
		if playerCount >= (mode.minPlayers or 1) then
			table.insert(eligible, mode)
		end
	end
	if #eligible == 0 then
		return Config.MODES[1]
	end
	if #eligible > 1 and lastModeId then
		for i, mode in eligible do
			if mode.id == lastModeId then
				table.remove(eligible, i)
				break
			end
		end
	end
	local total = 0
	for _, mode in eligible do
		total += mode.weight or 1
	end
	local roll = math.random() * total
	for _, mode in eligible do
		roll -= mode.weight or 1
		if roll <= 0 then
			return mode
		end
	end
	return eligible[#eligible]
end

--==============================================================================
-- Next-mode voting: during intermission players vote among a few random
-- eligible modes; the winner (ties broken randomly) is the round's mode. Falls
-- back to pickMode when voting is disabled or produces no clear result.
--==============================================================================

local votes: { [Player]: string } = {} -- voter -> modeId
local voteCandidates: { { id: string, name: string } } = {} -- current ballot
local votingOpen = false

-- Same eligibility rules as pickMode (respect minPlayers, drop the last mode
-- when there's a choice), then a shuffled slice of up to N options.
local function pickVoteCandidates(playerCount: number)
	local eligible = {}
	for _, mode in Config.MODES do
		if playerCount >= (mode.minPlayers or 1) then
			table.insert(eligible, mode)
		end
	end
	if #eligible > 1 and lastModeId then
		for i, mode in eligible do
			if mode.id == lastModeId then
				table.remove(eligible, i)
				break
			end
		end
	end
	for i = #eligible, 2, -1 do
		local j = math.random(i)
		eligible[i], eligible[j] = eligible[j], eligible[i]
	end
	local ballot = {}
	local count = math.min(Config.VOTE_OPTION_COUNT or 3, #eligible)
	for i = 1, count do
		table.insert(ballot, { id = eligible[i].id, name = eligible[i].name })
	end
	return ballot
end

-- How much a player's vote counts. VIP passes (IsVIP attribute, set by
-- MonetizationService) get double voting power; everyone else counts as one.
local function voteWeight(voter): number
	if typeof(voter) == "Instance" and voter:GetAttribute("IsVIP") then
		return 2
	end
	return 1
end

-- Zero-filled tally over the current ballot only (stale votes are ignored).
-- Each vote counts for its caster's voteWeight (VIP = 2), so tallies are power,
-- not head count.
local function countVotes(): { [string]: number }
	local counts = {}
	for _, cand in voteCandidates do
		counts[cand.id] = 0
	end
	for voter, modeId in votes do
		if counts[modeId] ~= nil then
			counts[modeId] += voteWeight(voter)
		end
	end
	return counts
end

local function modeById(id: string?)
	if id then
		for _, mode in Config.MODES do
			if mode.id == id then
				return mode
			end
		end
	end
	return nil
end

-- Winner = most-voted candidate; ties broken randomly among the leaders. With
-- no votes at all, a random candidate is chosen so the ballot still decides.
local function resolveVoteWinner()
	local counts = countVotes()
	local best = -1
	local leaders = {}
	for _, cand in voteCandidates do
		local n = counts[cand.id] or 0
		if n > best then
			best = n
			leaders = { cand.id }
		elseif n == best then
			table.insert(leaders, cand.id)
		end
	end
	if #leaders == 0 then
		return nil
	end
	return modeById(leaders[math.random(#leaders)])
end

VoteMode.OnServerEvent:Connect(function(player, modeId)
	if not votingOpen or typeof(modeId) ~= "string" then
		return
	end
	local valid = false
	for _, cand in voteCandidates do
		if cand.id == modeId then
			valid = true
			break
		end
	end
	if not valid or votes[player] == modeId then
		return
	end
	votes[player] = modeId
	-- Live counter update: repaint the current intermission info for everyone.
	currentInfo.voteCounts = countVotes()
	Remotes.RoundState:FireAllClients(currentState, currentInfo)
end)

Players.PlayerRemoving:Connect(function(player)
	if votes[player] then
		votes[player] = nil
		if votingOpen then
			currentInfo.voteCounts = countVotes()
			Remotes.RoundState:FireAllClients(currentState, currentInfo)
		end
	end
end)

--==============================================================================
-- Team Rush bookkeeping
--==============================================================================

local teamOf: { [Player]: string } = {} -- "RED" | "BLUE", current round only

-- Shuffle then alternate, so team sizes differ by at most one. Membership is
-- an attribute (not Player.Team) so the player list never grows Red/Blue
-- groups; the HUD and SoundDirector read RushTeam instead.
local function assignTeams(participants: { Player })
	table.clear(teamOf)
	local order = table.clone(participants)
	for i = #order, 2, -1 do
		local j = math.random(i)
		order[i], order[j] = order[j], order[i]
	end
	for i, player in order do
		local isRed = i % 2 == 1
		teamOf[player] = if isRed then "RED" else "BLUE"
		if typeof(player) == "Instance" then
			player:SetAttribute("RushTeam", teamOf[player])
		else
			AIService.tintTeam(player, teamOf[player])
		end
	end
end

local function clearTeams()
	for player in teamOf do
		if typeof(player) == "Instance" and player.Parent then
			player:SetAttribute("RushTeam", nil)
		end
	end
	table.clear(teamOf)
end

local function teamCounts(): { [string]: number }
	local counts = { RED = 0, BLUE = 0 }
	for _, player in RoundService.getAlive() do
		local team = teamOf[player]
		if counts[team] then
			counts[team] += 1
		end
	end
	return counts
end

--==============================================================================
-- Round helpers
--==============================================================================

-- All (row, col) pairs of the active window in random order, so spawn tiles
-- are distinct.
local function shuffledTiles(bounds): { { number } }
	local tiles = {}
	for row = bounds.rowMin, bounds.rowMax do
		for col = bounds.colMin, bounds.colMax do
			table.insert(tiles, { row, col })
		end
	end
	for i = #tiles, 2, -1 do
		local j = math.random(i)
		tiles[i], tiles[j] = tiles[j], tiles[i]
	end
	return tiles
end

-- Solo (practice) rounds only end when the lone player dies. Team rounds end
-- when every player left alive is on the same team. Otherwise the round is
-- decided as soon as 0 or 1 players remain.
local function roundDecided(soloRound: boolean, isTeams: boolean): boolean
	if isTeams then
		local aliveList = RoundService.getAlive()
		if #aliveList == 0 then
			return true
		end
		local firstTeam = teamOf[aliveList[1]]
		for _, player in aliveList do
			if teamOf[player] ~= firstTeam then
				return false
			end
		end
		return true
	end
	local count = RoundService.aliveCount()
	return if soloRound then count == 0 else count <= 1
end

local function destroyLeftoverBulls()
	-- Bulls are client-rendered: cancelling the server charges makes each one
	-- fire BullVisualEnd, which tears the local models down on every client.
	BullService.cancelAll()
end

-- Return the round's SURVIVORS to the lobby spawn. Only they are still standing
-- on the arena grid - everyone eliminated already respawned at the lobby spawn
-- naturally - so pivoting the whole server here would yank AFK sitters, shop
-- browsers, and practice-arena players back to spawn every round. The list can
-- still hold bot proxies (plain tables whose rig AIService.despawnAll just
-- destroyed) and real players who left during the 5s banner, hence the
-- Parent + Character guard on each entry.
local function teleportToLobby(survivors: { Player })
	local lobby = Workspace:FindFirstChild("Lobby")
	local spawnLocation = lobby and lobby:FindFirstChild("LobbySpawn")
	if not spawnLocation then
		return
	end
	-- Arena sits just south (+Z) of the lobby platform, so face players toward it.
	local base = spawnLocation.Position + Vector3.new(0, 4, 0)
	local facing = CFrame.lookAt(base, base + Vector3.new(0, 0, 1))
	for _, player in survivors do
		if player.Parent and player.Character then
			player.Character:PivotTo(facing)
		end
	end
end

-- Confetti for the champions: ReplicatedStorage.Confetti's emitters cloned
-- into each winner's torso for the WINNER-banner window (matches the task.wait(5)
-- before the lobby teleport), then disabled so the last particles fade out on
-- their own lifetime before the clones are removed. Server-side clones, so
-- everyone sees the shower; winners can be bot proxies (plain tables), but
-- their .Character rig takes the emitters just as happily.
local CONFETTI_SECONDS = 5
local CONFETTI_TAIL = 2 -- the template emitters' max particle Lifetime

local confettiTemplate = ReplicatedStorage:FindFirstChild("Confetti")

local function celebrateWinners(winners)
	if not confettiTemplate then
		return
	end
	for _, w in winners do
		local character = w.Character
		local torso = character
			and character.Parent
			and (character:FindFirstChild("UpperTorso")
				or character:FindFirstChild("Torso")
				or character:FindFirstChild("HumanoidRootPart"))
		if torso then
			local clones = {}
			for _, e in confettiTemplate:GetDescendants() do
				if e:IsA("ParticleEmitter") then
					local clone = e:Clone()
					clone.Parent = torso
					table.insert(clones, clone)
				end
			end
			task.delay(CONFETTI_SECONDS, function()
				for _, e in clones do
					e.Enabled = false
				end
			end)
			task.delay(CONFETTI_SECONDS + CONFETTI_TAIL, function()
				for _, e in clones do
					e:Destroy()
				end
			end)
		end
	end
end

-- Stage the arena SHOULD be at: the further along of the mode's time schedule
-- and its elimination schedule (mode.shrink.times / .aliveFractions).
local function desiredStage(roundStart: number, mode): number
	local schedule = mode.shrink
	local elapsed = os.clock() - roundStart
	local timeStage = 0
	for i, threshold in schedule.times do
		if elapsed >= threshold then
			timeStage = i
		end
	end

	-- Solo rounds (startCount == 1) keep the fraction at 1 while the player
	-- lives, so solo shrinking is purely time-driven.
	local aliveStage = 0
	local startCount = RoundService.getStartCount()
	if startCount > 0 then
		local fraction = RoundService.aliveCount() / startCount
		for i, threshold in schedule.aliveFractions do
			if fraction <= threshold then
				aliveStage = i
			end
		end
	end

	return math.clamp(math.max(timeStage, aliveStage), 0, #schedule.times)
end

-- Eliminates players who stay outside the active window longer than
-- Config.SHRINK.GRACE (stepping back in bounds resets their clock).
-- Returns a stop function; Main calls it the moment the round is decided so
-- nobody gets eliminated under the WINNER banner.
local function startBoundsWatcher(): () -> ()
	local running = true
	task.spawn(function()
		local outSince: { [Player]: number } = {}
		while running do
			task.wait(0.25)
			local bounds = ShrinkService.getBounds()
			for _, player in RoundService.getAlive() do
				local character = player.Character
				local root = character and character:FindFirstChild("HumanoidRootPart")
				if root then
					local row, col = GridUtil.worldToTile(root.Position)
					if row ~= nil and GridUtil.inBounds(row, col, bounds) then
						outSince[player] = nil
					else
						if not outSince[player] then
							outSince[player] = os.clock()
							NotifyService.send(player, "GET BACK ON THE GRID!", "red", Config.SHRINK.GRACE + 1)
						end
						if os.clock() - outSince[player] > Config.SHRINK.GRACE then
							outSince[player] = nil
							RoundService.eliminate(player, "FELL")
						end
					end
				end
			end
		end
	end)
	return function()
		running = false
	end
end

-- Special bulls (Config.SPECIAL_BULLS): sometimes a wave bull charges as a
-- NAMED catalog bull — rarity glow + name tag client-side —
-- so players see the box prizes alive on the grid. Rolled per launched bull,
-- gated by a server-wide interval so specials stay an event. Returns the
-- charge style for the clients plus the rarity's speed multiplier (applied to
-- the wave's CURRENT ramped speed, keeping specials relatively fast, never
-- absolutely unfair), or nil + 1 for a plain bull.
local specialRng = Random.new()
local lastSpecialAt = -math.huge
local function maybeSpecialBull()
	local cfg = Config.SPECIAL_BULLS
	if not (cfg and cfg.ENABLED) then
		return nil, 1
	end
	if os.clock() - lastSpecialAt < cfg.MIN_INTERVAL or specialRng:NextNumber() >= cfg.CHANCE then
		return nil, 1
	end
	local total = 0
	for _, w in cfg.WEIGHTS do
		total += w
	end
	local pick = specialRng:NextNumber() * total
	local rarity
	for r, w in cfg.WEIGHTS do
		rarity = r
		pick -= w
		if pick <= 0 then
			break
		end
	end
	-- Single-rarity weight table -> BullCatalog.roll picks uniformly among that
	-- rarity's ROLLABLE bulls, so a special is always a bull players can unlock.
	local bullId = BullCatalog.roll(specialRng, { [rarity] = 1 })
	local bull = BullCatalog.get(bullId)
	if not bull then
		return nil, 1
	end
	lastSpecialAt = os.clock()
	if cfg.ANNOUNCE[bull.rarity] then
		NotifyService.broadcast(bull.name .. "!", "red", 3)
	end
	return { bullId = bullId, special = bull.rarity }, cfg.SPEED_MULT[bull.rarity] or 1
end

local function runWaves(soloRound: boolean, roundStart: number, mode)
	local isTeams = mode.teams == true
	local difficulty = mode.difficulty or Config.DIFFICULTY
	local rampTime = mode.rampTime or Config.DIFFICULTY.RAMP_TIME
	local wave = 0
	-- Bulls stay "airborne" across waves: the next telegraph goes up while
	-- the previous wave is still charging, so pressure never fully drops.
	local airborne = 0
	local MAX_AIRBORNE = 10 -- brake if short gaps outrun bull run time
	local occupied: { [string]: number } = {} -- laneKey -> bulls in flight there

	-- End the round the INSTANT it's decided. Every elimination (bull, fall,
	-- push, quit) trips this hook; the moment one player (or one team) is left,
	-- every in-flight bull is cancelled so a charge already crossing the grid
	-- can't flatten the would-be winner during the telegraph/gap waits.
	local decided = false
	RoundService.onEliminated = function()
		if not decided and roundDecided(soloRound, isTeams) then
			decided = true
			BullService.cancelAll()
		end
	end
	-- Decided-aware sleep: waits `duration` in short slices, returning true as
	-- soon as the round is decided so the wave loop stops within ~0.1s instead
	-- of sitting out a full telegraph/gap with nothing left to settle.
	local function waitUnlessDecided(duration: number): boolean
		local deadline = os.clock() + duration
		while not decided and os.clock() < deadline do
			task.wait(math.min(0.1, deadline - os.clock()))
		end
		return decided
	end

	while true do
		wave += 1
		if roundDecided(soloRound, isTeams) then
			return
		end

		local targetStage = desiredStage(roundStart, mode)
		if targetStage > ShrinkService.getStage() then
			-- Let in-flight bulls clear first: the shrink is the round's
			-- breather, and bulls shouldn't cross tiles as they fall away.
			while airborne > 0 do
				task.wait(0.05)
			end
			-- Blocking: telegraph + sink per step. The bounds watcher keeps
			-- running, so stragglers on doomed tiles still get eliminated.
			NotifyService.broadcast("ARENA SHRINKING!", "red", Config.SHRINK.TELEGRAPH)
			ShrinkService.advanceTo(targetStage)
			EconomyService.noteStageSurvived(RoundService.getAlive()) -- stage bonus for the living
			if roundDecided(soloRound, isTeams) then
				return
			end
		end

		local bounds = ShrinkService.getBounds()
		-- CURVE (> 1) bows the ramp downward: the opening and the rampTime
		-- finale stay put, but the middle of the round runs a notch below the
		-- old straight line ("mid game a bit easier", 2026-07-13).
		local intensity = math.min((os.clock() - roundStart) / rampTime, 1) ^ (Config.DIFFICULTY.CURVE or 1)
		-- Larger maps (startSize >= 9) feel empty once the round is rolling, so
		-- floor the count — but only after an opening grace: the first few waves
		-- ride the gentle probabilistic ramp everywhere (a single slow bull to
		-- learn on), then the floor steps in at 2 and reaches 3 once the curved
		-- ramp passes a third (~72s on the base ramp; the ramp/mode can still
		-- push higher, e.g. Stampede to 4). The Small 7x7 grid keeps the gentle
		-- ramp throughout (no floor).
		local minBulls = nil
		if mode.startSize >= 9 and wave > 4 then
			minBulls = if intensity < 0.35 then 2 else 3
		end
		local waveData = WaveDirector.getWave(intensity, bounds, difficulty, occupied, minBulls)

		setRoundState("ACTIVE", {
			aliveCount = RoundService.aliveCount(),
			wave = wave,
			gridSize = bounds.rowMax - bounds.rowMin + 1,
			bounds = bounds,
			modeName = mode.name,
			modeId = mode.id,
			teamCounts = if isTeams then teamCounts() else nil,
		})

		local lanes = {}
		for _, bull in waveData.bulls do
			table.insert(lanes, bull.lane)
		end
		Remotes.Telegraph:FireAllClients(lanes, waveData.telegraph, bounds)
		AIService.onTelegraph(lanes, waveData.telegraph, bounds)
		if waitUnlessDecided(waveData.telegraph) then
			return
		end

		-- Each bull charges in its own thread (BullService.charge blocks).
		-- No barrier: the gap starts while these bulls are still running,
		-- so back-to-back waves overlap instead of waiting for a clear grid.
		for _, bull in waveData.bulls do
			local key = bull.lane.axis .. bull.lane.index
			airborne += 1
			occupied[key] = (occupied[key] or 0) + 1
			task.spawn(function()
				if bull.delay > 0 then
					task.wait(bull.delay)
				end
				-- Mid-wave short-circuit: bulls not yet launched are skipped
				-- once the round is decided; charging bulls are cancelled by
				-- the onEliminated hook the moment the field is settled.
				if not decided then
					-- Rolled at launch (not wave build) so the Epic+ broadcast
					-- lands exactly as the special leaves the gate.
					local style, speedMult = maybeSpecialBull()
					BullService.charge(bull.lane, waveData.speed * speedMult, bounds,
						RoundService.getAliveCached, function(victim)
							RoundService.eliminate(victim, "BULL")
						end, style)
				end
				airborne -= 1
				-- nil (not 0) when the lane empties: WaveDirector's exclusion
				-- set treats any present key as occupied.
				local left = occupied[key] - 1
				occupied[key] = if left > 0 then left else nil
			end)
		end

		if waitUnlessDecided(waveData.gap) then
			return
		end
		while airborne >= MAX_AIRBORNE do
			task.wait(0.05)
		end
	end
end

--==============================================================================
-- The round loop
--==============================================================================

while true do
	setRoundState("WAITING", {})
	while #activePlayers() < Config.MIN_PLAYERS do
		task.wait(0.5)
		-- Keep resending while short-handed: clients that joined (or loaded
		-- their UI) after the one-shot broadcast above still learn we're
		-- waiting, and the client's "Waiting for players" card rides these.
		setRoundState("WAITING", {})
	end

	local mode
	if Config.VOTING_ENABLED then
		-- Open the ballot: pick a few random eligible modes, clear last round's
		-- votes, and let the per-second resends carry the live tally (Main §14).
		voteCandidates = pickVoteCandidates(#activePlayers() + AIService.botCount())
		table.clear(votes)
		votingOpen = true
		for timeLeft = Config.INTERMISSION_TIME, 1, -1 do
			setRoundState("INTERMISSION", {
				timeLeft = timeLeft,
				voteOptions = voteCandidates,
				voteCounts = countVotes(),
			})
			task.wait(1)
		end
		votingOpen = false
		-- Winner decided AFTER the ballot closes; fall back if it's empty.
		mode = resolveVoteWinner() or pickMode(#activePlayers() + AIService.botCount())
	else
		mode = pickMode(#activePlayers() + AIService.botCount())
		-- Round identity rides the client's sticky intermission countdown card
		-- (Main §6), painted from the per-second INTERMISSION resends below.
		for timeLeft = Config.INTERMISSION_TIME, 1, -1 do
			setRoundState("INTERMISSION", {
				timeLeft = timeLeft,
				modeName = mode.name,
				modeId = mode.id,
			})
			task.wait(1)
		end
	end

	local participants = activePlayers() -- AFK players sit this one out
	if #participants > 0 then -- bots never run a round by themselves
		for _, bot in AIService.prepareForRound() do
			table.insert(participants, bot)
		end
	end
	if #participants >= Config.MIN_PLAYERS then
		-- Players may have left during intermission; Team Rush needs 2+.
		if mode.teams and #participants < 2 then
			mode = Config.MODES[1]
		end
		lastModeId = mode.id
		local soloRound = #participants < 2
		local isTeams = mode.teams == true
		if isTeams then
			assignTeams(participants)
		end

		-- Floaty round if the mode asks for it (restored after the waves).
		applyModeGravity(mode)

		-- Restore/configure the arena HERE (not at cleanup) so the sunken
		-- tiles stay visible under the previous round's end banner.
		ShrinkService.reset(mode.startSize, #mode.shrink.times)

		local tiles = shuffledTiles(ShrinkService.getBounds())
		for i, player in participants do
			local character = player.Character
			if character then
				local tile = tiles[(i - 1) % #tiles + 1]
				character:PivotTo(CFrame.new(
					GridUtil.tileCenter(tile[1], tile[2]) + Vector3.new(0, 3.5, 0)))
				local humanoid = character:FindFirstChildOfClass("Humanoid")
				if humanoid then
					humanoid.Health = humanoid.MaxHealth
				end
			end
		end

		-- Zippy round if the mode asks for it (restored after the waves).
		applyModeWalkSpeed(participants, mode)

		-- Breather on the field: everyone stands on their tile for a short
		-- countdown before bulls, shrink, and eliminations kick in. The
		-- `starting` flag makes the client swap the sticky card for big
		-- center-screen 5..1 digits (with per-second ticks in SoundDirector);
		-- no voteOptions here, so the vote HUD closes.
		for timeLeft = Config.START_DELAY, 1, -1 do
			setRoundState("INTERMISSION", {
				timeLeft = timeLeft,
				modeName = mode.name,
				modeId = mode.id,
				starting = true,
			})
			task.wait(1)
		end

		local roundStart = os.clock()
		RoundService.startRound(participants, isTeams)
		EconomyService.roundStarted(participants, mode)
		RevengeService.roundStarted()

		-- Funnel: mark each real player as having started a game (bots are plain
		-- tables; onFirstGameStart itself no-ops after the first call per player).
		if Analytics then
			for _, player in participants do
				if typeof(player) == "Instance" then
					Analytics.onFirstGameStart(player)
				end
			end
		end

		setRoundState("ACTIVE", {
			aliveCount = RoundService.aliveCount(),
			wave = 1,
			gridSize = mode.startSize,
			bounds = ShrinkService.getBounds(),
			modeName = mode.name,
			modeId = mode.id,
			teamCounts = if isTeams then teamCounts() else nil,
		})

		-- Kickoff: the on-field 5..1 countdown (big client digits + ticks) IS the
		-- announcement now — no "<MODE> — GO!" broadcast. Team Rush still whispers
		-- each player their side, since that isn't visible anywhere else.
		if isTeams then
			for _, player in participants do
				if player.Parent then
					NotifyService.send(player,
						("%s — YOU ARE %s"):format(mode.name:upper(), teamOf[player] or "?"),
						"white", 3)
				end
			end
		end

		local stopWatcher = startBoundsWatcher()
		runWaves(soloRound, roundStart, mode)
		stopWatcher()
		RoundService.onEliminated = nil -- the waves' instant-end hook retires with them
		RevengeService.roundEnded()
		restoreGravity() -- back to normal for the end banner + lobby
		restoreWalkSpeed(participants) -- reset any survivors' sprint

		local aliveList = RoundService.getAlive()
		local summaryWinner: { [string]: any } = {} -- for the Summary tab (EconomyService.settle)
		if isTeams then
			if #aliveList > 0 then
				-- Whole-team victory: every member of the surviving team gets
				-- the win (streak resets were deferred, so the fallen keep
				-- theirs); the losing team's streaks settle to 0 now.
				local winTeam = teamOf[aliveList[1]]
				for _, player in participants do
					if player.Parent then
						if teamOf[player] == winTeam then
							local won, paid = RoundService.awardWinner(player)
							if won then
								EconomyService.noteWin(player, paid)
							end
						else
							RoundService.resetStreak(player)
						end
					end
				end
				-- Featured winner: a random survivor of the winning side (everyone
				-- still alive is on winTeam, since the round only ends when the
				-- other team is wiped out). Prefer real players over bots so the
				-- Summary card shows an actual portrait when any human survived.
				local pool = {}
				for _, player in aliveList do
					if typeof(player) == "Instance" then
						table.insert(pool, player)
					end
				end
				if #pool == 0 then
					pool = aliveList
				end
				local featured = pool[math.random(#pool)]
				summaryWinner = {
					winnerName = featured.Name,
					winnerUserId = if typeof(featured) == "Instance" then featured.UserId else nil,
					teamColor = winTeam,
					-- champion's mount for the Summary TinyBox (getEquippedBull
					-- falls back to STARTER for bots/stub survivors)
					winnerBull = BullRollService.getEquippedBull(featured),
				}
				setRoundState("WINNER", {
					winnerName = featured.Name,
					teamColor = winTeam,
					modeName = mode.name,
				})
				NotifyService.broadcast((featured.Name .. " WINS THE STAMPEDE"):upper(), "green", 5)
				celebrateWinners(aliveList) -- the whole surviving team showers
			else
				-- The herd got everyone: nobody won, everybody's streak breaks.
				for _, player in participants do
					if player.Parent then
						RoundService.resetStreak(player)
					end
				end
				setRoundState("ROUNDOVER", { modeName = mode.name })
				NotifyService.broadcast("The herd got everyone…", "red", 5)
			end
		elseif not soloRound and #aliveList == 1 then
			local winner = aliveList[1]
			local won, paid = RoundService.awardWinner(winner)
			if won then
				EconomyService.noteWin(winner, paid)
			end
			summaryWinner = {
				winnerName = winner.Name,
				-- bot winners are plain tables with no UserId; the client
				-- falls back to the placeholder portrait
				winnerUserId = if typeof(winner) == "Instance" then winner.UserId else nil,
				-- champion's mount for the Summary TinyBox
				winnerBull = BullRollService.getEquippedBull(winner),
			}
			setRoundState("WINNER", { winnerName = winner.Name, modeName = mode.name })
			NotifyService.broadcast((winner.Name .. " WINS THE STAMPEDE"):upper(), "green", 5)
			celebrateWinners({ winner })
		else
			setRoundState("ROUNDOVER", { modeName = mode.name })
			NotifyService.broadcast("The herd got everyone…", "red", 5)
		end

		-- Pay the round ledgers and open every participant's Summary tab.
		EconomyService.settle(summaryWinner)

		-- Funnel: the round is over for everyone who was in it, so mark each real
		-- player as having finished a game (no-ops for anyone past their first).
		if Analytics then
			for _, player in participants do
				if typeof(player) == "Instance" then
					Analytics.onFirstGameFinish(player)
				end
			end
		end

		-- First-timers who just finished their first-ever round graduate: clear
		-- the FirstTimer attribute and persist the fact. Participants are
		-- captured at round start, so eliminated players graduate too -- they
		-- experienced a full round.
		for _, player in participants do
			if typeof(player) == "Instance" and player:GetAttribute("FirstTimer") == true then
				player:SetAttribute("FirstTimer", nil)
				DataHandler.SetStat(player, "HasPlayedBefore", true)
			end
		end

		RoundService.cleanup()
		if isTeams then
			clearTeams()
		end
		destroyLeftoverBulls()
		task.wait(5) -- let the winner / round-over banner show
		AIService.despawnAll()
		teleportToLobby(aliveList) -- only the survivors are still out on the grid
	end
end
