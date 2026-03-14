--[[
	UIConfig
	Shared configuration for the client UI system.

	REFINED + MODERN theme — front-page Roblox quality:
	  • Dark, clean panel backgrounds with subtle depth
	  • Thin refined borders (NOT heavy/thick outlines)
	  • Smooth gradients, soft shadows
	  • VISIBLE stud texture overlay (lighter, more opaque)
	  • Per-panel unique animations (via UIStyle)
	  • High-contrast white text with dark strokes
	  • Consistent corner radius and spacing
	  • BRIGHTER, more vibrant accent colors

	Used by every UI module.
]]

local UIConfig = {}

-- Global debug logging controls (kept OFF by default to avoid output spam).
UIConfig.DebugLogs = false
UIConfig.LogRateSeconds = 20

-- ═══════════════════════════════════════════════════════════════════
-- COLOURS (brighter, more vivid accents)
-- ═══════════════════════════════════════════════════════════════════

UIConfig.Colors = {
	-- Panel chrome — matched to Crown panel dark purple-black
	PanelBg         = Color3.fromRGB(5,  3,  18),
	PanelBgInner    = Color3.fromRGB(9,  6,  26),
	CardBg          = Color3.fromRGB(14, 10, 36),
	CardBgLighter   = Color3.fromRGB(22, 16, 52),
	CardBgDark      = Color3.fromRGB(6,  4,  20),
	CardStroke      = Color3.fromRGB(60, 45, 110),
	Overlay         = Color3.fromRGB(0, 0, 0),
	OverlayTransparency = 0.4,

	-- Per-panel accent (header gradient base) — +20% saturation
	HeaderShop    = Color3.fromRGB(255, 35, 62),
	HeaderCrowns  = Color3.fromRGB(172, 28, 252),
	HeaderPets    = Color3.fromRGB(255, 132, 12),
	HeaderIndex   = Color3.fromRGB(22, 218, 48),
	HeaderCrate   = Color3.fromRGB(255, 162, 8),
	HeaderSpin    = Color3.fromRGB(38, 185, 255),

	-- Accents (+15-20% saturation, no brightness loss)
	Gold   = Color3.fromRGB(255, 205, 18),
	Blue   = Color3.fromRGB(38, 178, 255),
	Green  = Color3.fromRGB(38, 238, 55),
	Red    = Color3.fromRGB(255, 32, 38),
	Pink   = Color3.fromRGB(255, 72, 145),
	Orange = Color3.fromRGB(255, 142, 18),
	Cyan   = Color3.fromRGB(22, 238, 238),
	Purple = Color3.fromRGB(188, 52, 255),

	-- Text hierarchy — bright white, no washed-out greys
	TextWhite = Color3.fromRGB(255, 255, 255),
	TextLight = Color3.fromRGB(218, 224, 248),
	TextMuted = Color3.fromRGB(165, 175, 218),
	TextDark  = Color3.fromRGB(12, 12, 28),

	-- Buttons (+20% saturation, brighter face for contrast)
	BuyButton        = Color3.fromRGB(32, 228, 48),
	BuyButtonHover   = Color3.fromRGB(55, 252, 72),
	EquipButton      = Color3.fromRGB(32, 178, 255),
	EquipButtonHover = Color3.fromRGB(65, 205, 255),
	RobuxButton      = Color3.fromRGB(28, 215, 82),
	RobuxButtonHover = Color3.fromRGB(45, 242, 105),
	CloseBtn         = Color3.fromRGB(252, 28, 45),
	CloseBtnHover    = Color3.fromRGB(255, 55, 72),
	DisabledBtn      = Color3.fromRGB(62, 68, 98),

	-- HUD — more vivid so readable against bright sky
	HudCoinBg  = Color3.fromRGB(22, 32, 72),
	HudRoundBg = Color3.fromRGB(255, 158, 22),

	-- Sidebar
	SidebarBg      = Color3.fromRGB(38, 45, 82),
	SidebarBgAlpha = 0.08,

	-- Sidebar button colors (+20% saturation, Settings de-greyed to indigo)
	SideShop     = Color3.fromRGB(255, 42, 65),
	SideCrowns   = Color3.fromRGB(198, 48, 255),
	SidePets     = Color3.fromRGB(255, 148, 22),
	SideIndex    = Color3.fromRGB(32, 228, 62),
	SideSpectate = Color3.fromRGB(32, 182, 255),
	SideSettings = Color3.fromRGB(108, 128, 218),
	SideAFK      = Color3.fromRGB(255, 198, 28),
	SideIcons    = Color3.fromRGB(255, 78, 182),
	SideDaily    = Color3.fromRGB(38, 188, 255),
	SideStats    = Color3.fromRGB(28, 222, 198),

	-- Extra panel header accents
	HeaderSpectate = Color3.fromRGB(32, 182, 255),
	HeaderSettings = Color3.fromRGB(108, 128, 218),
	HeaderIcons    = Color3.fromRGB(255, 72, 178),

	-- Rarity palette (+15-20% saturation, Common de-greyed)
	Common    = Color3.fromRGB(158, 172, 225),
	Uncommon  = Color3.fromRGB(38, 242, 55),
	Rare      = Color3.fromRGB(22, 162, 255),
	Epic      = Color3.fromRGB(192, 28, 255),
	Legendary = Color3.fromRGB(255, 192, 8),
	Exclusive = Color3.fromRGB(255, 42, 42),
	Impossible = Color3.fromRGB(255, 32, 32),

	-- Tab pills
	TabActive       = Color3.fromRGB(255, 255, 255),
	TabInactive     = Color3.fromRGB(55, 62, 105),
	TabTextActive   = Color3.fromRGB(12, 12, 28),
	TabTextInactive = Color3.fromRGB(188, 198, 228),

	-- Intermission
	IntermissionBg     = Color3.fromRGB(22, 168, 255),
	IntermissionBg2    = Color3.fromRGB(62, 202, 255),
	IntermissionText   = Color3.fromRGB(255, 255, 255),
	IntermissionStroke = Color3.fromRGB(8, 85, 195),
}

-- ═══════════════════════════════════════════════════════════════════
-- SIZES  (panel stroke thickened to 2.0 for sharper panel edges)
-- ═══════════════════════════════════════════════════════════════════

UIConfig.Sizes = {
	PanelWidth        = 0.64,
	PanelHeight       = 0.80,
	PanelCorner       = 14,
	PanelStroke       = 2.0,
	PanelHeaderHeight = 56,

	CardWidth  = 142,
	CardHeight = 185,
	CardCorner = 12,
	CardPad    = 10,

	CrateSectionHeight = 225,

	BtnHeight   = 48,
	BtnCorner   = 10,
	SmBtnCorner = 10,

	HudCoinW  = 172,
	HudCoinH  = 50,
	HudRoundW = 190,
	HudRoundH = 46,
	HudCorner = 12,

	SideBtnW = 86,
	SideBtnH = 86,
	SideBtnGap = 8,
	SideBtnCorner = 12,

	CloseBtnSize = 46,

	TabHeight = 42,
	TabCorner = 21,

	IntermissionW = 380,
	IntermissionH = 52,
	IntermissionCorner = 26,
}

-- ═══════════════════════════════════════════════════════════════════
-- STUD TEXTURE  (more visible — lower transparency, brighter tint)
-- ═══════════════════════════════════════════════════════════════════

UIConfig.StudTexture = {
	AssetId      = "rbxassetid://84772207963553",
	TileSize     = UDim2.fromOffset(64, 64),
	Transparency = 0.46,
	Color        = Color3.fromRGB(92, 108, 168),
}

-- ═══════════════════════════════════════════════════════════════════
-- ANIMATION  (smooth, stable — no overshoot)
-- ═══════════════════════════════════════════════════════════════════

UIConfig.Anim = {
	OpenDuration   = 0.26,
	CloseDuration  = 0.18,
	OpenStartScale = 0.92,
	OpenEase       = Enum.EasingStyle.Quad,
	CloseEase      = Enum.EasingStyle.Quad,

	HoverScale     = 1.04,
	HoverDuration  = 0.12,
	ClickScale     = 0.92,
	ClickDuration  = 0.05,
	BounceDuration = 0.20,
	BtnEase        = Enum.EasingStyle.Quad,

	CoinBumpScale    = 1.15,
	CoinBumpDuration = 0.24,

	RoundSlideDuration = 0.28,

	SunburstSpeed = 9,

	PopupOpenStartScale = 0.92,
	PopupOpenDuration   = 0.15,
	PopupOpenEase       = Enum.EasingStyle.Quad,
	PopupCloseDuration    = 0.15,
	PopupCloseEase        = Enum.EasingStyle.Quad,
	PopupCloseTargetScale = 0.9,
	PopupDestroyDelay     = 0.20,
}

-- ═══════════════════════════════════════════════════════════════════
-- SOUNDS
-- ═══════════════════════════════════════════════════════════════════

UIConfig.Sounds = {
	Hover       = { Id = "rbxassetid://9119713951", Volume = 0.10, Speed = 1.6 },
	Click       = { Id = "rbxassetid://9119713951", Volume = 0.28, Speed = 1.1 },
	Open        = { Id = "rbxassetid://9119713951", Volume = 0.24, Speed = 0.60 },
	Close       = { Id = "rbxassetid://9119713951", Volume = 0.18, Speed = 1.30 },
	CoinCollect = { Id = "rbxassetid://9119713951", Volume = 0.32, Speed = 1.80 },
	RoundCoinCollect = { Id = "rbxassetid://135303694517645", Volume = 0.50, Speed = 1.00 },
	Equip       = { Id = "rbxassetid://9119713951", Volume = 0.25, Speed = 1.40 },
}

-- ═══════════════════════════════════════════════════════════════════
-- RARITY
-- ═══════════════════════════════════════════════════════════════════

UIConfig.RarityOrder = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Impossible" }

UIConfig.RarityInfo = {
	Common    = { color = UIConfig.Colors.Common,    label = "Common" },
	Uncommon  = { color = UIConfig.Colors.Uncommon,  label = "Uncommon" },
	Rare      = { color = UIConfig.Colors.Rare,      label = "Rare" },
	Epic      = { color = UIConfig.Colors.Epic,      label = "Epic" },
	Legendary = { color = UIConfig.Colors.Legendary, label = "Legendary" },
	Impossible = { color = UIConfig.Colors.Impossible, label = "Impossible" },
}

-- ═══════════════════════════════════════════════════════════════════
-- MOCK DATA — PREMIUM SHOP  (actual Legendary Pets + Exclusive Crowns)
-- ═══════════════════════════════════════════════════════════════════

UIConfig.MockPremiumItems = {
	-- Coin packs (Developer Products)
	{ id = "coins_500",      name = "500 Fate Coins",    type = "Currency", robux = 100,  productId = 3539712298, iconColor = Color3.fromRGB(255, 218, 48), tag = "POPULAR",    coinsAmount = 500 },
	{ id = "coins_2000",     name = "2,000 Fate Coins",  type = "Currency", robux = 200,  productId = 3539713007, iconColor = Color3.fromRGB(255, 198, 28), tag = "",           coinsAmount = 2000 },
	{ id = "coins_5000",     name = "5,000 Fate Coins",  type = "Currency", robux = 400,  productId = 3539713203, iconColor = Color3.fromRGB(255, 178, 18), tag = "",           coinsAmount = 5000 },
	{ id = "coins_10000",    name = "10,000 Fate Coins", type = "Currency", robux = 500,  productId = 3548924617, iconColor = Color3.fromRGB(255, 170, 24), tag = "",           coinsAmount = 10000 },
	{ id = "coins_20000",    name = "20,000 Fate Coins", type = "Currency", robux = 600,  productId = 3548924750, iconColor = Color3.fromRGB(255, 160, 24), tag = "",           coinsAmount = 20000 },
	{ id = "coins_80000",    name = "80,000 Fate Coins", type = "Currency", robux = 800,  productId = 3548924909, iconColor = Color3.fromRGB(255, 150, 24), tag = "",           coinsAmount = 80000 },
	{ id = "coins_100000",   name = "100,000 Fate Coins",type = "Currency", robux = 1000, productId = 3548925138, iconColor = Color3.fromRGB(255, 140, 24), tag = "",           coinsAmount = 100000 },
	{ id = "coins_150000",   name = "150,000 Fate Coins",type = "Currency", robux = 1200, productId = 3548925310, iconColor = Color3.fromRGB(255, 130, 24), tag = "",           coinsAmount = 150000 },
	{ id = "coins_200000",   name = "200,000 Fate Coins",type = "Currency", robux = 2000, productId = 3548925433, iconColor = Color3.fromRGB(255, 120, 24), tag = "",           coinsAmount = 200000 },
	-- Legendary Pets (Gamepasses)
	{ id = "pet_glitched_dragon",    name = "Glitched Dragon",    type = "ExclusivePet",   robux = 250, gamepassId = 1718832641, iconColor = Color3.fromRGB(58, 255, 128),  tag = "EXCLUSIVE", rarity = "Legendary" },
	{ id = "pet_dark_winged_dragon", name = "Music Winged Dragon", type = "ExclusivePet",   robux = 300, gamepassId = 1717772785, iconColor = Color3.fromRGB(48, 28, 68),    tag = "EXCLUSIVE", rarity = "Legendary" },
	{ id = "pet_pink_butterfly",     name = "Pink Butterfly",     type = "ExclusivePet",   robux = 200, gamepassId = 1716864887, iconColor = Color3.fromRGB(255, 148, 208), tag = "NEW",       rarity = "Legendary" },
	{ id = "pet_dark_falcon",        name = "Dark Goblem",        type = "ExclusivePet",   robux = 250, gamepassId = 1716313058, iconColor = Color3.fromRGB(38, 28, 48),    tag = "EXCLUSIVE", rarity = "Legendary" },
	-- Animatronic Epic Pets (shop test flow)
	{ id = "pet_freddy_fazbear",     name = "AnimatronicBear",             type = "ExclusivePet",   robux = 400, gamepassId = 1885101001, iconColor = Color3.fromRGB(165, 108, 72), tag = "NEW",       rarity = "Epic" },
	{ id = "pet_bonnie",             name = "AnimatronicBunny",            type = "ExclusivePet",   robux = 400, gamepassId = 1885101002, iconColor = Color3.fromRGB(118, 88, 228), tag = "NEW",       rarity = "Epic" },
	{ id = "pet_chica",              name = "AnimatronicChicken",          type = "ExclusivePet",   robux = 400, gamepassId = 1885101003, iconColor = Color3.fromRGB(238, 198, 78), tag = "NEW",       rarity = "Epic" },
	{ id = "pet_foxy",               name = "AnimatronicFox",              type = "ExclusivePet",   robux = 400, gamepassId = 1885101004, iconColor = Color3.fromRGB(212, 78, 58),  tag = "NEW",       rarity = "Epic" },
	{ id = "pet_golden_freddy",      name = "TheOneYouShouldntHaveKilled", type = "ExclusivePet",   robux = 400, gamepassId = 1885101005, iconColor = Color3.fromRGB(238, 188, 58), tag = "NEW",       rarity = "Epic" },
	{ id = "pet_the_puppet",         name = "AnimatronicPuppet",           type = "ExclusivePet",   robux = 400, gamepassId = 1885101006, iconColor = Color3.fromRGB(220, 220, 220), tag = "NEW",      rarity = "Epic" },
	{ id = "pet_cupcake",            name = "HauntedCupcake",              type = "ExclusivePet",   robux = 400, gamepassId = 1885101007, iconColor = Color3.fromRGB(255, 148, 188), tag = "NEW",      rarity = "Epic" },
	-- Exclusive Crowns (Gamepasses + FateCoins)
	{ id = "crown_electric",      name = "Electric Crown",      type = "ExclusiveCrown", fateCoins = 40000, iconColor = Color3.fromRGB(48, 198, 255),  tag = "EXCLUSIVE", rarity = "Legendary" },
	{ id = "crown_portal",        name = "Portal Crown",        type = "ExclusiveCrown", fateCoins = 75000, iconColor = Color3.fromRGB(88, 255, 200),  tag = "EXCLUSIVE", rarity = "Legendary" },
	{ id = "crown_freddy_mask",   name = "FreddyMaskCrown",     type = "ExclusiveCrown", fateCoins = 80000, iconColor = Color3.fromRGB(186, 132, 92),  tag = "NEW",       rarity = "Legendary" },
	{ id = "crown_6am",           name = "6AMCrown",            type = "ExclusiveCrown", fateCoins = 5000,  iconColor = Color3.fromRGB(120, 185, 255), tag = "NEW",       rarity = "Epic" },
	{ id = "crown_ce",            name = "CE Crown",            type = "ExclusiveCrown", fateCoins = 10000, iconColor = Color3.fromRGB(235, 235, 245), tag = "NEW",       rarity = "Epic" },
	{ id = "crown_purple_sparks", name = "PurpleSparks Crown",  type = "ExclusiveCrown", fateCoins = 7500,  iconColor = Color3.fromRGB(164, 72, 212),  tag = "NEW",       rarity = "Epic" },
	{ id = "crown_fire_circle",   name = "Fire Circle Crown",   type = "ExclusiveCrown", robux = 450, gamepassId = 1728155288, iconColor = Color3.fromRGB(255, 90, 30),   tag = "NEW",       rarity = "Legendary" },
	{ id = "crown_nen_x_killua",  name = "Nen X Killua Crown",  type = "ExclusiveCrown", robux = 400, gamepassId = 1728821173, iconColor = Color3.fromRGB(140, 200, 255), tag = "EXCLUSIVE", rarity = "Legendary" },
	{ id = "crown_slashes",       name = "Slashes Crown",       type = "ExclusiveCrown", robux = 300, gamepassId = 1727051517, iconColor = Color3.fromRGB(255, 215, 255), tag = "EXCLUSIVE", rarity = "Legendary" },
	{ id = "crown_infinite_void", name = "Infinite Void Crown", type = "ExclusiveCrown", robux = 250, gamepassId = 1717662811, iconColor = Color3.fromRGB(18, 8, 38),    tag = "LIMITED",   rarity = "Legendary" },
	{ id = "crown_rengoku",       name = "Rengoku Crown",       type = "ExclusiveCrown", robux = 200, gamepassId = 1716918881, iconColor = Color3.fromRGB(255, 128, 28),  tag = "NEW",       rarity = "Legendary" },
	{ id = "crown_ultra",         name = "Ultra Crown",         type = "ExclusiveCrown", robux = 300, gamepassId = 1717864767, iconColor = Color3.fromRGB(218, 48, 255),  tag = "EXCLUSIVE", rarity = "Legendary" },
	-- Bundles
	{ id = "bundle_vip",     name = "VIP Bundle",  type = "Bundle", robux = 500, gamepassId = 1745607323, iconColor = Color3.fromRGB(255, 215, 78), tag = "VIP",  rarity = "Legendary" },
	{ id = "bundle_starter", name = "Starter Pack", type = "Bundle", robux = 100, iconColor = Color3.fromRGB(78, 208, 255), tag = "DEAL", rarity = "Rare" },
}

-- ═══════════════════════════════════════════════════════════════════
-- MOCK DATA — CRATES  (actual items from Workspace folders)
-- ═══════════════════════════════════════════════════════════════════

UIConfig.MockCrates = {
	{
		id = "crate_crown",
		name = "Crown Crate",
		iconColor = Color3.fromRGB(185, 68, 235),
		accentColor = Color3.fromRGB(218, 128, 255),
		drops = {
			{ name = "Red Crown",         chance = 13, rarity = "Common",    itemId = "crown_red",          modelPath = "ItemModels.Crowns.Findable.Red Crown" },
			{ name = "Blue Crown",        chance = 13, rarity = "Common",    itemId = "crown_blue",         modelPath = "ItemModels.Crowns.Findable.Blue Crown" },
			{ name = "Green Crown",       chance = 13, rarity = "Common",    itemId = "crown_green",        modelPath = "ItemModels.Crowns.Findable.Green Crown" },
			{ name = "Purple Crown",      chance = 13, rarity = "Common",    itemId = "crown_purple",       modelPath = "ItemModels.Crowns.Findable.Purple Crown" },
			{ name = "Pink Crown",        chance = 13, rarity = "Common",    itemId = "crown_pink",         modelPath = "ItemModels.Crowns.Findable.Pink Crown" },
			{ name = "White Crown",       chance = 12, rarity = "Common",    itemId = "crown_white",        modelPath = "ItemModels.Crowns.Findable.White Crown" },
			{ name = "Orange Crown",      chance = 12, rarity = "Common",    itemId = "crown_orange",       modelPath = "ItemModels.Crowns.Findable.Orange Crown" },
			{ name = "Sparkle Crown",     chance = 3,  rarity = "Rare",      itemId = "crown_sparkle",      modelPath = "ItemModels.Crowns.Findable.Sparkle Crown" },
			{ name = "Anime Lines Crown", chance = 2,  rarity = "Rare",      itemId = "crown_anime_lines",  modelPath = "ItemModels.Crowns.Findable.Anime Lines Crown" },
			{ name = "Darkness Crown",    chance = 2,  rarity = "Rare",      itemId = "crown_darkness",     modelPath = "ItemModels.Crowns.Findable.Darkness Crown" },
			{ name = "Love Crown",        chance = 2,  rarity = "Rare",      itemId = "crown_love",         modelPath = "ItemModels.Crowns.Findable.Love Crown" },
			{ name = "Mystic Art Crown",    chance = 1,  rarity = "Rare",      itemId = "crown_mystic_art",    modelPath = "ItemModels.Crowns.Findable.Mystic Art Crown" },
			{ name = "Orb Crown",           chance = 1,  rarity = "Rare",      itemId = "crown_orb",           modelPath = "ItemModels.Crowns.Findable.Orb Crown" },
			{ name = "Pop Crown",           chance = 1,  rarity = "Rare",      itemId = "crown_pop",           modelPath = "ItemModels.Crowns.Findable.Pop Crown" },
			{ name = "Cartoon Smoke Crown", chance = 1,  rarity = "Rare",      itemId = "crown_cartoon_smoke", modelPath = "ItemModels.Crowns.Findable.Cartoon Smoke Crown" },
			{ name = "Glitch Crown",      chance = 1,  rarity = "Epic",      itemId = "crown_glitch",       modelPath = "ItemModels.Crowns.Findable.Glitch Crown" },
			{ name = "Mystical Crown",    chance = 1,  rarity = "Epic",      itemId = "crown_mystical",     modelPath = "ItemModels.Crowns.Findable.Mystical Crown" },
			{ name = "Aura Crown",        chance = 0.5, rarity = "Legendary", itemId = "crown_aura",        modelPath = "ItemModels.Crowns.Findable.Aura Crown" },
		},
		prices = {
			{ label = "1 Crate",  cost = 500, currency = "Coins" },
			{ label = "3 Crates", cost = 800, currency = "Coins" },
			{ label = "6 Crates", cost = 400, currency = "Robux", productId = 3539706736 },
		},
	},
	{
		id = "crate_pet_common",
		name = "Common Pet Crate",
		iconColor = Color3.fromRGB(68, 198, 68),
		accentColor = Color3.fromRGB(128, 235, 128),
		drops = {
			{ name = "Bald Guest",  chance = 13, rarity = "Common", itemId = "pet_bald_guest",  modelPath = "ItemModels.Pets.Common.Bald Guest" },
			{ name = "Dog",         chance = 13, rarity = "Common", itemId = "pet_dog",         modelPath = "ItemModels.Pets.Common.Dog" },
			{ name = "Noob",        chance = 12, rarity = "Common", itemId = "pet_noob",        modelPath = "ItemModels.Pets.Common.Noob" },
			{ name = "Duck",        chance = 12, rarity = "Common", itemId = "pet_duck",        modelPath = "ItemModels.Pets.Common.Duck" },
			{ name = "Rabbit",      chance = 13, rarity = "Common", itemId = "pet_rabbit",      modelPath = "ItemModels.Pets.Common.Rabbit" },
			{ name = "Crocodile",   chance = 12, rarity = "Common", itemId = "pet_crocodile",   modelPath = "ItemModels.Pets.Common.Crocodile" },
			{ name = "Parrot",      chance = 13, rarity = "Common", itemId = "pet_parrot",      modelPath = "ItemModels.Pets.Common.Parrot" },
			{ name = "Penguin",     chance = 12, rarity = "Common", itemId = "pet_penguin",     modelPath = "ItemModels.Pets.Common.Penguin" },
		},
		prices = {
			{ label = "1 Crate",  cost = 500, currency = "Coins" },
			{ label = "3 Crates", cost = 800, currency = "Coins" },
			{ label = "6 Crates", cost = 400, currency = "Robux", productId = 3539709447 },
		},
	},
	{
		id = "crate_pet_rare",
		name = "Rare Pet Crate",
		iconColor = Color3.fromRGB(38, 150, 255),
		accentColor = Color3.fromRGB(108, 188, 255),
		drops = {
			{ name = "Scorpion",  chance = 20, rarity = "Rare", itemId = "pet_scorpion",  modelPath = "ItemModels.Pets.Rare.Scorpion" },
			{ name = "Ray Fish",  chance = 20, rarity = "Rare", itemId = "pet_ray_fish",  modelPath = "ItemModels.Pets.Rare.Ray fish" },
			{ name = "Shark",     chance = 20, rarity = "Rare", itemId = "pet_shark",     modelPath = "ItemModels.Pets.Rare.Shark" },
			{ name = "Spider",    chance = 20, rarity = "Rare", itemId = "pet_spider",    modelPath = "ItemModels.Pets.Rare.Spider" },
			{ name = "Eagle",     chance = 20, rarity = "Rare", itemId = "pet_eagle",     modelPath = "ItemModels.Pets.Rare.Eagle" },
		},
		prices = {
			{ label = "1 Crate",  cost = 800, currency = "Coins" },
			{ label = "3 Crates", cost = 1400, currency = "Coins" },
			{ label = "6 Crates", cost = 400, currency = "Robux", productId = 3539710049 },
		},
	},
	{
		id = "crate_pet_epic",
		name = "Epic Pet Crate",
		iconColor = Color3.fromRGB(178, 42, 255),
		accentColor = Color3.fromRGB(218, 128, 255),
		drops = {
			{ name = "Axolotl",       chance = 10, rarity = "Epic", itemId = "pet_axolotl",        modelPath = "ItemModels.Pets.Epic.Axolotl" },
			{ name = "Bat",           chance = 10, rarity = "Epic", itemId = "pet_bat",            modelPath = "ItemModels.Pets.Epic.Bat" },
			{ name = "Dolphin",       chance = 10, rarity = "Epic", itemId = "pet_dolphin",        modelPath = "ItemModels.Pets.Epic.Dolphin" },
			{ name = "Unicorn",       chance = 10, rarity = "Epic", itemId = "pet_unicorn",        modelPath = "ItemModels.Pets.Epic.Unicorn" },
			{ name = "Steven",        chance = 10, rarity = "Epic", itemId = "pet_steve",          modelPath = "ItemModels.Pets.Epic.Steven" },
			{ name = "Zombie",        chance = 10, rarity = "Epic", itemId = "pet_zombie",         modelPath = "ItemModels.Pets.Epic.Zombie" },
			{ name = "FoxPlush",      chance = 10, rarity = "Epic", itemId = "pet_foxy_plush",     modelPath = "ItemModels.Pets.Epic.FoxPlush" },
			{ name = "ChickenPlush",  chance = 10, rarity = "Epic", itemId = "pet_chica_plush",    modelPath = "ItemModels.Pets.Epic.ChickenPlush" },
			{ name = "BearPlush",     chance = 7,  rarity = "Epic", itemId = "pet_freddy_plush",   modelPath = "ItemModels.Pets.Epic.BearPlush" },
			{ name = "BunnyPlush",    chance = 7,  rarity = "Epic", itemId = "pet_bonnie_plush",   modelPath = "ItemModels.Pets.Epic.BunnyPlush" },
			{ name = "GoldbearPlush", chance = 3,  rarity = "Epic", itemId = "pet_fredbear_plush", modelPath = "ItemModels.Pets.Epic.GoldbearPlush" },
			{ name = "FurryHugs",     chance = 3,  rarity = "Epic", itemId = "pet_huggy_wuggy",    modelPath = "ItemModels.Pets.Epic.FurryHugs" },
		},
		prices = {
			{ label = "1 Crate",  cost = 1400, currency = "Coins" },
			{ label = "3 Crates", cost = 1950, currency = "Coins" },
			{ label = "6 Crates", cost = 400, currency = "Robux", productId = 3539710471 },
		},
	},
}

-- Debug
UIConfig.DebugLog = true

return UIConfig
