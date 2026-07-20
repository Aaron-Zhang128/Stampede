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

-- Canonical tile palette, shared by ShrinkService (server repaints) and
-- BullrushClient (danger pulse / restore tweens). The client must DERIVE a
-- tile's at-rest color from the checkerboard formula — never sample part.Color
-- at join time, because a mid-round joiner samples sunken tiles as charcoal
-- and then every post-charge restore paints that charcoal back onto live tiles.
Config.TILE_CHECKER_LIGHT = Color3.fromRGB(214, 182, 133) -- (row + col) even
Config.TILE_CHECKER_DARK = Color3.fromRGB(188, 152, 102) -- (row + col) odd
Config.TILE_CHARCOAL = Color3.fromRGB(55, 48, 42) -- dropped/sunken tiles

Config.BULL_RIDE_HEIGHT = 2.5     -- bull Root center height above tile surface
Config.BULL_OVERSHOOT = 12        -- studs beyond the active window edge where bulls spawn and exit
-- Kill box half-extents = HALF of the BullTemplate model's true bounding box, so
-- the hitbox matches the bull players SEE (measured in Studio, oriented to travel:
-- 9.83 nose-to-tail x 5.21 side-to-side x 8.68 tall). Re-measure and update these
-- if the bull model is resized. (Skinned revenge/special bulls can differ in size;
-- the box tracks the standard bull, not each skin.)
Config.BULL_HIT_HALF_LENGTH = 4.9 -- kill box half-length along the travel axis (nose-to-tail 9.83 / 2)
Config.BULL_HIT_HALF_WIDTH = 2.6  -- kill box half-width across the lane (side-to-side 5.21 / 2)
-- Half-HEIGHT (= bull height 8.68 / 2) doubles as the JUMP-OVER gap: the box is
-- centered on the charge line (tile surface + BULL_RIDE_HEIGHT = 22.5), so its top
-- is ~26.85 (the bull's own top). A standing root sits ~0.5 above the line so
-- walkers are always caught, but a default jump lifts the root ~7 studs (apex
-- ~7.5 above the line), clearing the box for the upper stretch of the hop.
Config.BULL_HIT_HALF_HEIGHT = 4.34

Config.MIN_PLAYERS = 2            -- matches need 2+ players; a lone player waits in the lobby (practice arena is always open)
-- Studio-only solo rounds (testing): a lone playtester starts a round instead
-- of sitting in WAITING. Live is unaffected (IsStudio gate). Drop the `false and`
-- to re-enable solo Studio rounds.
if false and game:GetService("RunService"):IsStudio() then
	Config.MIN_PLAYERS = 1
end
Config.INTERMISSION_TIME = 15
Config.START_DELAY = 5            -- seconds players stand on the field after teleport before the round begins
Config.MONEY_PER_WIN = 100

-- Money paid when your ABILITY causes an elimination (its hit is credited with the
-- victim's death within Config.PUSH.KILL_CREDIT seconds). This is the ONLY money
-- abilities earn now — simply LANDING a hit (push/bomb/freeze/shock/mine) pays
-- nothing. Applies to every ability; paid in RoundService.eliminate (face value,
-- friend/pass boosts apply on top).
Config.ABILITY_KILL_REWARD = 30

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
	-- Lucky Blocks (Store LuckyBlocks cards): ROBUX BULL ROLLS - each buy rolls
	-- one bull from its tier's own rarity pool (Config.LUCKY_BLOCKS), revealed
	-- on the bull carousel - NOT a wheel spin. Handled by BullRollService.
	-- Mapped by PRICE (the product names on Roblox differ from our tier names).
	LUCKY_SECRET = 3609137453,    -- "Lucky Block" (20 R$)  -> Secret tier
	LUCKY_ALIEN = 3609137528,     -- "Lucky Secret" (80 R$) -> Alien tier
	LUCKY_GOD = 3609137618,       -- "Lucky God" (200 R$)   -> GOD tier
	-- OP Lucky Block: ROBUX powerup rolls revealed through the shared carousel.
	-- X3/X10 award 3/10 powerups; duplicate ownership refunds in-game Money.
	OP_LUCKY = 3609162473,        -- "OP Lucky Block" (99 R$)      -> 1 powerup roll
	OP_LUCKY_X3 = 3609162516,     -- "OP Lucky Block X3" (249 R$)  -> 3 powerup rolls
	OP_LUCKY_X10 = 3609162604,    -- "OP Lucky Block X10" (699 R$) -> 10 powerup rolls
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
	-- First-spin dragon teaser (Main.client §10 emblem + SpinService rig): a
	-- glowing "???" dragon rides the dial at a slice BOUNDARY, so a spin can rest
	-- right beside it but never ON it (it is not a reward slice). A brand-new
	-- player's very first spin is rigged to land on `landIndex` so the emblem
	-- comes to rest next to the pointer -- a curiosity-sparking near-miss. Purely
	-- a tease: the dragon exists nowhere else in the game.
	DRAGON = {
		boundaryRotation = 90, -- dial-local angle of the emblem (boundary between slice 2 and slice 3)
		landIndex = 2,         -- first-ever spin lands on this slice (the one beside the emblem)
		landJitter = 0,        -- where in that slice the arrow rests (0 = dead-centre on the win, emblem one wedge over)
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
-- MUTATIONS_ENABLED (2026-07-13): mutations are OUT of the game for now.
-- false = every roll skips the mutation lottery (BullRollService gates on
-- this; the per-box mutationChance values below are kept as tuning for the
-- re-enable). Already-owned auras still render (Index tags, worn-bull VFX).
Config.BULLS = {
	MUTATIONS_ENABLED = false,
	BOXES = {
		BASIC = {
			name = "Common Egg", tag = "Basic", order = 1,
			cost = 300,           -- ~1 win of earnings
			color = Color3.fromRGB(205, 127, 50), -- bronze
			image = "rbxassetid://91683630954327", -- shop card art (fallback: BOX glyph)
			weights = { COMMON = 64, UNCOMMON = 25, RARE = 9, EPIC = 1.8, LEGENDARY = 0.2 },
			mutationChance = 0.08,
		},
		SUPER = {
			name = "Lava Egg", tag = "Super", order = 2,
			cost = 1000,          -- ~3-4 wins of earnings
			color = Color3.fromRGB(150, 190, 230), -- silver-blue
			image = "rbxassetid://112914675470468", -- shop card art (fallback: SUPER glyph)
			weights = { COMMON = 40, UNCOMMON = 31, RARE = 20, EPIC = 7, LEGENDARY = 2 },
			mutationChance = 0.14,
		},
		MEGA = {
			name = "Galaxy Egg", tag = "Mega", order = 3,
			cost = 2500,          -- ~9 wins of earnings; the grind-target crate
			color = Color3.fromRGB(255, 190, 40), -- gold
			image = "rbxassetid://91208663021116", -- shop card art (fallback: MEGA glyph)
			weights = { COMMON = 16, UNCOMMON = 28, RARE = 31, EPIC = 18, LEGENDARY = 7 },
			mutationChance = 0.22,
		},
	},
	ROBUX_BOX = "MEGA",           -- Robux rolls (BULL_ROLL/BULL_ROLL_10) open this box

	-- OP Lucky Block: a ROBUX-only POWERUP roll (Store "Exclusive" card). The
	-- reveal reuses the existing roll carousel. A new pull permanently unlocks the
	-- ability; a duplicate refunds that ability's normal in-game shop price.
	OP_ROLL = {
		powerups = {
			{ key = "FreezePunch", name = "Freeze Punch", rarity = "RARE",      weight = 24 },
			{ key = "FastPunch",   name = "Fast Punch",   rarity = "UNCOMMON",  weight = 24 },
			{ key = "Bomb",        name = "Bomb",         rarity = "UNCOMMON",  weight = 22 },
			{ key = "ExtraLives",  name = "Extra Lives",  rarity = "EPIC",      weight = 15 },
			{ key = "Mine",        name = "Mine",         rarity = "EPIC",      weight = 10 },
			{ key = "Shockwave",   name = "Shockwave",    rarity = "LEGENDARY", weight = 5 },
		},
		bundles = { -- Exclusive-card buy buttons 1/2/3, in this order
			{ product = "OP_LUCKY",     count = 1 },
			{ product = "OP_LUCKY_X3",  count = 3 },
			{ product = "OP_LUCKY_X10", count = 10 },
		},
	},
}

-- Community reward: a ONE-TIME free roll for liking + joining the Roblox group.
-- The "Like and Join the community" panel (Main.client) claims it; the server
-- (BullRollService) verifies group membership via Player:IsInGroup before it
-- grants one free roll of REWARD_BOX (a Config.LUCKY_BLOCKS tier) and flips the
-- persisted GroupRewardClaimed flag. In Studio the membership check is bypassed
-- and the claim is NOT persisted, so the flow stays re-testable (never leaks live).
Config.COMMUNITY = {
	GROUP_ID = 111761595,      -- the Roblox community group players must join to claim
	REWARD_BOX = "SECRET",     -- one free roll of this Config.LUCKY_BLOCKS tier on claim
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
	CLAIM_COOLDOWN = 24 * 3600,   -- a reward is ready 24h after the last claim
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

-- Player levels (LevelService): 10 levels fed by GAMEPLAY money - every grant
-- through RoundService.awardMoney adds its PRE-multiplier amount as XP
-- (XP_PER_MONEY per $1), so boosts/passes scale the money but never the curve,
-- and purchases/gifts (money packs, wheel, daily, dupe refunds) give no XP.
-- XP_TO_NEXT[n] = XP to climb from level n to n+1 (XP resets each level-up; a
-- win banks ~250 XP, a mid-round loss ~30-60, so level 2 lands in the first
-- session and level 10 is a long grind). REWARDS[n] lands the moment level n
-- is reached: money is a RAW gift (no boosts, no XP back); a box BANKS a free
-- opening in FreeBoxRolls (the shop card flips to FREE, same bank as the
-- new-player BASIC gift). label doubles as the level-up card text. The client
-- XP bar (Main section 17) renders level/progress off the Level/XP attributes
-- plus this table.
Config.LEVELS = {
	MAX_LEVEL = 10,
	XP_PER_MONEY = 1,             -- XP per $1 of pre-multiplier gameplay money
	XP_TO_NEXT = { 100, 250, 500, 900, 1400, 2000, 2800, 3800, 5000 },
	REWARDS = {
		[2] = { kind = "money", amount = 150, label = "+$150" },
		[3] = { kind = "box", boxId = "BASIC", label = "Free Lucky Box!" },
		[4] = { kind = "money", amount = 300, label = "+$300" },
		[5] = { kind = "box", boxId = "SUPER", label = "Free Super Box!" },
		[6] = { kind = "money", amount = 500, label = "+$500" },
		[7] = { kind = "box", boxId = "SUPER", label = "Free Super Box!" },
		[8] = { kind = "money", amount = 800, label = "+$800" },
		[9] = { kind = "box", boxId = "MEGA", label = "Free Mega Box!" },
		[10] = { kind = "box", boxId = "MEGA", label = "Free Mega Box!" },
	},
}

-- Revenge bulls: eliminated participants may send a bull down a lane of the
-- CURRENT window while the round is ACTIVE. Cooldown is server-enforced.
Config.REVENGE = {
	COOLDOWN = 10,                -- seconds between throws, per player
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
	UP = 40,                      -- initial upward pop velocity, studs/s; ramps toward -UP over UP_TIME
	UP_TIME = 0.4,                -- pop duration: Y ramps +UP -> -UP over this. At 0.4 the decel (2*UP/UP_TIME = 200) ~= gravity, and TIME cuts the drive just past apex, so victims float a real arc (~4 studs, ~0.4s air) instead of the old 0.24 snap-down
	TIME = 0.22,                  -- horizontal knockback window; short + sharp so it hits and ends, no drift tail
	HITSTOP = 0,                  -- freeze-frame at contact (0 = off); >0 anchors the victim briefly before the launch
	COOLDOWN = 4,                 -- seconds between shoves, per pusher
	KILL_CREDIT = 6,              -- a fall this soon after a shove credits the pusher
	MONEY_PER_HIT = 10,           -- Money paid to the pusher for every landed shove (PushService; face value + friend/pass boosts, shown on the Summary tab). The COOLDOWN caps the earn rate.
}

--==============================================================================
-- New abilities (2026-07-14). Each is self-contained (its own service + client
-- + this config block), modelled on Push. They're BUILT but not yet wired into
-- an equip / HUD-button system — see each service's header for the hooks.
--==============================================================================

-- Extra Lives: a PASSIVE buff. While it's granted, a player carries HEARTS lives
-- shown as a heart row over their head; a lethal hit spends a heart and revives
-- them, and only the last heart is their final life. ExtraLivesService owns the
-- hearts + the consume() hook you call from the elimination path.
Config.EXTRA_LIVES = {
	HEARTS = 2,                   -- total lives shown (survive HEARTS-1 lethal hits before you're out)
	HEART_IMAGE = "rbxassetid://71758683165076", -- overhead heart icon (the uploaded 2-Lives art); lit for a life in hand, dimmed when spent
	HEART_EMOJI = "❤️",           -- (legacy) a life still in hand
	LOST_EMOJI = "🤍",            -- (legacy) a spent life
	REVIVE_IFRAMES = 1.5,         -- seconds of forcefield shimmer after a heart is spent
	FLING_RECOVER = 1.3,          -- seconds a survivor stays ragdolled after a bull hit before standing up
}

-- Bomb: THROW a lobbed bomb that arcs where you're aiming and, on its fuse,
-- blasts everyone nearby AWAY from the blast. Real players get the burst applied
-- on their own client (client-authoritative, like Push); bots are server-driven.
-- SPEED/UP/UP_TIME/TIME mirror the Push knockback curve (see Config.PUSH).
Config.BOMB = {
	COOLDOWN = 8,                 -- seconds between throws, per player
	THROW_SPEED = 60,             -- initial forward speed of the lobbed bomb, studs/s
	THROW_UP = 24,                -- initial upward speed: a slight arc, not a high lob
	STICK_FUSE = 0.5,             -- seconds from STICKING to a target to the blast (semtex)
	FUSE = 1.4,                   -- last-resort cap: blow it if it never sticks (lobbed into the void)
	RADIUS = 22,                  -- blast reach in studs
	SPEED = 130,                  -- PEAK outward knockback at the blast, studs/s; eases to 0 over TIME
	UP = 55,                      -- upward pop velocity at the blast, studs/s
	UP_TIME = 0.45,               -- pop duration (Y ramps +UP -> -UP; decel ~ gravity for hang time)
	TIME = 0.28,                  -- horizontal knockback window, seconds
}

-- Speed Boost: a burst of extra WalkSpeed for a few seconds with speed-line
-- trails. Server-owned (it drives WalkSpeed) so the buff is real for physics and
-- everyone sees the trails. Restores to the WalkSpeed captured at activation.
Config.SPEED_BOOST = {
	COOLDOWN = 10,                -- seconds between activations, per player
	MULT = 1.8,                   -- WalkSpeed multiplier while active
	DURATION = 4,                 -- seconds the boost lasts
}

-- Shockwave: SLAM the ground and RAGDOLL every OTHER player within RADIUS for
-- RAGDOLL_TIME seconds, then they get back up on their own — a NON-lethal
-- knockdown (unlike the bull's lethal fling). Self-centered AoE, no aim. Real
-- players ragdoll on their own client (RagdollUtil keeps the assembly intact so
-- network ownership holds); bots are server-driven.
Config.SHOCKWAVE = {
	COOLDOWN = 20,                -- seconds between slams, per player (wind-down doubled 2026-07-15)
	RADIUS = 13,                  -- knockdown reach in studs (halved 2026-07-15)
	RAGDOLL_TIME = 2.5,           -- seconds a caught player stays down before standing up (halved 2026-07-15)
	UP = 26,                      -- small upward pop at the slam so the knockdown reads
}

-- Freeze Punch: a melee punch (Push's nearest-target reach) that FREEZES the
-- victim solid for FREEZE_TIME seconds instead of launching them — locked in
-- place inside an ice block, then released. Server-authoritative (WalkSpeed +
-- anchored root, like SpeedBoost owns WalkSpeed).
Config.FREEZE_PUNCH = {
	RANGE = 9,                    -- punch reach in studs (matches Push's prompt range)
	FREEZE_TIME = 2,              -- seconds the victim is frozen in place
	COOLDOWN = 4,                 -- seconds between punches, per puncher
}

-- Fast Punch: a Push VARIANT — the exact same shove, but the cooldown is HALVED so
-- you punch twice as often. Reuses PushService / PushClient / Config.PUSH; this block
-- only carries the cooldown multiplier those two apply when Fast Punch is equipped.
Config.FAST_PUNCH = {
	MULT = 0.5,                   -- punch cooldown multiplier vs PUSH.COOLDOWN (0.5 = twice as fast)
}

-- Mine: DROP a stationary mine at your feet. When another living player steps on it
-- (after a short arm delay) it EXPLODES and RAGDOLLS everyone within RADIUS for
-- RAGDOLL_TIME — a NON-lethal knockdown (they get back up; they stay ALIVE). Folded
-- into BombService / BombClient (spawn-a-part + explosion); ragdoll via RagdollUtil.
Config.MINE = {
	COOLDOWN = 6,                 -- seconds between drops, per player
	ARM_DELAY = 0.6,              -- seconds before a fresh mine can trigger (so you don't pop it walking off)
	LIFETIME = 30,                -- seconds a mine sits armed before it fizzles
	RADIUS = 12,                  -- blast reach in studs (everyone within is ragdolled)
	RAGDOLL_TIME = 2.5,           -- seconds a caught player stays down before standing back up
	KNOCK = 22,                   -- outward launch speed at the blast, studs/s
	UP = 45,                      -- upward pop at the blast so the ragdoll launches
}

-- Ability shop: the lobby shop sells ABILITIES for in-game Money (not bull rolls).
-- Purchases are PERMANENT (saved to OwnedAbilities). Every ROTATION_SECONDS the
-- shop features a fresh SERVER-WIDE set of FEATURED_COUNT abilities from the roster
-- below — you can only buy what's currently featured (AbilityShopService owns the
-- rotation + purchase). Push and Speed aren't sold; they're the free defaults
-- everyone starts with (so the round picker always has a choice).
Config.ABILITY_SHOP = {
	ROTATION_SECONDS = 300,       -- featured set rotates every 5 minutes, server-wide
	FEATURED_COUNT = 3,           -- abilities on sale each rotation
	-- First-timers get this ability FREE from a pinned slot-1 card in the shop (the
	-- tutorial's step-2 claim). Badged STARTER_RARITY on that free card only; its
	-- normal rotation entry keeps its own price. Kept in step with AbilityShopService
	-- (grant + eligibility) and Main.client (the free card + the tutorial arrow).
	STARTER_FREE = "FastPunch",
	STARTER_RARITY = "UNCOMMON",
	-- Money price per ability (roster = the keys here; tune freely).
	-- Prices roughly halved 2026-07-15 (user "make the abilities more affordable"):
	-- a solid round nets ~$100-200, so these land at ~3-6 rounds each instead of 5-20.
	PRICES = {
		FreezePunch = 500,
		FastPunch = 750,
		Bomb = 900,
		ExtraLives = 1400,
		Mine = 1500,
		Shockwave = 1750,
	},
	-- Card order in the shop / rotation roster (also the display order).
	ORDER = { "Bomb", "Shockwave", "FreezePunch", "FastPunch", "Mine", "ExtraLives" },
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
-- Studio-only: bots fill every round so solo playtests have company (and the
-- round stays ACTIVE after the tester dies, which the tutorial's spectate/send
-- step needs). Live never spawns bots (IsStudio gate) — no publish-time toggle
-- to forget. Drop the `false and` to re-enable bots for solo testing.
if false and game:GetService("RunService"):IsStudio() then
	Config.AI_PLAYERS.ENABLED = true
end

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
	RAMP_TIME = 157, -- 2026-07-12: ramps stretched another ~40% (25% pass was 112; original 90)

	-- 2026-07-13 "mid game a bit easier" pass (target: ~2.5 min rounds): Main
	-- raises the round's 0..1 ramp progress to this power, bowing the line
	-- downward. The widest dip lands mid-round (~10 intensity points around 40%
	-- in: slower bulls, roomier telegraphs/gaps), the opening moves only a hair,
	-- and FINAL still lands at rampTime with the same bite. 1 = old linear ramp.
	CURVE = 1.35,

	-- Gentle opening, eased ~40% further 2026-07-12 (was telegraph 1.7 / gap 1.4 /
	-- speed 24; original pre-easing: 1.4 / 1.0 / 31 / bulls 2): rounds start with a
	-- single slow, well-telegraphed bull so new players can learn the dodge before
	-- pressure builds; FINAL keeps the same late-round bite.
	-- Smaller peak waves + shorter gaps than the old 4-bull/0.55s pulse, so bulls
	-- arrive as a steadier stream (WaveDirector also trickles each wave's bulls
	-- out over a launch window) rather than in distinct bursts.
	START = { telegraph = 2.4, gap = 2.0, speed = 17, bulls = 1 },
	FINAL = { telegraph = 0.9, gap = 0.35, speed = 62, bulls = 3 },
}

-- Special bulls: rare cameo charges by NAMED catalog bulls inside normal waves
-- (Main.maybeSpecialBull). Sometimes a wave bull launches as a RARE/EPIC/
-- LEGENDARY bull from BullCatalog — rarity glow + name tag on the model, a
-- live tease of what the lucky boxes can drop (no broadcast card; ANNOUNCE
-- lists any rarities that should still get one).
-- Speed stays RELATIVE to the round: the special multiplies the wave's CURRENT
-- ramped speed by its rarity's SPEED_MULT, so an early-round legendary reads
-- fast-for-now instead of endgame-fast. Multipliers are deliberately big -
-- a special has to VISIBLY outrun the plain bulls beside it or the cameo
-- doesn't register (x1.15-1.45 didn't read in play).
Config.SPECIAL_BULLS = {
	ENABLED = true,
	CHANCE = 0.08,            -- odds per launched wave bull (after the interval gate)
	MIN_INTERVAL = 20,        -- server-wide seconds between specials, so they stay an event
	WEIGHTS = { RARE = 60, EPIC = 30, LEGENDARY = 10 }, -- rarity split among specials
	SPEED_MULT = { RARE = 1.3, EPIC = 1.5, LEGENDARY = 1.7 }, -- x the wave's current speed
	ANNOUNCE = {}, -- no broadcast cards; specials read via glow + name tag alone
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
--   holeLines      { rows = {..}?, cols = {..}?, invert = boolean? } of absolute
--                  grid indices. Normal (Hashtag's #): the listed rows/cols are
--                  permanent lethal TRENCHES, the rest is solid. invert = true
--                  (Reverse Hashtag): the pattern flips — the listed rows/cols
--                  are the ONLY solid ground (thin # walkways) and every other
--                  tile is a pit. Either way bulls never run a lane over holes;
--                  falling into a hole eliminates like the arena edge (see
--                  GridUtil.isHole / isLaneBlocked)
-- 2026-07-13 easing pass: shrink times pushed ~5-10s later (more room mid-round)
-- and the outlier rampTimes pulled toward the base 157 so every mode's FINAL
-- lands near the ~2.5-minute round target.
Config.MODES = {
	{
		id = "CLASSIC", name = "Classic", weight = 3, minPlayers = 1,
		startSize = 9,
		shrink = { times = { 45, 90 }, aliveFractions = { 0.6, 0.3 } },
		rampTime = 157,
	},
	{
		id = "MEGA", name = "Mega Grid", weight = 2, minPlayers = 1,
		startSize = 11,
		shrink = { times = { 35, 72, 110 }, aliveFractions = { 0.75, 0.5, 0.25 } },
		rampTime = 170,
		moneyMult = 1.1,
		-- The big 11x11 grid gets MORE bulls than the default (1->3) so the extra
		-- room plays HARDER, not emptier (2026-07-15, user request). telegraph/gap/
		-- speed match the default curve — only the bull COUNT is raised (2 -> 6).
		difficulty = {
			START = { telegraph = 2.4, gap = 2.0, speed = 17, bulls = 2 },
			FINAL = { telegraph = 0.9, gap = 0.35, speed = 62, bulls = 6 },
		},
	},
	{
		id = "SMALL", name = "Small Grid", weight = 2, minPlayers = 1,
		startSize = 7,
		shrink = { times = { 40 }, aliveFractions = { 0.45 } },
		rampTime = 125,
		moneyMult = 1.15,
		difficulty = {
			START = { telegraph = 2.4, gap = 2.0, speed = 16, bulls = 1 },
			FINAL = { telegraph = 0.9, gap = 0.4, speed = 56, bulls = 3 },
		},
	},
	{
		id = "STAMPEDE", name = "Stampede", weight = 2, minPlayers = 1,
		startSize = 9,
		shrink = { times = { 45, 90 }, aliveFractions = { 0.6, 0.3 } },
		rampTime = 145,
		moneyMult = 1.25,
		difficulty = {
			START = { telegraph = 2.4, gap = 2.0, speed = 17, bulls = 1 },
			FINAL = { telegraph = 0.85, gap = 0.3, speed = 62, bulls = 4 },
		},
	},
	-- Team Rush disabled for now; uncomment to restore.
	-- {
	-- 	id = "TEAMS", name = "Team Rush", weight = 2, minPlayers = 2,
	-- 	teams = true,
	-- 	startSize = 9,
	-- 	shrink = { times = { 40, 80 }, aliveFractions = { 0.6, 0.3 } },
	-- 	rampTime = 90,
	-- },
	{
		id = "LOWGRAV", name = "Low Gravity", weight = 2, minPlayers = 1,
		startSize = 9,
		shrink = { times = { 45, 90 }, aliveFractions = { 0.6, 0.3 } },
		rampTime = 157,
		gravity = 45,                 -- floaty moon-jumps; default is ~196
		moneyMult = 1.15,
	},
	{
		id = "HIGHSPEED", name = "High Speed", weight = 2, minPlayers = 1,
		startSize = 9,
		shrink = { times = { 45, 90 }, aliveFractions = { 0.6, 0.3 } },
		rampTime = 157,
		walkSpeed = 32,               -- players sprint at 2x (default 16)
		speedBoostMult = 2.5,         -- Speed ABILITY boosts harder here (vs default SPEED_BOOST.MULT 1.8)
		moneyMult = 1.2,
		difficulty = {                -- bulls charge faster too, to keep the twitch
			START = { telegraph = 2.0, gap = 1.7, speed = 23, bulls = 1 },
			FINAL = { telegraph = 0.75, gap = 0.3, speed = 80, bulls = 3 },
		},
	},
	{
		-- Hashtag (#): the full 11x11 window with two trench ROWS and two trench
		-- COLS carved out (holeLines 4 & 8), splitting the arena into nine 3x3
		-- rooms like a tic-tac-toe board. The trenches are lethal — fall in and
		-- you're out of bounds. Bulls only charge the SOLID lanes (never a full
		-- trench), so each room's 3 rows/3 cols give just enough dodge room; the
		-- 1-tile gaps between rooms are a risky running-jump apart. Shrink eats
		-- the outer rooms from the outside in.
		id = "HASHTAG", name = "Boxes", weight = 2, minPlayers = 1,
		startSize = 11,
		holeLines = { rows = { 4, 8 }, cols = { 4, 8 } },
		shrink = { times = { 55, 100 }, aliveFractions = { 0.55, 0.3 } },
		rampTime = 157,
		moneyMult = 1.2,
	},
	{
		-- Reverse Hashtag: the Hashtag map turned inside out. The two lines that
		-- were trenches (rows/cols 4 & 8) are now the ONLY solid ground — a # of
		-- 1-tile-wide walkways — and the rooms between them are pits. Players
		-- tightrope the corridors; step off and you fall. startSize 9 makes each
		-- corridor 9 tiles long, keeping the # centered/symmetric (rooms 2-3-2)
		-- inside the 2..10 window. Bulls charge only the four # lanes, so with the
		-- 2-bull cap at least one whole corridor axis is always bull-free to flee
		-- onto. Scarce dodge room, so bulls stay a hair slower/roomier than base
		-- and it pays the most. One gentle shrink (to 7x7) keeps the # readable
		-- rather than collapsing to a degenerate 5x5 ring.
		id = "REVHASH", name = "Hash", weight = 2, minPlayers = 1,
		startSize = 9,
		holeLines = { rows = { 4, 8 }, cols = { 4, 8 }, invert = true },
		shrink = { times = { 60 }, aliveFractions = { 0.4 } },
		rampTime = 157,
		moneyMult = 1.3,
		difficulty = {
			START = { telegraph = 2.4, gap = 2.0, speed = 17, bulls = 1 },
			FINAL = { telegraph = 1.0, gap = 0.5, speed = 55, bulls = 2 },
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
