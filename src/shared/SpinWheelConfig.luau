--[[
	SpinWheelConfig
	Shared configuration for the Spin The Wheel system.

	Defines:
	  • Wheel segments (rewards, chances, colors)
	  • Spin purchase prices
	  • Timing constants
	  • Coin equivalents for non-coin rewards

	Used by: SpinWheelPanel (client), SpinWheelService (server)
]]

local SpinWheelConfig = {}

SpinWheelConfig.NUM_SEGMENTS = 8
SpinWheelConfig.SEGMENT_ANGLE = 360 / 8 -- 45°

-- ═══════════════════════════════════════════
-- WHEEL SEGMENTS (8 slices, chances sum to 100)
-- ═══════════════════════════════════════════

SpinWheelConfig.Segments = {
	{
		name       = "50 Coins",
		icon       = "🪙",
		reward     = "Coins",
		amount     = 50,
		chance     = 32,
		rarity     = "Common",
		color      = Color3.fromRGB(72, 180, 255),   -- sky blue
	},
	{
		name       = "75 Coins",
		icon       = "🪙",
		reward     = "Coins",
		amount     = 75,
		chance     = 25,
		rarity     = "Common",
		color      = Color3.fromRGB(255, 215, 65),    -- gold
	},
	{
		name       = "150 Coins",
		icon       = "💰",
		reward     = "Coins",
		amount     = 150,
		chance     = 15,
		rarity     = "Uncommon",
		color      = Color3.fromRGB(85, 215, 130),    -- green
	},
	{
		name       = "200 Coins",
		icon       = "💰",
		reward     = "Coins",
		amount     = 200,
		chance     = 10,
		rarity     = "Uncommon",
		color      = Color3.fromRGB(100, 220, 255),   -- cyan
	},
	{
		name       = "400 Coins",
		icon       = "💎",
		reward     = "Coins",
		amount     = 400,
		chance     = 8,
		rarity     = "Rare",
		color      = Color3.fromRGB(175, 85, 255),    -- purple
	},
	{
		name       = "Random Crate",
		icon       = "📦",
		reward     = "Crate",
		amount     = 250, -- coin equivalent
		chance     = 5,
		rarity     = "Rare",
		color      = Color3.fromRGB(255, 110, 175),   -- pink
	},
	{
		name       = "Random Egg",
		icon       = "🥚",
		reward     = "Egg",
		amount     = 500, -- coin equivalent
		chance     = 3,
		rarity     = "Epic",
		color      = Color3.fromRGB(130, 55, 195),    -- deep purple
	},
	{
		name       = "Jackpot!",
		icon       = "⭐",
		reward     = "Icon",
		amount     = 1000, -- coin equivalent
		chance     = 2,
		rarity     = "Legendary",
		color      = Color3.fromRGB(255, 65, 85),     -- red/gold
	},
}

-- ═══════════════════════════════════════════
-- SPIN PURCHASE OPTIONS
-- ═══════════════════════════════════════════

SpinWheelConfig.SpinPrices = {
	{ spins = 1,  coins = 100,  robux = 10, label = "1 Spin"   },
	{ spins = 3,  coins = 250,  robux = 19, label = "3 Spins"  },
	{ spins = 10, coins = 750,  robux = 59, label = "10 Spins" },
}

-- ═══════════════════════════════════════════
-- TIMING
-- ═══════════════════════════════════════════

SpinWheelConfig.FREE_SPIN_COOLDOWN = 86400 -- 24 hours in seconds
SpinWheelConfig.SPIN_DURATION      = 5     -- animation duration in seconds
SpinWheelConfig.MIN_FULL_SPINS     = 5     -- minimum full rotations
SpinWheelConfig.MAX_FULL_SPINS     = 8     -- maximum full rotations

-- ═══════════════════════════════════════════
-- PROXIMITY
-- ═══════════════════════════════════════════

SpinWheelConfig.OPEN_DISTANCE     = 14  -- studs to show "Press E" prompt
SpinWheelConfig.CLOSE_DISTANCE    = 50  -- studs to auto-close (generous — only when player clearly walks away)
SpinWheelConfig.OPEN_GRACE_PERIOD = 3   -- seconds after opening before auto-close checks start

return SpinWheelConfig
