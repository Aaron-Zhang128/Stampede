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

	MUTATIONS: cosmetic particle auras (ReplicatedStorage.Mutations.<vfxName>)
	that a box pull can land ON TOP of the bull (box.mutationChance, then
	BullCatalog.rollMutation by per-mutation weight). Owned per bull
	(profile.BullMutations[bullId][mutId] = true); the equipped bull wears its
	RAREST owned mutation on revenge throws (BullService clones the emitters
	onto the bull's Body).
]]

local BullCatalog = {}

-- order/color are for the client UI (sort + rarity tinting); the server only
-- reads weight and dupeRefund.
BullCatalog.Rarities = {
	COMMON    = { weight = 55,  dupeRefund = 0.25, order = 1, color = Color3.fromRGB(205, 212, 222) },
	UNCOMMON  = { weight = 25,  dupeRefund = 0.30, order = 2, color = Color3.fromRGB(58, 224, 104) },
	RARE      = { weight = 13,  dupeRefund = 0.35, order = 3, color = Color3.fromRGB(46, 158, 255) },
	EPIC      = { weight = 5.5, dupeRefund = 0.40, order = 4, color = Color3.fromRGB(196, 78, 255) },
	LEGENDARY = { weight = 1.5, dupeRefund = 0.50, order = 5, color = Color3.fromRGB(255, 182, 24) },
}

-- Placeholder roster: speeds only for now (Config.REVENGE.SPEED was 50; the
-- difficulty ramp tops out at 62, so LEGENDARY overtakes even endgame bulls).
BullCatalog.Bulls = {
	-- Everyone owns and starts equipped with the starter (granted by the
	-- default profile in DataHandler; old saves pick it up on load merge).
	STARTER     = { name = "Ranch Bull",      rarity = "COMMON",    speed = 50, rollable = false },

	-- COMMON is the variety rarity: four distinct Meshy skins, each its own model
	-- in BullrushAssets.Bulls (Bull_COMMON_*). Higher rarities share one tier
	-- model each; STARTER (the granted starter) uses the default BullTemplate rig.
	RED         = { name = "Red",             rarity = "COMMON",    speed = 48, modelName = "Bull_COMMON_RED" },
	YELLOW      = { name = "Yellow",          rarity = "COMMON",    speed = 49, modelName = "Bull_COMMON_YELLOW" },
	GREEN       = { name = "Green",           rarity = "COMMON",    speed = 51, modelName = "Bull_COMMON_GREEN" },
	BLUE        = { name = "Blue",            rarity = "COMMON",    speed = 52, modelName = "Bull_COMMON_STEEL" },

	BRONZE      = { name = "Bronze",          rarity = "COMMON",    speed = 50, modelName = "Bull_BRONZE" },

	LONGHORN    = { name = "Longhorn",        rarity = "UNCOMMON",  speed = 55, modelName = "Bull_UNCOMMON" },
	SILVER      = { name = "Silver",          rarity = "UNCOMMON",  speed = 56, modelName = "Bull_SILVER" },
	ICE         = { name = "Ice",             rarity = "UNCOMMON",  speed = 57, modelName = "Bull_ICE" },

	MIDNIGHT    = { name = "Midnight",        rarity = "RARE",      speed = 60, modelName = "Bull_RARE" },
	GOLD        = { name = "Gold",            rarity = "RARE",      speed = 61, modelName = "Bull_GOLD" },
	MAGMA       = { name = "Magma",           rarity = "RARE",      speed = 62, modelName = "Bull_MAGMA" },

	DARK        = { name = "Dark",            rarity = "EPIC",      speed = 66, modelName = "Bull_DARK" },
	CYBERPUNK   = { name = "Cyberpunk",       rarity = "EPIC",      speed = 67, modelName = "Bull_CYBERPUNK" },
	-- The original EPIC, rollable AND the fortune-wheel prize (Config.SPINNER slice 1).
	DIABLO      = { name = "El Diablo",       rarity = "EPIC",      speed = 68, modelName = "Bull_EPIC" },

	PHAROW      = { name = "Pharaoh",         rarity = "LEGENDARY", speed = 72, modelName = "Bull_PHAROW" },
	GOLDEN      = { name = "The Golden Bull", rarity = "LEGENDARY", speed = 74, modelName = "Bull_LEGENDARY" },
	LUX         = { name = "Lux",             rarity = "LEGENDARY", speed = 75, modelName = "Bull_LUX" },
	-- Sold via the STRAWBERRY_ELEPHANT game pass ("Celestial Bull" on Roblox;
	-- granted instantly on purchase); rollable too, so it also drops as a rare
	-- LEGENDARY. Save key stays STRAWBERRY. modelName is a PLACEHOLDER (reuses the
	-- generic legendary skin) until the real model lands.
	STRAWBERRY  = { name = "Celestial Bull", rarity = "LEGENDARY", speed = 76, modelName = "Bull_LEGENDARY" },
}

-- Mutations: cosmetic particle auras a pull can land on top of the bull.
-- Graded by how cool they sound/look; weights are PER MUTATION (they sum to
-- 100 for readable odds, but rollMutation normalizes). rarity is display-only
-- (UI tinting/grouping); the roll uses weight alone. vfxName is the
-- ReplicatedStorage.Mutations child whose ParticleEmitters get cloned onto
-- the bull. color tints the mutation's name in the roll/index UI.
BullCatalog.Mutations = {
	TACO        = { name = "Taco",        rarity = "COMMON",    weight = 16,  vfxName = "TACO",        order = 1,  color = Color3.fromRGB(235, 170, 80) },
	CANDY       = { name = "Candy",       rarity = "COMMON",    weight = 15,  vfxName = "CANDY",       order = 2,  color = Color3.fromRGB(255, 110, 160) },
	BUBBLEGUM   = { name = "Bubblegum",   rarity = "COMMON",    weight = 14,  vfxName = "Bubblegum",   order = 3,  color = Color3.fromRGB(255, 160, 215) },

	CONFETTI    = { name = "Confetti",    rarity = "UNCOMMON",  weight = 11,  vfxName = "CONFETTI",    order = 4,  color = Color3.fromRGB(150, 240, 170) },
	ICE         = { name = "Ice",         rarity = "UNCOMMON",  weight = 11,  vfxName = "ICE",         order = 5,  color = Color3.fromRGB(140, 220, 255) },

	GOLD        = { name = "Gold",        rarity = "RARE",      weight = 8,   vfxName = "GOLD",        order = 6,  color = Color3.fromRGB(255, 200, 60) },
	FIRE        = { name = "Fire",        rarity = "RARE",      weight = 8,   vfxName = "FIRE",        order = 7,  color = Color3.fromRGB(255, 110, 40) },
	LIGHTNING   = { name = "Lightning",   rarity = "RARE",      weight = 6,   vfxName = "LIGHTNING",   order = 8,  color = Color3.fromRGB(255, 245, 130) },

	RADIOACTIVE = { name = "Radioactive", rarity = "EPIC",      weight = 4.5, vfxName = "RADIOACTIVE", order = 9,  color = Color3.fromRGB(130, 255, 60) },
	STAR        = { name = "Star",        rarity = "EPIC",      weight = 3.5, vfxName = "STAR",        order = 10, color = Color3.fromRGB(225, 180, 255) },

	DIAMOND     = { name = "Diamond",     rarity = "LEGENDARY", weight = 1.4, vfxName = "DiamondAura", order = 11, color = Color3.fromRGB(125, 240, 230) },
	RAINBOW     = { name = "Rainbow",     rarity = "LEGENDARY", weight = 1.0, vfxName = "RainbowAura", order = 12, color = Color3.fromRGB(255, 120, 235) },
	BLACKHOLE   = { name = "Blackhole",   rarity = "LEGENDARY", weight = 0.5, vfxName = "BLACKHOLE",   order = 13, color = Color3.fromRGB(120, 90, 200) },
	ADMIN       = { name = "Admin",       rarity = "LEGENDARY", weight = 0.1, vfxName = "ADMIN",       order = 14, color = Color3.fromRGB(255, 70, 70) },
}

export type Bull = {
	name: string,
	rarity: string,
	speed: number,
	modelName: string?,
	rollable: boolean?,
}

export type Mutation = {
	name: string,
	rarity: string,
	weight: number,
	vfxName: string,
	order: number,
	color: Color3,
}

function BullCatalog.get(bullId: string): Bull?
	return BullCatalog.Bulls[bullId]
end

function BullCatalog.getMutation(mutId: string): Mutation?
	return BullCatalog.Mutations[mutId]
end

-- One weighted mutation pick (the caller already decided a mutation drops -
-- box.mutationChance gates that in BullRollService).
function BullCatalog.rollMutation(rng: Random): string
	local totalWeight = 0
	for _, mut in BullCatalog.Mutations do
		totalWeight += mut.weight
	end
	local pick = rng:NextNumber() * totalWeight
	local lastId
	for id, mut in BullCatalog.Mutations do
		lastId = id
		pick -= mut.weight
		if pick <= 0 then
			return id
		end
	end
	return lastId -- float dust at the very top of the range
end

-- The coolest mutation in an owned set ({ mutId = true }), i.e. what the bull
-- actually wears: highest display rarity first, then the lower drop weight.
-- nil for empty/absent sets. Shared by BullRollService.getEquippedBull and
-- the index UI so server and client can never disagree on the worn aura.
function BullCatalog.bestMutation(owned: { [string]: any }?): string?
	local bestId, best
	for mutId, flag in owned or {} do
		local mut = flag and BullCatalog.Mutations[mutId]
		if mut then
			if not best
				or BullCatalog.Rarities[mut.rarity].order > BullCatalog.Rarities[best.rarity].order
				or (mut.rarity == best.rarity and mut.weight < best.weight) then
				bestId, best = mutId, mut
			end
		end
	end
	return bestId
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
