-- Server-authoritative Banana Peel trap. One victim, recoverable ragdoll, owner-safe.
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local Config = require(ReplicatedStorage.Bullrush.Config)
local RagdollUtil = require(ReplicatedStorage.Bullrush.RagdollUtil)
local AIService = require(script.Parent.AIService)
local RoundService = require(script.Parent.RoundService)
local Remotes = ReplicatedStorage.Bullrush.Remotes
local CFG = Config.BANANA_PEEL
local lastDrop: { [Player]: number } = {}
local function ensureRemote(name: string): RemoteEvent
	local remote = Remotes:FindFirstChild(name)
	if not (remote and remote:IsA("RemoteEvent")) then
		remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = Remotes
	end
	return remote
end
local dropRemote = ensureRemote("DropBananaPeel")
local minedRemote = ensureRemote("Mined")
local function canUse(participant): boolean
	return RoundService.isAlive(participant) or (typeof(participant) == "Instance"
		and participant:IsA("Player") and participant:GetAttribute("InPractice") == true)
end
local function participantFromPart(part: BasePart)
	local character = part:FindFirstAncestorOfClass("Model")
	if not character then return nil, false end
	local player = Players:GetPlayerFromCharacter(character)
	if player then return player, false end
	local bot = AIService.findByCharacter(character)
	return bot, bot ~= nil
end
local function playSlipSound(root: BasePart?)
	local group = SoundService:FindFirstChild("GameSFX")
	local template = group and group:FindFirstChild("banana peel slip")
	if not root or not (template and template:IsA("Sound")) then return end
	local sound = template:Clone()
	sound.Looped = false
	sound.TimePosition = 0
	sound.RollOffMaxDistance = 80
	sound.Parent = root
	sound:Play()
	-- The supplied clip is longer; Banana Peel intentionally uses only its first second.
	task.delay(1, function()
		if sound.Parent then
			sound:Stop()
			sound:Destroy()
		end
	end)
end
local function playThrowSound(root: BasePart)
	local group = SoundService:FindFirstChild("GameSFX")
	local template = group and group:FindFirstChild("banana peel throw")
	if not (template and template:IsA("Sound")) then return end
	local sound = template:Clone()
	sound.Looped = false
	sound.TimePosition = 0
	sound.RollOffMaxDistance = 70
	sound.Parent = root
	sound:Play()
	Debris:AddItem(sound, 4)
end
local function makePeel(position: Vector3): (Model, BasePart, BasePart)
	local model = Instance.new("Model")
	model.Name = "BananaPeel"
	-- Use the designer-authored ReplicatedStorage.BananaPeel MeshPart. Keep the
	-- source untouched; every drop gets an independent gameplay-safe clone.
	local template = ReplicatedStorage:FindFirstChild("BananaPeel")
	if template and template:IsA("BasePart") then
		local peel = template:Clone()
		peel.Name = "Peel"
		peel.Anchored = false
		peel.CanCollide = true
		peel.CanTouch = true -- detects the landing; sensor owns player slips
		peel.AssemblyLinearVelocity = Vector3.zero
		peel.AssemblyAngularVelocity = Vector3.zero
		peel.CFrame = CFrame.new(position) * template.CFrame.Rotation
		peel.Parent = model
	else
		-- Defensive fallback for a place copy missing the shared asset.
		local peel = Instance.new("Part")
		peel.Name = "Peel"
		peel.Size = Vector3.new(2.5, 0.25, 2.5)
		peel.Color = Color3.fromRGB(255, 225, 35)
		peel.Anchored = false
		peel.CanCollide = true
		peel.CanTouch = true
		peel.CFrame = CFrame.new(position)
		peel.Parent = model
	end
	local visual = model:FindFirstChild("Peel") :: BasePart
	local sensor = Instance.new("Part")
	sensor.Name = "SlipZone"
	sensor.Size = Vector3.new(4, 1.5, 4)
	sensor.CFrame = visual.CFrame + Vector3.new(0, 0.65, 0)
	sensor.Transparency = 1
	sensor.Anchored = false
	sensor.CanCollide = false
	sensor.CanTouch = true
	sensor.Parent = model
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = visual
	weld.Part1 = sensor
	weld.Parent = sensor
	model.Parent = workspace
	pcall(function() visual:SetNetworkOwner(nil) end)
	return model, sensor, visual
end
local function drop(player: Player)
	if player:GetAttribute("EquippedAbility") ~= "BananaPeel" or not canUse(player) then return end
	local now = os.clock()
	if lastDrop[player] and now - lastDrop[player] < CFG.COOLDOWN then return end
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not root then return end
	lastDrop[player] = now
	playThrowSound(root)
	local look = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
	local position = root.Position - look * 2 - Vector3.new(0, 1.2, 0)
	local peel, sensor, visual = makePeel(position)
	Debris:AddItem(peel, CFG.LIFETIME)
	local armed = false
	local landed = false
	visual.Touched:Connect(function(part)
		if landed or not peel.Parent then return end
		local participant = participantFromPart(part)
		if participant == player then return end
		landed = true
		visual.AssemblyLinearVelocity = Vector3.zero
		visual.AssemblyAngularVelocity = Vector3.zero
		visual.Anchored = true
		task.delay(CFG.ARM_DELAY, function() if peel.Parent then armed = true end end)
	end)
	local connection
	connection = sensor.Touched:Connect(function(part)
		if not armed or not peel.Parent then return end
		local victim, isBot = participantFromPart(part)
		if not victim or victim == player or not canUse(victim) then return end
		armed = false
		connection:Disconnect()
		local victimRoot = victim.Character and victim.Character:FindFirstChild("HumanoidRootPart")
		local impulse = Vector3.new(0, CFG.UP, 0)
		if victimRoot then
			local flat = Vector3.new(victimRoot.Position.X - position.X, 0, victimRoot.Position.Z - position.Z)
			if flat.Magnitude > 0.1 then impulse += flat.Unit * 10 end
		end
		playSlipSound(victimRoot)
		if isBot then
			local character = victim.Character
			RagdollUtil.ragdoll(character, impulse)
			victim.busyUntil = math.max(victim.busyUntil or 0, os.clock() + CFG.RAGDOLL_TIME)
			task.delay(CFG.RAGDOLL_TIME, function() RagdollUtil.recover(character) end)
		else
			minedRemote:FireClient(victim, impulse, CFG.RAGDOLL_TIME)
			RoundService.notePush(victim, player)
		end
		peel:Destroy()
	end)
end
local BananaPeelService = {}
function BananaPeelService.init()
	dropRemote.OnServerEvent:Connect(drop)
	Players.PlayerRemoving:Connect(function(player) lastDrop[player] = nil end)
end
return BananaPeelService
