--[[
	PushService - player-vs-player shove.

	A "Push" ProximityPrompt (created client-side in PushClient) sits over every
	OTHER player while the round is ACTIVE. Tapping it fires Remotes.Push here; we
	validate the request, then tell the VICTIM's client to apply the knockback
	burst - character movement is client-authoritative (same reasoning as
	BullrushDash), so the owning client drives the physics for smooth, lag-free
	motion that replicates to everyone.

	Rules (all server-enforced):
	  * target is a real Player, and not the pusher itself
	  * both pusher and target are alive in the current round - this ALONE gates
	    "only during an active round", since the alive set is empty between rounds
	  * per-pusher cooldown (Config.PUSH.COOLDOWN)
	  * a distance sanity check, so a tampered client can't shove from across the map

	Bots (AIService) never fire remotes, so they can't push — but they CAN be
	pushed (so the shove is testable solo): PushClient sends the bot's rig
	Model, we map it back to its proxy via AIService.findByCharacter, and since
	bot rigs are server-owned (network owner nil) the SERVER applies the same
	knockback burst the victim's client would.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Bullrush.Config)
local Remotes = ReplicatedStorage.Bullrush.Remotes
local AIService = require(script.Parent.AIService)
local RoundService = require(script.Parent.RoundService)
local NotifyService = require(script.Parent.NotifyService)

local PushService = {}

local lastPushAt: { [Player]: number } = {}

-- Works on real Players and bot proxies alike (both expose .Character).
local function rootOf(participant): BasePart?
	local character = participant.Character
	return character and character:FindFirstChild("HumanoidRootPart")
end

-- Server-side mirror of PushClient's knockback burst, for server-owned bot
-- rigs: one burst with an upward pop, then hold the horizontal velocity for
-- PUSH.TIME while gravity takes the vertical back over.
local function shoveBot(proxy, direction: Vector3)
	local character = proxy.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root then
		return
	end

	-- Pause the wander brain and cancel the current MoveTo so the humanoid
	-- doesn't fight the burst.
	proxy.busyUntil = math.max(proxy.busyUntil or 0, os.clock() + Config.PUSH.TIME + 0.3)
	humanoid:MoveTo(root.Position)

	root.AssemblyLinearVelocity = Vector3.new(
		direction.X * Config.PUSH.SPEED,
		Config.PUSH.UP,
		direction.Z * Config.PUSH.SPEED
	)
	local startedAt = os.clock()
	local connection
	connection = RunService.Heartbeat:Connect(function()
		if not root.Parent or humanoid.Health <= 0 or os.clock() - startedAt >= Config.PUSH.TIME then
			connection:Disconnect()
			return
		end
		root.AssemblyLinearVelocity = Vector3.new(
			direction.X * Config.PUSH.SPEED,
			root.AssemblyLinearVelocity.Y,
			direction.Z * Config.PUSH.SPEED
		)
	end)
end

function PushService.init()
	Remotes.Push.OnServerEvent:Connect(function(pusher: Player, target)
		-- Resolve the target: a real Player, or a bot rig Model (PushClient
		-- sends the Model since bot proxies never replicate).
		local victim: any = nil
		if typeof(target) == "Instance" then
			if target:IsA("Player") and target ~= pusher then
				victim = target
			elseif target:IsA("Model") then
				victim = AIService.findByCharacter(target)
			end
		end
		if not victim then
			return
		end

		-- Both in play => a round is ACTIVE and neither has been eliminated.
		if not RoundService.isAlive(pusher) or not RoundService.isAlive(victim) then
			return
		end

		-- Per-pusher cooldown.
		local now = os.clock()
		local last = lastPushAt[pusher]
		if last and now - last < Config.PUSH.COOLDOWN then
			return
		end

		local pusherRoot = rootOf(pusher)
		local targetRoot = rootOf(victim)
		if not pusherRoot or not targetRoot then
			return
		end

		-- Horizontal direction pusher -> target. Reject shoves from further than
		-- the prompt could legitimately have been triggered from.
		local offset = targetRoot.Position - pusherRoot.Position
		local flat = Vector3.new(offset.X, 0, offset.Z)
		if flat.Magnitude > Config.PUSH.RANGE + 6 then
			return
		end
		-- Roots stacked exactly: fall back to the pusher's facing.
		if flat.Magnitude < 0.1 then
			local look = pusherRoot.CFrame.LookVector
			flat = Vector3.new(look.X, 0, look.Z)
		end
		if flat.Magnitude < 0.01 then
			return
		end

		lastPushAt[pusher] = now

		if typeof(victim) == "Instance" then
			-- Real player: they own their character, so their client applies
			-- the burst.
			Remotes.Pushed:FireClient(victim, flat.Unit)
			NotifyService.send(pusher, "You shoved " .. victim.DisplayName .. "!", "green", 2)
			NotifyService.send(victim, pusher.DisplayName .. " shoved you!", "red", 2)
		else
			-- Bot: server-owned rig, server drives the knockback.
			shoveBot(victim, flat.Unit)
			NotifyService.send(pusher, "You shoved " .. victim.Name .. "!", "green", 2)
		end
	end)

	-- Don't leak cooldown entries for players who leave.
	Players.PlayerRemoving:Connect(function(player)
		lastPushAt[player] = nil
	end)
end

return PushService
