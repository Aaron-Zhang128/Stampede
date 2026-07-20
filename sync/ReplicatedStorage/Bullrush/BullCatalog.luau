--[[
	BullCatalog - the full bull roster for the roll system, shared so
	StarterGui.Main can render the roll/inventory UI from the same data the
	server rolls against. Pure data + lookups; no Instances, no state.

	A bull:
	  id         stable save key (profile.Bulls[id] = true) - the table key below
	  name       display name
	  rarity     key into BullCatalog.Rarities
	  speed      studs/s whenever this bull charges. Main wave bulls select the
	             closest catalog speed as difficulty ramps from 17 to 62; the
	             EQUIPPED revenge bull uses the same value
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

-- Catalog speeds share the main round's full 17..62 gameplay range. The roster
-- follows the old relative speed order, except STARTER deliberately owns the
-- 17-speed opening step so every round begins with the default Ranch Bull before
-- progressing into skinned bulls. A bull's look remains an honest speed cue in
-- both normal waves and revenge throws.
BullCatalog.Bulls = {
	-- Everyone owns and starts equipped with the starter (granted by the
	-- default profile in DataHandler; old saves pick it up on load merge).
	STARTER     = { name = "Ranch Bull",      rarity = "COMMON",    speed = 17, rollable = false },

	-- COMMON is the variety rarity: four distinct Meshy skins, each its own model
	-- in BullrushAssets.Bulls (Bull_COMMON_*). Higher rarities share one tier
	-- model each; STARTER (the granted starter) uses the default BullTemplate rig.
	RED         = { name = "Red",             rarity = "COMMON",    speed = 18, modelName = "Bull_COMMON_RED" },
	YELLOW      = { name = "Yellow",          rarity = "COMMON",    speed = 19, modelName = "Bull_COMMON_YELLOW" },
	GREEN       = { name = "Green",           rarity = "COMMON",    speed = 22, modelName = "Bull_COMMON_GREEN" },
	BLUE        = { name = "Blue",            rarity = "COMMON",    speed = 23, modelName = "Bull_COMMON_STEEL" },

	BRONZE      = { name = "Bronze",          rarity = "COMMON",    speed = 20, modelName = "Bull_BRONZE" },

	LONGHORN    = { name = "Longhorn",        rarity = "UNCOMMON",  speed = 28, modelName = "Bull_UNCOMMON" },
	SILVER      = { name = "Silver",          rarity = "UNCOMMON",  speed = 30, modelName = "Bull_SILVER" },
	ICE         = { name = "Ice",             rarity = "UNCOMMON",  speed = 31, modelName = "Bull_ICE" },

	MIDNIGHT    = { name = "Midnight",        rarity = "RARE",      speed = 36, modelName = "Bull_RARE",  themeMutation = "STAR" },
	GOLD        = { name = "Gold",            rarity = "RARE",      speed = 38, modelName = "Bull_GOLD",  themeMutation = "GOLD" },
	MAGMA       = { name = "Magma",           rarity = "RARE",      speed = 40, modelName = "Bull_MAGMA", themeMutation = "FIRE" },

	DARK        = { name = "Dark",            rarity = "EPIC",      speed = 46, modelName = "Bull_DARK",      themeMutation = "BLACKHOLE" },
	CYBERPUNK   = { name = "Cyberpunk",       rarity = "EPIC",      speed = 48, modelName = "Bull_CYBERPUNK", themeMutation = "LIGHTNING" },
	-- The original EPIC, rollable AND the fortune-wheel prize (Config.SPINNER slice 1).
	DIABLO      = { name = "El Diablo",       rarity = "EPIC",      speed = 49, modelName = "Bull_EPIC", themeMutation = "FIRE" },

	PHAROW      = { name = "Pharaoh",         rarity = "LEGENDARY", speed = 56, modelName = "Bull_PHAROW",    themeMutation = "RADIOACTIVE" },
	GOLDEN      = { name = "The Golden Bull", rarity = "LEGENDARY", speed = 59, modelName = "Bull_LEGENDARY", themeMutation = "GOLD" },
	LUX         = { name = "Lux",             rarity = "LEGENDARY", speed = 60, modelName = "Bull_LUX",       themeMutation = "GOLD" },
	-- Sold via the STRAWBERRY_ELEPHANT game pass ("Celestial Bull" on Roblox;
	-- granted instantly on purchase); rollable too, so it also drops as a rare
	-- LEGENDARY. Save key stays STRAWBERRY. modelName is a PLACEHOLDER (reuses the
	-- generic legendary skin) until the real model lands.
	STRAWBERRY  = { name = "Celestial Bull", rarity = "LEGENDARY", speed = 62, modelName = "Bull_LEGENDARY", themeMutation = "STAR" },
}

-- Stable speed order for normal wave progression. Entries sharing a speed are
-- both eligible, giving the 20-speed step a little cosmetic variety without
-- ever selecting a bull faster or slower than the chosen catalog step.
local WAVE_BULL_ORDER = {
	"STARTER", "RED", "YELLOW", "BRONZE", "GREEN", "BLUE",
	"LONGHORN", "SILVER", "ICE", "MIDNIGHT", "GOLD", "MAGMA",
	"DARK", "CYBERPUNK", "DIABLO", "PHAROW", "GOLDEN", "LUX", "STRAWBERRY",
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
	themeMutation: string?,
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

-- Return the catalog bull nearest to the continuous difficulty target. Main
-- then uses this bull's exact speed, turning the old smooth ramp into readable
-- catalog-speed steps. Ties between different speeds prefer the slower step;
-- duplicate bulls at the selected speed are chosen randomly for variety.
function BullCatalog.forWaveSpeed(targetSpeed: number, rng: Random?): (string, Bull)
	local bestDistance = math.huge
	local bestSpeed = math.huge
	local candidates = {}
	for _, bullId in WAVE_BULL_ORDER do
		local bull = BullCatalog.Bulls[bullId]
		local distance = math.abs(bull.speed - targetSpeed)
		if distance < bestDistance or (distance == bestDistance and bull.speed < bestSpeed) then
			bestDistance = distance
			bestSpeed = bull.speed
			table.clear(candidates)
			table.insert(candidates, bullId)
		elseif distance == bestDistance and bull.speed == bestSpeed then
			table.insert(candidates, bullId)
		end
	end
	local index = if rng and #candidates > 1 then rng:NextInteger(1, #candidates) else 1
	local bullId = candidates[index]
	return bullId, BullCatalog.Bulls[bullId]
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
