--[[
	PushClient — proximity shove targeting + input (server rules live in PushService).

	Reworked (2026-07-09): the old per-player "Push" ProximityPrompt is gone.
	Instead, while a round is ACTIVE and you're alive, the NEAREST other
	participant within PUSH.RANGE is highlighted RED — the mirror of your own
	green SelfAura (BullrushClient) — and you shove them with F (keyboard),
	gamepad Y, or the HUD push button. Only the single nearest target is ever
	highlighted, and only that one is pushed.

	UI / gameplay split (per the one-LocalScript UI rule): the HUD push button
	lives in StarterGui.Main. It talks to this script through the PushBridge
	BindableEvent in ReplicatedStorage — the same idiom as RevengeViewBridge:
	  * the button fires PushBridge (a tap) -> we attempt a push
	  * we broadcast state back via PushBridge attributes that drive the
	    button's look + cooldown sweep:
	        Enabled          bool    you're an ACTIVE-round participant (button shown)
	        HasTarget        bool    a target is highlighted (button bright vs dim)
	        CooldownDuration number  PUSH.COOLDOWN, so the sweep knows its length
	        ReadyAt          number  os.clock() when the local cooldown lapses

	Still calls ExpressivePrompts.Init(): the lobby shop door, fortune wheel and
	bull-cam pad all use Custom-styled ProximityPrompts dressed by it.

	Getting shoved is unchanged: the server fires Remotes.Pushed and we apply the
	knockback burst to our own character (movement is client-authoritative, same
	idiom as BullrushDash).

	Bots (Workspace.BullrushArena.Bots) can be targeted too, so the shove is
	testable solo; we send the rig Model and the SERVER applies the knockback
	(bot rigs are server-owned). Bots never push back.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Bullrush.Config)
local ExpressivePrompts = require(ReplicatedStorage.ExpressivePrompts)
local Remotes = ReplicatedStorage.Bullrush.Remotes

local PUSH = Config.PUSH
local player = Players.LocalPlayer

-- Fancy custom UI for every Custom-styled ProximityPrompt in the game (shop
-- door, fortune wheel, bull-cam pad). The push system no longer uses prompts,
-- but this installer must stay live for the ones that do.
ExpressivePrompts.Init()

--==============================================================================
-- HUD bridge: the StarterGui.Main push button drives us through this local
-- BindableEvent (never replicates). Fire() = a tap; the attributes broadcast
-- our state back to the button. Mirrors ReplicatedStorage.RevengeViewBridge.
--==============================================================================

local pushBridge = Instance.new("BindableEvent")
pushBridge.Name = "PushBridge"
pushBridge:SetAttribute("Enabled", false)
pushBridge:SetAttribute("HasTarget", false)
pushBridge:SetAttribute("CooldownDuration", PUSH.COOLDOWN)
pushBridge:SetAttribute("ReadyAt", 0)
pushBridge.Parent = ReplicatedStorage

--==============================================================================
-- Red target aura: one reusable Highlight whose Adornee tracks the current
-- nearest target. Kept in a client-only workspace folder and driven by Adornee
-- (NOT by parenting to the character) so a target leaving / respawning can
-- never destroy our single instance — Adornee just clears to nil.
--==============================================================================

local fxHost = Instance.new("Folder")
fxHost.Name = "PushClientFX"
fxHost.Parent = Workspace

local targetHighlight = Instance.new("Highlight")
targetHighlight.Name = "PushTarget"
targetHighlight.FillColor = Color3.fromRGB(255, 0, 0)
targetHighlight.FillTransparency = 0.3
targetHighlight.OutlineColor = Color3.fromRGB(255, 30, 30)
targetHighlight.OutlineTransparency = 0
targetHighlight.DepthMode = Enum.HighlightDepthMode.Occluded
targetHighlight.Adornee = nil
targetHighlight.Parent = fxHost

--==============================================================================
-- State
--==============================================================================

local roundActive = false
local currentTarget: any = nil -- Player (real) or bot rig Model, or nil
local readyAt = 0 -- os.clock() when the local push cooldown lapses

--==============================================================================
-- Targeting: nearest living participant within PUSH.RANGE (planar distance).
--==============================================================================

local function localRoot(): BasePart?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and root then
		return root
	end
	return nil
end

-- True when we're an ACTIVE-round participant standing in the arena — the
-- server sets the replicated InRound attribute at round start and clears it on
-- elimination / round end — OR when we're on the practice grid (PracticeArena
-- maintains the InPractice attribute the same way). Lobby-sitters, AFK players
-- and late-joiners have neither, so the push system stays dark in the lobby.
local function isParticipating(): boolean
	if localRoot() == nil then
		return false
	end
	if player:GetAttribute("InPractice") == true then
		return true
	end
	return roundActive and player:GetAttribute("InRound") == true
end

-- Alive, targetable character's root, or nil. Skips a character BullrushClient
-- has hidden from us (an eliminated ghost: LocalTransparencyModifier ~= 0) —
-- the server would reject shoving a non-participant anyway, so don't waste the
-- highlight / cooldown on one.
local function livingRoot(character: Model): BasePart?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and root and root.LocalTransparencyModifier < 0.9 then
		return root
	end
	return nil
end

local function getBotsFolder(): Instance?
	local arena = Workspace:FindFirstChild("BullrushArena")
	return arena and arena:FindFirstChild("Bots")
end

local function planarDist(a: Vector3, b: Vector3): number
	return (Vector3.new(a.X - b.X, 0, a.Z - b.Z)).Magnitude
end

-- Returns (participant, character): participant is the Player (real) or the rig
-- Model (bot) — that's what we hand PushService — and character is the Model to
-- highlight. Nil when nothing is in range.
local function findNearest(from: Vector3)
	local best, bestChar, bestDist = nil, nil, PUSH.RANGE

	for _, other in Players:GetPlayers() do
		if other ~= player and other.Character then
			local root = livingRoot(other.Character)
			if root then
				local d = planarDist(from, root.Position)
				if d <= bestDist then
					best, bestChar, bestDist = other, other.Character, d
				end
			end
		end
	end

	local folder = getBotsFolder()
	if folder then
		for _, rig in folder:GetChildren() do
			if rig:IsA("Model") then
				local root = livingRoot(rig)
				if root then
					local d = planarDist(from, root.Position)
					if d <= bestDist then
						best, bestChar, bestDist = rig, rig, d
					end
				end
			end
		end
	end

	return best, bestChar
end

local function setTarget(participant, character)
	currentTarget = participant
	targetHighlight.Adornee = character
	pushBridge:SetAttribute("HasTarget", participant ~= nil)
end

-- Re-evaluate the nearest target on a light throttle (a handful of participants,
-- so ~12Hz is plenty and the Highlight follows the model between scans).
local SCAN_INTERVAL = 0.08
local lastScan = 0

RunService.Heartbeat:Connect(function()
	local now = os.clock()
	if now - lastScan < SCAN_INTERVAL then
		return
	end
	lastScan = now

	-- The whole push system (HUD button + red target highlight) only lights up
	-- while you're an ACTIVE-round participant in the arena. In the lobby you're
	-- not participating, so the button hides and no target is ever painted.
	if not isParticipating() then
		pushBridge:SetAttribute("Enabled", false)
		if currentTarget then
			setTarget(nil, nil)
		end
		return
	end
	pushBridge:SetAttribute("Enabled", true)

	local root = localRoot() :: BasePart
	local participant, character = findNearest(root.Position)
	setTarget(participant, character)
end)

--==============================================================================
-- Round state: shoving only works while a round is ACTIVE.
--==============================================================================

Remotes.RoundState.OnClientEvent:Connect(function(state: string)
	roundActive = state == "ACTIVE"
	if not roundActive then
		-- Round lapsed: the scan will hide the button (no longer participating);
		-- drop any target now so nothing lingers highlighted.
		setTarget(nil, nil)
	end
end)

--==============================================================================
-- Shove feedback: when YOU push, a quick two-hand thrust gesture + an effort
-- whoosh, fired the instant the shove leaves (optimistic, like BullrushDash) so
-- it feels responsive. The gesture plays on your OWN Animator, so it replicates
-- to everyone who can see you; the whoosh is local. The shared 3D impact thud on
-- the victim is server-authored in PushService, so the shove reads from every
-- vantage — and bot shoves get audio too.
--==============================================================================

local SHOVE_ANIM_ID = 522638767 -- Roblox-owned "R15 Sword Lunge": a forward thrust
local WHOOSH_ID = 12222095 -- Rocket whoosh 01; same id the dash uses

-- One track per character, (re)loaded on spawn. pcall-guarded and optional: an
-- R6 avatar or a failed load just degrades to whoosh-only, never an error.
local shoveTrack: AnimationTrack? = nil

local function loadShoveTrack(character: Model)
	shoveTrack = nil
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return
	end
	local anim = Instance.new("Animation")
	anim.AnimationId = "rbxassetid://" .. SHOVE_ANIM_ID
	local ok, track = pcall(function()
		return animator:LoadAnimation(anim)
	end)
	if ok and track then
		track.Priority = Enum.AnimationPriority.Action
		track.Looped = false
		shoveTrack = track
	end
end

if player.Character then
	loadShoveTrack(player.Character)
end
player.CharacterAdded:Connect(loadShoveTrack)

local function playWhoosh(pitch: number, volume: number)
	local sound = Instance.new("Sound")
	pcall(function()
		sound.SoundId = "rbxassetid://" .. WHOOSH_ID
	end)
	sound.PlaybackSpeed = pitch
	sound.Volume = volume
	sound.Parent = SoundService
	pcall(function()
		sound:Play()
	end)
	Debris:AddItem(sound, 4)
end

local function playShoveFeedback()
	local track = shoveTrack
	if track then
		pcall(function()
			track:Stop(0)
			track:Play(0.05)
			track:AdjustSpeed(1.6) -- a shove is a jab, not a full sword lunge
		end)
		-- The lunge holds a pose at its end; cut it short so it snaps back to
		-- normal movement rather than lingering.
		task.delay(0.5, function()
			if track.IsPlaying then
				pcall(function()
					track:Stop(0.15)
				end)
			end
		end)
	end
	playWhoosh(1.15, 0.28)
end

--==============================================================================
-- The shove: F / gamepad Y / the HUD button all funnel here. The server
-- re-validates everything (alive-in-round, cooldown, distance), so the local
-- cooldown gate is purely so the button's sweep matches what will be accepted.
--==============================================================================

local function attemptPush()
	if not isParticipating() then
		return -- not an active-round participant (e.g. in the lobby)
	end
	if os.clock() < readyAt then
		return -- still cooling down locally
	end

	-- We always swing, play the whoosh and start the cooldown — even with nobody in
	-- range. A punch that connects with air is a MISS: currentTarget is nil, so the
	-- server sees a nil target and replies with a red "You missed!" card. The
	-- cooldown applies either way, so whiffing costs you the same beat as landing it.
	local target = currentTarget
	Remotes.Push:FireServer(target) -- Player / bot rig Model, or nil on a miss
	playShoveFeedback()
	readyAt = os.clock() + PUSH.COOLDOWN
	pushBridge:SetAttribute("ReadyAt", readyAt)
end

-- HUD button tap.
pushBridge.Event:Connect(attemptPush)

-- Keyboard F / gamepad Y.
UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end
	if input.KeyCode == Enum.KeyCode.F or input.KeyCode == Enum.KeyCode.ButtonY then
		attemptPush()
	end
end)

--==============================================================================
-- Getting shoved: the server hands us a direction; we apply the burst to our
-- own character (client-authoritative movement, like the dash).
--==============================================================================

-- One live knockback at a time: the constraint (and its attachment) wear this
-- name so a newer shove can find and replace a burst still in flight.
local KNOCKBACK_NAME = "PushKnockback"

local function aliveRoot(): BasePart?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and root then
		return root
	end
	return nil
end

-- A short, decaying jolt on the victim's OWN camera — the single biggest "this
-- hurt" cue. Bound one priority AFTER the default camera so we layer our offset
-- on top of the CFrame it just set (a plain RenderStepped connection would be
-- overwritten by the camera update that runs after it). Re-binds cleanly if a
-- second shove lands mid-shake.
local SHAKE_BIND = "PushCamShake"
local SHAKE_POS = 0.2592 -- studs of positional jitter at peak
local SHAKE_ROT = 1.44 -- degrees of rotational jitter at peak
local SHAKE_TIME = 0.3 -- seconds to settle

local function shakeCamera()
	pcall(function()
		RunService:UnbindFromRenderStep(SHAKE_BIND)
	end)
	local startedAt = os.clock()
	RunService:BindToRenderStep(SHAKE_BIND, Enum.RenderPriority.Camera.Value + 1, function()
		local cam = Workspace.CurrentCamera
		local t = os.clock() - startedAt
		if not cam or t >= SHAKE_TIME then
			pcall(function()
				RunService:UnbindFromRenderStep(SHAKE_BIND)
			end)
			return
		end
		local falloff = 1 - t / SHAKE_TIME
		falloff = falloff * falloff -- sharp at impact, quick settle
		local p = SHAKE_POS * falloff
		local r = math.rad(SHAKE_ROT * falloff)
		cam.CFrame = cam.CFrame
			* CFrame.new((math.random() * 2 - 1) * p, (math.random() * 2 - 1) * p, (math.random() * 2 - 1) * p)
			* CFrame.Angles((math.random() * 2 - 1) * r, (math.random() * 2 - 1) * r, (math.random() * 2 - 1) * r)
	end)
end

Remotes.Pushed.OnClientEvent:Connect(function(direction: Vector3)
	local root = aliveRoot()
	if not root then
		return
	end
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 0.01 then
		return
	end
	flat = flat.Unit

	-- Camera jolt fires the instant the shove lands, selling the hit through the
	-- victim's own view.
	shakeCamera()

	-- Hitstop: a brief freeze at the instant of contact. Robs the shove of its
	-- floatiness and makes the launch that follows read as a violent hit rather
	-- than a glide. Anchor freezes the whole assembly; we bail if the player
	-- died / respawned during the freeze.
	if PUSH.HITSTOP > 0 then
		root.AssemblyLinearVelocity = Vector3.zero
		root.Anchored = true
		task.wait(PUSH.HITSTOP)
		if aliveRoot() ~= root then
			root.Anchored = false
			return
		end
		root.Anchored = false
	end

	-- Knockback: a hard spike at contact (full SPEED) that eases to a stop over
	-- PUSH.TIME, so the body FEELS the deceleration instead of gliding at a
	-- constant speed. Plus an upward pop with deliberate hang time (see
	-- Config.PUSH.UP_TIME).
	--
	-- Driven through an unlimited-force LinearVelocity constraint rather than
	-- raw AssemblyLinearVelocity writes. Heartbeat runs AFTER physics, so with
	-- raw writes the grounded humanoid's own controller spent every step in
	-- between pulling horizontal speed back toward its WalkSpeed — how much of
	-- the burst survived depended on frame rate and the round's WalkSpeed, and
	-- the same shove read weaker on a slow frame than a fast one. The solver
	-- enforces a constraint at EVERY substep, so the scripted arc below is
	-- exactly what the victim flies — every victim, every machine, every mode.

	-- A second shove landing mid-burst restarts clean: destroying the stale
	-- constraint ends its update loop too (the loop bails once its attachment
	-- leaves the root).
	local stale = root:FindFirstChild(KNOCKBACK_NAME)
	if stale then
		stale:Destroy()
	end

	local spike = Vector3.new(flat.X * PUSH.SPEED, PUSH.UP, flat.Z * PUSH.SPEED)
	root.AssemblyLinearVelocity = spike -- cover the substeps before the constraint engages

	local attachment = Instance.new("Attachment")
	attachment.Name = KNOCKBACK_NAME
	local velocity = Instance.new("LinearVelocity")
	velocity.Name = KNOCKBACK_NAME
	velocity.Attachment0 = attachment
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.ForceLimitsEnabled = false
	velocity.MaxForce = math.huge -- either way: nothing gets to fight the arc
	velocity.VectorVelocity = spike
	velocity.Parent = attachment
	attachment.Parent = root

	local startedAt = os.clock()
	local connection
	connection = RunService.Heartbeat:Connect(function(dt: number)
		local t = os.clock() - startedAt
		-- aliveRoot() ~= root catches death / respawn mid-knockback; a gone
		-- attachment means a newer shove took over. At the cutoff the last
		-- written velocity carries over and gravity takes the descent.
		if aliveRoot() ~= root or attachment.Parent ~= root or t >= PUSH.TIME then
			connection:Disconnect()
			attachment:Destroy()
			return
		end
		-- The constraint HOLDS each written velocity until the next write, so
		-- sample the curve half a frame AHEAD — the staircase then covers the
		-- same ground per second at 24 fps as at 144.
		local ts = math.min(t + dt / 2, PUSH.TIME)
		local falloff = 1 - ts / PUSH.TIME
		falloff = falloff * falloff -- ease-out: hardest at contact, decays to nothing
		-- Vertical pop: ramp Y from +UP toward -UP over UP_TIME. UP_TIME is tuned
		-- so the ramp's decel ~= gravity and TIME cuts the constraint just past
		-- apex, so the victim rides a natural arc up and real gravity lands them —
		-- deliberate hang time. Past the pop window (reachable only if TIME is
		-- ever retuned past UP_TIME) Y keeps falling at workspace gravity.
		local vy
		if ts < PUSH.UP_TIME then
			vy = PUSH.UP - (2 * PUSH.UP / PUSH.UP_TIME) * ts
		else
			vy = -PUSH.UP - Workspace.Gravity * (ts - PUSH.UP_TIME)
		end
		velocity.VectorVelocity = Vector3.new(
			flat.X * PUSH.SPEED * falloff,
			vy,
			flat.Z * PUSH.SPEED * falloff
		)
	end)
end)
