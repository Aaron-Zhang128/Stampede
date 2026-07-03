--[[
	RevengeService - eliminated participants send one bull down a lane by
	STEPPING ON a pressure pad at that lane's end, on a per-player cooldown,
	and earn Money for every alive player their bull tramples.

	Pads ring the CURRENT window - one at each end of every row and column,
	just outside the guard walls (the bull charges INWARD from the pad you
	step on) - and slide inward as the arena shrinks. Everyone sees them;
	only eliminated participants of the current round can trigger them
	(requestThrow validates, so alive players and bystanders are inert).
	Standing on a pad re-fires automatically each time the cooldown laps.

	Client contract (see GridUtil header):
	- RevengeAck:FireClient(thrower, kind, data) answers the thrower only:
	  "THROW_OK" { cooldown }, "HIT" { victimName, amount }, "DENIED" { reason }.
	  The client drives pad glow/countdown visuals from THROW_OK timing.

	Main drives roundStarted()/refreshPads()/roundEnded(); throws are rejected
	outside that window, and in-flight bulls stop killing once the round is
	decided.
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

local REQUEST_GAP = 0.3 -- silent spam guard, well inside the real cooldown
local DENIED_ACK_GAP = 4 -- pad-standers retry every frame; one red card per card-lifetime
local PAD_SIZE = 6 -- studs square
local PAD_THICKNESS = 1.2
local PAD_GAP = 1.5 -- clearance between the wall's outer face and the pad edge
local PAD_TOP_LIFT = 0.4 -- pad top sits this far above canonical tile-top height
local WALL_THICKNESS = 1 -- matches ShrinkService's guard walls
-- Server paints the resting look; the CLIENT re-paints pads locally per
-- viewer (ready pulse / countdown / inert) - see BullrushClient.
local PAD_BASE_COLOR = Color3.fromRGB(90, 34, 30)

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
		Remotes.RevengeAck:FireClient(thrower, kind, data)
	end
end

--==============================================================================
-- Pressure pads
--==============================================================================

local function padsFolder(): Folder
	local arena = Workspace:FindFirstChild("BullrushArena")
	local parent = arena or Workspace
	local folder = parent:FindFirstChild("RevengePads")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "RevengePads"
		folder.Parent = parent
	end
	return folder
end

-- Pad center for a lane: on the lane's center line, one wall + gap + half a
-- pad beyond the window's boundary-tile outer edge, top slightly proud of
-- tile-top height so it reads as a raised button.
local function padCFrame(lane, bounds): CFrame
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
	local standoff = WALL_THICKNESS + PAD_GAP + PAD_SIZE / 2
	local along
	if lane.direction == 1 then
		along = originAxis + (minIdx - centerIndex) * Config.TILE_SIZE - half - standoff
	else
		along = originAxis + (maxIdx - centerIndex) * Config.TILE_SIZE + half + standoff
	end
	local y = Config.ARENA_ORIGIN.Y + PAD_TOP_LIFT - PAD_THICKNESS / 2
	local position = if lane.axis == "row"
		then Vector3.new(along, y, cross)
		else Vector3.new(cross, y, along)
	-- Face the pad toward the arena so its surface arrow points inward.
	local inward = if lane.axis == "row"
		then Vector3.new(lane.direction, 0, 0)
		else Vector3.new(0, 0, lane.direction)
	return CFrame.lookAt(position, position + inward)
end

local function onPadTouched(lane)
	return function(hit: BasePart)
		local character = hit and hit:FindFirstAncestorOfClass("Model")
		local player = character and Players:GetPlayerFromCharacter(character)
		if player then
			RevengeService.requestThrow(player, lane)
		end
	end
end

local function buildPad(lane, bounds)
	local pad = Instance.new("Part")
	pad.Name = ("Pad_%s_%d_%d"):format(lane.axis, lane.index, lane.direction)
	pad.Size = Vector3.new(PAD_SIZE, PAD_THICKNESS, PAD_SIZE)
	pad.CFrame = padCFrame(lane, bounds)
	pad.Anchored = true
	pad.CanCollide = true
	pad.Material = Enum.Material.SmoothPlastic
	pad.Color = PAD_BASE_COLOR
	pad:SetAttribute("axis", lane.axis)
	pad:SetAttribute("index", lane.index)
	pad:SetAttribute("direction", lane.direction)

	-- Big inward arrow on the top face ("gui-up" on a Top-face SurfaceGui
	-- runs along the part's -Z look vector, which padCFrame points inward).
	local surface = Instance.new("SurfaceGui")
	surface.Name = "PadSurface"
	surface.Face = Enum.NormalId.Top
	surface.LightInfluence = 0
	surface.AlwaysOnTop = false
	surface.Parent = pad
	local arrow = Instance.new("TextLabel")
	arrow.Name = "Arrow"
	arrow.BackgroundTransparency = 1
	arrow.Size = UDim2.fromScale(1, 0.62)
	arrow.Position = UDim2.fromScale(0, 0)
	arrow.Font = Enum.Font.GothamBlack
	arrow.TextScaled = true
	arrow.TextColor3 = Color3.fromRGB(255, 235, 230)
	arrow.Text = "▲"
	arrow.Parent = surface
	local caption = Instance.new("TextLabel")
	caption.Name = "Caption"
	caption.BackgroundTransparency = 1
	caption.Size = UDim2.fromScale(1, 0.3)
	caption.Position = UDim2.fromScale(0, 0.65)
	caption.Font = Enum.Font.GothamBlack
	caption.TextScaled = true
	caption.TextColor3 = Color3.fromRGB(255, 235, 230)
	caption.Text = "SEND BULL"
	caption.Parent = surface

	-- No floating text: the pad's COLOR is the signal (client paints green =
	-- ready / red = cooldown) and stomp feedback arrives as Notify cards.
	pad.Touched:Connect(onPadTouched(lane))
	pad.Parent = padsFolder()
end

local function clearPads()
	padsFolder():ClearAllChildren() -- also drops the Touched connections
end

-- (Re)build the pad ring for the CURRENT window. Called at round start and
-- after every shrink stage; between rounds the folder stays empty.
function RevengeService.refreshPads()
	clearPads()
	if not enabled then
		return
	end
	local bounds = ShrinkService.getBounds()
	for row = bounds.rowMin, bounds.rowMax do
		buildPad({ axis = "row", index = row, direction = 1 }, bounds)
		buildPad({ axis = "row", index = row, direction = -1 }, bounds)
	end
	for col = bounds.colMin, bounds.colMax do
		buildPad({ axis = "col", index = col, direction = 1 }, bounds)
		buildPad({ axis = "col", index = col, direction = -1 }, bounds)
	end
end

--==============================================================================
-- Round lifecycle + throw pipeline
--==============================================================================

function RevengeService.roundStarted()
	table.clear(cooldownUntil)
	enabled = true
	RevengeService.refreshPads()
end

function RevengeService.roundEnded()
	enabled = false
	table.clear(cooldownUntil)
	clearPads()
end

-- Public (not just the pads' target) so smoke tests can call it directly.
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
		-- Standing on a pad retries constantly; don't flood the client
		-- (gap ≈ one card lifetime, so at most one red card shows at a time).
		if now - (lastDeniedAt[thrower] or 0) >= DENIED_ACK_GAP then
			lastDeniedAt[thrower] = now
			local remaining = cooldownUntil[thrower] - now
			NotifyService.send(thrower,
				("Revenge bull ready in %ds"):format(math.ceil(remaining)), "red")
			ack(thrower, "DENIED", {
				reason = "COOLDOWN",
				remaining = remaining, -- lets a desynced client resync its pad state
			})
		end
		return
	end
	local bounds = ShrinkService.getBounds()
	local laneMin = if axis == "row" then bounds.rowMin else bounds.colMin
	local laneMax = if axis == "row" then bounds.rowMax else bounds.colMax
	if index < laneMin or index > laneMax then
		-- a shrink can trim the lane between pad spawn and the stomp
		NotifyService.send(thrower, "That lane is gone — the arena shrank!", "red")
		ack(thrower, "DENIED", { reason = "BOUNDS" })
		return
	end

	-- Rebuild the lane clean; never forward tables from outside this module.
	local lane = { axis = axis, index = index, direction = direction }

	cooldownUntil[thrower] = now + Config.REVENGE.COOLDOWN
	NotifyService.send(thrower,
		("Revenge bull charging down %s %d!"):format(
			if axis == "row" then "row" else "column", index), "green")
	ack(thrower, "THROW_OK", { cooldown = Config.REVENGE.COOLDOWN })

	task.spawn(function()
		Remotes.Telegraph:FireAllClients({ lane }, Config.REVENGE.TELEGRAPH, bounds)
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
				NotifyService.send(thrower,
					("+%d Money — your revenge bull hit %s!"):format(paid, victim.Name), "green")
				ack(thrower, "HIT", {
					victimName = victim.Name,
					amount = paid,
				})
			end
		end
		BullService.charge(lane, Config.REVENGE.SPEED, bounds, RoundService.getAlive, onKill)
	end)
end

Players.PlayerRemoving:Connect(function(player)
	cooldownUntil[player] = nil
	lastRequestAt[player] = nil
	lastDeniedAt[player] = nil
end)

return RevengeService
