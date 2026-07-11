local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local DataStore = DataStoreService:GetDataStore("PlayerData_v2")
local DataHandler = require(game.ServerScriptService.UserData.DataHandler)

-- Onboarding funnel logger. Loaded defensively: a missing/broken Analytics module
-- must never stop player data from loading, so guard every call with `if Analytics`.
local Analytics do
	local mod = game.ServerScriptService:FindFirstChild("Analytics")
	if mod then
		local ok, m = pcall(require, mod)
		if ok then Analytics = m end
	end
end

-- How many times a DataStore read/write is retried (with backoff) before giving up.
local MAX_ATTEMPTS = 5

-- [userId] = true once that player's data has been READ CLEANLY from the store.
-- A profile whose GetAsync failed is just the DEFAULT profile (0 money/wins), and
-- saving it would overwrite the player's real save with zeros -- a permanent wipe,
-- which gets MORE likely as player count climbs and reads start to throttle. So
-- savePlayer refuses to write unless this flag is set for the player.
local dataLoaded = {}

-- Run a DataStore call with exponential backoff. Returns (ok, result).
local function withRetry(fn)
	local attempt, lastErr = 0, nil
	while attempt < MAX_ATTEMPTS do
		attempt += 1
		local ok, result = pcall(fn)
		if ok then return true, result end
		lastErr = result
		if attempt < MAX_ATTEMPTS then
			task.wait(0.2 * 2 ^ (attempt - 1))  -- 0.2s, 0.4s, 0.8s, 1.6s
		end
	end
	return false, lastErr
end

-- Returns true only if the profile was actually written (used by ProcessReceipt
-- to confirm a purchase only after its grant is durably saved).
local function savePlayer(player): boolean
	local profile = DataHandler.Profiles[player.UserId]
	if not profile then return false end

	-- Guard: never clobber a real save with a profile that failed to load.
	if not dataLoaded[player.UserId] then
		warn("Skipping save for " .. player.Name .. " -- data never loaded cleanly (protecting real save)")
		return false
	end

	-- UpdateAsync (vs SetAsync) is an atomic read-modify-write on the key, so
	-- concurrent writes to the same player serialize on Roblox's side instead of
	-- racing. We still write the whole profile (last-write-wins on content), but
	-- the operation itself is contention-safe and retried on transient failure.
	local ok, err = withRetry(function()
		DataStore:UpdateAsync(player.UserId, function()
			return profile
		end)
	end)

	if not ok then
		warn("Failed to save data for " .. player.Name .. ": " .. tostring(err))
	end
	return ok
end

-- Let services (MonetizationService.ProcessReceipt) force a durable save on demand.
DataHandler.SaveNow = savePlayer

Players.PlayerAdded:Connect(function(player)
	local profile = DataHandler.GetDefaultProfile()

	local ok, savedData = withRetry(function()
		return DataStore:GetAsync(player.UserId)
	end)

	if ok then
		-- Clean read. savedData == nil just means a brand-new player; that's still
		-- a successful load, so it's safe to save them later.
		if savedData then
			for key in profile do
				if savedData[key] ~= nil then
					profile[key] = savedData[key]
				end
			end
		end
		dataLoaded[player.UserId] = true
	else
		-- Load failed after every retry. Let them play on a default profile, but do
		-- NOT mark loaded -- savePlayer will refuse to write, so their real data is
		-- never overwritten with these defaults. The attribute lets the client warn
		-- them that progress won't save this session.
		warn("Failed to LOAD data for " .. player.Name .. " -- temporary profile, progress will NOT save: " .. tostring(savedData))
		player:SetAttribute("DataLoadFailed", true)
	end

	DataHandler.Profiles[player.UserId] = profile

	player:SetAttribute("Chairs", HttpService:JSONEncode(profile.Chairs))
	player:SetAttribute("EquippedChair", profile.EquippedChair or "None")
	player:SetAttribute("Trails", HttpService:JSONEncode(profile.Trails or {}))
	player:SetAttribute("EquippedTrail", profile.EquippedTrail or "None")
	player:SetAttribute("Bulls", HttpService:JSONEncode(profile.Bulls or {}))
	player:SetAttribute("EquippedBull", profile.EquippedBull or "STARTER")
	player:SetAttribute("BullMutations", HttpService:JSONEncode(profile.BullMutations or {}))
	player:SetAttribute("GroupRewardClaimed", profile.GroupRewardClaimed or false)

	-- Leaderstats: only Money and Wins are shown in the player list (column order
	-- follows creation order: Money first).
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	leaderstats.Parent = player

	local money = Instance.new("NumberValue")
	money.Name = "Money"
	money.Value = profile.Money
	money.Parent = leaderstats

	local wins = Instance.new("NumberValue")
	wins.Name = "Wins"
	wins.Value = profile.Wins
	wins.Parent = leaderstats

	-- Stats: not displayed in the player list. Record has no instance reader (server
	-- uses the profile + OrderedDataStore), so it intentionally has no value here.
	local stats = Instance.new("Folder")
	stats.Name = "Stats"
	stats.Parent = player

	-- Rebirths: hidden from the player list, but clients still read/listen to the
	-- instance (money-boost label, rebirth panel).
	local rebirths = Instance.new("NumberValue")
	rebirths.Name = "Rebirths"
	rebirths.Value = profile.Rebirths or 0
	rebirths.Parent = stats

	-- Streak: lives in the hidden Stats folder (not leaderstats) so it replicates
	-- to every client for the over-head StreakBillboard without adding a column to
	-- the player list. DataHandler.SetStat mirrors win/loss updates to this instance.
	local streak = Instance.new("IntValue")
	streak.Name = "Streak"
	streak.Value = profile.Streak or 0
	streak.Parent = stats

	-- Funnel step 1: player entered (top of the activation funnel).
	if Analytics then Analytics.onJoin(player) end
end)

Players.PlayerRemoving:Connect(function(player)
	savePlayer(player)
	DataHandler.Profiles[player.UserId] = nil
	dataLoaded[player.UserId] = nil
end)

game:BindToClose(function()
	-- Save everyone in parallel and WAIT for the saves to actually finish (the old
	-- fixed 3s could return before retried writes completed). Cap the wait so a hung
	-- request can't stall the shutdown past Roblox's BindToClose budget.
	local pending = 0
	for _, player in Players:GetPlayers() do
		pending += 1
		task.spawn(function()
			savePlayer(player)
			pending -= 1
		end)
	end
	local deadline = os.clock() + 25
	while pending > 0 and os.clock() < deadline do
		task.wait(0.1)
	end
end)