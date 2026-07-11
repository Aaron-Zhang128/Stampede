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
-- never touches server state. The physical arena is 11x11; each round plays a
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
-- RevengeAck / RevengeThrow are OPTIONAL the same way: without them the
-- revenge lane-select controls stay inert and everything else keeps working.
-- (RevengeThrow is created by RevengeService at server boot, so it can land
-- in the folder a beat after join — hence the same generous waitFor.)
local revengeAckRemote = waitFor(remotes, "RevengeAck")
local revengeThrowRemote = waitFor(remotes, "RevengeThrow")
-- BullVisual / BullVisualEnd are OPTIONAL the same way: bulls are client-
-- rendered (the server charge is pure kill-box logic; see BullService), so
-- without these remotes bulls simply don't render while everything else keeps
-- working. BullCatalog picks each bull's model + mutation aura.
local bullVisualRemote = waitFor(remotes, "BullVisual")
local bullVisualEndRemote = waitFor(remotes, "BullVisualEnd")
-- RagdollFling is server -> us when a bull connects: the server has already
-- swapped our joints for ball-sockets and killed the humanoid, and hands us the
-- launch vector so we simulate our own tumble locally (see the handler below).
-- OPTIONAL like the others: without it a bull hit still ragdolls us limp, just
-- without the launch arc.
local ragdollFlingRemote = waitFor(remotes, "RagdollFling")
local bullCatalogModule = waitFor(bullrushFolder, "BullCatalog")
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

-- Danger pulse: every threatened tile pulsates in UNISON (a red floor breathing
-- up to full red and back), so the whole lane reads as one warning. A live claim
-- owns the tile color every frame, so a new red indicator always wins over the
-- selection tint and any scorch/restore in progress.
local PULSE_WAVE_PERIOD = 0.7 -- seconds for one full pulse cycle
local PULSE_FLOOR = 0.4 -- min red intensity so the lane never reads as safe
local SCORCH_RESTORE_TIME = 2.5

local SHAKE_RANGE = 14 -- studs from the lane center line
local SHAKE_DECAY_TIME = 0.4
local SHAKE_MAGNITUDE = 1.3
local MAX_TRAUMA = 1.25

local GRAZE_RANGE = 14 -- planar studs: a bull's closest approach inside this counts as a near miss
local GRAZE_DEADLY = 5 -- at/inside this it practically brushed you: full-strength punch
local GRAZE_HYSTERESIS = 2 -- bull must recede this far past its closest approach before the punch fires
local TREMOR_LEVEL = 0.3 -- sustained shake floor while the arena-shrink telegraph runs

local GHOST_PAW_HZ = 8.5 -- pawing rhythm of the winding-up ghost bull
local STREAK_COLOR = Color3.fromRGB(255, 244, 224) -- warm-white near-miss speed lines

local NEARMISS_FOV = 2.6 -- degrees the view widens on a close shave
local HITSTOP_TIME = 0.08 -- seconds of frozen camera on a heavy impact (fake hitstop)

-- Client-side effects folder (created locally; never replicates)
local fxFolder = workspace:FindFirstChild("BullrushClientFX") or Instance.new("Folder")
fxFolder.Name = "BullrushClientFX"
fxFolder.Parent = workspace

--==============================================================================
-- Sounds (defensive: a bad/moderated ID can never error the script)
--==============================================================================

local SOUND_IDS = {
	rumble = 12222030, -- HalloweenThunder.wav (Roblox) — used pitched-down as a ground bed
	chargeWhoosh = 12222095, -- Rocket whoosh 01.wav (Roblox)
	slam = 146163534, -- Slap Hit (Stickmasterluke)
	thud = 12221944, -- bass.wav (Roblox)
	gallop = 3300268152, -- "horse gallopping sound" (verified loadable) — layered into a herd
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

local function fadeOutAndDestroy(sound: Instance?, fadeTime: number?)
	if not sound then
		return
	end
	if sound:IsA("Sound") then
		local tween = TweenService:Create(sound, TweenInfo.new(fadeTime or 0.3), { Volume = 0 })
		tween.Completed:Once(function()
			sound:Destroy()
		end)
		tween:Play()
	else
		-- Container of layers (the stampede herd): fade every child sound, then
		-- drop the whole folder once they've gone silent.
		for _, child in ipairs(sound:GetDescendants()) do
			if child:IsA("Sound") then
				TweenService:Create(child, TweenInfo.new(fadeTime or 0.3), { Volume = 0 }):Play()
			end
		end
		Debris:AddItem(sound, (fadeTime or 0.3) + 0.1)
	end
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

-- Set of tiles a lane is threatening RIGHT NOW; the paint loop below owns their
-- color every frame and pulses them all in unison.
local tilePulse: { [BasePart]: boolean } = {}

-- Tiles currently wearing the local viewer's revenge-lane selection tint (green).
-- Declared up here because the danger pulse loop and claimTile (below) both read
-- it: YOUR selected lane outranks the red danger claim, so those tiles are left
-- green instead of pulsed red — your chosen throw lane always stays visible.
local selectionTinted: { [BasePart]: boolean } = {}

-- A lane starts threatening this tile. New claims take priority instantly: the
-- tile snaps to full red this frame, then the paint loop takes over the pulse.
local function claimTile(part: BasePart)
	local count = (tileRefCount[part] or 0) + 1
	tileRefCount[part] = count
	if count > 1 then
		return -- already claimed by another lane
	end
	stopTileTween(part) -- cancel any in-flight scorch restore
	tilePulse[part] = true
	if not selectionTinted[part] then
		part.Color = WARN_COLOR -- instant priority: a fresh danger tile reads red at once
	end -- ...unless it's your selected lane; that stays green (repaint tick owns it)
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
	tilePulse[part] = nil -- the paint loop stops owning it; scorch/restore takes over
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
	tilePulse[part] = nil
	stopTileTween(part)
end

-- The danger paint loop: every frame, every claimed tile pulses in UNISON over
-- a red floor. It owns a claimed tile's color against scorch and restore, but
-- YIELDS to the local viewer's own revenge-lane selection (green): those tiles
-- are skipped so your chosen throw lane stays visible over the danger pulse.
RunService.RenderStepped:Connect(function()
	if next(tilePulse) == nil then
		return
	end
	local wave = 0.5 + 0.5 * math.sin(os.clock() / PULSE_WAVE_PERIOD * 2 * math.pi)
	local a = PULSE_FLOOR + (1 - PULSE_FLOOR) * wave
	for part in pairs(tilePulse) do
		if not selectionTinted[part] then -- your selected lane keeps its green
			local base = originalColors[part]
			if base then
				part.Color = base:Lerp(WARN_COLOR, a)
			end
		end
	end
end)

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
	-- Stop the per-frame ghost wind-up animation.
	if entry.animConn then
		entry.animConn:Disconnect()
		entry.animConn = nil
	end
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

-- Smoky ghost-bull at the lane start that PAWS and COILS as it winds up, plus a
-- rumble that swells over warnTime. The red lane pulse marks the danger; this
-- ghost carries the anticipation (and faces the charge direction). Uses
-- entry.bounds so it sits at the ACTIVE window edge of a shrunken arena.
local function spawnSilhouette(entry, warnTime: number)
	-- A repeat Telegraph for this lane must not leak the old ghost/anim.
	if entry.animConn then
		entry.animConn:Disconnect()
		entry.animConn = nil
	end
	if entry.silhouette then
		entry.silhouette:Destroy()
		entry.silhouette = nil
	end
	local ghost = bullTemplate:Clone()
	ghost.Name = "Silhouette_" .. entry.key
	for _, desc in ipairs(ghost:GetDescendants()) do
		if desc:IsA("BasePart") then
			desc.CastShadow = false
			-- Ghosts park right at lane starts: keep them out of every
			-- raycast (mouse picking, camera occlusion) — they're pure FX.
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
	local dir = (endPos - startPos)
	dir = if dir.Magnitude > 0 then dir.Unit else Vector3.new(0, 0, 1)
	local ghostBaseCF = CFrame.lookAt(startPos, endPos)
	ghost:PivotTo(ghostBaseCF)
	ghost.Parent = fxFolder
	entry.silhouette = ghost

	-- Per-frame ghost wind-up: pawing scuff + a coil that leans it back and
	-- drops its nose, storing energy the real bull "releases" as its launch
	-- stretch. Torn down (animConn disconnected) the instant the bull charges.
	local ghostRoot = ghost.PrimaryPart or ghost:FindFirstChild("Root")
	local ghostPos = ghostBaseCF.Position
	local ghostRot = ghostBaseCF.Rotation
	local telegraphStart = os.clock()
	entry.animConn = RunService.RenderStepped:Connect(function()
		local liveGhost = entry.silhouette
		if not (liveGhost and ghostRoot and ghostRoot.Parent) then
			return
		end
		local now = os.clock()
		local progress = math.clamp((now - telegraphStart) / math.max(warnTime, 0.1), 0, 1)
		local paw = math.sin(now * GHOST_PAW_HZ * math.pi)
		local scuff = math.max(paw, 0) * 0.28 -- forward scuffs, never backward
		local coil = progress * progress -- eases into the wind-up
		local back = -(0.7 * coil + scuff) -- pull back along the charge line
		local dip = -0.18 * coil + math.abs(paw) * 0.07
		local pitch = 0.14 * coil -- nose dips as it readies
		local offset = dir * back + Vector3.new(0, dip, 0)
		liveGhost:PivotTo(CFrame.new(ghostPos + offset) * ghostRot * CFrame.Angles(pitch, 0, 0.05 * paw))
	end)

	local root = ghostRoot
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
		{ Volume = 0.28 }
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

-- Fake hitstop: on a heavy impact the camera FREEZES at a displaced offset for
-- HITSTOP_TIME (no jitter, no decay), then releases into the normal rattle.
-- That momentary hold is what reads as "the hit landed hard". Roblox can't pause
-- physics/animation network-wide from a client, so this is camera-only by design.
local hitstopUntil = 0
local hitstopOffset = Vector3.zero

local function getHumanoid(): Humanoid?
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid") or nil
end

local function addTrauma(amount: number)
	trauma = math.min(trauma + amount, MAX_TRAUMA)
end

-- strength 0..1: how hard the freeze displaces the camera and how much rattle
-- spills out the far side of the hold.
local function triggerHitstop(strength: number)
	strength = math.clamp(strength, 0, 1)
	hitstopUntil = os.clock() + HITSTOP_TIME
	local dir = Vector3.new(shakeRandom:NextNumber(-1, 1), shakeRandom:NextNumber(-1, 1), 0)
	dir = if dir.Magnitude > 0 then dir.Unit else Vector3.new(1, 0, 0)
	hitstopOffset = dir * (0.9 + 1.7 * strength)
	addTrauma(0.2 * strength) -- rattle released when the freeze ends
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

-- The persistent top-center status bar was removed: round identity is now two
-- notif cards (NEXT: <mode> at intermission, <mode> — GO! at kickoff), and the
-- live alive count rides the elimination-feed cards. See Main.server.luau.

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

-- Revenge cooldown mirror (server-authoritative, from RevengeAck THROW_OK /
-- DENIED): drives the SEND BULL button countdown (bridge attributes) below.
local revengeReadyAt = 0 -- os.clock() when the next throw unlocks
local revengeWasCooling = false -- edge-detects the cooldown lapping for the ready ding

--==============================================================================
-- Revenge lane selection — tile tint layer. While the overhead bull-cam is up
-- (see below), the eliminated cycle a clockwise ring of every lane entry
-- point around the ACTIVE window; the selected lane's tiles tint green with
-- the ENTRY tile brightest (that's where the bull spawns). Selection state +
-- inputs live with the bull-cam sections below; this layer only owns the ring
-- math and the tile colors. The local viewer's OWN selected lane outranks the
-- red danger pulse: its tiles are painted green here AND skipped by the danger
-- loop, so your revenge throw lane is always visible. The 0.1s repaint tick
-- re-asserts the green, and hands a tile back to the pulse when you move off it.
--==============================================================================

local SELECT_COLOR = Color3.fromRGB(70, 200, 100)
local SELECT_ENTRY_COLOR = Color3.fromRGB(180, 255, 200) -- the bull spawns off this edge

local selectionRing: { GridUtil.Lane } = {} -- clockwise entry points, screen order
local selectionIndex = 0 -- 0 = nothing selected yet this session
-- selectionTinted is declared up by tilePulse — the danger loop reads it

-- Clockwise ring in SCREEN order under the bull-cam (screen-up = north = row
-- rowMin): top edge left->right, right edge top->bottom, bottom edge
-- right->left, left edge bottom->top. direction points the bull INTO the
-- window, so the ring covers both ends of every row and column — the same
-- lane set the old clickable marker ring offered.
local function buildSelectionRing(window: GridUtil.Bounds): { GridUtil.Lane }
	local ring = {}
	for col = window.colMin, window.colMax do
		table.insert(ring, { axis = "col", index = col, direction = 1 }) -- north edge, heading south
	end
	for row = window.rowMin, window.rowMax do
		table.insert(ring, { axis = "row", index = row, direction = -1 }) -- east edge, heading west
	end
	for col = window.colMax, window.colMin, -1 do
		table.insert(ring, { axis = "col", index = col, direction = -1 }) -- south edge, heading north
	end
	for row = window.rowMax, window.rowMin, -1 do
		table.insert(ring, { axis = "row", index = row, direction = 1 }) -- west edge, heading east
	end
	return ring
end

-- "ROW 3 →" — the arrow is the bull's on-screen travel direction.
local function selectionLaneText(lane: GridUtil.Lane?): string
	if not lane then
		return ""
	end
	local arrow
	if lane.axis == "row" then
		arrow = if lane.direction == 1 then "→" else "←"
	else
		arrow = if lane.direction == 1 then "↓" else "↑"
	end
	return ("%s %d %s"):format(if lane.axis == "row" then "ROW" else "COL", lane.index, arrow)
end

-- Re-asserted every repaint tick (and immediately on selection moves);
-- active=false clears everything. Direct color sets, no tweens. Your selected
-- lane paints green even OVER a live danger claim (the pulse loop skips these
-- tiles), so it's always visible; when a tile leaves the selection it's handed
-- back to the pulse if a claim still owns it, else restored to its original.
local function paintSelectionTint(active: boolean, window: GridUtil.Bounds?)
	local wanted: { [BasePart]: Color3 } = {}
	local lane = if active then selectionRing[selectionIndex] else nil
	if lane then
		for i, cell in ipairs(GridUtil.laneTiles(lane, window)) do
			local part = tileParts[cell.row .. "_" .. cell.col]
			if part then
				wanted[part] = if i == 1 then SELECT_ENTRY_COLOR else SELECT_COLOR
			end
		end
	end
	for part in pairs(selectionTinted) do
		if not wanted[part] then
			selectionTinted[part] = nil
			if tileRefCount[part] then
				-- a live danger claim still owns it: hand it straight back to the
				-- pulse (which resumes owning it now that it's off the selection)
				part.Color = WARN_COLOR
			else
				-- nothing else owns it: restore the startup original
				stopTileTween(part)
				part.Color = originalColors[part]
			end
		end
	end
	for part, color in pairs(wanted) do
		selectionTinted[part] = true
		-- YOUR lane always reads green, even over a live claim — the danger loop
		-- skips selectionTinted tiles, so nothing repaints it red
		stopTileTween(part) -- a lapsing scorch-restore would repaint over us
		part.Color = color
	end
end

--==============================================================================
-- Arena base: per-viewer local painting. The base slab and the
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

-- Lobby BullCamPad ("Become a Bull"): stepping onto it flips the overhead
-- bull-cam on (see updateOverhead below) - purely client-side, no server
-- script. Only meaningful while a round is ACTIVE and you're an eliminated
-- participant, so hide it from everyone else. Change-only writes; this part
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
-- picking a lane with the arrow keys / HUD arrows (see the lane-selection
-- sections) instead of walking the ring. Enter by stepping
-- onto the lobby BullCamPad or via the HUD "Become a Bull" button
-- (StarterGui.Main owns the button per the UI rule; it talks to this script
-- through the RevengeViewBridge BindableEvent in ReplicatedStorage). The
-- character FREEZES where it stands (character physics is client-owned, so
-- the anchor is real) while viewing. Exit: the button again, E / gamepad B,
-- the character somehow leaving its freeze spot (a server teleport), or the
-- round ending.
--==============================================================================

local OVERHEAD_MARGIN = 16 -- studs beyond the window edge kept in frame (context ground)
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

-- Straight-down framing of the active window plus a margin of surrounding
-- ground: height is whatever fits the tighter screen axis. Up vector is
-- world -Z so north (row rowMin) reads as screen-up and the shot can never
-- roll — the lane-selection ring's screen ordering depends on exactly this.

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
	local eyeY = fitPlane(coreX + OVERHEAD_MARGIN, coreZ + OVERHEAD_MARGIN, Config.ARENA_ORIGIN.Y)
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
	playOneShot("chargeWhoosh", { Volume = 0.245, PlaybackSpeed = 1.1 })
	updateBridgeAttributes()
end

--==============================================================================
-- Revenge lane selection — state + inputs. While the bull-cam is up, ◀ ▶
-- (Left/Right arrow keys, gamepad d-pad, or the HUD arrow buttons via the
-- bridge) walk the clockwise ring built above; "send" (the HUD SEND BULL
-- button) fires the RevengeThrow remote. The server re-validates everything
-- (eliminated participant, cooldown, bounds), so all of this is pure UX.
--==============================================================================

local selectionBoundsKey = "" -- rebuild-detects window changes (round start + shrinks)

local function selectionWindow(): GridUtil.Bounds
	return lastBounds or GridUtil.boundsForStage(0)
end

local function announceSelection()
	viewBridge:SetAttribute("SelectionText", selectionLaneText(selectionRing[selectionIndex]))
end

-- (Re)build the ring for the current window, keeping the selection on the
-- same lane if it survived the shrink — else the nearest surviving lane on
-- the same edge (axis + direction).
local function refreshSelectionRing()
	local window = selectionWindow()
	local key = ("%d_%d_%d_%d"):format(window.rowMin, window.rowMax, window.colMin, window.colMax)
	if key == selectionBoundsKey then
		return
	end
	selectionBoundsKey = key
	local previous = selectionRing[selectionIndex]
	selectionRing = buildSelectionRing(window)
	if selectionIndex ~= 0 then
		selectionIndex = math.clamp(selectionIndex, 1, #selectionRing)
	end
	if previous then
		local bestDistance = math.huge
		for i, lane in ipairs(selectionRing) do
			if lane.axis == previous.axis and lane.direction == previous.direction then
				local distance = math.abs(lane.index - previous.index)
				if distance < bestDistance then
					bestDistance, selectionIndex = distance, i
				end
			end
		end
	end
	announceSelection()
end

local function cycleSelection(step: number)
	if not overheadViewing then
		return
	end
	refreshSelectionRing()
	local count = #selectionRing
	if count == 0 then
		return
	end
	selectionIndex = (math.max(selectionIndex, 1) - 1 + step) % count + 1
	announceSelection()
	paintSelectionTint(true, selectionWindow()) -- instant; don't wait for the tick
	playLibSfx("Click", 0.35, 1.35) -- same blip the shop buttons use
end

local function sendSelectedBull()
	if not (overheadViewing and revengeThrowRemote) then
		return
	end
	refreshSelectionRing()
	local lane = selectionRing[selectionIndex]
	if not lane then
		return
	end
	-- Cooldown is NOT gated here: the server throttles mashers and answers
	-- with a red "Bull ready in Ns" card, which doubles as a resync.
	revengeThrowRemote:FireServer({ axis = lane.axis, index = lane.index, direction = lane.direction })
end

-- One bridge, two jobs: no command = the HUD "Become a Bull" button toggling
-- the cam (the original contract); "left"/"right"/"send" = the lane controls.
viewBridge.Event:Connect(function(command)
	if command == "left" then
		cycleSelection(-1)
	elseif command == "right" then
		cycleSelection(1)
	elseif command == "send" then
		sendSelectedBull()
	elseif overheadViewing then
		exitOverhead()
	else
		enterOverhead()
	end
end)

-- Keyboard/gamepad: arrows move the selection, E / gamepad B exits; entry is
-- the pad or the HUD button only.
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed or not overheadViewing then
		return
	end
	if input.KeyCode == Enum.KeyCode.E or input.KeyCode == Enum.KeyCode.ButtonB then
		exitOverhead()
	elseif input.KeyCode == Enum.KeyCode.Left or input.KeyCode == Enum.KeyCode.DPadLeft then
		cycleSelection(-1)
	elseif input.KeyCode == Enum.KeyCode.Right or input.KeyCode == Enum.KeyCode.DPadRight then
		cycleSelection(1)
	end
end)

-- The 0.1s repaint tick: the ring follows the shrinking window, the selected
-- lane's tint re-asserts over lapsed danger claims, and the bridge mirrors
-- the cooldown for the HUD SEND BULL button (integer seconds; SetAttribute
-- is change-detected so equal writes are free).
local function refreshRevengeSelection()
	local active = overheadViewing and currentState == "ACTIVE" and locallyEliminated
	if active then
		refreshSelectionRing()
		if selectionIndex == 0 and #selectionRing > 0 then
			-- first-ever entry: start mid-top-edge, dead center of the screen
			local window = selectionWindow()
			selectionIndex = math.max(1, math.ceil((window.colMax - window.colMin + 1) / 2))
			announceSelection()
		end
	end
	paintSelectionTint(active, selectionWindow())
	local remaining = math.max(0, revengeReadyAt - os.clock())
	local cooling = remaining > 0
	local eliminated = currentState == "ACTIVE" and locallyEliminated
	if revengeWasCooling and not cooling and eliminated then
		playLibSfx("Confirm", 0.8, 1.15) -- ready ding: your next bull is up
	end
	revengeWasCooling = cooling and eliminated
	viewBridge:SetAttribute("ReadyIn", math.ceil(remaining))
end

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
-- Near-miss detection: the client-rendered bulls (see "client-rendered bulls"
-- below) live in BullrushArena.ActiveBulls locally. Track each bull's
-- closest planar approach to the local character; once it recedes past that
-- minimum it has "passed" -- if the pass was close, punch the camera and play
-- a whoosh by the ear. The kill box half-extents are ~3.5x3.9 studs, so
-- GRAZE_DEADLY (5) means "a hair from dying" and GRAZE_RANGE (14) fades to
-- nothing. Fires at most once per bull; a bull that kills you is drowned out
-- by the bigger elimination slam anyway (trauma is capped).
--==============================================================================

local grazeTracked: { [Instance]: { minDist: number, fired: boolean, dir: Vector3? } } = {}

-- Near-miss pop: a quick FOV widen-and-settle plus a couple of amber speed-line
-- streaks shooting past in the bull's travel direction. Grounded and subtle —
-- it rewards a close shave without touching the character rig or physics.
local function nearMissPop(originPos: Vector3, dir: Vector3, closeness: number)
	local camera = workspace.CurrentCamera
	if camera then
		local base = camera.FieldOfView
		-- Reversing tween: widens then returns to exactly where it started, so it
		-- can't drift even if the dash FOV kick overlaps it.
		TweenService:Create(
			camera,
			TweenInfo.new(0.11, Enum.EasingStyle.Sine, Enum.EasingDirection.Out, 0, true),
			{ FieldOfView = base + NEARMISS_FOV * closeness }
		):Play()
	end

	local count = 2 + math.floor(closeness * 2 + 0.5) -- 2..4 streaks by how close
	for i = 1, count do
		local streak = Instance.new("Part")
		streak.Anchored = true
		streak.CanCollide = false
		streak.CanQuery = false
		streak.CanTouch = false
		streak.CastShadow = false
		streak.Material = Enum.Material.Neon
		streak.Color = STREAK_COLOR
		streak.Size = Vector3.new(0.18, 0.18, 2.6 + 1.4 * closeness)
		streak.Transparency = 0.35
		local spread = Vector3.new(
			shakeRandom:NextNumber(-2.2, 2.2),
			shakeRandom:NextNumber(0.2, 2.6),
			shakeRandom:NextNumber(-2.2, 2.2)
		)
		local from = originPos + spread - dir * 3
		streak.CFrame = CFrame.lookAt(from, from + dir)
		streak.Parent = fxFolder
		TweenService:Create(
			streak,
			TweenInfo.new(0.16 + 0.06 * i, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ CFrame = CFrame.lookAt(from + dir * (13 + 6 * closeness), from + dir), Transparency = 1 }
		):Play()
		Debris:AddItem(streak, 0.5)
	end
end

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
				-- Bull faces -Z, so LookVector is its charge direction — stored so
				-- the near-miss streaks fly the way it was actually going.
				track = { minDist = dist, fired = false, dir = root.CFrame.LookVector }
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
					playOneShot("chargeWhoosh", { Volume = 0.14 + 0.245 * closeness, PlaybackSpeed = 1.25 })
					local popDir = track.dir or (root.Position - here)
					nearMissPop(here, Vector3.new(popDir.X, 0, popDir.Z).Unit, closeness)
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
-- Revenge bull priority: the bull the LOCAL player launched must always be the
-- easiest one to pick out FOR THEM. The thrower is eliminated when they send it,
-- so this can't ride the alive-only near-miss loop — it hooks ActiveBulls
-- directly. Property writes here are client-side, so ONLY the thrower sees the
-- boosted glow (renders through walls and over every other bull); everyone else
-- keeps the standard occluded red the server set.
--==============================================================================

local function boostOwnRevengeBull(bull: Instance)
	if not (bull and bull:IsA("Model")) then
		return
	end
	if bull:GetAttribute("ThrowerName") ~= player.Name then
		return
	end
	local glow = bull:FindFirstChild("RevengeGlow") or bull:WaitForChild("RevengeGlow", 2)
	if glow and glow:IsA("Highlight") then
		glow.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop -- see it through walls & other bulls
		glow.FillColor = Color3.fromRGB(255, 120, 70)
		glow.FillTransparency = 0.4
		glow.OutlineColor = Color3.fromRGB(255, 230, 120)
		glow.OutlineTransparency = 0
	end
end

-- Re-hooks if the ActiveBulls folder is ever recreated (round cleanup / stream).
local hookedBullsFolder: Instance? = nil
local function watchActiveBulls()
	local folder = arena and arena:FindFirstChild("ActiveBulls")
	if not folder or folder == hookedBullsFolder then
		return
	end
	hookedBullsFolder = folder
	folder.ChildAdded:Connect(function(bull)
		task.defer(boostOwnRevengeBull, bull)
	end)
	for _, bull in ipairs(folder:GetChildren()) do
		task.defer(boostOwnRevengeBull, bull)
	end
end

--==============================================================================
-- Client-rendered bulls: the server charge is pure logic (kill-box math, see
-- BullService.chargeAlong) and fires BullVisual once per launch; every client
-- builds the bull model locally and drives it here on RenderStepped. Driving
-- off elapsed = GetServerTimeNow() - launchTime keeps the local model glued to
-- the server's kill box regardless of ping (a client that receives the event
-- late spawns the bull that far along its path), and local interpolation means
-- smooth motion instead of replication-stepped anchored-CFrame teleports.
-- All the presentation that used to ride the server model lives here now:
-- gallop bob/squash, positional herd audio, dust, revenge glow + thrower tag,
-- mutation auras. Models parent into the same ActiveBulls folders as before,
-- so the near-miss tracker and own-revenge-bull boost work unchanged.
--==============================================================================

local BULL_BOB_AMPLITUDE = 0.35 -- studs of gallop bounce
local BULL_BOB_FREQ_PER_SPEED = 0.38 -- rad/s per stud/s: faster bulls gallop faster
local BULL_PITCH_AMPLITUDE = 0.07 -- rad: nose dips with each stride
local BULL_ROLL_AMPLITUDE = 0.06 -- rad: alternating shoulder lean

-- Squash & stretch (the "bouncy but grounded" juice). The bull coils out of the
-- gate STRETCHED along its travel axis (a lunge), eases back to normal, then
-- SQUASHES as it slams through the far edge. Body faces -Z, so its local Z is
-- the travel axis (scaled by `along`); X/Y are the cross-section (`cross`).
local BULL_LUNGE_TIME = 0.16    -- seconds the launch stretch takes to settle
local BULL_LUNGE_STRETCH = 0.30 -- +30% along travel at the very start of the charge
local BULL_LUNGE_SQUASH = 0.14  -- -14% cross-section while stretched (fake volume)
local BULL_IMPACT_TIME = 0.12   -- squash window as it barrels through the far edge
local BULL_IMPACT_SQUASH = 0.20 -- -20% along / +cross as it slams flat

local bullCatalog = nil -- optional: model + mutation lookups degrade to the template
if bullCatalogModule then
	local ok, catalog = pcall(require, bullCatalogModule)
	if ok and type(catalog) == "table" then
		bullCatalog = catalog
	end
end
local bullModelsFolder = assetsFolder and assetsFolder:FindFirstChild("Bulls")
local mutationRigs = ReplicatedStorage:FindFirstChild("Mutations")

-- The model to charge: the bull's catalog modelName (per-bull skins in
-- ReplicatedStorage.BullrushAssets.Bulls, same Root+Body build as
-- BullTemplate), or BullTemplate for wave bulls / missing models.
local function bullTemplateFor(bullId: string?): Model
	if bullId and bullCatalog and type(bullCatalog.get) == "function" then
		local ok, def = pcall(bullCatalog.get, bullId)
		local modelName = ok and type(def) == "table" and def.modelName
		local model = if modelName and bullModelsFolder then bullModelsFolder:FindFirstChild(modelName) else nil
		if model and model:IsA("Model") then
			return model
		end
	end
	return bullTemplate :: Model
end

-- Mutation auras: the VFX rigs in ReplicatedStorage.Mutations are dead parts
-- carrying tuned ParticleEmitters (some bare, some under Attachments); clone
-- just the emitters/attachments onto the Body so no extra geometry rides the
-- bull. Missing rig/catalog entry -> silently plain.
local function attachBullMutationVfx(body: BasePart?, mutId: string)
	if not (body and mutationRigs and bullCatalog and type(bullCatalog.getMutation) == "function") then
		return
	end
	local ok, def = pcall(bullCatalog.getMutation, mutId)
	local rig = if ok and type(def) == "table" then mutationRigs:FindFirstChild(def.vfxName) else nil
	if not rig then
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

-- Where the local model lives: the payload's folder override (practice arena),
-- else the main arena's ActiveBulls — created locally if the server never made
-- one (it has no models to put there anymore), so the near-miss tracker and
-- the own-revenge-bull ChildAdded hook keep their original home.
local function bullVisualFolder(override: Instance?): Instance
	if typeof(override) == "Instance" then
		return override
	end
	local folder = arena and arena:FindFirstChild("ActiveBulls")
	if not folder and arena then
		folder = Instance.new("Folder")
		folder.Name = "ActiveBulls"
		folder.Parent = arena
	end
	return folder or fxFolder
end

local bullVisuals: { [number]: {
	model: Model,
	body: BasePart?,
	baseBodySize: Vector3?,
	rotation: CFrame,
	startPos: Vector3,
	endPos: Vector3,
	speed: number,
	launchTime: number,
	duration: number,
} } = {}

local function removeBullVisual(id: number)
	local visual = bullVisuals[id]
	if visual then
		bullVisuals[id] = nil
		visual.model:Destroy()
	end
end

local function spawnBullVisual(data)
	if type(data) ~= "table" or type(data.id) ~= "number" or bullVisuals[data.id] then
		return
	end
	if typeof(data.startPos) ~= "Vector3" or typeof(data.endPos) ~= "Vector3" then
		return
	end
	local speed = tonumber(data.speed)
	local launchTime = tonumber(data.launchTime)
	if not speed or speed <= 0 or not launchTime then
		return
	end
	local duration = (data.endPos - data.startPos).Magnitude / speed
	if duration <= 0 then
		return
	end
	local style = if type(data.style) == "table" then data.style else nil

	local bull = bullTemplateFor(style and style.bullId):Clone()
	bull:PivotTo(CFrame.lookAt(data.startPos, data.endPos))

	-- Body is the visible mesh; squash/stretch drives its Size around its center
	-- each frame (Root, the invisible primary, is untouched so the model still
	-- rides where PivotTo puts it).
	local body = bull:FindFirstChild("Body")
	local baseBodySize = if body and body:IsA("BasePart") then body.Size else nil

	-- Revenge bulls read as PLAYER-SENT: a red glow, plus the thrower's name
	-- over its head so victims know who to blame (and the thrower can spot
	-- THEIR bull in a stampede).
	if style then
		-- Stamp the thrower so boostOwnRevengeBull (ChildAdded on the folder)
		-- gives the thrower's own client the top-priority highlight.
		if style.throwerName then
			bull:SetAttribute("ThrowerName", style.throwerName)
		end
		if style.mutation then
			attachBullMutationVfx(body :: BasePart?, style.mutation)
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

	bull.Parent = bullVisualFolder(data.folder)

	-- Positional hooves: the charge is HEARD coming from where the bull is,
	-- not just felt as the flat stampede layer. Dies with the model.
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

	bullVisuals[data.id] = {
		model = bull,
		body = if body and body:IsA("BasePart") then body else nil,
		baseBodySize = baseBodySize,
		rotation = CFrame.lookAt(data.startPos, data.endPos).Rotation,
		startPos = data.startPos,
		endPos = data.endPos,
		speed = speed,
		launchTime = launchTime,
		duration = duration,
	}
end

local function updateBullVisuals()
	if not next(bullVisuals) then
		return
	end
	local now = workspace:GetServerTimeNow()
	for id, visual in pairs(bullVisuals) do
		local raw = now - visual.launchTime
		-- Safety net: BullVisualEnd normally lands first; the grace covers a
		-- server heartbeat's slack past the nominal duration.
		if raw >= visual.duration + 0.5 or not visual.model.Parent then
			removeBullVisual(id)
			continue
		end
		local elapsed = math.clamp(raw, 0, visual.duration)

		local position = visual.startPos:Lerp(visual.endPos, elapsed / visual.duration)
		local phase = elapsed * visual.speed * BULL_BOB_FREQ_PER_SPEED
		local bob = BULL_BOB_AMPLITUDE * math.abs(math.sin(phase))
		local nod = BULL_PITCH_AMPLITUDE * math.sin(2 * phase)
		local sway = BULL_ROLL_AMPLITUDE * math.sin(phase)
		visual.model:PivotTo(CFrame.new(position + Vector3.new(0, bob, 0)) * visual.rotation * CFrame.Angles(nod, 0, sway))

		-- Coil-release lunge on the way out, slam-squash on arrival.
		local body = visual.body
		if body and visual.baseBodySize and body.Parent then
			local along, cross = 1, 1
			if elapsed < BULL_LUNGE_TIME then
				local k = 1 - elapsed / BULL_LUNGE_TIME -- 1 -> 0
				k = k * k                               -- quad ease-out of the stretch
				along += BULL_LUNGE_STRETCH * k
				cross -= BULL_LUNGE_SQUASH * k
			end
			local remain = visual.duration - elapsed
			if remain < BULL_IMPACT_TIME then
				local k = 1 - remain / BULL_IMPACT_TIME -- 0 -> 1 as it hits the far edge
				k = k * k
				along -= BULL_IMPACT_SQUASH * k
				cross += BULL_IMPACT_SQUASH * 0.6 * k
			end
			body.Size = Vector3.new(
				visual.baseBodySize.X * cross,
				visual.baseBodySize.Y * cross,
				visual.baseBodySize.Z * along
			)
		end
	end
end

if bullVisualRemote and bullVisualRemote:IsA("RemoteEvent") then
	bullVisualRemote.OnClientEvent:Connect(spawnBullVisual)
end
if bullVisualEndRemote and bullVisualEndRemote:IsA("RemoteEvent") then
	bullVisualEndRemote.OnClientEvent:Connect(function(id)
		if type(id) == "number" then
			removeBullVisual(id)
		end
	end)
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

	playOneShot("chargeWhoosh", { Volume = 0.075, PlaybackSpeed = 0.85 }) -- faint kick under the herd; the rocket-whoosh must not read as a jet engine

	-- Stampede: a low thunder rumble for the ground under a detuned herd of
	-- galloping hooves. Layering the one gallop clip at spread pitches (with a
	-- small phase offset so the loops don't sync) reads as many charging animals
	-- instead of a single looping sample. Levels sit ABOVE the whoosh and the
	-- battle-music bed so the charge is HEARD as a stampede, not felt behind it.
	local herd = Instance.new("Folder")
	herd.Name = "Stampede"
	herd.Parent = SoundService
	makeSound("rumble", { Volume = 0.52, Looped = true, PlaybackSpeed = 0.8 }, herd) -- ground bed
	local HERD = {
		{ pitch = 0.86, volume = 0.48 },
		{ pitch = 1.00, volume = 0.52 },
		{ pitch = 1.18, volume = 0.40 },
	}
	for i, layer in ipairs(HERD) do
		local hoof = makeSound("gallop", { Volume = layer.volume, Looped = true, PlaybackSpeed = layer.pitch }, herd)
		hoof.TimePosition = (i - 1) * 0.13
	end
	for _, s in ipairs(herd:GetChildren()) do
		safePlay(s :: Sound)
	end
	entry.chargeSound = herd
	task.delay(chargeTime + 0.25, function()
		if entry.chargeSound == herd then
			entry.chargeSound = nil
			fadeOutAndDestroy(herd, 0.35)
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
		if closeness > 0.35 then
			triggerHitstop(closeness) -- a hard clear right by you freeze-punches
		end
		playOneShot("slam", { Volume = 0.245 + 0.175 * closeness })
		playOneShot("thud", { Volume = 0.21 + 0.14 * closeness, PlaybackSpeed = 0.55 })
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

		playOneShot("rumble", { Volume = 0.21, PlaybackSpeed = 0.5 })
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
			playOneShot("slam", { Volume = 0.28 })
			playOneShot("thud", { Volume = 0.245, PlaybackSpeed = 0.5 })
			playOneShot("rumble", { Volume = 0.35, PlaybackSpeed = 0.75 }) -- collapse roar over the fall
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
	-- aliveCount now shows only in the server's elimination-feed cards, not a
	-- persistent HUD readout, so it's no longer tracked here.
	if typeof(playerName) == "string" then
		eliminatedNames[playerName] = true -- ghost them for the living
	end
	if playerName == player.Name then
		locallyEliminated = true
		refreshArenaBase() -- the ring appears the instant you fall
		triggerHitstop(1) -- freeze-frame the trample before the ragdoll launch
		addTrauma(MAX_TRAUMA) -- trampled: the hardest hit the shake system allows
		playHapticPulse("GameplayExplosion") -- phones etc; gamepads peak via the trauma-driven motors
		playOneShot("thud", { Volume = 0.42, PlaybackSpeed = 0.5 })
		updateBridgeAttributes() -- the HUD "Become a Bull" button appears now
	end
	refreshGhosts() -- hides the new ghost -- or, if WE just died, reveals them all
	-- Other players' eliminations reach the feed as server-pushed white cards
	-- (RoundService.eliminate -> NotifyService), not from this handler.
end)

-- Ragdoll fling: when a bull connects, the server has already swapped our joints
-- for ball-sockets and killed the humanoid (BreakJointsOnDeath off), leaving us a
-- limp rig we still own the network for. It hands us the launch vector here and
-- we drive the tumble locally, so the ragdoll physics never touches the server
-- and the motion replicates to everyone because we own the parts. PlatformStand
-- + the Physics state stop our own control script fighting the launch in case
-- this remote arrives a frame before the death itself replicates in.
if ragdollFlingRemote then
	local RunService = game:GetService("RunService")
	ragdollFlingRemote.OnClientEvent:Connect(function(velocity: Vector3, spin: Vector3)
		local character = player.Character
		if not character then
			return
		end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.PlatformStand = true
			pcall(function()
				humanoid:ChangeState(Enum.HumanoidStateType.Physics)
			end)
		end

		local function applyImpulse()
			for _, part in character:GetDescendants() do
				if part:IsA("BasePart") then
					part.AssemblyLinearVelocity = velocity
					part.AssemblyAngularVelocity = spin
				end
			end
		end

		-- Re-assert the launch for a few frames rather than once: the server
		-- builds the ball-socket joints and fires this remote in the same frame,
		-- so the ragdoll topology can replicate in a beat AFTER we arrive. A
		-- single impulse on a still-rigid (or just-asleep) assembly can be eaten;
		-- re-setting the velocity each frame is idempotent (a SET, not an add, so
		-- it never compounds) and guarantees the tumble reads once the joints are
		-- loose. A handful of frames (~0.1s) is invisible and then we stop.
		applyImpulse()
		local framesLeft = 3
		local conn
		conn = RunService.Heartbeat:Connect(function()
			framesLeft -= 1
			if framesLeft <= 0 or not character.Parent then
				conn:Disconnect()
				return
			end
			applyImpulse()
		end)
	end)
end

if revengeAckRemote then
	revengeAckRemote.OnClientEvent:Connect(function(kind, data)
		if kind == "THROW_OK" then
			local cooldown = (typeof(data) == "table" and tonumber(data.cooldown))
				or (typeof(Config.REVENGE) == "table" and tonumber(Config.REVENGE.COOLDOWN))
				or 15
			revengeReadyAt = os.clock() + cooldown
			playOneShot("thud", { Volume = 0.28, PlaybackSpeed = 0.9 }) -- launch feedback
			addTrauma(0.5) -- the stomp lands: kick the thrower's camera too
			playHapticPulse("GameplayCollision")
			playLibSfx("Confirm", 0.9)
		elseif kind == "HIT" then
			-- Server still sends the green money card; this is the BIG payoff:
			-- a center-screen burst + shake so a trample never goes unnoticed.
			local victim = if typeof(data) == "table" then tostring(data.victimName or "someone") else "someone"
			local amount = if typeof(data) == "table" then tonumber(data.amount) else nil
			showHitPopup(if amount
				then ("TRAMPLED %s! +$%d"):format(victim, amount)
				else ("TRAMPLED %s!"):format(victim))
			addTrauma(0.35)
			playHapticPulse("GameplayCollision")
			playOneShot("slam", { Volume = 0.315 })
			playOneShot("thud", { Volume = 0.245, PlaybackSpeed = 0.6 })
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

	-- The ACTIVE window drives the bull-cam framing; forget it between rounds.
	-- (Round identity + alive count moved to notif cards, so nothing else in
	-- the info payload needs mirroring here anymore.)
	if state == "ACTIVE" and isBounds(info.bounds) then
		lastBounds = info.bounds
	elseif state ~= "ACTIVE" then
		lastBounds = nil
	end

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
-- The single per-frame binding: near-miss tracking, shake decay + gamepad rumble.
--==============================================================================

local revengeRefreshAccum = 0
local baseRefreshAccum = 0

RunService.RenderStepped:Connect(function(dt)

	-- Revenge lane-select repaint, throttled to 0.1s: selection tint, ring
	-- rebuilds after shrinks, and the HUD cooldown mirror. Runs in EVERY
	-- round state (not just ACTIVE) so a round ending mid-view clears the
	-- lane tint within a tick.
	revengeRefreshAccum += dt
	if revengeRefreshAccum >= 0.1 then
		revengeRefreshAccum = 0
		refreshRevengeSelection()
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
		watchActiveBulls() -- (re)hook the thrower's-own-bull highlight boost
	end

	updateBullVisuals() -- move the local bulls BEFORE near-miss reads positions
	updateNearMisses()

	-- Hitstop wins the camera outright: while frozen, hold a constant displaced
	-- offset (no jitter, no trauma decay) so the impact reads as a hard stop
	-- before the rattle spills out. Everything above still ran this frame.
	if os.clock() < hitstopUntil then
		local humanoid = getHumanoid()
		if humanoid then
			humanoid.CameraOffset = hitstopOffset
		end
		shakeDirty = true
		setGamepadRumble(1)
		return
	end

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

--==============================================================================
-- VIP chat tag: a gold [VIP] badge in front of the sender's name for anyone who
-- owns the VIP pass. IsVIP is set server-side by MonetizationService and
-- replicated as a player attribute, so every client can read it here.
-- OnIncomingMessage runs locally for each message on each client (this is the
-- modern TextChatService path - verified ChatVersion), so all players see the
-- tag and nothing is stored on the message itself.
--==============================================================================

local TextChatService = game:GetService("TextChatService")
local VIP_TAG_HEX = Color3.fromRGB(255, 205, 60):ToHex() -- house gold

TextChatService.OnIncomingMessage = function(message: TextChatMessage)
	local source = message.TextSource
	if not source then
		return -- system / non-player messages carry no TextSource
	end
	local sender = Players:GetPlayerByUserId(source.UserId)
	if not (sender and sender:GetAttribute("IsVIP")) then
		return -- non-VIP (or the sender already left): leave the message untouched
	end
	-- Prepend the gold badge, keeping whatever prefix the chat already built.
	local props = Instance.new("TextChatMessageProperties")
	props.PrefixText = ('<font color="#%s">[VIP]</font> %s'):format(VIP_TAG_HEX, message.PrefixText)
	return props
end