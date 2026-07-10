--[[
	PushClient — proximity shove targeting + input (server rules live in PushService).

	Reworked (2026-07-09): the old per-player "Push" ProximityPrompt is gone.
	Instead, while a round is ACTIVE and you're alive, the NEAREST other
	participant within PUSH.RANGE is highlighted RED — the mirror of your own
	green SelfAura (BullrushClient) — and you shove them with F (keyboard),
	gamepad Y, or the HUD push button. Only the single nearest target is ever
	highlighted, and only that one is pushed.

	UI / gameplay split (per the one-LocalScript UI rule): the HUD push button
	lives in StarterGui.Main. It talks to this script through the PushBridge
	BindableEvent in ReplicatedStorage — the same idiom as RevengeViewBridge:
	  * the button fires PushBridge (a tap) -> we attempt a push
	  * we broadcast state back via PushBridge attributes that drive the
	    button's look + cooldown sweep:
	        Enabled          bool    round ACTIVE and you're alive (button shown)
	        HasTarget        bool    a target is highlighted (button bright vs dim)
	        CooldownDuration number  PUSH.COOLDOWN, so the sweep knows its length
	        ReadyAt          number  os.clock() when the local cooldown lapses

	Still calls ExpressivePrompts.Init(): the lobby shop door, fortune wheel and
	bull-cam pad all use Custom-styled ProximityPrompts dressed by it.

	Getting shoved is unchanged: the server fires Remotes.Pushed and we apply the
	knockback burst to our own character (movement is client-authoritative, same
	idiom as BullrushDash).

	Bots (Workspace.BullrushArena.Bots) can be targeted too, so the shove is
	testable solo; we send the rig Model and the SERVER applies the knockback
	(bot rigs are server-owned). Bots never push back.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Bullrush.Config)
local ExpressivePrompts = require(ReplicatedStorage.ExpressivePrompts)
local Remotes = ReplicatedStorage.Bullrush.Remotes

local PUSH = Config.PUSH
local player = Players.LocalPlayer

-- Fancy custom UI for every Custom-styled ProximityPrompt in the game (shop
-- door, fortune wheel, bull-cam pad). The push system no longer uses prompts,
-- but this installer must stay live for the ones that do.
ExpressivePrompts.Init()

--==============================================================================
-- HUD bridge: the StarterGui.Main push button drives us through this local
-- BindableEvent (never replicates). Fire() = a tap; the attributes broadcast
-- our state back to the button. Mirrors ReplicatedStorage.RevengeViewBridge.
--==============================================================================

local pushBridge = Instance.new("BindableEvent")
pushBridge.Name = "PushBridge"
pushBridge:SetAttribute("Enabled", false)
pushBridge:SetAttribute("HasTarget", false)
pushBridge:SetAttribute("CooldownDuration", PUSH.COOLDOWN)
pushBridge:SetAttribute("ReadyAt", 0)
pushBridge.Parent = ReplicatedStorage

--==============================================================================
-- Red target aura: one reusable Highlight whose Adornee tracks the current
-- nearest target. Kept in a client-only workspace folder and driven by Adornee
-- (NOT by parenting to the character) so a target leaving / respawning can
-- never destroy our single instance — Adornee just clears to nil.
--==============================================================================

local fxHost = Instance.new("Folder")
fxHost.Name = "PushClientFX"
fxHost.Parent = Workspace

local targetHighlight = Instance.new("Highlight")
targetHighlight.Name = "PushTarget"
targetHighlight.FillColor = Color3.fromRGB(255, 70, 70)
targetHighlight.FillTransparency = 0.82
targetHighlight.OutlineColor = Color3.fromRGB(255, 120, 120)
targetHighlight.OutlineTransparency = 0.1
targetHighlight.DepthMode = Enum.HighlightDepthMode.Occluded
targetHighlight.Adornee = nil
targetHighlight.Parent = fxHost

--==============================================================================
-- State
--==============================================================================

local roundActive = false
local currentTarget: any = nil -- Player (real) or bot rig Model, or nil
local readyAt = 0 -- os.clock() when the local push cooldown lapses

--==============================================================================
-- Targeting: nearest living participant within PUSH.RANGE (planar distance).
--==============================================================================

local function localRoot(): BasePart?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and root then
		return root
	end
	return nil
end

-- Alive, targetable character's root, or nil. Skips a character BullrushClient
-- has hidden from us (an eliminated ghost: LocalTransparencyModifier ~= 0) —
-- the server would reject shoving a non-participant anyway, so don't waste the
-- highlight / cooldown on one.
local function livingRoot(character: Model): BasePart?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and root and root.LocalTransparencyModifier < 0.9 then
		return root
	end
	return nil
end

local function getBotsFolder(): Instance?
	local arena = Workspace:FindFirstChild("BullrushArena")
	return arena and arena:FindFirstChild("Bots")
end

local function planarDist(a: Vector3, b: Vector3): number
	return (Vector3.new(a.X - b.X, 0, a.Z - b.Z)).Magnitude
end

-- Returns (participant, character): participant is the Player (real) or the rig
-- Model (bot) — that's what we hand PushService — and character is the Model to
-- highlight. Nil when nothing is in range.
local function findNearest(from: Vector3)
	local best, bestChar, bestDist = nil, nil, PUSH.RANGE

	for _, other in Players:GetPlayers() do
		if other ~= player and other.Character then
			local root = livingRoot(other.Character)
			if root then
				local d = planarDist(from, root.Position)
				if d <= bestDist then
					best, bestChar, bestDist = other, other.Character, d
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
						best, bestChar, bestDist = rig, rig, d
					end
				end
			end
		end
	end

	return best, bestChar
end

local function setTarget(participant, character)
	currentTarget = participant
	targetHighlight.Adornee = character
	pushBridge:SetAttribute("HasTarget", participant ~= nil)
end

-- Re-evaluate the nearest target on a light throttle (a handful of participants,
-- so ~12Hz is plenty and the Highlight follows the model between scans).
local SCAN_INTERVAL = 0.08
local lastScan = 0

RunService.Heartbeat:Connect(function()
	local now = os.clock()
	if now - lastScan < SCAN_INTERVAL then
		return
	end
	lastScan = now

	-- The button is shown whenever you're alive (so you can always see it, even
	-- in the lobby, dimmed); targeting + pushing only happen during an ACTIVE
	-- round, so a lapsed round just clears the target and dims the button.
	local root = localRoot()
	pushBridge:SetAttribute("Enabled", root ~= nil)
	if not (roundActive and root) then
		if currentTarget then
			setTarget(nil, nil)
		end
		return
	end

	local participant, character = findNearest(root.Position)
	setTarget(participant, character)
end)

--==============================================================================
-- Round state: shoving only works while a round is ACTIVE.
--==============================================================================

Remotes.RoundState.OnClientEvent:Connect(function(state: string)
	roundActive = state == "ACTIVE"
	if not roundActive then
		-- keep the button visible (the scan re-asserts Enabled from "alive"); just
		-- drop any target so it dims out.
		setTarget(nil, nil)
	end
end)

--==============================================================================
-- The shove: F / gamepad Y / the HUD button all funnel here. The server
-- re-validates everything (alive-in-round, cooldown, distance), so the local
-- cooldown gate is purely so the button's sweep matches what will be accepted.
--==============================================================================

local function attemptPush()
	if not roundActive then
		return
	end
	if os.clock() < readyAt then
		return -- still cooling down locally
	end
	local target = currentTarget
	if not target then
		return -- nobody in range
	end
	Remotes.Push:FireServer(target) -- Player, or a bot rig Model
	readyAt = os.clock() + PUSH.COOLDOWN
	pushBridge:SetAttribute("ReadyAt", readyAt)
end

-- HUD button tap.
pushBridge.Event:Connect(attemptPush)

-- Keyboard F / gamepad Y.
UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end
	if input.KeyCode == Enum.KeyCode.F or input.KeyCode == Enum.KeyCode.ButtonY then
		attemptPush()
	end
end)

--==============================================================================
-- Getting shoved: the server hands us a direction; we apply the burst to our
-- own character (client-authoritative movement, like the dash).
--==============================================================================

local function aliveRoot(): BasePart?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and root then
		return root
	end
	return nil
end

Remotes.Pushed.OnClientEvent:Connect(function(direction: Vector3)
	local root = aliveRoot()
	if not root then
		return
	end
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 0.01 then
		return
	end
	flat = flat.Unit

	-- One burst with a small upward pop, then hold the horizontal velocity for
	-- PUSH.TIME while gravity takes the vertical back over.
	root.AssemblyLinearVelocity = Vector3.new(flat.X * PUSH.SPEED, PUSH.UP, flat.Z * PUSH.SPEED)
	local startedAt = os.clock()
	local connection
	connection = RunService.Heartbeat:Connect(function()
		local nowRoot = aliveRoot()
		-- nowRoot ~= root catches death / respawn mid-knockback.
		if nowRoot ~= root or os.clock() - startedAt >= PUSH.TIME then
			connection:Disconnect()
			return
		end
		root.AssemblyLinearVelocity = Vector3.new(
			flat.X * PUSH.SPEED,
			root.AssemblyLinearVelocity.Y,
			flat.Z * PUSH.SPEED
		)
	end)
end)
