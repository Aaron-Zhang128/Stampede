--[[
	AbilityService — the ability-selection brain (server-authoritative).

	Each round every player picks ONE ability into their single "Ability Box".
	Everyone starts owning TWO for free — Push and Speed — so there's always
	a real choice; anything else they pick they must OWN. This service owns:

	  * EquippedAbility (replicated string attr): "Push" | "Bomb" | "Speed" |
	    "ExtraLives" | "Shockwave" | "FreezePunch". Every ability service/client
	    gates itself on this, so only the equipped one works.
	  * Ownership: Push and Speed are free defaults everyone has; the rest read
	    an Owns_<key> attribute that the ability shop (AbilityShopService) sets +
	    saves. The picker only shows abilities you actually own.
	  * The per-round flow, driven by Main.server's round loop:
	      beginSelection(participants)  at the on-field countdown: reset everyone to
	                                    Push, unlock the pick, and open each client's
	                                    picker (AbilityOffer) with their owned list.
	      lockSelection(participants)   when the round goes ACTIVE: lock the choice in
	                                    for the round (AbilityLocked).
	      clear(player)                 round end / elimination: back to Push, drop hearts.
	  * AbilityChoose (client -> server): a pick. Accepted while unlocked + owned.

	Picking ExtraLives grants the hearts immediately (ExtraLivesService); switching
	away clears them.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Bullrush.Config)
local Remotes = ReplicatedStorage.Bullrush.Remotes
local ExtraLivesService = require(script.Parent.ExtraLivesService)

local AbilityService = {}

-- Roster order = the order cards appear in the picker. Keep in sync with the
-- client picker's ABILITY table and each ability service's equip gate.
local ORDER = { "Push", "Bomb", "Speed", "ExtraLives", "Shockwave", "FreezePunch", "Mine", "FastPunch", "JumpHigher", "MegaPunch", "BananaPeel", "DoubleJump" }
local VALID: { [string]: boolean } = {}
for _, key in ORDER do
	VALID[key] = true
end

-- Free defaults: every player owns these from the start (no purchase), so the
-- round picker always has at least two cards and a genuine choice. Everything else
-- is bought in the ability shop (Owns_<key>).
local DEFAULT_OWNED: { [string]: boolean } = { Push = true, Speed = true }

local SELECT_SECONDS = Config.START_DELAY or 5

local function ensureRemote(name: string): RemoteEvent
	local remote = Remotes:FindFirstChild(name)
	if not (remote and remote:IsA("RemoteEvent")) then
		remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = Remotes
	end
	return remote
end
local offerRemote = ensureRemote("AbilityOffer") -- server -> client: { ownedKeys }, seconds
local chooseRemote = ensureRemote("AbilityChoose") -- client -> server: key

-- Ownership: Push and Speed are free (DEFAULT_OWNED); the rest are bought in
-- the lobby shop (AbilityShopService), which sets Owns_<key> and saves it to the
-- profile. This reads that attribute, so the picker only ever shows what you own.
-- Studio-only shortcut to own everything for testing (never runs live). OFF by
-- default so the picker really does hide what you don't own — flip to true only
-- to smoke-test all abilities without buying them.
local TEST_OWN_ALL = false
-- Temporary Studio QA unlock for the four abilities currently under test. This
-- only sets replicated session attributes; it never writes OwnedAbilities or
-- touches the production PlayerData_v2 store.
local STUDIO_TEST_ABILITIES = { "JumpHigher", "MegaPunch", "BananaPeel", "DoubleJump" }
local STUDIO_TEST_SET: { [string]: boolean } = {}
for _, key in STUDIO_TEST_ABILITIES do
	STUDIO_TEST_SET[key] = true
end

function AbilityService.owns(player: Player, key: string): boolean
	if DEFAULT_OWNED[key] then
		return true
	end
	if TEST_OWN_ALL and RunService:IsStudio() then
		return true
	end
	if RunService:IsStudio() and STUDIO_TEST_SET[key] then
		return true
	end
	return player:GetAttribute("Owns_" .. key) == true
end

local function ownedList(player: Player): { string }
	local list = {}
	for _, key in ORDER do
		if AbilityService.owns(player, key) then
			table.insert(list, key)
		end
	end
	return list
end

function AbilityService.getEquipped(player: Player): string
	return player:GetAttribute("EquippedAbility") or "Push"
end

local function setEquipped(player: Player, key: string)
	player:SetAttribute("EquippedAbility", key)
	-- ExtraLives is the one ability with an immediate on-equip effect (the hearts).
	if key == "ExtraLives" then
		ExtraLivesService.grant(player)
	else
		ExtraLivesService.clear(player)
	end
end

-- Start-of-round: reset to Push, unlock, and open the picker for real players.
function AbilityService.beginSelection(participants: { any })
	for _, p in participants do
		if typeof(p) == "Instance" and p:IsA("Player") then
			p:SetAttribute("AbilityLocked", false)
			setEquipped(p, "Push")
			-- Only open the picker when there's an actual choice (they own a non-Push
			-- ability). Players who only have Push just keep it — no pointless overlay.
			local owned = ownedList(p)
			if #owned > 1 then
				offerRemote:FireClient(p, owned, SELECT_SECONDS)
			end
		end
	end
end

-- Round goes ACTIVE: lock in whatever's equipped for the rest of the round.
function AbilityService.lockSelection(participants: { any })
	for _, p in participants do
		if typeof(p) == "Instance" and p:IsA("Player") then
			p:SetAttribute("AbilityLocked", true)
		end
	end
end

-- Round end / elimination: back to the default, drop any hearts.
function AbilityService.clear(player: Player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	player:SetAttribute("AbilityLocked", nil)
	player:SetAttribute("EquippedAbility", "Push")
	ExtraLivesService.clear(player)
end

function AbilityService.init()
	chooseRemote.OnServerEvent:Connect(function(player: Player, key)
		if type(key) ~= "string" or not VALID[key] then
			return
		end
		if player:GetAttribute("AbilityLocked") == true then
			return -- one pick per round; already locked in
		end
		if not AbilityService.owns(player, key) then
			return -- don't own it (spoof guard)
		end
		setEquipped(player, key)
	end)

	Players.PlayerRemoving:Connect(function(player)
		player:SetAttribute("EquippedAbility", nil)
	end)

	-- Studio-only test unlock: with TEST_OWN_ALL on, mark EVERY ability owned
	-- (Owns_<key>) on join so the skills index / HUD / shop all read unlocked too —
	-- owns() already short-circuits for the picker. Never runs live (IsStudio gate).
	if TEST_OWN_ALL and RunService:IsStudio() then
		local function grantAll(player: Player)
			for _, key in ORDER do
				player:SetAttribute("Owns_" .. key, true)
			end
		end
		for _, p in Players:GetPlayers() do
			grantAll(p)
		end
		Players.PlayerAdded:Connect(grantAll)
	end

	if RunService:IsStudio() then
		local function grantTestAbilities(player: Player)
			for _, key in STUDIO_TEST_ABILITIES do
				player:SetAttribute("Owns_" .. key, true)
			end
		end
		for _, player in Players:GetPlayers() do
			grantTestAbilities(player)
		end
		Players.PlayerAdded:Connect(grantTestAbilities)
	end
end

return AbilityService
