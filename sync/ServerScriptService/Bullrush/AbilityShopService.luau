--[[
	AbilityShopService — the lobby ability shop (server-authoritative).

	The lobby shop now sells ABILITIES for in-game Money instead of bull rolls.
	Purchases are PERMANENT: they're saved to the profile's OwnedAbilities and
	mirrored to Owns_<key> attributes, which AbilityService.owns() + the round
	picker + the shop UI all read.

	Rotation (server-wide): every ABILITY_SHOP.ROTATION_SECONDS a fresh set of
	FEATURED_COUNT abilities (from Config.ABILITY_SHOP.ORDER) goes on sale; you can
	only buy what's currently featured. The featured set + its end time are published
	as attributes on ReplicatedStorage.Bullrush (so every client, late joiners
	included, sees the same shop + countdown). Prices are static (Config), so the
	client reads those directly.

	Wire (Main.server): require + AbilityShopService.init().
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Bullrush.Config)
local Remotes = ReplicatedStorage.Bullrush.Remotes
local DataHandler = require(ServerScriptService.UserData.DataHandler)
local TutorialService = require(script.Parent.TutorialService)

local AbilityShopService = {}

local CFG = Config.ABILITY_SHOP
local ROSTER = CFG.ORDER -- purchasable abilities, in display order
local PRICES = CFG.PRICES
local STARTER = CFG.STARTER_FREE -- pinned FREE slot-1 ability for first-timers (tutorial claim)
local TUTORIAL_DONE = 3 -- mirrors TutorialService.DONE; a first-timer sits below this
local bullrushFolder = ReplicatedStorage:FindFirstChild("Bullrush")

local rng = Random.new()
local featured: { string } = {} -- current featured keys (server-wide)
local featuredSet: { [string]: boolean } = {}

local function ensureRemote(name: string): RemoteEvent
	local remote = Remotes:FindFirstChild(name)
	if not (remote and remote:IsA("RemoteEvent")) then
		remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = Remotes
	end
	return remote
end
local buyRemote = ensureRemote("AbilityBuy") -- client -> server: key ; server -> client: ack

local function isPurchasable(key): boolean
	return type(key) == "string" and PRICES[key] ~= nil
end

function AbilityShopService.isFeatured(key: string): boolean
	return featuredSet[key] == true
end

function AbilityShopService.getFeatured(): { string }
	return table.clone(featured)
end

-- Fisher-Yates shuffle-pick FEATURED_COUNT of the roster.
local function pickFeatured(): { string }
	local pool = table.clone(ROSTER)
	for i = #pool, 2, -1 do
		local j = rng:NextInteger(1, i)
		pool[i], pool[j] = pool[j], pool[i]
	end
	local n = math.min(CFG.FEATURED_COUNT, #pool)
	local out = {}
	for i = 1, n do
		out[i] = pool[i]
	end
	table.sort(out, function(a, b)
		return table.find(ROSTER, a) < table.find(ROSTER, b)
	end)
	return out
end

local function publish(endsAt: number)
	featuredSet = {}
	for _, k in featured do
		featuredSet[k] = true
	end
	if bullrushFolder then
		bullrushFolder:SetAttribute("AbilityShopFeatured", HttpService:JSONEncode(featured))
		bullrushFolder:SetAttribute("AbilityShopEndsAt", endsAt)
	end
end

local function rotate()
	featured = pickFeatured()
	publish(Workspace:GetServerTimeNow() + CFG.ROTATION_SECONDS)
end

--==============================================================================
-- Ownership: load from the profile on join, mirror to Owns_<key> attributes.
--==============================================================================

local function profileReady(player: Player): boolean
	if player:GetAttribute("DataLoadFailed") then
		return false
	end
	local ok, money = pcall(DataHandler.GetStat, player, "Money")
	return ok and money ~= nil
end

local function mirrorOwnership(player: Player)
	for _, key in ROSTER do
		if DataHandler.HasAbility(player, key) then
			player:SetAttribute("Owns_" .. key, true)
		end
	end
end

--==============================================================================
-- First-timer FREE starter ability: while a player is still in the tutorial
-- (TutorialStep below DONE) and doesn't yet own STARTER, they can claim it for
-- $0 from a pinned slot-1 card. The per-player FreeStarterAbility attribute tells
-- the client to show that card + the tutorial to aim its arrow; it clears the
-- instant they own the ability or finish the tutorial (never again after that).
--==============================================================================

local function ownsStarter(player: Player): boolean
	return player:GetAttribute("Owns_" .. STARTER) == true or DataHandler.HasAbility(player, STARTER)
end

local function isStarterEligible(player: Player): boolean
	if not STARTER or not profileReady(player) then
		return false
	end
	local step = tonumber(player:GetAttribute("TutorialStep")) or 0
	return step < TUTORIAL_DONE and not ownsStarter(player)
end

local function refreshFreeStarter(player: Player)
	player:SetAttribute("FreeStarterAbility", if isStarterEligible(player) then STARTER else nil)
end

local function onPlayer(player: Player)
	task.spawn(function()
		local deadline = os.clock() + 30
		while not profileReady(player) and os.clock() < deadline do
			task.wait(0.25)
		end
		if profileReady(player) then
			mirrorOwnership(player)
			refreshFreeStarter(player)
			-- Keep the free slot-1 card in step: it appears while the tutorial runs
			-- and vanishes the moment the ability is owned or the tour completes.
			player:GetAttributeChangedSignal("TutorialStep"):Connect(function()
				refreshFreeStarter(player)
			end)
			if STARTER then
				player:GetAttributeChangedSignal("Owns_" .. STARTER):Connect(function()
					refreshFreeStarter(player)
				end)
			end
		end
	end)
end

--==============================================================================
-- Purchase
--==============================================================================

local function grant(player: Player, key: string)
	DataHandler.AddAbility(player, key)
	player:SetAttribute("Owns_" .. key, true)
end

-- Public so tests can call it directly.
function AbilityShopService.buy(player: Player, key)
	if not isPurchasable(key) then
		buyRemote:FireClient(player, { ok = false, reason = "BAD" })
		return
	end
	-- First-timer free-starter claim: grant the pinned starter ability at $0,
	-- bypassing the featured + price gates. Eligibility already requires still being
	-- in the tutorial and not owning it, so this can only ever fire once. Advances
	-- the tutorial's final step (its completion gift).
	if key == STARTER and isStarterEligible(player) then
		grant(player, key)
		refreshFreeStarter(player) -- owned now -> the free card clears
		buyRemote:FireClient(player, { ok = true, key = key, money = DataHandler.GetStat(player, "Money") or 0, free = true })
		TutorialService.onClaimStarter(player)
		return
	end
	if not AbilityShopService.isFeatured(key) then
		buyRemote:FireClient(player, { ok = false, reason = "NOT_FEATURED", key = key })
		return
	end
	if not profileReady(player) then
		buyRemote:FireClient(player, { ok = false, reason = "DATA", key = key })
		return
	end
	if player:GetAttribute("Owns_" .. key) == true or DataHandler.HasAbility(player, key) then
		buyRemote:FireClient(player, { ok = false, reason = "OWNED", key = key })
		return
	end
	local price = PRICES[key]
	local money = DataHandler.GetStat(player, "Money") or 0
	if money < price then
		buyRemote:FireClient(player, { ok = false, reason = "NO_MONEY", key = key, cost = price })
		return
	end
	DataHandler.SetStat(player, "Money", money - price)
	grant(player, key)
	buyRemote:FireClient(player, { ok = true, key = key, money = money - price })
end

function AbilityShopService.init()
	rotate()

	buyRemote.OnServerEvent:Connect(function(player: Player, key)
		AbilityShopService.buy(player, key)
	end)

	for _, p in Players:GetPlayers() do
		onPlayer(p)
	end
	Players.PlayerAdded:Connect(onPlayer)

	task.spawn(function()
		while true do
			task.wait(CFG.ROTATION_SECONDS)
			rotate()
		end
	end)
end

return AbilityShopService
