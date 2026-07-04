--------------------------------------------------------------------------------
-- SoundDirector
-- The "game-show" audio layer for Bullrush Grid. Crossfades background music
-- between a calm lobby loop and a driving battle theme, and fires stingers on
-- the beats that matter: mode reveal, final-countdown ticks, round kickoff,
-- your own elimination, victory, defeat, revenge money, and a final-two
-- heartbeat. Every sound is pulled from the curated library the user placed in
-- SoundService (BackgroundMusic + GameSFX groups), so it all stays tweakable
-- from the Explorer and the SoundGroup mixer -- nothing here is hardcoded.
--
-- Independent, presentation-only client script: it listens to the same
-- replicated round contract as BullrushClient (a RemoteEvent fans out to every
-- listener) and never touches server state, so it can't change gameplay. Every
-- lookup is optional and every play is pcall-guarded -- a missing or moderated
-- sound degrades to silence, never an error.
--------------------------------------------------------------------------------

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local player = Players.LocalPlayer

--==============================================================================
-- Round contract (mirrors BullrushClient; all optional / defensive)
--==============================================================================

local WAIT_TIMEOUT = 30
local bullrushFolder = ReplicatedStorage:WaitForChild("Bullrush", WAIT_TIMEOUT)
local remotes = bullrushFolder and bullrushFolder:WaitForChild("Remotes", WAIT_TIMEOUT)
if not remotes then
	warn("[SoundDirector] Remotes missing; audio layer disabled.")
	return
end

local roundStateRemote = remotes:WaitForChild("RoundState", WAIT_TIMEOUT)
local eliminatedRemote = remotes:WaitForChild("Eliminated", WAIT_TIMEOUT)
local revengeAckRemote = remotes:FindFirstChild("RevengeAck") -- optional

if not (roundStateRemote and eliminatedRemote) then
	warn("[SoundDirector] Round-state remotes missing; audio layer disabled.")
	return
end

--==============================================================================
-- Sound library (the curated set placed in SoundService)
--==============================================================================

local musicGroup = SoundService:FindFirstChild("BackgroundMusic")
local sfxGroup = SoundService:FindFirstChild("GameSFX")

-- Resolve a library sound by name from either group. Returns a *template*;
-- callers clone it, so overlapping plays never fight and the library instances
-- stay pristine (and editable in the Explorer).
local function template(name: string): Sound?
	local inst = (sfxGroup and sfxGroup:FindFirstChild(name))
		or (musicGroup and musicGroup:FindFirstChild(name))
	if inst and inst:IsA("Sound") then
		return inst
	end
	return nil
end

-- Fire-and-forget one-shot: clone the template, route it through the GameSFX
-- group, play, and clean up. Silent no-op if the sound is missing.
local function playSfx(name: string, volume: number?, pitch: number?)
	local tmpl = template(name)
	if not tmpl then
		return
	end
	local ok, s = pcall(function()
		return tmpl:Clone()
	end)
	if not ok or not s then
		return
	end
	s.Looped = false
	if sfxGroup then
		s.SoundGroup = sfxGroup
	end
	if volume then
		s.Volume = volume
	end
	if pitch then
		s.PlaybackSpeed = pitch
	end
	s.Parent = SoundService
	pcall(function()
		s:Play()
	end)
	Debris:AddItem(s, 12) -- outlives the longest one-shot
	s.Ended:Once(function()
		s:Destroy()
	end)
end

--==============================================================================
-- Looped beds (music + heartbeat): kept alive from start, crossfaded by volume.
--==============================================================================

-- Clone a template into a persistent looped bed that starts silent and playing,
-- so a later fade-in is instant (no load hitch). Routes to the music group by
-- default; callers re-route as needed.
local function makeBed(name: string): Sound?
	local tmpl = template(name)
	if not tmpl then
		return nil
	end
	local ok, bed = pcall(function()
		return tmpl:Clone()
	end)
	if not ok or not bed then
		return nil
	end
	bed.Looped = true
	bed.Volume = 0
	if musicGroup then
		bed.SoundGroup = musicGroup
	end
	bed.Parent = SoundService
	pcall(function()
		bed:Play()
	end)
	return bed
end

local MUSIC_LOBBY_VOL = 0.5
local MUSIC_BATTLE_VOL = 0.55
local MUSIC_FADE = 1.5

local lobbyBed = makeBed("Game Lobby Alternate")
local battleBed = makeBed("Theme")

local currentTrack: string? = nil
local function setMusic(which: string)
	if currentTrack == which then
		return
	end
	currentTrack = which
	if lobbyBed then
		TweenService:Create(lobbyBed, TweenInfo.new(MUSIC_FADE), {
			Volume = if which == "lobby" then MUSIC_LOBBY_VOL else 0,
		}):Play()
	end
	if battleBed then
		TweenService:Create(battleBed, TweenInfo.new(MUSIC_FADE), {
			Volume = if which == "battle" then MUSIC_BATTLE_VOL else 0,
		}):Play()
	end
end

-- Final-two heartbeat: routed to the SFX group so it sits with the tension FX,
-- not the music mix.
local HEARTBEAT_AT = 2
local HEARTBEAT_VOL = 0.55

local heartbeatBed = makeBed("Heartbeat")
if heartbeatBed and sfxGroup then
	heartbeatBed.SoundGroup = sfxGroup
end

local heartbeatOn = false
local heartbeatTween: Tween? = nil
local function setHeartbeat(aliveCount: number?)
	if not heartbeatBed or aliveCount == nil then
		return
	end
	local shouldPlay = aliveCount == HEARTBEAT_AT
	if shouldPlay == heartbeatOn then
		return
	end
	heartbeatOn = shouldPlay
	if heartbeatTween then
		heartbeatTween:Cancel()
	end
	heartbeatTween = TweenService:Create(
		heartbeatBed,
		TweenInfo.new(if shouldPlay then 0.8 else 0.6),
		{ Volume = if shouldPlay then HEARTBEAT_VOL else 0 }
	)
	heartbeatTween:Play()
end

--==============================================================================
-- Wiring: the round contract drives music + stingers.
--==============================================================================

-- Did the local player (or their team) win? Conservative: false on any doubt.
local function localWon(info): boolean
	if typeof(info) ~= "table" then
		return false
	end
	if typeof(info.teamColor) == "string" then
		local team = player.Team
		return team ~= nil and string.find(string.upper(team.Name), info.teamColor) ~= nil
	end
	if typeof(info.winnerName) == "string" then
		return info.winnerName == player.Name
	end
	return false
end

local previousState: string? = nil

roundStateRemote.OnClientEvent:Connect(function(state, info)
	if typeof(state) ~= "string" then
		return
	end
	if typeof(info) ~= "table" then
		info = {}
	end

	-- Music bed follows the round: battle theme only while a round is live.
	setMusic(if state == "ACTIVE" then "battle" else "lobby")

	if state == "INTERMISSION" then
		-- Mode reveal sting once on entry (the server re-sends INTERMISSION
		-- every second as it counts down).
		if previousState ~= "INTERMISSION" then
			playSfx("Reveal", 0.8)
		end
		-- Final three ticks, rising on the last one.
		local t = tonumber(info.timeLeft)
		if t == 3 or t == 2 then
			playSfx("Ticker", 1.0, 1.0)
		elseif t == 1 then
			playSfx("Ticker", 1.0, 1.3)
		end
	elseif state == "ACTIVE" then
		-- Kickoff whoosh, only on a real intermission->active handoff (never on
		-- a mid-round join).
		if previousState == "INTERMISSION" then
			playSfx("Spin_Start", 0.8)
		end
		setHeartbeat(tonumber(info.aliveCount))
	elseif state == "WINNER" then
		setHeartbeat(0) -- duel's over
		playSfx("winner!", 1.0)
		if localWon(info) then
			playSfx("Cash", 1.0)
		end
	elseif state == "ROUNDOVER" then
		setHeartbeat(0)
		playSfx("Lose sound effects", 0.8)
	elseif state == "WAITING" then
		setHeartbeat(0)
	end

	previousState = state
end)

-- Your own elimination: a short hit sting layered over BullrushClient's thud.
-- Also carries the reliable per-elimination alive count that drives the
-- heartbeat as the field narrows to a duel.
eliminatedRemote.OnClientEvent:Connect(function(playerName, aliveCount)
	if playerName == player.Name then
		playSfx("C Hitsound", 0.85)
	end
	setHeartbeat(tonumber(aliveCount))
end)

-- Revenge bull cashed in on an alive victim: kaching.
if revengeAckRemote then
	revengeAckRemote.OnClientEvent:Connect(function(kind)
		if kind == "HIT" then
			playSfx("Cash", 1.0)
		end
	end)
end

-- Start on the lobby bed immediately so there's never dead air while we wait
-- for the first replicated state (a mid-round joiner won't get an ACTIVE event
-- until the next round).
setMusic("lobby")
