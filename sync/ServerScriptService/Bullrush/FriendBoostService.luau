--[[
	FriendBoostService - money multiplier for playing alongside friends:
	+50% per friend in the server (Config.FRIEND_BOOST.PER_FRIEND).

	Efficiency: friendship is symmetric and stable for a server's lifetime, so
	each unordered player PAIR costs at most ONE IsFriendsWith web call, made
	when the later of the two joins and cached for the rest of the session
	(rejoins hit the cache). Counts update incrementally on join/leave - no
	polling, and getMultiplier is a pure table lookup so award paths stay cheap.

	The count replicates to clients as the "FriendBoostPercent" player
	attribute, which the shop HUD's Boost counter displays.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Bullrush.Config)
local NotifyService = require(script.Parent.NotifyService)

local FriendBoostService = {}

local PER_FRIEND = Config.FRIEND_BOOST.PER_FRIEND

local friendCount: { [Player]: number } = {}
local pairCache: { [string]: boolean } = {} -- pairKey -> friends? (one web call ever)
local pairChecking: { [string]: boolean } = {} -- claimed synchronously before the web call
local activePairs: { [string]: boolean } = {} -- friend pairs where BOTH sides are counted

local function pairKey(a: Player, b: Player): string
	local x, y = a.UserId, b.UserId
	if x > y then
		x, y = y, x
	end
	return x .. ":" .. y
end

local function setCount(player: Player, count: number)
	friendCount[player] = count
	player:SetAttribute("FriendBoostPercent", math.floor(count * PER_FRIEND * 100 + 0.5))
end

local function activatePair(a: Player, b: Player, key: string)
	if activePairs[key] then
		return
	end
	activePairs[key] = true
	setCount(a, (friendCount[a] or 0) + 1)
	setCount(b, (friendCount[b] or 0) + 1)
	local bump = math.floor(PER_FRIEND * 100 + 0.5)
	NotifyService.send(a, ("Friend boost! +%d%% money while %s is here"):format(bump, b.DisplayName), "green")
	NotifyService.send(b, ("Friend boost! +%d%% money while %s is here"):format(bump, a.DisplayName), "green")
end

local function onJoin(player: Player)
	setCount(player, 0)
	-- Snapshot who is here NOW: later joiners will run the check against us,
	-- so each unordered pair is processed by exactly one side.
	local others = {}
	for _, other in Players:GetPlayers() do
		if other ~= player then
			table.insert(others, other)
		end
	end
	for _, other in others do
		local key = pairKey(player, other)
		local cached = pairCache[key]
		if cached == true then
			if other.Parent then
				activatePair(player, other, key) -- rejoin: no web call needed
			end
		elseif cached == nil and not pairChecking[key] then
			pairChecking[key] = true -- claim before yielding so no duplicate calls
			task.spawn(function()
				local ok, isFriend = pcall(player.IsFriendsWith, player, other.UserId)
				if ok then
					pairCache[key] = isFriend == true
					-- Only count if both survived the web call's round trip.
					if pairCache[key] and player.Parent and other.Parent then
						activatePair(player, other, key)
					end
				end
				-- On web failure the pair stays uncached; a future join retries.
				pairChecking[key] = nil
			end)
		end
	end
end

local function onLeave(player: Player)
	for _, other in Players:GetPlayers() do
		if other ~= player then
			local key = pairKey(player, other)
			if activePairs[key] then
				activePairs[key] = nil
				setCount(other, math.max(0, (friendCount[other] or 0) - 1))
			end
		end
	end
	friendCount[player] = nil
end

-- 1 + PER_FRIEND per friend currently in the server. Bots (plain-table
-- proxies) and unknown players fall through to 1.
function FriendBoostService.getMultiplier(player): number
	local count = if typeof(player) == "Instance" then friendCount[player] else nil
	return 1 + (count or 0) * PER_FRIEND
end

function FriendBoostService.getFriendCount(player): number
	return friendCount[player] or 0
end

function FriendBoostService.init()
	Players.PlayerAdded:Connect(onJoin)
	Players.PlayerRemoving:Connect(onLeave)
	for _, player in Players:GetPlayers() do
		onJoin(player) -- anyone who beat us to the server (Studio timing)
	end
end

return FriendBoostService
