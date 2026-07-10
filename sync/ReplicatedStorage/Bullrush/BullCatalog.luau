--[[
	BullCatalog - the full bull roster for the roll system, shared so
	StarterGui.Main can render the roll/inventory UI from the same data the
	server rolls against. Pure data + lookups; no Instances, no state.

	A bull:
	  id         stable save key (profile.Bulls[id] = true) - the table key below
	  name       display name
	  rarity     key into BullCatalog.Rarities
	  speed      studs/s for the revenge bull launched from the bull-cam;
	             the EQUIPPED bull's speed replaces Config.REVENGE.SPEED
	  modelName  ReplicatedStorage.BullrushAssets.Bulls child to clone
	             (BullService.charge); nil = the default BullTemplate.
	             Models are per rarity TIER for now (user decision
	             2026-07-08): ice/galaxy/lava/gold Meshy bison skins.
	  rollable   false keeps it out of the roll pool (starter + exclusives)

	Rolling (BullCatalog.roll): pick a rarity by weight, then a uniform bull
	within that rarity. The default weights below are overridable per roll -
	each lucky box in Config.BULLS.BOXES carries its own rarity weight table.
	Duplicate pulls refund box.cost * rarity.dupeRefund Money (BullRollService).
]]

local BullCatalog = {}

-- order/color are for the client UI (sort + rarity tinting); the server only
-- reads weight and dupeRefund.
BullCatalog.Rarities = {
	COMMON    = { weight = 55,  dupeRefund = 0.25, order = 1, color = Color3.fromRGB(170, 170, 170) },
	UNCOMMON  = { weight = 25,  dupeRefund = 0.30, order = 2, color = Color3.fromRGB(96, 200, 96) },
	RARE      = { weight = 13,  dupeRefund = 0.35, order = 3, color = Color3.fromRGB(80, 150, 255) },
	EPIC      = { weight = 5.5, dupeRefund = 0.40, order = 4, color = Color3.fromRGB(190, 90, 255) },
	LEGENDARY = { weight = 1.5, dupeRefund = 0.50, order = 5, color = Color3.fromRGB(255, 190, 40) },
}

-- Placeholder roster: speeds only for now (Config.REVENGE.SPEED was 50; the
-- difficulty ramp tops out at 62, so LEGENDARY overtakes even endgame bulls).
BullCatalog.Bulls = {
	-- Everyone owns and starts equipped with the starter (granted by the
	-- default profile in DataHandler; old saves pick it up on load merge).
	STARTER     = { name = "Ranch Bull",      rarity = "COMMON",    speed = 50, rollable = false },

	-- COMMON is the variety rarity: DUSTY keeps the default BullTemplate rig;
	-- the rest are distinct Meshy skins, each its own model in
	-- BullrushAssets.Bulls (Bull_COMMON_*). Higher rarities share one tier model
	-- each (STARTER shares the default rig, CELESTIAL the EPIC rig).
	DUSTY       = { name = "Dusty",           rarity = "COMMON",    speed = 50 },
	RED         = { name = "Red",             rarity = "COMMON",    speed = 48, modelName = "Bull_COMMON_RED" },
	YELLOW      = { name = "Yellow",          rarity = "COMMON",    speed = 49, modelName = "Bull_COMMON_YELLOW" },
	GREEN       = { name = "Green",           rarity = "COMMON",    speed = 51, modelName = "Bull_COMMON_GREEN" },
	BLUE        = { name = "Blue",            rarity = "COMMON",    speed = 52, modelName = "Bull_COMMON_STEEL" },

	LONGHORN    = { name = "Longhorn",        rarity = "UNCOMMON",  speed = 55, modelName = "Bull_UNCOMMON" },

	MIDNIGHT    = { name = "Midnight",        rarity = "RARE",      speed = 60, modelName = "Bull_RARE" },

	DIABLO      = { name = "El Diablo",       rarity = "EPIC",      speed = 68, modelName = "Bull_EPIC" },

	-- Fortune-wheel exclusive (Config.SPINNER slice 1, granted by SpinService);
	-- rollable=false keeps it out of the Money/Robux roll pool.
	CELESTIAL   = { name = "Celestial Bull",  rarity = "EPIC",      speed = 67, rollable = false, modelName = "Bull_EPIC" },

	GOLDEN      = { name = "The Golden Bull", rarity = "LEGENDARY", speed = 74, modelName = "Bull_LEGENDARY" },
}

export type Bull = {
	name: string,
	rarity: string,
	speed: number,
	modelName: string?,
	rollable: boolean?,
}

function BullCatalog.get(bullId: string): Bull?
	return BullCatalog.Bulls[bullId]
end

-- { rarityKey -> {bullId} } of rollable bulls, built once on first roll.
local pools = nil
local function getPools()
	if not pools then
		pools = {}
		for id, bull in BullCatalog.Bulls do
			if bull.rollable ~= false then
				local pool = pools[bull.rarity]
				if not pool then
					pool = {}
					pools[bull.rarity] = pool
				end
				table.insert(pool, id)
			end
		end
	end
	return pools
end

-- One weighted roll: rarity by weight (only rarities that actually have a
-- rollable bull count), then uniform within the rarity. The caller passes the
-- Random instance so tests can seed it. `weights` (optional, { rarity -> w })
-- overrides the default per-rarity weights - lucky boxes each bring their own
-- table; rarities weighted <= 0 (or absent from the table) can't drop.
function BullCatalog.roll(rng: Random, weights: { [string]: number }?): string
	local rarityPools = getPools()
	local function weightOf(rarity)
		local w = if weights then weights[rarity] or 0 else BullCatalog.Rarities[rarity].weight
		return math.max(w, 0)
	end
	local totalWeight = 0
	for rarity in rarityPools do
		totalWeight += weightOf(rarity)
	end
	if totalWeight <= 0 then
		-- a box with all-zero weights is a config bug; fall back to the defaults
		return BullCatalog.roll(rng)
	end
	local pick = rng:NextNumber() * totalWeight
	for rarity, pool in rarityPools do
		local w = weightOf(rarity)
		if w > 0 then
			pick -= w
			if pick <= 0 then
				return pool[rng:NextInteger(1, #pool)]
			end
		end
	end
	-- float dust at the very top of the range: any weighted pool works
	for rarity, pool in rarityPools do
		if weightOf(rarity) > 0 then
			return pool[1]
		end
	end
	local _, pool = next(rarityPools)
	return pool[1]
end

return BullCatalog
