--[[
	RagdollService - the "bull connects" moment. launch() ragdolls the victim
	and throws them along the bull's heading, then kills the humanoid, so the
	corpse holds together and tumbles instead of the default joint-break poof.

	Works on player characters and AIService bot rigs alike (anything with a
	Humanoid + Motor6D rig). Must run BEFORE anything sets Health = 0:
	BreakJointsOnDeath has to be false at the moment of death.

	Order inside launch(): joints -> death -> ownership/velocity. Ownership
	must come last - the Network Ownership API rejects parts of a LIVE player
	character, but allows them once the humanoid is dead. The server takes
	ownership so the fling simulates authoritatively for everyone.
]]

local Debris = game:GetService("Debris")

local UP_SPEED = 26 -- vertical boost so victims arc instead of skidding
local SPIN_MAX = 10 -- rad/s of random tumble
local IMPACT_COLOR = Color3.fromRGB(168, 138, 96) -- arena dust
local IMPACT_SOUND_ID = 146163534 -- Slap Hit; same id the client uses for slams

local rng = Random.new()

local RagdollService = {}

local function ragdollJoints(character: Model)
	for _, motor in character:GetDescendants() do
		if motor:IsA("Motor6D") and motor.Part0 and motor.Part1 then
			local a0 = Instance.new("Attachment")
			a0.CFrame = motor.C0
			a0.Parent = motor.Part0
			local a1 = Instance.new("Attachment")
			a1.CFrame = motor.C1
			a1.Parent = motor.Part1
			local socket = Instance.new("BallSocketConstraint")
			socket.Attachment0 = a0
			socket.Attachment1 = a1
			socket.LimitsEnabled = true
			socket.TwistLimitsEnabled = true
			socket.Parent = motor.Part0
			motor:Destroy()
		end
	end
end

-- One-shot dust burst + thwack at the impact point, server-side so every
-- client sees/hears the same hit.
local function impactBurst(position: Vector3)
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.one
	part.Position = position
	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(IMPACT_COLOR)
	emitter.Lifetime = NumberRange.new(0.35, 0.7)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.2),
		NumberSequenceKeypoint.new(1, 3.0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.25),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Speed = NumberRange.new(10, 18)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Acceleration = Vector3.new(0, -24, 0)
	emitter.Enabled = false
	emitter.Parent = part
	local sound = Instance.new("Sound")
	sound.SoundId = "rbxassetid://" .. IMPACT_SOUND_ID
	sound.Volume = 0.63
	sound.PlaybackSpeed = 0.75
	sound.RollOffMaxDistance = 140
	sound.Parent = part
	part.Parent = workspace
	emitter:Emit(24)
	pcall(function()
		sound:Play()
	end)
	Debris:AddItem(part, 2)
end

-- direction: bull travel vector (any length, Y ignored); speed: horizontal
-- fling speed in studs/s. No-op on missing/already-dead characters, so
-- double hits in the same frame are safe.
function RagdollService.launch(character: Model?, direction: Vector3, speed: number)
	if not character or not character.Parent then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root then
		return
	end

	humanoid.BreakJointsOnDeath = false
	humanoid.AutoRotate = false
	-- Physics state stops the owning client's controller fighting the fling.
	pcall(function()
		humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	end)

	impactBurst(root.Position)
	ragdollJoints(character) -- may itself kill via RequiresNeck; that's fine
	if humanoid.Health > 0 then
		humanoid.Health = 0
	end

	local horizontal = Vector3.new(direction.X, 0, direction.Z)
	horizontal = if horizontal.Magnitude > 0.01 then horizontal.Unit else Vector3.zAxis
	local velocity = horizontal * speed + Vector3.new(0, UP_SPEED, 0)
	local spin = Vector3.new(
		rng:NextNumber(-1, 1),
		rng:NextNumber(-1, 1),
		rng:NextNumber(-1, 1)
	) * SPIN_MAX

	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") then
			-- Limbs collide so the corpse tumbles; the invisible root box
			-- would just catch on things.
			part.CanCollide = part.Name ~= "HumanoidRootPart"
			pcall(part.SetNetworkOwner, part, nil)
			part.AssemblyLinearVelocity = velocity
			part.AssemblyAngularVelocity = spin
		end
	end
end

return RagdollService
