--[[
	PushClient - the "Push" shove prompt (server rules live in PushService).

	Installs ExpressivePrompts (the custom ProximityPrompt UI dropped into
	ReplicatedStorage) and puts a tap-to-trigger "Push" prompt over every OTHER
	player. Prompts are enabled only while the round is ACTIVE (Remotes.RoundState).

	Each prompt is created locally on THIS client and parented under another
	player's character, so it exists only for us - we never see one over our own
	head, and only we can trigger the ones we made. Triggering asks the server to
	shove that player.

	When WE get shoved, the server fires Remotes.Pushed back at us and we apply the
	knockback burst to our own character. Movement is client-authoritative, so the
	owning client drives the physics (same idiom as BullrushDash) and it replicates
	to everyone else.

	Bot rigs (Workspace.BullrushArena.Bots) get the same prompt so the shove is
	testable solo; triggering sends the rig Model and the SERVER applies the
	knockback (bots are server-owned). Bots never push back.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Bullrush.Config)
local ExpressivePrompts = require(ReplicatedStorage.ExpressivePrompts)
local Remotes = ReplicatedStorage.Bullrush.Remotes

local PUSH = Config.PUSH
local player = Players.LocalPlayer

-- Fancy custom UI for every Custom-styled ProximityPrompt in the game.
ExpressivePrompts.Init()

--==============================================================================
-- Round state: the shove prompts only work while a round is ACTIVE.
--==============================================================================

local roundActive = false
local prompts: { [Player]: ProximityPrompt } = {}
local botPrompts: { [Model]: ProximityPrompt } = {}

local function refreshEnabled()
	for _, prompt in prompts do
		if prompt.Parent then -- skip prompts destroyed with an old character
			prompt.Enabled = roundActive
		end
	end
	for _, prompt in botPrompts do
		if prompt.Parent then
			prompt.Enabled = roundActive
		end
	end
end

Remotes.RoundState.OnClientEvent:Connect(function(state: string)
	roundActive = state == "ACTIVE"
	refreshEnabled()
end)

--==============================================================================
-- A "Push" prompt over every other player, refreshed each time they respawn.
--==============================================================================

local function attachPrompt(other: Player, character: Model)
	if other == player then
		return
	end
	local adornee = character:WaitForChild("Head", 10) or character:FindFirstChild("HumanoidRootPart")
	if not adornee or not adornee.Parent then
		return
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "PushPrompt"
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.ActionText = "Push"
	prompt.ObjectText = other.DisplayName
	prompt.HoldDuration = 0 -- tap / instant
	prompt.MaxActivationDistance = PUSH.RANGE
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonY
	prompt.Enabled = roundActive
	prompt.Parent = adornee

	prompt.Triggered:Connect(function()
		Remotes.Push:FireServer(other)
	end)

	prompts[other] = prompt
end

local function trackPlayer(other: Player)
	if other == player then
		return
	end
	other.CharacterAdded:Connect(function(character)
		attachPrompt(other, character)
	end)
	if other.Character then
		attachPrompt(other, other.Character)
	end
end

for _, other in Players:GetPlayers() do
	trackPlayer(other)
end
Players.PlayerAdded:Connect(trackPlayer)
Players.PlayerRemoving:Connect(function(other)
	prompts[other] = nil
end)

--==============================================================================
-- Same prompt over every bot rig, so the shove is testable solo. AIService
-- rebuilds the rigs each round; prompts die with them.
--==============================================================================

local function attachBotPrompt(rig: Instance)
	if not rig:IsA("Model") or botPrompts[rig] then
		return
	end
	local adornee = rig:WaitForChild("Head", 10) or rig:FindFirstChild("HumanoidRootPart")
	if not adornee or not adornee.Parent then
		return
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "PushPrompt"
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.ActionText = "Push"
	prompt.ObjectText = rig.Name
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = PUSH.RANGE
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonY
	prompt.Enabled = roundActive
	prompt.Parent = adornee

	prompt.Triggered:Connect(function()
		Remotes.Push:FireServer(rig) -- bot proxies never replicate, so send the rig
	end)

	botPrompts[rig] = prompt
	rig.Destroying:Connect(function()
		botPrompts[rig] = nil
	end)
end

local function watchBotsFolder(folder: Instance)
	folder.ChildAdded:Connect(attachBotPrompt)
	for _, rig in folder:GetChildren() do
		task.spawn(attachBotPrompt, rig)
	end
end

task.spawn(function()
	local arena = Workspace:WaitForChild("BullrushArena", 30) or Workspace
	local folder = arena:FindFirstChild("Bots")
	if folder then
		watchBotsFolder(folder)
	end
	arena.ChildAdded:Connect(function(child)
		if child.Name == "Bots" and child:IsA("Folder") then
			watchBotsFolder(child)
		end
	end)
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
