--!strict
-- Stampede loading screen (ReplicatedFirst).
--
-- Lives in ReplicatedFirst so it runs and renders BEFORE the player enters the
-- world -- the whole point of "load things in properly before the user enters".
-- StarterGui GUIs only reach PlayerGui after the default load finishes, which is
-- too late, so this ScreenGui is a template here that we reparent to PlayerGui.
--
-- It holds the player behind the overlay until ALL of these are true:
--   1. game:IsLoaded()                         -- initial replication done
--   2. critical assets preloaded               -- lobby + core UI, no pop-in
--   3. the player's Character + HumanoidRootPart exists
--   4. the "DataReady" attribute is set         -- their DataStore profile loaded
--      (server sets this in Data.server, on both the clean-load and failed-load
--       paths, so we never hang; there's also a hard timeout backstop below)

local ReplicatedFirst = game:GetService("ReplicatedFirst")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ContentProvider = game:GetService("ContentProvider")
local Workspace = game:GetService("Workspace")

-- Kill Roblox's default loading screen immediately so ours is the only one shown.
pcall(function()
	ReplicatedFirst:RemoveDefaultLoadingScreen()
end)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local root = script.Parent
local frame: Frame
local screenGui: ScreenGui?

if root:IsA("ScreenGui") then
	screenGui = root
	frame = root:WaitForChild("LoadingScreenFrame") :: Frame
else
	frame = root :: Frame
	screenGui = frame:FindFirstAncestorWhichIsA("ScreenGui")
end

-- Reparent the template out of ReplicatedFirst into PlayerGui so it actually
-- renders (a ScreenGui only draws under PlayerGui). Do it up front and on top.
if screenGui then
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 1000
	screenGui.Enabled = true
	if screenGui.Parent ~= playerGui then
		screenGui.Parent = playerGui
	end
end

local imageLabel = frame:WaitForChild("ImageLabel") :: ImageLabel
local loadingText = frame:WaitForChild("LoadingText") :: TextLabel
local dot1 = frame:WaitForChild("Dot1") :: GuiObject
local dot2 = frame:WaitForChild("Dot2") :: GuiObject
local dot3 = frame:WaitForChild("Dot3") :: GuiObject

local dots = {dot1, dot2, dot3}

local DOT_UP_OFFSET = 10
local DOT_UP_TIME = 0.12
local DOT_DOWN_TIME = 0.16
local DOT_DELAY_BETWEEN = 0.08
local DOT_CYCLE_PAUSE = 0.18

-- Image ambient motion (the gentle drift) + the extra "bop" pulse on top of it.
local IMAGE_FLOAT_X = 6
local IMAGE_FLOAT_Y = 4
local IMAGE_ROTATION = 2
local IMAGE_SPEED = 1.6
local IMAGE_PULSE_AMOUNT = 0.045   -- +/- 4.5% breathing scale
local IMAGE_PULSE_SPEED = 3.2
local IMAGE_POP_TIME = 0.5         -- springy entrance

local MIN_DISPLAY_AFTER_LOADED = 1.2
local DATA_READY_TIMEOUT = 20      -- backstop: reveal even if the attr never lands
local DOT_FADE_TIME = 0.28
local LOADED_TEXT_HOLD = 0.4
local FRAME_FADE_TIME = 0.45

local running = true
local transitionStarted = false
local entranceDone = false

type DotState = {
	Object: GuiObject,
	BasePos: UDim2,
	Busy: boolean
}

local dotStates: {DotState} = {}

local function tween(obj: Instance, info: TweenInfo, props: {[string]: any})
	local tw = TweenService:Create(obj, info, props)
	tw:Play()
	return tw
end

local function ensureVisibleOnStart()
	frame.Visible = true
	imageLabel.Visible = true
	loadingText.Visible = true
	dot1.Visible = true
	dot2.Visible = true
	dot3.Visible = true
end

local function collectFadeTargets(container: Instance)
	local list = {}
	if container:IsA("GuiObject") then
		table.insert(list, container)
	end
	for _, d in ipairs(container:GetDescendants()) do
		if d:IsA("GuiObject") or d:IsA("UIStroke") or d:IsA("UIGradient") then
			table.insert(list, d)
		end
	end
	return list
end

local function fadeFrameOut()
	local fadeTargets = collectFadeTargets(frame)
	for _, obj in ipairs(fadeTargets) do
		if obj:IsA("Frame") or obj:IsA("ScrollingFrame") then
			tween(obj, TweenInfo.new(FRAME_FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				BackgroundTransparency = 1
			})
		elseif obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then
			tween(obj, TweenInfo.new(FRAME_FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				BackgroundTransparency = 1,
				TextTransparency = 1
			})
			pcall(function()
				tween(obj, TweenInfo.new(FRAME_FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
					TextStrokeTransparency = 1
				})
			end)
		elseif obj:IsA("ImageLabel") or obj:IsA("ImageButton") then
			tween(obj, TweenInfo.new(FRAME_FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				BackgroundTransparency = 1,
				ImageTransparency = 1
			})
		elseif obj:IsA("UIStroke") then
			tween(obj, TweenInfo.new(FRAME_FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Transparency = 1
			})
		end
	end

	task.wait(FRAME_FADE_TIME + 0.05)

	if screenGui then
		screenGui.Enabled = false
	end
	frame.Visible = false
	if screenGui then
		screenGui:Destroy()
	end
end

ensureVisibleOnStart()

for _, dot in ipairs(dots) do
	table.insert(dotStates, {
		Object = dot,
		BasePos = dot.Position,
		Busy = false
	})
end

local function animateDot(state: DotState)
	if state.Busy or transitionStarted then
		return
	end
	state.Busy = true

	local obj = state.Object
	if not obj or obj.Parent == nil then
		state.Busy = false
		return
	end

	local upPos = UDim2.new(
		state.BasePos.X.Scale, state.BasePos.X.Offset,
		state.BasePos.Y.Scale, state.BasePos.Y.Offset - DOT_UP_OFFSET
	)

	local tweenUp = tween(
		obj,
		TweenInfo.new(DOT_UP_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{Position = upPos}
	)
	tweenUp.Completed:Wait()

	if transitionStarted or obj.Parent == nil then
		state.Busy = false
		return
	end

	local tweenDown = tween(
		obj,
		TweenInfo.new(DOT_DOWN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{Position = state.BasePos}
	)
	tweenDown.Completed:Wait()

	state.Busy = false
end

-- Re-anchor the image to its own center so the bop pulse grows/shrinks in place
-- instead of tugging toward a corner. Keeps the same on-screen spot.
local baseSize = imageLabel.Size
local origPos = imageLabel.Position
imageLabel.AnchorPoint = Vector2.new(0.5, 0.5)
local imageBasePos = UDim2.new(
	origPos.X.Scale + baseSize.X.Scale / 2, origPos.X.Offset + baseSize.X.Offset / 2,
	origPos.Y.Scale + baseSize.Y.Scale / 2, origPos.Y.Offset + baseSize.Y.Offset / 2
)
imageLabel.Position = imageBasePos
local imageBaseRotation = imageLabel.Rotation

-- Springy pop-in entrance: scale up from nothing with a Back overshoot ("bop").
imageLabel.Size = UDim2.new(0, 0, 0, 0)
task.spawn(function()
	local popTween = tween(
		imageLabel,
		TweenInfo.new(IMAGE_POP_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{Size = baseSize}
	)
	popTween.Completed:Wait()
	entranceDone = true
end)

local t = 0
local floatConn: RBXScriptConnection? = nil
floatConn = RunService.RenderStepped:Connect(function(dt)
	if not running or not frame.Parent then
		if floatConn then
			floatConn:Disconnect()
			floatConn = nil
		end
		return
	end

	-- Don't fight the pop-in tween or the fade-out transition for the Size/Position.
	if transitionStarted or not entranceDone then
		return
	end

	t += dt * IMAGE_SPEED

	local x = math.sin(t * 1.2) * IMAGE_FLOAT_X
	local y = math.cos(t * 1.7) * IMAGE_FLOAT_Y
	local rot = math.sin(t * 1.1) * IMAGE_ROTATION

	imageLabel.Position = UDim2.new(
		imageBasePos.X.Scale, imageBasePos.X.Offset + x,
		imageBasePos.Y.Scale, imageBasePos.Y.Offset + y
	)
	imageLabel.Rotation = imageBaseRotation + rot

	-- Breathing bop layered on top of the drift.
	local pulse = 1 + math.sin(t * IMAGE_PULSE_SPEED) * IMAGE_PULSE_AMOUNT
	imageLabel.Size = UDim2.new(
		baseSize.X.Scale * pulse, baseSize.X.Offset * pulse,
		baseSize.Y.Scale * pulse, baseSize.Y.Offset * pulse
	)
end)

task.spawn(function()
	while running and frame.Parent and not transitionStarted do
		for _, state in ipairs(dotStates) do
			if transitionStarted then
				break
			end
			task.spawn(animateDot, state)
			task.wait(DOT_DELAY_BETWEEN)
		end
		task.wait(DOT_CYCLE_PAUSE)
	end
end)

-- Block until the world, its assets, the character, and the player's DATA are all
-- actually ready -- so when we reveal, nothing is missing, popping in, or stale.
local function waitForEverything()
	-- Preload the pieces the player sees first, so there's no texture/model pop-in
	-- the instant we fade out. Guarded: preload must never be able to stall reveal.
	local toPreload: {Instance} = {imageLabel}
	local lobby = Workspace:FindFirstChild("Lobby")
	if lobby then table.insert(toPreload, lobby) end
	local mainGui = playerGui:FindFirstChild("Main")
	if mainGui then table.insert(toPreload, mainGui) end

	if not game:IsLoaded() then
		game.Loaded:Wait()
	end

	pcall(function()
		ContentProvider:PreloadAsync(toPreload)
	end)

	-- Character in and standing (HumanoidRootPart exists) before we reveal.
	if not player.Character then
		player.CharacterAdded:Wait()
	end
	local char = player.Character
	if char then
		char:WaitForChild("HumanoidRootPart", 10)
	end

	-- The real gate: the server's DataReady flag = their profile is loaded and every
	-- inventory/equip attribute + leaderstat exists. Timeout so a lost attribute or
	-- a hard data-load failure can never leave the player stuck on the loader.
	if not player:GetAttribute("DataReady") then
		local deadline = os.clock() + DATA_READY_TIMEOUT
		local conn: RBXScriptConnection?
		local done = false
		conn = player:GetAttributeChangedSignal("DataReady"):Connect(function()
			if player:GetAttribute("DataReady") then done = true end
		end)
		while not done and not player:GetAttribute("DataReady") and os.clock() < deadline do
			task.wait(0.1)
		end
		if conn then conn:Disconnect() end
	end
end

local function runLoadedTransition()
	if transitionStarted then
		return
	end
	transitionStarted = true

	task.wait(0.03)

	for _, dot in ipairs(dots) do
		for _, s in ipairs(dotStates) do
			if s.Object == dot then
				dot.Position = s.BasePos
				break
			end
		end

		if dot:IsA("TextLabel") or dot:IsA("TextButton") or dot:IsA("TextBox") then
			tween(dot, TweenInfo.new(DOT_FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				TextTransparency = 1,
				BackgroundTransparency = 1
			})
			pcall(function()
				tween(dot, TweenInfo.new(DOT_FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
					TextStrokeTransparency = 1
				})
			end)
		elseif dot:IsA("ImageLabel") or dot:IsA("ImageButton") then
			tween(dot, TweenInfo.new(DOT_FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				ImageTransparency = 1,
				BackgroundTransparency = 1
			})
		else
			tween(dot, TweenInfo.new(DOT_FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				BackgroundTransparency = 1
			})
		end
	end

	loadingText.Text = "Loaded!"

	task.wait(DOT_FADE_TIME)
	task.wait(LOADED_TEXT_HOLD)

	fadeFrameOut()

	running = false
	if floatConn then
		floatConn:Disconnect()
		floatConn = nil
	end
end

task.spawn(function()
	waitForEverything()
	task.wait(MIN_DISPLAY_AFTER_LOADED)
	runLoadedTransition()
end)

script.Destroying:Connect(function()
	running = false
	if floatConn then
		floatConn:Disconnect()
		floatConn = nil
	end
end)
