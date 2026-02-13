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
	-- Segment 1: 100 Fate Coins (HIGH)
	{
		name       = "100 Coins",
		icon       = "\240\159\170\153",
		reward     = "Coins",
		amount     = 100,
		weight     = 25,
		rarity     = "Common",
		color      = Color3.fromRGB(72, 180, 255),   -- sky blue
		modelPath  = nil, -- no model for coins; use existing coin image
	},
	-- Segment 2: Random Common Pet (HIGH)
	{
		name       = "Common Pet",
		icon       = "\240\159\144\190",
		reward     = "Pet",
		catalogId  = "pet_dog",
		amount     = 0,
		weight     = 20,
		rarity     = "Common",
		color      = Color3.fromRGB(68, 198, 68),     -- green
		modelPath  = "ItemModels.Pets.Common.Dog",
	},
	-- Segment 3: 200 Fate Coins (HIGH)
	{
		name       = "200 Coins",
		icon       = "\240\159\170\153",
		reward     = "Coins",
		amount     = 200,
		weight     = 15,
		rarity     = "Uncommon",
		color      = Color3.fromRGB(85, 215, 130),    -- green
		modelPath  = nil,
	},
	-- Segment 4: Random Rare Pet (MEDIUM)
	{
		name       = "Rare Pet",
		icon       = "\240\159\144\190",
		reward     = "Pet",
		catalogId  = "pet_shark",
		amount     = 0,
		weight     = 12,
		rarity     = "Rare",
		color      = Color3.fromRGB(38, 150, 255),    -- blue
		modelPath  = "ItemModels.Pets.Rare.shark",
	},
	-- Segment 5: Findable Crown (MEDIUM)
	{
		name       = "Crown",
		icon       = "\240\159\145\145",
		reward     = "Crown",
		catalogId  = "crown_sparkle",
		amount     = 0,
		weight     = 10,
		rarity     = "Rare",
		color      = Color3.fromRGB(185, 68, 235),    -- purple
		modelPath  = "ItemModels.Crowns.Findable.Sparkle Crown",
	},
	-- Segment 6: 500 Fate Coins (LOW)
	{
		name       = "500 Coins",
		icon       = "\240\159\146\142",
		reward     = "Coins",
		amount     = 500,
		weight     = 6,
		rarity     = "Rare",
		color      = Color3.fromRGB(175, 85, 255),    -- purple
		modelPath  = nil,
	},
	-- Segment 7: Random Epic Pet (LOW)
	{
		name       = "Epic Pet",
		icon       = "\240\159\144\190",
		reward     = "Pet",
		catalogId  = "pet_axolotl",
		amount     = 0,
		weight     = 4,
		rarity     = "Epic",
		color      = Color3.fromRGB(178, 42, 255),    -- deep purple
		modelPath  = "ItemModels.Pets.Epic.axolotl",
	},
	-- Segment 8: 4000 Coins — JACKPOT (VERY LOW)
	{
		name       = "4000 Coins",
		icon       = "\226\173\144",
		reward     = "Coins",
		amount     = 4000,
		weight     = 2,
		rarity     = "Legendary",
		color      = Color3.fromRGB(255, 65, 85),     -- red/gold
		modelPath  = nil,
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
