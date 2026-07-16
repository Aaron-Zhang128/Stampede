--[[
	ShockwaveClient — shockwave input + getting-knocked-down (server rules in ShockwaveService).

	Press Q / gamepad L1, or tap the Ability Box (via ShockwaveBridge), while you hold
	the Shockwave ability as an alive participant to SLAM the ground; ShockwaveService
	knocks down everyone nearby. When YOU get caught (Shockwaved), your own client
	ragdolls your character for SHOCKWAVE.RAGDOLL_TIME then stands you back up
	(client-owned, using the shared RagdollUtil).

	HUD bridge (same idiom as PushBridge): the ShockwaveBridge BindableEvent in
	ReplicatedStorage. Fire() = a tap; its attributes broadcast state to the box:
		Enabled          bool    Shockwave equipped + you can slam right now
		CooldownDuration number  SHOCKWAVE.COOLDOWN, so the sweep knows its length
		ReadyAt          number  os.clock() when the local cooldown lapses
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage.Bullrush.Config)
local RagdollUtil = require(ReplicatedStorage.Bullrush.RagdollUtil)
local Remotes = ReplicatedStorage.Bullrush.Remotes

local CFG = Config.SHOCKWAVE
local player = Players.LocalPlayer

-- Created by ShockwaveService at runtime (absent in edit mode), so wait for them.
local slamRemote = Remotes:WaitForChild("Shockwave")
local downRemote = Remotes:WaitForChild("Shockwaved")
local roundStateRemote = Remotes:WaitForChild("RoundState")

--==============================================================================
-- HUD bridge (never replicates); mirrors ReplicatedStorage.PushBridge.
--==============================================================================

local bridge = Instance.new("BindableEvent")
bridge.Name = "ShockwaveBridge"
bridge:SetAttribute("Enabled", false)
bridge:SetAttribute("CooldownDuration", CFG.COOLDOWN)
bridge:SetAttribute("ReadyAt", 0)
bridge.Parent = ReplicatedStorage

local roundActive = false
local readyAt = 0

local function localRoot(): BasePart?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and root then
		return root
	end
	return nil
end

local function isEquipped(): boolean
	return (player:GetAttribute("EquippedAbility") or "Push") == "Shockwave"
end

local function isParticipating(): boolean
	if localRoot() == nil then
		return false
	end
	if player:GetAttribute("InPractice") == true then
		return true
	end
	return roundActive and player:GetAttribute("InRound") == true
end

roundStateRemote.OnClientEvent:Connect(function(state: string)
	roundActive = state == "ACTIVE"
end)

-- Keep the HUD button's Enabled flag in step on a light throttle.
local SCAN = 0.12
local lastScan = 0
RunService.Heartbeat:Connect(function()
	local now = os.clock()
	if now - lastScan < SCAN then
		return
	end
	lastScan = now
	bridge:SetAttribute("Enabled", isEquipped() and isParticipating())
end)

local function attemptSlam()
	if not (isEquipped() and isParticipating()) then
		return
	end
	if os.clock() < readyAt then
		return
	end
	slamRemote:FireServer()
	readyAt = os.clock() + CFG.COOLDOWN
	bridge:SetAttribute("ReadyAt", readyAt)
end

bridge.Event:Connect(attemptSlam)

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end
	if input.KeyCode == Enum.KeyCode.F or input.KeyCode == Enum.KeyCode.ButtonY then
		attemptSlam()
	end
end)

--==============================================================================
-- Getting knocked down: flop our own character for RAGDOLL_TIME, then get up.
--==============================================================================

downRemote.OnClientEvent:Connect(function(velocity: Vector3)
	local character = player.Character
	if not character then
		return
	end
	RagdollUtil.ragdoll(character, velocity)
	task.delay(CFG.RAGDOLL_TIME, function()
		if player.Character == character then
			RagdollUtil.recover(character)
		end
	end)
end)
