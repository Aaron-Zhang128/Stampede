--[[
	PracticeArena — an always-on 5x5 practice grid on the far (north) side of the
	lobby, reached by the lobby PracticePad teleporter. 3-4 bulls perpetually
	charge random lanes behind a red-tile telegraph; a hit flings the player
	(RagdollService) and kills them, so they respawn at the lobby.

	Fully independent of the main round loop: its own coordinate system (NOT
	GridUtil, which is bound to the main arena origin), its own ActiveBulls
	folder, and it fires no round remotes — main clients never hear about these
	bulls. Reuses BullService.chargeAlong for the exact real-bull feel
	(gallop / squash / dust / hooves / ragdoll kill box).
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Bullrush.Config)
local BullService = require(script.Parent.BullService)

-- Geometry ------------------------------------------------------------------
local N = 5
local CENTER = (N + 1) / 2                    -- 3
local TILE = Config.TILE_SIZE                  -- 6
local ORIGIN = Vector3.new(200, 20, 40)        -- grid center at tile-top height
local TOP_Y = ORIGIN.Y
local BULL_Y = TOP_Y + Config.BULL_RIDE_HEIGHT
local OVERSHOOT = Config.BULL_OVERSHOOT

-- Tuning --------------------------------------------------------------------
local SPEED = 40                               -- constant practice bull speed
local TELEGRAPH = 1.3                           -- red-tile warning before a charge
local TARGET_MIN, TARGET_MAX = 3, 4             -- concurrent bulls held in this range
local STAGGER_MIN, STAGGER_MAX = 30, 80         -- ms*10 gap between topping up bulls
local WARN_COLOR = Color3.fromRGB(225, 60, 45)

local arena = Workspace:WaitForChild("PracticeArena")
local tilesFolder = arena:WaitForChild("Tiles")
local bullFolder = arena:WaitForChild("ActiveBulls")

local function tilePart(r, c)
	return tilesFolder:FindFirstChild(string.format("Tile_%d_%d", r, c))
end

-- Base tile colours captured once so telegraphs restore exactly.
local baseColor = {}
for _, t in tilesFolder:GetChildren() do
	if t:IsA("BasePart") then
		baseColor[t] = t.Color
	end
end

-- Ref-counted warning tint (a row and a col telegraph can share one tile, so a
-- plain set/restore would blink the crossing tile off too early).
local warnCount = {}
local function setWarn(part, on)
	local n = (warnCount[part] or 0) + (if on then 1 else -1)
	warnCount[part] = n
	part.Color = if n > 0 then WARN_COLOR else (baseColor[part] or part.Color)
end

-- Root-center start/end for a practice lane {axis, index, direction} across the
-- whole 5x5 grid, mirroring GridUtil.lanePath but on the practice origin.
local function lanePath(lane)
	local cross = if lane.axis == "row"
		then ORIGIN.Z + (lane.index - CENTER) * TILE
		else ORIGIN.X + (lane.index - CENTER) * TILE
	local originAxis = if lane.axis == "row" then ORIGIN.X else ORIGIN.Z
	local minEdge = originAxis + (1 - CENTER) * TILE - TILE / 2 - OVERSHOOT
	local maxEdge = originAxis + (N - CENTER) * TILE + TILE / 2 + OVERSHOOT
	local s, e = minEdge, maxEdge
	if lane.direction == -1 then
		s, e = maxEdge, minEdge
	end
	if lane.axis == "row" then
		return Vector3.new(s, BULL_Y, cross), Vector3.new(e, BULL_Y, cross), cross
	else
		return Vector3.new(cross, BULL_Y, s), Vector3.new(cross, BULL_Y, e), cross
	end
end

local function laneTiles(lane)
	local out = {}
	for i = 1, N do
		local r = if lane.axis == "row" then lane.index else i
		local c = if lane.axis == "row" then i else lane.index
		local p = tilePart(r, c)
		if p then
			out[#out + 1] = p
		end
	end
	return out
end

-- Players standing ON the grid (tight footprint). The staging deck to the south
-- is deliberately excluded, so it stays a safe waiting spot even when a column
-- bull overshoots past it.
--
-- chargeAlong polls this every Heartbeat, ONCE PER ACTIVE BULL. With 3-4 bulls
-- perpetually charging, a per-call rebuild (fresh table + a FindFirstChild and
-- zone test per player) ran 3-4x every frame, forever. Instead we rebuild the
-- snapshot at most once per frame and hand every bull the same list, so the cost
-- is 1x with no change in hit freshness. Each rebuild allocates a NEW table
-- (rather than clearing in place) so a bull mid-iteration keeps a stable list
-- even if its kill loop yields into a later frame.
local GRID_HALF = (N * TILE) / 2 + 1
local frameId = 0
RunService.Heartbeat:Connect(function()
	frameId += 1
end)
local gridSnapshot = {}
local gridSnapshotFrame = -1
local function playersOnGrid()
	if frameId ~= gridSnapshotFrame then
		gridSnapshotFrame = frameId
		local list = {}
		for _, pl in Players:GetPlayers() do
			local ch = pl.Character
			local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
			if hrp then
				local p = hrp.Position
				if math.abs(p.X - ORIGIN.X) <= GRID_HALF
					and math.abs(p.Z - ORIGIN.Z) <= GRID_HALF
					and math.abs(p.Y - TOP_Y) < 12
				then
					list[#list + 1] = pl
				end
			end
		end
		gridSnapshot = list
	end
	return gridSnapshot
end

-- RagdollService.launch (inside chargeAlong) already flings + kills the victim,
-- so respawn-at-lobby is automatic; this is a safety net if that no-oped.
local function onKill(pl)
	local ch = pl.Character
	local hum = ch and ch:FindFirstChildWhichIsA("Humanoid")
	if hum and hum.Health > 0 then
		hum.Health = 0
	end
end

-- Bull supervisor -----------------------------------------------------------
-- Never two bulls on the same grid line at once, so a safe row and column
-- always exist to escape to.
local activeLines = {}
local activeCount = 0

local function pickLane()
	for _ = 1, 40 do
		local axis = if math.random() < 0.5 then "row" else "col"
		local index = math.random(1, N)
		local line = axis .. index
		if not activeLines[line] then
			return { axis = axis, index = index, direction = if math.random() < 0.5 then 1 else -1 }, line
		end
	end
	return nil, nil
end

local function runBull()
	local lane, line = pickLane()
	if not lane then
		activeCount -= 1
		return
	end
	activeLines[line] = true

	local warned = laneTiles(lane)
	for _, t in warned do
		setWarn(t, true)
	end
	task.wait(TELEGRAPH)

	local startPos, endPos, cross = lanePath(lane)
	-- chargeAlong(startPos, endPos, crossCoord, axis, speed, getAlive, onKill,
	--   style, onCharge, onCleared, parentFolder) — no remotes, own folder.
	BullService.chargeAlong(startPos, endPos, cross, lane.axis, SPEED, playersOnGrid, onKill, nil, nil, nil, bullFolder)

	for _, t in warned do
		setWarn(t, false)
	end
	activeLines[line] = nil
	activeCount -= 1
end

task.spawn(function()
	while true do
		local target = math.random(TARGET_MIN, TARGET_MAX)
		while activeCount < target do
			activeCount += 1
			task.spawn(runBull)
			task.wait(math.random(STAGGER_MIN, STAGGER_MAX) / 100)
		end
		task.wait(0.25)
	end
end)

-- Teleport: the lobby plate drops the player straight onto the grid center;
-- the only way back to the lobby is to get hit (respawn), so no return pad.
local ENTRY = CFrame.lookAt(ORIGIN + Vector3.new(0, 2.5, 0), ORIGIN + Vector3.new(0, 2.5, 12))
local lobby = Workspace:WaitForChild("Lobby")
local practicePad = lobby:WaitForChild("PracticePad")

local cooldown = {}
local function teleport(hitPart, dest)
	local ch = hitPart.Parent
	local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
	local pl = ch and Players:GetPlayerFromCharacter(ch)
	if not (hrp and pl) then
		return
	end
	local now = os.clock()
	if cooldown[pl] and now - cooldown[pl] < 1.5 then
		return
	end
	cooldown[pl] = now
	hrp.CFrame = dest
end

practicePad.Touched:Connect(function(hit)
	teleport(hit, ENTRY)
end)
