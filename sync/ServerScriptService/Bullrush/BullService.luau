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

-- Squash & stretch (the "bouncy but grounded" juice). The bull coils out of the
-- gate STRETCHED along its travel axis (a lunge), eases back to normal, then
-- SQUASHES as it slams through the far edge. Body faces -Z, so its local Z is
-- the travel axis (scaled by `along`); X/Y are the cross-section (`cross`).
local LUNGE_TIME = 0.16    -- seconds the launch stretch takes to settle
local LUNGE_STRETCH = 0.30 -- +30% along travel at the very start of the charge
local LUNGE_SQUASH = 0.14  -- -14% cross-section while stretched (fake volume)
local IMPACT_TIME = 0.12   -- squash window as it barrels through the far edge
local IMPACT_SQUASH = 0.20 -- -20% along / +cross as it slams flat

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

-- Mutation auras: a rolled mutation rides the charge as particles. The VFX
-- rigs in ReplicatedStorage.Mutations are dead parts carrying tuned
-- ParticleEmitters (some bare, some under Attachments); clone just the
-- emitters/attachments onto the Body so no extra geometry ships with the
-- bull. Missing rig/catalog entry -> silently plain (a data hiccup must
-- never block a throw).
local MutationRigs = ReplicatedStorage:FindFirstChild("Mutations")
local function attachMutationVfx(body: BasePart?, mutId: string)
	local def = BullCatalog.getMutation(mutId)
	local rig = if def and MutationRigs then MutationRigs:FindFirstChild(def.vfxName) else nil
	if not (body and rig) then
		return
	end
	for _, child in ipairs(rig:GetChildren()) do
		if child:IsA("ParticleEmitter") or child:IsA("Attachment") then
			local copy = child:Clone()
			if copy:IsA("ParticleEmitter") then
				copy.Enabled = true
			else
				for _, d in ipairs(copy:GetDescendants()) do
					if d:IsA("ParticleEmitter") then
						d.Enabled = true
					end
				end
			end
			copy.Parent = body
		end
	end
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

-- chargeAlong runs a bull straight from startPos to endPos (Root-center world
-- positions) at `speed`, killing players inside the axis-aligned kill box around
-- crossCoord. `axis` ("row" | "col") is the travel axis the kill box measures
-- along. onCharge(duration) / onCleared() are optional hooks fired at launch /
-- exit (the main game wires the ChargeStart / LaneCleared remotes there; the
-- practice arena passes none, so no client is told about its bulls).
-- parentFolder overrides where the bull model lives (defaults to the main
-- arena's ActiveBulls). This is the origin-agnostic core; BullService.charge
-- below maps a main-arena lane onto it.
-- style.bullId: the thrower's equipped BullCatalog id (revenge throws only) —
-- picks the model via templateFor above. style.mutation: the bull's worn
-- mutation id — its aura emitters are cloned onto the Body at launch.
function BullService.chargeAlong(startPos: Vector3, endPos: Vector3, crossCoord: number, axis: string, speed: number, getAlivePlayers, onKill, style: { throwerName: string?, bullId: string?, mutation: string? }?, onCharge, onCleared, parentFolder): number
	local duration = (endPos - startPos).Magnitude / speed
	local rotation = CFrame.lookAt(startPos, endPos).Rotation

	local bull = templateFor(style and style.bullId):Clone()
	bull:PivotTo(CFrame.lookAt(startPos, endPos))

	-- Body is the visible mesh; squash/stretch drives its Size around its center
	-- each frame (Root, the invisible primary, is untouched so the model still
	-- rides where PivotTo puts it).
	local body = bull:FindFirstChild("Body")
	local baseBodySize = if body and body:IsA("BasePart") then body.Size else nil

	-- Revenge bulls read as PLAYER-SENT: a red glow everyone can see, plus the
	-- thrower's name over its head so victims know who to blame (and the
	-- thrower can spot THEIR bull in a stampede).
	if style then
		-- Stamp the thrower so their own client can give this bull top-priority
		-- highlighting (see BullrushClient.boostOwnRevengeBull) — they should
		-- always be able to pick out the bull they sent.
		if style.throwerName then
			bull:SetAttribute("ThrowerName", style.throwerName)
		end
		if style.mutation then
			attachMutationVfx(body, style.mutation)
		end
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

	bull.Parent = parentFolder or getActiveBullsFolder()

	-- Positional hooves: the charge is HEARD coming from where the bull is,
	-- not just felt as a flat stampede layer. Dies with the model.
	local soundRoot = bull.PrimaryPart or bull:FindFirstChild("Root")
	if soundRoot then
		-- Stampede, not one horse: stack the same verified gallop clip at spread
		-- pitches so the hooves overlap like a herd, plus a deep sub-pitched layer
		-- that reads as the ground thundering. Detune + phase offset keep the
		-- loops from beating together into an obvious single sample.
		local chargePitch = math.clamp(speed / 50, 0.85, 1.25) -- faster charge, faster hooves
		local HERD = {
			{ pitch = 0.55, volume = 0.28 }, -- ground rumble (sub layer)
			{ pitch = 0.86, volume = 0.20 },
			{ pitch = 1.00, volume = 0.20 },
			{ pitch = 1.17, volume = 0.16 },
		}
		for i, layer in ipairs(HERD) do
			local gallop = Instance.new("Sound")
			gallop.Name = "GallopLoop" .. i
			gallop.SoundId = "rbxassetid://3300268152" -- "horse gallopping sound" (verified loadable)
			gallop.Looped = true
			gallop.Volume = layer.volume
			gallop.PlaybackSpeed = chargePitch * layer.pitch
			gallop.RollOffMinDistance = 15
			gallop.RollOffMaxDistance = 200
			gallop.Parent = soundRoot
			gallop:Play()
			gallop.TimePosition = (i - 1) * 0.13 -- phase offset so loops don't sync
		end
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

	if onCharge then
		onCharge(duration)
	end

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

		-- Coil-release lunge on the way out, slam-squash on arrival.
		if baseBodySize and body.Parent then
			local along, cross = 1, 1
			if elapsed < LUNGE_TIME then
				local k = 1 - elapsed / LUNGE_TIME -- 1 -> 0
				k = k * k                          -- quad ease-out of the stretch
				along += LUNGE_STRETCH * k
				cross -= LUNGE_SQUASH * k
			end
			local remain = duration - elapsed
			if remain < IMPACT_TIME then
				local k = 1 - remain / IMPACT_TIME -- 0 -> 1 as it hits the far edge
				k = k * k
				along -= IMPACT_SQUASH * k
				cross += IMPACT_SQUASH * 0.6 * k
			end
			body.Size = Vector3.new(baseBodySize.X * cross, baseBodySize.Y * cross, baseBodySize.Z * along)
		end

		-- Kill check: axis-aligned box around the bull's root position.
		local bullAlong = if axis == "row" then position.X else position.Z
		for _, player in getAlivePlayers() do
			if not killed[player] then
				local character = player.Character
				local root = character and character:FindFirstChild("HumanoidRootPart")
				if root then
					local p = root.Position
					local along = if axis == "row" then p.X else p.Z
					local cross = if axis == "row" then p.Z else p.X
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

	if onCleared then
		onCleared()
	end
	bull:Destroy()
	return duration
end

-- charge runs a lane across the ACTIVE window of the MAIN arena, mapping it
-- through GridUtil (ARENA_ORIGIN-bound) and firing the ChargeStart / LaneCleared
-- remotes so every client renders the telegraph/clear. Signature unchanged for
-- Main.runWaves and RevengeService.
function BullService.charge(lane, speed: number, bounds, getAlivePlayers, onKill, style: { throwerName: string?, bullId: string?, mutation: string? }?): number
	local startPos, endPos = GridUtil.lanePath(lane, bounds)
	local crossCoord = GridUtil.laneCrossCoord(lane)
	return BullService.chargeAlong(
		startPos, endPos, crossCoord, lane.axis, speed, getAlivePlayers, onKill, style,
		function(duration)
			Remotes.ChargeStart:FireAllClients(lane, duration, bounds)
		end,
		function()
			Remotes.LaneCleared:FireAllClients(lane)
		end
	)
end

return BullService
