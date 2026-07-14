--[[
	RevengeService - ROUND SPECTATORS (eliminated participants + anyone
	watching from outside the round: late/first joiners, AFK sitters) send one
	bull down a lane of the CURRENT window from the overhead bull-cam
	(BullrushClient owns the camera and the arrow-key lane selection;
	StarterGui.Main owns the ◀ SEND BULL ▶ buttons), on a per-player cooldown,
	and earn Money for every alive player their bull tramples.

	Throws arrive on the RevengeThrow RemoteEvent as a lane table
	{ axis, index, direction }. The remote is trivially spoofable, so
	requestThrow re-validates EVERYTHING server-side: round window open,
	lane shape, caller is not ALIVE in the current round,
	cooldown lapsed, lane still inside the (possibly shrunken) bounds.

	Client contract (see GridUtil header):
	- RevengeThrow:FireServer(lane) - the only client->server remote.
	- RevengeAck:FireClient(thrower, kind, data) answers the thrower only:
	  "THROW_OK" { cooldown, lane, bullId }, "HIT" { victimName, amount },
	  "DENIED" { reason }. The client drives its SEND BULL cooldown readout
	  from THROW_OK timing.

	The bull sent is the thrower's EQUIPPED bull from the roll system
	(BullRollService.getEquippedBull): its catalog speed replaces the old
	flat Config.REVENGE.SPEED, and its id rides along to BullService for
	the model swap once real bull models exist.

	Main drives roundStarted()/roundEnded(); throws are rejected outside
	that window, and in-flight bulls stop killing once the round is decided.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Bullrush.Config)
local BullCatalog = require(ReplicatedStorage.Bullrush.BullCatalog)
local Remotes = ReplicatedStorage.Bullrush.Remotes

local BullService = require(script.Parent.BullService)
local NotifyService = require(script.Parent.NotifyService)
local RoundService = require(script.Parent.RoundService)
local ShrinkService = require(script.Parent.ShrinkService)
local EconomyService = require(script.Parent.EconomyService)
local BullRollService = require(script.Parent.BullRollService)
local TutorialService = require(script.Parent.TutorialService)

local REQUEST_GAP = 0.3 -- silent spam guard, well inside the real cooldown
local DENIED_ACK_GAP = 4 -- send-mashers on cooldown get one red card per card-lifetime

local RevengeService = {}

local enabled = false
local cooldownUntil: { [Player]: number } = {} -- os.clock() deadline per thrower
local lastRequestAt: { [Player]: number } = {}
local lastDeniedAt: { [Player]: number } = {}

-- The Team Rush payout flip lives here: to stop paying for teammate hits,
-- compare the players' RushTeam attributes (nil outside Team Rush):
-- return thrower:GetAttribute("RushTeam") == nil
--     or thrower:GetAttribute("RushTeam") ~= victim:GetAttribute("RushTeam")
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

-- RevengeThrow is the newest remote; the Remotes folder is built in edit
-- mode, so ensure it here for places that predate the lane-select rework.
local throwRemote = Remotes:FindFirstChild("RevengeThrow")
if not (throwRemote and throwRemote:IsA("RemoteEvent")) then
	throwRemote = Instance.new("RemoteEvent")
	throwRemote.Name = "RevengeThrow"
	throwRemote.Parent = Remotes
end

--==============================================================================
-- Round lifecycle + throw pipeline
--==============================================================================

function RevengeService.roundStarted()
	table.clear(cooldownUntil)
	enabled = true
end

function RevengeService.roundEnded()
	enabled = false
	table.clear(cooldownUntil)
end

-- True between roundStarted() and roundEnded() — the exact window when
-- throws are accepted. The client's bull-cam gates on round state +
-- elimination the same way, so "can see the board" and "can throw" can
-- never disagree.
function RevengeService.isEnabled(): boolean
	return enabled
end

-- Public (not just the remote's target) so smoke tests can call it directly.
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
	-- Any ROUND SPECTATOR may throw (2026-07-13 widening): eliminated
	-- participants plus everyone watching from outside the round — late/first
	-- joiners, AFK sitters. Only players still ALIVE on the grid are barred.
	-- Mirrors the client's isRoundSpectator()-based canThrowRevenge() gate.
	if RoundService.isAlive(thrower) then
		return
	end
	if now < (cooldownUntil[thrower] or 0) then
		-- Mashing SEND BULL on cooldown shouldn't flood the client
		-- (gap ≈ one card lifetime, so at most one red card shows at a time).
		if now - (lastDeniedAt[thrower] or 0) >= DENIED_ACK_GAP then
			lastDeniedAt[thrower] = now
			local remaining = cooldownUntil[thrower] - now
			NotifyService.send(thrower,
				("Bull ready in %ds"):format(math.ceil(remaining)), "red")
			ack(thrower, "DENIED", {
				reason = "COOLDOWN",
				remaining = remaining, -- lets a desynced client resync its cooldown readout
			})
		end
		return
	end
	local bounds = ShrinkService.getBounds()
	local laneMin = if axis == "row" then bounds.rowMin else bounds.colMin
	local laneMax = if axis == "row" then bounds.rowMax else bounds.colMax
	if index < laneMin or index > laneMax then
		-- a shrink can trim the lane between the client's selection and the send
		NotifyService.send(thrower, "That lane is gone!", "red")
		ack(thrower, "DENIED", { reason = "BOUNDS" })
		return
	end

	-- Rebuild the lane clean; never forward tables from outside this module.
	local lane = { axis = axis, index = index, direction = direction }

	-- The equipped bull (roll system) sets the throw's speed; STARTER matches
	-- the old flat Config.REVENGE.SPEED, so unequipped players lose nothing.
	local bull = BullRollService.getEquippedBull(thrower)

	cooldownUntil[thrower] = now + Config.REVENGE.COOLDOWN
	-- The worn mutation leads the name ("Radioactive El Diablo charging...")
	local mutDef = bull.mutation and BullCatalog.getMutation(bull.mutation)
	local throwName = if mutDef then mutDef.name .. " " .. bull.name else bull.name
	NotifyService.send(thrower,
		("%s charging down %s %d!"):format(
			throwName, if axis == "row" then "row" else "column", index), "green")
	ack(thrower, "THROW_OK", { cooldown = Config.REVENGE.COOLDOWN, lane = lane, bullId = bull.id })

	-- Tutorial step 1 (send a bull) completes on any accepted throw.
	TutorialService.onThrow(thrower)

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
				EconomyService.noteRevenge(thrower, paid) -- shows on the Summary tab
				NotifyService.send(thrower,
					("+%d Money — your bull hit %s!"):format(paid, victim.Name), "green")
				ack(thrower, "HIT", {
					victimName = victim.Name,
					amount = paid,
				})
			end
		end
		BullService.charge(lane, bull.speed, bounds, RoundService.getAliveCached, onKill,
			{ throwerName = thrower.Name, bullId = bull.id, mutation = bull.mutation })
	end)
end

throwRemote.OnServerEvent:Connect(function(thrower: Player, laneData: any)
	RevengeService.requestThrow(thrower, laneData)
end)

Players.PlayerRemoving:Connect(function(player)
	cooldownUntil[player] = nil
	lastRequestAt[player] = nil
	lastDeniedAt[player] = nil
end)

return RevengeService
