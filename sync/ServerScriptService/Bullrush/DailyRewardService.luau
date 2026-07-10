--[[
	DailyRewardService - the daily login reward backend (Frames.Daily UI + the
	"Gifts" HUD button).

	A 7-day escalating loop (Config.DAILY.REWARDS, indexed by day 1-7). The day
	to claim next is DailyStreak % 7 + 1, so after claiming day 7 the loop wraps
	back to day 1. Two profile fields drive everything:
	  DailyStreak    consecutive days claimed
	  LastDailyClaim unix time of the last claim (0 = never; first claim is
	                 ready immediately)
	Timing (both from Config.DAILY):
	  CLAIM_COOLDOWN a reward is only ready this long after the last claim
	  RESET_WINDOW   claim within this of the last claim to keep the streak; let
	                 it lapse and the next claim restarts at day 1 (the grace
	                 period past the cooldown, so one busy day won't punish you)

	Rewards are granted RAW (a gift, not round earnings - no friend boost / mode
	multiplier), same reasoning as SpinService's wheel prizes and BullRollService's
	dupe refunds. Reward kinds: money, spin (banks fortune-wheel spins), box
	(opens one Config.BULLS.BOXES box = a free bull roll; a duplicate pull
	refunds box.cost * rarity.dupeRefund Money, exactly like a bought box).

	Client contract (StarterGui.Main owns ALL the UI, per the house rule):
	- DailyRequest:FireServer()      claim the day that's ready
	- DailyAck:FireClient(player, kind, data) answers the caller only:
	    "CLAIMED" { day, streak, reward = Config.DAILY.REWARDS[day], money,
	                nextClaim, -- plus for a box reward: bullId, rarity, isNew, refund
	                spins }    -- current banked spins (spin/box rewards touch this)
	    "CLAIMED_ALL" { rewards = { {day, reward, +box fields}... }, streak,
	                money, spins, nextClaim } -- the DAILY_CLAIM_ALL Robux product
	    "DENIED"  { reason = "COOLDOWN" (+ nextClaim) | "DATA_NOT_LOADED" }

	The "Claim all" button prompts the Config.PRODUCTS.DAILY_CLAIM_ALL dev
	product (client-side, like every other Robux prompt); the receipt lands in
	MonetizationService and calls grantClaimAll, which banks all 7 days at once.

	State replicates as player attributes (no fetch remote, same as SpinService):
	  DailyStreak     consecutive claims
	  DailyDay        the day (1-7) that will be claimed next
	  DailyReady      bool - is a claim available right now
	  NextDailyClaim  unix time the next reward becomes ready (0 when ready now)
	The lazy sweep flips DailyReady while the player is in-game and re-computes
	DailyDay if the streak lapsed offline.
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

local REQUEST_GAP = 0.5 -- silent spam guard; the client paces itself anyway
local SWEEP_TICK = 30 -- how often DailyReady is re-checked while in-game
local DAYS = 7 -- the loop length; Config.DAILY.REWARDS is authored 1..DAYS

local DailyRewardService = {}

local rng = Random.new()
local lastRequestAt: { [Player]: number } = {}

-- Ensure the remotes for places that predate the daily system (same pattern as
-- SpinService / BullRollService; the Remotes folder is built in edit mode).
local function ensureRemote(name: string): RemoteEvent
	local remote = Remotes:FindFirstChild(name)
	if not (remote and remote:IsA("RemoteEvent")) then
		remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = Remotes
	end
	return remote
end
local requestRemote = ensureRemote("DailyRequest")
local ackRemote = ensureRemote("DailyAck")

-- Smoke tests may drive this with duck-typed stub players; only real Players
-- can receive remote acks (same idiom as SpinService.ack).
local function ack(player, kind: string, data: { [string]: any })
	if typeof(player) == "Instance" then
		ackRemote:FireClient(player, kind, data)
	end
end

-- A claim both reads and saves, so it needs a profile that (a) exists and (b)
-- loaded cleanly - a DataLoadFailed session would hand out rewards that
-- evaporate on leave (same guard as SpinService / BullRollService).
local function profileReady(player): boolean
	if typeof(player) == "Instance" and player:GetAttribute("DataLoadFailed") then
		return false
	end
	local ok, streak = pcall(DataHandler.GetStat, player, "DailyStreak")
	return ok and streak ~= nil
end

--==============================================================================
-- Claim state (pure - unit-testable without a live player)
--==============================================================================

export type ClaimStatus = {
	ready: boolean,   -- is a reward claimable right now
	day: number,      -- the day (1-DAYS) that a claim would grant
	streak: number,   -- streak BEFORE this claim (day = streak % DAYS + 1)
	nextClaim: number, -- unix time the reward becomes ready (0 when ready now)
}

-- Given the saved streak + last-claim time, what can the player claim now?
-- Never claimed -> day 1, ready. On cooldown -> the continuing day, not ready.
-- Past cooldown but within the grace window -> the continuing day, ready. Past
-- the grace window -> streak lapsed, so the next claim restarts at day 1.
local function claimStatus(streak: number, lastClaim: number, now: number): ClaimStatus
	if lastClaim <= 0 then
		return { ready = true, day = 1, streak = 0, nextClaim = 0 }
	end
	local elapsed = now - lastClaim
	local continuingDay = streak % DAYS + 1
	if elapsed < Config.DAILY.CLAIM_COOLDOWN then
		return { ready = false, day = continuingDay, streak = streak, nextClaim = lastClaim + Config.DAILY.CLAIM_COOLDOWN }
	elseif elapsed < Config.DAILY.RESET_WINDOW then
		return { ready = true, day = continuingDay, streak = streak, nextClaim = 0 }
	else
		return { ready = true, day = 1, streak = 0, nextClaim = 0 } -- grace lapsed
	end
end
DailyRewardService._claimStatus = claimStatus -- exposed for smoke tests

local function refreshAttributes(player)
	if typeof(player) ~= "Instance" then
		return
	end
	local ok, streak = pcall(DataHandler.GetStat, player, "DailyStreak")
	local okLast, lastClaim = pcall(DataHandler.GetStat, player, "LastDailyClaim")
	if not (ok and streak ~= nil and okLast and lastClaim ~= nil) then
		return
	end
	local status = claimStatus(streak, lastClaim, os.time())
	player:SetAttribute("DailyStreak", streak)
	player:SetAttribute("DailyDay", status.day)
	player:SetAttribute("DailyReady", status.ready)
	player:SetAttribute("NextDailyClaim", status.nextClaim)
end

--==============================================================================
-- Granting
--==============================================================================

-- Opens one Config.BULLS.BOXES box as a free roll: adds the bull if new (with
-- an EPIC/LEGENDARY broadcast), else refunds box.cost * dupeRefund Money - the
-- same economics as a bought box, minus the cost. Returns the ack fields.
local function grantBox(player, boxId: string): { [string]: any }
	local box = Config.BULLS.BOXES[boxId]
	if not box then -- misconfigured reward: fall back to any box so a claim never dead-ends
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
					("%s pulled %s from a daily reward!"):format(player.DisplayName, bull.name:upper()), "green", 5)
			end
		end
	else
		refund = math.floor(box.cost * BullCatalog.Rarities[bull.rarity].dupeRefund)
		DataHandler.SetStat(player, "Money", (DataHandler.GetStat(player, "Money") or 0) + refund)
	end
	return { boxId = boxId, bullId = bullId, rarity = bull.rarity, isNew = isNew, refund = refund }
end

-- Applies Config.DAILY.REWARDS[day] to the profile and returns the reward-
-- specific ack fields (a box roll's bull, a new spin/money balance, ...).
local function grantReward(player, day: number): { [string]: any }
	local reward = Config.DAILY.REWARDS[day]
	local extra: { [string]: any } = {}
	if reward.kind == "money" then
		DataHandler.SetStat(player, "Money", (DataHandler.GetStat(player, "Money") or 0) + reward.amount)
	elseif reward.kind == "spin" then
		DataHandler.SetStat(player, "Spins", (DataHandler.GetStat(player, "Spins") or 0) + reward.amount)
		if typeof(player) == "Instance" then
			player:SetAttribute("Spins", DataHandler.GetStat(player, "Spins")) -- keep the wheel UI in sync
		end
	elseif reward.kind == "box" then
		extra = grantBox(player, reward.boxId)
	end
	return extra
end

-- Public (not just the remote's target) so smoke tests can call it directly.
function DailyRewardService.requestClaim(player)
	local now = os.clock()
	if now - (lastRequestAt[player] or 0) < REQUEST_GAP then
		return
	end
	lastRequestAt[player] = now

	if not profileReady(player) then
		ack(player, "DENIED", { reason = "DATA_NOT_LOADED" })
		return
	end

	local streak = DataHandler.GetStat(player, "DailyStreak") or 0
	local lastClaim = DataHandler.GetStat(player, "LastDailyClaim") or 0
	local status = claimStatus(streak, lastClaim, os.time())
	if not status.ready then
		ack(player, "DENIED", { reason = "COOLDOWN", nextClaim = status.nextClaim })
		return
	end

	local day = status.day
	local extra = grantReward(player, day)

	-- Commit the new streak + claim time BEFORE refreshing attributes so the
	-- replicated state matches the profile.
	local newStreak = status.streak + 1
	DataHandler.SetStat(player, "DailyStreak", newStreak)
	DataHandler.SetStat(player, "LastDailyClaim", os.time())
	refreshAttributes(player)

	local payload: { [string]: any } = {
		day = day,
		streak = newStreak,
		reward = Config.DAILY.REWARDS[day],
		money = DataHandler.GetStat(player, "Money"),
		spins = DataHandler.GetStat(player, "Spins"),
		nextClaim = os.time() + Config.DAILY.CLAIM_COOLDOWN,
	}
	for key, value in extra do -- box rewards add bullId/rarity/isNew/refund
		payload[key] = value
	end
	ack(player, "CLAIMED", payload)
	return payload -- smoke tests assert on this
end

--==============================================================================
-- "Claim all" dev product (DAILY_CLAIM_ALL): pay Robux to bank the whole 7-day
-- loop at once, skipping every cooldown. Registered with MonetizationService.
--==============================================================================

-- Grants every day (1..DAYS) of the loop in one shot and rolls the streak up to
-- the next loop boundary, so the player's next FREE claim starts clean at day 1
-- on a fresh cooldown (LastDailyClaim = now). Returns the aggregated ack
-- payload, or nil if the profile can't safely take a grant (buyer left / data
-- not loaded) so the receipt handler can defer the receipt.
function DailyRewardService.grantClaimAll(player): { [string]: any }?
	if not profileReady(player) then
		return nil
	end

	local rewards = {} -- one entry per day, in loop order, for the client reveal
	for day = 1, DAYS do
		local entry: { [string]: any } = { day = day, reward = Config.DAILY.REWARDS[day] }
		for key, value in grantReward(player, day) do -- box days add bullId/rarity/isNew/refund
			entry[key] = value
		end
		table.insert(rewards, entry)
	end

	-- Land the streak on a loop boundary (multiple of DAYS) so DailyDay resets to
	-- 1 next, and stamp the claim time so the normal cooldown resumes from now.
	local streak = DataHandler.GetStat(player, "DailyStreak") or 0
	local newStreak = math.ceil((streak + 1) / DAYS) * DAYS
	DataHandler.SetStat(player, "DailyStreak", newStreak)
	DataHandler.SetStat(player, "LastDailyClaim", os.time())
	refreshAttributes(player)

	local payload: { [string]: any } = {
		rewards = rewards,
		streak = newStreak,
		money = DataHandler.GetStat(player, "Money"),
		spins = DataHandler.GetStat(player, "Spins"),
		nextClaim = os.time() + Config.DAILY.CLAIM_COOLDOWN,
	}
	ack(player, "CLAIMED_ALL", payload)
	if typeof(player) == "Instance" then
		NotifyService.send(player, ("Claimed all %d daily rewards!"):format(DAYS), "green", 5)
	end
	return payload -- smoke tests assert on this
end

--==============================================================================
-- Ready clock: lazy sweep, so DailyReady flips (and a lapsed streak re-computes
-- its day) while the player is in-game, not only on rejoin.
--==============================================================================

function DailyRewardService.init()
	-- "Claim all" Robux product: grant the full loop, or defer the receipt if
	-- the buyer's data isn't safely writable (Roblox retries, then refunds).
	MonetizationService.registerProduct(Config.PRODUCTS.DAILY_CLAIM_ALL, function(_receipt, player)
		if not player or not DailyRewardService.grantClaimAll(player) then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end)

	-- Prompt per-join seed: the client auto-opens the window on join when a
	-- reward is ready, so the attributes must be set as soon as the profile
	-- loads - not up to SWEEP_TICK later. Polls until the profile is ready (it
	-- loads async), then seeds once; the sweep below still handles mid-session
	-- flips and any player this misses.
	Players.PlayerAdded:Connect(function(player)
		task.spawn(function()
			for _ = 1, 60 do
				if player.Parent == nil then
					return
				end
				if profileReady(player) then
					refreshAttributes(player)
					return
				end
				task.wait(1)
			end
		end)
	end)

	task.spawn(function()
		while true do
			for _, player in Players:GetPlayers() do
				if profileReady(player) then
					refreshAttributes(player) -- seeds on first sight, then flips DailyReady
				end
			end
			task.wait(SWEEP_TICK)
		end
	end)
end

requestRemote.OnServerEvent:Connect(function(player)
	DailyRewardService.requestClaim(player)
end)

Players.PlayerRemoving:Connect(function(player)
	lastRequestAt[player] = nil
end)

return DailyRewardService
