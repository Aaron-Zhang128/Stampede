--[[
	GridUtil - pure math for the Bullrush shrinking grid. No Workspace
	access; safe to require from both server and client.

	The PHYSICAL grid is 9x9 (Config.GRID_SIZE). Each round plays inside a
	centered square WINDOW of it (the mode's startSize: 9, 7, or 5), which
	then shrinks stage by stage. See boundsForStage.

	A "lane" is a plain table: { axis = "row" | "col", index = 1..GRID_SIZE, direction = 1 | -1 }
	- axis = "row": bull travels along X at that row's constant Z.
	  direction = 1 starts WEST (min X) traveling toward +X; direction = -1 starts EAST.
	- axis = "col": bull travels along Z at that column's constant X.
	  direction = 1 starts NORTH (min Z) traveling toward +Z; direction = -1 starts SOUTH.

	A "bounds" is a plain table: { rowMin, rowMax, colMin, colMax } (exactly
	those keys) describing the ACTIVE window of the shrinking arena.

	Remote contract (ReplicatedStorage.Bullrush.Remotes), all server -> client:
	- Telegraph:FireAllClients(lanes: {lane}, warnTime: number, bounds)
	- ChargeStart:FireAllClients(lane, duration: number, bounds)
	- LaneCleared:FireAllClients(lane)
	- Eliminated:FireAllClients(playerName: string, aliveCount: number, cause: string?)
	  cause is flavor for the toast; "REVENGE" = a revenge bull did it.
	- RoundState:FireAllClients(state: string, info: table)
	  states: "WAITING" | "INTERMISSION" | "ACTIVE" | "WINNER" | "ROUNDOVER"
	  info may contain: timeLeft, aliveCount, wave, winnerName,
	  gridSize (active window side length, 3..9),
	  bounds (current active window, ACTIVE updates only),
	  modeName / modeId (current round's mode, see Config.MODES),
	  teamCounts ({ RED = n, BLUE = n }, Team Rush ACTIVE updates only),
	  teamColor ("RED" | "BLUE", Team Rush WINNER only)
	- ArenaShrink:FireAllClients(stage: number, bounds, removedCells: {{row, col}}, telegraphTime: number)
	  Fired at the START of the shrink telegraph; tiles sink telegraphTime
	  seconds later. The server recolors dropped tiles charcoal
	  Color3.fromRGB(55, 48, 42) and restores position/color at round start.
	- RevengeAck:FireClient(thrower, kind: string, data: table) -- to the
	  thrower only: "THROW_OK" { cooldown }, "HIT" { victimName, amount },
	  "DENIED" { reason: "COOLDOWN" | "BOUNDS", remaining: number? }
	  Revenge throws have NO client->server remote: eliminated participants
	  step on server-side pressure pads (Workspace.BullrushArena.RevengePads,
	  built by RevengeService per window; lane in pad attributes). The client
	  only repaints the pads locally (ready pulse / cooldown countdown).
]]

local Config = require(script.Parent.Config)

local GridUtil = {}

local ORIGIN = Config.ARENA_ORIGIN
local TILE_SIZE = Config.TILE_SIZE
local GRID_SIZE = Config.GRID_SIZE
local CENTER_INDEX = (GRID_SIZE + 1) / 2 -- 5 for a 9x9 grid

export type Lane = { axis: string, index: number, direction: number }
export type Bounds = { rowMin: number, rowMax: number, colMin: number, colMax: number }
export type Cell = { row: number, col: number }

-- Top-surface center of tile (row, col).
function GridUtil.tileCenter(row: number, col: number): Vector3
	return Vector3.new(
		ORIGIN.X + (col - CENTER_INDEX) * TILE_SIZE,
		ORIGIN.Y,
		ORIGIN.Z + (row - CENTER_INDEX) * TILE_SIZE
	)
end

-- Inverse of tileCenter via rounding (Y is ignored).
-- Returns (row, col), or nil if the rounded tile falls outside 1..GRID_SIZE.
function GridUtil.worldToTile(position: Vector3): (number?, number?)
	local col = math.round((position.X - ORIGIN.X) / TILE_SIZE + CENTER_INDEX)
	local row = math.round((position.Z - ORIGIN.Z) / TILE_SIZE + CENTER_INDEX)
	if row < 1 or row > GRID_SIZE or col < 1 or col > GRID_SIZE then
		return nil
	end
	return row, col
end

-- Active window for a shrink stage. startSize (default GRID_SIZE) is the
-- side length of the stage-0 window, centered in the physical grid (both
-- must be odd so the offset is an integer). Each subsequent stage trims one
-- row AND one col, alternating sides starting with the MAX side, e.g.
-- startSize 7 in the 9x9 grid:
--   stage 0 = { 2, 8, 2, 8 }, stage 1 = { 2, 7, 2, 7 },
--   stage 2 = { 3, 7, 3, 7 }, stage 3 = { 3, 6, 3, 6 }
function GridUtil.boundsForStage(stage: number, startSize: number?): Bounds
	local size = startSize or GRID_SIZE
	local offset = math.floor((GRID_SIZE - size) / 2)
	local bounds = {
		rowMin = 1 + offset,
		rowMax = GRID_SIZE - offset,
		colMin = 1 + offset,
		colMax = GRID_SIZE - offset,
	}
	for step = 1, stage do
		if step % 2 == 1 then
			bounds.rowMax -= 1
			bounds.colMax -= 1
		else
			bounds.rowMin += 1
			bounds.colMin += 1
		end
	end
	return bounds
end

-- Whether tile (row, col) lies inside the active window.
function GridUtil.inBounds(row: number, col: number, bounds: Bounds): boolean
	return row >= bounds.rowMin and row <= bounds.rowMax
		and col >= bounds.colMin and col <= bounds.colMax
end

-- Array of { row = r, col = c } for the lane's tiles INSIDE bounds,
-- ordered along the bull's travel direction. bounds defaults to the full grid.
function GridUtil.laneTiles(lane: Lane, bounds: Bounds?): { Cell }
	local window = bounds or GridUtil.boundsForStage(0)
	local tiles = {}
	local first, last
	if lane.axis == "row" then
		first, last = window.colMin, window.colMax
	else
		first, last = window.rowMin, window.rowMax
	end
	local step = 1
	if lane.direction == -1 then
		first, last, step = last, first, -1
	end
	for i = first, last, step do
		local row, col
		if lane.axis == "row" then
			row, col = lane.index, i
		else
			row, col = i, lane.index
		end
		if GridUtil.inBounds(row, col, window) then
			table.insert(tiles, { row = row, col = col })
		end
	end
	return tiles
end

-- The constant coordinate of the lane's center line:
-- the Z value for a row lane, the X value for a col lane.
function GridUtil.laneCrossCoord(lane: Lane): number
	if lane.axis == "row" then
		return ORIGIN.Z + (lane.index - CENTER_INDEX) * TILE_SIZE
	else
		return ORIGIN.X + (lane.index - CENTER_INDEX) * TILE_SIZE
	end
end

-- Bull Root center start/end positions for a lane across the ACTIVE window.
-- Along the travel axis the window edges are tileCenter(minIdx) - TILE_SIZE/2
-- and tileCenter(maxIdx) + TILE_SIZE/2 (minIdx/maxIdx from bounds on the
-- travel axis: colMin/colMax for row lanes, rowMin/rowMax for col lanes),
-- extended outward by BULL_OVERSHOOT. Y = ORIGIN.Y + BULL_RIDE_HEIGHT.
-- direction = 1 starts at the min edge. bounds defaults to the full grid.
function GridUtil.lanePath(lane: Lane, bounds: Bounds?): (Vector3, Vector3)
	local window = bounds or GridUtil.boundsForStage(0)
	local cross = GridUtil.laneCrossCoord(lane)
	local y = ORIGIN.Y + Config.BULL_RIDE_HEIGHT

	local minIdx, maxIdx, originAxis
	if lane.axis == "row" then
		minIdx, maxIdx = window.colMin, window.colMax
		originAxis = ORIGIN.X
	else
		minIdx, maxIdx = window.rowMin, window.rowMax
		originAxis = ORIGIN.Z
	end

	local minEdge = originAxis + (minIdx - CENTER_INDEX) * TILE_SIZE - TILE_SIZE / 2 - Config.BULL_OVERSHOOT
	local maxEdge = originAxis + (maxIdx - CENTER_INDEX) * TILE_SIZE + TILE_SIZE / 2 + Config.BULL_OVERSHOOT

	local startCoord, endCoord = minEdge, maxEdge
	if lane.direction == -1 then
		startCoord, endCoord = maxEdge, minEdge
	end

	if lane.axis == "row" then
		return Vector3.new(startCoord, y, cross), Vector3.new(endCoord, y, cross)
	else
		return Vector3.new(cross, y, startCoord), Vector3.new(cross, y, endCoord)
	end
end

return GridUtil