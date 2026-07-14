--[[
	TutorialService - server-authoritative first-session tutorial.

	Three guided steps for brand-new players (playing a round itself needs no
	teaching): 1 = send a bull from the Bull Cam, 2 = open the free BASIC
	lucky box at the shop stall, 3 = equip the rolled bull in the Index.
	Progress lives in the profile as TutorialStep (0 = not started, 4 = done)
	and mirrors to the same-named player attribute; the client overlay
	(StarterGui.Main section 18) is purely reactive and never talks back -
	every completion below is observed at its server-side source, so the
	steps can't be spoofed and no tutorial remotes exist.

	Start trigger: joining while a round is ACTIVE and young (wave <=
	JOIN_WAVE_CUTOFF) starts it immediately - the joiner is a spectator and
	may throw (RevengeService's 2026-07-13 widening). Everyone else starts on
	their FIRST elimination, whenever that lands (a player who wins game one
	starts when they die in game two). The tutorial never blocks play: while
	the player is alive in a round the overlay hides on its own (InRound).

	Steps 2/3 can be satisfied out-of-band (a fortune-wheel bull, a
	self-served roll or equip), so every write re-normalizes: anything the
	profile already proves learned is skipped, and a player left with nothing
	actionable is completed rather than stranded. Completion pays a one-time
	RAW money gift (no friend/VIP multipliers, no XP - the LevelService gift
	rule), exactly once, because crossing into DONE persists.

	Old saves never see any of this: Data.server grandfathers a missing
	TutorialStep key straight to DONE on load, and load-failed sessions
	(temp profiles) are refused so a veteran is never re-taught.
]]

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local DataHandler = require(ServerScriptService.UserData.DataHandler)
local NotifyService = require(script.Parent.NotifyService)

-- TUTORIAL TESTING MODE (STUDIO ONLY) --------------------------------------
-- Flip this true to make EVERY join restart the tour as a brand-new
-- first-timer: fresh STARTER-only inventory, one banked free BASIC box, and
-- TutorialStep reset to 0 so the next elimination opens step 1 (a young
-- mid-round join still auto-starts it immediately). Hard-gated to
-- RunService:IsStudio() below, so a stray `true` can NEVER wipe a live
-- player's bulls. TURN OFF before publishing.
local TEST_MODE = false

local DONE = 4
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

local function bullCount(profile): number
	local bulls = if typeof(profile.Bulls) == "table" then profile.Bulls else {}
	local n = 0
	for _ in bulls do
		n += 1
	end
	return n
end

-- Skips any step the profile already proves learned. Step 1 (the throw) has
-- no persistent trace, so it only ever completes live via onThrow.
local function normalized(profile, step: number): number
	while step == 2 or step == 3 do
		if step == 2 then
			if bullCount(profile) <= 1 then
				break -- still only STARTER: the roll is genuinely undone
			end
		else
			local equipped = profile.EquippedBull or "STARTER"
			if equipped == "STARTER" and bullCount(profile) > 1 then
				break -- owns a rolled bull but still wears STARTER: teach the equip
			end
		end
		step += 1
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

-- RoundService.eliminate (real players, quits excluded): the first death of
-- an untaught player opens the tutorial - they are about to become a
-- spectator of a round that is still running, the perfect launch classroom.
function TutorialService.onEliminated(player)
	if typeof(player) == "Instance" and player:GetAttribute("DataLoadFailed") then
		return -- temp profile: could be a veteran, never re-teach
	end
	if getStep(player) == 0 then
		setStep(player, 1)
	end
end

-- RevengeService.requestThrow success: step 1 done.
function TutorialService.onThrow(player)
	if getStep(player) == 1 then
		setStep(player, 2)
	end
end

-- BullRollService commitReveal (any box, any payment): step 2 done. Riding
-- the reveal commit means the attribute flips exactly as the carousel lands,
-- so the overlay never points at the Index mid-spin.
function TutorialService.onRoll(player)
	if getStep(player) == 2 then
		setStep(player, 3)
	end
end

-- BullRollService.requestEquip success: step 3 done -> completion gift.
function TutorialService.onEquip(player)
	if getStep(player) == 3 then
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
			-- Joined mid-round, early enough to matter? They're a spectator
			-- (never added to a round in progress) who can throw right now.
			if roundState == "ACTIVE"
				and (roundWave or math.huge) <= JOIN_WAVE_CUTOFF
				and player:GetAttribute("InRound") ~= true then
				setStep(player, 1)
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
