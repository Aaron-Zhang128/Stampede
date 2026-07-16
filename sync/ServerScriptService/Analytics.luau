--[[
	Analytics - first-session player-progression funnel.

	Logs a single linear ONBOARDING funnel via AnalyticsService. Onboarding steps
	are deduped per user for their lifetime by Roblox, so this measures how far a
	NEW player gets on their first exposure to the game:

	  1. Joined            - entered the server
	  2. StartedFirstGame  - spawned into their first round
	  3. FinishedFirstGame - that round ended (won or eliminated)
	  4. Played3Min        - 3 minutes of continuous session playtime
	  5. Played8Min        - 8 minutes of continuous session playtime

	View the drop-off between steps under Analytics > Funnels in the Creator
	Dashboard (funnel name "PlayerProgression").

	Separately, a "Tutorial" funnel measures how far a first-timer gets through
	the guided first-session tour (Bullrush/TutorialService):

	  1. TutorialStarted   - the tour opened (first elimination / young join)
	  2. TutorialSentBull  - step 1 done: they sent a bull from the Bull Cam
	  3. TutorialFinished  - step 2 done: they opened the free box (tour done)

	This is a standard named funnel (not the onboarding funnel, of which Roblox
	allows only one per experience - already spent on PlayerProgression above).
	Its steps are keyed by a per-user funnel session id so one player's whole
	tour groups as a single journey and links even across a mid-tour rejoin.

	Every entry point is wrapped so a failing analytics call can never disrupt
	gameplay. onJoin is called from UserData/Data.server; onFirstGameStart /
	onFirstGameFinish are called from Bullrush/Main.server; the onTutorial*
	steps are called from Bullrush/TutorialService.
]]

local AnalyticsService = game:GetService("AnalyticsService")
local Players = game:GetService("Players")

local Analytics = {}

-- Onboarding funnel step numbers (STABLE once shipped - reordering breaks the
-- dashboard's history) paired with their display names.
local FUNNEL_NAME = "PlayerProgression"
local STEP_JOIN = { 1, "Joined" }
local STEP_START = { 2, "StartedFirstGame" }
local STEP_FINISH = { 3, "FinishedFirstGame" }
local STEP_3MIN = { 4, "Played3Min" }
local STEP_8MIN = { 5, "Played8Min" }

-- Tutorial funnel: a standard (named) funnel, since the single onboarding
-- funnel is already PlayerProgression. Step numbers STABLE once shipped.
local TUTORIAL_FUNNEL = "Tutorial"
local TUT_STEP_START = { 1, "TutorialStarted" }
local TUT_STEP_SENT = { 2, "TutorialSentBull" }
local TUT_STEP_FINISH = { 3, "TutorialFinished" }

-- [userId] = { started = bool, finished = bool } for the live session. Guards the
-- once-per-session game steps and lets pending playtime timers know the player
-- is still around (cleared on PlayerRemoving).
local sessions = {}

local function logStep(player: Player, step: { any })
	local ok, err = pcall(function()
		AnalyticsService:LogOnboardingFunnelStepEvent(player, step[1], step[2])
	end)
	if not ok then
		warn("[Analytics] funnel step failed:", step[2], err)
	end
end

-- One standard-funnel step for the "Tutorial" journey. The funnel session id is
-- derived from the userId (not a fresh GUID) so every step of one player's tour
-- groups together AND a rejoin that finishes the tour still links to its start;
-- re-logging a step for the same id is harmless (the dashboard counts unique
-- sessions reaching each step).
local function logTutorialStep(player: Player, step: { any })
	local ok, err = pcall(function()
		AnalyticsService:LogFunnelStepEvent(
			player, TUTORIAL_FUNNEL, "tutorial-" .. player.UserId, step[1], step[2])
	end)
	if not ok then
		warn("[Analytics] tutorial funnel step failed:", step[2], err)
	end
end

-- Player joined: log step 1 and arm the continuous-playtime milestones.
function Analytics.onJoin(player: Player)
	local userId = player.UserId
	sessions[userId] = { started = false, finished = false }
	logStep(player, STEP_JOIN)

	-- Each milestone fires only if this exact session is still live: the flag is
	-- cleared the instant the player leaves, so a stale timer can't fire (and a
	-- later rejoin gets its own session; Roblox also dedupes onboarding steps).
	local session = sessions[userId]
	task.delay(180, function()
		if sessions[userId] == session and player.Parent then
			logStep(player, STEP_3MIN)
		end
	end)
	task.delay(480, function()
		if sessions[userId] == session and player.Parent then
			logStep(player, STEP_8MIN)
		end
	end)
end

-- Player spawned into their FIRST round this session.
function Analytics.onFirstGameStart(player: Player)
	local session = sessions[player.UserId]
	if not session or session.started then
		return
	end
	session.started = true
	logStep(player, STEP_START)
end

-- Player's first round ended (won or eliminated). Only meaningful once they've
-- actually started one, so it can never outrun the StartedFirstGame step.
function Analytics.onFirstGameFinish(player: Player)
	local session = sessions[player.UserId]
	if not session or not session.started or session.finished then
		return
	end
	session.finished = true
	logStep(player, STEP_FINISH)
end

-- Tutorial tour opened (TutorialService step -> 1).
function Analytics.onTutorialStart(player: Player)
	logTutorialStep(player, TUT_STEP_START)
end

-- Tutorial step 1 done: a bull was sent (TutorialService step -> 2).
function Analytics.onTutorialSentBull(player: Player)
	logTutorialStep(player, TUT_STEP_SENT)
end

-- Tutorial complete: the free box was opened, the final step (-> DONE).
function Analytics.onTutorialFinish(player: Player)
	logTutorialStep(player, TUT_STEP_FINISH)
end

Players.PlayerRemoving:Connect(function(player)
	sessions[player.UserId] = nil
end)

return Analytics
