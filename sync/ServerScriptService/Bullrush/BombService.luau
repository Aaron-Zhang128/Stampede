--[[
	BombService — throwable bomb ability (server-authoritative).

	An ALIVE participant throws a lobbed bomb (BombThrow remote, carrying their aim
	direction); the server spawns the bomb, arcs it, and on its FUSE detonates —
	everyone within BOMB.RADIUS is knocked outward from the blast. Real players get
	the burst applied on their OWN client (Remotes.Bombed -> BombClient; movement
	is client-authoritative, same idiom as Push), while server-owned bots are
	shoved by the server here.

	All rules are server-enforced (the remote is spoofable): the thrower must be
	alive in the round (or on the practice grid) and off their per-player cooldown.
	The aim is only ever a direction (you can't lob anywhere but where you look),
	so there's nothing to clamp.

	WIRING (left to you): BombClient already fires BombThrow on its key / HUD
	button and applies the Bombed burst, so nothing else is required to make it
	work. Kill credit / payouts aren't wired — call into RoundService from the
	hit loop in detonate() if you want them.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage.Bullrush.Config)
local Remotes = ReplicatedStorage.Bullrush.Remotes
local AIService = require(script.Parent.AIService)
local RoundService = require(script.Parent.RoundService)
local NotifyService = require(script.Parent.NotifyService)
local RagdollUtil = require(ReplicatedStorage.Bullrush.RagdollUtil)

local BombService = {}

local CFG = Config.BOMB
local KNOCKBACK_NAME = "BombKnockback"
local lastThrowAt: { [Player]: number } = {}

-- Ensure-on-require, same as the other services: the Remotes folder is built in
-- edit mode, so make ours here for places that predate this ability.
local function ensureRemote(name: string): RemoteEvent
	local remote = Remotes:FindFirstChild(name)
	if not (remote and remote:IsA("RemoteEvent")) then
		remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = Remotes
	end
	return remote
end
local throwRemote = ensureRemote("BombThrow") -- client -> server: { aimDir }
local bombedRemote = ensureRemote("Bombed") -- server -> victim client: outward direction
local dropRemote = ensureRemote("DropMine") -- client -> server: drop a mine at my feet
local minedRemote = ensureRemote("Mined") -- server -> victim client: non-lethal ragdoll impulse

local MINE = Config.MINE
local lastMineAt: { [Player]: number } = {}

-- Works on real Players and bot proxies alike (both expose .Character).
local function rootOf(participant): BasePart?
	local character = participant.Character
	return character and character:FindFirstChild("HumanoidRootPart")
end

-- Same eligibility as Push: alive in the active round, or on the practice grid.
local function canUse(participant): boolean
	if RoundService.isAlive(participant) then
		return true
	end
	return typeof(participant) == "Instance"
		and participant:IsA("Player")
		and participant:GetAttribute("InPractice") == true
end

local function getBotsFolder(): Instance?
	local arena = Workspace:FindFirstChild("BullrushArena")
	return arena and arena:FindFirstChild("Bots")
end

-- Server-driven knockback burst for a server-owned bot rig, mirroring
-- BombClient's arc: a hard spike at the blast easing to a stop over TIME with the
-- same floaty vertical pop. Driven through an unlimited-force LinearVelocity
-- constraint (see PushService for the full why). `dir` is the flat outward unit.
local function shoveBot(proxy, dir: Vector3)
	local character = proxy.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root then
		return
	end

	proxy.busyUntil = math.max(proxy.busyUntil or 0, os.clock() + CFG.TIME + 0.3)
	humanoid:MoveTo(root.Position)

	local stale = root:FindFirstChild(KNOCKBACK_NAME)
	if stale then
		stale:Destroy()
	end

	local spike = Vector3.new(dir.X * CFG.SPEED, CFG.UP, dir.Z * CFG.SPEED)
	root.AssemblyLinearVelocity = spike

	local attachment = Instance.new("Attachment")
	attachment.Name = KNOCKBACK_NAME
	local velocity = Instance.new("LinearVelocity")
	velocity.Name = KNOCKBACK_NAME
	velocity.Attachment0 = attachment
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.ForceLimitsEnabled = false
	velocity.MaxForce = math.huge
	velocity.VectorVelocity = spike
	velocity.Parent = attachment
	attachment.Parent = root

	local startedAt = os.clock()
	local connection
	connection = RunService.Heartbeat:Connect(function(dt: number)
		local t = os.clock() - startedAt
		if not root.Parent or humanoid.Health <= 0 or attachment.Parent ~= root or t >= CFG.TIME then
			connection:Disconnect()
			attachment:Destroy()
			return
		end
		local ts = math.min(t + dt / 2, CFG.TIME)
		local falloff = 1 - ts / CFG.TIME
		falloff = falloff * falloff
		local vy
		if ts < CFG.UP_TIME then
			vy = CFG.UP - (2 * CFG.UP / CFG.UP_TIME) * ts
		else
			vy = -CFG.UP - Workspace.Gravity * (ts - CFG.UP_TIME)
		end
		velocity.VectorVelocity = Vector3.new(dir.X * CFG.SPEED * falloff, vy, dir.Z * CFG.SPEED * falloff)
	end)
end

-- Positional one-shot from the curated GameSFX library, dropped at a world point
-- via a throwaway speaker part so every nearby client hears the blast in 3D
-- (server-built, same idiom as PushService). Silent if the sound is missing.
local function playSfxAtPos(name: string, pos: Vector3)
	local group = SoundService:FindFirstChild("GameSFX")
	local template = group and group:FindFirstChild(name)
	if not (template and template:IsA("Sound")) then
		return
	end
	local speaker = Instance.new("Part")
	speaker.Anchored = true
	speaker.CanCollide = false
	speaker.CanQuery = false
	speaker.CanTouch = false
	speaker.Transparency = 1
	speaker.Size = Vector3.one
	speaker.CFrame = CFrame.new(pos)
	speaker.Parent = Workspace
	local ok, sound = pcall(function()
		return template:Clone()
	end)
	if ok and sound then
		sound.Looped = false
		sound.RollOffMaxDistance = 120
		sound.Parent = speaker
		pcall(function()
			sound:Play()
		end)
	end
	Debris:AddItem(speaker, 6)
end

-- A punchy one-shot explosion ANIMATION at the blast point: a bright flash core
-- that swells and fades, an expanding shockwave shell, a light flash, and a burst
-- of fire + smoke. Purely cosmetic (server-built so everyone sees it) — the real
-- knockback is driven separately. Everything is Anchored / CanCollide false and
-- self-cleans via Debris, so it never touches physics or lingers.
local function spawnBlastVfx(position: Vector3, radius: number?)
	local R = radius or CFG.RADIUS

	-- Flash core — a neon ball that pops from tiny to ~blast size and fades out.
	local flash = Instance.new("Part")
	flash.Shape = Enum.PartType.Ball
	flash.Material = Enum.Material.Neon
	flash.Color = Color3.fromRGB(255, 226, 150)
	flash.Anchored = true
	flash.CanCollide = false
	flash.CanQuery = false
	flash.CanTouch = false
	flash.CastShadow = false
	flash.Size = Vector3.new(3, 3, 3)
	flash.CFrame = CFrame.new(position)
	flash.Transparency = 0.1
	flash.Parent = Workspace
	TweenService:Create(flash, TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(R * 1.3, R * 1.3, R * 1.3),
		Transparency = 1,
	}):Play()
	Debris:AddItem(flash, 0.4)

	-- A light flash rides the core.
	local flashLight = Instance.new("PointLight")
	flashLight.Color = Color3.fromRGB(255, 190, 120)
	flashLight.Range = R * 1.6
	flashLight.Brightness = 6
	flashLight.Parent = flash
	TweenService:Create(flashLight, TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Brightness = 0,
	}):Play()

	-- Shockwave shell — a hot expanding sphere that outruns the flash.
	local shock = Instance.new("Part")
	shock.Shape = Enum.PartType.Ball
	shock.Material = Enum.Material.Neon
	shock.Color = Color3.fromRGB(255, 170, 70)
	shock.Anchored = true
	shock.CanCollide = false
	shock.CanQuery = false
	shock.CanTouch = false
	shock.CastShadow = false
	shock.Size = Vector3.new(4, 4, 4)
	shock.CFrame = CFrame.new(position)
	shock.Transparency = 0.5
	shock.Parent = Workspace
	TweenService:Create(shock, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(R * 2.2, R * 2.2, R * 2.2),
		Transparency = 1,
	}):Play()
	Debris:AddItem(shock, 0.45)

	-- Fire + smoke burst — a tiny anchored emitter that fires once and dies.
	local emitter = Instance.new("Part")
	emitter.Transparency = 1
	emitter.Size = Vector3.new(1, 1, 1)
	emitter.Anchored = true
	emitter.CanCollide = false
	emitter.CanQuery = false
	emitter.CanTouch = false
	emitter.CFrame = CFrame.new(position)
	emitter.Parent = Workspace

	local fire = Instance.new("ParticleEmitter")
	fire.Texture = "rbxasset://textures/particles/fire_main.dds"
	fire.Color = ColorSequence.new(Color3.fromRGB(255, 200, 90), Color3.fromRGB(255, 90, 40))
	fire.LightEmission = 0.7
	fire.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, R * 0.35),
		NumberSequenceKeypoint.new(1, R * 0.9),
	})
	fire.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	fire.Lifetime = NumberRange.new(0.3, 0.55)
	fire.Speed = NumberRange.new(R * 0.6, R * 1.1)
	fire.SpreadAngle = Vector2.new(180, 180)
	fire.Rotation = NumberRange.new(0, 360)
	fire.Enabled = false
	fire.Parent = emitter

	local smoke = Instance.new("ParticleEmitter")
	smoke.Texture = "rbxasset://textures/particles/smoke_main.dds"
	smoke.Color = ColorSequence.new(Color3.fromRGB(60, 55, 50))
	smoke.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, R * 0.5),
		NumberSequenceKeypoint.new(1, R * 1.3),
	})
	smoke.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(0.6, 0.7),
		NumberSequenceKeypoint.new(1, 1),
	})
	smoke.Lifetime = NumberRange.new(0.5, 0.9)
	smoke.Speed = NumberRange.new(R * 0.3, R * 0.6)
	smoke.SpreadAngle = Vector2.new(180, 180)
	smoke.Rotation = NumberRange.new(0, 360)
	smoke.Enabled = false
	smoke.Parent = emitter

	fire:Emit(46)
	smoke:Emit(26)
	Debris:AddItem(emitter, 1.2)
end

-- Detonate at `position`: a boom for show, then knock every LIVING participant
-- within RADIUS outward. The thrower is spared their own blast.
local function detonate(thrower: Player, position: Vector3)
	-- Custom explosion ANIMATION (flash + shockwave + fire/smoke) IS the whole
	-- visual. We deliberately DON'T spawn a Roblox Explosion: it dismembers
	-- characters and DestroyJointsRadiusPercent (the property that would stop that)
	-- isn't settable in this engine build — setting it threw and aborted the blast
	-- before the knockback ever ran. We drive the knockback ourselves anyway.
	spawnBlastVfx(position)
	playSfxAtPos("Mine explosion", position)

	local function tryHit(participant, isBot: boolean)
		if participant == thrower then
			return -- don't launch yourself with your own bomb
		end
		if not canUse(participant) then
			return -- only living participants get flung
		end
		local root = rootOf(participant)
		if not root then
			return
		end
		local offset = root.Position - position
		if offset.Magnitude > CFG.RADIUS then
			return
		end
		local flat = Vector3.new(offset.X, 0, offset.Z)
		local dir = if flat.Magnitude > 0.1 then flat.Unit else Vector3.new(0, 0, 1)
		if isBot then
			shoveBot(participant, dir)
		else
			-- Real player: they own their character, so their client applies it.
			bombedRemote:FireClient(participant, dir)
			-- Credit the KILL: if the blast leads to their elimination, the thrower
			-- earns it (ABILITY_KILL_REWARD in RoundService.eliminate).
			RoundService.notePush(participant, thrower)
			-- Tell the victim who bombed them (mirror of Push's "X shoved you!").
			NotifyService.send(participant, thrower.DisplayName .. " bombed YOU!", "red", 2)
		end
	end

	for _, other in Players:GetPlayers() do
		tryHit(other, false)
	end
	local folder = getBotsFolder()
	if folder then
		for _, rig in folder:GetChildren() do
			if rig:IsA("Model") then
				local proxy = AIService.findByCharacter(rig)
				if proxy then
					tryHit(proxy, true)
				end
			end
		end
	end
end

-- The bomb doesn't go anywhere: it pops up right in front of the thrower's FACE,
-- bobs UP then DOWN (a quick anchored toss ANIMATION), and EXPLODES MIDAIR right
-- there — then VANISHES. Nothing fancy. `dir` is ignored (it's self-centered now).
local function throwBomb(thrower: Player, dir: Vector3)
	local character = thrower.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	local head = character:FindFirstChild("Head")

	-- Right in front of the face.
	local facePos = (head and head.Position) or (root.Position + Vector3.new(0, 1.5, 0))
	local look = root.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	flat = if flat.Magnitude > 0.01 then flat.Unit else Vector3.new(0, 0, -1)
	local startPos = facePos + flat * 2.5

	local bomb = Instance.new("Part")
	bomb.Name = "Bomb"
	bomb.Shape = Enum.PartType.Ball
	bomb.Size = Vector3.new(1.6, 1.6, 1.6)
	bomb.Color = Color3.fromRGB(28, 28, 28)
	bomb.Material = Enum.Material.Metal
	bomb.Anchored = true -- driven by the tween, not physics
	bomb.CanCollide = false
	bomb.CanTouch = false
	bomb.CFrame = CFrame.new(startPos)
	bomb.Parent = Workspace
	Debris:AddItem(bomb, 3) -- safety net; it's destroyed on the blast anyway

	-- A hot fuse glow so it reads.
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 120, 40)
	light.Range = 9
	light.Brightness = 2.5
	light.Parent = bomb

	local detonated = false
	local function detonateOnce()
		if detonated then
			return
		end
		detonated = true
		detonate(thrower, (bomb.Parent and bomb.Position) or startPos)
		bomb:Destroy() -- DISAPPEARS the instant it blows
	end

	-- The ANIM: pop UP ~3 studs, then fall back DOWN to face level, then EXPLODE
	-- midair right there. Anchored + tweened, no physics.
	local topPos = startPos + Vector3.new(0, 3, 0)
	local up = TweenService:Create(bomb,
		TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Position = topPos })
	up.Completed:Connect(function()
		if not bomb.Parent then
			return
		end
		local down = TweenService:Create(bomb,
			TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Position = startPos })
		down.Completed:Connect(detonateOnce)
		down:Play()
	end)
	up:Play()

	-- Backstop so it can never linger if a tween is interrupted (idempotent).
	task.delay(1.2, detonateOnce)
end

-- Public (not just the remote's target) so tests can drive it directly.
function BombService.requestThrow(thrower: Player, aim)
	-- Only the THROW is ability-gated; canUse (reused below to pick blast victims)
	-- must stay ability-agnostic so everyone nearby still gets flung.
	if thrower:GetAttribute("EquippedAbility") ~= "Bomb" then
		return
	end
	if not canUse(thrower) then
		return
	end
	local now = os.clock()
	local last = lastThrowAt[thrower]
	if last and now - last < CFG.COOLDOWN then
		return
	end

	-- Sanitize the aim into a unit direction; fall back to the thrower's facing.
	local dir: Vector3
	if typeof(aim) == "Vector3" and aim.Magnitude > 0.01 then
		dir = aim.Unit
	else
		local root = rootOf(thrower)
		dir = if root then root.CFrame.LookVector else Vector3.new(0, 0, 1)
	end

	lastThrowAt[thrower] = now
	throwBomb(thrower, dir)
	NotifyService.send(thrower, "Bomb away!", "green", 1.5)
end

--==============================================================================
-- MINE (folded in): drop a stationary trap that EXPLODES + NON-lethally ragdolls
-- everyone within RADIUS when a living player steps on it. Victims stay ALIVE and
-- get back up (RagdollUtil — client-owned for players, server-driven for bots).
--==============================================================================

-- Knock one mine victim down: real players ragdoll on their OWN client (ownership
-- holds), bots are ragdolled here. `impulse` is the outward+up launch written to
-- the root as it goes down.
local function ragdollMineVictim(participant, impulse: Vector3, isBot: boolean)
	if isBot then
		local character = participant.Character
		if character then
			RagdollUtil.ragdoll(character, impulse)
			participant.busyUntil = math.max(participant.busyUntil or 0, os.clock() + MINE.RAGDOLL_TIME + 0.5)
			task.delay(MINE.RAGDOLL_TIME, function()
				RagdollUtil.recover(character)
			end)
		end
	elseif typeof(participant) == "Instance" then
		minedRemote:FireClient(participant, impulse)
	end
end

-- A mine went off at `position`: a boom for show, then ragdoll every LIVING
-- participant within RADIUS (the owner is spared) outward + up. Non-lethal.
local function detonateMine(owner: Player, position: Vector3)
	-- Custom explosion VFX at the mine's own radius (no Roblox Explosion — it
	-- dismembers, and DestroyJointsRadiusPercent isn't settable here). We drive the
	-- ragdoll ourselves.
	spawnBlastVfx(position, MINE.RADIUS)
	playSfxAtPos("Mine", position)

	local function tryHit(participant, isBot: boolean)
		if participant == owner or not canUse(participant) then
			return
		end
		local root = rootOf(participant)
		if not root then
			return
		end
		local offset = root.Position - position
		if offset.Magnitude > MINE.RADIUS then
			return
		end
		local flat = Vector3.new(offset.X, 0, offset.Z)
		local dir = if flat.Magnitude > 0.1 then flat.Unit else Vector3.new(0, 0, 1)
		local impulse = Vector3.new(dir.X * MINE.KNOCK, MINE.UP, dir.Z * MINE.KNOCK)
		ragdollMineVictim(participant, impulse, isBot)
		if not isBot then
			RoundService.notePush(participant, owner) -- credit the kill if this leads to a death
			-- Tell the victim who blew them up (mirror of Push's "X shoved you!").
			NotifyService.send(participant, owner.DisplayName .. " bombed YOU!", "red", 2)
		end
	end

	for _, other in Players:GetPlayers() do
		tryHit(other, false)
	end
	local folder = getBotsFolder()
	if folder then
		for _, rig in folder:GetChildren() do
			if rig:IsA("Model") then
				local proxy = AIService.findByCharacter(rig)
				if proxy then
					tryHit(proxy, true)
				end
			end
		end
	end
end

-- Spawn the mine at the owner's feet: a low disc with a blinking red light. Arms
-- after ARM_DELAY; the first LIVING non-owner participant to touch it sets it off.
-- Fizzles (via Debris) after LIFETIME if nobody steps on it.
local function dropMine(owner: Player)
	local root = rootOf(owner)
	if not root then
		return
	end
	local look = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
	local pos = root.Position - look * 2 - Vector3.new(0, 1.2, 0)

	local mine = Instance.new("Part")
	mine.Name = "Mine"
	mine.Shape = Enum.PartType.Cylinder
	mine.Size = Vector3.new(0.5, 3, 3)
	mine.CFrame = CFrame.new(pos) * CFrame.Angles(0, 0, math.rad(90)) -- lie flat as a disc
	mine.Color = Color3.fromRGB(35, 32, 30)
	mine.Material = Enum.Material.Metal
	mine.Anchored = false
	mine.CanCollide = true
	mine.CanTouch = true
	mine.Parent = Workspace
	pcall(function() mine:SetNetworkOwner(nil) end) -- deterministic server-owned fall
	Debris:AddItem(mine, MINE.LIFETIME + 0.5)

	-- Red detonator tip poking up from the disc's center so it clearly reads as a
	-- MINE. Child of the mine, so it vanishes with it (Destroy / Debris take it too).
	local tip = Instance.new("Part")
	tip.Name = "Tip"
	tip.Shape = Enum.PartType.Ball
	tip.Size = Vector3.new(1, 1, 1)
	tip.Color = Color3.fromRGB(210, 35, 35)
	tip.Material = Enum.Material.Neon
	tip.Anchored = false
	tip.CanCollide = false
	tip.CanTouch = false
	tip.CanQuery = false
	tip.CFrame = CFrame.new(pos + Vector3.new(0, 0.35, 0))
	tip.Parent = mine
	local tipWeld = Instance.new("WeldConstraint")
	tipWeld.Part0 = mine
	tipWeld.Part1 = tip
	tipWeld.Parent = tip

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 45, 45)
	light.Range = 8
	light.Brightness = 2
	light.Parent = mine
	task.spawn(function()
		while mine.Parent do
			light.Enabled = not light.Enabled
			task.wait(0.4)
		end
	end)

	local triggered = false
	local landed = false
	local armAt = os.clock() + MINE.ARM_DELAY
	mine.Touched:Connect(function(hit: BasePart)
		if triggered then
			return
		end
		local model = hit:FindFirstAncestorWhichIsA("Model")
		local hitParticipant = model and (Players:GetPlayerFromCharacter(model) or AIService.findByCharacter(model))
		if not landed and hitParticipant ~= owner then
			landed = true
			mine.AssemblyLinearVelocity = Vector3.zero
			mine.AssemblyAngularVelocity = Vector3.zero
			mine.Anchored = true
		end
		if not landed or os.clock() < armAt then
			return
		end
		if not model then
			return
		end
		local participant = hitParticipant
		if not participant or participant == owner or not canUse(participant) then
			return -- only a living OTHER participant sets it off
		end
		triggered = true
		local at = if mine.Parent then mine.Position else pos
		mine:Destroy() -- DISAPPEARS the instant it blows (before the blast, so nothing leaves it behind)
		detonateMine(owner, at)
	end)
end

-- Public so tests can drive it directly.
function BombService.requestDropMine(owner: Player)
	if owner:GetAttribute("EquippedAbility") ~= "Mine" then
		return
	end
	if not canUse(owner) then
		return
	end
	local now = os.clock()
	local last = lastMineAt[owner]
	if last and now - last < MINE.COOLDOWN then
		return
	end
	lastMineAt[owner] = now
	dropMine(owner)
	NotifyService.send(owner, "Mine dropped!", "green", 1.5)
end

function BombService.init()
	throwRemote.OnServerEvent:Connect(function(thrower: Player, aim)
		BombService.requestThrow(thrower, aim)
	end)
	dropRemote.OnServerEvent:Connect(function(owner: Player)
		BombService.requestDropMine(owner)
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastThrowAt[player] = nil
		lastMineAt[player] = nil
	end)
end

return BombService
