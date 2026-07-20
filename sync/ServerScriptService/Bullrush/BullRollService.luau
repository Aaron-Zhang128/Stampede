--[[
	BullRollService - the roll + equip backend for revenge bulls.

	Players buy LUCKY BOXES (Config.BULLS.BOXES) - each box is one roll of the
	shared BullCatalog with the box's own rarity weights. The EQUIPPED bull's
	speed replaces Config.REVENGE.SPEED on the bull sent from the overhead
	bull-cam (RevengeService calls getEquippedBull at throw time). Duplicate
	pulls auto-refund box.cost * rarity.dupeRefund Money - a refund, not an
	earner, so it's granted RAW (no friend boost / mode multiplier).

	Every pull is also a MUTATION lottery (box.mutationChance, then
	BullCatalog.rollMutation by weight) — currently OFF game-wide via
	Config.BULLS.MUTATIONS_ENABLED = false: a cosmetic particle aura that sticks
	to THAT bull forever ({bullId = {mutId = true}}), dupes included - so a
	dupe pull can still upgrade the bull it duplicates. The equipped bull
	wears its rarest owned mutation (BullCatalog.bestMutation) on revenge
	throws.

	Client contract (StarterGui.Main owns ALL the UI, per the house rule):
	- BullRoll:FireServer(boxId)      buy + open one Config.BULLS.BOXES box
	- BullEquip:FireServer(bullId)    equip an owned BullCatalog id
	- BullAck:FireClient(player, kind, data) answers the caller only:
	    "ROLLED"   { results = {{bullId, rarity, isNew, refund,
	                 mutation = mutId?, mutationIsNew = boolean?}}, boxId,
	                 money = new balance, source = "MONEY" | "ROBUX" | "FREE" }
	    "EQUIPPED" { bullId }
	    "DENIED"   { reason = "NO_MONEY" (+ cost) | "DATA_NOT_LOADED"
	                        | "NOT_OWNED" | "BAD_ID" | "BAD_BOX" }
	Inventory replicates as player attributes (set on join by Data.server.luau,
	refreshed here after every roll): Bulls = JSON { bullId = true },
	BullMutations = JSON { bullId = { mutId = true } }, EquippedBull = id -
	so the UI needs no fetch remote.

	Robux rolls (Config.PRODUCTS.BULL_ROLL = 1 roll, BULL_ROLL_10 = 10): the
	client prompts the purchase itself via MarketplaceService; the receipts
	land in MonetizationService's ProcessReceipt (the game's ONLY one) and are
	dispatched to the handlers this module registers in init(). Ids are 0
	until the place is published - unconfigured products never register.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Bullrush.Config)
local BullCatalog = require(ReplicatedStorage.Bullrush.BullCatalog)
local Remotes = ReplicatedStorage.Bullrush.Remotes
local DataHandler = require(ServerScriptService.UserData.DataHandler)

local NotifyService = require(script.Parent.NotifyService)
local MonetizationService = require(script.Parent.MonetizationService)

-- Silent spam guard, one clock PER ACTION (roll and equip each get their own):
-- a guard shared across both let an equip silently eat a roll fired within the
-- gap after it - no ROLLED/DENIED ack ever came, stranding the client's
-- `rolling` flag (and its Lucky Box UI) until rejoin.
local REQUEST_GAP = 0.5

local BullRollService = {}

local rng = Random.new()
local lastRollAt: { [Player]: number } = {}
local lastEquipAt: { [Player]: number } = {}

-- These remotes are the newest; the Remotes folder is built in edit mode, so
-- ensure them here for places that predate the roll system (same pattern as
-- RevengeService's RevengeThrow).
local function ensureRemote(name: string): RemoteEvent
	local remote = Remotes:FindFirstChild(name)
	if not (remote and remote:IsA("RemoteEvent")) then
		remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = Remotes
	end
	return remote
end
local rollRemote = ensureRemote("BullRoll")
local equipRemote = ensureRemote("BullEquip")
local ackRemote = ensureRemote("BullAck")
local communityRemote = ensureRemote("ClaimCommunityReward")

-- Smoke tests may drive this with duck-typed stub players; only real
-- Players can receive remote acks (same idiom as RevengeService.ack).
local function ack(player, kind: string, data: { [string]: any })
	if typeof(player) == "Instance" then
		ackRemote:FireClient(player, kind, data)
	end
end

-- A roll both spends and saves, so it needs a profile that (a) exists and
-- (b) loaded cleanly - a DataLoadFailed session would take real Money for
-- bulls that evaporate on leave.
local function profileReady(player): boolean
	if typeof(player) == "Instance" and player:GetAttribute("DataLoadFailed") then
		return false
	end
	local ok, money = pcall(DataHandler.GetStat, player, "Money")
	return ok and money ~= nil
end

local function refreshInventoryAttribute(player)
	if typeof(player) ~= "Instance" then
		return
	end
	local ok, bulls = pcall(DataHandler.GetStat, player, "Bulls")
	if ok and bulls then
		player:SetAttribute("Bulls", HttpService:JSONEncode(bulls))
		player:SetAttribute("EquippedBull", DataHandler.GetEquippedBull(player))
	end
	local okMuts, muts = pcall(DataHandler.GetStat, player, "BullMutations")
	if okMuts and muts then
		player:SetAttribute("BullMutations", HttpService:JSONEncode(muts))
	end
end

-- Mirrors the banked free-box openings ({boxId = count}, set on join by
-- Data.server) so the shop card / ROLL AGAIN button can read "FREE". Updated
-- the moment a free roll is SPENT — not reveal-gated like the inventory: the
-- label flipping back to the price mid-carousel spoils nothing.
local function refreshFreeRollsAttribute(player)
	if typeof(player) ~= "Instance" then
		return
	end
	local ok, bank = pcall(DataHandler.GetStat, player, "FreeBoxRolls")
	if ok and typeof(bank) == "table" then
		player:SetAttribute("FreeBoxRolls", HttpService:JSONEncode(bank))
	end
end

--==============================================================================
-- Rolling
--==============================================================================

-- boxId -> (boxId, box) from Config.BULLS.BOXES; nil for junk input.
local function getBox(boxId: any): (string?, any)
	if typeof(boxId) == "string" then
		local box = Config.BULLS.BOXES[boxId]
		if box then
			return boxId, box
		end
	end
	return nil, nil
end

-- Grants `count` already-paid-for openings of `box` and acks the batch. Dupe
-- refunds (box.cost basis) are summed and granted raw at the end (one profile
-- write, not one per dupe). Each pull also rolls the box's mutationChance
-- (skipped entirely while Config.BULLS.MUTATIONS_ENABLED is false); a hit
-- sticks a BullCatalog.Mutations aura to the pulled bull (dupes too, so a
-- dupe pull can still upgrade the bull it duplicates).
-- The grant is REVEAL-GATED: the profile (the saved truth) is written right
-- here — a leave/crash/receipt force-save can never lose a pull — but the
-- visible half (dupe-refund Money tick, the Bulls/BullMutations attributes the
-- Index rides, the server-wide pull broadcasts) is deferred until the client's
-- carousel lands, so nothing on screen spoils a reveal that's still spinning.
-- REVEAL_DELAY mirrors the client's reveal clock: up-front layout settle
-- (a few frames, up to ~1s worst case) + the 4.6s carousel + latency.
local REVEAL_DELAY = 5.5

local function grantRolls(player, count: number, source: string, boxId: string, box, productKey: string?)
	local results = {}
	local refundTotal = 0
	local broadcasts = {}
	for _ = 1, count do
		-- luck (owned luck passes + active Server Luck) lifts Epic/Legendary odds
		local bullId = BullCatalog.roll(rng, MonetizationService.boostedWeights(player, box.weights))
		local bull = BullCatalog.get(bullId) :: BullCatalog.Bull
		local isNew = not DataHandler.HasBull(player, bullId)
		local refund = 0
		local displayName = if typeof(player) == "Instance" then player.DisplayName else player.Name
		if isNew then
			DataHandler.AddBull(player, bullId)
			if bull.rarity == "EPIC" or bull.rarity == "LEGENDARY" then
				table.insert(broadcasts, {
					text = ("%s rolled a %s!"):format(displayName, bull.name:upper()),
					rarity = bull.rarity,
				})
			end
		else
			refund = math.floor(box.cost * BullCatalog.Rarities[bull.rarity].dupeRefund)
			refundTotal += refund
		end
		local mutId, mutationIsNew
		if Config.BULLS.MUTATIONS_ENABLED and rng:NextNumber() < (box.mutationChance or 0) then
			mutId = BullCatalog.rollMutation(rng)
			local mut = BullCatalog.getMutation(mutId) :: BullCatalog.Mutation
			mutationIsNew = not DataHandler.HasBullMutation(player, bullId, mutId)
			if mutationIsNew then
				DataHandler.AddBullMutation(player, bullId, mutId)
			end
			if mut.rarity == "EPIC" or mut.rarity == "LEGENDARY" then
				table.insert(broadcasts, {
					text = ("%s rolled a %s mutation on %s!"):format(displayName, mut.name:upper(), bull.name),
					rarity = mut.rarity,
				})
			end
		end
		table.insert(results, {
			bullId = bullId, rarity = bull.rarity, isNew = isNew, refund = refund,
			mutation = mutId, mutationIsNew = mutationIsNew,
		})
	end
	if refundTotal > 0 then
		DataHandler.AddStatQuiet(player, "Money", refundTotal)
	end
	ack(player, "ROLLED", {
		results = results,
		boxId = boxId,
		money = DataHandler.GetStat(player, "Money"),
		source = source,
		productKey = productKey,
	})

	-- The visible half lands with the carousel. Safe if the player leaves
	-- mid-reveal (attribute/stat mirrors no-op on a gone profile; the pull
	-- itself was committed above). Stub players (smoke tests) get it
	-- synchronously so asserts can read attributes right after the call.
	local function commitReveal()
		refreshInventoryAttribute(player)
		if typeof(player) == "Instance" then
			DataHandler.SyncStat(player, "Money")
		end
		for _, b in broadcasts do
			-- "chat" style: lands in the chat window as "[System]: ..." instead
			-- of a notif card (Main.client's Notify handler routes it there);
			-- the rarity tints the line in that rarity's text gradient
			NotifyService.broadcast(b.text, "chat", nil, b.rarity)
		end
	end
	if typeof(player) == "Instance" then
		task.delay(REVEAL_DELAY, commitReveal)
	else
		commitReveal()
	end
	return results
end

-- OP Lucky Block powerups use the same ROLLED acknowledgement and reveal delay
-- as bulls, but grant permanent ability ownership. Duplicate pulls refund the
-- ability's normal Money-shop price.
local function grantPowerupRolls(player, count: number, opRoll, productKey: string)
	local pool = opRoll.powerups or {}
	local totalWeight = 0
	for _, entry in pool do
		totalWeight += math.max(0, tonumber(entry.weight) or 0)
	end
	if totalWeight <= 0 then
		warn("[BullRoll] OP powerup pool is empty")
		return nil
	end

	local results = {}
	local refundTotal = 0
	local newlyOwned = {}
	for _ = 1, count do
		local roll = rng:NextNumber(0, totalWeight)
		local chosen = pool[#pool]
		for _, entry in pool do
			roll -= math.max(0, tonumber(entry.weight) or 0)
			if roll <= 0 then
				chosen = entry
				break
			end
		end

		local key = chosen.key
		local isNew = not DataHandler.HasAbility(player, key)
		local refund = 0
		if isNew then
			DataHandler.AddAbility(player, key)
			newlyOwned[key] = true
		else
			refund = tonumber(Config.ABILITY_SHOP.PRICES[key]) or 0
			refundTotal += refund
		end
		table.insert(results, {
			abilityKey = key,
			name = chosen.name or key,
			rarity = chosen.rarity or "EPIC",
			isNew = isNew,
			refund = refund,
		})
	end

	if refundTotal > 0 then
		DataHandler.AddStatQuiet(player, "Money", refundTotal)
	end
	ack(player, "ROLLED", {
		results = results,
		boxId = "OP",
		money = DataHandler.GetStat(player, "Money"),
		source = "ROBUX",
		contentType = "POWERUP",
		productKey = productKey,
	})

	local function commitReveal()
		if typeof(player) == "Instance" then
			for key in newlyOwned do
				player:SetAttribute("Owns_" .. key, true)
			end
			DataHandler.SyncStat(player, "Money")
		end
	end
	if typeof(player) == "Instance" then
		task.delay(REVEAL_DELAY, commitReveal)
	else
		commitReveal()
	end
	return results
end

-- Public (not just the remote's target) so smoke tests can call it directly.
function BullRollService.requestRoll(player, requestedBoxId: any)
	local now = os.clock()
	if now - (lastRollAt[player] or 0) < REQUEST_GAP then
		return
	end
	lastRollAt[player] = now

	local boxId, box = getBox(requestedBoxId)
	if not (boxId and box) then
		ack(player, "DENIED", { reason = "BAD_BOX" })
		return
	end
	if not profileReady(player) then
		ack(player, "DENIED", { reason = "DATA_NOT_LOADED" })
		return
	end
	-- Banked free openings (FreeBoxRolls — new players start with one BASIC)
	-- are spent BEFORE Money, so a brand-new player's $0 can't deny the gift.
	local freeBank = DataHandler.GetStat(player, "FreeBoxRolls")
	local banked = if typeof(freeBank) == "table" then tonumber(freeBank[boxId]) or 0 else 0
	if banked > 0 then
		freeBank[boxId] = if banked > 1 then banked - 1 else nil
		refreshFreeRollsAttribute(player)
		grantRolls(player, 1, "FREE", boxId, box)
		return
	end
	local cost = box.cost
	local money = DataHandler.GetStat(player, "Money") or 0
	if money < cost then
		ack(player, "DENIED", { reason = "NO_MONEY", cost = cost })
		return
	end
	DataHandler.SetStat(player, "Money", money - cost)
	grantRolls(player, 1, "MONEY", boxId, box)
end

-- Grant ONE free roll of a box/tier to a player (source "FREE"): resolves the
-- box config from either the Money BOXES or the Robux LUCKY_BLOCKS tiers, then
-- runs the standard grant path — so the client's BullAck "ROLLED" carousel
-- auto-opens exactly like a bought roll. Used by the community reward claim.
function BullRollService.grantFreeRoll(player, boxId: string)
	local box = Config.BULLS.BOXES[boxId] or (Config.LUCKY_BLOCKS and Config.LUCKY_BLOCKS[boxId])
	if not box then
		warn(("[BullRoll] grantFreeRoll: unknown box '%s'"):format(tostring(boxId)))
		return nil
	end
	if not profileReady(player) then
		return nil
	end
	return grantRolls(player, 1, "FREE", boxId, box)
end
function BullRollService.requestEquip(player, bullId: any)
	local now = os.clock()
	if now - (lastEquipAt[player] or 0) < REQUEST_GAP then
		return
	end
	lastEquipAt[player] = now

	if typeof(bullId) ~= "string" or BullCatalog.get(bullId) == nil then
		ack(player, "DENIED", { reason = "BAD_ID" })
		return
	end
	if not profileReady(player) then
		ack(player, "DENIED", { reason = "DATA_NOT_LOADED" })
		return
	end
	if not DataHandler.HasBull(player, bullId) then
		ack(player, "DENIED", { reason = "NOT_OWNED" })
		return
	end
	DataHandler.SetEquippedBull(player, bullId) -- also mirrors the attribute
	ack(player, "EQUIPPED", { bullId = bullId })
end

--==============================================================================
-- Equipped-bull lookup (RevengeService reads this at throw time)
--==============================================================================

export type EquippedBull = {
	id: string,
	name: string,
	rarity: string,
	speed: number,
	modelName: string?,
	mutation: string?,
}

-- Catalog entry (plus its id) of the player's equipped bull. Falls back to
-- STARTER for bot/stub proxies (no UserId -> no profile), unloaded profiles,
-- and ids that fell out of the catalog, so a throw can never crash on data
-- problems. Ownership isn't rechecked: EquippedBull is only ever written
-- through validated equips. mutation = the bull's rarest owned aura
-- (BullCatalog.bestMutation); BullService clones its emitters onto the
-- launched model.
function BullRollService.getEquippedBull(player): EquippedBull
	local bullId = "STARTER"
	local ok, equipped = pcall(DataHandler.GetEquippedBull, player)
	if ok and equipped and BullCatalog.get(equipped) then
		bullId = equipped
	end
	local bull = BullCatalog.get(bullId) :: BullCatalog.Bull
	local okMut, owned = pcall(DataHandler.GetBullMutations, player, bullId)
	return {
		id = bullId,
		name = bull.name,
		rarity = bull.rarity,
		speed = bull.speed,
		modelName = bull.modelName,
		mutation = if okMut then BullCatalog.bestMutation(owned) else nil,
	}
end

--==============================================================================
-- Robux roll products
--==============================================================================

function BullRollService.init()
	local function makeHandler(count: number, productKey: string)
		return function(receipt, player)
			if not player or not profileReady(player) then
				-- Buyer left / data can't save: let Roblox retry the receipt
				-- (and eventually refund) rather than eat the Robux.
				return Enum.ProductPurchaseDecision.NotProcessedYet
			end
			-- Robux rolls open the premium box (best odds; refunds on its cost)
			local boxId, box = getBox(Config.BULLS.ROBUX_BOX)
			if not (boxId and box) then
				boxId, box = next(Config.BULLS.BOXES)
			end
			grantRolls(player, count, "ROBUX", boxId, box, productKey)
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end
	end
	MonetizationService.registerProduct(Config.PRODUCTS.BULL_ROLL, makeHandler(1, "BULL_ROLL"))
	MonetizationService.registerProduct(Config.PRODUCTS.BULL_ROLL_10, makeHandler(10, "BULL_ROLL_10"))

	-- OP Lucky Block: ROBUX powerup rolls. Results keep the shared ROLLED contract
	-- so the existing carousel and multi-result grid present them.
	local opRoll = Config.BULLS.OP_ROLL
	if opRoll and opRoll.powerups then
		for _, bundle in opRoll.bundles or {} do
			local count = bundle.count
			local productKey = bundle.product
			local productId = tonumber(Config.PRODUCTS[productKey]) or 0
			if productId > 0 then
				MonetizationService.registerProduct(productId, function(_receipt, player)
					if not player or not profileReady(player) then
						return Enum.ProductPurchaseDecision.NotProcessedYet
					end
					grantPowerupRolls(player, count, opRoll, productKey)
					return Enum.ProductPurchaseDecision.PurchaseGranted
				end)
			end
		end
	end

	-- Store Lucky Blocks: ROBUX bull rolls from each tier's own rarity pool
	-- (Config.LUCKY_BLOCKS - NOT wheel spins). A tier already reads as a box -
	-- grantRolls only touches its weights, cost (dupe-refund basis; Robux-bought,
	-- so no Money is charged) and mutationChance. tierId ("SECRET"/"ALIEN"/"GOD")
	-- rides as the boxId, opaque to the client like "OP" above (its ROLLED
	-- handler just won't retarget the ROLL AGAIN button), and the bull-carousel
	-- reveal auto-opens off the ack.
	for tierId, tier in Config.LUCKY_BLOCKS or {} do
		local productId = tonumber(Config.PRODUCTS[tier.product]) or 0
		if productId > 0 then
			MonetizationService.registerProduct(productId, function(_receipt, player)
				if not player or not profileReady(player) then
					return Enum.ProductPurchaseDecision.NotProcessedYet
				end
				grantRolls(player, 1, "ROBUX", tierId, tier, tier.product)
				return Enum.ProductPurchaseDecision.PurchaseGranted
			end)
		end
	end
end

rollRemote.OnServerEvent:Connect(function(player, boxId)
	BullRollService.requestRoll(player, boxId)
end)

equipRemote.OnServerEvent:Connect(function(player, bullId)
	BullRollService.requestEquip(player, bullId)
end)

-- "Like & Join the community" free reward (Main.client's Free Rewards panel):
-- a ONE-TIME free Secret Block roll gated on Roblox group membership. Studio
-- bypasses the group check AND skips persistence so the flow stays re-testable
-- with no live leak. On success the reward rides grantFreeRoll's standard path,
-- so the client's BullAck "ROLLED" carousel auto-opens like any roll; the reply
-- on this remote only drives the panel's own feedback.
local IS_STUDIO = RunService:IsStudio()
communityRemote.OnServerEvent:Connect(function(player)
	if not profileReady(player) then
		communityRemote:FireClient(player, "DATA")
		return
	end
	if DataHandler.GetStat(player, "GroupRewardClaimed") == true and not IS_STUDIO then
		communityRemote:FireClient(player, "ALREADY_CLAIMED")
		return
	end
	local groupId = tonumber(Config.COMMUNITY and Config.COMMUNITY.GROUP_ID) or 0
	local inGroup = IS_STUDIO
	if not inGroup and groupId > 0 then
		local ok, res = pcall(function()
			return player:IsInGroup(groupId)
		end)
		inGroup = ok and res == true
	end
	if not inGroup then
		communityRemote:FireClient(player, "NOT_IN_GROUP")
		return
	end
	if not IS_STUDIO then
		DataHandler.SetStat(player, "GroupRewardClaimed", true)
		player:SetAttribute("GroupRewardClaimed", true)
	end
	communityRemote:FireClient(player, "OK")
	BullRollService.grantFreeRoll(player, (Config.COMMUNITY and Config.COMMUNITY.REWARD_BOX) or "SECRET")
end)

Players.PlayerRemoving:Connect(function(player)
	lastRollAt[player] = nil
	lastEquipAt[player] = nil
end)

return BullRollService
