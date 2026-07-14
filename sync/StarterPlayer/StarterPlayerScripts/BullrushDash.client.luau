--[[
	BullrushDash - dodge dash: a quick horizontal burst on a cooldown.
	Triggered by a DOUBLE JUMP: press jump a second time while already airborne
	(space / gamepad A / the mobile jump button all count, via JumpRequest).

	Purely client-side: Roblox character movement is client-authoritative, so
	a server round-trip would add latency without adding trust. No HUD by
	design - the cooldown speaks through sound (whoosh on use, soft ping when
	ready again) and the trail.

	The dash is positional only: no invincibility frames, the bull kill box
	stays honest. It pushes along the humanoid's move direction (camera-flat
	look direction when standing still) for DASH_TIME, with a one-time updraft
	kick at the start; after that vertical velocity is left to gravity.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer

local DASH_SPEED = 60 -- studs/s, vs 16 walk and 36-62 bulls (nudged up a touch for snap)
local DASH_TIME = 0.18 -- ~11 studs: enough to clear a kill box, not a lane hop
local DASH_UPDRAFT = 20 -- studs/s upward kick at dash start: a lift, not a launch (jump is 50)
local COOLDOWN = 2 -- roughly every wave late-game
local FOV_KICK = 6 -- degrees of momentary camera widen
local TRAIL_COLOR = Color3.fromRGB(240, 246, 255) -- airy near-white: reads as wind, not a warm streak

local WHOOSH_ID = 12222095 -- Rocket whoosh 01.wav; same id BullrushClient uses

-- Roblox's classic R6 tool-lunge animation (the sword-thrust lunge) reused as a
-- forward dash pose. It's a full-body forward drive, so it reads as a dash from
-- any camera angle. Time-scaled per-use to finish just after the burst ends.
local LUNGE_ID = "rbxassetid://129967478"
local lungeAnim = Instance.new("Animation")
lungeAnim.AnimationId = LUNGE_ID

local lungeTrack: AnimationTrack? = nil
local lungeHumanoid: Humanoid? = nil

-- Load (and cache) the lunge track for the given humanoid, re-loading on respawn.
local function getLungeTrack(humanoid: Humanoid): AnimationTrack?
	if lungeTrack and lungeHumanoid == humanoid then
		return lungeTrack
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return nil
	end
	local ok, track = pcall(function()
		return animator:LoadAnimation(lungeAnim)
	end)
	if not ok or not track then
		return nil
	end
	track.Priority = Enum.AnimationPriority.Action
	lungeTrack = track
	lungeHumanoid = humanoid
	return track
end

local lastDashAt = -math.huge
local dashing = false

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

local function aliveParts(): (Humanoid?, BasePart?)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and root then
		return humanoid, root
	end
	return nil, nil
end

-- A windswept streak that rips off the body during the dash. Taller than the
-- character, always broadside to camera, and self-lit so it pops even in shade.
local function attachTrail(root: BasePart)
	local a0 = Instance.new("Attachment")
	a0.Position = Vector3.new(0, 2.2, 0) -- tall sheet, top -> reads as a gust, not a thin ribbon
	a0.Parent = root
	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(0, -2.6, 0) -- ...to the feet
	a1.Parent = root
	local trail = Instance.new("Trail")
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Color = ColorSequence.new(TRAIL_COLOR)
	-- Bright and solid at the body, streaking out to nothing behind.
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.05),
		NumberSequenceKeypoint.new(0.5, 0.4),
		NumberSequenceKeypoint.new(1, 1),
	})
	trail.Lifetime = 0.4 -- longer tail = a proper wind streak
	trail.WidthScale = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.4),
		NumberSequenceKeypoint.new(1, 0),
	})
	trail.FaceCamera = true -- always broadside to the camera = always visible
	trail.LightInfluence = 0 -- self-lit; doesn't get swallowed by lobby shade
	trail.Texture = "rbxassetid://241629053" -- soft wisp, stretched into windswept streaks
	trail.TextureMode = Enum.TextureMode.Stretch
	trail.Parent = root
	Debris:AddItem(a0, DASH_TIME + 1)
	Debris:AddItem(a1, DASH_TIME + 1)
	Debris:AddItem(trail, DASH_TIME + 1)
end

local function fovKick()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local base = camera.FieldOfView
	local out = TweenService:Create(camera,
		TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ FieldOfView = base + FOV_KICK })
	out.Completed:Once(function()
		TweenService:Create(camera,
			TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ FieldOfView = base }):Play()
	end)
	out:Play()
end

-- A quick puff of dust kicked up where the dash plants — the "stick the landing"
-- beat that makes the burst feel like it ended with weight, not just stopped.
local function landingPuff(root: BasePart)
	local emitAt = Instance.new("Attachment")
	emitAt.Position = Vector3.new(0, -2.6, 0) -- near the feet
	emitAt.Parent = root
	local puff = Instance.new("ParticleEmitter")
	puff.Texture = "rbxassetid://241629053" -- soft round smoke (Roblox default dust)
	puff.Color = ColorSequence.new(Color3.fromRGB(196, 176, 142)) -- dusty tan
	puff.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
	puff.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.6),
		NumberSequenceKeypoint.new(1, 3.4),
	})
	puff.Lifetime = NumberRange.new(0.35, 0.55)
	puff.Speed = NumberRange.new(4, 7)
	puff.SpreadAngle = Vector2.new(180, 180)
	puff.Drag = 6
	puff.Rotation = NumberRange.new(0, 360)
	puff.LightEmission = 0.05
	puff.Enabled = false
	puff.Parent = emitAt
	puff:Emit(10)
	Debris:AddItem(emitAt, 1)
end

local function dash()
	if dashing or os.clock() - lastDashAt < COOLDOWN then
		return
	end
	local humanoid, root = aliveParts()
	if not humanoid or not root then
		return
	end

	-- Dash only fires when actively moving: the burst follows the movement input,
	-- so no input = nothing to dash toward (no standing double-tap dash).
	local direction = humanoid.MoveDirection
	direction = Vector3.new(direction.X, 0, direction.Z)
	if direction.Magnitude < 0.1 then
		return -- no directional input: nowhere to go
	end
	direction = direction.Unit

	lastDashAt = os.clock()
	dashing = true

	-- Updraft: one-time upward kick so the dash lifts as it bursts. Any downward
	-- momentum is cancelled first (max with 0) so the lift reads the same whether
	-- the player dashed off a jump's apex or mid-fall. The heartbeat loop below
	-- preserves Y each frame, so gravity takes it from here.
	local vel = root.AssemblyLinearVelocity
	root.AssemblyLinearVelocity = Vector3.new(vel.X, math.max(vel.Y, 0) + DASH_UPDRAFT, vel.Z)

	playWhoosh(1.4, 0.315)
	fovKick()
	attachTrail(root)

	local track = getLungeTrack(humanoid)
	if track then
		track:Play(0.05)
		-- Scale so the lunge plays across ~1.6x the burst: snappy, but it lands a
		-- beat after the movement stops rather than freezing mid-pose.
		if track.Length > 0 then
			track:AdjustSpeed(track.Length / (DASH_TIME * 1.6))
		end
	end

	local connection
	connection = RunService.Heartbeat:Connect(function()
		local _nowHumanoid, nowRoot = aliveParts()
		-- nowRoot ~= root catches death/respawn mid-dash.
		if nowRoot ~= root or os.clock() - lastDashAt >= DASH_TIME then
			connection:Disconnect()
			dashing = false
			if lungeTrack and lungeTrack.IsPlaying then
				lungeTrack:Stop(0.12) -- fade out; lunge tail overhangs the movement slightly
			end
			if nowRoot == root then
				landingPuff(root) -- only if we survived the dash (not a mid-dash death)
			end
			task.delay(math.max(COOLDOWN - (os.clock() - lastDashAt), 0), function()
				if aliveParts() then
					playWhoosh(2.1, 0.084) -- soft "ready again" ping
				end
			end)
			return
		end
		-- Horizontal push only; gravity keeps doing its thing.
		root.AssemblyLinearVelocity = Vector3.new(
			direction.X * DASH_SPEED,
			root.AssemblyLinearVelocity.Y,
			direction.Z * DASH_SPEED
		)
	end)
end

-- Double-tap jump = dash. JumpRequest fires on space / gamepad A / the mobile
-- jump button. The FIRST press is a normal jump; a SECOND press within
-- DOUBLE_TAP_WINDOW spends the dash instead -- but ONLY if the button was
-- released between the two presses (press -> release -> press). A held button,
-- or the engine emitting a rapid JumpRequest pair, won't dash. dash() also
-- no-ops unless moving, so a stationary double-tap is just a plain jump.
local DOUBLE_TAP_WINDOW = 0.35 -- max seconds between the two presses to count as a double-tap
local lastJumpAt = -math.huge
local releasedSincePress = true -- true once the jump input has been let go again

-- Which inputs count as "jump" for release detection (touch covers the mobile
-- jump button; keyboard space and gamepad A cover the rest).
local function isJumpInput(input: InputObject): boolean
	return input.KeyCode == Enum.KeyCode.Space
		or input.KeyCode == Enum.KeyCode.ButtonA
		or input.UserInputType == Enum.UserInputType.Touch
end

UserInputService.InputEnded:Connect(function(input)
	if isJumpInput(input) then
		releasedSincePress = true
	end
end)

UserInputService.JumpRequest:Connect(function()
	local now = os.clock()
	if releasedSincePress and now - lastJumpAt <= DOUBLE_TAP_WINDOW then
		lastJumpAt = -math.huge -- consume the pair so a 3rd press starts fresh
		dash()
	else
		lastJumpAt = now -- (re)arm as the first press of a potential double-tap
	end
	releasedSincePress = false -- next press only counts after a fresh release
end)
