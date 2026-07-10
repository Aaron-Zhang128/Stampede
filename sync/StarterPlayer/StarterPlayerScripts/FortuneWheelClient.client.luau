--[[
	FortuneWheelClient - spins the lobby wheel model (Workspace.FortuneWheel).

	The disc rotates on its own with a slow, continuous "attract" idle so the
	lobby wheel always looks alive. When anyone's spin lands, the committed
	SpinStarted broadcast takes the disc over with the SAME cubic ease-out the
	UI wheel uses (Main's section 10) and lands it on the winning slice; the
	idle then resumes from that resting angle. So the physical wheel and the
	Spinner UI still tell the same story.

	SpinService broadcasts SpinStarted { index, revolutions, jitter,
	duration } to every client; slice edges tick a positional peg clack for
	anyone standing nearby during a real spin (idle stays quiet).

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
local IDLE_SPEED = 20 -- degrees/sec of continuous attract rotation while idle

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

-- currentAngle accumulates across idle + spins so everything keeps flowing
-- from wherever the disc rests; the UI's Rotation is clockwise-positive, and
-- -Z here reads clockwise to a player facing the wheel from the lobby side.
local basePivot = disc:GetPivot()
local currentAngle = 0
local lastEdge = 0

-- nil while idling; set to a committed spin's params while one is playing.
local activeSpin = nil

local function applyAngle(angle)
	disc:PivotTo(basePivot * CFrame.Angles(0, 0, -math.rad(angle % 360)))
end

-- one persistent loop: gently rotates the disc while idle, then hands the
-- wheel to a committed spin when SpinStarted arrives, then idles again.
RunService.RenderStepped:Connect(function(dt)
	local spin = activeSpin
	if spin then
		spin.elapsed = math.min(spin.elapsed + dt, spin.duration)
		local alpha = 1 - (1 - spin.elapsed / spin.duration) ^ 3
		currentAngle = spin.startAngle + spin.delta * alpha

		-- clack once per slice edge the pointer crosses during a real spin
		local edge = math.floor((currentAngle + SLICE_ANGLE / 2) / SLICE_ANGLE)
		if edge ~= lastEdge then
			lastEdge = edge
			clack()
		end

		if spin.elapsed >= spin.duration then
			currentAngle = spin.targetMod % 360
			if activeSpin == spin then
				activeSpin = nil
			end
		end
	else
		currentAngle = (currentAngle + IDLE_SPEED * dt) % 360
	end
	applyAngle(currentAngle)
end)

startedRemote.OnClientEvent:Connect(function(data)
	if typeof(data) ~= "table" then
		return
	end

	local startAngle = currentAngle
	local targetMod = -((tonumber(data.index) or 1) - 1) * SLICE_ANGLE + (tonumber(data.jitter) or 0)
	local delta = (targetMod - startAngle) % 360 + (tonumber(data.revolutions) or 4) * 360

	-- assigning activeSpin hands the wheel over; a newer broadcast simply
	-- replaces it, and the loop picks up the new params on the next frame.
	lastEdge = math.floor((startAngle + SLICE_ANGLE / 2) / SLICE_ANGLE)
	activeSpin = {
		startAngle = startAngle,
		delta = delta,
		duration = tonumber(data.duration) or 6,
		targetMod = targetMod,
		elapsed = 0,
	}
end)
