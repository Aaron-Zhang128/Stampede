local Config = {}

-- Physical arena: a 9x9 tile grid (Tile_1_1 .. Tile_9_9). Every MODE plays in
-- a centered square WINDOW of that grid (mode.startSize); tiles outside the
-- window start the round already sunken. The window then shrinks during the
-- round per the mode's schedule.
Config.GRID_SIZE = 9
Config.TILE_SIZE = 8.4            -- spacing between tile centers (8-stud tiles + 0.4 gap)
Config.TILE_PART_SIZE = 8         -- visible tile width (integer so surface studs fit exactly)
Config.TILE_THICKNESS = 1
Config.ARENA_ORIGIN = Vector3.new(200, 20, 200) -- grid center at tile TOP surface height

Config.BULL_RIDE_HEIGHT = 2.5     -- bull Root center height above tile surface
Config.BULL_OVERSHOOT = 12        -- studs beyond the active window edge where bulls spawn and exit
Config.BULL_HIT_HALF_LENGTH = 3.5 -- kill box half-length along the travel axis
Config.BULL_HIT_HALF_WIDTH = 3.9  -- kill box half-width across the lane

Config.MIN_PLAYERS = 1            -- solo rounds run for practice; wins only awarded with 2+ starters
Config.INTERMISSION_TIME = 10
Config.MONEY_PER_WIN = 100

-- Friend boost: every money grant is multiplied by 1 + PER_FRIEND for each of
-- the player's Roblox friends currently in the server (FriendBoostService).
Config.FRIEND_BOOST = {
	PER_FRIEND = 0.5,             -- +50% money per friend in the server
}

-- Revenge bulls: eliminated participants may send a bull down a lane of the
-- CURRENT window while the round is ACTIVE. Cooldown is server-enforced.
Config.REVENGE = {
	COOLDOWN = 15,                -- seconds between throws, per player
	MONEY_PER_HIT = 25,           -- paid to the thrower per alive player trampled
	TELEGRAPH = 1.2,              -- lane warning before the revenge bull launches
	SPEED = 50,                   -- studs/s, fixed (independent of the difficulty ramp)
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
	SINK_DEPTH = 1.4,             -- how far dropped tiles sink
	SINK_TIME = 0.8,              -- sink tween duration
}

-- Base bull difficulty: intensity = min(elapsed / rampTime, 1), every
-- parameter lerps START -> FINAL. Modes may override rampTime and/or the
-- whole START/FINAL pair (see MODES below).
Config.DIFFICULTY = {
	RAMP_TIME = 150,
	START = { telegraph = 1.8, gap = 2.4, speed = 38, bulls = 1 },
	FINAL = { telegraph = 1.0, gap = 0.8, speed = 60, bulls = 4 },
}

-- Game modes. Main picks one per round: weighted random among modes whose
-- minPlayers is met, never repeating the previous mode when it has a choice.
-- Fields:
--   startSize      side length of the starting window (odd, <= GRID_SIZE)
--   shrink.times   stage i fires at times[i] seconds into the round...
--   shrink.aliveFractions  ...OR when alive/starters <= aliveFractions[i],
--                  whichever comes first; #times = total shrink stages
--   rampTime       overrides DIFFICULTY.RAMP_TIME for this mode
--   difficulty     overrides DIFFICULTY.START/FINAL wholesale (optional)
--   teams          split players into Red/Blue; the last team with a member
--                  standing wins as a group (every member gets the win)
Config.MODES = {
	{
		id = "CLASSIC", name = "Classic", weight = 3, minPlayers = 1,
		startSize = 7,
		shrink = { times = { 45, 90, 135 }, aliveFractions = { 0.75, 0.5, 0.25 } },
		rampTime = 150,
	},
	{
		id = "MEGA", name = "Mega Grid", weight = 2, minPlayers = 1,
		startSize = 9,
		shrink = { times = { 40, 80, 120, 160 }, aliveFractions = { 0.8, 0.6, 0.4, 0.2 } },
		rampTime = 170,
	},
	{
		id = "SMALL", name = "Small Grid", weight = 2, minPlayers = 1,
		startSize = 5,
		shrink = { times = { 40, 80 }, aliveFractions = { 0.6, 0.3 } },
		rampTime = 100,
		difficulty = {
			START = { telegraph = 1.8, gap = 2.4, speed = 38, bulls = 1 },
			FINAL = { telegraph = 1.0, gap = 0.8, speed = 56, bulls = 3 },
		},
	},
	{
		id = "STAMPEDE", name = "Stampede", weight = 2, minPlayers = 1,
		startSize = 7,
		shrink = { times = { 45, 90, 135 }, aliveFractions = { 0.75, 0.5, 0.25 } },
		rampTime = 130,
		difficulty = {
			START = { telegraph = 1.8, gap = 2.6, speed = 38, bulls = 2 },
			FINAL = { telegraph = 0.9, gap = 0.8, speed = 62, bulls = 5 },
		},
	},
	{
		id = "TEAMS", name = "Team Rush", weight = 2, minPlayers = 2,
		teams = true,
		startSize = 7,
		shrink = { times = { 45, 90, 135 }, aliveFractions = { 0.75, 0.5, 0.25 } },
		rampTime = 150,
	},
}

return Config