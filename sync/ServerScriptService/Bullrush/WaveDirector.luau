--[[
	WaveDirector - pure wave generation. No Workspace/Remote access.

	WaveDirector.getWave(intensity, bounds, difficulty?) ->
		{ telegraph = seconds, gap = seconds, speed = studs/s,
		  bulls = { { lane = lane, delay = seconds }, ... } }

	intensity = 0..1 round progress (Main computes elapsed / rampTime,
	clamped here as well); telegraph/gap/speed/bull count each lerp
	difficulty.START -> difficulty.FINAL, so bulls get continuously harder
	over the round with no discrete wave types. The fractional part of the
	lerped bull count becomes a probabilistic extra bull, keeping the ramp
	smooth between integer counts.

	difficulty defaults to Config.DIFFICULTY; modes may pass their own
	{ START = {...}, FINAL = {...} } (e.g. Stampede's 2 -> 5 bulls).

	bounds = active window (see GridUtil.boundsForStage); lane indices come
	from bounds (rowMin..rowMax for row lanes, colMin..colMax for col lanes).
	lane = { axis = "row"|"col", index, direction = 1|-1 } (see GridUtil).
	delay = seconds after the telegraph ends when that bull launches; the
	first bull is always 0, later bulls stagger up to 0.4s so multi-bull
	waves feel like a rolling stampede rather than one wall.

	Guarantees per wave: no duplicate (axis, index), and at most
	activeSize - 1 lanes on the same axis, so at least one full row AND one
	full col of the active window always survive.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Bullrush.Config)

local WaveDirector = {}

local function lerp(a: number, b: number, t: number): number
	return (1 - t) * a + t * b -- endpoint-exact: t=0 -> a, t=1 -> b
end

local function randomAxis(): string
	return if math.random(2) == 1 then "row" else "col"
end

local function randomDirection(): number
	return if math.random(2) == 1 then 1 else -1
end

local function otherAxis(axis: string): string
	return if axis == "row" then "col" else "row"
end

local function axisRange(axis: string, bounds): (number, number)
	if axis == "row" then
		return bounds.rowMin, bounds.rowMax
	else
		return bounds.colMin, bounds.colMax
	end
end

local function randomLane(axis: string, bounds)
	local minIdx, maxIdx = axisRange(axis, bounds)
	return { axis = axis, index = math.random(minIdx, maxIdx), direction = randomDirection() }
end

-- Safety net for the hard rules (see header comment).
local function validate(bulls, bounds)
	assert(#bulls > 0, "WaveDirector: empty wave")
	local activeSize = bounds.rowMax - bounds.rowMin + 1
	local seen = {}
	local perAxis = { row = 0, col = 0 }
	for _, bull in bulls do
		local lane = bull.lane
		local minIdx, maxIdx = axisRange(lane.axis, bounds)
		assert(lane.index >= minIdx and lane.index <= maxIdx,
			"WaveDirector: lane index out of bounds: " .. lane.axis .. lane.index)
		local key = lane.axis .. lane.index
		assert(not seen[key], "WaveDirector: duplicate lane " .. key)
		seen[key] = true
		perAxis[lane.axis] += 1
	end
	assert(perAxis.row <= activeSize - 1 and perAxis.col <= activeSize - 1,
		"WaveDirector: wave covers an entire axis")
end

function WaveDirector.getWave(intensity: number, bounds, difficulty)
	assert(type(intensity) == "number",
		"WaveDirector.getWave: intensity must be a number")
	intensity = math.clamp(intensity, 0, 1)
	difficulty = difficulty or Config.DIFFICULTY

	local START = difficulty.START
	local FINAL = difficulty.FINAL
	local activeSize = bounds.rowMax - bounds.rowMin + 1

	-- Fractional part of the lerped count = chance of one extra bull.
	local count = math.floor(lerp(START.bulls, FINAL.bulls, intensity) + math.random())
	count = math.clamp(count, 1, FINAL.bulls)
	count = math.min(count, 2 * (activeSize - 1)) -- what the hard rules allow

	local bulls = {}
	local used: { [string]: boolean } = {}
	local perAxis = { row = 0, col = 0 }
	local attempts = 0
	while #bulls < count and attempts < 50 do -- defensive cap: settle for fewer
		attempts += 1
		local axis = randomAxis()
		if perAxis[axis] >= activeSize - 1 then
			axis = otherAxis(axis) -- saturated; use the other axis
			if perAxis[axis] >= activeSize - 1 then
				break -- both saturated; settle for fewer bulls
			end
		end
		local lane = randomLane(axis, bounds)
		local key = lane.axis .. lane.index
		if not used[key] then -- reject duplicates, re-roll
			used[key] = true
			perAxis[axis] += 1
			local delay = if #bulls == 0 then 0 else math.random() * 0.4
			table.insert(bulls, { lane = lane, delay = delay })
		end
	end

	validate(bulls, bounds)
	return {
		telegraph = lerp(START.telegraph, FINAL.telegraph, intensity),
		gap = lerp(START.gap, FINAL.gap, intensity),
		speed = lerp(START.speed, FINAL.speed, intensity),
		bulls = bulls,
	}
end

return WaveDirector