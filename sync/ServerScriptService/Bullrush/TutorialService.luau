--[[
	TutorialService - server-authoritative first-session tutorial.

	TWO guided beats for brand-new players, BOTH carried on TutorialStep 2 (so
	DONE stays 3 and no save renumbers): first CLAIM the FREE starter ability from
	the lobby ability shop's pinned slot-1 card, then PLAY A ROUND and die once
	while owning it. Which beat the client shows is derived purely from whether
	the starter ability is owned (the Owns_<starter> attribute the claim sets):
	not owned -> the "claim" halo on the shop card; owned -> a lobby "Play a game
	using ability 0/1" objective. (The old bull-send step - TutorialStep 1 - was
	REMOVED 2026-07-15.) Progress lives in the profile as TutorialStep (0 = not
	started, 2 = the two-beat tour, 3 = done) and mirrors to the same-named player
	attribute; the client overlay (StarterGui.Main section 18) is purely reactive
	and never talks back - both transitions are observed at their server-side
	source (owning the starter ability flips the client onto the play beat; a
	RoundService elimination while owning it completes the tour + pays the gift),
	so they can't be spoofed and no tutorial remotes exist.

	Start trigger: joining while a round is ACTIVE and young (wave <=
	JOIN_WAVE_CUTOFF) starts it immediately; everyone else starts on their FIRST
	elimination, whenever that lands (a player who wins game one starts when they
	die in game two). The tutorial never blocks play: while the player is alive
	in a round the overlay hides on its own (InRound).

	The claim beat has a persistent proof (owning the starter ability) that the
	play beat does not, so owning it no longer auto-COMPLETES the tour - it just
	moves the player onto the play beat; only a real in-round death finishes.
	Completion pays a one-time RAW money gift (no friend/VIP multipliers, no XP -
	the LevelService gift rule), exactly once, because crossing into DONE persists.

	Old saves never see any of this: Data.server grandfathers a missing
	TutorialStep key straight to DONE on load, and load-failed sessions
	(temp profiles) are refused so a veteran is never re-taught.
]]

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local Config = require(ReplicatedStorage.Bullrush.Config)
local DataHandler = require(ServerScriptService.UserData.DataHandler)

-- The ability first-timers claim FREE in step 2 (AbilityShopService pins it to the
-- shop's slot 1). Owning it is the persistent proof step 2 is done.
local STARTER_ABILITY = Config.ABILITY_SHOP.STARTER_FREE

-- Tutorial funnel logger (optional). Loaded defensively like in Main.server /
-- Data.server: a missing/broken Analytics module must never disrupt a throw, a
-- roll, or a data write, so guard every call with `if Analytics`.
local Analytics do
	local mod = ServerScriptService:FindFirstChild("Analytics")
	if mod then
		local ok, m = pcall(require, mod)
		if ok then Analytics = m end
	end
end

-- TUTORIAL TESTING MODE (STUDIO ONLY) --------------------------------------
-- Flip this true to make EVERY join restart the tour as a brand-new
-- first-timer: fresh STARTER-only inventory, one banked free BASIC box, and
-- TutorialStep reset to 0 so the next elimination opens step 2 (a young
-- mid-round join still auto-starts it immediately). Hard-gated to
-- RunService:IsStudio() below, so a stray `true` can NEVER wipe a live
-- player's bulls. TURN OFF before publishing.
local TEST_MODE = false

local DONE = 3
local REWARD = 150 -- completion gift; keep small, the economy is deliberately lean
local JOIN_WAVE_CUTOFF = 2 -- an ACTIVE round at wave <= this is "just started"
local DATA_READY_TIMEOUT = 60

local TutorialService = {}

-- Round snapshot for the join trigger (fed by Main.server's setRoundState).
local roundState = "WAITING"
local roundWave: number? = nil

-- A missing profile (data still loading, player left mid-step) must never
-- break a throw, a roll, or the round loop, so writes stay pcall-guarded.
local function safeData(fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		warn("Bullrush: TutorialService data call failed:", err)
	end
end

local function getStep(player): number
	local ok, step = pcall(DataHandler.GetStat, player, "TutorialStep")
	return if ok then tonumber(step) or 0 else 0
end

local function ownsStarterAbility(profile): boolean
	local owned = if typeof(profile.OwnedAbilities) == "table" then profile.OwnedAbilities else {}
	return STARTER_ABILITY ~= nil and owned[STARTER_ABILITY] == true
end

-- Folds the RETIRED bull-send step (1) into the two-beat tour step (2): the tour
-- no longer teaches throwing, so any legacy step-1 value - a save from before
-- the 2026-07-15 removal, or a resume - resolves straight to step 2. Owning the
-- starter ability is deliberately NOT folded to DONE here anymore: it only proves
-- the CLAIM beat is behind them, so the player resumes on the "play a game" beat
-- (still step 2) and finishes by DYING in a round, not by owning the ability.
local function normalized(_profile, step: number): number
	if step == 1 then
		step = 2 -- retired bull-send step folds into the two-beat tour step
	end
	return step
end

local function setStepUnsafe(player, step: number)
	local profile = DataHandler.Profiles[player.UserId]
	if not profile then
		return
	end
	step = normalized(profile, step)
	local before = tonumber(profile.TutorialStep) or 0
	if step >= DONE and before < DONE then
		step = DONE
		-- One-time completion gift: RAW money through SetStat (leaderstats
		-- must tick) - never RoundService.awardMoney, which would stack
		-- friend/VIP multipliers onto a fixed gift and feed the XP curve. No
		-- "Tutorial finished!" toast here - the client's fading objective card
		-- (Main.client section 18) already announces it, so a notif would double up.
		DataHandler.SetStat(player, "Money",
			(DataHandler.GetStat(player, "Money") or 0) + REWARD)
	end
	DataHandler.SetStat(player, "TutorialStep", step)
	if typeof(player) == "Instance" then
		player:SetAttribute("TutorialStep", step)
		-- Analytics "Tutorial" funnel, now START -> FINISH (the middle
		-- "sent bull" event retired with the bull-send step). The tour opens
		-- straight at the claim step, so onTutorialStart fires on the 0 -> 2
		-- write and onTutorialFinish on 2 -> DONE; each at most once.
		if Analytics then
			if before < 1 and step >= 1 then
				Analytics.onTutorialStart(player)
			end
			if before < DONE and step >= DONE then
				Analytics.onTutorialFinish(player)
			end
		end
	end
end

local function setStep(player, step: number)
	safeData(setStepUnsafe, player, step)
end

--==============================================================================
-- Hooks (one call each from Main.server / RoundService / RevengeService /
-- BullRollService; this module requires none of them back, so no cycles)
--==============================================================================

-- Main.server setRoundState: cache what the join trigger needs.
function TutorialService.onRoundState(state: string, info: any)
	roundState = state
	roundWave = if state == "ACTIVE" and typeof(info) == "table"
		then tonumber(info.wave)
		else nil
end

-- RoundService.eliminate (real players, quits excluded): one hook now drives
-- BOTH ends of the two-beat tour.
--   * An untaught player's FIRST death opens the tour at step 2 (claim beat;
--     the bull-send step 1 was retired 2026-07-15), guiding them to the lobby
--     ability shop once they're back on their feet.
--   * A LATER death, once they already OWN the starter ability (the play beat -
--     "play a game using your ability"), completes the tour and pays the gift.
--     Gating completion on ownership means a death BEFORE claiming (they died
--     again while still shopping) can't skip the claim.
function TutorialService.onEliminated(player)
	if typeof(player) == "Instance" and player:GetAttribute("DataLoadFailed") then
		return -- temp profile: could be a veteran, never re-teach
	end
	local step = getStep(player)
	if step == 0 then
		setStep(player, 2) -- first death opens the claim beat
	elseif step == 2 then
		local profile = DataHandler.Profiles[player.UserId]
		if profile and ownsStarterAbility(profile) then
			setStep(player, DONE) -- play beat done: died in a round owning the ability
		end
	end
end

-- Main.server round-end settlement (called for each SURVIVOR - see the aliveList
-- loop there, NOT all participants): a play-beat player who FINISHED the round
-- WITHOUT dying - won it, or survived to the end - also completes the tour. The
-- "play a game using your ability" beat is satisfied by playing a full round, not
-- specifically by dying, so a winner isn't left stranded on 0/1. Survivors-only
-- is deliberate: an eliminated player who claimed the ability mid-round (from the
-- lobby, while the round they died in was still running) must NOT finish on that
-- round - only on the next one they actually play. Gated on owning the starter,
-- exactly like onEliminated, so a claim-beat player who never claimed isn't
-- completed just by surviving.
function TutorialService.onFinishedRound(player)
	if typeof(player) == "Instance" and player:GetAttribute("DataLoadFailed") then
		return -- temp profile: could be a veteran, never re-teach
	end
	if getStep(player) == 2 then
		local profile = DataHandler.Profiles[player.UserId]
		if profile and ownsStarterAbility(profile) then
			setStep(player, DONE)
		end
	end
end

-- AbilityShopService free-starter claim: claiming no longer FINISHES the tour -
-- it moves the player from the claim beat onto the play beat. The client switches
-- chrome off the Owns_<starter> attribute the grant just set (this hook doesn't
-- touch the step for a mid-tour player), so all this does is advance a player who
-- somehow claimed BEFORE their first death (still at step 0) into the tour rather
-- than leaving them untaught; the tour then completes on their next in-round death.
function TutorialService.onClaimStarter(player)
	if getStep(player) == 0 then
		setStep(player, 2)
	end
end

--==============================================================================
-- Join trigger / resume
--==============================================================================

local function watchJoin(player: Player)
	task.spawn(function()
		-- Data.server flips DataReady once the profile + attributes exist.
		local t0 = os.clock()
		while player.Parent ~= nil
			and player:GetAttribute("DataReady") ~= true
			and os.clock() - t0 < DATA_READY_TIMEOUT do
			task.wait(0.25)
		end
		if player.Parent == nil
			or player:GetAttribute("DataReady") ~= true
			or player:GetAttribute("DataLoadFailed") then
			return
		end
		-- Studio testing mode: wipe this session back to a fresh first-timer so
		-- the tour runs from scratch on every Play. Studio-only (see TEST_MODE).
		if TEST_MODE and RunService:IsStudio() then
			safeData(function()
				local profile = DataHandler.Profiles[player.UserId]
				if not profile then
					return
				end
				profile.Bulls = { STARTER = true }
				profile.EquippedBull = "STARTER"
				profile.FreeBoxRolls = { BASIC = 1 }
				DataHandler.SetStat(player, "TutorialStep", 0)
				DataHandler.SetStat(player, "WheelSpun", false) -- re-arm the dragon first-spin near-miss
				player:SetAttribute("Bulls", HttpService:JSONEncode(profile.Bulls))
				player:SetAttribute("FreeBoxRolls", HttpService:JSONEncode(profile.FreeBoxRolls))
				player:SetAttribute("EquippedBull", "STARTER")
				player:SetAttribute("TutorialStep", 0)
			end)
		end
		local step = getStep(player)
		if step == 0 then
			-- Joined mid-round, early enough to matter? A young-round spectator is
			-- in the lobby-shop flow just like a fresh joiner, so open the claim
			-- step (step 2; the bull-send step 1 was retired 2026-07-15).
			if roundState == "ACTIVE"
				and (roundWave or math.huge) <= JOIN_WAVE_CUTOFF
				and player:GetAttribute("InRound") ~= true then
				setStep(player, 2)
			end
			-- Otherwise stay untaught: their first elimination starts it.
		elseif step < DONE then
			-- Resumed mid-tutorial: re-normalize so anything satisfied while
			-- away (or committed during REVEAL_DELAY as they left) is skipped.
			setStep(player, step)
		end
	end)
end

function TutorialService.init()
	Players.PlayerAdded:Connect(watchJoin)
	for _, player in Players:GetPlayers() do
		watchJoin(player)
	end
end

return TutorialService
