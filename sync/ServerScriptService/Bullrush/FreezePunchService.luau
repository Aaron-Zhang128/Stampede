--[[
	FreezePunchService — freeze-punch ability (server-authoritative).

	A melee punch (Push's reach) that FREEZES the nearest participant solid for
	FREEZE_PUNCH.FREEZE_TIME seconds instead of launching them: WalkSpeed 0, jump
	locked, root anchored, wrapped in an ice block — then released. The puncher must
	be alive in the round (or practice), hold Freeze Punch equipped, and be off
	cooldown. The SERVER picks + validates the victim (nearest in range), so the
	client's aim is only a HUD hint.

	A per-victim generation token guards the thaw so an overlapping freeze / respawn
	can never restore stale movement values (same idiom as SpeedBoostService).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Bullrush.Config)
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
	-- Freeze's library template is a quiet 0.5; the raw clone was easy to miss, so
	-- crank it well above the template and hold full volume close in (same "make the
	-- hit read" intent as PushService.playImpactSound, just a bigger lift).
	sound.Volume = 3
	sound.RollOffMinDistance = 15
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

local FreezePunchService = {}

local CFG = Config.FREEZE_PUNCH
local lastUseAt: { [Player]: number } = {}
-- victim -> { token, walk, jumpP, jumpH, autoRotate, anchored }
local frozen: { [any]: any } = {}
local tokens: { [any]: number } = {}

local function ensureRemote(name: string): RemoteEvent
	local remote = Remotes:FindFirstChild(name)
	if not (remote and remote:IsA("RemoteEvent")) then
		remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = Remotes
	end
	return remote
end
local punchRemote = ensureRemote("FreezePunch") -- client -> server: swing

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

local function canUse(puncher: Player): boolean
	if puncher:GetAttribute("EquippedAbility") ~= "FreezePunch" then
		return false
	end
	return isAliveParticipant(puncher)
end

local function getBotsFolder(): Instance?
	local arena = Workspace:FindFirstChild("BullrushArena")
	return arena and arena:FindFirstChild("Bots")
end

-- A translucent ice block around the victim while frozen.
local function addIce(character: Model)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or character:FindFirstChild("FreezeIce") then
		return
	end
	local ice = Instance.new("Part")
	ice.Name = "FreezeIce"
	ice.Size = Vector3.new(4.5, 6.5, 4.5)
	ice.CFrame = root.CFrame
	ice.Anchored = false
	ice.CanCollide = false
	ice.CanQuery = false
	ice.CanTouch = false
	ice.Material = Enum.Material.Ice
	ice.Color = Color3.fromRGB(175, 225, 255)
	ice.Transparency = 0.45
	ice.Parent = character
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = ice
	weld.Parent = ice
end

local function removeIce(character: Model)
	local ice = character:FindFirstChild("FreezeIce")
	if ice then
		ice:Destroy()
	end
end

local function thaw(victim, token: number)
	local s = frozen[victim]
	if not s or s.token ~= token then
		return
	end
	frozen[victim] = nil
	if typeof(victim) == "Instance" then
		victim:SetAttribute("Frozen", nil)
	end
	local character = victim.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid then
		humanoid.WalkSpeed = s.walk
		humanoid.JumpPower = s.jumpP
		humanoid.JumpHeight = s.jumpH
		humanoid.AutoRotate = s.autoRotate
	end
	if root then
		root.Anchored = s.anchored
	end
	if character then
		removeIce(character)
	end
end

local function freeze(victim)
	local character = victim.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root then
		return
	end

	local token = (tokens[victim] or 0) + 1
	tokens[victim] = token

	-- Capture the pre-freeze values only if not already frozen, so a re-freeze
	-- never restores WalkSpeed 0 later.
	if not frozen[victim] then
		frozen[victim] = {
			walk = humanoid.WalkSpeed,
			jumpP = humanoid.JumpPower,
			jumpH = humanoid.JumpHeight,
			autoRotate = humanoid.AutoRotate,
			anchored = root.Anchored,
		}
	end
	frozen[victim].token = token

	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0
	humanoid.JumpHeight = 0
	humanoid.AutoRotate = false
	root.Anchored = true
	if typeof(victim) == "Instance" then
		victim:SetAttribute("Frozen", true)
	else
		-- Bot proxy: keep the AI from steering it while iced.
		victim.busyUntil = math.max(victim.busyUntil or 0, os.clock() + CFG.FREEZE_TIME + 0.3)
	end
	addIce(character)
	playSfxAt("Freeze - Ice", root)

	task.delay(CFG.FREEZE_TIME, function()
		thaw(victim, token)
	end)
end

-- Nearest OTHER alive participant within RANGE of the puncher (players + bots).
local function nearestVictim(puncher: Player)
	local pRoot = rootOf(puncher)
	if not pRoot then
		return nil
	end
	local best, bestDist = nil, nil
	local function consider(participant)
		if participant == puncher or not isAliveParticipant(participant) then
			return
		end
		local r = rootOf(participant)
		if not r then
			return
		end
		local d = (r.Position - pRoot.Position).Magnitude
		if d <= CFG.RANGE and (bestDist == nil or d < bestDist) then
			best, bestDist = participant, d
		end
	end
	for _, other in Players:GetPlayers() do
		consider(other)
	end
	local folder = getBotsFolder()
	if folder then
		for _, rig in folder:GetChildren() do
			if rig:IsA("Model") then
				local proxy = AIService.findByCharacter(rig)
				if proxy then
					consider(proxy)
				end
			end
		end
	end
	return best
end

-- Public so tests can drive it directly.
function FreezePunchService.requestPunch(puncher: Player)
	if not canUse(puncher) then
		return
	end
	local now = os.clock()
	local last = lastUseAt[puncher]
	if last and now - last < CFG.COOLDOWN then
		return
	end
	lastUseAt[puncher] = now

	local victim = nearestVictim(puncher)
	if victim then
		freeze(victim)
		-- Credit the KILL: if the freeze gets them killed (bull / fall) within the
		-- window, the puncher earns it (ABILITY_KILL_REWARD in RoundService.eliminate).
		if typeof(victim) == "Instance" and victim:IsA("Player") then
			RoundService.notePush(victim, puncher)
			-- Tell the victim who froze them (mirror of Push's "X shoved you!").
			NotifyService.send(victim, puncher.DisplayName .. " froze YOU!", "red", 2)
		end
		NotifyService.send(puncher, "Frozen!", "green", 1.5)
	else
		NotifyService.send(puncher, "Missed!", "red", 1.2)
	end
end

function FreezePunchService.init()
	punchRemote.OnServerEvent:Connect(function(puncher: Player)
		FreezePunchService.requestPunch(puncher)
	end)

	-- Respawn: the fresh character resets its own movement, so just drop our
	-- bookkeeping (a pending thaw then no-ops on the token check).
	local function hookCharacter(player: Player)
		player.CharacterAdded:Connect(function()
			frozen[player] = nil
			player:SetAttribute("Frozen", nil)
		end)
	end
	for _, player in Players:GetPlayers() do
		hookCharacter(player)
	end
	Players.PlayerAdded:Connect(hookCharacter)

	Players.PlayerRemoving:Connect(function(player)
		lastUseAt[player] = nil
		frozen[player] = nil
		tokens[player] = nil
	end)
end

return FreezePunchService
