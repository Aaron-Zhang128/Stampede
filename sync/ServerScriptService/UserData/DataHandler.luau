local DataHandler = {}

DataHandler.Profiles = {}

function DataHandler.GetDefaultProfile()
	return {
		Streak = 0,
		Wins = 0,
		Money = 0,
		Record = 0,
		Chairs = {},        -- stored as {Star=true, Blue=true, ...}
		EquippedChair = "None",
		Trails = {},        -- aura trails, stored as {FIRE=true, GOLD=true, ...}
		EquippedTrail = "None",
		Rebirths = 0,
		GroupRewardClaimed = false,  -- one-time $250 group-join reward (RewardService)

		-- Daily-mission state (DailyMissionService). day=0 forces a re-roll on first load;
		-- the load merge in Data.server.luau copies a saved table here wholesale, so old
		-- saves with no key keep this default and are re-rolled to today on join.
		DailyMissions = {day = 0, set = {}, bonusClaimed = false},

		-- One-time starter-task state (StarterTaskService). Persists (no reset); old saves
		-- start empty and existing chair-owners get buy_chair pre-seeded on load.
		StarterTasks = {progress = {}, claimed = {}},

		-- Bull roll system (BullRollService): everyone owns + equips the free
		-- starter; the load merge keeps this default for old saves, so
		-- existing players get the starter granted on their next join.
		Bulls = {STARTER = true},   -- stored as {bullId = true}, like Chairs/Trails
		EquippedBull = "STARTER",

		-- Fortune wheel (SpinService): banked spins + when the last free spin
		-- accrued. LastFreeSpin=0 means a free spin banks immediately on the
		-- next join (new players and old saves alike get one on first sight).
		Spins = 0,
		LastFreeSpin = 0,

		-- Daily reward (DailyRewardService): DailyStreak = consecutive days
		-- claimed (the day to claim next is DailyStreak % 7 + 1); LastDailyClaim
		-- = unix time of the last claim. 0 means never claimed, so the first
		-- reward is ready immediately on join (new saves and old saves alike).
		DailyStreak = 0,
		LastDailyClaim = 0,
	}
end

function DataHandler.GetStat(player, statName)
	local profile = DataHandler.Profiles[player.UserId]
	if profile then
		return profile[statName]
	end
end

function DataHandler.SetStat(player, statName, value)
	local profile = DataHandler.Profiles[player.UserId]
	if not profile then
		warn("No profile found for " .. player.Name)
		return
	end

	profile[statName] = value

	-- Mirror to the value instance wherever it lives: Money/Wins are under
	-- leaderstats (shown in the player list); Rebirths/Streak are under Stats (hidden).
	for _, folderName in {"leaderstats", "Stats"} do
		local folder = player:FindFirstChild(folderName)
		local stat = folder and folder:FindFirstChild(statName)
		if stat then stat.Value = value end
	end
end

function DataHandler.IncrementStat(player, statName)
	local profile = DataHandler.Profiles[player.UserId]
	if not profile then return end
	profile[statName] = (profile[statName] or 0) + 1
	DataHandler.SetStat(player, statName, profile[statName])
end

-- Chairs inventory helpers — Chairs is a dictionary {chairId = true}
function DataHandler.AddChair(player, chairId)
	local profile = DataHandler.Profiles[player.UserId]
	if not profile then return end
	profile.Chairs[chairId] = true
end

function DataHandler.HasChair(player, chairId)
	local profile = DataHandler.Profiles[player.UserId]
	if not profile then return false end
	return profile.Chairs[chairId] == true
end

function DataHandler.GetEquippedChair(player)
	local profile = DataHandler.Profiles[player.UserId]
	return profile and profile.EquippedChair or "None"
end

function DataHandler.SetEquippedChair(player, chairId)
	local profile = DataHandler.Profiles[player.UserId]
	if not profile then return end
	profile.EquippedChair = chairId
	player:SetAttribute("EquippedChair", chairId)
end

-- Trails inventory helpers -- Trails is a dictionary {trailId = true}, same
-- shape as Chairs. The client renders the equipped trail by cloning
-- ReplicatedStorage.Mutations[trailId] off the EquippedTrail attribute.
function DataHandler.AddTrail(player, trailId)
	local profile = DataHandler.Profiles[player.UserId]
	if not profile then return end
	profile.Trails[trailId] = true
end

function DataHandler.HasTrail(player, trailId)
	local profile = DataHandler.Profiles[player.UserId]
	if not profile then return false end
	return profile.Trails[trailId] == true
end

function DataHandler.GetEquippedTrail(player)
	local profile = DataHandler.Profiles[player.UserId]
	return profile and profile.EquippedTrail or "None"
end

function DataHandler.SetEquippedTrail(player, trailId)
	local profile = DataHandler.Profiles[player.UserId]
	if not profile then return end
	profile.EquippedTrail = trailId
	player:SetAttribute("EquippedTrail", trailId)
end

-- Bulls inventory helpers -- Bulls is a dictionary {bullId = true}, same shape
-- as Chairs/Trails. The catalog (names/rarities/speeds) lives in
-- ReplicatedStorage.Bullrush.BullCatalog; RevengeService launches the equipped
-- bull's speed. The EquippedBull attribute replicates for the client UI.
function DataHandler.AddBull(player, bullId)
	local profile = DataHandler.Profiles[player.UserId]
	if not profile then return end
	profile.Bulls[bullId] = true
end

function DataHandler.HasBull(player, bullId)
	local profile = DataHandler.Profiles[player.UserId]
	if not profile then return false end
	return profile.Bulls[bullId] == true
end

function DataHandler.GetEquippedBull(player)
	local profile = DataHandler.Profiles[player.UserId]
	return profile and profile.EquippedBull or "STARTER"
end

function DataHandler.SetEquippedBull(player, bullId)
	local profile = DataHandler.Profiles[player.UserId]
	if not profile then return end
	profile.EquippedBull = bullId
	player:SetAttribute("EquippedBull", bullId)
end

return DataHandler
