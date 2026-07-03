--------------------------------------------------------------------------------
-- BullrushClient
-- Presentation layer for Bullrush Grid: lane telegraphs (tile pulse, bull
-- silhouette, rumble), charge audio, scorch + camera shake on lane clear,
-- near-miss graze shakes from live bulls, charge-launch camera kicks,
-- elimination feedback, arena-shrink telegraph FX (with sustained ground
-- tremor), gamepad rumble + device haptics mirroring the shakes, and the
-- round HUD (including per-round MODE display and Team Rush team counts).
-- Client-only; reads the shared contract in ReplicatedStorage.Bullrush and
-- never touches server state. The physical arena is 9x9; each round plays a
-- mode-sized centered window of it that shrinks during the round. The SERVER
-- owns tile sinking/recoloring, this script only telegraphs the danger and
-- reacts at the sink moment.
--
-- Sound credits (free marketplace audio, verified loadable in this place):
--   12222030  "HalloweenThunder.wav" (Roblox)  - telegraph/charge/shrink rumble
--   12222095  "Rocket whoosh 01.wav" (Roblox)  - charge launch whoosh + graze
--   146163534 "Slap Hit" (Stickmasterluke)     - lane-clear + shrink slam impact
--   12221944  "bass.wav" (Roblox)              - slam low end + elimination thud
--------------------------------------------------------------------------------

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")
local HapticService = game:GetService("HapticService")
local Debris = game:GetService("Debris")

local player = Players.LocalPlayer

--==============================================================================
-- Self aura: green halo on your own character so you can spot yourself in the
-- crowd. Created client-side, so only you ever see it.
--==============================================================================

local function attachSelfAura(character: Model)
	local aura = Instance.new("Highlight")
	aura.Name = "SelfAura"
	aura.FillColor = Color3.fromRGB(85, 255, 127)
	aura.FillTransparency = 0.85
	aura.OutlineColor = Color3.fromRGB(120, 255, 150)
	aura.OutlineTransparency = 0.1
	aura.DepthMode = Enum.HighlightDepthMode.Occluded
	aura.Parent = character
end

if player.Character then
	attachSelfAura(player.Character)
end
player.CharacterAdded:Connect(attachSelfAura)
--==============================================================================
-- Contract instances (generous timeouts; disable cleanly if anything missing)
--==============================================================================

local WAIT_TIMEOUT = 30

local function waitFor(parent: Instance?, childName: string): Instance?
	if not parent then
		return nil
	end
	local child = parent:WaitForChild(childName, WAIT_TIMEOUT)
	if not child then
		warn(("[BullrushClient] Missing contract instance %q under %s"):format(childName, parent:GetFullName()))
	end
	return child
end

local bullrushFolder = waitFor(ReplicatedStorage, "Bullrush")
local configModule = waitFor(bullrushFolder, "Config")
local gridUtilModule = waitFor(bullrushFolder, "GridUtil")
local remotes = waitFor(bullrushFolder, "Remotes")
local telegraphRemote = waitFor(remotes, "Telegraph")
local chargeStartRemote = waitFor(remotes, "ChargeStart")
local laneClearedRemote = waitFor(remotes, "LaneCleared")
local eliminatedRemote = waitFor(remotes, "Eliminated")
local roundStateRemote = waitFor(remotes, "RoundState")
-- ArenaShrink is the newest remote and deliberately OPTIONAL: if it's missing
-- we warned above, skip shrink FX, and every other effect keeps working.
local arenaShrinkRemote = waitFor(remotes, "ArenaShrink")
-- RevengeAck is OPTIONAL the same way: without it the revenge pads stay in
-- their server-painted resting look and everything else keeps working.
-- (Revenge throws are physical pressure pads — server-side, no remote.)
local revengeAckRemote = waitFor(remotes, "RevengeAck")
local assetsFolder = waitFor(ReplicatedStorage, "BullrushAssets")
local bullTemplate = waitFor(assetsFolder, "BullTemplate")
local arena = waitFor(workspace, "BullrushArena")
local tilesFolder = waitFor(arena, "Tiles")
local playerGui = player:WaitForChild("PlayerGui", WAIT_TIMEOUT)

if not (configModule and gridUtilModule and telegraphRemote and chargeStartRemote
	and laneClearedRemote and eliminatedRemote and roundStateRemote
	and bullTemplate and tilesFolder and playerGui) then
	warn("[BullrushClient] Contract incomplete; client presentation disabled.")
	return
end

local Config = require(configModule)
local GridUtil = require(gridUtilModule)

--==============================================================================
-- Tuning constants
--==============================================================================

local WARN_COLOR = Color3.fromRGB(220, 60, 40)
local SCORCH_COLOR = Color3.fromRGB(55, 48, 42)
local SILHOUETTE_COLOR = Color3.fromRGB(56, 56, 62)

local PULSE_TWEEN_INFO = TweenInfo.new(0.35, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
local SCORCH_RESTORE_TIME = 2.5

local SHAKE_RANGE = 14 -- studs from the lane center line
local SHAKE_DECAY_TIME = 0.4
local SHAKE_MAGNITUDE = 1.3
local MAX_TRAUMA = 1.25

local GRAZE_RANGE = 14 -- planar studs: a bull's closest approach inside this counts as a near miss
local GRAZE_DEADLY = 5 -- at/inside this it practically brushed you: full-strength punch
local GRAZE_HYSTERESIS = 2 -- bull must recede this far past its closest approach before the punch fires
local TREMOR_LEVEL = 0.3 -- sustained shake floor while the arena-shrink telegraph runs

-- Client-side effects folder (created locally; never replicates)
local fxFolder = workspace:FindFirstChild("BullrushClientFX") or Instance.new("Folder")
fxFolder.Name = "BullrushClientFX"
fxFolder.Parent = workspace

--==============================================================================
-- Sounds (defensive: a bad/moderated ID can never error the script)
--==============================================================================

local SOUND_IDS = {
	rumble = 12222030, -- HalloweenThunder.wav (Roblox)
	chargeWhoosh = 12222095, -- Rocket whoosh 01.wav (Roblox)
	slam = 146163534, -- Slap Hit (Stickmasterluke)
	thud = 12221944, -- bass.wav (Roblox)
}

local function makeSound(idKey: string, props: { [string]: any }?, parent: Instance?): Sound
	local sound = Instance.new("Sound")
	sound.Name = "Bullrush_" .. idKey
	pcall(function()
		sound.SoundId = "rbxassetid://" .. tostring(SOUND_IDS[idKey] or 0)
	end)
	if props then
		for prop, value in pairs(props) do
			pcall(function()
				(sound :: any)[prop] = value
			end)
		end
	end
	sound.Parent = parent or SoundService
	return sound
end

local function safePlay(sound: Sound?)
	if sound then
		pcall(function()
			sound:Play()
		end)
	end
end

local function playOneShot(idKey: string, props: { [string]: any }?): Sound
	local sound = makeSound(idKey, props, SoundService)
	safePlay(sound)
	Debris:AddItem(sound, 8)
	return sound
end

local function fadeOutAndDestroy(sound: Sound?, fadeTime: number?)
	if not sound then
		return
	end
	local tween = TweenService:Create(sound, TweenInfo.new(fadeTime or 0.3), { Volume = 0 })
	tween.Completed:Once(function()
		sound:Destroy()
	end)
	tween:Play()
end

--==============================================================================
-- Tile highlight system (reference-counted so overlapping lanes can't corrupt
-- shared tiles: a tile in both a row lane and a col lane stays red until BOTH
-- clear, and always restores to its startup original color, never to red)
--==============================================================================

local tileParts: { [string]: BasePart } = {} -- "row_col" -> Part

-- originalColors is captured ONCE at startup and is the single source of truth
-- for restore tweens. NEVER re-capture after arena shrinks: the server snaps
-- sunken tiles to charcoal, and that must not be mistaken for an "original".
local originalColors: { [BasePart]: Color3 } = {}
local tileRefCount: { [BasePart]: number } = {}
local tileTweens: { [BasePart]: Tween } = {} -- active pulse OR restore tween

for row = 1, Config.GRID_SIZE do
	for col = 1, Config.GRID_SIZE do
		local name = ("Tile_%d_%d"):format(row, col)
		local part = tilesFolder:WaitForChild(name, WAIT_TIMEOUT)
		if part and part:IsA("BasePart") then
			tileParts[row .. "_" .. col] = part
			originalColors[part] = part.Color
		else
			warn("[BullrushClient] Missing arena tile " .. name)
		end
	end
end

local function stopTileTween(part: BasePart)
	local tween = tileTweens[part]
	if tween then
		tween:Cancel()
		tileTweens[part] = nil
	end
end

-- A lane starts threatening this tile: bump refcount, start pulsing on 0 -> 1.
local function claimTile(part: BasePart)
	local count = (tileRefCount[part] or 0) + 1
	tileRefCount[part] = count
	if count > 1 then
		return -- already pulsing for another lane
	end
	stopTileTween(part) -- cancel any in-flight scorch restore
	part.Color = originalColors[part] -- pulse from a clean base
	local tween = TweenService:Create(part, PULSE_TWEEN_INFO, { Color = WARN_COLOR })
	tileTweens[part] = tween
	tween:Play()
end

-- A lane stops threatening this tile. Only when the LAST lane releases it does
-- the tile leave the warning state (scorch flash on lane clear, gentle restore
-- on round reset). Always restores to the startup original color.
local function releaseTile(part: BasePart, withScorch: boolean)
	local count = (tileRefCount[part] or 0) - 1
	if count > 0 then
		tileRefCount[part] = count
		return -- another active lane still owns this tile; keep pulsing
	end
	tileRefCount[part] = nil
	stopTileTween(part)
	if withScorch then
		part.Color = SCORCH_COLOR
	end
	local restoreTime = withScorch and SCORCH_RESTORE_TIME or 0.5
	local tween = TweenService:Create(
		part,
		TweenInfo.new(restoreTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Color = originalColors[part] }
	)
	tileTweens[part] = tween
	tween:Play()
	tween.Completed:Once(function()
		if tileTweens[part] == tween then
			tileTweens[part] = nil
		end
	end)
end

-- Tiles claimed by an arena-shrink telegraph. Kept SEPARATE from lane entries:
-- shrink claims are keyed by part, live for exactly one telegraph window, and
-- are dropped via abandonTile below (never releaseTile).
local shrinkClaimed: { [BasePart]: boolean } = {}

-- The shrink counterpart of releaseTile: drop one claim, but when the count
-- reaches zero DO NOT start a restore tween and DO NOT touch part.Color. The
-- server recolors the sunken tile charcoal at this exact moment, and a local
-- restore tween would fight the replicated color -- just cancel the pulse and
-- clear state. (If a lane still claims the tile the refcount stays > 0 and it
-- keeps pulsing; that lane's eventual release will briefly restore the old
-- tan over the charcoal -- accepted cosmetic edge.)
local function abandonTile(part: BasePart)
	local count = (tileRefCount[part] or 0) - 1
	if count > 0 then
		tileRefCount[part] = count
		return
	end
	tileRefCount[part] = nil
	stopTileTween(part)
end

-- Round reset safety: abandon (never restore) every outstanding shrink claim.
-- The server restores canonical tile positions/colors at the next round start.
local function abandonAllShrinkClaims()
	for part in pairs(shrinkClaimed) do
		shrinkClaimed[part] = nil
		abandonTile(part)
	end
end

--==============================================================================
-- Lane registry (everything keyed per-lane so overlapping lanes are safe)
--==============================================================================

local activeLanes = {} -- key -> { lane, key, bounds?, tiles = {BasePart}, silhouette?, rumble?, chargeSound? }

local function laneKey(lane): string
	return ("%s_%s_%s"):format(tostring(lane.axis), tostring(lane.index), tostring(lane.direction))
end

local function isLane(lane): boolean
	return typeof(lane) == "table"
		and (lane.axis == "row" or lane.axis == "col")
		and tonumber(lane.index) ~= nil
		and (lane.direction == 1 or lane.direction == -1)
end

-- Mirrors isLane for the ACTIVE-window table the server sends alongside
-- lanes: { rowMin, rowMax, colMin, colMax }, all numeric.
local function isBounds(bounds): boolean
	return typeof(bounds) == "table"
		and tonumber(bounds.rowMin) ~= nil
		and tonumber(bounds.rowMax) ~= nil
		and tonumber(bounds.colMin) ~= nil
		and tonumber(bounds.colMax) ~= nil
end

-- bounds (validated or nil) scopes the lane to the shrunken ACTIVE window;
-- nil falls back to the full grid inside GridUtil.
local function registerLane(lane, bounds)
	local key = laneKey(lane)
	local entry = activeLanes[key]
	if entry then
		return entry
	end
	entry = { lane = lane, key = key, bounds = bounds, tiles = {} }
	for _, cell in ipairs(GridUtil.laneTiles(lane, bounds)) do
		local part = tileParts[cell.row .. "_" .. cell.col]
		if part then
			table.insert(entry.tiles, part)
			claimTile(part)
		end
	end
	activeLanes[key] = entry
	return entry
end

-- Removes silhouette + sounds for a lane entry (tiles are handled separately).
local function teardownLaneFX(entry, fadeSounds: boolean)
	if entry.rumble then
		if fadeSounds then
			entry.rumble.Parent = SoundService -- detach before the silhouette dies
			fadeOutAndDestroy(entry.rumble, 0.25)
		else
			entry.rumble:Destroy()
		end
		entry.rumble = nil
	end
	if entry.silhouette then
		entry.silhouette:Destroy()
		entry.silhouette = nil
	end
	if entry.chargeSound then
		fadeOutAndDestroy(entry.chargeSound, 0.3)
		entry.chargeSound = nil
	end
end

-- Smoky ghost-bull at the lane start, plus a rumble that swells over warnTime.
-- Uses entry.bounds so the ghost stands at the ACTIVE window edge of a
-- shrunken arena, not out at the full-grid edge.
local function spawnSilhouette(entry, warnTime: number)
	if entry.silhouette then
		entry.silhouette:Destroy()
		entry.silhouette = nil
	end
	local ghost = bullTemplate:Clone()
	ghost.Name = "Silhouette_" .. entry.key
	for _, desc in ipairs(ghost:GetDescendants()) do
		if desc:IsA("BasePart") then
			desc.CastShadow = false
			if desc ~= ghost.PrimaryPart and desc.Name ~= "Root" then
				desc.Color = SILHOUETTE_COLOR
				desc.Material = Enum.Material.SmoothPlastic
				desc.Transparency = 0.55
			end
		elseif desc:IsA("ParticleEmitter") then
			desc.Enabled = false
		end
	end
	local startPos, endPos = GridUtil.lanePath(entry.lane, entry.bounds)
	ghost:PivotTo(CFrame.lookAt(startPos, endPos))
	ghost.Parent = fxFolder
	entry.silhouette = ghost

	local root = ghost.PrimaryPart or ghost:FindFirstChild("Root")
	local rumble = makeSound("rumble", {
		Volume = 0,
		Looped = true,
		PlaybackSpeed = 0.7,
		RollOffMinDistance = 20,
		RollOffMaxDistance = 400,
	}, root or SoundService)
	entry.rumble = rumble
	safePlay(rumble)
	TweenService:Create(
		rumble,
		TweenInfo.new(math.max(warnTime, 0.1), Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Volume = 0.4 }
	):Play()
end

-- Round reset: drop every lane without scorch (gentle restore to original).
local function clearAllLanes()
	for key, entry in pairs(activeLanes) do
		activeLanes[key] = nil
		teardownLaneFX(entry, false)
		for _, part in ipairs(entry.tiles) do
			releaseTile(part, false)
		end
	end
end

--==============================================================================
-- Camera shake: single trauma accumulator driven by one RenderStepped binding.
-- Simultaneous lane clears just add trauma; CameraOffset always returns to zero.
-- tremor is a second, SUSTAINED component (arena-shrink telegraph ground
-- tremble): it never decays, only the code that set it clears it. The two sum
-- into one shake level so overlapping sources can never fight over the camera.
--==============================================================================

local trauma = 0
local tremor = 0
local shakeDirty = false
local shakeRandom = Random.new()

local function getHumanoid(): Humanoid?
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid") or nil
end

local function addTrauma(amount: number)
	trauma = math.min(trauma + amount, MAX_TRAUMA)
end

-- Perpendicular distance from the local character to a lane's center line,
-- or nil if the character doesn't exist yet.
local function distanceToLaneLine(lane): number?
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return nil
	end
	local cross = GridUtil.laneCrossCoord(lane)
	if lane.axis == "row" then
		return math.abs(hrp.Position.Z - cross)
	end
	return math.abs(hrp.Position.X - cross)
end

--==============================================================================
-- Haptics: two complementary layers, both pcall-guarded so a platform quirk
-- can never error gameplay presentation.
--   1) Gamepad motors mirror the camera-shake level every frame: the large
--      (low-frequency) motor gets the squared level like the camera punch,
--      the small (high-frequency) motor gets a linear map so subtle tremors
--      still buzz faintly. Zeroed the same frame the shake ends.
--   2) HapticEffect one-shots reach devices SetMotor can't (phone vibration).
--      HapticEffect is spatialized (default Radius is only 3 studs!), so each
--      pulse is pinned to the current camera position with a wide radius.
--==============================================================================

local GAMEPAD = Enum.UserInputType.Gamepad1

local gamepadLargeOK = false
local gamepadSmallOK = false

local function refreshGamepadSupport()
	local okVib, vib = pcall(function()
		return HapticService:IsVibrationSupported(GAMEPAD)
	end)
	if not (okVib and vib == true) then
		gamepadLargeOK, gamepadSmallOK = false, false
		return
	end
	local okL, l = pcall(function()
		return HapticService:IsMotorSupported(GAMEPAD, Enum.VibrationMotor.Large)
	end)
	local okS, s = pcall(function()
		return HapticService:IsMotorSupported(GAMEPAD, Enum.VibrationMotor.Small)
	end)
	gamepadLargeOK = okL and l == true
	gamepadSmallOK = okS and s == true
end

refreshGamepadSupport()
UserInputService.GamepadConnected:Connect(refreshGamepadSupport)
UserInputService.GamepadDisconnected:Connect(refreshGamepadSupport)

-- level is the combined shake level (0..MAX_TRAUMA); 0 stops both motors.
local function setGamepadRumble(level: number)
	if gamepadLargeOK then
		pcall(function()
			HapticService:SetMotor(GAMEPAD, Enum.VibrationMotor.Large, math.clamp(level * level, 0, 1))
		end)
	end
	if gamepadSmallOK then
		pcall(function()
			HapticService:SetMotor(GAMEPAD, Enum.VibrationMotor.Small, math.clamp(level * 0.8, 0, 1))
		end)
	end
end

-- One-shot device haptic ("GameplayExplosion" / "GameplayCollision" / ...).
-- Indexed by name inside the pcall so an enum member missing on an older
-- client just skips the pulse instead of erroring.
local function playHapticPulse(effectTypeName: string)
	pcall(function()
		local effect = Instance.new("HapticEffect")
		effect.Type = (Enum.HapticEffectType :: any)[effectTypeName]
		local camera = workspace.CurrentCamera
		if camera then
			effect.Position = camera.CFrame.Position
		end
		effect.Radius = 100
		effect.Parent = SoundService
		effect:Play()
		Debris:AddItem(effect, 2)
	end)
end

--==============================================================================
-- HUD (built programmatically; the only GUI this client owns)
--==============================================================================

local hud = Instance.new("ScreenGui")
hud.Name = "BullrushHUD"
hud.ResetOnSpawn = false
hud.IgnoreGuiInset = true
hud.DisplayOrder = 10
hud.Parent = playerGui

local function addCorner(inst: Instance, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = inst
end

local function addStroke(inst: Instance, thickness: number, transparency: number)
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(0, 0, 0)
	stroke.Thickness = thickness
	stroke.Transparency = transparency
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = inst
end

-- Top-center status panel
local statusPanel = Instance.new("Frame")
statusPanel.Name = "StatusPanel"
statusPanel.AnchorPoint = Vector2.new(0.5, 0)
statusPanel.Position = UDim2.new(0.5, 0, 0, 62)
statusPanel.Size = UDim2.new(0, 430, 0, 44)
statusPanel.BackgroundColor3 = Color3.fromRGB(16, 16, 22)
statusPanel.BackgroundTransparency = 0.35
statusPanel.BorderSizePixel = 0
statusPanel.Parent = hud
addCorner(statusPanel, 10)
addStroke(statusPanel, 1.5, 0.5)

local statusLabel = Instance.new("TextLabel")
statusLabel.Name = "StatusLabel"
statusLabel.BackgroundTransparency = 1
statusLabel.Position = UDim2.new(0, 10, 0, 0)
statusLabel.Size = UDim2.new(1, -20, 1, 0)
statusLabel.Font = Enum.Font.GothamBlack
statusLabel.TextSize = 20
statusLabel.TextScaled = true -- mode + team strings can run long; shrink, never clip
statusLabel.TextColor3 = Color3.fromRGB(240, 238, 230)
statusLabel.TextStrokeTransparency = 0.85
statusLabel.Text = "Waiting for players…"
statusLabel.Parent = statusPanel

local statusSizeCap = Instance.new("UITextSizeConstraint")
statusSizeCap.MaxTextSize = 20
statusSizeCap.Parent = statusLabel

-- Full-screen elimination overlay
local elimOverlay = Instance.new("Frame")
elimOverlay.Name = "ElimOverlay"
elimOverlay.Size = UDim2.fromScale(1, 1)
elimOverlay.BackgroundColor3 = Color3.fromRGB(12, 4, 4)
elimOverlay.BackgroundTransparency = 1
elimOverlay.BorderSizePixel = 0
elimOverlay.Visible = false
elimOverlay.ZIndex = 10
elimOverlay.Parent = hud

local elimText = Instance.new("TextLabel")
elimText.Name = "ElimText"
elimText.AnchorPoint = Vector2.new(0.5, 0.5)
elimText.Position = UDim2.fromScale(0.5, 0.42)
elimText.Size = UDim2.new(1, 0, 0, 110)
elimText.BackgroundTransparency = 1
elimText.Font = Enum.Font.GothamBlack
elimText.TextSize = 72
elimText.TextColor3 = Color3.fromRGB(235, 55, 45)
elimText.TextStrokeColor3 = Color3.fromRGB(20, 0, 0)
elimText.TextStrokeTransparency = 0.4
elimText.TextTransparency = 1
elimText.Text = "ELIMINATED"
elimText.ZIndex = 11
elimText.Parent = elimOverlay

--==============================================================================
-- HUD state
--==============================================================================

local currentState = "WAITING"
local locallyEliminated = false -- true from our elimination until the round leaves ACTIVE
local lastWave = 0
local lastAlive = 0
local lastGridSize = Config.GRID_SIZE -- active window side length
local lastModeName: string? = nil -- current/next round's mode display name
local lastTeamCounts: { [string]: number }? = nil -- Team Rush alive counts, ACTIVE only
local intermissionEndsAt: number? = nil
local lastIntermissionSecond: number? = nil

-- Revenge cooldown mirror (server-authoritative, from RevengeAck THROW_OK /
-- DENIED): drives the pad glow/countdown repaint below.
local revengeReadyAt = 0 -- os.clock() when the next throw unlocks

local elimToken = 0

-- Validates the Team Rush counts table the server sends in ACTIVE updates.
local function isTeamCounts(counts): boolean
	return typeof(counts) == "table"
		and tonumber(counts.RED) ~= nil
		and tonumber(counts.BLUE) ~= nil
end

local function refreshStatus(timeLeft: number?)
	if currentState == "WAITING" then
		statusLabel.Text = "Waiting for players…"
	elseif currentState == "INTERMISSION" then
		if timeLeft then
			statusLabel.Text = ("%s starts in %ds"):format(
				lastModeName or "Round", math.max(0, math.ceil(timeLeft)))
		else
			statusLabel.Text = "Round starting…"
		end
	elseif currentState == "ACTIVE" then
		local prefix = if lastModeName then lastModeName .. " • " else ""
		if lastTeamCounts then
			statusLabel.Text = ("%sRED %d v %d BLUE • %dx%d"):format(
				prefix, lastTeamCounts.RED or 0, lastTeamCounts.BLUE or 0, lastGridSize, lastGridSize)
		else
			statusLabel.Text = ("%sWave %d • %d alive • %dx%d"):format(
				prefix, lastWave, lastAlive, lastGridSize, lastGridSize)
		end
	elseif currentState == "WINNER" or currentState == "ROUNDOVER" then
		statusLabel.Text = "Round over"
	else
		statusLabel.Text = tostring(currentState)
	end
end

local function showEliminatedOverlay()
	elimToken += 1
	local token = elimToken
	elimOverlay.Visible = true
	elimOverlay.BackgroundTransparency = 1
	elimText.TextTransparency = 1
	TweenService:Create(elimOverlay, TweenInfo.new(0.15), { BackgroundTransparency = 0.45 }):Play()
	TweenService:Create(elimText, TweenInfo.new(0.15), { TextTransparency = 0 }):Play()
	task.delay(1.9, function()
		if elimToken ~= token then
			return
		end
		TweenService:Create(elimOverlay, TweenInfo.new(0.6), { BackgroundTransparency = 1 }):Play()
		TweenService:Create(elimText, TweenInfo.new(0.6), { TextTransparency = 1 }):Play()
		task.delay(0.65, function()
			if elimToken == token then
				elimOverlay.Visible = false
			end
		end)
	end)
end

--==============================================================================
-- Revenge pads: the server builds pressure pads ringing the active window
-- (see RevengeService) with a plain resting look. Locally the pads exist
-- ONLY for the eliminated: everyone else has them fully hidden and
-- non-collidable (character physics is client-owned, so a local CanCollide
-- change really does let the living walk through; the server-side Touched
-- still fires but requestThrow rejects them anyway). For the eliminated
-- viewer they glow: pulsing green READY or an amber cooldown countdown.
-- All property sets are local-only, so every player sees their own state
-- on the same shared parts.
--==============================================================================

-- Color IS the signal (no floating text): green pad = ready to stomp,
-- red pad = cooling down. Stomp outcomes arrive as red/green Notify cards
-- pushed by the server (RevengeService -> NotifyService).
local PAD_READY_A = Color3.fromRGB(70, 220, 100)
local PAD_READY_B = Color3.fromRGB(150, 255, 170)
local PAD_WAIT_A = Color3.fromRGB(170, 40, 35)
local PAD_WAIT_B = Color3.fromRGB(220, 65, 55)

local function paintPad(pad: BasePart, visible: boolean, remaining: number, pulse: number)
	pad.LocalTransparencyModifier = if visible then 0 else 1
	pad.CanCollide = visible -- the dead stand on them; the living walk through
	local surface = pad:FindFirstChild("PadSurface")
	if surface and surface:IsA("SurfaceGui") then
		surface.Enabled = visible
	end
	if not visible then
		return
	end
	pad.Material = Enum.Material.Neon
	if remaining <= 0 then
		pad.Color = PAD_READY_A:Lerp(PAD_READY_B, pulse) -- green: stomp me
	else
		pad.Color = PAD_WAIT_A:Lerp(PAD_WAIT_B, pulse * 0.4) -- red: not yet
	end
end

local function refreshRevengePads()
	local padsFolder = arena and arena:FindFirstChild("RevengePads")
	if not padsFolder then
		return
	end
	local visible = currentState == "ACTIVE" and locallyEliminated
	local remaining = revengeReadyAt - os.clock()
	local pulse = 0.5 + 0.5 * math.sin(os.clock() * 5)
	for _, pad in padsFolder:GetChildren() do
		if pad:IsA("BasePart") then
			paintPad(pad, visible, remaining, pulse)
		end
	end
end

-- Pads replicate server-visible; hide each one the moment it arrives so the
-- living never glimpse the ring at round start (the throttled repaint alone
-- would leave a one-tick flash). The folder outlives rounds - hook it once.
local padsHooked = false
local function ensurePadsHook()
	if padsHooked then
		return
	end
	local padsFolder = arena and arena:FindFirstChild("RevengePads")
	if not padsFolder then
		return
	end
	padsHooked = true
	padsFolder.ChildAdded:Connect(function(pad)
		if pad:IsA("BasePart") then
			task.defer(function() -- let the pad's guis replicate in behind it
				if pad.Parent then
					paintPad(pad, currentState == "ACTIVE" and locallyEliminated,
						revengeReadyAt - os.clock(), 0.5)
				end
			end)
		end
	end)
end

--==============================================================================
-- Near-miss detection: the server replicates live bull models into
-- BullrushArena.ActiveBulls and moves them every Heartbeat. Track each bull's
-- closest planar approach to the local character; once it recedes past that
-- minimum it has "passed" -- if the pass was close, punch the camera and play
-- a whoosh by the ear. The kill box half-extents are ~3.5x3.9 studs, so
-- GRAZE_DEADLY (5) means "a hair from dying" and GRAZE_RANGE (14) fades to
-- nothing. Fires at most once per bull; a bull that kills you is drowned out
-- by the bigger elimination slam anyway (trauma is capped).
--==============================================================================

local grazeTracked: { [Instance]: { minDist: number, fired: boolean } } = {}

local function updateNearMisses()
	local bullsFolder = arena and arena:FindFirstChild("ActiveBulls")
	if not bullsFolder then
		return
	end
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		table.clear(grazeTracked) -- death/respawn: stale approach distances would lie
		return
	end
	local here = hrp.Position

	local seen: { [Instance]: boolean } = {}
	for _, bull in ipairs(bullsFolder:GetChildren()) do
		local root = bull:IsA("Model") and (bull.PrimaryPart or bull:FindFirstChild("Root"))
		if root and root:IsA("BasePart") then
			seen[bull] = true
			local delta = root.Position - here
			local dist = Vector2.new(delta.X, delta.Z).Magnitude -- planar; ignore gallop bob
			local track = grazeTracked[bull]
			if not track then
				track = { minDist = dist, fired = false }
				grazeTracked[bull] = track
			elseif dist < track.minDist then
				track.minDist = dist
			end
			if not track.fired and track.minDist <= GRAZE_RANGE and dist > track.minDist + GRAZE_HYSTERESIS then
				track.fired = true
				if currentState == "ACTIVE" and not locallyEliminated then
					local closeness = 1
						- math.clamp((track.minDist - GRAZE_DEADLY) / (GRAZE_RANGE - GRAZE_DEADLY), 0, 1)
					addTrauma(0.35 + 0.45 * closeness)
					playOneShot("chargeWhoosh", { Volume = 0.2 + 0.35 * closeness, PlaybackSpeed = 1.25 })
					if closeness >= 0.5 then
						-- Phone-class devices buzz only on REALLY close shaves;
						-- gamepads already rumble via the trauma-driven motors.
						playHapticPulse("GameplayCollision")
					end
				end
			end
		end
	end

	-- Forget bulls that left the arena (destroyed on lane clear / round reset).
	for bull in pairs(grazeTracked) do
		if not seen[bull] then
			grazeTracked[bull] = nil
		end
	end
end

--==============================================================================
-- Remote handlers
--==============================================================================

telegraphRemote.OnClientEvent:Connect(function(lanes, warnTime, bounds)
	if typeof(lanes) ~= "table" then
		return
	end
	local warn_ = tonumber(warnTime) or 1.5
	local window = isBounds(bounds) and bounds or nil
	for _, lane in ipairs(lanes) do
		if isLane(lane) then
			local entry = registerLane(lane, window)
			spawnSilhouette(entry, warn_)
		end
	end
end)

chargeStartRemote.OnClientEvent:Connect(function(lane, duration, bounds)
	if not isLane(lane) then
		return
	end
	local chargeTime = tonumber(duration) or 1.5
	-- registerLane is defensive: highlights start even if Telegraph was missed
	-- (bounds passed through so a late registration still scopes to the window)
	local entry = registerLane(lane, isBounds(bounds) and bounds or nil)
	teardownLaneFX(entry, true) -- silhouette gone, rumble fades; tiles keep pulsing

	-- Launch kick: if this bull is aimed anywhere near the local player, jolt
	-- the camera so the charge feels like it is coming for THEM.
	if currentState == "ACTIVE" and not locallyEliminated then
		local dist = distanceToLaneLine(lane)
		if dist and dist <= SHAKE_RANGE then
			addTrauma(0.15 + 0.2 * (1 - dist / SHAKE_RANGE))
		end
	end

	playOneShot("chargeWhoosh", { Volume = 0.5, PlaybackSpeed = 0.85 })
	local stampede = makeSound("rumble", { Volume = 0.45, Looped = true, PlaybackSpeed = 1.2 }, SoundService)
	entry.chargeSound = stampede
	safePlay(stampede)
	task.delay(chargeTime + 0.25, function()
		if entry.chargeSound == stampede then
			entry.chargeSound = nil
			fadeOutAndDestroy(stampede, 0.35)
		end
	end)
end)

laneClearedRemote.OnClientEvent:Connect(function(lane)
	if not isLane(lane) then
		return
	end
	local entry = activeLanes[laneKey(lane)]
	if not entry then
		return
	end
	activeLanes[entry.key] = nil
	teardownLaneFX(entry, true)
	for _, part in ipairs(entry.tiles) do
		releaseTile(part, true) -- scorch, then restore to original over 2.5s
	end

	-- Heavy impact only if the local player is near the lane's center line
	local dist = distanceToLaneLine(lane)
	if dist and dist <= SHAKE_RANGE then
		local closeness = 1 - dist / SHAKE_RANGE -- 0 at the edge, 1 on the line
		addTrauma(0.55 + 0.45 * closeness)
		playOneShot("slam", { Volume = 0.35 + 0.25 * closeness })
		playOneShot("thud", { Volume = 0.3 + 0.2 * closeness, PlaybackSpeed = 0.55 })
	end
end)

-- Crumble burst at a dropping tile: one-shot dust plume from an invisible
-- part pinned at the tile's (pre-sink) top surface, so the puff hangs where
-- the floor used to be while the tile lerps down out from under it.
local function emitTileDebris(tile: BasePart)
	local holder = Instance.new("Part")
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.Transparency = 1
	holder.Size = Vector3.new(tile.Size.X, 0.2, tile.Size.Z)
	holder.CFrame = tile.CFrame * CFrame.new(0, tile.Size.Y / 2, 0)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(SCORCH_COLOR)
	emitter.Lifetime = NumberRange.new(0.4, 0.9)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.8),
		NumberSequenceKeypoint.new(1, 2.4),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Speed = NumberRange.new(4, 9)
	emitter.SpreadAngle = Vector2.new(75, 75)
	emitter.Acceleration = Vector3.new(0, -20, 0)
	emitter.Enabled = false
	emitter.Parent = holder
	holder.Parent = fxFolder
	emitter:Emit(14)
	Debris:AddItem(holder, 2)
end

-- Arena shrink: the server fires this at telegraph START; telegraphTime later
-- it sinks the removed tiles and snaps them charcoal. We pulse the doomed
-- tiles red (danger is danger), then ABANDON our claims at the exact sink
-- moment so the replicated charcoal wins over any local tween.
if arenaShrinkRemote then
	arenaShrinkRemote.OnClientEvent:Connect(function(stage, _bounds, removedCells, telegraphTime)
		if tonumber(stage) == nil or typeof(removedCells) ~= "table" then
			return
		end
		local sinkDelay = tonumber(telegraphTime)
			or (typeof(Config.SHRINK) == "table" and tonumber(Config.SHRINK.TELEGRAPH))
			or 3

		-- Claim every doomed tile through the shared ref-counted pulse system,
		-- tracked in shrinkClaimed (separate from lane entries).
		local claimed: { BasePart } = {}
		for _, cell in ipairs(removedCells) do
			if typeof(cell) == "table" then
				local row = tonumber(cell.row) or tonumber(cell[1])
				local col = tonumber(cell.col) or tonumber(cell[2])
				local part = row and col and tileParts[row .. "_" .. col]
				if part and not shrinkClaimed[part] then
					shrinkClaimed[part] = true
					table.insert(claimed, part)
					claimTile(part)
				end
			end
		end

		playOneShot("rumble", { Volume = 0.3, PlaybackSpeed = 0.5 })
		tremor = TREMOR_LEVEL -- the ground trembles for the whole telegraph window

		task.delay(sinkDelay, function()
			tremor = 0 -- tremble ends exactly when the floor drops
			-- A round reset may have abandoned these already; drop live claims only.
			local dropped = 0
			for _, part in ipairs(claimed) do
				if shrinkClaimed[part] then
					shrinkClaimed[part] = nil
					abandonTile(part)
					emitTileDebris(part)
					dropped += 1
				end
			end
			if dropped > 0 then
				-- The server drops the tiles at this same moment; sell the impact.
				addTrauma(0.5)
				playOneShot("slam", { Volume = 0.4 })
				playOneShot("thud", { Volume = 0.35, PlaybackSpeed = 0.5 })
			end
		end)
	end)
end

eliminatedRemote.OnClientEvent:Connect(function(playerName, aliveCount, cause)
	if tonumber(aliveCount) then
		lastAlive = tonumber(aliveCount) :: number
		if currentState == "ACTIVE" then
			refreshStatus(nil)
		end
	end
	if playerName == player.Name then
		locallyEliminated = true
		addTrauma(MAX_TRAUMA) -- trampled: the hardest hit the shake system allows
		playHapticPulse("GameplayExplosion") -- phones etc; gamepads peak via the trauma-driven motors
		showEliminatedOverlay()
		playOneShot("thud", { Volume = 0.6, PlaybackSpeed = 0.5 })
	end
	-- Other players' eliminations reach the feed as server-pushed white cards
	-- (RoundService.eliminate -> NotifyService), not from this handler.
end)

if revengeAckRemote then
	revengeAckRemote.OnClientEvent:Connect(function(kind, data)
		if kind == "THROW_OK" then
			local cooldown = (typeof(data) == "table" and tonumber(data.cooldown))
				or (typeof(Config.REVENGE) == "table" and tonumber(Config.REVENGE.COOLDOWN))
				or 15
			revengeReadyAt = os.clock() + cooldown
			playOneShot("thud", { Volume = 0.4, PlaybackSpeed = 0.9 }) -- stomp feedback
		elseif kind == "HIT" then
			-- The reward card comes from the server (green, via NotifyService);
			-- this ack just punctuates it.
			playOneShot("slam", { Volume = 0.3 })
		elseif kind == "DENIED" and typeof(data) == "table" then
			-- Server-authoritative resync (e.g. we rejoined mid-cooldown and
			-- our local timer reads READY): adopt the server's remaining time.
			local remaining = tonumber(data.remaining)
			if data.reason == "COOLDOWN" and remaining then
				revengeReadyAt = math.max(revengeReadyAt, os.clock() + remaining)
			end
		end
	end)
end

roundStateRemote.OnClientEvent:Connect(function(state, info)
	if typeof(state) ~= "string" then
		return
	end
	if typeof(info) ~= "table" then
		info = {}
	end
	currentState = state
	if tonumber(info.wave) then
		lastWave = tonumber(info.wave) :: number
	end
	if tonumber(info.aliveCount) then
		lastAlive = tonumber(info.aliveCount) :: number
	end
	if tonumber(info.gridSize) then
		lastGridSize = tonumber(info.gridSize) :: number
	elseif state == "INTERMISSION" or state == "WAITING" then
		-- The server reconfigures the arena at the next round start, so fall
		-- back to the full grid until ACTIVE info says otherwise.
		lastGridSize = Config.GRID_SIZE
	end

	if typeof(info.modeName) == "string" then
		lastModeName = info.modeName
	elseif state == "WAITING" then
		lastModeName = nil -- no mode picked until players show up
	end
	lastTeamCounts = if state == "ACTIVE" and isTeamCounts(info.teamCounts)
		then info.teamCounts
		else nil

	local timeLeft = tonumber(info.timeLeft)
	if state == "INTERMISSION" and timeLeft then
		intermissionEndsAt = os.clock() + timeLeft
	else
		intermissionEndsAt = nil
	end
	lastIntermissionSecond = nil
	refreshStatus(timeLeft)

	if state ~= "ACTIVE" then
		locallyEliminated = false -- fresh eyes (and shakes) for the next round
		tremor = 0 -- no shrink telegraph survives a round transition
		clearAllLanes() -- safety net: no lane may outlive its round
		abandonAllShrinkClaims() -- nor may a shrink claim; server recolors at next round start
		revengeReadyAt = 0 -- server clears cooldowns between rounds; mirror it
	end
end)

--==============================================================================
-- The single per-frame binding: near-miss tracking, shake decay + gamepad
-- rumble, and the intermission countdown display
--==============================================================================

local revengeRefreshAccum = 0

RunService.RenderStepped:Connect(function(dt)
	-- Local intermission countdown (display only; server events stay authoritative)
	if currentState == "INTERMISSION" and intermissionEndsAt then
		local remaining = math.max(0, intermissionEndsAt - os.clock())
		local second = math.ceil(remaining)
		if second ~= lastIntermissionSecond then
			lastIntermissionSecond = second
			refreshStatus(remaining)
		end
	end

	-- Revenge pad repaint (world buttons), throttled: visibility + glow +
	-- countdown are a per-viewer local paint. 0.1s keeps the ready pulse
	-- smooth without per-frame property churn. The hook is ensured every
	-- frame (cheap flag check) so pad spawns are hidden the instant they
	-- replicate, even before the first ACTIVE tick.
	ensurePadsHook()
	if currentState == "ACTIVE" then
		revengeRefreshAccum += dt
		if revengeRefreshAccum >= 0.1 then
			revengeRefreshAccum = 0
			refreshRevengePads()
		end
	end

	updateNearMisses()

	-- Trauma-based camera shake: punchy trauma decays fast; tremor holds a
	-- sustained floor until whoever set it clears it. One combined level so
	-- overlapping sources can never fight over CameraOffset. Gamepad motors
	-- follow the same level and are zeroed by the same dirty-flag reset (which
	-- must run even with no character, so shakeDirty is set unconditionally).
	local shakeLevel = math.min(trauma + tremor, MAX_TRAUMA)
	if shakeLevel > 0 then
		trauma = math.max(0, trauma - dt / SHAKE_DECAY_TIME)
		shakeDirty = true
		local humanoid = getHumanoid()
		if humanoid then
			local intensity = shakeLevel * shakeLevel * SHAKE_MAGNITUDE
			humanoid.CameraOffset = Vector3.new(
				shakeRandom:NextNumber(-1, 1) * intensity,
				shakeRandom:NextNumber(-1, 1) * intensity,
				shakeRandom:NextNumber(-1, 1) * intensity * 0.4
			)
		end
		setGamepadRumble(shakeLevel)
	elseif shakeDirty then
		shakeDirty = false
		local humanoid = getHumanoid()
		if humanoid then
			humanoid.CameraOffset = Vector3.zero
		end
		setGamepadRumble(0)
	end
end)