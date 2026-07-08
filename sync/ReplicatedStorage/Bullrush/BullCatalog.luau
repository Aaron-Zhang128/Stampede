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
	within that rarity. Duplicate pulls refund
	Config.BULLS.ROLL_COST * rarity.dupeRefund Money (BullRollService).
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

	PLOW        = { name = "Plow Bull",       rarity = "COMMON",    speed = 48 },
	DUSTY       = { name = "Dusty",           rarity = "COMMON",    speed = 50 },
	BRINDLE     = { name = "Brindle",         rarity = "COMMON",    speed = 52 },

	LONGHORN    = { name = "Longhorn",        rarity = "UNCOMMON",  speed = 55, modelName = "Bull_UNCOMMON" },
	IRONHIDE    = { name = "Ironhide",        rarity = "UNCOMMON",  speed = 57, modelName = "Bull_UNCOMMON" },

	MIDNIGHT    = { name = "Midnight",        rarity = "RARE",      speed = 60, modelName = "Bull_RARE" },
	CRIMSON     = { name = "Crimson Fury",    rarity = "RARE",      speed = 62, modelName = "Bull_RARE" },

	THUNDERHOOF = { name = "Thunderhoof",     rarity = "EPIC",      speed = 66, modelName = "Bull_EPIC" },
	DIABLO      = { name = "El Diablo",       rarity = "EPIC",      speed = 68, modelName = "Bull_EPIC" },

	-- Fortune-wheel exclusive (Config.SPINNER slice 1, granted by SpinService);
	-- rollable=false keeps it out of the Money/Robux roll pool.
	LA_VACCA    = { name = "La Vacca",        rarity = "EPIC",      speed = 67, rollable = false, modelName = "Bull_EPIC" },

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
-- Random instance so tests can seed it.
function BullCatalog.roll(rng: Random): string
	local rarityPools = getPools()
	local totalWeight = 0
	for rarity in rarityPools do
		totalWeight += BullCatalog.Rarities[rarity].weight
	end
	local pick = rng:NextNumber() * totalWeight
	for rarity, pool in rarityPools do
		pick -= BullCatalog.Rarities[rarity].weight
		if pick <= 0 then
			return pool[rng:NextInteger(1, #pool)]
		end
	end
	-- float dust at the very top of the range: any pool works
	local _, pool = next(rarityPools)
	return pool[1]
end

return BullCatalog
