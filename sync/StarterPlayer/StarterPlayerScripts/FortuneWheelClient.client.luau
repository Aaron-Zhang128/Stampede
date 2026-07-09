--[[
	FortuneWheelClient - spins the lobby wheel model (Workspace.FortuneWheel)
	whenever anyone's spin lands, so the physical wheel and the Spinner UI
	tell the same story.

	SpinService broadcasts SpinStarted { index, revolutions, jitter,
	duration } to every client; this script replays it on the wheel's Disc
	sub-model (pivot pre-set at the hub in edit mode) with the SAME cubic
	ease-out the UI wheel uses (Main's section 10), plus a positional peg
	clack per slice edge for anyone standing nearby.

	World FX only - all fortune-wheel UI lives in StarterGui.Main.Main, per
	the house rule. Rotation is a RenderStepped lerp, not a tween (see the
	project's TweenService-in-Run-mode note); the disc parts are anchored,
	so PivotTo is purely visual per-client.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")

local SLICE_ANGLE = 60

local sfxGroup = SoundService:FindFirstChild("GameSFX")
local tickerTemplate = sfxGroup and sfxGroup:FindFirstChild("Ticker")

-- the wheel was reparented under Workspace.Lobby in the map rework, so a plain
-- workspace:WaitForChild("FortuneWheel") no longer resolves. Scan descendants
-- (retrying while the model streams in) so any future move can't break this.
local function resolveWheel()
	local deadline = os.clock() + 60
	repeat
		for _, m in ipairs(workspace:GetDescendants()) do
			if m:IsA("Model") and m.Name == "FortuneWheel" then
				return m
			end
		end
		task.wait(0.2)
	until os.clock() >= deadline
	return nil
end

local wheelModel = resolveWheel()
local disc = wheelModel and wheelModel:WaitForChild("Disc", 10)
if not (disc and disc:IsA("Model")) then
	warn("[FortuneWheelClient] Workspace.FortuneWheel.Disc missing; lobby wheel stays still")
	return
end

local bullrush = ReplicatedStorage:WaitForChild("Bullrush", 30)
local remotes = bullrush and bullrush:FindFirstChild("Remotes")
local startedRemote = remotes and remotes:WaitForChild("SpinStarted", 30)
if not (startedRemote and startedRemote:IsA("RemoteEvent")) then
	warn("[FortuneWheelClient] SpinStarted remote missing; lobby wheel stays still")
	return
end

-- a part on the disc to hang positional clacks off (any will do)
local clackHost = disc:FindFirstChildWhichIsA("BasePart")
local function clack()
	if not (tickerTemplate and tickerTemplate:IsA("Sound") and clackHost) then
		return
	end
	local sound = tickerTemplate:Clone()
	sound.Volume = 0.3
	if sfxGroup and sfxGroup:IsA("SoundGroup") then
		sound.SoundGroup = sfxGroup
	end
	sound.Parent = clackHost
	sound:Play()
	Debris:AddItem(sound, 3)
end

-- currentAngle accumulates across spins so back-to-back spins keep flowing
-- from wherever the disc rests; the UI's Rotation is clockwise-positive, and
-- -Z here reads clockwise to a player facing the wheel from the lobby side.
local basePivot = disc:GetPivot()
local currentAngle = 0
local spinToken = 0

local function applyAngle(angle)
	disc:PivotTo(basePivot * CFrame.Angles(0, 0, -math.rad(angle % 360)))
end

startedRemote.OnClientEvent:Connect(function(data)
	if typeof(data) ~= "table" then
		return
	end
	spinToken += 1
	local token = spinToken -- a newer broadcast takes the wheel over mid-spin

	local startAngle = currentAngle
	local targetMod = -((tonumber(data.index) or 1) - 1) * SLICE_ANGLE + (tonumber(data.jitter) or 0)
	local delta = (targetMod - startAngle) % 360 + (tonumber(data.revolutions) or 4) * 360
	local duration = tonumber(data.duration) or 6

	local lastEdge = math.floor((startAngle + SLICE_ANGLE / 2) / SLICE_ANGLE)
	local elapsed = 0
	local connection
	connection = RunService.RenderStepped:Connect(function(dt)
		if token ~= spinToken then
			connection:Disconnect()
			return
		end
		elapsed = math.min(elapsed + dt, duration)
		local alpha = 1 - (1 - elapsed / duration) ^ 3
		currentAngle = startAngle + delta * alpha

		local edge = math.floor((currentAngle + SLICE_ANGLE / 2) / SLICE_ANGLE)
		if edge ~= lastEdge then
			lastEdge = edge
			clack()
		end

		if elapsed >= duration then
			currentAngle = targetMod % 360
			connection:Disconnect()
		end
		applyAngle(currentAngle)
	end)
end)
