local Config = {}

-- Physical arena: a 9x9 tile grid (Tile_1_1 .. Tile_9_9). Every MODE plays in
-- a centered square WINDOW of that grid (mode.startSize); tiles outside the
-- window start the round already sunken. The window then shrinks during the
-- round per the mode's schedule.
Config.GRID_SIZE = 9
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
-- ProcessReceipt leaves unknown products untouched.
Config.PRODUCTS = {
	DOUBLE_ROUND = 0,             -- Summary tab "2x Rewards?": doubles that round's payout
	BULL_ROLL = 0,                -- 1 bull roll for Robux (BullRollService)
	BULL_ROLL_10 = 0,             -- 10 bull rolls for Robux
	SPIN_1 = 0,                   -- 1 fortune-wheel spin (SpinService); UI prices it 99 R$
	SPIN_10 = 0,                  -- 10 fortune-wheel spins; UI prices it 699 R$
}

-- Fortune wheel (Frames.Spinner UI + the lobby wheel model): one free spin
-- banked every FREE_SPIN_INTERVAL, more via the SPIN_1/SPIN_10 products.
-- REWARDS is indexed by UI slice (Wheel.Spin.<i>); the client paints each
-- slice's label + chance from this table so the wheel can never lie about
-- its odds. weights sum to 100. kind:
--   money  grants amount (raw - a prize, not round earnings, so no boosts)
--   bull   grants bullId from BullCatalog; already owned -> consolation Money
--   spin   grants amount spins back (the "free respin" slice)
Config.SPINNER = {
	FREE_SPIN_INTERVAL = 12 * 3600,  -- a free spin banks twice a day
	SPIN_DURATION = 6,            -- seconds of wheel animation (classic decelerate)
	REWARDS = {
		{ kind = "bull",  bullId = "LA_VACCA", label = "La Vacca", weight = 4, consolation = 400 },
		{ kind = "money", amount = 100,  label = "+100",     weight = 30 },
		{ kind = "money", amount = 250,  label = "+250",     weight = 22 },
		{ kind = "money", amount = 2000, label = "JACKPOT",  weight = 5 },
		{ kind = "spin",  amount = 1,    label = "+1 Spin",  weight = 15 },
		{ kind = "money", amount = 500,  label = "+500",     weight = 24 },
	},
}

-- Bull rolls: players buy LUCKY BOXES (Frames.Shop1 "Lucky Boxes" window);
-- each box is one roll of the shared BullCatalog with the box's own rarity
-- weights - pricier boxes skew harder toward the top tiers. Buying a box
-- immediately plays the roll reveal. Duplicate pulls refund
-- box.cost * rarity.dupeRefund Money. weights need not sum to 100 (they're
-- normalized), but keeping them at 100 makes the UI odds label obvious.
Config.BULLS = {
	BOXES = {
		BASIC = {
			name = "Lucky Box", tag = "Basic", order = 1,
			cost = 150,           -- ~1-2 rounds of earnings
			color = Color3.fromRGB(205, 127, 50), -- bronze
			weights = { COMMON = 64, UNCOMMON = 25, RARE = 9, EPIC = 1.8, LEGENDARY = 0.2 },
		},
		SUPER = {
			name = "Super Lucky Box", tag = "Super", order = 2,
			cost = 450,
			color = Color3.fromRGB(150, 190, 230), -- silver-blue
			weights = { COMMON = 40, UNCOMMON = 31, RARE = 20, EPIC = 7, LEGENDARY = 2 },
		},
		MEGA = {
			name = "Mega Lucky Box", tag = "Mega", order = 3,
			cost = 1200,
			color = Color3.fromRGB(255, 190, 40), -- gold
			weights = { COMMON = 16, UNCOMMON = 28, RARE = 31, EPIC = 18, LEGENDARY = 7 },
		},
	},
	ROBUX_BOX = "MEGA",           -- Robux rolls (BULL_ROLL/BULL_ROLL_10) open this box
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
	SPEED = 48,                   -- horizontal knockback, studs/s (dash is 56)
	UP = 14,                      -- upward pop so the victim briefly loses footing
	TIME = 0.2,                   -- burst hold; ~10 studs, a bit over one tile
	COOLDOWN = 4,                 -- seconds between shoves, per pusher
}

-- TESTING: fake players so multiplayer modes can be playtested alone. When
-- enabled, bots join every round, dodge telegraphs, and count toward mode
-- eligibility and team splits, but never touch saved player data. Rounds
-- still need at least one real player to start. TURN OFF BEFORE PUBLISHING.
Config.AI_PLAYERS = {
	ENABLED = true,
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
	START = { telegraph = 1.4, gap = 1.3, speed = 44, bulls = 2 },
	FINAL = { telegraph = 0.9, gap = 0.55, speed = 62, bulls = 4 },
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
Config.MODES = {
	{
		id = "CLASSIC", name = "Classic", weight = 3, minPlayers = 1,
		startSize = 7,
		shrink = { times = { 40, 80 }, aliveFractions = { 0.6, 0.3 } },
		rampTime = 90,
	},
	{
		id = "MEGA", name = "Mega Grid", weight = 2, minPlayers = 1,
		startSize = 9,
		shrink = { times = { 30, 65, 100 }, aliveFractions = { 0.75, 0.5, 0.25 } },
		rampTime = 105,
		moneyMult = 1.1,
	},
	{
		id = "SMALL", name = "Small Grid", weight = 2, minPlayers = 1,
		startSize = 5,
		shrink = { times = { 35 }, aliveFractions = { 0.45 } },
		rampTime = 60,
		moneyMult = 1.15,
		difficulty = {
			START = { telegraph = 1.4, gap = 1.3, speed = 40, bulls = 2 },
			FINAL = { telegraph = 0.9, gap = 0.55, speed = 56, bulls = 3 },
		},
	},
	{
		id = "STAMPEDE", name = "Stampede", weight = 2, minPlayers = 1,
		startSize = 7,
		shrink = { times = { 40, 80 }, aliveFractions = { 0.6, 0.3 } },
		rampTime = 75,
		moneyMult = 1.25,
		difficulty = {
			START = { telegraph = 1.4, gap = 1.4, speed = 44, bulls = 2 },
			FINAL = { telegraph = 0.85, gap = 0.5, speed = 62, bulls = 5 },
		},
	},
	{
		id = "TEAMS", name = "Team Rush", weight = 2, minPlayers = 2,
		teams = true,
		startSize = 7,
		shrink = { times = { 40, 80 }, aliveFractions = { 0.6, 0.3 } },
		rampTime = 90,
	},
}

return Config
