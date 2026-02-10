--[[
	SpinWheelConfig
	Shared configuration for the Spin The Wheel system.

	Defines:
	  • Wheel segments (rewards, chances, colors)
	  • Spin purchase prices (Fate Coins + Robux Developer Products)
	  • Timing constants

	Segments now include BOTH coin rewards and pet rewards.
	Pet segments reference ItemCatalog IDs so the server can grant the
	correct pet and the client can look up the matching image.

	Used by: SpinWheelPanel (client), SpinWheelService (server), SpinWheelScript (client)
]]

local SpinWheelConfig = {}

SpinWheelConfig.NUM_SEGMENTS = 8
SpinWheelConfig.SEGMENT_ANGLE = 360 / 8 -- 45°

-- DEV / TESTING
-- In Studio, the server will treat spins as unlimited automatically.
-- If you need unlimited spins outside Studio (private test server), set this true.
SpinWheelConfig.DEBUG_UNLIMITED_SPINS = false

-- ═══════════════════════════════════════════
-- WHEEL SEGMENTS (8 slices)
--
-- Weight-based odds (weights don't need to sum to 100):
--   HIGH   chance: 100–200 Coins, Common Pets
--   LOW    chance: 500–1000 Coins
--   V.LOW  chance: 4000 Coins (jackpot)
--
-- reward types:
--   "Coins"  → grant coin amount
--   "Pet"    → grant pet from ItemCatalog (catalogId field)
-- ═══════════════════════════════════════════

SpinWheelConfig.Segments = {
	-- Segment 1: 100 Coins (HIGH)
	{
		name       = "100 Coins",
		icon       = "🪙",
		reward     = "Coins",
		amount     = 100,
		weight     = 25,
		rarity     = "Common",
		color      = Color3.fromRGB(72, 180, 255),   -- sky blue
	},
	-- Segment 2: Puppy pet (HIGH)
	{
		name       = "Puppy",
		icon       = "🐶",
		reward     = "Pet",
		catalogId  = "PUPPY_COMMON",
		amount     = 0,
		weight     = 20,
		rarity     = "Common",
		color      = Color3.fromRGB(198, 158, 118),   -- warm brown
	},
	-- Segment 3: 150 Coins (HIGH)
	{
		name       = "150 Coins",
		icon       = "🪙",
		reward     = "Coins",
		amount     = 150,
		weight     = 15,
		rarity     = "Uncommon",
		color      = Color3.fromRGB(85, 215, 130),    -- green
	},
	-- Segment 4: Chick pet (HIGH)
	{
		name       = "Chick",
		icon       = "🐣",
		reward     = "Pet",
		catalogId  = "CHICK_COMMON",
		amount     = 0,
		weight     = 18,
		rarity     = "Common",
		color      = Color3.fromRGB(255, 228, 78),    -- yellow
	},
	-- Segment 5: 200 Coins (HIGH)
	{
		name       = "200 Coins",
		icon       = "💰",
		reward     = "Coins",
		amount     = 200,
		weight     = 10,
		rarity     = "Uncommon",
		color      = Color3.fromRGB(100, 220, 255),   -- cyan
	},
	-- Segment 6: 500 Coins (LOW)
	{
		name       = "500 Coins",
		icon       = "💎",
		reward     = "Coins",
		amount     = 500,
		weight     = 6,
		rarity     = "Rare",
		color      = Color3.fromRGB(175, 85, 255),    -- purple
	},
	-- Segment 7: 1000 Coins (LOW)
	{
		name       = "1000 Coins",
		icon       = "💎",
		reward     = "Coins",
		amount     = 1000,
		weight     = 4,
		rarity     = "Epic",
		color      = Color3.fromRGB(130, 55, 195),    -- deep purple
	},
	-- Segment 8: 4000 Coins — JACKPOT (VERY LOW)
	{
		name       = "4000 Coins",
		icon       = "⭐",
		reward     = "Coins",
		amount     = 4000,
		weight     = 2,
		rarity     = "Legendary",
		color      = Color3.fromRGB(255, 65, 85),     -- red/gold
	},
}

-- ═══════════════════════════════════════════
-- SPIN PURCHASE OPTIONS
--
-- Each entry supports:
--   • coins:     Fate Coin price (deducted server-side)
--   • robux:     display price (actual price set in Developer Product)
--   • productId: Roblox Developer Product ID for Robux purchase
--                Set to 0 = not yet created (button shows "Setup needed")
--                CREATE products in Game Settings → Monetization → Developer Products
--                then paste the real IDs here.
-- ═══════════════════════════════════════════

SpinWheelConfig.SpinPrices = {
	{ spins = 1,  coins = 100,  robux = 10,  productId = 0, label = "1 Spin"   },
	{ spins = 3,  coins = 250,  robux = 29,  productId = 0, label = "3 Spins"  },
	{ spins = 10, coins = 750,  robux = 89,  productId = 0, label = "10 Spins" },
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
SpinWheelConfig.CLOSE_DISTANCE    = 50  -- studs to auto-close (generous)
SpinWheelConfig.OPEN_GRACE_PERIOD = 3   -- seconds after opening before auto-close checks start

return SpinWheelConfig
