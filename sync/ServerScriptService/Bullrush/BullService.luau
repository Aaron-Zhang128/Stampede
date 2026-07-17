--[[
	BullService - runs a single bull charge down a lane.

	The server never builds or moves a bull MODEL: a charge is pure logic
	(deterministic path math + the kill box). Rendering is fully client-side —
	chargeAlong fires Remotes.BullVisual once at launch with everything a
	client needs to build and drive the bull locally (path, speed, style, and
	a GetServerTimeNow launch stamp so every client's bull sits exactly where
	the server's kill box is), and BullVisualEnd when the charge exits so
	clients tear the model down. See BullrushClient "client-rendered bulls".

	BullService.charge(lane, speed, bounds, getAlivePlayers, onKill) -> duration
	- BLOCKING: yields until the bull exits the arena (or the charge is
	  cancelled via BullService.cancelAll), then returns the charge duration
	  in seconds. The CALLER is responsible for concurrency: run each
	  simultaneous lane in its own task.spawn. charge() uses only locals, so
	  overlapping calls are safe.
	- bounds: active-window bounds (see GridUtil); the charge path spans only
	  the window plus BULL_OVERSHOOT on each side.
	- getAlivePlayers: () -> { Player }, polled every Heartbeat for kill checks.
	- onKill: (Player) -> (), called at most once per player per charge.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Bullrush.Config)
local GridUtil = require(ReplicatedStorage.Bullrush.GridUtil)
local Remotes = ReplicatedStorage.Bullrush.Remotes

local RagdollService = require(script.Parent.RagdollService)
local ExtraLivesService = require(script.Parent.ExtraLivesService)

-- Same ensure-on-require pattern as the other services: the Remotes folder is
-- built in edit mode, so places that predate a feature still get its remotes.
local function ensureRemote(name: string): RemoteEvent
	local remote = Remotes:FindFirstChild(name)
	if not (remote and remote:IsA("RemoteEvent")) then
		remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = Remotes
	end
	return remote
end
local BullVisual = ensureRemote("BullVisual") -- server -> client: build + drive this bull locally
local BullVisualEnd = ensureRemote("BullVisualEnd") -- server -> client: tear the bull down

local LAUNCH_SPEED_SCALE = 1.4 -- victim fling speed relative to bull speed
local LAUNCH_SPEED_BASE = 16 -- studs/s added on top, so slow bulls still send you

local BullService = {}

-- Every in-flight charge, so round cleanup can stop them without a model to
-- destroy. Keyed by the charge id the clients render under.
local nextChargeId = 0
local activeCharges: { [number]: { cancelled: boolean, main: boolean } } = {}

-- Cancels every MAIN-arena charge (each loop exits on its next Heartbeat and
-- fires BullVisualEnd, so clients drop the models). Practice-arena charges
-- (parentFolder overrides) are untouched — round cleanup never owned them.
function BullService.cancelAll()
	for _, state in activeCharges do
		if state.main then
			state.cancelled = true
		end
	end
end

-- chargeAlong runs a bull straight from startPos to endPos (Root-center world
-- positions) at `speed`, killing players inside the axis-aligned kill box around
-- crossCoord. `axis` ("row" | "col") is the travel axis the kill box measures
-- along. onCharge(duration) / onCleared() are optional hooks fired at launch /
-- exit (the main game wires the ChargeStart / LaneCleared remotes there; the
-- practice arena passes none, so its bulls skip the lane telegraph plumbing).
-- parentFolder tags where clients should PARENT their local model (defaults to
-- the main arena's ActiveBulls) — it also marks the charge as outside round
-- cleanup's cancelAll. This is the origin-agnostic core; BullService.charge
-- below maps a main-arena lane onto it.
-- style.bullId: a BullCatalog id (revenge throws + Main's special wave bulls)
-- — picks the client-rendered model. style.mutation: the bull's worn mutation
-- id — clients clone its aura emitters onto the Body. style.throwerName rides
-- the payload so the thrower's own client can boost their bull's glow.
-- style.special: the rarity key of a special wave bull — clients swap the red
-- revenge treatment for a rarity-colored glow + the bull's name tag.
function BullService.chargeAlong(startPos: Vector3, endPos: Vector3, crossCoord: number, axis: string, speed: number, getAlivePlayers, onKill, style: { throwerName: string?, bullId: string?, mutation: string?, special: string? }?, onCharge, onCleared, parentFolder): number
	local duration = (endPos - startPos).Magnitude / speed

	nextChargeId += 1
	local id = nextChargeId
	local state = { cancelled = false, main = parentFolder == nil }
	activeCharges[id] = state

	BullVisual:FireAllClients({
		id = id,
		startPos = startPos,
		endPos = endPos,
		speed = speed,
		launchTime = Workspace:GetServerTimeNow(),
		folder = parentFolder, -- nil -> the main arena's ActiveBulls
		style = style,
	})

	if onCharge then
		onCharge(duration)
	end

	local killed: { [Player]: boolean } = {} -- onKill fires once per player
	local elapsed = 0
	while elapsed < duration do
		local dt = RunService.Heartbeat:Wait()
		if state.cancelled then
			break -- round cleanup (see cancelAll)
		end
		elapsed = math.min(elapsed + dt, duration)

		local position = startPos:Lerp(endPos, elapsed / duration)

		-- Kill check: axis-aligned box around the bull's root position.
		local bullAlong = if axis == "row" then position.X else position.Z
		for _, player in getAlivePlayers() do
			if not killed[player] then
				local character = player.Character
				local root = character and character:FindFirstChild("HumanoidRootPart")
				if root then
					local p = root.Position
					local along = if axis == "row" then p.X else p.Z
					local cross = if axis == "row" then p.Z else p.X
					-- 3D kill box: the height term lets a player JUMP OVER the bull --
					-- a root lifted more than BULL_HIT_HALF_HEIGHT above the charge line
					-- (position.Y) has cleared it (Config.BULL_HIT_HALF_HEIGHT).
					if math.abs(along - bullAlong) < Config.BULL_HIT_HALF_LENGTH
						and math.abs(cross - crossCoord) < Config.BULL_HIT_HALF_WIDTH
						and math.abs(p.Y - position.Y) < Config.BULL_HIT_HALF_HEIGHT
					then
						killed[player] = true
						-- Extra Lives: a player who's currently invulnerable (a revive
						-- forcefield from a heart just spent) eats no hit; one holding
						-- Extra Lives spends a heart to survive. Otherwise it's the
						-- lethal fling + elimination. Only real players (not bot
						-- proxies) carry the ability / i-frames.
						local isRealPlayer = typeof(player) == "Instance"
						local invulnerable = isRealPlayer
							and character:FindFirstChildOfClass("ForceField") ~= nil
						local survived = false
						if not invulnerable and isRealPlayer
							and player:GetAttribute("EquippedAbility") == "ExtraLives" then
							survived = ExtraLivesService.consume(player)
							if survived then
								-- A heart absorbed the hit: still get FLUNG + camera shake
								-- like any bull hit (same launch vector as a kill), but
								-- NON-lethally — they ragdoll and get back up instead of
								-- being eliminated.
								RagdollService.flingSurvivor(character, endPos - startPos,
									speed * LAUNCH_SPEED_SCALE + LAUNCH_SPEED_BASE)
							end
						end
						if not (invulnerable or survived) then
							-- Send them flying before onKill's Health = 0 default-death poof.
							RagdollService.launch(character, endPos - startPos,
								speed * LAUNCH_SPEED_SCALE + LAUNCH_SPEED_BASE)
							onKill(player)
							if state.cancelled then
								-- That kill decided the round (onEliminated ->
								-- cancelAll): spare the rest of this frame's
								-- sweep so the last one standing actually wins.
								break
							end
						end
					end
				end
			end
		end
	end

	activeCharges[id] = nil
	BullVisualEnd:FireAllClients(id)
	if onCleared then
		onCleared()
	end
	return duration
end

-- charge runs a lane across the ACTIVE window of the MAIN arena, mapping it
-- through GridUtil (ARENA_ORIGIN-bound) and firing the ChargeStart / LaneCleared
-- remotes so every client renders the telegraph/clear. Signature unchanged for
-- Main.runWaves and RevengeService.
function BullService.charge(lane, speed: number, bounds, getAlivePlayers, onKill, style: { throwerName: string?, bullId: string?, mutation: string?, special: string? }?): number
	local startPos, endPos = GridUtil.lanePath(lane, bounds)
	local crossCoord = GridUtil.laneCrossCoord(lane)
	return BullService.chargeAlong(
		startPos, endPos, crossCoord, lane.axis, speed, getAlivePlayers, onKill, style,
		function(duration)
			Remotes.ChargeStart:FireAllClients(lane, duration, bounds)
		end,
		function()
			Remotes.LaneCleared:FireAllClients(lane)
		end
	)
end

return BullService
