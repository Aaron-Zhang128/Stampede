local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BullCatalog = require(ReplicatedStorage.Bullrush.BullCatalog)

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

		-- Longest single practice-grid survival stint, in seconds (0.1s steps).
		-- Written by Bullrush/PracticeArena at stint end; replicated to the HUD
		-- stopwatch (Main §16) as the PracticeBest attribute.
		PracticeRecord = 0,

		-- False until the player FINISHES their first-ever round (flipped in
		-- Bullrush/Main.server). While false the player carries the replicated
		-- FirstTimer attribute (no gameplay effect yet -- there for analytics
		-- and future first-session features). Old saves predate this key;
		-- Data.server infers true for them on load (an existing save means
		-- they've been here before).
		HasPlayedBefore = false,

		-- First-session tutorial progress (Bullrush/TutorialService): 0 = not
		-- started, 1 = launch a bull, 2 = free roll, 3 = equip, 4 = done.
		-- Advanced ONLY server-side by TutorialService; replicates as the
		-- same-named attribute the client overlay (Main §18) renders from.
		-- Old saves predate this key; Data.server grandfathers them to 4.
		TutorialStep = 0,

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

		-- Ability shop (AbilityShopService): abilities the player has BOUGHT,
		-- {abilityKey = true}. Push is free/implicit and never stored. Mirrored to
		-- Owns_<key> attributes on join so AbilityService.owns + the picker read it.
		OwnedAbilities = {},

		-- Banked FREE lucky-box openings, {boxId = count} (BullRollService spends
		-- them before Money in requestRoll). New players start with one free
		-- BASIC box so their first roll costs nothing; Data.server's load
		-- inference empties this for pre-feature saves (a new-player gift, not
		-- a veteran grant). Replicates as the FreeBoxRolls JSON attribute.
		FreeBoxRolls = {BASIC = 1},

		-- Mutations rolled onto specific bulls (BullRollService): a nested
		-- dictionary {bullId = {mutId = true}}. The equipped bull wears its
		-- rarest owned mutation (BullCatalog.bestMutation) on revenge throws.
		BullMutations = {},

		-- Fortune wheel (SpinService): banked spins + when the last free spin
		-- accrued. LastFreeSpin=0 means a free spin banks immediately on the
		-- next join (new players and old saves alike get one on first sight).
		Spins = 0,
		LastFreeSpin = 0,
		LastVipSpin = 0, -- when the VIP pass's extra daily spin last accrued (VIP only)
		-- Has the player EVER spun the wheel? Their first-ever spin is rigged to a
		-- dragon near-miss (SpinService); this one-way persisted flag makes it a
		-- one-time thing. Old saves are grandfathered to true in Data.server so a
		-- returning veteran's first spin isn't hijacked.
		WheelSpun = false,

		-- Daily reward (DailyRewardService): DailyStreak = consecutive days
		-- claimed (the day to claim next is DailyStreak % 7 + 1); LastDailyClaim
		-- = unix time of the last claim. 0 means never claimed, so the first
		-- reward is ready immediately on join (new saves and old saves alike).
		DailyStreak = 0,
		LastDailyClaim = 0,

		-- Gates the daily-reward window's auto-open (Main §13). A brand-new player
		-- shouldn't get the popup the instant they finish the tutorial, so it stays
		-- false until they've completed ONE full round AFTER the tutorial was done
		-- (flipped by Main.server at round finish). Old saves are grandfathered to
		-- true in Data.server -- veterans are past onboarding and pop as before.
		DailyUnlocked = false,

		-- Player level progression (LevelService): Level 1..Config.LEVELS.MAX_LEVEL;
		-- XP = progress INTO the current level (the per-level step is subtracted on
		-- each level-up). Old saves keep these defaults via the load merge, so
		-- veterans simply start climbing from level 1 like everyone else. Both
		-- replicate as same-named player attributes for the HUD XP bar.
		Level = 1,
		XP = 0,

		-- Processed dev-product receipts (MonetizationService). A ring of the most
		-- recent PurchaseIds, recorded in the SAME durable write as the grant so a
		-- retried/duplicated Roblox receipt is recognized and never granted twice.
		ProcessedReceipts = {},
	}
end

-- How many recent PurchaseIds to keep per profile (bounds DataStore growth for
-- players who buy a lot; Roblox only retries a receipt for a short window, so a
-- generous ring is far more than enough to dedup any real retry).
local RECEIPT_HISTORY_CAP = 100

-- Assigned by Data.server once the DataStore is wired up: forces an immediate,
-- retried save of the player's whole profile and returns true only if the write
-- actually landed. Lets ProcessReceipt persist a grant + its dedup marker before
-- it confirms the purchase to Roblox. Missing (data script not up) -> treated as
-- a failed save so the receipt stays NotProcessedYet and Roblox retries.
DataHandler.SaveNow = nil

function DataHandler.Save(player): boolean
	if DataHandler.SaveNow then
		return DataHandler.SaveNow(player) == true
	end
	return false
end

function DataHandler.HasProcessedReceipt(player, purchaseId): boolean
	local profile = DataHandler.Profiles[player.UserId]
	local hist = profile and profile.ProcessedReceipts
	if not hist then return false end
	local key = tostring(purchaseId)
	for _, id in hist do
		if id == key then return true end
	end
	return false
end

function DataHandler.MarkReceiptProcessed(player, purchaseId)
	local profile = DataHandler.Profiles[player.UserId]
	if not profile then return end
	local hist = profile.ProcessedReceipts
	if not hist then
		hist = {}
		profile.ProcessedReceipts = hist
	end
	table.insert(hist, tostring(purchaseId))
	while #hist > RECEIPT_HISTORY_CAP do
		table.remove(hist, 1)  -- drop oldest; recent ids are the ones that get retried
	end
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

-- Quiet write for reveal-gated rewards (SpinService/BullRollService): the
-- profile (the saved truth) updates NOW, so leaves/crashes/receipt force-saves
-- can never lose a granted prize — but the leaderstats/Stats mirror is skipped,
-- so the HUD can't spoil a wheel or lucky-box reveal that is still spinning.
-- Pair with SyncStat when the client's reveal animation lands.
function DataHandler.AddStatQuiet(player, statName, delta)
	local profile = DataHandler.Profiles[player.UserId]
	if not profile then
		warn("No profile found for " .. player.Name)
		return
	end
	profile[statName] = (profile[statName] or 0) + delta
end

-- Re-mirrors a stat's current profile value to its value instance (the visible
-- half of SetStat). No-op if the player already left (profile gone).
function DataHandler.SyncStat(player, statName)
	local profile = DataHandler.Profiles[player.UserId]
	if not profile then
		return
	end
	for _, folderName in {"leaderstats", "Stats"} do
		local folder = player:FindFirstChild(folderName)
		local stat = folder and folder:FindFirstChild(statName)
		if stat then stat.Value = profile[statName] end
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
	if profile.Bulls[bullId] == true then return end

	-- Auto-equip only when this unlock establishes a new personal-best rarity.
	-- Compare before inserting it; another bull in the same tier must not replace
	-- a bull the player deliberately equipped.
	local previousBestOrder = 0
	for ownedId, owned in profile.Bulls do
		if owned == true then
			local ownedBull = BullCatalog.get(ownedId)
			local ownedRarity = ownedBull and BullCatalog.Rarities[ownedBull.rarity]
			if ownedRarity then
				previousBestOrder = math.max(previousBestOrder, ownedRarity.order)
			end
		end
	end

	profile.Bulls[bullId] = true
	local newBull = BullCatalog.get(bullId)
	local newRarity = newBull and BullCatalog.Rarities[newBull.rarity]
	if newRarity and newRarity.order > previousBestOrder then
		profile.EquippedBull = bullId
	end
end

function DataHandler.HasBull(player, bullId)
	local profile = DataHandler.Profiles[player.UserId]
	if not profile then return false end
	return profile.Bulls[bullId] == true
end

-- Ability ownership helpers (AbilityShopService) -- OwnedAbilities is a dictionary
-- {abilityKey = true}, same shape as Bulls. Push is free and never stored here.
function DataHandler.AddAbility(player, abilityKey)
	local profile = DataHandler.Profiles[player.UserId]
	if not profile then return end
	profile.OwnedAbilities = profile.OwnedAbilities or {}
	profile.OwnedAbilities[abilityKey] = true
end

function DataHandler.HasAbility(player, abilityKey)
	local profile = DataHandler.Profiles[player.UserId]
	if not profile or not profile.OwnedAbilities then return false end
	return profile.OwnedAbilities[abilityKey] == true
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

-- Bull mutation helpers -- BullMutations is {bullId = {mutId = true}}: a
-- mutation is owned PER BULL (rolling Fire onto Magma doesn't put Fire on
-- anything else). Old saves get the empty table from the default profile on
-- load merge. BullRollService mirrors the whole table to the BullMutations
-- player attribute after every roll.
function DataHandler.AddBullMutation(player, bullId, mutId)
	local profile = DataHandler.Profiles[player.UserId]
	if not profile then return end
	profile.BullMutations = profile.BullMutations or {}
	local forBull = profile.BullMutations[bullId]
	if not forBull then
		forBull = {}
		profile.BullMutations[bullId] = forBull
	end
	forBull[mutId] = true
end

function DataHandler.HasBullMutation(player, bullId, mutId)
	local profile = DataHandler.Profiles[player.UserId]
	local forBull = profile and profile.BullMutations and profile.BullMutations[bullId]
	return (forBull and forBull[mutId]) == true
end

function DataHandler.GetBullMutations(player, bullId)
	local profile = DataHandler.Profiles[player.UserId]
	local muts = profile and profile.BullMutations
	if bullId then
		return muts and muts[bullId]
	end
	return muts
end

return DataHandler
