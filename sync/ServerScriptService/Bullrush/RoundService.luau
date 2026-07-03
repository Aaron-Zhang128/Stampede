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

local RoundService = {}

local alive: { [Player]: boolean } = {}
local participantSet: { [Player]: boolean } = {} -- everyone the round started with
local connections: { RBXScriptConnection } = {}
local startCount = 0
local deferStreakReset = false

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
	Remotes.Eliminated:FireAllClients(player.Name, RoundService.aliveCount(), cause)

	-- Elimination feed (white cards, top-center stack under the shop HUD).
	local remaining = RoundService.aliveCount()
	NotifyService.broadcast(
		player.Name
			.. (if cause == "REVENGE"
				then " was taken out by a REVENGE bull — "
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

function RoundService.getAlive(): { Player }
	local list = {}
	for player in alive do
		table.insert(list, player)
	end
	return list
end

function RoundService.aliveCount(): number
	local count = 0
	for _ in alive do
		count += 1
	end
	return count
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
	startCount = 0
	deferStreakReset = false
end

return RoundService