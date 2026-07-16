--[[
	SpeedBoostService — speed-boost ability (server-authoritative).

	Fire the SpeedBoost remote (SpeedBoostClient does this on its key / HUD button)
	and, if you're an alive participant off cooldown, your WalkSpeed jumps to
	base * SPEED_BOOST.MULT for SPEED_BOOST.DURATION seconds with speed-line
	trails, then restores. WalkSpeed is SERVER-owned so the buff is real for
	physics and every client sees the trails.

	Server-enforced: alive-in-round (or practice) + per-player cooldown. The base
	WalkSpeed captured at activation is what we restore to; re-activating while
	already boosted just refreshes the timer (base isn't re-captured, so the buff
	never compounds). A generation token guards the restore so a boost that ends
	stale (round change, death) can never stomp a newer WalkSpeed.

	WIRING (left to you): SpeedBoostClient already drives this; nothing else is
	required. If your round system re-sets WalkSpeed mid-boost, prefer calling
	SpeedBoostService.activate() AFTER that so the captured base is correct.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Bullrush.Config)
local Remotes = ReplicatedStorage.Bullrush.Remotes
local RoundService = require(script.Parent.RoundService)
local NotifyService = require(script.Parent.NotifyService)
local SoundService = game:GetService("SoundService")

-- Positional one-shot from the curated GameSFX library, parented to `at` so it
-- plays in 3D at the effect and every nearby client hears it (server-built, same
-- idiom as PushService.playImpactSound). Silent if the library sound is missing.
local function playSfxAt(name: string, at: BasePart?)
	if not at then
		return
	end
	local group = SoundService:FindFirstChild("GameSFX")
	local template = group and group:FindFirstChild(name)
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
	sound.RollOffMaxDistance = 100
	sound.Parent = at
	pcall(function()
		sound:Play()
	end)
	task.delay(6, function()
		if sound then
			sound:Destroy()
		end
	end)
end

local SpeedBoostService = {}

local CFG = Config.SPEED_BOOST

local lastUseAt: { [Player]: number } = {}
-- Active boost per player: { base = WalkSpeed to restore, token = generation }.
local active: { [Player]: { base: number, token: number } } = {}
local tokens: { [Player]: number } = {} -- monotonic per player; newest owns restore

local function ensureRemote(name: string): RemoteEvent
	local remote = Remotes:FindFirstChild(name)
	if not (remote and remote:IsA("RemoteEvent")) then
		remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = Remotes
	end
	return remote
end
local boostRemote = ensureRemote("SpeedBoost") -- client -> server: activate

local function canUse(player: Player): boolean
	if player:GetAttribute("EquippedAbility") ~= "Speed" then
		return false -- some other ability is equipped in the Ability Box
	end
	if RoundService.isAlive(player) then
		return true
	end
	return player:GetAttribute("InPractice") == true
end

-- A vertical speed-line trail down the body, cleaned up when the boost ends.
local function addTrail(character: Model)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or root:FindFirstChild("SpeedBoostTrail") then
		return
	end
	local a0 = Instance.new("Attachment")
	a0.Name = "SpeedTrailTop"
	a0.Position = Vector3.new(0, 1.4, 0)
	a0.Parent = root
	local a1 = Instance.new("Attachment")
	a1.Name = "SpeedTrailBottom"
	a1.Position = Vector3.new(0, -1.4, 0)
	a1.Parent = root
	local trail = Instance.new("Trail")
	trail.Name = "SpeedBoostTrail"
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Lifetime = 0.35
	trail.MinLength = 0
	trail.Color = ColorSequence.new(Color3.fromRGB(120, 220, 255))
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	trail.LightEmission = 1
	trail.Parent = root
end

local function removeTrail(character: Model)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	for _, name in { "SpeedBoostTrail", "SpeedTrailTop", "SpeedTrailBottom" } do
		local inst = root:FindFirstChild(name)
		if inst then
			inst:Destroy()
		end
	end
end

-- End a boost, but only if this token still owns the player (a newer boost, a
-- respawn, or a clear may have taken over meanwhile).
local function restore(player: Player, token: number)
	local state = active[player]
	if not state or state.token ~= token then
		return
	end
	active[player] = nil
	player:SetAttribute("SpeedBoosted", nil)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = state.base
	end
	if character then
		removeTrail(character)
	end
end

-- Public so tests / other systems can trigger a boost directly.
function SpeedBoostService.activate(player: Player)
	if not canUse(player) then
		return
	end
	local now = os.clock()
	local last = lastUseAt[player]
	if last and now - last < CFG.COOLDOWN then
		return
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	lastUseAt[player] = now

	local token = (tokens[player] or 0) + 1
	tokens[player] = token

	-- Capture the base only if not already boosted, so a refresh never compounds.
	local base = if active[player] then active[player].base else humanoid.WalkSpeed
	active[player] = { base = base, token = token }
	player:SetAttribute("SpeedBoosted", true)

	-- Mode-specific boost: High Speed (any mode with speedBoostMult) sprints HARDER.
	-- Main.server publishes the mode's mult on the Bullrush folder; default to MULT.
	local modeMult = Remotes.Parent:GetAttribute("SpeedBoostMult")
	local mult = (type(modeMult) == "number" and modeMult > 0) and modeMult or CFG.MULT
	humanoid.WalkSpeed = base * mult
	addTrail(character)
	playSfxAt("Speed Boost (Short Ver)", character:FindFirstChild("HumanoidRootPart"))
	NotifyService.send(player, "Speed boost!", "green", 1.5)

	task.delay(CFG.DURATION, function()
		restore(player, token)
	end)
end

function SpeedBoostService.init()
	boostRemote.OnServerEvent:Connect(function(player: Player)
		SpeedBoostService.activate(player)
	end)

	-- Respawn: the fresh humanoid resets WalkSpeed on its own, so just drop our
	-- bookkeeping (a pending stale restore then no-ops on the token check).
	local function hookCharacter(player: Player)
		player.CharacterAdded:Connect(function()
			active[player] = nil
			player:SetAttribute("SpeedBoosted", nil)
		end)
	end
	for _, player in Players:GetPlayers() do
		hookCharacter(player)
	end
	Players.PlayerAdded:Connect(hookCharacter)

	Players.PlayerRemoving:Connect(function(player)
		lastUseAt[player] = nil
		active[player] = nil
		tokens[player] = nil
	end)
end

return SpeedBoostService
