-- Banana Peel input/HUD bridge. Victim ragdoll uses BombClient's shared Mined event.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Config = require(ReplicatedStorage.Bullrush.Config)
local player = Players.LocalPlayer
local remote = ReplicatedStorage.Bullrush.Remotes:WaitForChild("DropBananaPeel")
local bridge = Instance.new("BindableEvent")
bridge.Name = "BananaPeelBridge"
bridge:SetAttribute("Enabled", false)
bridge:SetAttribute("CooldownDuration", Config.BANANA_PEEL.COOLDOWN)
bridge:SetAttribute("ReadyAt", 0)
bridge.Parent = ReplicatedStorage
local readyAt = 0
local function participating(): boolean
	return player:GetAttribute("EquippedAbility") == "BananaPeel"
		and (player:GetAttribute("InRound") == true or player:GetAttribute("InPractice") == true)
end
local function refresh() bridge:SetAttribute("Enabled", participating()) end
local function drop()
	if not participating() or os.clock() < readyAt then return end
	remote:FireServer()
	readyAt = os.clock() + Config.BANANA_PEEL.COOLDOWN
	bridge:SetAttribute("ReadyAt", readyAt)
end
bridge.Event:Connect(drop)
UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and (input.KeyCode == Enum.KeyCode.F or input.KeyCode == Enum.KeyCode.ButtonY) then drop() end
end)
for _, attr in { "EquippedAbility", "InRound", "InPractice" } do player:GetAttributeChangedSignal(attr):Connect(refresh) end
refresh()
