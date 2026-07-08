--[[
	RoundService - alive-set bookkeeping, eliminations, and winner rewards.
	One round at a time; Main drives startRound()/cleanup() between rounds.

	Team Rush: startRound(participants, true) DEFERS streak resets - being
	eliminated must not cost you your streak if your team ends up winning.
	Main settles streaks at round end (awardWinner for the winning team,
	resetStreak for the losers).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage.Bullrush.Config)
local Remotes = ReplicatedStorage.Bullrush.Remotes
local DataHandler = require(ServerScriptService.UserData.DataHandler)
local NotifyService = require(script.Parent.NotifyService)
local FriendBoostService = require(script.Parent.FriendBoostService)
local EconomyService = require(script.Parent.EconomyService)

local RoundService = {}

local alive: { [Player]: boolean } = {}
local participantSet: { [Player]: boolean } = {} -- everyone the round started with
local connections: { RBXScriptConnection } = {}
local startCount = 0
local deferStreakReset = false

-- Alive-set fast paths. aliveCountValue is kept in lockstep with `alive` so
-- aliveCount() is O(1) instead of walking the dict (it's polled many times per
-- wave). aliveListCache backs getAliveCached() for the per-frame bull kill loop:
-- it's rebuilt only when membership changes (aliveDirty), so 60fps × N-bulls
-- polling costs zero allocations between eliminations.
local aliveCountValue = 0
local aliveListCache: { Player } = {}
local aliveDirty = true

-- Bots (see AIService) duck-type Player as plain tables. They flow through
-- the alive set like anyone else but must never touch persistent data.
local function isRealPlayer(player): boolean
	return typeof(player) == "Instance"
end

-- A missing profile (player left mid-round, data still loading, ...) must
-- never break the round loop, so every DataHandler call goes through pcall.
local function safeData(fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		warn("Bullrush: DataHandler call failed:", err)
	end
end

function RoundService.startRound(participants: { Player }, deferStreaks: boolean?)
	RoundService.cleanup()
	startCount = #participants
	deferStreakReset = deferStreaks == true
	for _, player in participants do
		if not alive[player] then
			aliveCountValue += 1
		end
		alive[player] = true
		participantSet[player] = true
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			-- Death by ANY cause (bull, fall, reset) counts as elimination.
			table.insert(connections, humanoid.Died:Connect(function()
				RoundService.eliminate(player)
			end))
		end
	end
	aliveDirty = true
	table.insert(connections, Players.PlayerRemoving:Connect(function(player)
		RoundService.eliminate(player)
	end))
end

-- Idempotent: safe to call from bull hits, Died, and PlayerRemoving alike.
-- cause is optional flavor for the elimination feed ("REVENGE" today).
function RoundService.eliminate(player: Player, cause: string?)
	if not alive[player] then
		return
	end
	alive[player] = nil
	aliveCountValue -= 1
	aliveDirty = true

	-- Bull hits kill the character; Health = 0 re-triggers Died ->
	-- eliminate, which is a no-op now that the player left the alive set.
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		humanoid.Health = 0
	end

	if not deferStreakReset and isRealPlayer(player) then
		safeData(DataHandler.SetStat, player, "Streak", 0)
	end
	local remaining = RoundService.aliveCount()
	-- Ledger: elimination order fixes placement; the final-3 bonus fires here.
	EconomyService.noteElimination(player, remaining, RoundService.getAlive())
	Remotes.Eliminated:FireAllClients(player.Name, remaining, cause)

	-- Elimination feed (white cards, top-center stack under the shop HUD).
	NotifyService.broadcast(
		player.Name
			.. (if cause == "REVENGE"
				then " was trampled by a bull — "
				else " was eliminated — ")
			.. (if remaining == 1 then "1 remains" else ("%d remain"):format(remaining)),
		"white")
end

-- Participant of the current round who has since been eliminated. Gates who
-- may throw revenge bulls: lobby latecomers and alive players don't qualify.
function RoundService.isEliminatedParticipant(player: Player): boolean
	return participantSet[player] == true and alive[player] == nil
end

-- Shared money grant through the safeData/DataHandler pattern (bots excluded).
-- Every grant is scaled by the friend boost (+50% per friend in the server);
-- returns the amount actually paid so callers can report the real number.
function RoundService.awardMoney(player: Player, amount: number): number
	if not isRealPlayer(player) then
		return 0
	end
	local paid = math.floor(amount * FriendBoostService.getMultiplier(player) + 0.5)
	safeData(function()
		DataHandler.SetStat(player, "Money",
			(DataHandler.GetStat(player, "Money") or 0) + paid)
	end)
	return paid
end

-- Applies win rewards. No-op (false) for solo rounds and bot winners.
-- Second return is the money actually paid (friend boost included).
function RoundService.awardWinner(winner: Player): (boolean, number)
	if startCount < 2 or not isRealPlayer(winner) then
		return false, 0
	end
	safeData(DataHandler.IncrementStat, winner, "Wins")
	safeData(function()
		DataHandler.SetStat(winner, "Streak", (DataHandler.GetStat(winner, "Streak") or 0) + 1)
	end)
	return true, RoundService.awardMoney(winner, Config.MONEY_PER_WIN)
end

-- Team Rush end-of-round settlement for the losing side (streak resets were
-- deferred during the round).
function RoundService.resetStreak(player: Player)
	if isRealPlayer(player) then
		safeData(DataHandler.SetStat, player, "Streak", 0)
	end
end

-- Fresh, caller-owned copy: safe to hold onto or mutate. Use this for anything
-- that isn't a per-frame poll (bounds watcher, round-end settlement, ...).
function RoundService.getAlive(): { Player }
	local list = {}
	for player in alive do
		table.insert(list, player)
	end
	return list
end

-- SHARED, READ-ONLY alive list rebuilt only when membership changes. For the
-- per-frame bull kill loop (BullService), which polls every Heartbeat per bull
-- and never mutates the result. Callers MUST NOT modify or retain it across a
-- membership change. Eliminations mark it dirty, so a mid-charge death still
-- drops out on the next Heartbeat.
function RoundService.getAliveCached(): { Player }
	if aliveDirty then
		table.clear(aliveListCache)
		for player in alive do
			table.insert(aliveListCache, player)
		end
		aliveDirty = false
	end
	return aliveListCache
end

function RoundService.aliveCount(): number
	return aliveCountValue
end

-- Number of players the round started with (0 outside a round).
function RoundService.getStartCount(): number
	return startCount
end

function RoundService.isAlive(player: Player): boolean
	return alive[player] == true
end

function RoundService.cleanup()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
	table.clear(alive)
	table.clear(participantSet)
	table.clear(aliveListCache)
	aliveCountValue = 0
	aliveDirty = true
	startCount = 0
	deferStreakReset = false
end

return RoundService
