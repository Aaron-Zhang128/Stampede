--[[
	Main - Bullrush round orchestrator.
	Loops forever: WAITING -> INTERMISSION -> ACTIVE (waves) -> WINNER/ROUNDOVER.

	Each round runs one MODE from Config.MODES (weighted random, no immediate
	repeat, modes needing more players skipped): the mode sets the starting
	window size on the 9x9 physical grid (Mega 9x9 / Classic 7x7 / Small 5x5),
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

local WaveDirector = require(script.Parent.WaveDirector)
local BullService = require(script.Parent.BullService)
local RoundService = require(script.Parent.RoundService)
local ShrinkService = require(script.Parent.ShrinkService)
local AIService = require(script.Parent.AIService)
local RevengeService = require(script.Parent.RevengeService)
local NotifyService = require(script.Parent.NotifyService)
local FriendBoostService = require(script.Parent.FriendBoostService)

FriendBoostService.init() -- friends-in-server tracking; scales all money grants

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
	NotifyService.broadcast(player.DisplayName .. " joined the stampede", "white")
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
							NotifyService.send(player, "OUT OF BOUNDS — GET BACK ON THE GRID!", "red", Config.SHRINK.GRACE + 1)
						end
						if os.clock() - outSince[player] > Config.SHRINK.GRACE then
							outSince[player] = nil
							RoundService.eliminate(player)
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
	while true do
		wave += 1
		if roundDecided(soloRound, isTeams) then
			return
		end

		local targetStage = desiredStage(roundStart, mode)
		if targetStage > ShrinkService.getStage() then
			-- Blocking: telegraph + sink per step. The bounds watcher keeps
			-- running, so stragglers on doomed tiles still get eliminated.
			NotifyService.broadcast("ARENA SHRINKING!", "red", Config.SHRINK.TELEGRAPH)
			ShrinkService.advanceTo(targetStage)
			RevengeService.refreshPads() -- pad ring follows the new window
			if roundDecided(soloRound, isTeams) then
				return
			end
		end

		local bounds = ShrinkService.getBounds()
		local intensity = math.min((os.clock() - roundStart) / rampTime, 1)
		local waveData = WaveDirector.getWave(intensity, bounds, difficulty)

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

		-- Each bull charges in its own thread (BullService.charge blocks);
		-- `pending` gates the wave until every thread finishes.
		local pending = #waveData.bulls
		for _, bull in waveData.bulls do
			task.spawn(function()
				if bull.delay > 0 then
					task.wait(bull.delay)
				end
				-- Mid-wave short-circuit: bulls not yet launched are skipped
				-- once the round is decided; charging bulls finish their run.
				if not roundDecided(soloRound, isTeams) then
					BullService.charge(bull.lane, waveData.speed, bounds,
						RoundService.getAlive, RoundService.eliminate)
				end
				pending -= 1
			end)
		end
		while pending > 0 do
			task.wait(0.05)
		end

		if roundDecided(soloRound, isTeams) then
			return
		end
		task.wait(waveData.gap)
	end
end

--==============================================================================
-- The round loop
--==============================================================================

while true do
	setRoundState("WAITING", {})
	while #playersWithCharacters() < Config.MIN_PLAYERS do
		task.wait(0.5)
	end

	local mode = pickMode(#playersWithCharacters() + AIService.botCount())
	for timeLeft = Config.INTERMISSION_TIME, 1, -1 do
		setRoundState("INTERMISSION", {
			timeLeft = timeLeft,
			modeName = mode.name,
			modeId = mode.id,
		})
		task.wait(1)
	end

	local participants = playersWithCharacters()
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

		RoundService.startRound(participants, isTeams)
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
			NotifyService.broadcast(mode.name:upper(), "white", 3)
		end

		local stopWatcher = startBoundsWatcher()
		runWaves(soloRound, roundStart, mode)
		stopWatcher()
		RevengeService.roundEnded()

		local aliveList = RoundService.getAlive()
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
								NotifyService.send(player,
									("VICTORY! +1 Win  •  +%d Money"):format(paid), "green", 6)
							end
						else
							RoundService.resetStreak(player)
						end
					end
				end
				local winnerName = if winTeam == "RED" then "RED TEAM" else "BLUE TEAM"
				setRoundState("WINNER", {
					winnerName = winnerName,
					teamColor = winTeam,
					modeName = mode.name,
				})
				NotifyService.broadcast((winnerName .. " WINS THE STAMPEDE"):upper(), "green", 5)
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
				NotifyService.send(winner,
					("VICTORY! +1 Win  •  +%d Money"):format(paid), "green", 6)
			end
			setRoundState("WINNER", { winnerName = winner.Name, modeName = mode.name })
			NotifyService.broadcast((winner.Name .. " WINS THE STAMPEDE"):upper(), "green", 5)
		else
			setRoundState("ROUNDOVER", { modeName = mode.name })
			NotifyService.broadcast("The herd got everyone…", "red", 5)
		end

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