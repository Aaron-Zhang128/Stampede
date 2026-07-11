--[[
	RagdollService - the "bull connects" moment. launch() ragdolls the victim
	and throws them along the bull's heading, then kills the humanoid, so the
	corpse holds together and tumbles instead of the default joint-break poof.

	Works on player characters and AIService bot rigs alike (anything with a
	Humanoid + Motor6D rig). Must run BEFORE anything sets Health = 0:
	BreakJointsOnDeath has to be false at the moment of death.

	Ownership model: the SERVER only does the cheap, authoritative bits -
	convert joints to ball-sockets (so every client agrees on the rig), mark the
	limbs collidable, and kill the humanoid (which drives elimination). It then
	hands the launch vector to the VICTIM'S CLIENT over RagdollFling and does no
	physics itself: the victim already owns its character assembly, so its own
	machine simulates the tumble and it replicates to everyone for free. That
	keeps the ragdoll cost off the server entirely. Bot rigs have no client to
	own them, so they fall back to the old server-authoritative fling.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UP_SPEED = 26 -- vertical boost so victims arc instead of skidding
local SPIN_MAX = 10 -- rad/s of random tumble
local IMPACT_COLOR = Color3.fromRGB(168, 138, 96) -- arena dust
local IMPACT_SOUND_ID = 146163534 -- Slap Hit; same id the client uses for slams

local rng = Random.new()

-- Same ensure-on-require pattern the other services use: the Remotes folder is
-- created by Main at boot, but we self-heal the one remote we need so require
-- order never matters. server -> victim client: "you were hit; simulate your
-- own tumble", carrying the pre-computed launch vector so the fling math lives
-- in exactly one place.
local Remotes = ReplicatedStorage.Bullrush.Remotes
local function ensureRemote(name: string): RemoteEvent
	local remote = Remotes:FindFirstChild(name)
	if not (remote and remote:IsA("RemoteEvent")) then
		remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = Remotes
	end
	return remote
end
local RagdollFling = ensureRemote("RagdollFling")

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

-- The launch vector: a horizontal shove along the bull's heading + an upward
-- boost so victims arc instead of skidding, plus a random tumble. Computed
-- server-side so the player path, the bot path, and every client share one
-- source of truth.
local function computeFling(direction: Vector3, speed: number): (Vector3, Vector3)
	local horizontal = Vector3.new(direction.X, 0, direction.Z)
	horizontal = if horizontal.Magnitude > 0.01 then horizontal.Unit else Vector3.zAxis
	local velocity = horizontal * speed + Vector3.new(0, UP_SPEED, 0)
	local spin = Vector3.new(
		rng:NextNumber(-1, 1),
		rng:NextNumber(-1, 1),
		rng:NextNumber(-1, 1)
	) * SPIN_MAX
	return velocity, spin
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

	impactBurst(root.Position)
	ragdollJoints(character) -- may itself kill via RequiresNeck; that's fine
	if humanoid.Health > 0 then
		humanoid.Health = 0
	end

	-- Limbs collide so the corpse tumbles; the invisible root box would just
	-- catch on things. Set server-side so the collision state replicates to
	-- every client (and to the victim, who will simulate the tumble).
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") then
			part.CanCollide = part.Name ~= "HumanoidRootPart"
		end
	end

	local velocity, spin = computeFling(direction, speed)
	local player = Players:GetPlayerFromCharacter(character)
	if player then
		-- Player victim: their client ALREADY owns this character, and Roblox
		-- keeps that ownership through death until respawn (default death flops
		-- are client-simulated for exactly this reason). So we deliberately do
		-- NOT touch network ownership here - calling SetNetworkOwner would yank
		-- the assembly out from under the client's own simulation and, racing the
		-- client's velocity write, leave a window where NEITHER side simulates:
		-- the body freezes mid-pose and reads as "stiff, not ragdolling". We just
		-- hand the launch vector to the owning client and let it drive the tumble;
		-- the server runs no ragdoll physics and the motion replicates to everyone
		-- because the victim owns the parts.
		RagdollFling:FireClient(player, velocity, spin)
	else
		-- Bot rig has no client to own it: keep the server-authoritative fling.
		-- Physics state stops any controller fighting the launch; ownership must
		-- come last (the API allows it now that the humanoid is dead).
		pcall(function()
			humanoid:ChangeState(Enum.HumanoidStateType.Physics)
		end)
		for _, part in character:GetDescendants() do
			if part:IsA("BasePart") then
				pcall(part.SetNetworkOwner, part, nil)
				part.AssemblyLinearVelocity = velocity
				part.AssemblyAngularVelocity = spin
			end
		end
	end
end

return RagdollService
