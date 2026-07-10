--[[
	EconomyService - the per-round Money ledger (Config.ECONOMY).

	Every REAL participant banks Money for how the round went:
	  Survival      SURVIVAL_MONEY per SURVIVAL_INTERVAL seconds alive
	  Placement     top-3 finish (non-team rounds with enough starters)
	  Final 3       reaching the last 3 alive (same gate as placement)
	  Arena stages  alive through each shrink stage
	  Win streak    STREAK_BONUS x current streak (capped), on top of the
	                flat win pay that awardWinner already grants
	Nothing is paid mid-round except revenge hits (RevengeService pays those
	live and reports them here for display). settle() pays each category
	through the injected awardMoney - one choke point, so the friend boost
	applies and the Summary tab's lines add up to what actually landed -
	scaled by the mode's moneyMult, then fires RoundSummary per participant.

	Round flow (who calls what):
	  Main            init(RoundService.awardMoney), roundStarted(), noteWin(),
	                  noteStageSurvived(), settle()
	  RoundService    noteElimination() from eliminate()
	  RevengeService  noteRevenge() after paying a hit

	"2x Rewards?" (Summary tab button) prompts Config.PRODUCTS.DOUBLE_ROUND;
	ProcessReceipt re-grants the buyer's LAST settled round total once, raw -
	the original payout already carried every multiplier, so paying it again
	is exactly 2x.

	Bots (AIService plain-table proxies) flow through elimination order - so
	real players' placements are correct - but never get a ledger entry.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage.Bullrush.Config)
local Remotes = ReplicatedStorage.Bullrush.Remotes
local DataHandler = require(ServerScriptService.UserData.DataHandler)
local NotifyService = require(script.Parent.NotifyService)
local MonetizationService = require(script.Parent.MonetizationService)

local ECON = Config.ECONOMY

local EconomyService = {}

local awardMoney: (Player, number) -> number -- injected (RoundService.awardMoney)

local active = false
local roundStart = 0
local moneyMult = 1
local startCount = 0
local isTeams = false

type Entry = {
	placement: number,
	survivalSeconds: number,
	eliminated: boolean,
	stage: number,
	last3: number,
	streakBonus: number,
	winPaid: number,
	revengePaid: number,
}
local ledger: { [Player]: Entry } = {}

-- Last settled round per user, kept so a 2x purchase can land after the
-- round is over (receipts may arrive minutes late).
local lastSettled: { [number]: { total: number, doubled: boolean } } = {}

local function isRealPlayer(player): boolean
	return typeof(player) == "Instance"
end

local function safeData(fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		warn("Bullrush: DataHandler call failed:", err)
	end
end

--==============================================================================
-- Round lifecycle
--==============================================================================

function EconomyService.roundStarted(participants: { Player }, mode)
	table.clear(ledger)
	active = true
	roundStart = os.clock()
	moneyMult = mode.moneyMult or 1
	isTeams = mode.teams == true
	startCount = #participants
	for _, player in participants do
		if isRealPlayer(player) then
			ledger[player] = {
				placement = 1, -- overwritten on elimination; survivors finish 1st
				survivalSeconds = 0,
				eliminated = false,
				stage = 0,
				last3 = 0,
				streakBonus = 0,
				winPaid = 0,
				revengePaid = 0,
			}
		end
	end
end

-- From RoundService.eliminate: `remaining` is the alive count AFTER this
-- elimination, so the victim placed remaining + 1 (bots included in the
-- order - beating a bot is still beating an opponent).
function EconomyService.noteElimination(player: Player, remaining: number, aliveList: { Player })
	if not active then
		return
	end
	local entry = ledger[player]
	if entry and not entry.eliminated then
		entry.eliminated = true
		entry.survivalSeconds = os.clock() - roundStart
		entry.placement = remaining + 1
	end
	-- The final-3 moment: everyone still standing banks the bonus (the
	-- eventual winner included). Needs a real lobby, like placement pay.
	if remaining == 3 and not isTeams and startCount >= ECON.PLACEMENT_MIN_STARTERS then
		for _, alive in aliveList do
			local aliveEntry = ledger[alive]
			if aliveEntry then
				aliveEntry.last3 = ECON.LAST3_BONUS
			end
		end
	end
end

-- After each completed shrink stage: everyone who lived through it earns.
function EconomyService.noteStageSurvived(aliveList: { Player })
	if not active then
		return
	end
	for _, player in aliveList do
		local entry = ledger[player]
		if entry then
			entry.stage += ECON.STAGE_BONUS
		end
	end
end

-- After awardWinner pays the flat win: record it for the summary and bank
-- the streak bonus (streak was just incremented, so a first win pays 1x).
function EconomyService.noteWin(player: Player, paidFlat: number)
	local entry = ledger[player]
	if not entry then
		return
	end
	entry.winPaid += paidFlat
	local streak = 0
	safeData(function()
		streak = DataHandler.GetStat(player, "Streak") or 0
	end)
	entry.streakBonus = math.min(streak * ECON.STREAK_BONUS, ECON.STREAK_BONUS_CAP)
end

-- RevengeService already paid this; recorded so the summary can show it.
function EconomyService.noteRevenge(player: Player, paid: number)
	local entry = ledger[player]
	if entry then
		entry.revengePaid += paid
	end
end

-- Pays every ledger and mails each participant their Summary-tab payload.
-- winnerInfo: { winnerName: string?, winnerUserId: number?, teamColor: ("RED"|"BLUE")? }
function EconomyService.settle(winnerInfo: { [string]: any })
	if not active then
		return
	end
	active = false
	local roundEnd = os.clock()

	for player, entry in ledger do
		if not entry.eliminated then
			entry.survivalSeconds = roundEnd - roundStart
		end

		local lines = {}
		local total = 0
		-- Pay one category: mode multiplier here, friend boost inside
		-- awardMoney; the line records what actually landed.
		local function pay(label: string, raw: number)
			if raw <= 0 then
				return
			end
			local paid = awardMoney(player, raw * moneyMult)
			if paid > 0 then
				table.insert(lines, { label = label, amount = paid })
				total += paid
			end
		end

		if entry.winPaid > 0 then -- already paid flat by awardWinner
			table.insert(lines, { label = "Victory", amount = entry.winPaid })
			total += entry.winPaid
		end
		pay("Win streak", entry.streakBonus)
		if not isTeams and startCount >= ECON.PLACEMENT_MIN_STARTERS then
			pay("Placement", ECON.PLACEMENT[entry.placement] or 0)
		end
		pay("Final 3", entry.last3)
		pay("Arena stages", entry.stage)
		pay("Survival",
			math.floor(entry.survivalSeconds / ECON.SURVIVAL_INTERVAL) * ECON.SURVIVAL_MONEY)
		if entry.revengePaid > 0 then -- already paid live by RevengeService
			table.insert(lines, { label = "Revenge bulls", amount = entry.revengePaid })
			total += entry.revengePaid
		end

		if player.Parent then
			lastSettled[player.UserId] = { total = total, doubled = false }
			Remotes.RoundSummary:FireClient(player, {
				winnerName = winnerInfo.winnerName,
				winnerUserId = winnerInfo.winnerUserId,
				teamColor = winnerInfo.teamColor,
				placement = entry.placement,
				survivalSeconds = math.floor(entry.survivalSeconds + 0.5),
				lines = lines,
				total = total,
				canDouble = total > 0,
			})
		end
	end
end

--==============================================================================
-- "2x Rewards?" dev product (DOUBLE_ROUND)
--==============================================================================

-- MonetizationService owns the game's single ProcessReceipt; we hand it this
-- one handler for DOUBLE_ROUND and it dispatches the receipt to us. Grants the
-- buyer their last settled round total again, once.
local function grantDoubleRound(receipt, player: Player?): Enum.ProductPurchaseDecision
	local record = lastSettled[receipt.PlayerId]
	if not player or not record or record.doubled or record.total <= 0 then
		-- Nothing to double (left the server / already doubled / empty round):
		-- let Roblox retry, and eventually refund, rather than eat the Robux.
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	record.doubled = true
	-- Raw grant, NOT awardMoney: the settled total already includes the mode
	-- multiplier and friend boost, so re-adding it is exactly a 2x.
	safeData(function()
		DataHandler.SetStat(player, "Money",
			(DataHandler.GetStat(player, "Money") or 0) + record.total)
	end)
	NotifyService.send(player, ("2x REWARDS! +%d Money"):format(record.total), "green", 5)
	Remotes.RoundSummary:FireClient(player, {
		update = true, -- client: refresh the coins line, hide the 2x button
		total = record.total * 2,
		canDouble = false,
	})
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

function EconomyService.init(awardMoneyFn: (Player, number) -> number)
	awardMoney = awardMoneyFn
	MonetizationService.registerProduct(Config.PRODUCTS.DOUBLE_ROUND, grantDoubleRound)
end

Players.PlayerRemoving:Connect(function(player)
	lastSettled[player.UserId] = nil
end)

return EconomyService
