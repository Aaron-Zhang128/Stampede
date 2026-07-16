--[[
	ShockwaveService — shockwave ability (server-authoritative gate; ragdoll applied per-owner).

	An alive participant SLAMS the ground (Shockwave remote). Every OTHER participant
	within SHOCKWAVE.RADIUS is knocked down — ragdolled for SHOCKWAVE.RAGDOLL_TIME
	seconds, then they stand back up (NON-lethal, unlike a bull hit). Real players
	ragdoll on their OWN client (Shockwaved -> ShockwaveClient, so the flop is
	client-owned + smooth); server-owned bots are ragdolled here.

	Server-enforced: the slammer must be alive in the round (or in practice), hold
	the Shockwave ability equipped, and be off cooldown.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Bullrush.Config)
local RagdollUtil = require(ReplicatedStorage.Bullrush.RagdollUtil)
local Remotes = ReplicatedStorage.Bullrush.Remotes
local AIService = require(script.Parent.AIService)
local RoundService = require(script.Parent.RoundService)
local NotifyService = require(script.Parent.NotifyService)
local SoundService = game:GetService("SoundService")

-- Positional one-shot from the curated GameSFX library, parented to `at` so it
-- plays in 3D at the effect and every nearby client hears it (server-built, same
-- idiom as PushService.playImpactSound). Silent if the library sound is missing.
local function playSfxAt(name: string, at: BasePart?)
	if not at then
		return
	end
	local group = SoundService:FindFirstChild("GameSFX")
	local template = group and group:FindFirstChild(name)
	if not (template and template:IsA("Sound")) then
		return
	end
	local ok, sound = pcall(function()
		return template:Clone()
	end)
	if not ok or not sound then
		return
	end
	sound.Looped = false
	sound.RollOffMaxDistance = 100
	sound.Parent = at
	pcall(function()
		sound:Play()
	end)
	task.delay(6, function()
		if sound then
			sound:Destroy()
		end
	end)
end

local ShockwaveService = {}

local CFG = Config.SHOCKWAVE
local KNOCK_SPEED = 24 -- small outward shove so the knockdown reads as a hit, not a faint
local lastUseAt: { [Player]: number } = {}

local function ensureRemote(name: string): RemoteEvent
	local remote = Remotes:FindFirstChild(name)
	if not (remote and remote:IsA("RemoteEvent")) then
		remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = Remotes
	end
	return remote
end
local slamRemote = ensureRemote("Shockwave") -- client -> server: activate
local downRemote = ensureRemote("Shockwaved") -- server -> victim client: knockdown velocity

-- Works on real Players and bot proxies alike (both expose .Character).
local function rootOf(participant): BasePart?
	local character = participant.Character
	return character and character:FindFirstChild("HumanoidRootPart")
end

local function isAliveParticipant(participant): boolean
	if RoundService.isAlive(participant) then
		return true
	end
	return typeof(participant) == "Instance"
		and participant:IsA("Player")
		and participant:GetAttribute("InPractice") == true
end

-- The slammer additionally has to hold Shockwave equipped.
local function canUse(caster: Player): boolean
	if caster:GetAttribute("EquippedAbility") ~= "Shockwave" then
		return false
	end
	return isAliveParticipant(caster)
end

local function getBotsFolder(): Instance?
	local arena = Workspace:FindFirstChild("BullrushArena")
	return arena and arena:FindFirstChild("Bots")
end

-- Expanding neon ground ring so the slam reads for everyone.
local function slamFx(position: Vector3)
	local ring = Instance.new("Part")
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.Material = Enum.Material.Neon
	ring.Color = Color3.fromRGB(150, 205, 255)
	ring.Transparency = 0.15
	ring.Size = Vector3.new(1, 4, 4)
	ring.CFrame = CFrame.new(position - Vector3.new(0, 2.6, 0)) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent = Workspace
	TweenService:Create(ring, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(1, CFG.RADIUS * 2, CFG.RADIUS * 2),
		Transparency = 1,
	}):Play()
	Debris:AddItem(ring, 0.6)
end

-- Outward knockdown velocity from the slam origin toward the victim's root.
local function knockdownVelocity(origin: Vector3, targetRoot: BasePart): Vector3
	local offset = targetRoot.Position - origin
	local flat = Vector3.new(offset.X, 0, offset.Z)
	local dir = if flat.Magnitude > 0.1 then flat.Unit else Vector3.new(0, 0, 1)
	return Vector3.new(dir.X * KNOCK_SPEED, CFG.UP, dir.Z * KNOCK_SPEED)
end

-- Public so tests / other systems can trigger a slam directly.
function ShockwaveService.activate(caster: Player)
	if not canUse(caster) then
		return
	end
	local now = os.clock()
	local last = lastUseAt[caster]
	if last and now - last < CFG.COOLDOWN then
		return
	end
	local casterRoot = rootOf(caster)
	if not casterRoot then
		return
	end
	lastUseAt[caster] = now

	local origin = casterRoot.Position
	slamFx(origin)
	playSfxAt("Shockwave SFX (1)", casterRoot)
	NotifyService.send(caster, "Shockwave!", "green", 1.5)

	local function tryHit(participant, isBot: boolean)
		if participant == caster or not isAliveParticipant(participant) then
			return -- the slammer is spared; only living participants get knocked down
		end
		local root = rootOf(participant)
		if not root or (root.Position - origin).Magnitude > CFG.RADIUS then
			return
		end
		local vel = knockdownVelocity(origin, root)
		if isBot then
			local character = participant.Character
			RagdollUtil.ragdoll(character, vel)
			participant.busyUntil = math.max(participant.busyUntil or 0, os.clock() + CFG.RAGDOLL_TIME + 0.5)
			task.delay(CFG.RAGDOLL_TIME, function()
				RagdollUtil.recover(character)
			end)
		else
			-- Real player owns their character: their client flops + recovers itself.
			downRemote:FireClient(participant, vel)
			RoundService.notePush(participant, caster) -- credit the kill if this leads to a death
		end
	end

	for _, other in Players:GetPlayers() do
		tryHit(other, false)
	end
	local folder = getBotsFolder()
	if folder then
		for _, rig in folder:GetChildren() do
			if rig:IsA("Model") then
				local proxy = AIService.findByCharacter(rig)
				if proxy then
					tryHit(proxy, true)
				end
			end
		end
	end
end

function ShockwaveService.init()
	slamRemote.OnServerEvent:Connect(function(caster: Player)
		ShockwaveService.activate(caster)
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastUseAt[player] = nil
	end)
end

return ShockwaveService
