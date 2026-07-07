--------------------------------------------------------------------------------
-- BullrushClient
-- Presentation layer for Bullrush Grid: lane telegraphs (tile pulse, bull
-- silhouette, rumble), charge audio, scorch + camera shake on lane clear,
-- near-miss graze shakes from live bulls, charge-launch camera kicks,
-- elimination feedback, arena-shrink FX (doom glow, ground tremor, and
-- a crumbling pillar collapse), gamepad rumble + device haptics mirroring
-- the shakes, and the
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
-- RevengeAck is OPTIONAL the same way: without it the revenge markers stay in
-- their server-painted resting look and everything else keeps working.
-- (Revenge throws are server-side ClickDetector markers — no remote to send.)
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

-- One-shot from the curated SoundService library (GameSFX group, same set
-- SoundDirector uses), cloned so overlapping plays never fight. Silent no-op
-- if the sound is missing or moderated.
local function playLibSfx(name: string, volume: number?, pitch: number?)
	local group = SoundService:FindFirstChild("GameSFX")
	local tmpl = group and group:FindFirstChild(name)
	if not (tmpl and tmpl:IsA("Sound")) then
		return
	end
	local s = tmpl:Clone()
	s.Looped = false
	if volume then
		s.Volume = volume
	end
	if pitch then
		s.PlaybackSpeed = pitch
	end
	s.Parent = SoundService
	pcall(function()
		s:Play()
	end)
	Debris:AddItem(s, 8)
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

-- Doom glow: a neon-red slab pinned just above a doomed tile's top, fading in
-- from invisible to a hot glow across the telegraph (quad ease-in: barely-there
-- at first, burning by the drop). Client-only parts in fxFolder, wiped at the
-- sink moment (or on round-reset abandon) - then the crumble takes over.
local DOOM_COLOR = Color3.fromRGB(255, 60, 30)
local DOOM_PEAK_TRANSPARENCY = 0.35 -- how hot the glow gets right before the drop
local tileDooms: { [BasePart]: BasePart } = {}

local function clearTileDoom(tile: BasePart)
	local slab = tileDooms[tile]
	if slab then
		tileDooms[tile] = nil
		slab:Destroy()
	end
end

local function spawnTileDoom(tile: BasePart, telegraphTime: number)
	clearTileDoom(tile)
	local slab = Instance.new("Part")
	slab.Anchored = true
	slab.CanCollide = false
	slab.CanQuery = false
	slab.CanTouch = false
	slab.CastShadow = false
	slab.Color = DOOM_COLOR
	slab.Material = Enum.Material.Neon
	slab.Transparency = 1
	slab.Size = Vector3.new(tile.Size.X, 0.1, tile.Size.Z)
	slab.CFrame = CFrame.new(tile.Position + Vector3.new(0, tile.Size.Y / 2 + 0.06, 0))
	slab.Parent = fxFolder
	tileDooms[tile] = slab
	TweenService:Create(slab, TweenInfo.new(
		math.max(telegraphTime, 0.2),
		Enum.EasingStyle.Quad,
		Enum.EasingDirection.In
	), { Transparency = DOOM_PEAK_TRANSPARENCY }):Play()
end

-- Round reset safety: abandon (never restore) every outstanding shrink claim.
-- The server restores canonical tile positions/colors at the next round start.
local function abandonAllShrinkClaims()
	for part in pairs(shrinkClaimed) do
		shrinkClaimed[part] = nil
		abandonTile(part)
		clearTileDoom(part)
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
			-- Ghosts park right at lane starts, beside the revenge markers:
			-- never let them soak up the bull-cam's click rays.
			desc.CanQuery = false
			desc.CanTouch = false
			if desc ~= ghost.PrimaryPart and desc.Name ~= "Root" then
				desc.Color = SILHOUETTE_COLOR
				desc.Material = Enum.Material.SmoothPlastic
				desc.Transparency = 0.55
			end
		elseif desc:IsA("SurfaceAppearance") then
			-- The bison's baked texture overrides part Color, which would
			-- leave the ghost fully opaque-looking; strip it so the tint reads.
			desc:Destroy()
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

-- Revenge onboarding: lands under ELIMINATED so the death screen itself
-- teaches the comeback mechanic.
local elimHint = Instance.new("TextLabel")
elimHint.Name = "ElimHint"
elimHint.AnchorPoint = Vector2.new(0.5, 0.5)
elimHint.Position = UDim2.fromScale(0.5, 0.56)
elimHint.Size = UDim2.new(1, -40, 0, 60)
elimHint.BackgroundTransparency = 1
elimHint.Font = Enum.Font.GothamBlack
elimHint.TextSize = 26
elimHint.TextWrapped = true
elimHint.TextColor3 = Color3.fromRGB(120, 255, 150)
elimHint.TextStrokeColor3 = Color3.fromRGB(0, 25, 0)
elimHint.TextStrokeTransparency = 0.4
elimHint.TextTransparency = 1
elimHint.Text = "GET REVENGE — hit BECOME A BULL (or step on the lobby pad) and click a lane from above!"
elimHint.ZIndex = 11
elimHint.Parent = elimOverlay

-- Revenge hit payoff: a big center-screen burst when YOUR bull tramples
-- someone — the small green money card alone is easy to miss.
local hitPopup = Instance.new("TextLabel")
hitPopup.Name = "RevengeHitPopup"
hitPopup.AnchorPoint = Vector2.new(0.5, 0.5)
hitPopup.Position = UDim2.fromScale(0.5, 0.3)
hitPopup.Size = UDim2.new(1, 0, 0, 64)
hitPopup.BackgroundTransparency = 1
hitPopup.Font = Enum.Font.GothamBlack
hitPopup.TextSize = 46
hitPopup.TextColor3 = Color3.fromRGB(120, 255, 150)
hitPopup.TextStrokeColor3 = Color3.fromRGB(0, 25, 0)
hitPopup.TextStrokeTransparency = 0.3
hitPopup.TextTransparency = 1
hitPopup.Visible = false
hitPopup.ZIndex = 12
hitPopup.Parent = hud

local hitPopupToken = 0
local function showHitPopup(text: string)
	hitPopupToken += 1
	local token = hitPopupToken
	hitPopup.Text = text
	hitPopup.Visible = true
	hitPopup.TextTransparency = 0
	hitPopup.TextSize = 24
	TweenService:Create(hitPopup,
		TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ TextSize = 46 }):Play()
	task.delay(1.4, function()
		if hitPopupToken ~= token then
			return
		end
		TweenService:Create(hitPopup, TweenInfo.new(0.4), { TextTransparency = 1 }):Play()
		task.delay(0.45, function()
			if hitPopupToken == token then
				hitPopup.Visible = false
			end
		end)
	end)
end

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
-- DENIED): drives the marker glow/countdown repaint below.
local revengeReadyAt = 0 -- os.clock() when the next throw unlocks
local markersWereCooling = false -- edge-detects the cooldown lapping for the ready ding

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
	elimHint.TextTransparency = 1
	TweenService:Create(elimOverlay, TweenInfo.new(0.15), { BackgroundTransparency = 0.45 }):Play()
	TweenService:Create(elimText, TweenInfo.new(0.15), { TextTransparency = 0 }):Play()
	-- The revenge hint lands a beat after the gut punch, and the overlay
	-- holds a little longer so it can actually be read.
	TweenService:Create(elimHint,
		TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, 0.5),
		{ TextTransparency = 0 }):Play()
	task.delay(2.6, function()
		if elimToken ~= token then
			return
		end
		TweenService:Create(elimOverlay, TweenInfo.new(0.6), { BackgroundTransparency = 1 }):Play()
		TweenService:Create(elimText, TweenInfo.new(0.6), { TextTransparency = 1 }):Play()
		TweenService:Create(elimHint, TweenInfo.new(0.6), { TextTransparency = 1 }):Play()
		task.delay(0.65, function()
			if elimToken == token then
				elimOverlay.Visible = false
			end
		end)
	end)
end

--==============================================================================
-- Revenge markers: the server builds clickable arrow markers ringing the
-- active window (see RevengeService), one at each end of every row/column,
-- each carrying a server-side ClickDetector. The eliminated click them from
-- the overhead bull-cam (next section). Locally the markers exist ONLY for
-- the eliminated: everyone else has them fully hidden and their click range
-- zeroed. For the eliminated viewer they glow: pulsing green READY or red
-- while cooling down, and the marker you fire sinks and springs back. All
-- property sets are local-only, so every player sees their own state on the
-- same shared parts.
--==============================================================================

-- Color IS the signal (no floating text): green marker = ready to click,
-- red marker = cooling down. Outcomes arrive as red/green Notify cards
-- pushed by the server (RevengeService -> NotifyService).
local MARKER_READY_A = Color3.fromRGB(70, 220, 100)
local MARKER_READY_B = Color3.fromRGB(150, 255, 170)
local MARKER_WAIT_A = Color3.fromRGB(170, 40, 35)
local MARKER_WAIT_B = Color3.fromRGB(220, 65, 55)
local MARKER_PLATE_COLOR = Color3.fromRGB(26, 22, 20) -- dark leather button face
local MARKER_CLICK_RANGE = 512 -- mirror of the server's build value; zeroed locally when hidden/cooling

-- The glyphs are white; these vertical ramps tint them per state — the same
-- hot-highlight -> saturated-mid -> deep-shade style as the notif cards.
local GLYPH_READY = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(215, 255, 225)),
	ColorSequenceKeypoint.new(0.45, Color3.fromRGB(110, 255, 145)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(30, 150, 70)),
})
local GLYPH_WAIT = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 215, 210)),
	ColorSequenceKeypoint.new(0.45, Color3.fromRGB(255, 110, 95)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(150, 30, 25)),
})

local function tintGlyph(label: Instance?, ramp: ColorSequence)
	if not (label and label:IsA("TextLabel")) then
		return
	end
	local tint = label:FindFirstChild("Tint")
	if not (tint and tint:IsA("UIGradient")) then
		tint = Instance.new("UIGradient")
		tint.Name = "Tint"
		tint.Rotation = 90
		tint.Parent = label
	end
	tint.Color = ramp
end

local function paintMarker(pad: BasePart, visible: boolean, remaining: number, pulse: number)
	pad.LocalTransparencyModifier = if visible then 0 else 1
	local surface = pad:FindFirstChild("MarkerSurface")
	local gui = if surface and surface:IsA("SurfaceGui") then surface else nil
	if gui then
		gui.Enabled = visible
	end
	-- MaxActivationDistance is a plain property: setting it locally only
	-- affects THIS viewer, so the living can never even hover the markers.
	local click = pad:FindFirstChildOfClass("ClickDetector")
	if click then
		click.MaxActivationDistance = if visible and remaining <= 0 then MARKER_CLICK_RANGE else 0
	end
	if not visible then
		return
	end
	pad.Material = Enum.Material.Neon
	-- Face readout (all local-only): the dark PLATE frame is the button body
	-- (state shows in its pulsing rim, the gradient-tinted glyphs, and the
	-- neon part sides — not a flood-filled face, matching the notif-card
	-- style). While recharging: big countdown number + sweeping fill bar;
	-- ready: arrow + SEND BULL.
	local plate = gui and gui:FindFirstChild("Plate")
	if not (plate and plate:IsA("Frame")) then
		return
	end
	local arrow = plate:FindFirstChild("Arrow")
	local caption = plate:FindFirstChild("Caption")
	local rim = plate:FindFirstChild("Rim")
	local fill = plate:FindFirstChild("CooldownFill")
	if not fill then
		local bar = Instance.new("Frame")
		bar.Name = "CooldownFill"
		bar.AnchorPoint = Vector2.new(0.5, 1)
		bar.Position = UDim2.fromScale(0.5, 0.96)
		bar.Size = UDim2.fromScale(0, 0.07)
		bar.BorderSizePixel = 0
		bar.BackgroundColor3 = Color3.fromRGB(255, 240, 235)
		bar.BackgroundTransparency = 0.15
		local barCorner = Instance.new("UICorner")
		barCorner.CornerRadius = UDim.new(0.5, 0)
		barCorner.Parent = bar
		bar.Parent = plate
		fill = bar
	end
	plate.BackgroundColor3 = MARKER_PLATE_COLOR
	local stateColor
	if remaining <= 0 then
		stateColor = MARKER_READY_A:Lerp(MARKER_READY_B, pulse) -- green: click me
		if arrow and arrow:IsA("TextLabel") then
			arrow.Text = "▲"
		end
		if caption and caption:IsA("TextLabel") then
			caption.Text = "SEND BULL"
		end
		tintGlyph(arrow, GLYPH_READY)
		tintGlyph(caption, GLYPH_READY)
		if fill:IsA("Frame") then
			fill.Visible = false
		end
	else
		stateColor = MARKER_WAIT_A:Lerp(MARKER_WAIT_B, pulse * 0.4) -- red: not yet
		if arrow and arrow:IsA("TextLabel") then
			arrow.Text = tostring(math.ceil(remaining))
		end
		if caption and caption:IsA("TextLabel") then
			caption.Text = "RECHARGING"
		end
		tintGlyph(arrow, GLYPH_WAIT)
		tintGlyph(caption, GLYPH_WAIT)
		if fill:IsA("Frame") then
			fill.Visible = true
			local cooldown = (typeof(Config.REVENGE) == "table" and tonumber(Config.REVENGE.COOLDOWN)) or 15
			fill.Size = UDim2.fromScale((1 - math.clamp(remaining / cooldown, 0, 1)) * 0.9, 0.07)
		end
	end
	if rim and rim:IsA("UIStroke") then
		rim.Color = stateColor -- the rim pulses with the state
	end
	pad.Color = stateColor -- neon sides glow the state color from any angle
end

-- Hover feel (local-only): the plate grows and blips when your cursor finds
-- a clickable marker. ClickDetector hover events fire on the client too, and
-- the click range is zeroed unless the marker is visible + ready, so these
-- never fire for the living or during cooldown.
local markerHoverHooked = setmetatable({} :: { [BasePart]: boolean }, { __mode = "k" })

local function hookMarkerHover(marker: BasePart)
	if markerHoverHooked[marker] then
		return
	end
	markerHoverHooked[marker] = true
	task.defer(function() -- let the marker's gui/detector replicate in behind it
		if not marker.Parent then
			return
		end
		local click = marker:FindFirstChildOfClass("ClickDetector")
		local surface = marker:FindFirstChild("MarkerSurface")
		local plate = surface and surface:FindFirstChild("Plate")
		local scale = plate and plate:FindFirstChild("HoverScale")
		if not (click and scale and scale:IsA("UIScale")) then
			return
		end
		click.MouseHoverEnter:Connect(function()
			TweenService:Create(scale,
				TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Scale = 1.09 }):Play()
			playLibSfx("Click", 0.35, 1.5) -- same hover blip the shop buttons use
		end)
		click.MouseHoverLeave:Connect(function()
			TweenService:Create(scale,
				TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Scale = 1 }):Play()
		end)
	end)
end

local function refreshRevengeMarkers()
	local markersFolder = arena and arena:FindFirstChild("RevengeMarkers")
	if not markersFolder then
		return
	end
	local visible = currentState == "ACTIVE" and locallyEliminated
	local remaining = revengeReadyAt - os.clock()
	local pulse = 0.5 + 0.5 * math.sin(os.clock() * 5)
	-- Ready ding the moment the cooldown laps, so you don't have to stare at
	-- a marker face to know your next bull is up.
	local cooling = remaining > 0
	if markersWereCooling and not cooling and visible then
		playLibSfx("Confirm", 0.8, 1.15)
	end
	markersWereCooling = visible and cooling
	for _, marker in markersFolder:GetChildren() do
		if marker:IsA("BasePart") then
			paintMarker(marker, visible, remaining, pulse)
			hookMarkerHover(marker) -- weak-set no-op after the first call
		end
	end
end

-- Markers replicate server-visible; hide each one the moment it arrives so
-- the living never glimpse the ring at round start (the throttled repaint
-- alone would leave a one-tick flash). The folder outlives rounds - hook it
-- once.
local markersHooked = false
local function ensureMarkersHook()
	if markersHooked then
		return
	end
	local markersFolder = arena and arena:FindFirstChild("RevengeMarkers")
	if not markersFolder then
		return
	end
	markersHooked = true
	markersFolder.ChildAdded:Connect(function(marker)
		if marker:IsA("BasePart") then
			task.defer(function() -- let the marker's guis replicate in behind it
				if marker.Parent then
					paintMarker(marker, currentState == "ACTIVE" and locallyEliminated,
						revengeReadyAt - os.clock(), 0.5)
					hookMarkerHover(marker)
				end
			end)
		end
	end)
end

--==============================================================================
-- Arena base: same per-viewer trick as the markers. The base slab and the
-- ring decor that sits on it (skirt, corner posts, hay, rocks) exist only
-- for the eliminated, whose overhead bull-cam looks down on it (a floating
-- grid over void reads wrong from above). Everyone else has
-- the lot hidden -- and the slab non-collidable (character physics is
-- client-owned, so the local CanCollide really is what the living fall
-- through) -- leaving them a floating tile grid. All property sets are
-- local-only. The lobby-side FencePosts are spared: they sit on the lobby
-- floor, not the base.
--==============================================================================

local function refreshArenaBase()
	local visible = currentState == "ACTIVE" and locallyEliminated
	local base = arena:FindFirstChild("ArenaBase")
	if base and base:IsA("BasePart") then
		base.LocalTransparencyModifier = if visible then 0 else 1
		base.CanCollide = visible -- the dead walk the ring; the living fall past it
	end
	local decor = arena:FindFirstChild("Decor")
	if decor then
		for _, part in decor:GetChildren() do
			if part:IsA("BasePart") and part.Name ~= "FencePost" then
				part.LocalTransparencyModifier = if visible then 0 else 1
			end
		end
	end
end

-- Streaming can hand the base (or its decor) back fully visible at any time;
-- hide each arrival immediately rather than waiting for the next repaint tick.
local baseHooked = false
local function ensureBaseHook()
	if baseHooked then
		return
	end
	baseHooked = true
	arena.ChildAdded:Connect(function(child)
		if child.Name == "ArenaBase" then
			task.defer(refreshArenaBase)
		end
	end)
	local decor = arena:FindFirstChild("Decor")
	if decor then
		decor.ChildAdded:Connect(function()
			task.defer(refreshArenaBase)
		end)
	end
end

ensureBaseHook()
refreshArenaBase() -- hide at load; don't wait for the first repaint tick

--==============================================================================
-- Ghost players: an eliminated participant who roams the ring (or the lobby)
-- is invisible to the living -- no distracting dead players hopping around
-- the pads -- but stays visible to fellow eliminated viewers. Same per-viewer
-- local painting as the pads/base. The Eliminated remote reaches every
-- client with the victim's name, so each viewer keeps its own name set for
-- the round. The Health > 0 guard spares the ragdolled corpse mid-fling
-- (that's the kill's juice); only the respawned character ghosts out. A late
-- joiner misses earlier Eliminated events and sees those ghosts -- accepted.
--==============================================================================

local eliminatedNames: { [string]: boolean } = {}
-- character -> saved nameplate mode; entry existing = "this viewer hid it".
-- Weak keys so despawned characters never pin memory or need cleanup.
local ghostHidden = setmetatable(
	{} :: { [Model]: { nameplate: Enum.HumanoidDisplayDistanceType? } },
	{ __mode = "k" }
)

local function setCharacterHidden(character: Model, hidden: boolean)
	if hidden then
		local entry = ghostHidden[character]
		if not entry then
			entry = {}
			ghostHidden[character] = entry
		end
		-- Re-sweep every call: accessories/parts may replicate in after the
		-- first hide and would otherwise pop in visible.
		for _, d in character:GetDescendants() do
			if d:IsA("BasePart") or d:IsA("Decal") then
				d.LocalTransparencyModifier = 1
			end
		end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid and entry.nameplate == nil then
			entry.nameplate = humanoid.DisplayDistanceType
			humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		end
	else
		local entry = ghostHidden[character]
		if not entry then
			return -- never hidden by us; nothing to restore
		end
		ghostHidden[character] = nil
		for _, d in character:GetDescendants() do
			if d:IsA("BasePart") or d:IsA("Decal") then
				d.LocalTransparencyModifier = 0
			end
		end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid and entry.nameplate ~= nil then
			humanoid.DisplayDistanceType = entry.nameplate
		end
	end
end

local function refreshGhosts()
	for _, other in Players:GetPlayers() do
		if other ~= player then
			local character = other.Character
			if character then
				local humanoid = character:FindFirstChildOfClass("Humanoid")
				local shouldHide = currentState == "ACTIVE"
					and not locallyEliminated -- the dead see their own kind
					and eliminatedNames[other.Name] == true
					and humanoid ~= nil
					and humanoid.Health > 0 -- corpse stays visible while it flies
				setCharacterHidden(character, shouldHide)
			end
		end
	end
end

-- Respawns hand every viewer a fresh, fully visible character; re-evaluate
-- immediately instead of waiting for the repaint tick.
local function watchGhostCandidate(other: Player)
	if other == player then
		return
	end
	other.CharacterAdded:Connect(function()
		task.defer(refreshGhosts)
	end)
end
for _, other in Players:GetPlayers() do
	watchGhostCandidate(other)
end
Players.PlayerAdded:Connect(watchGhostCandidate)

-- Click feedback: on an accepted throw the acked lane's marker sinks and
-- springs back. Local-only CFrame tween on the shared anchored part; the
-- rest CFrame is remembered per marker (weak keys) so a THROW_OK landing
-- mid-animation can't capture a sunk position and make the marker drift.
local markerRestCFrames = setmetatable({} :: { [BasePart]: CFrame }, { __mode = "k" })

local function pressMarkerFeedback(lane)
	local markersFolder = arena and arena:FindFirstChild("RevengeMarkers")
	if not (markersFolder and isLane(lane)) then
		return
	end
	local target: BasePart? = nil
	for _, marker in markersFolder:GetChildren() do
		if marker:IsA("BasePart")
			and marker:GetAttribute("axis") == lane.axis
			and marker:GetAttribute("index") == lane.index
			and marker:GetAttribute("direction") == lane.direction
		then
			target = marker
			break
		end
	end
	if not target then
		return -- a shrink refresh can race the ack; skip quietly
	end
	local rest = markerRestCFrames[target] or target.CFrame
	markerRestCFrames[target] = rest
	local down = TweenService:Create(target,
		TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ CFrame = rest - Vector3.new(0, 0.5, 0) })
	down.Completed:Once(function()
		if target.Parent then
			TweenService:Create(target,
				TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
				{ CFrame = rest }):Play()
		end
	end)
	down:Play()
end

-- Lobby BullCamPad ("Become a Bull"): stepping onto it flips the overhead
-- bull-cam on (see updateOverhead below) - purely client-side, no server
-- script. Only meaningful while a round is ACTIVE and you're an eliminated
-- participant, so hide it from everyone else - same visibility rule as the
-- markers. Change-only writes; unlike the per-round marker ring this part
-- is permanent, so the refresh must also run OUTSIDE ACTIVE to re-hide it
-- when the round ends.
local bullCamPadVisible: boolean? = nil -- tri-state: nil forces the first paint

-- The pad lives somewhere the user parks it (currently Workspace.Lobby), so
-- find it recursively once and cache; re-search only if it despawns.
local bullCamPadCache: BasePart? = nil
local function getBullCamPad(): BasePart?
	if bullCamPadCache and bullCamPadCache.Parent then
		return bullCamPadCache
	end
	local found = workspace:FindFirstChild("BullCamPad", true)
	bullCamPadCache = if found and found:IsA("BasePart") then found else nil
	return bullCamPadCache
end

local function refreshBullCamPad()
	local pad = getBullCamPad()
	if not pad then
		return
	end
	local visible = currentState == "ACTIVE" and locallyEliminated
	if bullCamPadVisible == visible then
		return
	end
	bullCamPadVisible = visible
	pad.LocalTransparencyModifier = if visible then 0 else 1
	for _, child in pad:GetChildren() do
		if child:IsA("Highlight") or child:IsA("BillboardGui") then
			child.Enabled = visible
		end
	end
end

--==============================================================================
-- Overhead bull-cam: eliminated participants aim revenge bulls from a fixed
-- top-down camera that frames the CURRENT window (re-framing as it shrinks),
-- clicking the arrow markers instead of walking the ring. Enter by stepping
-- onto the lobby BullCamPad or via the HUD "Become a Bull" button
-- (StarterGui.Main owns the button per the UI rule; it talks to this script
-- through the RevengeViewBridge BindableEvent in ReplicatedStorage). The
-- character FREEZES where it stands (character physics is client-owned, so
-- the anchor is real) while viewing. Exit: the button again, E / gamepad B,
-- the character somehow leaving its freeze spot (a server teleport), or the
-- round ending.
--==============================================================================

local OVERHEAD_MARGIN = 16 -- studs beyond the window edge kept in frame (covers the marker ring)
local OVERHEAD_DRIFT_EXIT = 8 -- freeze-spot drift that force-exits the cam (server moved us)

local overheadViewing = false
local overheadTweening = false
local overheadFreezePos: Vector3? = nil
local overheadSaved: { walkSpeed: number, jumpPower: number, jumpHeight: number, autoRotate: boolean }? = nil
local wasOnBullCamPad = false
local lastBounds: GridUtil.Bounds? = nil -- ACTIVE window, from RoundState/ArenaShrink

-- StarterGui.Main's HUD button drives the cam through this bridge (client-
-- created local instance; never replicates): Fire() toggles, attributes
-- broadcast eligibility + viewing state back to the button.
local viewBridge = Instance.new("BindableEvent")
viewBridge.Name = "RevengeViewBridge"
viewBridge:SetAttribute("Eligible", false)
viewBridge:SetAttribute("Viewing", false)
viewBridge.Parent = ReplicatedStorage

local function updateBridgeAttributes()
	-- SetAttribute is change-detected; equal writes fire no signals.
	viewBridge:SetAttribute("Eligible", currentState == "ACTIVE" and locallyEliminated)
	viewBridge:SetAttribute("Viewing", overheadViewing)
end

-- Straight-down framing of the active window plus the marker ring: the eye
-- must fit BOTH the ground plane (window + margin) and the raised marker
-- plane (markers float above the guard walls so clicks can't be occluded --
-- MARKER_PLANE_LIFT mirrors RevengeService's MARKER_HOVER). Height is
-- whatever fits the tighter screen axis. Up vector is world -Z so north (row
-- 1) reads as screen-up and the shot can never roll.
local MARKER_PLANE_LIFT = 17 -- mirror of RevengeService MARKER_HOVER
local MARKER_RING_REACH = 11.5 -- wall 1 + gap 1.5 + full 6-stud marker + 3 pad, beyond the tile edge

local function overheadCFrame(): CFrame
	local camera = workspace.CurrentCamera
	local window = lastBounds or GridUtil.boundsForStage(0)
	local minC = GridUtil.tileCenter(window.rowMin, window.colMin)
	local maxC = GridUtil.tileCenter(window.rowMax, window.colMax)
	local center = (minC + maxC) / 2
	local halfFov = math.rad((camera and camera.FieldOfView or 70) / 2)
	local aspect = if camera and camera.ViewportSize.Y > 0
		then camera.ViewportSize.X / camera.ViewportSize.Y
		else 1.78
	-- eye height that fits a half-extent (x, z) plane sitting at planeY
	local function fitPlane(halfX: number, halfZ: number, planeY: number): number
		return planeY + math.max(halfZ / math.tan(halfFov), halfX / (math.tan(halfFov) * aspect))
	end
	local coreX = (maxC.X - minC.X) / 2 + Config.TILE_SIZE / 2
	local coreZ = (maxC.Z - minC.Z) / 2 + Config.TILE_SIZE / 2
	local eyeY = math.max(
		fitPlane(coreX + OVERHEAD_MARGIN, coreZ + OVERHEAD_MARGIN, Config.ARENA_ORIGIN.Y),
		fitPlane(coreX + MARKER_RING_REACH, coreZ + MARKER_RING_REACH,
			Config.ARENA_ORIGIN.Y + MARKER_PLANE_LIFT)
	)
	local eye = Vector3.new(center.X, eyeY, center.Z)
	return CFrame.lookAt(eye, Vector3.new(center.X, Config.ARENA_ORIGIN.Y, center.Z), Vector3.new(0, 0, -1))
end

local function exitOverhead()
	if not overheadViewing then
		return
	end
	overheadViewing = false
	overheadTweening = false
	overheadFreezePos = nil
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if hrp and hrp:IsA("BasePart") then
		hrp.Anchored = false
	end
	if humanoid and overheadSaved then
		humanoid.WalkSpeed = overheadSaved.walkSpeed
		humanoid.JumpPower = overheadSaved.jumpPower
		humanoid.JumpHeight = overheadSaved.jumpHeight
		humanoid.AutoRotate = overheadSaved.autoRotate
	end
	overheadSaved = nil
	local camera = workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Custom
		if humanoid then
			camera.CameraSubject = humanoid
		end
	end
	updateBridgeAttributes()
end

local function enterOverhead()
	if overheadViewing then
		return
	end
	if not (currentState == "ACTIVE" and locallyEliminated) then
		return
	end
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local camera = workspace.CurrentCamera
	if not (hrp and hrp:IsA("BasePart") and humanoid and humanoid.Health > 0 and camera) then
		return
	end
	overheadViewing = true
	overheadFreezePos = hrp.Position
	overheadSaved = {
		walkSpeed = humanoid.WalkSpeed,
		jumpPower = humanoid.JumpPower,
		jumpHeight = humanoid.JumpHeight,
		autoRotate = humanoid.AutoRotate,
	}
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0
	humanoid.JumpHeight = 0
	humanoid.AutoRotate = false
	hrp.Anchored = true
	camera.CameraType = Enum.CameraType.Scriptable
	overheadTweening = true
	local swoop = TweenService:Create(camera,
		TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
		{ CFrame = overheadCFrame() })
	swoop.Completed:Once(function()
		overheadTweening = false
	end)
	swoop:Play()
	playOneShot("chargeWhoosh", { Volume = 0.35, PlaybackSpeed = 1.1 })
	updateBridgeAttributes()
end

viewBridge.Event:Connect(function()
	if overheadViewing then
		exitOverhead()
	else
		enterOverhead()
	end
end)

-- Keyboard/gamepad exit; entry is the pad or the HUD button only.
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed or not overheadViewing then
		return
	end
	if input.KeyCode == Enum.KeyCode.E or input.KeyCode == Enum.KeyCode.ButtonB then
		exitOverhead()
	end
end)

-- Per-tick keeper (0.25s): while viewing, enforce exit conditions and keep
-- the camera glued to the (possibly shrunken) window; while not, watch for
-- the character stepping onto the BullCamPad. Pad entry fires on the
-- outside -> inside edge only, so exiting while still standing on the pad
-- doesn't instantly re-enter.
local function updateOverhead()
	updateBridgeAttributes() -- safety repaint for the HUD button's state
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if overheadViewing then
		if currentState ~= "ACTIVE" or not locallyEliminated
			or not (hrp and humanoid and humanoid.Health > 0)
			or (overheadFreezePos ~= nil
				and (hrp.Position - overheadFreezePos).Magnitude > OVERHEAD_DRIFT_EXIT)
		then
			exitOverhead()
			return
		end
		if not overheadTweening then
			local camera = workspace.CurrentCamera
			if camera then
				camera.CFrame = overheadCFrame() -- tracks shrink + viewport changes
			end
		end
		return
	end
	local onPad = false
	if currentState == "ACTIVE" and locallyEliminated and hrp then
		local pad = getBullCamPad()
		if pad then
			local offset = hrp.Position - pad.Position
			onPad = math.abs(offset.X) <= pad.Size.X / 2 + 0.5
				and math.abs(offset.Z) <= pad.Size.Z / 2 + 0.5
				and offset.Y >= 0 and offset.Y <= 8
		end
	end
	if onPad and not wasOnBullCamPad then
		enterOverhead()
	end
	wasOnBullCamPad = onPad
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

-- Crumble-in-motion: while the server lerps a doomed pillar into the pit, a
-- dust plume streams off the whole shaft and chips of it break away from the
-- rim. Chips read the tile's CURRENT position at spawn, so later waves break
-- off lower as the pillar falls; gravity and Debris handle the rest.
local shrinkTremorGen = 0 -- invalidates a pending fall-quiet timer when a newer telegraph/fall starts

local function attachSinkDust(tile: BasePart, sinkTime: number)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "CrumbleDust"
	emitter.Color = ColorSequence.new(SCORCH_COLOR)
	emitter.Lifetime = NumberRange.new(0.5, 1.1)
	emitter.Rate = 24
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.2),
		NumberSequenceKeypoint.new(1, 3.2),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Speed = NumberRange.new(2, 5)
	emitter.SpreadAngle = Vector2.new(60, 60)
	emitter.Acceleration = Vector3.new(0, -12, 0)
	emitter.Parent = tile -- local-only child of the server tile; Debris reaps it
	task.delay(sinkTime, function()
		emitter.Enabled = false -- landed: the shaft vanishes, the dust stops
	end)
	Debris:AddItem(emitter, sinkTime + 1.5)
end

local function spawnCrumbleChip(tile: BasePart, rng: Random)
	local half = tile.Size.X / 2
	local side = rng:NextInteger(1, 4)
	local edge = if side == 1
		then Vector3.new(-half, 0, rng:NextNumber(-half, half))
		elseif side == 2 then Vector3.new(half, 0, rng:NextNumber(-half, half))
		elseif side == 3 then Vector3.new(rng:NextNumber(-half, half), 0, -half)
		else Vector3.new(rng:NextNumber(-half, half), 0, half)
	local chip = Instance.new("Part")
	chip.Size = Vector3.new(rng:NextNumber(0.5, 1.4), rng:NextNumber(0.5, 1.4), rng:NextNumber(0.5, 1.4))
	chip.CFrame = CFrame.new(tile.Position + edge + Vector3.new(0, tile.Size.Y / 2, 0))
		* CFrame.Angles(rng:NextNumber(0, math.pi), rng:NextNumber(0, math.pi), 0)
	chip.Color = tile.Color
	chip.Material = tile.Material
	chip.CanCollide = false
	chip.CanQuery = false
	chip.CanTouch = false
	chip.CastShadow = false
	chip.AssemblyLinearVelocity = Vector3.new(edge.X, 0, edge.Z).Unit * rng:NextNumber(4, 10)
		+ Vector3.new(0, rng:NextNumber(2, 8), 0)
	chip.AssemblyAngularVelocity = Vector3.new(rng:NextNumber(-8, 8), rng:NextNumber(-8, 8), rng:NextNumber(-8, 8))
	chip.Parent = fxFolder
	Debris:AddItem(chip, 2.2)
end

-- Arena shrink: the server fires this at telegraph START; telegraphTime later
-- it sinks the removed tiles and snaps them charcoal. We pulse the doomed
-- tiles red (danger is danger) under a doom glow that brightens toward the
-- drop, then ABANDON our claims at the exact sink moment so the replicated
-- charcoal wins over any local tween - and crumble each pillar (dust, rim
-- chips, tremor, roar) for the whole fall.
if arenaShrinkRemote then
	arenaShrinkRemote.OnClientEvent:Connect(function(stage, shrinkBounds, removedCells, telegraphTime)
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
					spawnTileDoom(part, sinkDelay)
				end
			end
		end

		playOneShot("rumble", { Volume = 0.3, PlaybackSpeed = 0.5 })
		shrinkTremorGen += 1 -- a fresh telegraph owns the tremor now
		tremor = TREMOR_LEVEL -- the ground trembles for the whole telegraph window

		task.delay(sinkDelay, function()
			-- The window officially shrinks at this moment; the bull-cam
			-- reframes to it on its next tick. (Guarded so a round reset
			-- during the telegraph can't smear stale bounds into the next round.)
			if currentState == "ACTIVE" and isBounds(shrinkBounds) then
				lastBounds = shrinkBounds
			end
			-- A round reset may have abandoned these already; drop live claims only.
			local droppedTiles = {}
			for _, part in ipairs(claimed) do
				if shrinkClaimed[part] then
					shrinkClaimed[part] = nil
					abandonTile(part)
					clearTileDoom(part)
					emitTileDebris(part)
					table.insert(droppedTiles, part)
				end
			end
			if #droppedTiles == 0 then
				tremor = 0 -- nothing actually fell; end the tremble quietly
				return
			end
			-- The server starts the pillar fall at this same moment: sell the
			-- impact, then keep the ground grumbling until the pillars land.
			local sinkTime = (typeof(Config.SHRINK) == "table" and tonumber(Config.SHRINK.SINK_TIME)) or 1
			addTrauma(0.5)
			playOneShot("slam", { Volume = 0.4 })
			playOneShot("thud", { Volume = 0.35, PlaybackSpeed = 0.5 })
			playOneShot("rumble", { Volume = 0.5, PlaybackSpeed = 0.75 }) -- collapse roar over the fall
			shrinkTremorGen += 1
			local gen = shrinkTremorGen
			tremor = TREMOR_LEVEL * 1.5
			task.delay(sinkTime, function()
				if shrinkTremorGen == gen then
					tremor = 0 -- quiet only if a newer telegraph/fall hasn't taken over
				end
			end)
			-- Dust off every falling shaft plus rim chips in waves, budgeted so
			-- a MEGA ring drop (32 tiles) stays mobile-friendly.
			local rng = Random.new()
			local chipsPerTile = math.clamp(math.floor(140 / #droppedTiles), 3, 8)
			for _, part in ipairs(droppedTiles) do
				attachSinkDust(part, sinkTime)
				for _ = 1, chipsPerTile do
					task.delay(rng:NextNumber(0, sinkTime * 0.7), function()
						spawnCrumbleChip(part, rng)
					end)
				end
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
	if typeof(playerName) == "string" then
		eliminatedNames[playerName] = true -- ghost them for the living
	end
	if playerName == player.Name then
		locallyEliminated = true
		refreshArenaBase() -- the ring appears the instant you fall
		addTrauma(MAX_TRAUMA) -- trampled: the hardest hit the shake system allows
		playHapticPulse("GameplayExplosion") -- phones etc; gamepads peak via the trauma-driven motors
		showEliminatedOverlay()
		playOneShot("thud", { Volume = 0.6, PlaybackSpeed = 0.5 })
		updateBridgeAttributes() -- the HUD "Become a Bull" button appears now
	end
	refreshGhosts() -- hides the new ghost -- or, if WE just died, reveals them all
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
			pressMarkerFeedback(if typeof(data) == "table" then data.lane else nil) -- the marker sinks + springs back
			playOneShot("thud", { Volume = 0.4, PlaybackSpeed = 0.9 }) -- launch feedback
			addTrauma(0.5) -- the stomp lands: kick the thrower's camera too
			playHapticPulse("GameplayCollision")
			playLibSfx("Confirm", 0.9)
		elseif kind == "HIT" then
			-- Server still sends the green money card; this is the BIG payoff:
			-- a center-screen burst + shake so a trample never goes unnoticed.
			local victim = if typeof(data) == "table" then tostring(data.victimName or "someone") else "someone"
			local amount = if typeof(data) == "table" then tonumber(data.amount) else nil
			showHitPopup(if amount
				then ("TRAMPLED %s! +%d💰"):format(victim, amount)
				else ("TRAMPLED %s!"):format(victim))
			addTrauma(0.35)
			playHapticPulse("GameplayCollision")
			playOneShot("slam", { Volume = 0.45 })
			playOneShot("thud", { Volume = 0.35, PlaybackSpeed = 0.6 })
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

	-- The ACTIVE window drives the bull-cam framing; forget it between rounds.
	if state == "ACTIVE" and isBounds(info.bounds) then
		lastBounds = info.bounds
	elseif state ~= "ACTIVE" then
		lastBounds = nil
	end

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
		exitOverhead() -- the bull-cam never outlives the round (also unfreezes
		-- BEFORE the server's round-end lobby teleport, so the anchored HRP
		-- can't fight the PivotTo)
		tremor = 0 -- no shrink telegraph survives a round transition
		clearAllLanes() -- safety net: no lane may outlive its round
		abandonAllShrinkClaims() -- nor may a shrink claim; server recolors at next round start
		revengeReadyAt = 0 -- server clears cooldowns between rounds; mirror it
		table.clear(eliminatedNames) -- the dead rejoin the visible world
	end
	updateBridgeAttributes() -- eligibility changes with the state
	refreshArenaBase() -- visibility depends on state; repaint on every transition
	refreshGhosts()
end)

--==============================================================================
-- The single per-frame binding: near-miss tracking, shake decay + gamepad
-- rumble, and the intermission countdown display
--==============================================================================

local revengeRefreshAccum = 0
local baseRefreshAccum = 0

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

	-- Revenge marker repaint (world buttons), throttled: visibility + glow +
	-- countdown are a per-viewer local paint. 0.1s keeps the ready pulse
	-- smooth without per-frame property churn. The hook is ensured every
	-- frame (cheap flag check) so marker spawns are hidden the instant they
	-- replicate, even before the first ACTIVE tick.
	ensureMarkersHook()
	if currentState == "ACTIVE" then
		revengeRefreshAccum += dt
		if revengeRefreshAccum >= 0.1 then
			revengeRefreshAccum = 0
			refreshRevengeMarkers()
		end
	end

	-- Arena base + ghost repaint, throttled: cheap safety net behind the
	-- event-driven refreshes (elimination, state changes, stream-ins,
	-- respawns) so a missed edge can never leave the slab or a ghost in the
	-- wrong state for more than a beat. The ghost sweep also re-hides
	-- late-replicating accessories on already-hidden characters.
	baseRefreshAccum += dt
	if baseRefreshAccum >= 0.25 then
		baseRefreshAccum = 0
		refreshArenaBase()
		refreshGhosts()
		refreshBullCamPad() -- change-guarded; hides again when the round ends
		updateOverhead() -- bull-cam exit conditions, reframing, and pad entry
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