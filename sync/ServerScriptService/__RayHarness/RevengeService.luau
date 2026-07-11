--[[
	RevengeService - eliminated participants send one bull down a lane by
	CLICKING an arrow marker at that lane's end from the overhead bull-cam
	(BullrushClient owns the camera), on a per-player cooldown, and earn
	Money for every alive player their bull tramples.

	Markers ring the CURRENT window - one at each end of every row and
	column, just outside the guard walls (the bull charges INWARD from the
	marker you click) - and slide inward as the arena shrinks. Each marker
	carries a server-side ClickDetector, so there is no client->server
	remote to spoof; only eliminated participants of the current round can
	trigger them (requestThrow validates, so alive players and bystanders
	are inert - the client also hides the markers and zeroes their click
	range locally).

	Client contract (see GridUtil header):
	- RevengeAck:FireClient(thrower, kind, data) answers the thrower only:
	  "THROW_OK" { cooldown, lane }, "HIT" { victimName, amount },
	  "DENIED" { reason }. The client drives marker glow/countdown visuals
	  from THROW_OK timing and presses the acked lane's marker.

	Main drives roundStarted()/refreshMarkers()/roundEnded(); throws are
	rejected outside that window, and in-flight bulls stop killing once the
	round is decided.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Bullrush.Config)
local GridUtil = require(ReplicatedStorage.Bullrush.GridUtil)
local Remotes = ReplicatedStorage.Bullrush.Remotes

local BullService = require(script.Parent.BullService)
local NotifyService = require(script.Parent.NotifyService)
local RoundService = require(script.Parent.RoundService)
local ShrinkService = require(script.Parent.ShrinkService)
local EconomyService = require(script.Parent.EconomyService)

local REQUEST_GAP = 0.3 -- silent spam guard, well inside the real cooldown
local DENIED_ACK_GAP = 4 -- click-mashers on cooldown get one red card per card-lifetime
local MARKER_SIZE = 6 -- studs square
local MARKER_THICKNESS = 1.2
local MARKER_GAP = 1.5 -- clearance between the wall's outer face and the marker edge
-- Markers FLOAT above the guard walls (16 studs tall): the overhead bull-cam
-- clicks them via mouse rays, and nothing may ever sit between the camera and
-- a marker (walls/tiles/decor all top out below this plane). BullrushClient's
-- overheadCFrame mirrors this constant to keep the raised ring in frame.
local MARKER_HOVER = 17 -- marker center this far above tile-top height
local WALL_THICKNESS = 1 -- matches ShrinkService's guard walls
local CLICK_RANGE = 512 -- clickers aim from the lobby (frozen ~150 studs out) via the overhead cam
-- Server paints the resting look; the CLIENT re-paints markers locally per
-- viewer (ready pulse / countdown / hidden) - see BullrushClient.
local MARKER_BASE_COLOR = Color3.fromRGB(90, 34, 30)

local RevengeService = {}

local enabled = false
local cooldownUntil: { [Player]: number } = {} -- os.clock() deadline per thrower
local lastRequestAt: { [Player]: number } = {}
local lastDeniedAt: { [Player]: number } = {}

-- The Team Rush payout flip lives here: to stop paying for teammate hits,
-- change the body to: return thrower.Team == nil or thrower.Team ~= victim.Team
local function shouldReward(thrower: Player, victim: Player): boolean
	return true
end

-- Smoke tests drive requestThrow with duck-typed stub players (like the
-- bots in AIService); only real Players can receive remote acks.
local function ack(thrower: Player, kind: string, data: { [string]: any })
	if typeof(thrower) == "Instance" then
		print(thrower, kind, data)
	end
end

--==============================================================================
-- Lane markers (the clickable arrows)
--==============================================================================

local function markersFolder(): Folder
	local arena = Workspace:FindFirstChild("BullrushArena")
	local parent = arena or Workspace
	local folder = parent:FindFirstChild("RevengeMarkers")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "RevengeMarkers"
		folder.Parent = parent
	end
	return folder
end

-- Marker center for a lane: on the lane's center line, one wall + gap + half
-- a marker beyond the window's boundary-tile outer edge, floating MARKER_HOVER
-- above tile-top height so the overhead cam always has line of sight.
local function markerCFrame(lane, bounds): CFrame
	local cross = GridUtil.laneCrossCoord(lane)
	local minIdx, maxIdx, originAxis
	if lane.axis == "row" then
		minIdx, maxIdx = bounds.colMin, bounds.colMax
		originAxis = Config.ARENA_ORIGIN.X
	else
		minIdx, maxIdx = bounds.rowMin, bounds.rowMax
		originAxis = Config.ARENA_ORIGIN.Z
	end
	local centerIndex = (Config.GRID_SIZE + 1) / 2
	local half = Config.TILE_PART_SIZE / 2
	local standoff = WALL_THICKNESS + MARKER_GAP + MARKER_SIZE / 2
	local along
	if lane.direction == 1 then
		along = originAxis + (minIdx - centerIndex) * Config.TILE_SIZE - half - standoff
	else
		along = originAxis + (maxIdx - centerIndex) * Config.TILE_SIZE + half + standoff
	end
	local y = Config.ARENA_ORIGIN.Y + MARKER_HOVER
	local position = if lane.axis == "row"
		then Vector3.new(along, y, cross)
		else Vector3.new(cross, y, along)
	-- Face the marker toward the arena so its surface arrow points inward.
	local inward = if lane.axis == "row"
		then Vector3.new(lane.direction, 0, 0)
		else Vector3.new(0, 0, lane.direction)
	return CFrame.lookAt(position, position + inward)
end

local function buildMarker(lane, bounds)
	local marker = Instance.new("Part")
	marker.Name = ("Marker_%s_%d_%d"):format(lane.axis, lane.index, lane.direction)
	marker.Size = Vector3.new(MARKER_SIZE, MARKER_THICKNESS, MARKER_SIZE)
	marker.CFrame = markerCFrame(lane, bounds)
	marker.Anchored = true
	marker.CanCollide = false
	marker.Material = Enum.Material.SmoothPlastic
	marker.Color = MARKER_BASE_COLOR
	marker:SetAttribute("axis", lane.axis)
	marker:SetAttribute("index", lane.index)
	marker:SetAttribute("direction", lane.direction)

	-- Button face on the top - the face the overhead cam looks at ("gui-up"
	-- on a Top-face SurfaceGui runs along the part's -Z look vector, which
	-- markerCFrame points inward). A rounded, outlined PLATE frame is the
	-- button body: the client recolors plate + part per viewer state, tints
	-- the white glyphs with green/red text gradients, and scales the plate on
	-- hover (UIScale "HoverScale").
	local surface = Instance.new("SurfaceGui")
	surface.Name = "MarkerSurface"
	surface.Face = Enum.NormalId.Top
	surface.LightInfluence = 0
	surface.AlwaysOnTop = false
	surface.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	surface.PixelsPerStud = 50
	surface.Parent = marker

	local plate = Instance.new("Frame")
	plate.Name = "Plate"
	plate.AnchorPoint = Vector2.new(0.5, 0.5)
	plate.Position = UDim2.fromScale(0.5, 0.5)
	plate.Size = UDim2.fromScale(0.94, 0.94) -- inset so neighboring buttons read as separate
	plate.BackgroundColor3 = MARKER_BASE_COLOR
	plate.BorderSizePixel = 0
	plate.Parent = surface
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.18, 0)
	corner.Parent = plate
	local rim = Instance.new("UIStroke")
	rim.Name = "Rim"
	rim.Color = Color3.fromRGB(20, 16, 14)
	rim.Thickness = 4
	rim.Transparency = 0.1
	rim.Parent = plate
	local bevel = Instance.new("UIGradient")
	bevel.Rotation = 90 -- lit top edge -> shaded bottom, multiplies the state color
	bevel.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
		ColorSequenceKeypoint.new(0.55, Color3.fromRGB(215, 215, 215)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(150, 150, 150)),
	})
	bevel.Parent = plate
	local hoverScale = Instance.new("UIScale")
	hoverScale.Name = "HoverScale"
	hoverScale.Parent = plate

	local function addGlyph(name: string, text: string, yScale: number, heightScale: number)
		local label = Instance.new("TextLabel")
		label.Name = name
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, heightScale)
		label.Position = UDim2.fromScale(0, yScale)
		label.Font = Enum.Font.GothamBlack
		label.TextScaled = true
		label.TextColor3 = Color3.fromRGB(255, 255, 255) -- white base; client tints via UIGradient
		label.Text = text
		local outline = Instance.new("UIStroke")
		outline.Color = Color3.fromRGB(15, 10, 8)
		outline.Thickness = 3
		outline.Parent = label
		label.Parent = plate
		return label
	end
	addGlyph("Arrow", "▲", 0.02, 0.6)
	addGlyph("Caption", "SEND BULL", 0.64, 0.26)

	-- No floating text: the marker's COLOR is the signal (client paints green
	-- = ready / red = cooldown) and outcomes arrive as Notify cards. Clicks
	-- land server-side (MouseClick), same validation for every clicker.
	local click = Instance.new("ClickDetector")
	click.MaxActivationDistance = CLICK_RANGE
	click.MouseClick:Connect(function(clicker: Player)
		RevengeService.requestThrow(clicker, lane)
	end)
	click.Parent = marker

	marker.Parent = markersFolder()
end

local function clearMarkers()
	markersFolder():ClearAllChildren() -- also drops the MouseClick connections
end

-- (Re)build the marker ring for the CURRENT window. Called at round start and
-- after every shrink stage; between rounds the folder stays empty.
function RevengeService.refreshMarkers()
	clearMarkers()
	if not enabled then
		return
	end
	local bounds = ShrinkService.getBounds()
	for row = bounds.rowMin, bounds.rowMax do
		buildMarker({ axis = "row", index = row, direction = 1 }, bounds)
		buildMarker({ axis = "row", index = row, direction = -1 }, bounds)
	end
	for col = bounds.colMin, bounds.colMax do
		buildMarker({ axis = "col", index = col, direction = 1 }, bounds)
		buildMarker({ axis = "col", index = col, direction = -1 }, bounds)
	end
end

--==============================================================================
-- Round lifecycle + throw pipeline
--==============================================================================

function RevengeService.roundStarted()
	table.clear(cooldownUntil)
	enabled = true
	RevengeService.refreshMarkers()
end

function RevengeService.roundEnded()
	enabled = false
	table.clear(cooldownUntil)
	clearMarkers()
end

-- True between roundStarted() and roundEnded() — the exact window when
-- markers accept clicks. The client's bull-cam gates on round state +
-- elimination the same way, so "can see the board" and "markers work" can
-- never disagree.
function RevengeService.isEnabled(): boolean
	return enabled
end

-- Public (not just the markers' target) so smoke tests can call it directly.
function RevengeService.requestThrow(thrower: Player, laneData: any)
	local now = os.clock()
	if now - (lastRequestAt[thrower] or 0) < REQUEST_GAP then
		return
	end
	lastRequestAt[thrower] = now

	if not enabled then
		return
	end
	if typeof(laneData) ~= "table" then
		return
	end
	local axis = laneData.axis
	local index = tonumber(laneData.index)
	local direction = laneData.direction
	if (axis ~= "row" and axis ~= "col")
		or index == nil or index % 1 ~= 0
		or (direction ~= 1 and direction ~= -1)
	then
		return
	end
	if not RoundService.isEliminatedParticipant(thrower) then
		return
	end
	if now < (cooldownUntil[thrower] or 0) then
		-- Mashing a cooling marker shouldn't flood the client
		-- (gap ≈ one card lifetime, so at most one red card shows at a time).
		if now - (lastDeniedAt[thrower] or 0) >= DENIED_ACK_GAP then
			lastDeniedAt[thrower] = now
			local remaining = cooldownUntil[thrower] - now
			NotifyService.send(thrower,
				("Bull ready in %ds"):format(math.ceil(remaining)), "red")
			ack(thrower, "DENIED", {
				reason = "COOLDOWN",
				remaining = remaining, -- lets a desynced client resync its marker state
			})
		end
		return
	end
	local bounds = ShrinkService.getBounds()
	local laneMin = if axis == "row" then bounds.rowMin else bounds.colMin
	local laneMax = if axis == "row" then bounds.rowMax else bounds.colMax
	if index < laneMin or index > laneMax then
		-- a shrink can trim the lane between marker spawn and the click
		NotifyService.send(thrower, "That lane is gone!", "red")
		ack(thrower, "DENIED", { reason = "BOUNDS" })
		return
	end

	-- Rebuild the lane clean; never forward tables from outside this module.
	local lane = { axis = axis, index = index, direction = direction }

	cooldownUntil[thrower] = now + Config.REVENGE.COOLDOWN
	NotifyService.send(thrower,
		("Bull charging down %s %d!"):format(
			if axis == "row" then "row" else "column", index), "green")
	ack(thrower, "THROW_OK", { cooldown = Config.REVENGE.COOLDOWN, lane = lane })

	task.spawn(function()
		print({ lane }, Config.REVENGE.TELEGRAPH, bounds)
		task.wait(Config.REVENGE.TELEGRAPH)
		if not enabled then
			return -- round was decided during the telegraph
		end
		local function onKill(victim: Player)
			if not enabled then
				return -- never trample players under the winner banner
			end
			local wasAlive = RoundService.isAlive(victim)
			RoundService.eliminate(victim, "REVENGE")
			if wasAlive and thrower.Parent ~= nil and shouldReward(thrower, victim) then
				local paid = RoundService.awardMoney(thrower, Config.REVENGE.MONEY_PER_HIT)
				EconomyService.noteRevenge(thrower, paid) -- shows on the Summary tab
				NotifyService.send(thrower,
					("+%d Money — your bull hit %s!"):format(paid, victim.Name), "green")
				ack(thrower, "HIT", {
					victimName = victim.Name,
					amount = paid,
				})
			end
		end
		BullService.charge(lane, Config.REVENGE.SPEED, bounds, RoundService.getAlive, onKill,
			{ throwerName = thrower.Name })
	end)
end

Players.PlayerRemoving:Connect(function(player)
	cooldownUntil[player] = nil
	lastRequestAt[player] = nil
	lastDeniedAt[player] = nil
end)

return RevengeService
