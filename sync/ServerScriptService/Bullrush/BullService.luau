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
local BullCatalog = require(ReplicatedStorage.Bullrush.BullCatalog)
local Remotes = ReplicatedStorage.Bullrush.Remotes
local BullTemplate = ReplicatedStorage.BullrushAssets.BullTemplate
local BullModels = ReplicatedStorage.BullrushAssets:FindFirstChild("Bulls")

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

-- The model charged down the lane: the bull's catalog modelName (per-rarity
-- tier skins in ReplicatedStorage.BullrushAssets.Bulls, same Root+Body build
-- as BullTemplate), or BullTemplate for wave bulls / commons / missing models.
local function templateFor(bullId: string?): Model
	if bullId then
		local def = BullCatalog.get(bullId)
		local modelName = def and def.modelName
		local model = if modelName and BullModels then BullModels:FindFirstChild(modelName) else nil
		if model and model:IsA("Model") then
			return model
		end
	end
	return BullTemplate
end

-- style.bullId: the thrower's equipped BullCatalog id (revenge throws only) —
-- picks the model via templateFor above.
function BullService.charge(lane, speed: number, bounds, getAlivePlayers, onKill, style: { throwerName: string?, bullId: string? }?): number
	local startPos, endPos = GridUtil.lanePath(lane, bounds)
	local duration = (endPos - startPos).Magnitude / speed
	local rotation = CFrame.lookAt(startPos, endPos).Rotation
	local crossCoord = GridUtil.laneCrossCoord(lane)

	local bull = templateFor(style and style.bullId):Clone()
	bull:PivotTo(CFrame.lookAt(startPos, endPos))

	-- Revenge bulls read as PLAYER-SENT: a red glow everyone can see, plus the
	-- thrower's name over its head so victims know who to blame (and the
	-- thrower can spot THEIR bull in a stampede).
	if style then
		local glow = Instance.new("Highlight")
		glow.Name = "RevengeGlow"
		glow.FillColor = Color3.fromRGB(255, 60, 40)
		glow.FillTransparency = 0.75
		glow.OutlineColor = Color3.fromRGB(255, 90, 60)
		glow.OutlineTransparency = 0.2
		glow.DepthMode = Enum.HighlightDepthMode.Occluded
		glow.Parent = bull
		local root = bull.PrimaryPart or bull:FindFirstChild("Root")
		if style.throwerName and root then
			local tag = Instance.new("BillboardGui")
			tag.Name = "RevengeTag"
			tag.Size = UDim2.new(0, 130, 0, 26)
			tag.StudsOffset = Vector3.new(0, 4, 0)
			tag.AlwaysOnTop = true
			tag.MaxDistance = 220
			local label = Instance.new("TextLabel")
			label.BackgroundTransparency = 1
			label.Size = UDim2.fromScale(1, 1)
			label.Font = Enum.Font.GothamBlack
			label.TextScaled = true
			label.TextColor3 = Color3.fromRGB(255, 90, 60)
			label.TextStrokeColor3 = Color3.fromRGB(25, 0, 0)
			label.TextStrokeTransparency = 0.3
			label.Text = style.throwerName .. "'s bull!"
			label.Parent = tag
			tag.Parent = root
		end
	end

	bull.Parent = getActiveBullsFolder()

	-- Positional hooves: the charge is HEARD coming from where the bull is,
	-- not just felt as a flat stampede layer. Dies with the model.
	local soundRoot = bull.PrimaryPart or bull:FindFirstChild("Root")
	if soundRoot then
		local gallop = Instance.new("Sound")
		gallop.Name = "GallopLoop"
		gallop.SoundId = "rbxassetid://3300268152" -- "horse gallopping sound" (verified loadable)
		gallop.Looped = true
		gallop.Volume = 0.315
		gallop.PlaybackSpeed = math.clamp(speed / 50, 0.85, 1.25) -- faster charge, faster hooves
		gallop.RollOffMinDistance = 15
		gallop.RollOffMaxDistance = 200
		gallop.Parent = soundRoot
		gallop:Play()
		if style then
			-- Launch bellow for revenge bulls: a pitched-down moo reads as an
			-- angry bull; only the first bawl of the long clip plays.
			local bellow = Instance.new("Sound")
			bellow.Name = "Bellow"
			bellow.SoundId = "rbxassetid://130829741" -- "Cow moo sound effect" (verified loadable)
			bellow.Volume = 0.63
			bellow.PlaybackSpeed = 0.78
			bellow.RollOffMinDistance = 25
			bellow.RollOffMaxDistance = 350
			bellow.Parent = soundRoot
			bellow:Play()
			task.delay(2.4, function()
				if bellow.Parent then
					bellow:Stop()
				end
			end)
		end
	end

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
