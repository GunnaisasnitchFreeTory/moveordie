--[[
	SpinWheelConfig
	Shared configuration for the Spin The Wheel system.

	Defines:
	  • Wheel segments (rewards, chances, colors)
	  • Spin purchase prices (Fate Coins + Robux Developer Products)
	  • Timing constants

	Segments include coin rewards, pet rewards, and crown rewards.
	Pet/Crown segments reference ItemCatalog IDs so the server can grant the
	correct item and the client can look up the matching image.

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
--   "Crown"  → grant crown from ItemCatalog (catalogId field)
--
-- wheelImage = "rbxassetid://..."
--   Explicit wheel-only icon for this segment.
--   Pet slices use this directly. Crown slices ignore wheelImage and
--   resolve the exact ItemCatalog crown entry through ThumbnailRenderer.
--   If no usable image/model is available, the wheel shows a "?" placeholder and warns.
-- ═══════════════════════════════════════════

SpinWheelConfig.Segments = {
	-- Segment 1: 100 Fate Coins (HIGH)
	{
		name       = "100 Coins",
		icon = "",
		reward     = "Coins",
		amount     = 100,
		weight     = 25,
		rarity     = "Common",
		color      = Color3.fromRGB(72, 180, 255),   -- sky blue
		modelPath  = nil,
	},
	-- Segment 2: Dog Pet (HIGH)
	{
		name       = "Dog Pet",
		icon = "",
		reward     = "Pet",
		catalogId  = "pet_dog",
		wheelImage = "rbxassetid://81462451441223",
		amount     = 0,
		weight     = 20,
		rarity     = "Common",
		color      = Color3.fromRGB(68, 198, 68),     -- green
		modelPath  = "ItemModels.Pets.Common.Dog",
	},
	-- Segment 3: 200 Fate Coins (HIGH)
	{
		name       = "200 Coins",
		icon = "",
		reward     = "Coins",
		amount     = 200,
		weight     = 15,
		rarity     = "Uncommon",
		color      = Color3.fromRGB(85, 215, 130),    -- green
		modelPath  = nil,
	},
	-- Segment 4: Noob Pet (MEDIUM)
	{
		name       = "Noob Pet",
		icon = "",
		reward     = "Pet",
		catalogId  = "pet_noob",
		wheelImage = "rbxassetid://81702684827965",
		amount     = 0,
		weight     = 12,
		rarity     = "Rare",
		color      = Color3.fromRGB(38, 150, 255),    -- blue
		modelPath  = "ItemModels.Pets.Common.Noob",
	},
	-- Segment 5: Sparkle Crown (MEDIUM)
	{
		name       = "Sparkle Crown",
		icon = "",
		reward     = "Crown",
		catalogId  = "crown_sparkle",
		wheelImage = "rbxassetid://137567080814300",
		amount     = 0,
		weight     = 10,
		rarity     = "Rare",
		color      = Color3.fromRGB(185, 68, 235),    -- purple
		modelPath  = "ItemModels.Crowns.Findable.Sparkle Crown",
	},
	-- Segment 6: 500 Fate Coins (LOW)
	{
		name       = "500 Coins",
		icon = "",
		reward     = "Coins",
		amount     = 500,
		weight     = 6,
		rarity     = "Rare",
		color      = Color3.fromRGB(175, 85, 255),    -- purple
		modelPath  = nil,
	},
	-- Segment 7: Penguin Pet (LOW)
	{
		name       = "Penguin Pet",
		icon = "",
		reward     = "Pet",
		catalogId  = "pet_penguin",
		wheelImage = "rbxassetid://115903577500727",
		amount     = 0,
		weight     = 4,
		rarity     = "Epic",
		color      = Color3.fromRGB(178, 42, 255),    -- deep purple
		modelPath  = "ItemModels.Pets.Common.Penguin",
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
	{ spins = 1,  coins = 250,  robux = 10,  productId = 3539703395, label = "1 SPIN"   },
	{ spins = 3,  coins = 450,  robux = 30,  productId = 3539705825, label = "3 SPINS"  },
	{ spins = 10, coins = 850,  robux = 90,  productId = 3539706154, label = "10 SPINS" },
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
