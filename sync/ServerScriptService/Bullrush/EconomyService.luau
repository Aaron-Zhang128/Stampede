--[[
	EconomyService - SCAFFOLD. The round-ledger / Summary-tab economy feature
	is in-flight (its call sites were merged into Main/RoundService/
	RevengeService before this module existed, which killed every server
	script at require time and stopped rounds from starting). This stub
	restores the exact interface those call sites use, as no-ops, so the game
	runs with pre-economy behavior. Replace the bodies with the real ledger.

	Interface (from the call sites):
	- init(awardMoney)                      Main, once at boot
	- roundStarted(participants, mode)      Main, after RoundService.startRound
	- noteStageSurvived(aliveList)          Main, after each shrink stage
	- noteWin(player, paid)                 Main, per winner payout
	- noteRevenge(thrower, paid)            RevengeService, per revenge payout
	- noteElimination(player, remaining, aliveList)  RoundService.eliminate
	- settle(summaryWinner)                 Main, at round end
]]

local EconomyService = {}

function EconomyService.init(awardMoney)
end

function EconomyService.roundStarted(participants, mode)
end

function EconomyService.noteStageSurvived(aliveList)
end

function EconomyService.noteWin(player, paid)
end

function EconomyService.noteRevenge(thrower, paid)
end

function EconomyService.noteElimination(player, remaining, aliveList)
end

function EconomyService.settle(summaryWinner)
end

return EconomyService
