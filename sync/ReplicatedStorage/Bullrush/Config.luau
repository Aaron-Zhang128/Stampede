local Config = {}

-- Physical arena: an 11x11 tile grid (Tile_1_1 .. Tile_11_11). Every MODE plays
-- in a centered square WINDOW of that grid (mode.startSize); tiles outside the
-- window start the round already sunken. The window then shrinks during the
-- round per the mode's schedule.
Config.GRID_SIZE = 11
Config.TILE_SIZE = 6              -- spacing between tile centers (= tile width; tiles touch) [A/B test 2026-07-04: was 8.4]
Config.TILE_PART_SIZE = Config.TILE_SIZE -- tile width = center spacing, so tiles touch edge-to-edge
Config.TILE_THICKNESS = 80       -- tiles are tall pillars; TOPS stay at ARENA_ORIGIN height
Config.ARENA_ORIGIN = Vector3.new(200, 20, 200) -- grid center at tile TOP surface height

Config.BULL_RIDE_HEIGHT = 2.5     -- bull Root center height above tile surface
Config.BULL_OVERSHOOT = 12        -- studs beyond the active window edge where bulls spawn and exit
Config.BULL_HIT_HALF_LENGTH = 3.5 -- kill box half-length along the travel axis
Config.BULL_HIT_HALF_WIDTH = 3.9  -- kill box half-width across the lane

Config.MIN_PLAYERS = 1            -- solo rounds run for practice; wins only awarded with 2+ starters
Config.INTERMISSION_TIME = 15
Config.MONEY_PER_WIN = 100

-- Next-mode voting: during intermission, players vote among VOTE_OPTION_COUNT
-- random eligible modes for the round to play; most votes wins (ties broken
-- randomly). Disable to fall back to the plain weighted-random pickMode.
Config.VOTING_ENABLED = true
Config.VOTE_OPTION_COUNT = 3

-- Friend boost: every money grant is multiplied by 1 + PER_FRIEND for each of
-- the player's Roblox friends currently in the server (FriendBoostService).
Config.FRIEND_BOOST = {
	PER_FRIEND = 0.5,             -- +50% money per friend in the server
}

-- Round economy: every participant banks Money for how the round went, paid in
-- one pass at round end (EconomyService) through the awardMoney choke point,
-- so the friend boost applies to all of it. The Summary tab itemizes the pay.
-- Amounts below are pre-multiplier; the mode's moneyMult scales them.
Config.ECONOMY = {
	SURVIVAL_MONEY = 2,           -- paid per SURVIVAL_INTERVAL seconds survived
	SURVIVAL_INTERVAL = 5,
	PLACEMENT = { 75, 40, 20 },   -- 1st/2nd/3rd finish, non-team rounds only
	PLACEMENT_MIN_STARTERS = 4,   -- placement + final-3 pay need this many starters
	STAGE_BONUS = 10,             -- each arena shrink you were alive through
	LAST3_BONUS = 15,             -- reaching the final 3 alive
	STREAK_BONUS = 25,            -- per consecutive win, on top of MONEY_PER_WIN
	STREAK_BONUS_CAP = 100,       -- streak bonus ceiling (hit at a 4-win streak)
}

-- Robux developer products (fill the IDs in after publishing). 0 = not
-- configured: the client's purchase prompt fails to a red card and
-- MonetizationService's ProcessReceipt leaves unknown products untouched.
-- All of these are dispatched by MonetizationService (the game's Robux hub).
Config.PRODUCTS = {
	DOUBLE_ROUND = 3609138326,    -- "2x Rewards" (7 R$): Summary tab, doubles that round's payout
	BULL_ROLL = 3609138124,       -- "Bull Roll X1" (9 R$): 1 bull roll (BullRollService)
	BULL_ROLL_10 = 3609138196,    -- "Bull Roll X10" (64 R$): 10 bull rolls
	SPIN_1 = 3609137845,          -- "Spin 1" (32 R$): 1 fortune-wheel spin (SpinService)
	SPIN_10 = 3609137877,         -- "Spin X10" (240 R$): 10 fortune-wheel spins
	DAILY_CLAIM_ALL = 3609138406, -- "Daily Claim All" (104 R$): claim the whole 7-day daily loop (DailyRewardService)
	-- Lucky Blocks (Store LuckyBlocks cards): premium one-shot wheel spins that
	-- roll their OWN richer reward table (Config.LUCKY_BLOCKS) instead of the free
	-- wheel's. Buying auto-opens the Spinner and spins. Handled by SpinService.
	-- Mapped by PRICE (the product names on Roblox differ from our tier names).
	LUCKY_SECRET = 3609137453,    -- "Lucky Block" (20 R$)  -> Secret tier
	LUCKY_ALIEN = 3609137528,     -- "Lucky Secret" (80 R$) -> Alien tier
	LUCKY_GOD = 3609137618,       -- "Lucky God" (200 R$)   -> GOD tier
	-- OP Lucky Block: a ROBUX elite BULL ROLL (Config.BULLS.OP_ROLL, Epic/Legendary
	-- only) revealed on the bull carousel - NOT a wheel spin. Handled by
	-- BullRollService; X3/X10 roll 3/10 elite bulls. Sold on the Store "Exclusive" card.
	OP_LUCKY = 3609162473,        -- "OP Lucky Block" (99 R$)      -> 1 elite bull roll
	OP_LUCKY_X3 = 3609162516,     -- "OP Lucky Block X3" (249 R$)  -> 3 elite bull rolls
	OP_LUCKY_X10 = 3609162604,    -- "OP Lucky Block X10" (699 R$) -> 10 elite bull rolls
	SERVER_LUCK = 3609144868,     -- "Server Luck" product: boosts the WHOLE server's Epic/Legendary roll odds for Config.LUCK.SERVER.duration (re-buy adds time)
	-- Money Packs (Store "Cash" section): buy Robux -> get in-game Money. Amounts
	-- live in Config.MONEY_PACKS; handled by MonetizationService.
	MONEY_PACK_1 = 3609139604,    -- "Money Pack #1" (16 R$)
	MONEY_PACK_2 = 3609139680,    -- "Money Pack #2" (32 R$)
	MONEY_PACK_3 = 3609139731,    -- "Money Pack #3" (64 R$)
	MONEY_PACK_4 = 3609139823,    -- "Money Pack #4" (104 R$)
	MONEY_PACK_5 = 3609139866,    -- "Money Pack #5" (144 R$)
}

-- Money Packs (Store "Cash" section cards): each grants `amount` Money RAW (a
-- purchase, not round earnings - no friend/mode/pass multipliers). label is what
-- the card's Info.Amount shows; name is the card title. Order = the Cash section
-- card order (cheapest first). MonetizationService registers + grants these.
-- Sized to the round/crate economy (a win ~270, Mega crate 2500): the cheapest
-- pack is ~2 Mega crates and the biggest ~30, so packs are a real jumpstart but
-- never dwarf the earn-and-spend loop the way 100K-1.75M did.
Config.MONEY_PACKS = {
	{ product = "MONEY_PACK_1", amount = 5000,  label = "$5,000",  name = "Tiny Pack" },
	{ product = "MONEY_PACK_2", amount = 12000, label = "$12,000", name = "Small Pack" },
	{ product = "MONEY_PACK_3", amount = 28000, label = "$28,000", name = "Medium Pack" },
	{ product = "MONEY_PACK_4", amount = 50000, label = "$50,000", name = "Large Pack" },
	{ product = "MONEY_PACK_5", amount = 75000, label = "$75,000", name = "Huge Pack" },
}

-- Robux game passes (permanent perks; fill the IDs in after publishing). 0 =
-- not configured: MonetizationService treats the pass as owned-by-nobody, so
-- its perk stays off and prompts no-op. Perks are declared in
-- MonetizationService.PASS_BENEFITS; add a pass by publishing it, pasting its
-- id here, and adding a benefits row there.
Config.PASSES = {
	VIP = 1905787138,             -- perk bundle + IsVIP attribute; +50% Money (getMoneyMultiplier),
	                              -- x1.5 roll luck (stacks on top of luck passes), 2x vote power,
	                              -- an extra free wheel spin every day, and a gold [VIP] chat tag
	DOUBLE_MONEY = 1907797039,    -- "2X Money" pass: permanent 2x Money on every grant (stacks with VIP + friend boost)
	-- Luck passes (personal, permanent): multiply the Epic/Legendary weight on
	-- Lucky BOX rolls. Only the HIGHEST owned tier applies (they don't stack with
	-- each other), then Server Luck multiplies on top. Multipliers live in
	-- MonetizationService.PASS_BENEFITS.
	LUCK_2X = 1907581101,         -- "2x Luck" (32 R$): x2 Epic/Legendary odds
	LUCK_SUPER = 1907203195,      -- "Super Luck" (64 R$): x3
	LUCK_MEGA = 1906735192,       -- "Mega Luck" (104 R$): x5
	STRAWBERRY_ELEPHANT = 1907029151, -- "Celestial Bull" pass (144 R$): grants the STRAWBERRY legendary bull (also rollable)
}

-- Luck: multiplies the Epic/Legendary weight on Lucky BOX rolls (BullRollService),
-- then BullCatalog.roll renormalizes, so a "x2" roughly doubles those odds. Only
-- box rolls are affected (Lucky Blocks + wheel give fixed prizes). Personal luck =
-- the highest owned luck PASS (Config.PASSES LUCK_*); Server Luck multiplies on top
-- of that (stacks) while active. Pass multipliers are in MonetizationService.
Config.LUCK = {
	BOOSTED = { EPIC = true, LEGENDARY = true }, -- which rarities luck lifts
	SERVER = {
		multiplier = 2,           -- SERVER_LUCK product: x2 Epic/Legendary for everyone
		duration = 30 * 60,       -- seconds one purchase lasts; re-buying extends it
	},
}

-- Fortune wheel (Frames.Spinner UI + the lobby wheel model): one free spin
-- banked every FREE_SPIN_INTERVAL, more via the SPIN_1/SPIN_10 products.
-- REWARDS is indexed by UI slice (Wheel.Spin.<i>); the client paints each
-- slice's label + chance from this table so the wheel can never lie about
-- its odds. weights sum to 100. kind:
--   money  grants amount (raw - a prize, not round earnings, so no boosts)
--   bull   grants bullId from BullCatalog; already owned -> consolation Money
--   box    opens one Config.BULLS.BOXES[boxId] free roll (dupe refunds like a
--          bought box) - the "lucky block" slice
--   spin   grants amount spins back (the "free respin" slice; no slice uses it
--          today but SpinService still supports it)
Config.SPINNER = {
	FREE_SPIN_INTERVAL = 12 * 3600,  -- a free spin banks twice a day
	VIP_SPIN_INTERVAL = 24 * 3600,   -- VIP pass: one EXTRA free spin banks every day (on top of the two above)
	SPIN_DURATION = 6,            -- seconds of wheel animation (classic decelerate)
	REWARDS = {
		{ kind = "bull",  bullId = "DIABLO", label = "El Diablo", weight = 4,  consolation = 300 },
		{ kind = "money", amount = 500, label = "$500",     weight = 8 },   -- biggest money win
		{ kind = "money", amount = 300, label = "$300",     weight = 18 },  -- medium money win 2
		{ kind = "box",   boxId = "MEGA", label = "Mega Box", weight = 10 },  -- lucky block: free Mega box roll
		{ kind = "money", amount = 75,  label = "$75",      weight = 30 },  -- small money
		{ kind = "money", amount = 150, label = "$150",     weight = 30 },  -- medium money 1
	},
}

-- ROBUX bull rolls (Store "Lucky Blocks" cards). Like the OP block
-- (Config.BULLS.OP_ROLL), buying one rolls a bull on the carousel from the tier's
-- own rarity `weights` (better than the Money BOXES) - NOT a wheel spin. Handled
-- by BullRollService (grantRolls); dupes refund `cost` x the rarity's dupeRefund
-- in Money. Tiers escalate Secret -> Alien -> GOD (pricier = rarer pool + higher
-- mutationChance). `price` is the Robux price the Store card shows (real charge is
-- the product). `color`/`tag`/`order` are card cosmetics; the marquee preview is
-- built from `weights` so it can't drift from what actually rolls.
Config.LUCKY_BLOCKS = {
	SECRET = {
		name = "Secret Block", tag = "Secret", order = 1,
		product = "LUCKY_SECRET", price = 25,
		color = Color3.fromRGB(170, 110, 255), -- amethyst
		cost = 3000, -- dupe refund basis (Robux-bought, no Money charged)
		weights = { UNCOMMON = 35, RARE = 42, EPIC = 20, LEGENDARY = 3 },
		mutationChance = 0.10,
	},
	ALIEN = {
		name = "Alien Block", tag = "Alien", order = 2,
		product = "LUCKY_ALIEN", price = 99,
		color = Color3.fromRGB(90, 230, 150), -- alien green
		cost = 6000,
		weights = { RARE = 45, EPIC = 42, LEGENDARY = 13 },
		mutationChance = 0.18,
	},
	GOD = {
		name = "GOD Block", tag = "GOD", order = 3,
		product = "LUCKY_GOD", price = 249,
		color = Color3.fromRGB(255, 205, 70), -- divine gold
		cost = 9000,
		weights = { RARE = 18, EPIC = 57, LEGENDARY = 25 },
		mutationChance = 0.25,
	},
}

-- Bull rolls: players buy LUCKY BOXES (Frames.Shop1 "Lucky Boxes" window);
-- each box is one roll of the shared BullCatalog with the box's own rarity
-- weights - pricier boxes skew harder toward the top tiers. Buying a box
-- immediately plays the roll reveal. Duplicate pulls refund
-- box.cost * rarity.dupeRefund Money. weights need not sum to 100 (they're
-- normalized), but keeping them at 100 makes the UI odds label obvious.
-- mutationChance: odds the pull ALSO lands a mutation (a cosmetic particle
-- aura, BullCatalog.Mutations - rarity weighted there) on the rolled bull.
-- Mutations stick to that bull forever, dupes included, so every dupe pull
-- is still a mutation lottery ticket.
Config.BULLS = {
	BOXES = {
		BASIC = {
			name = "Lucky Box", tag = "Basic", order = 1,
			cost = 300,           -- ~1 win of earnings
			color = Color3.fromRGB(205, 127, 50), -- bronze
			image = "rbxassetid://91683630954327", -- shop card art (fallback: BOX glyph)
			weights = { COMMON = 64, UNCOMMON = 25, RARE = 9, EPIC = 1.8, LEGENDARY = 0.2 },
			mutationChance = 0.08,
		},
		SUPER = {
			name = "Super Lucky Box", tag = "Super", order = 2,
			cost = 1000,          -- ~3-4 wins of earnings
			color = Color3.fromRGB(150, 190, 230), -- silver-blue
			image = "rbxassetid://112914675470468", -- shop card art (fallback: SUPER glyph)
			weights = { COMMON = 40, UNCOMMON = 31, RARE = 20, EPIC = 7, LEGENDARY = 2 },
			mutationChance = 0.14,
		},
		MEGA = {
			name = "Mega Lucky Box", tag = "Mega", order = 3,
			cost = 2500,          -- ~9 wins of earnings; the grind-target crate
			color = Color3.fromRGB(255, 190, 40), -- gold
			image = "rbxassetid://91208663021116", -- shop card art (fallback: MEGA glyph)
			weights = { COMMON = 16, UNCOMMON = 28, RARE = 31, EPIC = 18, LEGENDARY = 7 },
			mutationChance = 0.22,
		},
	},
	ROBUX_BOX = "MEGA",           -- Robux rolls (BULL_ROLL/BULL_ROLL_10) open this box

	-- OP Lucky Block: a ROBUX-only ELITE bull roll (Store "Exclusive" card). Every
	-- pull is Epic or Legendary - no commons/uncommons/rares in the pool - and the
	-- reveal reuses the bull carousel (BullRollService grants; not the wheel). The
	-- bundles map to the card's x1/x3/x10 buy buttons in order. cost = the dupe
	-- refund basis (Robux-bought, so no Money is charged); mutationChance is the
	-- richest in the game. See [[fortune-wheel]] tiers for the wheel-based blocks.
	OP_ROLL = {
		box = {
			name = "OP Bull", tag = "OP", color = Color3.fromRGB(255, 90, 210),
			cost = 10000,                          -- dupe refund basis only
			weights = { EPIC = 70, LEGENDARY = 30 }, -- elite pool: Epic or Legendary only
			mutationChance = 0.30,
		},
		bundles = { -- Exclusive-card buy buttons 1/2/3, in this order
			{ product = "OP_LUCKY",     count = 1 },
			{ product = "OP_LUCKY_X3",  count = 3 },
			{ product = "OP_LUCKY_X10", count = 10 },
		},
	},
}

-- Daily reward (Frames.Daily UI + the "Gifts" HUD button): a 7-day escalating
-- loop (DailyRewardService). A reward is ready CLAIM_COOLDOWN after the last
-- claim; claim within RESET_WINDOW of the last claim to keep the streak going,
-- else it resets to day 1 (one busy day won't punish you - RESET_WINDOW gives
-- a grace period past the cooldown). After day 7 the loop returns to day 1.
-- REWARDS is indexed by day (1-7); the client paints each day's tile from it,
-- so the UI can never lie about what a day gives. kind:
--   money  grants amount Money (raw - a gift, not round earnings, no boosts)
--   spin   grants amount banked fortune-wheel spins (SpinService's pool)
--   box    opens one Config.BULLS.BOXES[boxId] (a free bull roll); a duplicate
--          pull refunds box.cost * rarity.dupeRefund Money, same as a bought box
Config.DAILY = {
	CLAIM_COOLDOWN = 20 * 3600,   -- a reward is ready 20h after the last claim
	RESET_WINDOW = 48 * 3600,     -- claim within 48h of the last claim to keep the streak
	REWARDS = {                   -- day 1-7, then loops back to day 1
		{ day = 1, kind = "money", amount = 100,          label = "$100" },
		{ day = 2, kind = "money", amount = 200,          label = "$200" },
		{ day = 3, kind = "spin",  amount = 1,            label = "1 Spin" },
		{ day = 4, kind = "money", amount = 400,          label = "$400" },
		{ day = 5, kind = "spin",  amount = 2,            label = "2 Spins" },
		{ day = 6, kind = "money", amount = 800,          label = "$800" },
		{ day = 7, kind = "box",   boxId = "MEGA",        label = "Mega Box" },
	},
}

-- Revenge bulls: eliminated participants may send a bull down a lane of the
-- CURRENT window while the round is ACTIVE. Cooldown is server-enforced.
Config.REVENGE = {
	COOLDOWN = 15,                -- seconds between throws, per player
	MONEY_PER_HIT = 25,           -- paid to the thrower per alive player trampled
	TELEGRAPH = 1.2,              -- lane warning before the revenge bull launches
	SPEED = 50,                   -- studs/s, fixed (independent of the difficulty ramp)
}

-- Player-vs-player shove: PushClient puts a tap prompt over every other
-- player during ACTIVE rounds; PushService validates and the victim's own
-- client applies the burst (client-authoritative, same idiom as the dash).
Config.PUSH = {
	RANGE = 9,                    -- prompt reach in studs (server allows +6 slack)
	SPEED = 120,                  -- PEAK horizontal knockback at contact, studs/s; eases to 0 over TIME (dash is 56)
	UP = 40,                      -- initial upward pop velocity, studs/s; driven as a fast symmetric hop (see UP_TIME)
	UP_TIME = 0.24,               -- pop duration: Y ramps +UP -> -UP over this, so up AND down accel are snappy — no hang time
	TIME = 0.22,                  -- horizontal knockback window; short + sharp so it hits and ends, no drift tail
	HITSTOP = 0,                  -- freeze-frame at contact (0 = off); >0 anchors the victim briefly before the launch
	COOLDOWN = 4,                 -- seconds between shoves, per pusher
	KILL_CREDIT = 6,              -- a fall this soon after a shove credits the pusher
}

-- TESTING: fake players so multiplayer modes can be playtested alone. When
-- enabled, bots join every round, dodge telegraphs, and count toward mode
-- eligibility and team splits, but never touch saved player data. Rounds
-- still need at least one real player to start. TURN OFF BEFORE PUBLISHING.
Config.AI_PLAYERS = {
	ENABLED = false,
	COUNT = 5,
	DODGE_CHANCE = 0.8,            -- odds a bot reacts to a telegraph at all
	REACTION_TIME = { 0.25, 0.9 }, -- delay before a reacting bot starts moving
}

-- Shared shrink mechanics (FX timing + out-of-bounds rules). The per-round
-- shrink SCHEDULE (when stages fire, how many there are) lives on each mode.
Config.SHRINK = {
	TELEGRAPH = 3.0,              -- doomed tiles flash this long before dropping
	GRACE = 1.5,                  -- seconds a player may stand out of bounds before elimination
	SINK_DEPTH = 110,             -- pillars plunge this far; tops rest 90 below the grid, so the whole 80-stud column falls clear of the skyline
	SINK_TIME = 1.6,              -- pillar fall duration (quad ease-in; slower than true gravity for a readable crumble)
}

-- Base bull difficulty: intensity = min(elapsed / rampTime, 1), every
-- parameter lerps START -> FINAL. Modes may override rampTime and/or the
-- whole START/FINAL pair (see MODES below).
Config.DIFFICULTY = {
	RAMP_TIME = 90,
	-- speed starts 30% below FINAL and ramps up over RAMP_TIME (was 44).
	-- Smaller peak waves + shorter gaps than the old 4-bull/0.55s pulse, so bulls
	-- arrive as a steadier stream (WaveDirector also trickles each wave's bulls
	-- out over a launch window) rather than in distinct bursts.
	START = { telegraph = 1.4, gap = 1.0, speed = 31, bulls = 2 },
	FINAL = { telegraph = 0.9, gap = 0.35, speed = 62, bulls = 3 },
}

-- Game modes. Main picks one per round: weighted random among modes whose
-- minPlayers is met, never repeating the previous mode when it has a choice.
-- Fields:
--   startSize      side length of the starting window (odd, <= GRID_SIZE)
--   shrink.times   stage i fires at times[i] seconds into the round...
--   shrink.aliveFractions  ...OR when alive/starters <= aliveFractions[i],
--                  whichever comes first; #times = total shrink stages.
--                  Each stage peels one full outer ring (side length -2);
--                  ShrinkService caps stages so the window never dips below 3x3
--   rampTime       overrides DIFFICULTY.RAMP_TIME for this mode
--   difficulty     overrides DIFFICULTY.START/FINAL wholesale (optional)
--   moneyMult      round-earnings multiplier (harder modes pay more; default 1)
--   teams          split players into Red/Blue; the last team with a member
--                  standing wins as a group (every member gets the win)
--   gravity        workspace gravity for the round (default ~196; lower = floaty)
--   walkSpeed      participant WalkSpeed for the round (default 16; higher = zippy)
Config.MODES = {
	{
		id = "CLASSIC", name = "Classic", weight = 3, minPlayers = 1,
		startSize = 9,
		shrink = { times = { 40, 80 }, aliveFractions = { 0.6, 0.3 } },
		rampTime = 90,
	},
	{
		id = "MEGA", name = "Mega Grid", weight = 2, minPlayers = 1,
		startSize = 11,
		shrink = { times = { 30, 65, 100 }, aliveFractions = { 0.75, 0.5, 0.25 } },
		rampTime = 105,
		moneyMult = 1.1,
	},
	{
		id = "SMALL", name = "Small Grid", weight = 2, minPlayers = 1,
		startSize = 7,
		shrink = { times = { 35 }, aliveFractions = { 0.45 } },
		rampTime = 60,
		moneyMult = 1.15,
		difficulty = {
			START = { telegraph = 1.4, gap = 1.0, speed = 28, bulls = 2 },
			FINAL = { telegraph = 0.9, gap = 0.4, speed = 56, bulls = 3 },
		},
	},
	{
		id = "STAMPEDE", name = "Stampede", weight = 2, minPlayers = 1,
		startSize = 9,
		shrink = { times = { 40, 80 }, aliveFractions = { 0.6, 0.3 } },
		rampTime = 75,
		moneyMult = 1.25,
		difficulty = {
			START = { telegraph = 1.4, gap = 1.1, speed = 31, bulls = 2 },
			FINAL = { telegraph = 0.85, gap = 0.3, speed = 62, bulls = 4 },
		},
	},
	{
		id = "TEAMS", name = "Team Rush", weight = 2, minPlayers = 2,
		teams = true,
		startSize = 9,
		shrink = { times = { 40, 80 }, aliveFractions = { 0.6, 0.3 } },
		rampTime = 90,
	},
	{
		id = "LOWGRAV", name = "Low Gravity", weight = 2, minPlayers = 1,
		startSize = 9,
		shrink = { times = { 40, 80 }, aliveFractions = { 0.6, 0.3 } },
		rampTime = 90,
		gravity = 45,                 -- floaty moon-jumps; default is ~196
		moneyMult = 1.15,
	},
	{
		id = "HIGHSPEED", name = "High Speed", weight = 2, minPlayers = 1,
		startSize = 9,
		shrink = { times = { 40, 80 }, aliveFractions = { 0.6, 0.3 } },
		rampTime = 90,
		walkSpeed = 32,               -- players sprint at 2x (default 16)
		moneyMult = 1.2,
		difficulty = {                -- bulls charge faster too, to keep the twitch
			START = { telegraph = 1.15, gap = 0.85, speed = 40, bulls = 2 },
			FINAL = { telegraph = 0.75, gap = 0.3, speed = 80, bulls = 3 },
		},
	},
}

-- Lobby "Update" notice board (Workspace.Update). The board shows the next
-- upcoming Roblox Experience Event (SocialService.GetUpcomingExperienceEventsAsync)
-- and clicking it opens the native RSVP / "notify me" prompt. When no event is
-- scheduled (e.g. before the place is published, or between events) the board
-- falls back to this promo card and clicks open the friend-invite flow instead.
Config.EVENTS_BOARD = {
	HEADLINE = "STAY IN THE LOOP",        -- big centered text on the fallback card
	CTA = "INVITE FRIENDS",               -- fallback button label
	REFRESH_SECONDS = 120,                -- how often to re-fetch the event list
}

-- Shared rarity/tier text gradient: a lit top edge -> saturated middle -> shaded
-- baseline, built from any rarity's base colour so every rarity label matches.
-- Assign the result to a UIGradient's .Color (use Rotation 90 for top -> bottom).
do
	local PAPER = Color3.fromRGB(255, 255, 255)
	local INK = Color3.fromRGB(15, 15, 15)
	function Config.rarityGradient(col)
		return ColorSequence.new({
			ColorSequenceKeypoint.new(0, col:Lerp(PAPER, 0.55)),
			ColorSequenceKeypoint.new(0.45, col),
			ColorSequenceKeypoint.new(1, col:Lerp(INK, 0.5)),
		})
	end
end

return Config
