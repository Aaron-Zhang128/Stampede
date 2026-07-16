--[[
	TutorialService - server-authoritative first-session tutorial.

	ONE guided step for brand-new players (playing a round itself needs no
	teaching): claim the FREE starter ability from the lobby ability shop's
	pinned slot-1 card. (The old bull-send step - TutorialStep 1 - was REMOVED
	2026-07-15; the tour now opens straight at the claim step, which is KEPT as
	step 2 so DONE = 3, the client overlay, and old saves all stay valid.)
	Progress lives in the profile as TutorialStep (0 = not started, 3 = done) and
	mirrors to the same-named player attribute; the client overlay
	(StarterGui.Main section 18) is purely reactive and never talks back - the
	one completion below is observed at its server-side source
	(AbilityShopService claim), so it can't be spoofed and no tutorial remotes exist.

	Start trigger: joining while a round is ACTIVE and young (wave <=
	JOIN_WAVE_CUTOFF) starts it immediately; everyone else starts on their FIRST
	elimination, whenever that lands (a player who wins game one starts when they
	die in game two). The tutorial never blocks play: while the player is alive
	in a round the overlay hides on its own (InRound).

	Step 2 can be satisfied out-of-band (the player already owns the starter
	ability), so every write re-normalizes: anything the profile already proves
	learned is skipped, and a player left with nothing actionable is completed
	rather than stranded. Completion pays a one-time RAW money gift (no
	friend/VIP multipliers, no XP - the LevelService gift rule), exactly once,
	because crossing into DONE persists.

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
local NotifyService = require(script.Parent.NotifyService)

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

-- Folds the RETIRED bull-send step (1) into the claim step (2): the tour no
-- longer teaches throwing, so any legacy step-1 value - a save from before the
-- 2026-07-15 removal, or a resume - resolves straight to the claim step. Then
-- skips even that when the profile already proves the free ability was claimed
-- (owns STARTER_ABILITY), completing rather than stranding.
local function normalized(profile, step: number): number
	if step == 1 then
		step = 2 -- retired bull-send step folds into the claim step
	end
	if step == 2 and ownsStarterAbility(profile) then
		return DONE -- already claimed the free ability: nothing left to teach
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
		-- friend/VIP multipliers onto a fixed gift and feed the XP curve.
		DataHandler.SetStat(player, "Money",
			(DataHandler.GetStat(player, "Money") or 0) + REWARD)
		NotifyService.send(player, ("Tutorial done! +$%d"):format(REWARD), "green", 5)
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

-- RoundService.eliminate (real players, quits excluded): the first death of an
-- untaught player opens the tutorial at the claim step (step 2; the bull-send
-- step 1 was retired 2026-07-15), guiding them to the lobby ability shop once
-- they're back on their feet.
function TutorialService.onEliminated(player)
	if typeof(player) == "Instance" and player:GetAttribute("DataLoadFailed") then
		return -- temp profile: could be a veteran, never re-teach
	end
	if getStep(player) == 0 then
		setStep(player, 2)
	end
end

-- AbilityShopService free-starter claim: step 2 (grab the free ability from the
-- shop's pinned slot-1 card) is the final step -> completion gift. Fires the
-- instant the grant lands, so the overlay clears as the card flips to OWNED.
function TutorialService.onClaimStarter(player)
	if getStep(player) == 2 then
		setStep(player, DONE)
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
