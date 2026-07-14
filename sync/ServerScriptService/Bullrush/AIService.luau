--[[
	AIService - server-driven dummy players so multiplayer modes can be
	playtested alone. Toggle via Config.AI_PLAYERS.

	Bots are plain tables that duck-type the slice of Player the round
	pipeline touches (.Name / .Character / .Parent).
	RoundService treats anything that is not a real Player instance as a
	bot and skips DataHandler writes; everything else (alive set, kill
	boxes, bounds watcher, team assignment) works on bots unchanged.

	Lifecycle (all driven by Main):
	  prepareForRound() -> fresh rigs; returns proxies to append to participants
	  onTelegraph(...)  -> called next to the Telegraph remote so bots dodge
	  despawnAll()      -> rigs removed when everyone ports back to the lobby
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")

local Config = require(ReplicatedStorage.Bullrush.Config)
local GridUtil = require(ReplicatedStorage.Bullrush.GridUtil)
local ShrinkService = require(script.Parent.ShrinkService)

local WANDER_PAUSE = { 0.7, 1.6 } -- seconds between wander targets
local DEAD_RIG_DESPAWN = 0.6 -- seconds a dead bot corpse lingers before it's cleared

local AIService = {}

local bots: { any } = {}
local rng = Random.new()

local function settings()
	return Config.AI_PLAYERS or {}
end

function AIService.enabled(): boolean
	return settings().ENABLED == true
end

-- How many bots WOULD join a round right now (for mode eligibility counts).
function AIService.botCount(): number
	return if AIService.enabled() then settings().COUNT or 0 else 0
end

local function botsFolder(): Folder
	local parent = Workspace:FindFirstChild("BullrushArena") or Workspace
	local folder = parent:FindFirstChild("Bots")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Bots"
		folder.Parent = parent
	end
	return folder
end

local function aliveHumanoid(proxy): (Humanoid?, BasePart?)
	local character = proxy.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and root then
		return humanoid, root
	end
	return nil, nil
end

-- Random point on the tile so bots don't all stack dead center.
local function tilePoint(row: number, col: number): Vector3
	return GridUtil.tileCenter(row, col)
		+ Vector3.new(rng:NextNumber(-2.5, 2.5), 0, rng:NextNumber(-2.5, 2.5))
end

-- Idle behavior: amble to a random in-bounds tile unless a dodge order
-- (proxy.busyUntil) is in effect.
local function startBrain(proxy)
	task.spawn(function()
		while proxy.Character and proxy.Character.Parent do
			local humanoid = aliveHumanoid(proxy)
			if not humanoid then
				break
			end
			if os.clock() >= (proxy.busyUntil or 0) then
				local bounds = ShrinkService.getBounds()
				humanoid:MoveTo(tilePoint(
					rng:NextInteger(bounds.rowMin, bounds.rowMax),
					rng:NextInteger(bounds.colMin, bounds.colMax)))
			end
			task.wait(rng:NextNumber(WANDER_PAUSE[1], WANDER_PAUSE[2]))
		end
	end)
end

local function buildRig(name: string): Model?
	local ok, rig = pcall(function()
		return Players:CreateHumanoidModelFromDescription(
			Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
	end)
	if not ok or typeof(rig) ~= "Instance" then
		warn("Bullrush: could not build bot rig:", rig)
		return nil
	end
	rig.Name = name
	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.DisplayName = name
		-- Corpses never respawn like players do, so clear the dead rig quickly
		-- instead of leaving it slumped on the arena until the lobby port.
		humanoid.Died:Once(function()
			Debris:AddItem(rig, DEAD_RIG_DESPAWN)
		end)
	end
	local animate = rig:FindFirstChild("Animate") -- LocalScript, dead weight on a server rig
	if animate then
		animate:Destroy()
	end
	return rig
end

function AIService.despawnAll()
	for _, proxy in bots do
		proxy.Parent = nil -- Main's `player.Parent` checks now skip it
		if proxy.Character then
			proxy.Character:Destroy()
			proxy.Character = nil
		end
	end
	table.clear(bots)
end

-- Fresh rigs every round: dead R15s break apart, so reviving is messier
-- than rebuilding. Returns the proxies for Main to append to participants.
function AIService.prepareForRound(): { any }
	AIService.despawnAll()
	if not AIService.enabled() then
		return {}
	end
	local folder = botsFolder()
	for i = 1, settings().COUNT or 5 do
		local rig = buildRig("Bot " .. i)
		if rig then
			-- Rough placement only; Main pivots every participant onto a
			-- spawn tile right after gathering them.
			rig:PivotTo(CFrame.new(Config.ARENA_ORIGIN + Vector3.new((i - 3) * 4, 6, 0)))
			rig.Parent = folder
			for _, part in rig:GetDescendants() do
				if part:IsA("BasePart") then
					pcall(part.SetNetworkOwner, part, nil) -- keep bots server-driven
				end
			end
			local proxy = {
				Name = rig.Name,
				Character = rig,
				Parent = folder,
				isBot = true,
			}
			table.insert(bots, proxy)
			startBrain(proxy)
		end
	end
	return table.clone(bots)
end

-- PushService: clients can only reference a bot by its rig Model, so map the
-- rig back to the proxy the round pipeline knows about.
function AIService.findByCharacter(character: Model)
	for _, proxy in bots do
		if proxy.Character == character then
			return proxy
		end
	end
	return nil
end

-- Team Rush: bots carry no RushTeam attribute, so paint the rig instead.
function AIService.tintTeam(proxy, teamName: string)
	local character = proxy.Character
	if not character then
		return
	end
	local color = if teamName == "RED"
		then Color3.fromRGB(196, 40, 28)
		else Color3.fromRGB(13, 105, 172)
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
			part.Color = color
		end
	end
end

-- Mirror of the Telegraph remote: after a human-ish reaction delay, any bot
-- standing on a telegraphed lane runs for the nearest safe tile.
-- WaveDirector guarantees >=1 safe row AND col, so a safe tile always exists.
function AIService.onTelegraph(lanes, telegraphTime: number, bounds)
	if #bots == 0 then
		return
	end
	local dangerRows: { [number]: boolean } = {}
	local dangerCols: { [number]: boolean } = {}
	for _, lane in lanes do
		if lane.axis == "row" then
			dangerRows[lane.index] = true
		else
			dangerCols[lane.index] = true
		end
	end

	local dodgeChance = settings().DODGE_CHANCE or 0.8
	local reaction = settings().REACTION_TIME or { 0.25, 0.9 }
	for _, proxy in bots do
		if rng:NextNumber() < dodgeChance then
			task.delay(rng:NextNumber(reaction[1], reaction[2]), function()
				local humanoid, root = aliveHumanoid(proxy)
				if not humanoid or not root then
					return
				end
				local row, col = GridUtil.worldToTile(root.Position)
				local exposed = row == nil
					or dangerRows[row] or dangerCols[col]
					or not GridUtil.inBounds(row, col, bounds)
				if not exposed then
					return -- already standing somewhere safe
				end
				-- Nearest tile on a safe row AND safe column.
				local fromRow = row or math.floor((bounds.rowMin + bounds.rowMax) / 2)
				local fromCol = col or math.floor((bounds.colMin + bounds.colMax) / 2)
				local bestRow, bestCol, bestDist
				for r = bounds.rowMin, bounds.rowMax do
					if not dangerRows[r] then
						for c = bounds.colMin, bounds.colMax do
							if not dangerCols[c] then
								local dist = math.abs(r - fromRow) + math.abs(c - fromCol)
								if not bestDist or dist < bestDist then
									bestRow, bestCol, bestDist = r, c, dist
								end
							end
						end
					end
				end
				if bestRow then
					proxy.busyUntil = os.clock() + telegraphTime + 0.5
					humanoid:MoveTo(tilePoint(bestRow, bestCol))
				end
			end)
		end
	end
end

return AIService