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
local TeamsService = game:GetService("Teams")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Bullrush.Config)
local GridUtil = require(ReplicatedStorage.Bullrush.GridUtil)
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

FriendBoostService.init() -- friends-in-server tracking; scales all money grants
PushService.init() -- player-vs-player shove (prompts are made client-side in PushClient)
MonetizationService.init() -- Robux hub: owns ProcessReceipt + game passes; init before its registrants
EconomyService.init(RoundService.awardMoney) -- round ledger; registers "2x Rewards?" receipt
BullRollService.init() -- bull roll/equip backend; registers its Robux-roll receipts
SpinService.init() -- fortune wheel: free-spin clock + Robux spin receipts
DailyRewardService.init() -- daily login reward: 7-day loop + ready clock

--==============================================================================
-- Teams (created in edit mode; ensured here so a fresh place still works)
--==============================================================================

local function ensureTeam(name: string, brickColor: string): Team
	local team = TeamsService:FindFirstChild(name)
	if not team or not team:IsA("Team") then
		team = Instance.new("Team")
		team.Name = name
		team.TeamColor = BrickColor.new(brickColor)
		team.AutoAssignable = false
		team.Parent = TeamsService
	end
	return team
end

local RED_TEAM = ensureTeam("Red Team", "Really red")
local BLUE_TEAM = ensureTeam("Blue Team", "Really blue")

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

-- Shuffle then alternate, so team sizes differ by at most one.
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
		player.Neutral = false
		player.Team = if isRed then RED_TEAM else BLUE_TEAM
		if typeof(player) ~= "Instance" then
			AIService.tintTeam(player, teamOf[player])
		end
	end
end

local function clearTeams()
	for player in teamOf do
		if player.Parent then
			player.Team = nil
			player.Neutral = true
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
	local arena = Workspace:FindFirstChild("BullrushArena")
	local activeBulls = arena and arena:FindFirstChild("ActiveBulls")
	if activeBulls then
		activeBulls:ClearAllChildren()
	end
end

local function teleportToLobby()
	local lobby = Workspace:FindFirstChild("Lobby")
	local spawnLocation = lobby and lobby:FindFirstChild("LobbySpawn")
	if not spawnLocation then
		return
	end
	-- Arena sits just south (+Z) of the lobby platform, so face players toward it.
	local base = spawnLocation.Position + Vector3.new(0, 4, 0)
	local facing = CFrame.lookAt(base, base + Vector3.new(0, 0, 1))
	for _, player in playersWithCharacters() do
		player.Character:PivotTo(facing)
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
		local intensity = math.min((os.clock() - roundStart) / rampTime, 1)
		-- Larger maps (startSize >= 9) feel empty opening with a lone pair, so
		-- floor the count: 2 bulls on the first wave, then >= 3 from the second
		-- on (the ramp/mode can still push higher, e.g. Stampede to 4). The Small
		-- 7x7 grid keeps the gentle probabilistic ramp (no floor).
		local minBulls = nil
		if mode.startSize >= 9 then
			minBulls = if wave <= 1 then 2 else 3
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
		task.wait(waveData.telegraph)

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
				-- once the round is decided; charging bulls finish their run.
				if not roundDecided(soloRound, isTeams) then
					BullService.charge(bull.lane, waveData.speed, bounds,
						RoundService.getAliveCached, function(victim)
							RoundService.eliminate(victim, "BULL")
						end)
				end
				airborne -= 1
				-- nil (not 0) when the lane empties: WaveDirector's exclusion
				-- set treats any present key as occupied.
				local left = occupied[key] - 1
				occupied[key] = if left > 0 then left else nil
			end)
		end

		task.wait(waveData.gap)
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
		local roundStart = os.clock()

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

		RoundService.startRound(participants, isTeams)
		EconomyService.roundStarted(participants, mode)
		RevengeService.roundStarted()
		setRoundState("ACTIVE", {
			aliveCount = RoundService.aliveCount(),
			wave = 1,
			gridSize = mode.startSize,
			bounds = ShrinkService.getBounds(),
			modeName = mode.name,
			modeId = mode.id,
			teamCounts = if isTeams then teamCounts() else nil,
		})

		-- Kickoff announcement (replaces the old client center banner): everyone
		-- learns the mode; in Team Rush each player is told which side they're on.
		if isTeams then
			for _, player in participants do
				if player.Parent then
					NotifyService.send(player,
						("%s — YOU ARE %s"):format(mode.name:upper(), teamOf[player] or "?"),
						"white", 3)
				end
			end
		else
			NotifyService.broadcast((mode.name:upper() .. " — GO!"), "white", 3)
		end

		local stopWatcher = startBoundsWatcher()
		runWaves(soloRound, roundStart, mode)
		stopWatcher()
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
								-- Money lives in the Summary tab now, not this card.
								NotifyService.send(player, "VICTORY! +1 Win", "green", 6)
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
				-- Money lives in the Summary tab now, not this card.
				NotifyService.send(winner, "VICTORY! +1 Win", "green", 6)
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
		else
			setRoundState("ROUNDOVER", { modeName = mode.name })
			NotifyService.broadcast("The herd got everyone…", "red", 5)
		end

		-- Pay the round ledgers and open every participant's Summary tab.
		EconomyService.settle(summaryWinner)

		RoundService.cleanup()
		if isTeams then
			clearTeams()
		end
		destroyLeftoverBulls()
		task.wait(5) -- let the winner / round-over banner show
		AIService.despawnAll()
		teleportToLobby()
	end
end
