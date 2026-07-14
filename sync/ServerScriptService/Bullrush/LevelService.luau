--[[
	LevelService - 10-level player progression fed by gameplay money.

	XP source: RoundService.awardMoney calls addXP with the PRE-multiplier
	amount (Config.LEVELS.XP_PER_MONEY per $1), so every gameplay grant -
	survival/placement/stage/streak pay, the flat win pay, revenge hits -
	levels everyone at the same rate: friend boosts / VIP / 2x Money scale
	the money, never the curve. Purchases and gifts (money packs, wheel,
	daily, dupe refunds) are granted raw elsewhere and give no XP.

	Profile keys: Level (1..MAX_LEVEL) + XP (progress INTO the current
	level - the XP_TO_NEXT step is subtracted on each level-up). Both
	mirror to same-named player attributes (seeded on join by Data.server);
	the client XP bar (Main section 17) renders straight off those.

	Level rewards (Config.LEVELS.REWARDS): money lands RAW via DataHandler
	(a gift, not round earnings - no boosts, and no XP back, or reward
	money would feed the next level). A box reward BANKS a free opening in
	FreeBoxRolls - the shop card flips to FREE and the next open of that
	box costs nothing, full carousel reveal included (same bank as the
	new-player BASIC gift).
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage.Bullrush.Config)
local DataHandler = require(ServerScriptService.UserData.DataHandler)
local NotifyService = require(script.Parent.NotifyService)

local LEVELS = Config.LEVELS

local LevelService = {}

-- A missing profile (data still loading, player left mid-round) must never
-- break the round loop that pays money -> XP, so writes stay pcall-guarded.
local function safeData(fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		warn("Bullrush: LevelService data call failed:", err)
	end
end

-- Applies Config.LEVELS.REWARDS[level] and announces the level-up. Money
-- goes through SetStat (the leaderstats mirror must tick); the box bank has
-- no value instance, so it's a direct profile write + attribute refresh.
local function grantReward(player, level: number)
	local reward = LEVELS.REWARDS[level]
	if reward then
		if reward.kind == "money" then
			DataHandler.SetStat(player, "Money",
				(DataHandler.GetStat(player, "Money") or 0) + reward.amount)
		elseif reward.kind == "box" then
			local profile = DataHandler.Profiles[player.UserId]
			local bank = typeof(profile.FreeBoxRolls) == "table" and profile.FreeBoxRolls or {}
			bank[reward.boxId] = (bank[reward.boxId] or 0) + 1
			profile.FreeBoxRolls = bank
			if typeof(player) == "Instance" then
				player:SetAttribute("FreeBoxRolls", HttpService:JSONEncode(bank))
			end
		end
	end
	NotifyService.send(player,
		("LEVEL %d! %s"):format(level, reward and reward.label or ""), "green", 5)
end

-- Adds gameplay-money XP and settles any level-ups it causes. `amount` is
-- the pre-multiplier money figure; callers (RoundService.awardMoney) have
-- already excluded bots. Attributes update in the same pass so the XP bar
-- animates through each level as rewards land.
function LevelService.addXP(player, amount: number)
	local xpGain = math.floor((tonumber(amount) or 0) * LEVELS.XP_PER_MONEY + 0.5)
	if xpGain <= 0 then
		return
	end
	local profile = DataHandler.Profiles[player.UserId]
	if not profile then
		return -- data still loading / already left: don't fake level-ups
	end
	local level = tonumber(profile.Level) or 1
	local xp = tonumber(profile.XP) or 0
	if level >= LEVELS.MAX_LEVEL then
		return -- capped: the bar shows MAX, extra XP is dropped
	end
	xp += xpGain
	local reached = {}
	while level < LEVELS.MAX_LEVEL and xp >= (LEVELS.XP_TO_NEXT[level] or math.huge) do
		xp -= LEVELS.XP_TO_NEXT[level]
		level += 1
		table.insert(reached, level)
	end
	if level >= LEVELS.MAX_LEVEL then
		xp = 0 -- no next threshold; the bar renders MAX off Level
	end
	-- XP/Level have no leaderstats/Stats mirror, so write the profile directly
	-- (SetStat's mirror sweep adds nothing here) and replicate via attributes.
	profile.XP = xp
	profile.Level = level
	if typeof(player) == "Instance" then
		player:SetAttribute("XP", xp)
		player:SetAttribute("Level", level)
	end
	-- Each reward in its own guard: one failed grant must not eat the rest.
	for _, newLevel in reached do
		safeData(grantReward, player, newLevel)
	end
end

function LevelService.getLevel(player): number
	return DataHandler.GetStat(player, "Level") or 1
end

return LevelService
