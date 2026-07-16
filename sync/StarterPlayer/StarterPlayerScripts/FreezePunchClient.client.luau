--[[
	FreezePunchClient — freeze-punch input (server logic in FreezePunchService).

	Press F / gamepad Y, or tap the Ability Box (via FreezePunchBridge), while you
	hold the Freeze Punch ability as an alive participant to swing; the server freezes
	the nearest participant in range. This client forwards the swing, lights the
	button, and paints the nearest target with the same RED aiming Highlight Push
	uses (mirror of PushClient's PushTarget) so you can see who you'll freeze — the
	server still picks + validates the victim.

	HUD bridge (same idiom as PushBridge): the FreezePunchBridge BindableEvent in
	ReplicatedStorage:
		Enabled          bool    Freeze Punch equipped + you can swing right now
		HasTarget        bool    someone is in range (button bright vs dim)
		CooldownDuration number  FREEZE_PUNCH.COOLDOWN
		ReadyAt          number  os.clock() when the local cooldown lapses
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Bullrush.Config)
local Remotes = ReplicatedStorage.Bullrush.Remotes

local CFG = Config.FREEZE_PUNCH
local player = Players.LocalPlayer

local punchRemote = Remotes:WaitForChild("FreezePunch")
local roundStateRemote = Remotes:WaitForChild("RoundState")

local bridge = Instance.new("BindableEvent")
bridge.Name = "FreezePunchBridge"
bridge:SetAttribute("Enabled", false)
bridge:SetAttribute("HasTarget", false)
bridge:SetAttribute("CooldownDuration", CFG.COOLDOWN)
bridge:SetAttribute("ReadyAt", 0)
bridge.Parent = ReplicatedStorage

--==============================================================================
-- Red target aura: one reusable Highlight (the twin of PushClient's PushTarget)
-- whose Adornee tracks the nearest freeze target. Kept in a client-only workspace
-- folder and driven by Adornee (never parented to the victim) so a target leaving
-- / respawning just clears the Adornee to nil instead of destroying our instance.
--==============================================================================

local fxHost = Instance.new("Folder")
fxHost.Name = "FreezePunchClientFX"
fxHost.Parent = Workspace

local targetHighlight = Instance.new("Highlight")
targetHighlight.Name = "FreezePunchTarget"
targetHighlight.FillColor = Color3.fromRGB(255, 0, 0)
targetHighlight.FillTransparency = 0.3
targetHighlight.OutlineColor = Color3.fromRGB(255, 30, 30)
targetHighlight.OutlineTransparency = 0
targetHighlight.DepthMode = Enum.HighlightDepthMode.Occluded
targetHighlight.Adornee = nil
targetHighlight.Parent = fxHost

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
	return (player:GetAttribute("EquippedAbility") or "Push") == "FreezePunch"
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

local function getBotsFolder(): Instance?
	local arena = Workspace:FindFirstChild("BullrushArena")
	return arena and arena:FindFirstChild("Bots")
end

local function planarDist(a: Vector3, b: Vector3): number
	return (Vector3.new(a.X - b.X, 0, a.Z - b.Z)).Magnitude
end

-- Alive, targetable character's root, or nil. Skips a character BullrushClient has
-- hidden from us (an eliminated ghost: LocalTransparencyModifier ~= 0), matching
-- PushClient's red-target rules.
local function livingRoot(character: Model): BasePart?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and root and root.LocalTransparencyModifier < 0.9 then
		return root
	end
	return nil
end

-- Nearest OTHER living participant within CFG.RANGE (players + bots), planar. The
-- SERVER makes the authoritative pick with the same nearest-in-range rule, so this
-- red highlight always paints exactly who the punch will freeze.
local function findNearest(from: Vector3): Model?
	local bestChar, bestDist = nil, CFG.RANGE

	for _, other in Players:GetPlayers() do
		if other ~= player and other.Character then
			local root = livingRoot(other.Character)
			if root then
				local d = planarDist(from, root.Position)
				if d <= bestDist then
					bestChar, bestDist = other.Character, d
				end
			end
		end
	end

	local folder = getBotsFolder()
	if folder then
		for _, rig in folder:GetChildren() do
			if rig:IsA("Model") then
				local root = livingRoot(rig)
				if root then
					local d = planarDist(from, root.Position)
					if d <= bestDist then
						bestChar, bestDist = rig, d
					end
				end
			end
		end
	end

	return bestChar
end

local currentTarget: Model? = nil

-- Point the red highlight at the current freeze target (or clear it). HasTarget
-- also drives the Ability Box's bright/dim look, same as before.
local function setTarget(character: Model?)
	currentTarget = character
	targetHighlight.Adornee = character
	bridge:SetAttribute("HasTarget", character ~= nil)
end

roundStateRemote.OnClientEvent:Connect(function(state: string)
	roundActive = state == "ACTIVE"
	if not roundActive then
		-- Round lapsed: drop any target now so nothing lingers highlighted (the
		-- scan will also hide the button once we stop participating).
		setTarget(nil)
	end
end)

local SCAN = 0.12
local lastScan = 0
RunService.Heartbeat:Connect(function()
	local now = os.clock()
	if now - lastScan < SCAN then
		return
	end
	lastScan = now
	-- The red target highlight + button only light up while Freeze Punch is the
	-- equipped ability and you're an ACTIVE-round (or practice) participant; any
	-- other ability equipped, or the lobby, and this stays dark.
	local on = isEquipped() and isParticipating()
	bridge:SetAttribute("Enabled", on)
	if not on then
		if currentTarget then
			setTarget(nil)
		end
		return
	end
	local root = localRoot() :: BasePart
	setTarget(findNearest(root.Position))
end)

local function attemptPunch()
	if not (isEquipped() and isParticipating()) then
		return
	end
	if os.clock() < readyAt then
		return
	end
	punchRemote:FireServer()
	readyAt = os.clock() + CFG.COOLDOWN
	bridge:SetAttribute("ReadyAt", readyAt)
end

bridge.Event:Connect(attemptPunch)

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end
	if input.KeyCode == Enum.KeyCode.F or input.KeyCode == Enum.KeyCode.ButtonY then
		attemptPunch()
	end
end)
