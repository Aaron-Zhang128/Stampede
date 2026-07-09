--[[
	BullrushDash - dodge dash: a quick horizontal burst on a cooldown.
	Q / gamepad X / the auto-created mobile touch button (ContextActionService).

	Purely client-side: Roblox character movement is client-authoritative, so
	a server round-trip would add latency without adding trust. No HUD by
	design - the cooldown speaks through sound (whoosh on use, soft ping when
	ready again) and the trail.

	The dash is positional only: no invincibility frames, the bull kill box
	stays honest. It pushes along the humanoid's move direction (camera-flat
	look direction when standing still) for DASH_TIME, preserving vertical
	velocity so gravity and jumps behave.
]]

local ContextActionService = game:GetService("ContextActionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer

local DASH_SPEED = 56 -- studs/s, vs 16 walk and 36-62 bulls
local DASH_TIME = 0.18 -- ~10 studs: enough to clear a kill box, not a lane hop
local COOLDOWN = 3.5 -- roughly every other wave late-game
local FOV_KICK = 6 -- degrees of momentary camera widen
local TRAIL_COLOR = Color3.fromRGB(255, 236, 190)

local WHOOSH_ID = 12222095 -- Rocket whoosh 01.wav; same id BullrushClient uses

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

local function attachTrail(root: BasePart)
	local a0 = Instance.new("Attachment")
	a0.Position = Vector3.new(0, 1, 0)
	a0.Parent = root
	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(0, -1, 0)
	a1.Parent = root
	local trail = Instance.new("Trail")
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Color = ColorSequence.new(TRAIL_COLOR)
	trail.Transparency = NumberSequence.new(0.4, 1)
	trail.Lifetime = 0.25
	trail.WidthScale = NumberSequence.new(1, 0.3)
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

	local direction = humanoid.MoveDirection
	if direction.Magnitude < 0.1 then
		local camera = workspace.CurrentCamera
		local look = if camera then camera.CFrame.LookVector else root.CFrame.LookVector
		direction = look
	end
	direction = Vector3.new(direction.X, 0, direction.Z)
	if direction.Magnitude < 0.01 then
		return -- looking straight down with no input: nowhere to go
	end
	direction = direction.Unit

	lastDashAt = os.clock()
	dashing = true
	playWhoosh(1.4, 0.315)
	fovKick()
	attachTrail(root)

	local connection
	connection = RunService.Heartbeat:Connect(function()
		local _nowHumanoid, nowRoot = aliveParts()
		-- nowRoot ~= root catches death/respawn mid-dash.
		if nowRoot ~= root or os.clock() - lastDashAt >= DASH_TIME then
			connection:Disconnect()
			dashing = false
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

local function onAction(_name: string, state: Enum.UserInputState)
	if state == Enum.UserInputState.Begin then
		dash()
	end
	return Enum.ContextActionResult.Sink
end

ContextActionService:BindAction("BullrushDash", onAction, true,
	Enum.KeyCode.Q, Enum.KeyCode.ButtonX)
ContextActionService:SetTitle("BullrushDash", "Dash")
