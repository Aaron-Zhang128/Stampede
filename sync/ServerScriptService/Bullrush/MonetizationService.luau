--[[
	MonetizationService - the game's single Robux hub.

	Every monetizable thing in Bullrush flows through here:

	  DEVELOPER PRODUCTS (consumable, buy again)   Config.PRODUCTS
	    DOUBLE_ROUND     Summary "2x Rewards?"    -> EconomyService handler
	    BULL_ROLL        1 Robux bull roll        -> BullRollService handler
	    BULL_ROLL_10     10 Robux bull rolls      -> BullRollService handler
	    SPIN_1           1 Robux fortune spin     -> SpinService handler
	    SPIN_10          10 Robux fortune spins   -> SpinService handler
	    DAILY_CLAIM_ALL  whole 7-day daily loop   -> DailyRewardService handler

	  GAME PASSES (permanent perks)                Config.PASSES
	    VIP            perk bundle + money boost -> PASS_BENEFITS below
	    DOUBLE_MONEY   permanent 2x money        -> PASS_BENEFITS below

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
	  SpinService.init()         -- registers SPIN_1 / SPIN_10
	  DailyRewardService.init()  -- registers DAILY_CLAIM_ALL
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Bullrush.Config)
local NotifyService = require(script.Parent.NotifyService)

local MonetizationService = {}

local NotYet = Enum.ProductPurchaseDecision.NotProcessedYet

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
local function onReceipt(receipt): Enum.ProductPurchaseDecision
	local handler = productHandlers[receipt.ProductId]
	if not handler then
		return NotYet
	end
	local player = Players:GetPlayerByUserId(receipt.PlayerId)
	local ok, decision = pcall(handler, receipt, player)
	if not ok then
		warn("MonetizationService: product handler errored:", receipt.ProductId, decision)
		return NotYet -- handler blew up mid-grant: retry rather than charge for nothing
	end
	-- A handler that forgets to return is treated as "not done" so Roblox
	-- retries instead of us silently swallowing the purchase.
	return decision or NotYet
end

--==============================================================================
-- Game passes
--==============================================================================

-- Per-pass perks, keyed by Config.PASSES key. Fields (all optional):
--   moneyBonus  added to the money multiplier while owned (getMoneyMultiplier);
--               0.5 = +50%, 1 = +100%. Stacks across owned passes.
--   attribute   a boolean player attribute set true while owned, for the
--               client to read (badges, cosmetics, unlocked UI).
--   apply(player)  arbitrary grant run once on join and once on purchase; make
--               it idempotent (it can run again on rejoin).
-- Add a pass by publishing it, pasting its id into Config.PASSES, and adding a
-- row here - that is the whole integration.
local PASS_BENEFITS: { [string]: { moneyBonus: number?, attribute: string?, apply: ((Player) -> ())? } } = {
	VIP = { moneyBonus = 0.5, attribute = "IsVIP" },
	DOUBLE_MONEY = { moneyBonus = 1.0, attribute = "HasDoubleMoney" },
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
