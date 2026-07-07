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

	Bots (AIService) are plain tables, never fire remotes, and never receive a
	client-made prompt, so they simply don't take part as pushers or targets.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Bullrush.Config)
local Remotes = ReplicatedStorage.Bullrush.Remotes
local RoundService = require(script.Parent.RoundService)
local NotifyService = require(script.Parent.NotifyService)

local PushService = {}

local lastPushAt: { [Player]: number } = {}

local function rootOf(player: Player): BasePart?
	local character = player.Character
	return character and character:FindFirstChild("HumanoidRootPart")
end

function PushService.init()
	Remotes.Push.OnServerEvent:Connect(function(pusher: Player, target)
		-- Only ever act on a real Player target that isn't the pusher.
		if typeof(target) ~= "Instance" or not target:IsA("Player") or target == pusher then
			return
		end

		-- Both in play => a round is ACTIVE and neither has been eliminated.
		if not RoundService.isAlive(pusher) or not RoundService.isAlive(target) then
			return
		end

		-- Per-pusher cooldown.
		local now = os.clock()
		local last = lastPushAt[pusher]
		if last and now - last < Config.PUSH.COOLDOWN then
			return
		end

		local pusherRoot = rootOf(pusher)
		local targetRoot = rootOf(target)
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

		-- The victim owns their character, so their client applies the burst.
		Remotes.Pushed:FireClient(target, flat.Unit)

		NotifyService.send(pusher, "You shoved " .. target.DisplayName .. "!", "green", 2)
		NotifyService.send(target, pusher.DisplayName .. " shoved you!", "red", 2)
	end)

	-- Don't leak cooldown entries for players who leave.
	Players.PlayerRemoving:Connect(function(player)
		lastPushAt[player] = nil
	end)
end

return PushService
