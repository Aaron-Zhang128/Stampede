--[[
	ShrinkService - owns the shrinking arena floor (Workspace.BullrushArena.Tiles)
	and the guard walls (Workspace.BullrushArena.Walls).

	The physical grid is 9x9; each round plays in a centered window of it.
	reset(startSize, stages) configures the round: tiles inside the window are
	restored (checkerboard, canonical height), tiles OUTSIDE it snap to sunken
	charcoal immediately (no telegraph - they were never in play). Stage 0 =
	the full window; advanceTo() then trims per stage via GridUtil.boundsForStage.

	advanceTo() is BLOCKING: per step it fires ArenaShrink, waits out the
	telegraph, sinks the removed tiles (server-side position tween + charcoal
	recolor), then waits out the sink. Sunken tiles keep CanCollide = true -
	they are walkable dead ground; Main's out-of-bounds watcher does the
	eliminating. The guard walls track the window too: reset() and each
	completed stage snap them flush to the boundary tiles' outer edges.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Bullrush.Config)
local GridUtil = require(ReplicatedStorage.Bullrush.GridUtil)
local Remotes = ReplicatedStorage.Bullrush.Remotes

local CHECKER_LIGHT = Color3.fromRGB(214, 182, 133) -- (row + col) even
local CHECKER_DARK = Color3.fromRGB(188, 152, 102) -- (row + col) odd
local CHARCOAL = Color3.fromRGB(55, 48, 42) -- dropped tiles

local ShrinkService = {}

local stage = 0
local startSize = Config.GRID_SIZE -- window side length at stage 0 (set by reset)
local maxStage = 0 -- how many shrink stages this round allows (set by reset)
local bounds = GridUtil.boundsForStage(0)
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

-- Configure the arena for a round: cancel in-flight sinks, restore every
-- window tile to canonical position / checkerboard color, snap every tile
-- OUTSIDE the window straight to sunken charcoal, stage back to 0.
-- newStartSize defaults to the full grid; stages defaults to 0 (no shrinking).
function ShrinkService.reset(newStartSize: number?, stages: number?)
	sinkGeneration += 1 -- any in-flight sink loop bails on its next frame

	startSize = newStartSize or Config.GRID_SIZE
	maxStage = stages or 0
	stage = 0
	bounds = GridUtil.boundsForStage(0, startSize)
	updateWalls(bounds)

	for row = 1, Config.GRID_SIZE do
		for col = 1, Config.GRID_SIZE do
			local tile = getTile(row, col)
			if tile then
				tile.CanCollide = true
				if GridUtil.inBounds(row, col, bounds) then
					tile.Position = tilePartPosition(row, col)
					tile.Color = if (row + col) % 2 == 0 then CHECKER_LIGHT else CHECKER_DARK
				else
					-- Outside the mode's window: dead ground from second zero.
					tile.Position = tilePartPosition(row, col) - Vector3.new(0, Config.SHRINK.SINK_DEPTH, 0)
					tile.Color = CHARCOAL
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

		-- TweenService doesn't step in some server contexts (observed frozen in
		-- Studio Run mode), so sink via a Heartbeat lerp like BullService's charge.
		local myGeneration = sinkGeneration
		local sinking = {}
		for _, cell in removedCells do
			local tile = getTile(cell.row, cell.col)
			if tile then
				tile.Color = CHARCOAL -- color snaps; only the position animates
				table.insert(sinking, { tile = tile, from = tilePartPosition(cell.row, cell.col) })
			end
		end
		local elapsed = 0
		while elapsed < Config.SHRINK.SINK_TIME and sinkGeneration == myGeneration do
			local dt = RunService.Heartbeat:Wait()
			elapsed = math.min(elapsed + dt, Config.SHRINK.SINK_TIME)
			local alpha = elapsed / Config.SHRINK.SINK_TIME
			alpha *= alpha -- Quad ease-in
			for _, item in sinking do
				item.tile.Position = item.from - Vector3.new(0, Config.SHRINK.SINK_DEPTH * alpha, 0)
			end
		end

		stage = s
		bounds = newBounds
		updateWalls(newBounds)
	end
end

return ShrinkService