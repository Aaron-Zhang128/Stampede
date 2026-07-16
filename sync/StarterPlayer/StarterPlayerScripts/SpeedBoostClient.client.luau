--[[
	SpeedBoostClient — speed-boost ability input (server logic in SpeedBoostService).

	Press the boost key (default R / gamepad ButtonB) or the HUD boost button while
	you're an ALIVE round participant (or on the practice grid) to fire the
	SpeedBoost remote; the server raises your WalkSpeed for a few seconds and adds
	the speed-line trails.

	HUD bridge (same idiom as PushBridge): the SpeedBoostBridge BindableEvent in
	ReplicatedStorage.
		Enabled          bool    you can boost right now
		CooldownDuration number  SPEED_BOOST.COOLDOWN
		ReadyAt          number  os.clock() when the local cooldown lapses
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage.Bullrush.Config)
local Remotes = ReplicatedStorage.Bullrush.Remotes

local BOOST = Config.SPEED_BOOST
local player = Players.LocalPlayer

-- Created by SpeedBoostService at runtime (absent in edit mode), so wait for it.
local boostRemote = Remotes:WaitForChild("SpeedBoost")
local roundStateRemote = Remotes:WaitForChild("RoundState")

--==============================================================================
-- HUD bridge (never replicates); mirrors ReplicatedStorage.PushBridge.
--==============================================================================

local boostBridge = Instance.new("BindableEvent")
boostBridge.Name = "SpeedBoostBridge"
boostBridge:SetAttribute("Enabled", false)
boostBridge:SetAttribute("CooldownDuration", BOOST.COOLDOWN)
boostBridge:SetAttribute("ReadyAt", 0)
boostBridge.Parent = ReplicatedStorage

--==============================================================================
-- State + participation (same gate as PushClient)
--==============================================================================

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

local SCAN = 0.12
local lastScan = 0
RunService.Heartbeat:Connect(function()
	local now = os.clock()
	if now - lastScan < SCAN then
		return
	end
	lastScan = now
	boostBridge:SetAttribute("Enabled", isParticipating()
		and (player:GetAttribute("EquippedAbility") or "Push") == "Speed")
end)

--==============================================================================
-- Activation: R / gamepad ButtonB / the HUD button all funnel here. The server
-- re-validates (alive-in-round, cooldown), so the local cooldown gate is purely
-- so the button's sweep matches what will be accepted.
--==============================================================================

local function attemptBoost()
	if (player:GetAttribute("EquippedAbility") or "Push") ~= "Speed" then
		return -- some other ability is equipped in the Ability Box
	end
	if not isParticipating() then
		return
	end
	if os.clock() < readyAt then
		return
	end
	boostRemote:FireServer()
	readyAt = os.clock() + BOOST.COOLDOWN
	boostBridge:SetAttribute("ReadyAt", readyAt)
end

boostBridge.Event:Connect(attemptBoost)

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end
	if input.KeyCode == Enum.KeyCode.F or input.KeyCode == Enum.KeyCode.ButtonY then
		attemptBoost()
	end
end)
