--[[
	BullService - runs a single bull charge down a lane.

	BullService.charge(lane, speed, bounds, getAlivePlayers, onKill) -> duration
	- BLOCKING: yields until the bull exits the arena (or its model is removed
	  externally), then returns the charge duration in seconds. The CALLER is
	  responsible for concurrency: run each simultaneous lane in its own
	  task.spawn. charge() uses only locals, so overlapping calls are safe.
	- bounds: active-window bounds (see GridUtil); the charge path spans only
	  the window plus BULL_OVERSHOOT on each side.
	- getAlivePlayers: () -> { Player }, polled every Heartbeat for kill checks.
	- onKill: (Player) -> (), called at most once per player per charge.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Bullrush.Config)
local GridUtil = require(ReplicatedStorage.Bullrush.GridUtil)
local Remotes = ReplicatedStorage.Bullrush.Remotes
local BullTemplate = ReplicatedStorage.BullrushAssets.BullTemplate

local RagdollService = require(script.Parent.RagdollService)

local BOB_AMPLITUDE = 0.35 -- studs of gallop bounce
local BOB_FREQUENCY_PER_SPEED = 0.38 -- rad/s per stud/s: faster bulls gallop faster
local PITCH_AMPLITUDE = 0.07 -- rad: nose dips with each stride
local ROLL_AMPLITUDE = 0.06 -- rad: alternating shoulder lean
local LAUNCH_SPEED_SCALE = 1.15 -- victim fling speed relative to bull speed
local LAUNCH_SPEED_BASE = 12 -- studs/s added on top, so slow bulls still send you

local BullService = {}

local function getActiveBullsFolder(): Folder
	local arena = Workspace:FindFirstChild("BullrushArena")
	local parent = arena or Workspace
	local folder = parent:FindFirstChild("ActiveBulls")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "ActiveBulls"
		folder.Parent = parent
	end
	return folder
end

function BullService.charge(lane, speed: number, bounds, getAlivePlayers, onKill): number
	local startPos, endPos = GridUtil.lanePath(lane, bounds)
	local duration = (endPos - startPos).Magnitude / speed
	local rotation = CFrame.lookAt(startPos, endPos).Rotation
	local crossCoord = GridUtil.laneCrossCoord(lane)

	local bull = BullTemplate:Clone()
	bull:PivotTo(CFrame.lookAt(startPos, endPos))
	bull.Parent = getActiveBullsFolder()

	local emitter = bull:FindFirstChild("DustEmitter", true)
	if emitter and emitter:IsA("ParticleEmitter") then
		emitter.Enabled = true
		emitter.Rate = math.clamp(speed * 1.6, 60, 110) -- harder charges kick up more dust
	end

	Remotes.ChargeStart:FireAllClients(lane, duration, bounds)

	local killed: { [Player]: boolean } = {} -- onKill fires once per player
	local elapsed = 0
	while elapsed < duration do
		local dt = RunService.Heartbeat:Wait()
		if not bull.Parent then
			break -- destroyed externally (round cleanup)
		end
		elapsed = math.min(elapsed + dt, duration)

		local position = startPos:Lerp(endPos, elapsed / duration)
		local phase = elapsed * speed * BOB_FREQUENCY_PER_SPEED
		local bob = BOB_AMPLITUDE * math.abs(math.sin(phase))
		local nod = PITCH_AMPLITUDE * math.sin(2 * phase)
		local sway = ROLL_AMPLITUDE * math.sin(phase)
		bull:PivotTo(CFrame.new(position + Vector3.new(0, bob, 0)) * rotation * CFrame.Angles(nod, 0, sway))

		-- Kill check: axis-aligned box around the bull's root position.
		local bullAlong = if lane.axis == "row" then position.X else position.Z
		for _, player in getAlivePlayers() do
			if not killed[player] then
				local character = player.Character
				local root = character and character:FindFirstChild("HumanoidRootPart")
				if root then
					local p = root.Position
					local along = if lane.axis == "row" then p.X else p.Z
					local cross = if lane.axis == "row" then p.Z else p.X
					if math.abs(along - bullAlong) < Config.BULL_HIT_HALF_LENGTH
						and math.abs(cross - crossCoord) < Config.BULL_HIT_HALF_WIDTH
					then
						killed[player] = true
						-- Send them flying before onKill's Health = 0 default-death poof.
						RagdollService.launch(character, endPos - startPos,
							speed * LAUNCH_SPEED_SCALE + LAUNCH_SPEED_BASE)
						onKill(player)
					end
				end
			end
		end
	end

	Remotes.LaneCleared:FireAllClients(lane)
	bull:Destroy()
	return duration
end

return BullService
