--[[
	LobbyBullDisplays - hover animation for every lobby showpiece bull.

	Any Workspace model tagged "HoverDisplay" (CelestialBull, LuxBull, ...)
	gets a gentle bob + slow spin via Heartbeat PivotTo, each offset in phase
	so the herd doesn't bob in lockstep. The models are anchored and never
	move on the server, so the motion costs zero replication bandwidth (and
	Heartbeat lerps are the house style - TweenService is unreliable in this
	project's Run-mode testing). Showpieces should be ModelStreamingMode
	Persistent so they replicate whole under streaming.

	To add a display: build the anchored model, tag it HoverDisplay - no
	script changes needed. The CelestialBull's buy prompt shows for EVERYONE,
	owners included (its BuyCelestial server guard answers owners with
	"Already yours!" instead of a purchase).
]]

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local TAG = "HoverDisplay"

local BOB_HEIGHT = 1 -- studs above/below the rest height
local BOB_SPEED = 1.5 -- radians/s through the sine
local SPIN_SPEED = 0.5 -- radians/s of lazy yaw
local PHASE_STEP = 2.4 -- radians between displays so each bobs on its own beat

local displays: { [Model]: { base: CFrame, phase: number } } = {}
local nextPhase = 0

local function add(model: Instance)
	if not (model:IsA("Model") and not displays[model]) then
		return
	end
	displays[model] = { base = model:GetPivot(), phase = nextPhase }
	nextPhase += PHASE_STEP
end

for _, model in CollectionService:GetTagged(TAG) do
	add(model)
end
CollectionService:GetInstanceAddedSignal(TAG):Connect(add)
CollectionService:GetInstanceRemovedSignal(TAG):Connect(function(model)
	displays[model] = nil
end)

RunService.Heartbeat:Connect(function()
	local t = os.clock()
	for model, d in displays do
		model:PivotTo(d.base
			* CFrame.new(0, BOB_HEIGHT * math.sin(t * BOB_SPEED + d.phase), 0)
			* CFrame.Angles(0, t * SPIN_SPEED + d.phase, 0))
	end
end)
