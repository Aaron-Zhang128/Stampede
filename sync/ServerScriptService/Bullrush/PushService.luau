--[[
	PushService - player-vs-player shove.

	A "Push" ProximityPrompt (created client-side in PushClient) sits over every
	OTHER player while the round is ACTIVE. Tapping it fires Remotes.Push here; we
	validate the request, then tell the VICTIM's client to apply the knockback
	burst - character movement is client-authoritative (same reasoning as
	BullrushDash), so the owning client drives the physics for smooth, lag-free
	motion that replicates to everyone.

	Rules (all server-enforced):
	  * the pusher is alive in the current round - this ALONE gates "only during
	    an active round", since the alive set is empty between rounds - and past
	    the per-pusher cooldown (Config.PUSH.COOLDOWN); failing either returns
	    silently, since the client gates the same things and only a stale or
	    forged request trips them
	  * the swing LANDS when the target resolves (a real Player that isn't the
	    pusher, or a bot rig Model), the victim is alive, both roots exist, and
	    a distance sanity check passes - so a tampered client can't shove from
	    across the map
	  * a swing that connects with nothing is a MISS: it spends the cooldown all
	    the same and is answered with a red "You missed!" card, matching the
	    client's optimistic swing + local cooldown

	Bots (AIService) never fire remotes, so they can't push — but they CAN be
	pushed (so the shove is testable solo): PushClient sends the bot's rig
	Model, we map it back to its proxy via AIService.findByCharacter, and since
	bot rigs are server-owned (network owner nil) the SERVER applies the same
	knockback burst the victim's client would.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Bullrush.Config)
local Remotes = ReplicatedStorage.Bullrush.Remotes
local AIService = require(script.Parent.AIService)
local RoundService = require(script.Parent.RoundService)
local NotifyService = require(script.Parent.NotifyService)
local EconomyService = require(script.Parent.EconomyService)

local PushService = {}

local lastPushAt: { [Player]: number } = {}

-- Works on real Players and bot proxies alike (both expose .Character).
local function rootOf(participant): BasePart?
	local character = participant.Character
	return character and character:FindFirstChild("HumanoidRootPart")
end

-- The shared "thud" a landed shove makes: a 3D impact sound on the victim's
-- root. Built server-side (cloned from the curated GameSFX library) so it
-- replicates to EVERY client — pusher, victim, and bystanders all hear it, and
-- bot shoves, which never round-trip to a victim client, still get audio.
-- Degrades to silence if the library sound is missing.
local IMPACT_SOUND = "punch7" -- lives in SoundService.GameSFX

local function playImpactSound(root: BasePart, soundName: string?)
	local group = SoundService:FindFirstChild("GameSFX")
	local template = group and group:FindFirstChild(soundName or IMPACT_SOUND)
	if not (template and template:IsA("Sound")) then
		return
	end
	local ok, sound = pcall(function()
		return template:Clone()
	end)
	if not ok or not sound then
		return
	end
	sound.Looped = false
	sound.RollOffMaxDistance = 90
	sound.Volume = math.min(sound.Volume + 0.2, 1)
	sound.Parent = root
	pcall(function()
		sound:Play()
	end)
	Debris:AddItem(sound, 4)
end

-- The VISUAL half of a landed shove, authored server-side alongside the sound so
-- it, too, reads from every vantage (pusher, victim, bystanders) and fires for
-- bot shoves that never reach a victim client. Two beats, both intuitive "I got
-- hit" signals on the person who got pushed:
--   1. a white->orange hit-flash Highlight over the victim's whole body, which
--      snaps on and fades out in a quarter second, and
--   2. the curated "Push" impact display (ReplicatedStorage.Mutations.Push): its
--      Attachment of particle emitters, cloned onto the victim's root and burst
--      once for the "poof" of the shove connecting.
-- Everything is a runtime instance parented onto the victim and Debris-reaped, so
-- there is nothing to clean up by hand and a missing template just degrades.
local PUSH_DISPLAY = ReplicatedStorage.Mutations:FindFirstChild("Push")

-- Clone the Push display's Attachment onto the victim's root and fire every
-- emitter as a one-shot burst (Rate zeroed so nothing lingers as a stream), then
-- Debris-reap once the longest-lived particle has died.
local function playPushDisplay(root: BasePart)
	local template = PUSH_DISPLAY and PUSH_DISPLAY:FindFirstChild("Attachment")
	if not template then
		return
	end
	pcall(function()
		local attachment = template:Clone()
		attachment.Name = "PushDisplay"
		attachment.Parent = root

		local longest = 0
		for _, emitter in attachment:GetChildren() do
			if emitter:IsA("ParticleEmitter") then
				if emitter.Lifetime.Max > longest then
					longest = emitter.Lifetime.Max
				end
				emitter.Rate = 0 -- burst only, not a lingering aura stream
				emitter.LockedToPart = true -- ride the victim as they're knocked back, not stay put
				emitter:Emit(24)
			end
		end
		Debris:AddItem(attachment, longest + 0.5)
	end)
end

local function playImpactVfx(root: BasePart)
	local character = root.Parent
	if not character then
		return
	end

	-- 1. Hit-flash on the body: a Highlight that fades from bright to gone.
	local ok, flash = pcall(function()
		local h = Instance.new("Highlight")
		h.Name = "PushHitFlash"
		h.FillColor = Color3.fromRGB(255, 235, 190)
		h.OutlineColor = Color3.fromRGB(255, 150, 60)
		h.FillTransparency = 0.35
		h.OutlineTransparency = 0
		h.DepthMode = Enum.HighlightDepthMode.Occluded
		h.Adornee = character
		h.Parent = character
		return h
	end)
	if ok and flash then
		pcall(function()
			local info = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			TweenService:Create(flash, info, { FillTransparency = 1, OutlineTransparency = 1 }):Play()
		end)
		Debris:AddItem(flash, 0.4)
	end

	-- 2. The curated Push impact display, burst on the victim's root.
	playPushDisplay(root)
end

-- Sound + visuals together: the full impact a landed shove makes on the victim.
local function playImpactFx(root: BasePart?, soundName: string?)
	if not root then
		return
	end
	playImpactSound(root, soundName)
	playImpactVfx(root)
end

-- Server-side mirror of PushClient's knockback burst, for server-owned bot
-- rigs: a hard spike at contact easing to a stop over PUSH.TIME, with the
-- same floaty vertical pop. Driven through an unlimited-force LinearVelocity
-- constraint (see PushClient for the full why): the solver enforces it every
-- substep, so the humanoid can't eat any of the burst and the arc no longer
-- varies with frame time — bot shoves match player shoves exactly.
local KNOCKBACK_NAME = "PushKnockback" -- same name PushClient uses on players

local function shoveBot(proxy, direction: Vector3, knockbackMult: number?)
	local mult = knockbackMult or 1
	local character = proxy.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root then
		return
	end

	-- Pause the wander brain and cancel the current MoveTo so the humanoid
	-- doesn't fight the burst.
	proxy.busyUntil = math.max(proxy.busyUntil or 0, os.clock() + Config.PUSH.HITSTOP + Config.PUSH.TIME + 0.3)
	humanoid:MoveTo(root.Position)
	playImpactFx(root, if mult > 1 then "mega punch" else nil)

	-- Hitstop: freeze at contact, then launch — mirrors PushClient. Makes the
	-- shove read as a hit instead of a floaty glide. Bail if the bot died/despawned
	-- during the freeze.
	if Config.PUSH.HITSTOP > 0 then
		root.AssemblyLinearVelocity = Vector3.zero
		root.Anchored = true
		task.wait(Config.PUSH.HITSTOP)
		if not root.Parent or humanoid.Health <= 0 then
			root.Anchored = false
			return
		end
		root.Anchored = false
	end

	-- A second shove landing mid-burst restarts clean: destroying the stale
	-- constraint ends its update loop too.
	local stale = root:FindFirstChild(KNOCKBACK_NAME)
	if stale then
		stale:Destroy()
	end

	local spike = Vector3.new(
		direction.X * Config.PUSH.SPEED * mult,
		Config.PUSH.UP * mult,
		direction.Z * Config.PUSH.SPEED * mult
	)
	root.AssemblyLinearVelocity = spike -- cover the substeps before the constraint engages

	local attachment = Instance.new("Attachment")
	attachment.Name = KNOCKBACK_NAME
	local velocity = Instance.new("LinearVelocity")
	velocity.Name = KNOCKBACK_NAME
	velocity.Attachment0 = attachment
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.ForceLimitsEnabled = false
	velocity.MaxForce = math.huge -- either way: nothing gets to fight the arc
	velocity.VectorVelocity = spike
	velocity.Parent = attachment
	attachment.Parent = root

	local startedAt = os.clock()
	local connection
	connection = RunService.Heartbeat:Connect(function(dt: number)
		local t = os.clock() - startedAt
		-- Dead/despawned bot or a newer shove's constraint: stand down. At the
		-- cutoff the last written velocity carries over and gravity takes the
		-- descent.
		if not root.Parent or humanoid.Health <= 0 or attachment.Parent ~= root or t >= Config.PUSH.TIME then
			connection:Disconnect()
			attachment:Destroy()
			return
		end
		-- Mirror PushClient: ease the horizontal velocity SPEED->0 so the shove
		-- reads as an impact rather than a constant-speed glide, and drive the
		-- vertical pop (+UP toward -UP over UP_TIME; decel ~= gravity for
		-- deliberate hang time — see Config.PUSH).
		-- Sample half a frame ahead: the constraint holds each value until the
		-- next write, and midpoint sampling keeps the arc frame-rate-proof.
		local ts = math.min(t + dt / 2, Config.PUSH.TIME)
		local falloff = 1 - ts / Config.PUSH.TIME
		falloff = falloff * falloff
		local vy
		if ts < Config.PUSH.UP_TIME then
			vy = Config.PUSH.UP - (2 * Config.PUSH.UP / Config.PUSH.UP_TIME) * ts
		else
			vy = -Config.PUSH.UP - Workspace.Gravity * (ts - Config.PUSH.UP_TIME)
		end
		velocity.VectorVelocity = Vector3.new(
			direction.X * Config.PUSH.SPEED * mult * falloff,
			vy * mult,
			direction.Z * Config.PUSH.SPEED * mult * falloff
		)
	end)
end

-- Push eligibility: alive in the active round, or a player standing on the
-- practice grid (PracticeArena maintains the replicated InPractice attribute).
-- Works on real Players and bot proxies alike; bots only ever qualify via the
-- round's alive set.
local function canPush(participant): boolean
	if RoundService.isAlive(participant) then
		return true
	end
	return typeof(participant) == "Instance"
		and participant:IsA("Player")
		and participant:GetAttribute("InPractice") == true
end

function PushService.init()
	Remotes.Push.OnServerEvent:Connect(function(pusher: Player, target)
		-- PUSHER gates first, and silently: the client checks the same things
		-- before it swings (participating, off its local cooldown), so a
		-- request that fails them is stale or forged and gets no feedback.
		if not canPush(pusher) then
			return
		end
		local equipped = pusher:GetAttribute("EquippedAbility") or "Push"
		if equipped ~= "Push" and equipped ~= "FastPunch" and equipped ~= "MegaPunch" then
			return
		end
		local now = os.clock()
		local last = lastPushAt[pusher]
		-- Fast Punch is the same shove with the cooldown HALVED (Config.FAST_PUNCH.MULT).
		local cooldown = Config.PUSH.COOLDOWN
		if pusher:GetAttribute("EquippedAbility") == "FastPunch" then
			cooldown *= (Config.FAST_PUNCH and Config.FAST_PUNCH.MULT) or 0.5
		elseif equipped == "MegaPunch" then
			cooldown = Config.MEGA_PUNCH.COOLDOWN
		end
		local knockbackMult = if equipped == "MegaPunch" then Config.MEGA_PUNCH.KNOCKBACK_MULT else 1
		if last and now - last < cooldown then
			return
		end

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

		-- Does the swing LAND? It needs a living victim, both roots, and a
		-- planar distance no further than the prompt could legitimately have
		-- been triggered from (so a tampered client can't shove across the map).
		local pusherRoot = rootOf(pusher)
		local targetRoot = if victim and canPush(victim) then rootOf(victim) else nil
		local flat = Vector3.zero
		local lands = false
		if pusherRoot and targetRoot then
			-- Horizontal direction pusher -> target.
			local offset = targetRoot.Position - pusherRoot.Position
			flat = Vector3.new(offset.X, 0, offset.Z)
			lands = flat.Magnitude <= Config.PUSH.RANGE + 6
		end

		if not lands then
			-- MISS: the swing connected with nothing. The client already spent
			-- its local cooldown the moment it swung, so charge ours too (keeps
			-- the two clocks in step) and answer with the red card PushClient
			-- promises on a whiff.
			lastPushAt[pusher] = now
			NotifyService.send(pusher, "You missed!", "red", 2)
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
		-- Credit window: if the victim falls or dies to a bull within
		-- PUSH.KILL_CREDIT seconds, the feed names this pusher AND pays them the
		-- kill (RoundService.eliminate → ABILITY_KILL_REWARD). Landing the shove
		-- itself pays NOTHING now — only causing a death does.
		RoundService.notePush(victim, pusher)

		if typeof(victim) == "Instance" then
			-- Real player: they own their character, so their client applies
			-- the burst.
			Remotes.Pushed:FireClient(victim, flat.Unit, knockbackMult)
			playImpactFx(targetRoot, if equipped == "MegaPunch" then "mega punch" else nil)
			NotifyService.send(pusher, ("You shoved %s!"):format(victim.DisplayName), "green", 2)
			NotifyService.send(victim, pusher.DisplayName .. " shoved you!", "red", 2)
		else
			-- Bot: server-owned rig, server drives the knockback.
			shoveBot(victim, flat.Unit, knockbackMult)
			NotifyService.send(pusher, ("You shoved %s!"):format(victim.Name), "green", 2)
		end
	end)

	-- Don't leak cooldown entries for players who leave.
	Players.PlayerRemoving:Connect(function(player)
		lastPushAt[player] = nil
	end)
end

return PushService
