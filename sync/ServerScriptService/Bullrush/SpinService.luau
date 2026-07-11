--[[
	SpinService - the fortune wheel backend (Frames.Spinner UI + the lobby
	FortuneWheel model).

	Spins are a banked count on the profile (Spins): one accrues free every
	Config.SPINNER.FREE_SPIN_INTERVAL (LastFreeSpin tracks the last accrual;
	only one banks per interval - going idle for a week still yields one),
	more come from the SPIN_1/SPIN_10 dev products. The reward table is
	Config.SPINNER.REWARDS - the same table the client paints the slices
	from, so displayed odds are the rolled odds.

	Client contract (StarterGui.Main owns ALL the UI, per the house rule):
	- SpinRequest:FireServer()      spend one banked spin
	- SpinAck:FireClient(player, kind, data) answers the caller only:
	    "SPUN"    { index, reward = REWARDS[index], revolutions, jitter,
	                duration, spins, money, isNew, consolation (bull slice),
	                bullId/bullName/rarity/isNew/refund (box "lucky block" slice);
	                for a Store Lucky Block also rewards = the tier's full 6-slice
	                table + luckyTier = "SECRET"|"ALIEN"|"GOD" so the client
	                repaints the wheel to that tier for the one reveal }
	    "GRANTED" { granted, spins }   (a Robux spin purchase landed)
	    "DENIED"  { reason = "NO_SPINS" | "DATA_NOT_LOADED" }
	- SpinStarted:FireAllClients(payload) - same index/revolutions/jitter/
	  duration as the ack; FortuneWheelClient replays it on the lobby wheel
	  model so everyone sees the physical wheel spin.

	The wheel animation is server-committed: revolutions + jitter (where in
	the slice the arrow rests) are rolled here and shipped in both events,
	so the UI wheel and the lobby wheel land on the same frame.

	Spin counts replicate as player attributes (Spins, NextFreeSpin - unix
	time the next free spin banks) so the UI needs no fetch remote.

	Grants are RAW (no friend boost / mode multiplier): wheel prizes aren't
	round earnings - same reasoning as BullRollService's dupe refunds.
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

local REQUEST_GAP = 1 -- silent spam guard; the client paces itself anyway
local ACCRUAL_TICK = 30 -- how often the free-spin clock is checked

local SpinService = {}

local rng = Random.new()
local lastRequestAt: { [Player]: number } = {}

-- Same ensure-on-require pattern as BullRollService: the Remotes folder is
-- built in edit mode, so places that predate the wheel still get the remotes.
local function ensureRemote(name: string): RemoteEvent
	local remote = Remotes:FindFirstChild(name)
	if not (remote and remote:IsA("RemoteEvent")) then
		remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = Remotes
	end
	return remote
end
local requestRemote = ensureRemote("SpinRequest")
local ackRemote = ensureRemote("SpinAck")
local startedRemote = ensureRemote("SpinStarted")

-- Smoke tests drive this with duck-typed stub players; only real Players can
-- receive remotes (same idiom as BullRollService.ack).
local function ack(player, kind: string, data: { [string]: any })
	if typeof(player) == "Instance" then
		ackRemote:FireClient(player, kind, data)
	end
end

-- Spending a spin both takes and grants, so it needs a profile that exists
-- and loaded cleanly (a DataLoadFailed session would eat spins that
-- evaporate on leave).
local function profileReady(player): boolean
	if typeof(player) == "Instance" and player:GetAttribute("DataLoadFailed") then
		return false
	end
	local ok, spins = pcall(DataHandler.GetStat, player, "Spins")
	return ok and spins ~= nil
end

local function refreshAttributes(player)
	if typeof(player) ~= "Instance" then
		return
	end
	local ok, spins = pcall(DataHandler.GetStat, player, "Spins")
	if ok and spins ~= nil then
		player:SetAttribute("Spins", spins)
	end
	local okLast, lastAt = pcall(DataHandler.GetStat, player, "LastFreeSpin")
	if okLast and lastAt ~= nil then
		player:SetAttribute("NextFreeSpin", lastAt + Config.SPINNER.FREE_SPIN_INTERVAL)
	end
end

-- Banks the free spin when the interval has elapsed. One per accrual: the
-- clock restarts at NOW (not lastAt + interval), so offline time past one
-- interval doesn't stack spins.
local function accrueFreeSpin(player)
	if not profileReady(player) then
		return
	end
	local lastAt = DataHandler.GetStat(player, "LastFreeSpin") or 0
	if os.time() - lastAt >= Config.SPINNER.FREE_SPIN_INTERVAL then
		DataHandler.SetStat(player, "Spins", (DataHandler.GetStat(player, "Spins") or 0) + 1)
		DataHandler.SetStat(player, "LastFreeSpin", os.time())
		refreshAttributes(player)
		if typeof(player) == "Instance" then
			NotifyService.send(player, "Free spin ready!", "green", 4)
		end
	end
end

-- VIP pass perk: one EXTRA spin banks every VIP_SPIN_INTERVAL (a day), on its
-- own LastVipSpin clock so it's independent of the free-for-everyone spin above.
-- Same "clock restarts at NOW" rule (offline days don't stack). Non-VIP players
-- and stubs (no IsVIP attribute) are skipped, so nothing accrues for them.
local function accrueVipSpin(player)
	if typeof(player) ~= "Instance" or not player:GetAttribute("IsVIP") then
		return
	end
	if not profileReady(player) then
		return
	end
	local lastAt = DataHandler.GetStat(player, "LastVipSpin") or 0
	if os.time() - lastAt >= Config.SPINNER.VIP_SPIN_INTERVAL then
		DataHandler.SetStat(player, "Spins", (DataHandler.GetStat(player, "Spins") or 0) + 1)
		DataHandler.SetStat(player, "LastVipSpin", os.time())
		refreshAttributes(player)
		NotifyService.send(player, "VIP spin ready!", "green", 4)
	end
end

--==============================================================================
-- Rolling
--==============================================================================

-- Weighted pick over a reward table (defaults to the free wheel's); returns the
-- slice index the arrow must land on. A Lucky Block passes its own richer table.
-- Weights are authored to sum to 100 but any total works.
local function rollSlice(rewards): number
	rewards = rewards or Config.SPINNER.REWARDS
	local total = 0
	for _, reward in rewards do
		total += reward.weight
	end
	local pick = rng:NextNumber() * total
	for index, reward in rewards do
		pick -= reward.weight
		if pick <= 0 then
			return index
		end
	end
	return #rewards -- float dust at the top of the range
end

-- Opens one Config.BULLS.BOXES box as a free roll (the "lucky block" slice):
-- adds the bull if new (EPIC/LEGENDARY broadcast), else refunds
-- box.cost * dupeRefund Money - same economics as a bought box, minus the cost.
local function grantBox(player, boxId: string): { [string]: any }
	local box = Config.BULLS.BOXES[boxId]
	if not box then -- misconfigured slice: fall back to any box so a spin never dead-ends
		boxId, box = next(Config.BULLS.BOXES)
	end
	local bullId = BullCatalog.roll(rng, box.weights)
	local bull = BullCatalog.get(bullId) :: BullCatalog.Bull
	local isNew = not DataHandler.HasBull(player, bullId)
	local refund = 0
	if isNew then
		DataHandler.AddBull(player, bullId)
		if typeof(player) == "Instance" then
			local ok, bulls = pcall(DataHandler.GetStat, player, "Bulls")
			if ok and bulls then
				player:SetAttribute("Bulls", HttpService:JSONEncode(bulls))
			end
			if bull.rarity == "EPIC" or bull.rarity == "LEGENDARY" then
				NotifyService.broadcast(
					("%s won %s from a lucky block!"):format(player.DisplayName, bull.name:upper()), "green", 5)
			end
		end
	else
		refund = math.floor(box.cost * BullCatalog.Rarities[bull.rarity].dupeRefund)
		DataHandler.SetStat(player, "Money", (DataHandler.GetStat(player, "Money") or 0) + refund)
	end
	return { boxId = boxId, bullId = bullId, bullName = bull.name, rarity = bull.rarity, isNew = isNew, refund = refund }
end

-- Applies rewards[index] to the profile (defaults to the free wheel's table; a
-- Lucky Block passes its own). Returns a table of reward-specific ack fields
-- (bull isNew/consolation, box roll bullId/rarity/isNew/refund, ...) that the
-- caller merges into the SPUN payload for the client's reveal.
local function grantReward(player, index: number, rewards): { [string]: any }
	rewards = rewards or Config.SPINNER.REWARDS
	local reward = rewards[index]
	if reward.kind == "money" then
		DataHandler.SetStat(player, "Money", (DataHandler.GetStat(player, "Money") or 0) + reward.amount)
		return {}
	elseif reward.kind == "spin" then
		DataHandler.SetStat(player, "Spins", (DataHandler.GetStat(player, "Spins") or 0) + reward.amount)
		return {}
	elseif reward.kind == "box" then
		return grantBox(player, reward.boxId)
	elseif reward.kind == "bull" then
		local isNew = not DataHandler.HasBull(player, reward.bullId)
		if isNew then
			DataHandler.AddBull(player, reward.bullId)
			if typeof(player) == "Instance" then
				local ok, bulls = pcall(DataHandler.GetStat, player, "Bulls")
				if ok and bulls then
					player:SetAttribute("Bulls", HttpService:JSONEncode(bulls))
				end
				local bull = BullCatalog.get(reward.bullId)
				NotifyService.broadcast(
					("%s won %s on the wheel!"):format(player.DisplayName, (bull and bull.name or reward.bullId):upper()),
					"green", 5)
			end
			return { isNew = true }
		end
		local consolation = reward.consolation or 0
		DataHandler.SetStat(player, "Money", (DataHandler.GetStat(player, "Money") or 0) + consolation)
		return { isNew = false, consolation = consolation }
	end
	return {}
end

-- Public (not just the remote's target) so smoke tests can call it directly.
function SpinService.requestSpin(player)
	local now = os.clock()
	if now - (lastRequestAt[player] or 0) < REQUEST_GAP then
		return
	end
	lastRequestAt[player] = now

	if not profileReady(player) then
		ack(player, "DENIED", { reason = "DATA_NOT_LOADED" })
		return
	end
	accrueFreeSpin(player) -- a click right as the timer laps still counts
	local spins = DataHandler.GetStat(player, "Spins") or 0
	if spins < 1 then
		ack(player, "DENIED", { reason = "NO_SPINS" })
		return
	end
	DataHandler.SetStat(player, "Spins", spins - 1)

	local index = rollSlice()
	local extra = grantReward(player, index)
	refreshAttributes(player)

	-- Commit the whole animation server-side so the UI wheel and the lobby
	-- wheel model land identically: full extra turns + where in the 60-degree
	-- slice the arrow rests (+-20 keeps it clear of the slice edges).
	local payload = {
		index = index,
		reward = Config.SPINNER.REWARDS[index],
		revolutions = rng:NextInteger(4, 5),
		jitter = rng:NextNumber(-20, 20),
		duration = Config.SPINNER.SPIN_DURATION,
	}
	for key, value in extra do -- bull isNew/consolation, or box bullId/rarity/isNew/refund
		payload[key] = value
	end
	payload.spins = DataHandler.GetStat(player, "Spins")
	payload.money = DataHandler.GetStat(player, "Money")

	ack(player, "SPUN", payload)
	startedRemote:FireAllClients({
		index = index,
		revolutions = payload.revolutions,
		jitter = payload.jitter,
		duration = payload.duration,
	})
	return payload -- smoke tests assert on this
end

-- Premium "Lucky Block" spin: rolls tierId's OWN richer reward table
-- (Config.LUCKY_BLOCKS) and pushes a PRIVATE wheel spin to the buyer - the
-- SPUN payload carries the tier's full REWARDS so the client repaints the 6
-- slices for the reveal, then restores the free wheel. No SpinStarted
-- broadcast: the physical lobby wheel stays on the free table (only the
-- buyer's Spinner window animates). Returns true on a completed grant so the
-- product receipt can resolve; false leaves the receipt for Roblox to retry.
function SpinService.spinLuckyBlock(player, tierId: string): boolean
	local tier = Config.LUCKY_BLOCKS and Config.LUCKY_BLOCKS[tierId]
	if not tier then
		-- Misconfigured product mapping: don't eat the Robux, let it retry.
		return false
	end
	if not profileReady(player) then
		return false
	end

	local rewards = tier.REWARDS
	local index = rollSlice(rewards)
	local extra = grantReward(player, index, rewards)
	refreshAttributes(player)

	local payload = {
		index = index,
		reward = rewards[index],
		rewards = rewards, -- client repaints the dial to this tier for the reveal
		luckyTier = tierId,
		revolutions = rng:NextInteger(4, 5),
		jitter = rng:NextNumber(-20, 20),
		duration = Config.SPINNER.SPIN_DURATION,
	}
	for key, value in extra do -- bull isNew/consolation, or box bullId/rarity/isNew/refund
		payload[key] = value
	end
	payload.spins = DataHandler.GetStat(player, "Spins")
	payload.money = DataHandler.GetStat(player, "Money")

	ack(player, "SPUN", payload)
	return true
end

--==============================================================================
-- Robux spin products + free-spin clock
--==============================================================================

function SpinService.init()
	local function makeHandler(count: number)
		return function(receipt, player)
			if not player or not profileReady(player) then
				-- Buyer left / data can't save: let Roblox retry the receipt
				-- rather than eat the Robux (same as BullRollService).
				return Enum.ProductPurchaseDecision.NotProcessedYet
			end
			DataHandler.SetStat(player, "Spins", (DataHandler.GetStat(player, "Spins") or 0) + count)
			refreshAttributes(player)
			ack(player, "GRANTED", { granted = count, spins = DataHandler.GetStat(player, "Spins") })
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end
	end
	MonetizationService.registerProduct(Config.PRODUCTS.SPIN_1, makeHandler(1))
	MonetizationService.registerProduct(Config.PRODUCTS.SPIN_10, makeHandler(10))

	-- Lucky Blocks (Store): each product opens its tier's richer wheel spin.
	for tierId, tier in Config.LUCKY_BLOCKS or {} do
		local productId = Config.PRODUCTS[tier.product]
		MonetizationService.registerProduct(productId, function(_receipt, player)
			if not player then
				return Enum.ProductPurchaseDecision.NotProcessedYet
			end
			if SpinService.spinLuckyBlock(player, tierId) then
				return Enum.ProductPurchaseDecision.PurchaseGranted
			end
			-- data not loaded / misconfigured: retry rather than eat the Robux
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end)
	end

	-- Free-spin clock: lazy sweep, so the "Free spin ready" flip happens
	-- while playing, not just on rejoin. Profiles load async, so the same
	-- sweep doubles as the on-join accrual + attribute seed.
	task.spawn(function()
		while true do
			for _, player in Players:GetPlayers() do
				if profileReady(player) then
					if player:GetAttribute("Spins") == nil then
						refreshAttributes(player) -- first sight after profile load
					end
					accrueFreeSpin(player)
					accrueVipSpin(player)
				end
			end
			task.wait(ACCRUAL_TICK)
		end
	end)
end

requestRemote.OnServerEvent:Connect(function(player)
	SpinService.requestSpin(player)
end)

Players.PlayerRemoving:Connect(function(player)
	lastRequestAt[player] = nil
end)

return SpinService
