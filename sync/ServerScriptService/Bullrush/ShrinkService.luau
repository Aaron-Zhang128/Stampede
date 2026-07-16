--[[
	ShrinkService - owns the shrinking arena floor (Workspace.BullrushArena.Tiles)
	and the guard walls (Workspace.BullrushArena.Walls).

	The physical grid is 11x11; each round plays in a centered window of it.
	reset(startSize, stages) configures the round: tiles inside the window are
	restored (checkerboard, canonical height, visible), tiles OUTSIDE it vanish
	into the pit immediately (no telegraph - they were never in play). Stage 0 =
	the full window; advanceTo() then peels one full outer ring per stage via
	GridUtil.boundsForStage.

	advanceTo() is BLOCKING: per step it fires ArenaShrink, waits out the
	telegraph, then snaps the removed pillars straight to their landed state
	(parked SINK_DEPTH down, invisible, no collision) in one write per
	property — the visible SINK_TIME collapse is client-rendered by
	BullrushClient from the same ArenaShrink payload, so the fall costs no
	replication. Anyone on a doomed pillar free-falls into the void; Main's
	out-of-bounds watcher does the eliminating. The guard walls track the
	window too: reset() and each completed stage snap them flush to the
	boundary tiles' outer edges.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Bullrush.Config)
local GridUtil = require(ReplicatedStorage.Bullrush.GridUtil)
local Remotes = ReplicatedStorage.Bullrush.Remotes

local CHECKER_LIGHT = Config.TILE_CHECKER_LIGHT -- (row + col) even
local CHECKER_DARK = Config.TILE_CHECKER_DARK -- (row + col) odd
local CHARCOAL = Config.TILE_CHARCOAL -- dropped tiles

local ShrinkService = {}

local stage = 0
local startSize = Config.GRID_SIZE -- window side length at stage 0 (set by reset)
local maxStage = 0 -- how many shrink stages this round allows (set by reset)
local bounds = GridUtil.boundsForStage(0)
local roundHoleLines: any = nil -- carved trenches for the round (Hashtag), or nil
local sinkGeneration = 0 -- bumped by reset() to cancel in-flight sinks

local function getTile(row: number, col: number): BasePart?
	local arena = Workspace:FindFirstChild("BullrushArena")
	local tiles = arena and arena:FindFirstChild("Tiles")
	local tile = tiles and tiles:FindFirstChild(string.format("Tile_%d_%d", row, col))
	return if tile and tile:IsA("BasePart") then tile else nil
end

-- Part center for tile (row, col): GridUtil.tileCenter is the TOP surface,
-- so the part sits half a thickness below it.
local function tilePartPosition(row: number, col: number): Vector3
	return GridUtil.tileCenter(row, col) - Vector3.new(0, Config.TILE_THICKNESS / 2, 0)
end

local WALL_THICKNESS = 1 -- matches the built Walls parts (X/Z depth)

local function getWall(name: string): BasePart?
	local arena = Workspace:FindFirstChild("BullrushArena")
	local walls = arena and arena:FindFirstChild("Walls")
	local wall = walls and walls:FindFirstChild(name)
	return if wall and wall:IsA("BasePart") then wall else nil
end

-- Snap the four guard walls flush to the active window: inner faces on the
-- outer edge of the boundary tiles, lengths extended one wall thickness past
-- each corner so the fence never gaps. Height and Y stay whatever the built
-- parts use. Called at reset and after each stage's sink completes - anyone
-- still on removed tiles is fenced out on dead ground for the out-of-bounds
-- watcher to eliminate.
local function updateWalls(b: GridUtil.Bounds)
	local minCenter = GridUtil.tileCenter(b.rowMin, b.colMin)
	local maxCenter = GridUtil.tileCenter(b.rowMax, b.colMax)
	local half = Config.TILE_PART_SIZE / 2
	local minX, maxX = minCenter.X - half, maxCenter.X + half
	local minZ, maxZ = minCenter.Z - half, maxCenter.Z + half
	local midX, midZ = (minX + maxX) / 2, (minZ + maxZ) / 2
	local spanX = maxX - minX + 2 * WALL_THICKNESS
	local spanZ = maxZ - minZ + 2 * WALL_THICKNESS

	local function place(name: string, x: number, z: number, sizeX: number, sizeZ: number)
		local wall = getWall(name)
		if wall then
			wall.Size = Vector3.new(sizeX, wall.Size.Y, sizeZ)
			wall.Position = Vector3.new(x, wall.Position.Y, z)
			-- Pure physics fence: must never soak up mouse rays, or the
			-- bull-cam's clicks can't reach the revenge markers just outside.
			wall.CanQuery = false
		end
	end

	place("WallNorth", midX, minZ - WALL_THICKNESS / 2, spanX, WALL_THICKNESS)
	place("WallSouth", midX, maxZ + WALL_THICKNESS / 2, spanX, WALL_THICKNESS)
	place("WallWest", minX - WALL_THICKNESS / 2, midZ, WALL_THICKNESS, spanZ)
	place("WallEast", maxX + WALL_THICKNESS / 2, midZ, WALL_THICKNESS, spanZ)
end

function ShrinkService.getStage(): number
	return stage
end

function ShrinkService.getBounds(): GridUtil.Bounds
	return bounds
end

-- The round's carved trench spec (Hashtag mode's #), or nil for normal modes.
-- Consumers (AIService bot movement) read it to steer clear of the trenches.
function ShrinkService.getHoleLines(): any
	return roundHoleLines
end

-- Configure the arena for a round: cancel in-flight sinks, restore every
-- window tile to canonical position / checkerboard color / visible, snap
-- every tile OUTSIDE the window straight to gone (invisible, no collision,
-- parked in the pit), stage back to 0.
-- newStartSize defaults to the full grid; stages defaults to 0 (no shrinking).
-- holeLines (optional, Hashtag mode) additionally sinks the listed trench
-- rows/cols INSIDE the window straight to gone, exactly like out-of-bounds
-- tiles, so the # pattern is present from second zero.
function ShrinkService.reset(newStartSize: number?, stages: number?, holeLines: any?)
	sinkGeneration += 1 -- any in-flight sink loop bails on its next frame

	roundHoleLines = holeLines
	startSize = newStartSize or Config.GRID_SIZE
	-- Each stage peels a full outer ring (side length -2); never let the
	-- window shrink below 3x3, whatever the mode's schedule says.
	maxStage = math.min(stages or 0, math.floor((startSize - 3) / 2))
	stage = 0
	bounds = GridUtil.boundsForStage(0, startSize)
	updateWalls(bounds)

	for row = 1, Config.GRID_SIZE do
		for col = 1, Config.GRID_SIZE do
			local tile = getTile(row, col)
			if tile then
				-- Size enforced from Config so a thickness tweak needs no manual rebuild.
				tile.Size = Vector3.new(Config.TILE_PART_SIZE, Config.TILE_THICKNESS, Config.TILE_PART_SIZE)
				if GridUtil.inBounds(row, col, bounds) and not GridUtil.isHole(row, col, holeLines) then
					tile.Position = tilePartPosition(row, col)
					tile.Color = if (row + col) % 2 == 0 then CHECKER_LIGHT else CHECKER_DARK
					tile.Transparency = 0
					tile.CanCollide = true
				else
					-- Outside the window, or a carved Hashtag trench: gone from second zero.
					tile.Position = tilePartPosition(row, col) - Vector3.new(0, Config.SHRINK.SINK_DEPTH, 0)
					tile.Color = CHARCOAL
					tile.Transparency = 1
					tile.CanCollide = false
				end
			end
		end
	end
end

-- BLOCKING: walks the arena from the current stage to targetStage one step
-- at a time (telegraph, then sink). No-op if targetStage <= current stage.
-- Clamped to the stage count reset() configured for this round.
function ShrinkService.advanceTo(targetStage: number)
	targetStage = math.clamp(targetStage, 0, maxStage)
	for s = stage + 1, targetStage do
		local newBounds = GridUtil.boundsForStage(s, startSize)

		local removedCells = {}
		for row = bounds.rowMin, bounds.rowMax do
			for col = bounds.colMin, bounds.colMax do
				if not GridUtil.inBounds(row, col, newBounds) then
					table.insert(removedCells, { row = row, col = col })
				end
			end
		end

		Remotes.ArenaShrink:FireAllClients(s, newBounds, removedCells, Config.SHRINK.TELEGRAPH)
		task.wait(Config.SHRINK.TELEGRAPH)

		-- The pillar fall is CLIENT-RENDERED (BullrushClient drops a local
		-- stand-in pillar from the tile's pre-sink spot, same quad ease-in):
		-- the server snaps each removed pillar straight to its landed state in
		-- ONE write per property, instead of the old per-frame position lerp
		-- that replicated ~100 updates per pillar to every client — the game's
		-- biggest bandwidth burst. Anyone still on a doomed pillar free-falls
		-- into the pit the moment collision drops (they used to ride it down;
		-- either way the out-of-bounds watcher does the eliminating).
		local myGeneration = sinkGeneration
		for _, cell in removedCells do
			local tile = getTile(cell.row, cell.col)
			if tile then
				-- The Color write is LOAD-BEARING even though the tile is
				-- invisible: clients paint doomed tiles red locally and rely on
				-- this replicated charcoal to stomp it (abandonTile drops the
				-- claim without restoring). It also makes reset()'s checkerboard
				-- restore a real server-side change — same-value writes don't
				-- replicate, so without the charcoal step the local red would
				-- survive into the next round's regenerated tiles.
				tile.Color = CHARCOAL
				tile.Position = tilePartPosition(cell.row, cell.col)
					- Vector3.new(0, Config.SHRINK.SINK_DEPTH, 0)
				tile.Transparency = 1
				tile.CanCollide = false
			end
		end
		-- Bounds (and with them the out-of-bounds grace clock) still commit
		-- only after the fall has played out on clients — same rhythm as when
		-- the server animated it.
		task.wait(Config.SHRINK.SINK_TIME)
		if sinkGeneration ~= myGeneration then
			return -- reset() mid-fall: it restored the tiles and owns the state now
		end

		stage = s
		bounds = newBounds
		updateWalls(newBounds)
	end
end

return ShrinkService