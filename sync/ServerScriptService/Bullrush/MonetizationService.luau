--[[
	MonetizationService - the game's single Robux hub.

	Every monetizable thing in Bullrush flows through here:

	  DEVELOPER PRODUCTS (consumable, buy again)   Config.PRODUCTS
	    DOUBLE_ROUND     Summary "2x Rewards?"    -> EconomyService handler
	    BULL_ROLL        1 Robux bull roll        -> BullRollService handler
	    BULL_ROLL_10     10 Robux bull rolls      -> BullRollService handler
	    SPIN_1           1 Robux fortune spin     -> SpinService handler
	    SPIN_10          10 Robux fortune spins   -> SpinService handler
	    LUCKY_SECRET     Secret Block wheel spin  -> SpinService handler
	    LUCKY_ALIEN      Alien Block wheel spin   -> SpinService handler
	    LUCKY_GOD        GOD Block wheel spin     -> SpinService handler
	    DAILY_CLAIM_ALL  whole 7-day daily loop   -> DailyRewardService handler
	    SERVER_LUCK      server-wide roll luck    -> handled here (init)
	    MONEY_PACK_1..5  buy Robux -> Money        -> handled here (init, Config.MONEY_PACKS)

	  GAME PASSES (permanent perks)                Config.PASSES
	    VIP                  perk bundle: +50% money, x1.5 roll luck (stacks on
	                         top of luck passes), 2x vote power, an extra daily
	                         wheel spin, and a gold [VIP] chat tag. Money + luck
	                         are here; vote power / daily spin / chat tag live in
	                         the consuming services, keyed off the IsVIP attribute.
	    DOUBLE_MONEY         permanent 2x money        -> PASS_BENEFITS below
	    LUCK_2X/SUPER/MEGA   x2/x3/x5 Epic+Legendary roll luck (highest owned TIER
	                         wins; VIP's x1.5 and Server Luck multiply on top;
	                         getLuckMultiplier)
	    STRAWBERRY_ELEPHANT  grants the Strawberry Elephant Legendary bull on buy

	  LUCK: getLuckMultiplier(player) = highest owned luck pass x active Server Luck;
	  boostedWeights(player, weights) lifts the Config.LUCK.BOOSTED rarities by it.
	  BullRollService feeds every box roll through boostedWeights (box rolls only).

	This module owns the ONE game-wide MarketplaceService.ProcessReceipt and the
	ONE PromptGamePassPurchaseFinished handler - nothing else in the place sets
	them. Domain services that grant a product plug in with registerProduct()
	instead of touching the receipt callback themselves; game-pass perks are
	declared in PASS_BENEFITS and applied on join and on purchase.

	>> IDs ARE LEFT TO FILL IN <<  Every product id lives in Config.PRODUCTS and
	every pass id in Config.PASSES; both are 0 until you publish the asset and
	paste its id. A 0 id is inert - registerProduct ignores it, prompts no-op,
	and ProcessReceipt leaves unknown receipts NotProcessedYet (Roblox retries,
	then refunds) rather than eating the Robux.

	Wiring (Main.server): init FIRST, before the services that register into it.
	  MonetizationService.init()
	  EconomyService.init(...)   -- registers DOUBLE_ROUND
	  BullRollService.init()     -- registers BULL_ROLL / BULL_ROLL_10
	  SpinService.init()         -- registers SPIN_1 / SPIN_10 + LUCKY_SECRET/ALIEN/GOD
	  DailyRewardService.init()  -- registers DAILY_CLAIM_ALL
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local HttpService = game:GetService("HttpService")

local Config = require(ReplicatedStorage.Bullrush.Config)
local NotifyService = require(script.Parent.NotifyService)
local DataHandler = require(ServerScriptService.UserData.DataHandler)

local BullrushFolder = ReplicatedStorage:WaitForChild("Bullrush")

local MonetizationService = {}

local NotYet = Enum.ProductPurchaseDecision.NotProcessedYet
local Granted = Enum.ProductPurchaseDecision.PurchaseGranted

--==============================================================================
-- Developer products
--==============================================================================

-- productId -> handler(receipt, player?) -> Enum.ProductPurchaseDecision.
-- Owning services register here; the handler runs inside ProcessReceipt.
local productHandlers: { [number]: (receipt: any, player: Player?) -> Enum.ProductPurchaseDecision } = {}

-- Called by a domain service in its init() to claim a product id. A 0 id (not
-- yet published) is silently skipped, so unconfigured products stay inert.
function MonetizationService.registerProduct(
	productId: number,
	handler: (receipt: any, player: Player?) -> Enum.ProductPurchaseDecision
)
	if productId and productId ~= 0 then
		if productHandlers[productId] then
			warn("MonetizationService: product id already registered:", productId)
		end
		productHandlers[productId] = handler
	end
end

-- Server-side prompt helper (most product prompts fire client-side, but some
-- flows prompt from the server). Pass a Config.PRODUCTS key, e.g. "SPIN_1".
function MonetizationService.promptProduct(player: Player, productKey: string): boolean
	local id = tonumber(Config.PRODUCTS[productKey]) or 0
	if id == 0 then
		warn("MonetizationService: product not configured:", productKey)
		return false
	end
	local ok, err = pcall(function()
		MarketplaceService:PromptProductPurchase(player, id)
	end)
	if not ok then
		warn("MonetizationService: PromptProductPurchase failed:", err)
	end
	return ok
end

-- The game's sole receipt callback. Dispatches to the registered handler;
-- anything unrecognized is left for Roblox to retry (never granted blindly).
--
-- Roblox delivers receipts at-least-once and re-fires them until we return
-- PurchaseGranted from a callback that has ALREADY committed the grant durably.
-- So this callback enforces two invariants for every product:
--   * Idempotency  - the PurchaseId is recorded in the profile, and a receipt
--                    whose id we've already recorded is acked without re-granting
--                    (no double money / double bull on a retry or duplicate).
--   * Grant-then-save - the grant (in the profile) and its PurchaseId marker are
--                    flushed to the DataStore in one write BEFORE we confirm; if
--                    that write fails we return NotProcessedYet so Roblox retries
--                    (this session or the next) instead of charging for a grant
--                    that could evaporate before the next save.
local function onReceipt(receipt): Enum.ProductPurchaseDecision
	local handler = productHandlers[receipt.ProductId]
	if not handler then
		return NotYet
	end
	local player = Players:GetPlayerByUserId(receipt.PlayerId)

	-- No loaded/saveable profile -> we can't record the grant. Leave it for Roblox
	-- to retry rather than grant into something that won't persist.
	if not player or player:GetAttribute("DataLoadFailed") then
		return NotYet
	end

	-- Already granted this exact purchase. The marker rides in the same profile as
	-- the grant, so if it's present the grant happened; just make sure it's durably
	-- saved before we ack (it may be marked-in-memory from an earlier failed save).
	if DataHandler.HasProcessedReceipt(player, receipt.PurchaseId) then
		return if DataHandler.Save(player) then Granted else NotYet
	end

	local ok, decision = pcall(handler, receipt, player)
	if not ok then
		warn("MonetizationService: product handler errored:", receipt.ProductId, decision)
		return NotYet -- handler blew up mid-grant: retry rather than charge for nothing
	end

	-- Handler declined (e.g. profile not ready, returned NotYet, or forgot to
	-- return): nothing was granted, so nothing to record or save.
	if decision ~= Granted then
		return decision or NotYet
	end

	-- Grant landed in the profile. Record the PurchaseId and flush; only confirm
	-- once the write lands. On a failed save we KEEP the marker (do not roll it
	-- back) so the inevitable retry dedups instead of granting a second time, then
	-- confirms as soon as a save succeeds.
	DataHandler.MarkReceiptProcessed(player, receipt.PurchaseId)
	return if DataHandler.Save(player) then Granted else NotYet
end

--==============================================================================
-- Game passes
--==============================================================================

-- Per-pass perks, keyed by Config.PASSES key. Fields (all optional):
--   moneyBonus  added to the money multiplier while owned (getMoneyMultiplier);
--               0.5 = +50%, 1 = +100%. Stacks across owned passes.
--   luck        Epic/Legendary roll multiplier while owned (getLuckMultiplier);
--               this is a TIER - only the HIGHEST owned luck-tier pass counts
--               (tiers don't stack with each other).
--   luckMult    a STACKING Epic/Legendary roll multiplier (VIP's x1.5); unlike
--               luck tiers, every owned luckMult multiplies together and on top
--               of the winning tier and Server Luck.
--   attribute   a boolean player attribute set true while owned, for the
--               client to read (badges, cosmetics, unlocked UI).
--   apply(player)  arbitrary grant run once on join and once on purchase; make
--               it idempotent (it can run again on rejoin).
-- Add a pass by publishing it, pasting its id into Config.PASSES, and adding a
-- row here - that is the whole integration.
local PASS_BENEFITS: { [string]: { moneyBonus: number?, luck: number?, luckMult: number?, attribute: string?, apply: ((Player) -> ())? } } = {
	-- VIP bundle: +50% money, a x1.5 stacking roll-luck boost, plus 2x vote power,
	-- a daily bonus wheel spin, and a gold [VIP] chat tag - those last three read
	-- the IsVIP attribute in Main.server / SpinService / the client chat hook.
	VIP = { moneyBonus = 0.5, luckMult = 1.5, attribute = "IsVIP" },
	DOUBLE_MONEY = { moneyBonus = 1.0, attribute = "HasDoubleMoney" },
	LUCK_2X = { luck = 2, attribute = "Luck2x" },
	LUCK_SUPER = { luck = 3, attribute = "LuckSuper" },
	LUCK_MEGA = { luck = 5, attribute = "LuckMega" },
	-- Grants the Strawberry Elephant LEGENDARY bull once (idempotent - it also
	-- drops from rolls, so HasBull guards against a double grant / overwrite).
	STRAWBERRY_ELEPHANT = {
		attribute = "HasStrawberryElephant",
		apply = function(player)
			if typeof(player) ~= "Instance" then
				return
			end
			-- Grant off-thread so we can wait out the join-vs-dataload race: a
			-- bull added before the profile loads wouldn't save. HasBull guards
			-- the double-grant (it's also rollable), so re-running is harmless.
			task.spawn(function()
				for _ = 1, 60 do
					if player:GetAttribute("DataLoadFailed") then
						return -- unsaveable session: don't hand out a bull that evaporates
					end
					local ok, bulls = pcall(DataHandler.GetStat, player, "Bulls")
					if ok and bulls ~= nil then
						break
					end
					task.wait(0.5)
				end
				if not player.Parent or DataHandler.HasBull(player, "STRAWBERRY") then
					return
				end
				DataHandler.AddBull(player, "STRAWBERRY")
				local ok, bulls = pcall(DataHandler.GetStat, player, "Bulls")
				if ok and bulls then
					player:SetAttribute("Bulls", HttpService:JSONEncode(bulls)) -- client inventory refresh
				end
				NotifyService.send(player, "You own the Celestial Bull! Equip it in your bull index.", "green", 6)
			end)
		end,
	},
}

-- Cached ownership per player: owned[player][passKey] = true/false. Populated
-- on join (one UserOwnsGamePassAsync per configured pass) and flipped live by
-- the purchase-finished signal, so hot-path queries never yield or web-call.
local owned: { [Player]: { [string]: boolean } } = {}

local function passId(passKey: string): number
	return tonumber(Config.PASSES[passKey]) or 0
end

-- Set the owned-pass attributes + run each owned pass's apply(). Idempotent.
local function applyBenefits(player: Player)
	local bag = owned[player]
	if not bag then
		return
	end
	for passKey, benefit in PASS_BENEFITS do
		local has = bag[passKey] == true
		if benefit.attribute then
			player:SetAttribute(benefit.attribute, has)
		end
		if has and benefit.apply then
			local ok, err = pcall(benefit.apply, player)
			if not ok then
				warn("MonetizationService: pass apply() errored:", passKey, err)
			end
		end
	end
end

-- One web query per configured pass on join; unpublished passes (id 0) resolve
-- to not-owned without a call. Failures cache false (the player can still
-- buy; a bad query never wrongly grants a perk).
local function loadOwnership(player: Player)
	local bag = {}
	owned[player] = bag
	for passKey in PASS_BENEFITS do
		local id = passId(passKey)
		local has = false
		if id ~= 0 then
			local ok, result = pcall(function()
				return MarketplaceService:UserOwnsGamePassAsync(player.UserId, id)
			end)
			if ok then
				has = result == true
			else
				warn("MonetizationService: UserOwnsGamePassAsync failed:", passKey, result)
			end
		end
		bag[passKey] = has
	end
	if player.Parent then
		applyBenefits(player)
	end
end

-- Live truth for "does this player own pass X". Safe on the hot path: reads the
-- join-time cache (kicks a lazy load if the profile query hasn't landed yet).
function MonetizationService.ownsPass(player: Player, passKey: string): boolean
	local bag = owned[player]
	if not bag then
		task.spawn(loadOwnership, player) -- not loaded yet: seed it for next time
		return false
	end
	return bag[passKey] == true
end

-- Combined money multiplier from owned passes (1 = no boost). RoundService
-- stacks this onto the friend boost inside awardMoney, so VIP / Double Money
-- lift every Money grant in the game through the one choke point.
function MonetizationService.getMoneyMultiplier(player: Player): number
	local mult = 1
	local bag = owned[player]
	if bag then
		for passKey, benefit in PASS_BENEFITS do
			if bag[passKey] and benefit.moneyBonus then
				mult += benefit.moneyBonus
			end
		end
	end
	return mult
end

--==============================================================================
-- Luck (Epic/Legendary roll boost)
--==============================================================================

-- Server Luck: a dev product (SERVER_LUCK) buys everyone a temporary boost. The
-- timer is a plain unix deadline; re-buying extends it. Replicated as an
-- attribute so clients can show a countdown.
local serverLuckUntil = 0

local function serverLuckActive(): boolean
	return os.time() < serverLuckUntil
end

local function serverLuckMultiplier(): number
	return serverLuckActive() and Config.LUCK.SERVER.multiplier or 1
end

local function replicateServerLuck()
	BullrushFolder:SetAttribute("ServerLuckUntil", serverLuckUntil)
end

-- Total Epic/Legendary luck for this player: the HIGHEST owned luck TIER (tiers
-- don't stack with each other), times every owned stacking luckMult (VIP's
-- x1.5), times the current Server Luck (which also stacks on top). 1 = no boost.
-- Safe for bot/stub players (no owned bag -> just server).
function MonetizationService.getLuckMultiplier(player): number
	local tierMult = 1  -- highest owned luck TIER (LUCK_2X/SUPER/MEGA)
	local stackMult = 1 -- product of every owned stacking luckMult (VIP)
	local bag = owned[player]
	if bag then
		for passKey, benefit in PASS_BENEFITS do
			if bag[passKey] then
				if benefit.luck and benefit.luck > tierMult then
					tierMult = benefit.luck
				end
				if benefit.luckMult then
					stackMult *= benefit.luckMult
				end
			end
		end
	end
	return tierMult * stackMult * serverLuckMultiplier()
end

-- Returns a copy of `weights` with the Config.LUCK.BOOSTED rarities multiplied by
-- the player's luck (BullCatalog.roll renormalizes, so higher weight = higher
-- odds). Unchanged table when luck is 1, so the no-boost path allocates nothing.
function MonetizationService.boostedWeights(player, weights: { [string]: number }): { [string]: number }
	local mult = MonetizationService.getLuckMultiplier(player)
	if mult <= 1 then
		return weights
	end
	local out = {}
	for rarity, w in weights do
		out[rarity] = if Config.LUCK.BOOSTED[rarity] then w * mult else w
	end
	return out
end

-- Server-side pass prompt. Pass a Config.PASSES key, e.g. "VIP".
function MonetizationService.promptPass(player: Player, passKey: string): boolean
	local id = passId(passKey)
	if id == 0 then
		warn("MonetizationService: pass not configured:", passKey)
		return false
	end
	local ok, err = pcall(function()
		MarketplaceService:PromptGamePassPurchase(player, id)
	end)
	if not ok then
		warn("MonetizationService: PromptGamePassPurchase failed:", err)
	end
	return ok
end

local function onPassPurchased(player: Player, purchasedId: number, wasPurchased: boolean)
	if not wasPurchased then
		return
	end
	for passKey in PASS_BENEFITS do
		if passId(passKey) == purchasedId then
			local bag = owned[player]
			if not bag then
				bag = {}
				owned[player] = bag
			end
			bag[passKey] = true
			applyBenefits(player)
			NotifyService.send(player, "Purchase complete - thanks for the support!", "green", 5)
			return
		end
	end
end

--==============================================================================
-- Lifecycle
--==============================================================================

function MonetizationService.init()
	-- Sole game-wide receipt callback. pcall so edit-mode test harnesses
	-- without receipt access still load us (same guard EconomyService used).
	local ok, err = pcall(function()
		MarketplaceService.ProcessReceipt = onReceipt
	end)
	if not ok then
		warn("MonetizationService: ProcessReceipt not installed:", err)
	end

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(onPassPurchased)

	-- Server Luck dev product: each buy extends the server-wide boost and
	-- announces it. Skipped while its id is 0 (registerProduct ignores 0).
	replicateServerLuck()
	MonetizationService.registerProduct(Config.PRODUCTS.SERVER_LUCK, function(_receipt, player)
		local now = os.time()
		serverLuckUntil = math.max(serverLuckUntil, now) + Config.LUCK.SERVER.duration
		replicateServerLuck()
		local mins = math.floor(Config.LUCK.SERVER.duration / 60)
		local who = if player then player.DisplayName else "Someone"
		NotifyService.broadcast(
			("%s activated SERVER LUCK! %dx Epic & Legendary odds for everyone (%d min)"):format(
				who, Config.LUCK.SERVER.multiplier, mins), "green", 6)
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end)

	-- Money Packs: grant `amount` Money RAW (a purchase, not round earnings, so
	-- no boosts). Needs a loaded/saveable profile or the money would evaporate -
	-- return NotProcessedYet so Roblox retries rather than eating the Robux.
	for _, pack in Config.MONEY_PACKS do
		MonetizationService.registerProduct(Config.PRODUCTS[pack.product], function(_receipt, player)
			if not player or player:GetAttribute("DataLoadFailed") then
				return NotYet
			end
			local ok, money = pcall(DataHandler.GetStat, player, "Money")
			if not ok or money == nil then
				return NotYet
			end
			DataHandler.SetStat(player, "Money", money + pack.amount)
			NotifyService.send(player, ("You got %s from the %s!"):format(pack.label, pack.name), "green", 5)
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end)
	end

	-- Seed ownership for anyone already in (studio join can beat this connect).
	for _, player in Players:GetPlayers() do
		task.spawn(loadOwnership, player)
	end
	Players.PlayerAdded:Connect(function(player)
		task.spawn(loadOwnership, player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		owned[player] = nil
	end)
end

return MonetizationService
