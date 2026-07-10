--[[
	BullRollService - the roll + equip backend for revenge bulls.

	Players buy LUCKY BOXES (Config.BULLS.BOXES) - each box is one roll of the
	shared BullCatalog with the box's own rarity weights. The EQUIPPED bull's
	speed replaces Config.REVENGE.SPEED on the bull sent from the overhead
	bull-cam (RevengeService calls getEquippedBull at throw time). Duplicate
	pulls auto-refund box.cost * rarity.dupeRefund Money - a refund, not an
	earner, so it's granted RAW (no friend boost / mode multiplier).

	Client contract (StarterGui.Main owns ALL the UI, per the house rule):
	- BullRoll:FireServer(boxId)      buy + open one Config.BULLS.BOXES box
	- BullEquip:FireServer(bullId)    equip an owned BullCatalog id
	- BullAck:FireClient(player, kind, data) answers the caller only:
	    "ROLLED"   { results = {{bullId, rarity, isNew, refund}}, boxId,
	                 money = new balance, source = "MONEY" | "ROBUX" }
	    "EQUIPPED" { bullId }
	    "DENIED"   { reason = "NO_MONEY" (+ cost) | "DATA_NOT_LOADED"
	                        | "NOT_OWNED" | "BAD_ID" | "BAD_BOX" }
	Inventory replicates as player attributes (set on join by Data.server.luau,
	refreshed here after every roll): Bulls = JSON { bullId = true },
	EquippedBull = id - so the UI needs no fetch remote.

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

local Config = require(ReplicatedStorage.Bullrush.Config)
local BullCatalog = require(ReplicatedStorage.Bullrush.BullCatalog)
local Remotes = ReplicatedStorage.Bullrush.Remotes
local DataHandler = require(ServerScriptService.UserData.DataHandler)

local NotifyService = require(script.Parent.NotifyService)
local MonetizationService = require(script.Parent.MonetizationService)

local REQUEST_GAP = 0.5 -- silent spam guard shared by roll + equip

local BullRollService = {}

local rng = Random.new()
local lastRequestAt: { [Player]: number } = {}

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
-- write, not one per dupe).
local function grantRolls(player, count: number, source: string, boxId: string, box)
	local results = {}
	local refundTotal = 0
	for _ = 1, count do
		local bullId = BullCatalog.roll(rng, box.weights)
		local bull = BullCatalog.get(bullId) :: BullCatalog.Bull
		local isNew = not DataHandler.HasBull(player, bullId)
		local refund = 0
		if isNew then
			DataHandler.AddBull(player, bullId)
			if bull.rarity == "EPIC" or bull.rarity == "LEGENDARY" then
				local displayName = if typeof(player) == "Instance" then player.DisplayName else player.Name
				NotifyService.broadcast(
					("%s pulled %s!"):format(displayName, bull.name:upper()), "green", 5)
			end
		else
			refund = math.floor(box.cost * BullCatalog.Rarities[bull.rarity].dupeRefund)
			refundTotal += refund
		end
		table.insert(results, { bullId = bullId, rarity = bull.rarity, isNew = isNew, refund = refund })
	end
	if refundTotal > 0 then
		DataHandler.SetStat(player, "Money", (DataHandler.GetStat(player, "Money") or 0) + refundTotal)
	end
	refreshInventoryAttribute(player)
	ack(player, "ROLLED", {
		results = results,
		boxId = boxId,
		money = DataHandler.GetStat(player, "Money"),
		source = source,
	})
	return results
end

-- Public (not just the remote's target) so smoke tests can call it directly.
function BullRollService.requestRoll(player, requestedBoxId: any)
	local now = os.clock()
	if now - (lastRequestAt[player] or 0) < REQUEST_GAP then
		return
	end
	lastRequestAt[player] = now

	local boxId, box = getBox(requestedBoxId)
	if not (boxId and box) then
		ack(player, "DENIED", { reason = "BAD_BOX" })
		return
	end
	if not profileReady(player) then
		ack(player, "DENIED", { reason = "DATA_NOT_LOADED" })
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

function BullRollService.requestEquip(player, bullId: any)
	local now = os.clock()
	if now - (lastRequestAt[player] or 0) < REQUEST_GAP then
		return
	end
	lastRequestAt[player] = now

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
}

-- Catalog entry (plus its id) of the player's equipped bull. Falls back to
-- STARTER for bot/stub proxies (no UserId -> no profile), unloaded profiles,
-- and ids that fell out of the catalog, so a throw can never crash on data
-- problems. Ownership isn't rechecked: EquippedBull is only ever written
-- through validated equips.
function BullRollService.getEquippedBull(player): EquippedBull
	local bullId = "STARTER"
	local ok, equipped = pcall(DataHandler.GetEquippedBull, player)
	if ok and equipped and BullCatalog.get(equipped) then
		bullId = equipped
	end
	local bull = BullCatalog.get(bullId) :: BullCatalog.Bull
	return {
		id = bullId,
		name = bull.name,
		rarity = bull.rarity,
		speed = bull.speed,
		modelName = bull.modelName,
	}
end

--==============================================================================
-- Robux roll products
--==============================================================================

function BullRollService.init()
	local function makeHandler(count: number)
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
			grantRolls(player, count, "ROBUX", boxId, box)
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end
	end
	MonetizationService.registerProduct(Config.PRODUCTS.BULL_ROLL, makeHandler(1))
	MonetizationService.registerProduct(Config.PRODUCTS.BULL_ROLL_10, makeHandler(10))
end

rollRemote.OnServerEvent:Connect(function(player, boxId)
	BullRollService.requestRoll(player, boxId)
end)

equipRemote.OnServerEvent:Connect(function(player, bullId)
	BullRollService.requestEquip(player, bullId)
end)

Players.PlayerRemoving:Connect(function(player)
	lastRequestAt[player] = nil
end)

return BullRollService
