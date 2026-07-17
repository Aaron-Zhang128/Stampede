--[[
	BombClient — bomb ability input + getting-blasted burst (server rules in BombService).

	Press the bomb key (default G / gamepad ButtonX) or the HUD bomb button while
	you're an ALIVE round participant (or on the practice grid) to lob a bomb where
	your camera is facing; BombService spawns + arcs it and detonates on its fuse.

	HUD bridge (same idiom as PushBridge): the BombBridge BindableEvent in
	ReplicatedStorage. Fire() = a tap; attributes broadcast state back to a button:
		Enabled          bool    you can throw right now
		CooldownDuration number  BOMB.COOLDOWN, so the sweep knows its length
		ReadyAt          number  os.clock() when the local cooldown lapses

	Getting blasted: the server fires Remotes.Bombed with the outward direction and
	we apply the knockback burst to our OWN character (client-authoritative, the
	same LinearVelocity-constraint arc as Push's Pushed handler, tuned by Config.BOMB).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Bullrush.Config)
local RagdollUtil = require(ReplicatedStorage.Bullrush.RagdollUtil)
local Remotes = ReplicatedStorage.Bullrush.Remotes

local BOMB = Config.BOMB
local MINE = Config.MINE
local player = Players.LocalPlayer

-- These remotes are created by BombService at runtime (they don't exist in edit
-- mode), so wait for them rather than indexing straight away.
local throwRemote = Remotes:WaitForChild("BombThrow")
local bombedRemote = Remotes:WaitForChild("Bombed")
local dropRemote = Remotes:WaitForChild("DropMine")
local minedRemote = Remotes:WaitForChild("Mined")
local roundStateRemote = Remotes:WaitForChild("RoundState")

--==============================================================================
-- HUD bridge (never replicates); mirrors ReplicatedStorage.PushBridge.
--==============================================================================

local bombBridge = Instance.new("BindableEvent")
bombBridge.Name = "BombBridge"
bombBridge:SetAttribute("Enabled", false)
bombBridge:SetAttribute("CooldownDuration", BOMB.COOLDOWN)
bombBridge:SetAttribute("ReadyAt", 0)
bombBridge.Parent = ReplicatedStorage

-- Mine shares this client (both are "spawn an explosive" abilities) but gets its own
-- HUD bridge so the Ability Box can bind to it when Mine is the equipped ability.
local mineBridge = Instance.new("BindableEvent")
mineBridge.Name = "MineBridge"
mineBridge:SetAttribute("Enabled", false)
mineBridge:SetAttribute("CooldownDuration", MINE.COOLDOWN)
mineBridge:SetAttribute("ReadyAt", 0)
mineBridge.Parent = ReplicatedStorage

--==============================================================================
-- State + participation (same gate as PushClient)
--==============================================================================

local roundActive = false
local readyAt = 0 -- os.clock() when the local cooldown lapses

local function localRoot(): BasePart?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and root then
		return root
	end
	return nil
end

local function isParticipating(): boolean
	if localRoot() == nil then
		return false
	end
	if player:GetAttribute("InPractice") == true then
		return true
	end
	return roundActive and player:GetAttribute("InRound") == true
end

roundStateRemote.OnClientEvent:Connect(function(state: string)
	roundActive = state == "ACTIVE"
end)

-- Keep the HUD button's Enabled flag in step on a light throttle.
local SCAN = 0.12
local lastScan = 0
RunService.Heartbeat:Connect(function()
	local now = os.clock()
	if now - lastScan < SCAN then
		return
	end
	lastScan = now
	local equipped = player:GetAttribute("EquippedAbility") or "Push"
	bombBridge:SetAttribute("Enabled", isParticipating() and equipped == "Bomb")
	mineBridge:SetAttribute("Enabled", isParticipating() and equipped == "Mine")
end)

--==============================================================================
-- Throwing
--==============================================================================

-- Aim where the camera looks, with the vertical damped so looking up lobs it
-- farther without launching it straight overhead.
local function aimDirection(): Vector3
	local cam = Workspace.CurrentCamera
	local look = if cam then cam.CFrame.LookVector else Vector3.new(0, 0, -1)
	local dir = Vector3.new(look.X, look.Y * 0.35, look.Z)
	if dir.Magnitude < 0.01 then
		return Vector3.new(0, 0, -1)
	end
	return dir.Unit
end

local function attemptThrow()
	if (player:GetAttribute("EquippedAbility") or "Push") ~= "Bomb" then
		return -- some other ability is equipped in the Ability Box
	end
	if not isParticipating() then
		return
	end
	if os.clock() < readyAt then
		return
	end
	throwRemote:FireServer(aimDirection())
	readyAt = os.clock() + BOMB.COOLDOWN
	bombBridge:SetAttribute("ReadyAt", readyAt)
end

bombBridge.Event:Connect(attemptThrow)

-- Mine: same key/button as Bomb, but only fires when Mine is equipped (attemptThrow
-- bails when it isn't, and attemptDropMine bails when Bomb is, so calling both is safe).
local mineReadyAt = 0
local function attemptDropMine()
	if (player:GetAttribute("EquippedAbility") or "Push") ~= "Mine" then
		return
	end
	if not isParticipating() then
		return
	end
	if os.clock() < mineReadyAt then
		return
	end
	dropRemote:FireServer()
	mineReadyAt = os.clock() + MINE.COOLDOWN
	mineBridge:SetAttribute("ReadyAt", mineReadyAt)
end

mineBridge.Event:Connect(attemptDropMine)

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end
	if input.KeyCode == Enum.KeyCode.F or input.KeyCode == Enum.KeyCode.ButtonY then
		attemptThrow()
		attemptDropMine()
	end
end)

--==============================================================================
-- Getting blasted: apply the knockback burst to our own character. Same
-- unlimited-force LinearVelocity arc as PushClient (see there for the full why),
-- tuned by Config.BOMB.
--==============================================================================

local KNOCKBACK_NAME = "BombKnockback"

local function aliveRoot(): BasePart?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and root then
		return root
	end
	return nil
end

-- Short decaying camera jolt on the victim, layered one priority after the
-- default camera so our offset survives the camera update (mirrors PushClient).
local SHAKE_BIND = "BombCamShake"
local SHAKE_POS = 0.192 -- reduced 40% (was 0.32, user request 2026-07-15)
local SHAKE_ROT = 1.08 -- reduced 40% (was 1.8)
local SHAKE_TIME = 0.35
-- Phones get 30% less camera shake than PC (user request 2026-07-16).
local MOBILE_SHAKE_MULT = (UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled) and 0.7 or 1

local function shakeCamera()
	pcall(function()
		RunService:UnbindFromRenderStep(SHAKE_BIND)
	end)
	local startedAt = os.clock()
	RunService:BindToRenderStep(SHAKE_BIND, Enum.RenderPriority.Camera.Value + 1, function()
		local cam = Workspace.CurrentCamera
		local t = os.clock() - startedAt
		if not cam or t >= SHAKE_TIME then
			pcall(function()
				RunService:UnbindFromRenderStep(SHAKE_BIND)
			end)
			return
		end
		local falloff = 1 - t / SHAKE_TIME
		falloff = falloff * falloff
		local p = SHAKE_POS * falloff * MOBILE_SHAKE_MULT
		local r = math.rad(SHAKE_ROT * falloff * MOBILE_SHAKE_MULT)
		cam.CFrame = cam.CFrame
			* CFrame.new((math.random() * 2 - 1) * p, (math.random() * 2 - 1) * p, (math.random() * 2 - 1) * p)
			* CFrame.Angles((math.random() * 2 - 1) * r, (math.random() * 2 - 1) * r, (math.random() * 2 - 1) * r)
	end)
end

bombedRemote.OnClientEvent:Connect(function(direction: Vector3)
	local root = aliveRoot()
	if not root then
		return
	end
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 0.01 then
		return
	end
	flat = flat.Unit

	shakeCamera()

	-- A second blast mid-burst restarts clean.
	local stale = root:FindFirstChild(KNOCKBACK_NAME)
	if stale then
		stale:Destroy()
	end

	local spike = Vector3.new(flat.X * BOMB.SPEED, BOMB.UP, flat.Z * BOMB.SPEED)
	root.AssemblyLinearVelocity = spike -- cover the substeps before the constraint engages

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
		if aliveRoot() ~= root or attachment.Parent ~= root or t >= BOMB.TIME then
			connection:Disconnect()
			attachment:Destroy()
			return
		end
		-- Sample half a frame ahead so the arc is frame-rate-proof.
		local ts = math.min(t + dt / 2, BOMB.TIME)
		local falloff = 1 - ts / BOMB.TIME
		falloff = falloff * falloff
		local vy
		if ts < BOMB.UP_TIME then
			vy = BOMB.UP - (2 * BOMB.UP / BOMB.UP_TIME) * ts
		else
			vy = -BOMB.UP - Workspace.Gravity * (ts - BOMB.UP_TIME)
		end
		velocity.VectorVelocity = Vector3.new(flat.X * BOMB.SPEED * falloff, vy, flat.Z * BOMB.SPEED * falloff)
	end)
end)

--==============================================================================
-- Stepped on a mine: NON-lethally ragdoll our OWN character (client-owned, so
-- network ownership holds — same as Shockwave) with the server's launch impulse,
-- plus a camera jolt, then stand back up after MINE.RAGDOLL_TIME. We stay ALIVE.
--==============================================================================

minedRemote.OnClientEvent:Connect(function(impulse: Vector3)
	local character = player.Character
	if not character then
		return
	end
	shakeCamera()
	RagdollUtil.ragdoll(character, if typeof(impulse) == "Vector3" then impulse else nil)
	task.delay(MINE.RAGDOLL_TIME, function()
		if player.Character == character then
			RagdollUtil.recover(character)
		end
	end)
end)
