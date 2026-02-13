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

-- ═══════════════════════════════════════════════════════════════════
-- COLOURS (brighter, more vivid accents)
-- ═══════════════════════════════════════════════════════════════════

UIConfig.Colors = {
	-- Panel chrome
	PanelBg         = Color3.fromRGB(28, 32, 58),
	PanelBgInner    = Color3.fromRGB(35, 40, 68),
	CardBg          = Color3.fromRGB(48, 55, 88),
	CardBgLighter   = Color3.fromRGB(65, 72, 108),
	CardBgDark      = Color3.fromRGB(30, 34, 55),
	CardStroke      = Color3.fromRGB(72, 80, 115),
	Overlay         = Color3.fromRGB(0, 0, 0),
	OverlayTransparency = 0.35,

	-- Per-panel accent (header gradient base) — BRIGHTER
	HeaderShop    = Color3.fromRGB(245, 48, 72),
	HeaderCrowns  = Color3.fromRGB(162, 42, 238),
	HeaderPets    = Color3.fromRGB(248, 145, 25),
	HeaderIndex   = Color3.fromRGB(35, 195, 58),
	HeaderCrate   = Color3.fromRGB(248, 168, 18),
	HeaderSpin    = Color3.fromRGB(62, 178, 252),

	-- Accents (slightly more vivid)
	Gold   = Color3.fromRGB(255, 215, 38),
	Blue   = Color3.fromRGB(55, 175, 255),
	Green  = Color3.fromRGB(55, 228, 68),
	Red    = Color3.fromRGB(240, 42, 42),
	Pink   = Color3.fromRGB(255, 95, 148),
	Orange = Color3.fromRGB(255, 152, 32),
	Cyan   = Color3.fromRGB(45, 228, 228),
	Purple = Color3.fromRGB(175, 68, 255),

	-- Text hierarchy
	TextWhite = Color3.fromRGB(255, 255, 255),
	TextLight = Color3.fromRGB(210, 215, 235),
	TextMuted = Color3.fromRGB(155, 162, 192),
	TextDark  = Color3.fromRGB(18, 18, 32),

	-- Buttons (brighter greens/blues)
	BuyButton        = Color3.fromRGB(48, 215, 48),
	BuyButtonHover   = Color3.fromRGB(72, 242, 72),
	EquipButton      = Color3.fromRGB(50, 168, 255),
	EquipButtonHover = Color3.fromRGB(82, 198, 255),
	RobuxButton      = Color3.fromRGB(42, 200, 88),
	RobuxButtonHover = Color3.fromRGB(58, 232, 108),
	CloseBtn         = Color3.fromRGB(240, 38, 52),
	CloseBtnHover    = Color3.fromRGB(255, 62, 75),
	DisabledBtn      = Color3.fromRGB(68, 72, 95),

	-- HUD
	HudCoinBg  = Color3.fromRGB(32, 38, 65),
	HudRoundBg = Color3.fromRGB(255, 168, 38),

	-- Sidebar
	SidebarBg      = Color3.fromRGB(42, 48, 78),
	SidebarBgAlpha = 0.08,

	-- Sidebar button colors (BRIGHTER, more vivid)
	SideShop     = Color3.fromRGB(248, 55, 72),
	SideCrowns   = Color3.fromRGB(188, 62, 255),
	SidePets     = Color3.fromRGB(252, 158, 35),
	SideIndex    = Color3.fromRGB(48, 218, 68),
	SideSpectate = Color3.fromRGB(48, 175, 255),
	SideSettings = Color3.fromRGB(135, 145, 168),
	SideAFK      = Color3.fromRGB(255, 205, 42),
	SideIcons    = Color3.fromRGB(252, 95, 178),

	-- Extra panel header accents
	HeaderSpectate = Color3.fromRGB(48, 172, 252),
	HeaderSettings = Color3.fromRGB(135, 145, 168),
	HeaderIcons    = Color3.fromRGB(248, 95, 172),

	-- Rarity palette (slightly brighter)
	Common    = Color3.fromRGB(170, 178, 200),
	Uncommon  = Color3.fromRGB(58, 225, 62),
	Rare      = Color3.fromRGB(38, 150, 255),
	Epic      = Color3.fromRGB(178, 42, 255),
	Legendary = Color3.fromRGB(255, 198, 18),

	-- Tab pills
	TabActive       = Color3.fromRGB(255, 255, 255),
	TabInactive     = Color3.fromRGB(62, 68, 100),
	TabTextActive   = Color3.fromRGB(18, 18, 32),
	TabTextInactive = Color3.fromRGB(178, 185, 212),

	-- Intermission
	IntermissionBg     = Color3.fromRGB(32, 160, 255),
	IntermissionBg2    = Color3.fromRGB(75, 195, 255),
	IntermissionText   = Color3.fromRGB(255, 255, 255),
	IntermissionStroke = Color3.fromRGB(15, 92, 178),
}

-- ═══════════════════════════════════════════════════════════════════
-- SIZES  (refined — thinner strokes, tighter radius)
-- ═══════════════════════════════════════════════════════════════════

UIConfig.Sizes = {
	PanelWidth        = 0.64,
	PanelHeight       = 0.80,
	PanelCorner       = 14,
	PanelStroke       = 1.5,
	PanelHeaderHeight = 56,

	CardWidth  = 142,
	CardHeight = 185,
	CardCorner = 12,
	CardPad    = 10,

	CrateSectionHeight = 225,

	BtnHeight   = 44,
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

	CloseBtnSize = 40,

	TabHeight = 34,
	TabCorner = 17,

	IntermissionW = 380,
	IntermissionH = 52,
	IntermissionCorner = 26,
}

-- ═══════════════════════════════════════════════════════════════════
-- STUD TEXTURE  (MUCH MORE VISIBLE — lighter color, lower transparency)
-- ═══════════════════════════════════════════════════════════════════

UIConfig.StudTexture = {
	AssetId      = "rbxassetid://14861368908",
	TileSize     = UDim2.fromOffset(64, 64),
	Transparency = 0.55,
	Color        = Color3.fromRGB(85, 98, 145),
}

-- ═══════════════════════════════════════════════════════════════════
-- ANIMATION  (smooth, subtle, premium)
-- ═══════════════════════════════════════════════════════════════════

UIConfig.Anim = {
	OpenDuration   = 0.30,
	CloseDuration  = 0.20,
	OpenStartScale = 0.92,
	OpenEase       = Enum.EasingStyle.Back,
	CloseEase      = Enum.EasingStyle.Quad,

	HoverScale     = 1.04,
	HoverDuration  = 0.14,
	ClickScale     = 0.92,
	ClickDuration  = 0.06,
	BounceDuration = 0.24,
	BtnEase        = Enum.EasingStyle.Quad,

	CoinBumpScale    = 1.15,
	CoinBumpDuration = 0.28,

	RoundSlideDuration = 0.32,

	SunburstSpeed = 8,
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
	Equip       = { Id = "rbxassetid://9119713951", Volume = 0.25, Speed = 1.40 },
}

-- ═══════════════════════════════════════════════════════════════════
-- RARITY
-- ═══════════════════════════════════════════════════════════════════

UIConfig.RarityOrder = { "Common", "Uncommon", "Rare", "Epic", "Legendary" }

UIConfig.RarityInfo = {
	Common    = { color = UIConfig.Colors.Common,    label = "Common" },
	Uncommon  = { color = UIConfig.Colors.Uncommon,  label = "Uncommon" },
	Rare      = { color = UIConfig.Colors.Rare,      label = "Rare" },
	Epic      = { color = UIConfig.Colors.Epic,      label = "Epic" },
	Legendary = { color = UIConfig.Colors.Legendary, label = "Legendary" },
}

-- ═══════════════════════════════════════════════════════════════════
-- MOCK DATA — PREMIUM SHOP  (actual Legendary Pets + Exclusive Crowns)
-- ═══════════════════════════════════════════════════════════════════

UIConfig.MockPremiumItems = {
	-- Coin packs
	{ id = "coins_500",     name = "500 Fate Coins",   type = "Currency",       robux = 99,  iconColor = Color3.fromRGB(255, 218, 48),  tag = "POPULAR" },
	{ id = "coins_2000",    name = "2,000 Fate Coins", type = "Currency",       robux = 299, iconColor = Color3.fromRGB(255, 198, 28),  tag = "BEST VALUE" },
	{ id = "coins_5000",    name = "5,000 Fate Coins", type = "Currency",       robux = 599, iconColor = Color3.fromRGB(255, 178, 18),  tag = "" },
	-- Legendary Pets (Shop-only)
	{ id = "pet_glitched_dragon",    name = "Glitched Dragon",    type = "ExclusivePet",   robux = 249, iconColor = Color3.fromRGB(58, 255, 128),  tag = "EXCLUSIVE", rarity = "Legendary" },
	{ id = "pet_dark_winged_dragon", name = "Dark Winged Dragon", type = "ExclusivePet",   robux = 299, iconColor = Color3.fromRGB(48, 28, 68),    tag = "EXCLUSIVE", rarity = "Legendary" },
	{ id = "pet_pink_butterfly",     name = "Pink Butterfly",     type = "ExclusivePet",   robux = 199, iconColor = Color3.fromRGB(255, 148, 208), tag = "NEW",       rarity = "Legendary" },
	{ id = "pet_dark_falcon",        name = "Dark Falcon",        type = "ExclusivePet",   robux = 249, iconColor = Color3.fromRGB(38, 28, 48),    tag = "EXCLUSIVE", rarity = "Legendary" },
	-- Exclusive Crowns (Shop-only)
	{ id = "crown_electric",      name = "Electric Crown",      type = "ExclusiveCrown", robux = 149, iconColor = Color3.fromRGB(48, 198, 255),  tag = "EXCLUSIVE", rarity = "Legendary" },
	{ id = "crown_infinite_void", name = "Infinite Void Crown", type = "ExclusiveCrown", robux = 249, iconColor = Color3.fromRGB(18, 8, 38),    tag = "LIMITED",   rarity = "Legendary" },
	{ id = "crown_rengoku",       name = "Rengoku Crown",       type = "ExclusiveCrown", robux = 199, iconColor = Color3.fromRGB(255, 128, 28),  tag = "NEW",       rarity = "Legendary" },
	{ id = "crown_ultra",         name = "Ultra Crown",         type = "ExclusiveCrown", robux = 299, iconColor = Color3.fromRGB(218, 48, 255),  tag = "EXCLUSIVE", rarity = "Legendary" },
	-- Bundles
	{ id = "bundle_vip",     name = "VIP Bundle",  type = "Bundle", robux = 499, iconColor = Color3.fromRGB(255, 215, 78), tag = "VIP",  rarity = "Legendary" },
	{ id = "bundle_starter", name = "Starter Pack", type = "Bundle", robux = 99,  iconColor = Color3.fromRGB(78, 208, 255), tag = "DEAL", rarity = "Rare" },
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
			{ name = "Sparkle Crown",     chance = 17, rarity = "Common",  itemId = "crown_sparkle",      modelPath = "ItemModels.Crowns.Findable.Sparkle Crown" },
			{ name = "Anime Lines Crown", chance = 17, rarity = "Rare",    itemId = "crown_anime_lines",  modelPath = "ItemModels.Crowns.Findable.Anime Lines Crown" },
			{ name = "Darkness Crown",    chance = 17, rarity = "Rare",    itemId = "crown_darkness",     modelPath = "ItemModels.Crowns.Findable.Darkness Crown" },
			{ name = "Love Crown",        chance = 17, rarity = "Rare",    itemId = "crown_love",         modelPath = "ItemModels.Crowns.Findable.Love Crown" },
			{ name = "Glitch Crown",      chance = 16, rarity = "Epic",    itemId = "crown_glitch",       modelPath = "ItemModels.Crowns.Findable.Glitch Crown" },
			{ name = "Mystical Crown",    chance = 16, rarity = "Epic",    itemId = "crown_mystical",     modelPath = "ItemModels.Crowns.Findable.Mystical Crown" },
		},
		prices = {
			{ label = "1 Crate",  cost = 100, currency = "Coins" },
			{ label = "3 Crates", cost = 250, currency = "Coins" },
			{ label = "5 Crates", cost = 399, currency = "Robux" },
		},
	},
	{
		id = "crate_pet_common",
		name = "Common Crate",
		iconColor = Color3.fromRGB(68, 198, 68),
		accentColor = Color3.fromRGB(128, 235, 128),
		drops = {
			{ name = "Bald Guest",  chance = 15, rarity = "Common", itemId = "pet_bald_guest",  modelPath = "ItemModels.Pets.Common.Bald Guest" },
			{ name = "Dog",         chance = 15, rarity = "Common", itemId = "pet_dog",         modelPath = "ItemModels.Pets.Common.Dog" },
			{ name = "Noob",        chance = 14, rarity = "Common", itemId = "pet_noob",        modelPath = "ItemModels.Pets.Common.noob" },
			{ name = "Duck",        chance = 14, rarity = "Common", itemId = "pet_duck",        modelPath = "ItemModels.Pets.Common.Duck" },
			{ name = "Rabbit",      chance = 14, rarity = "Common", itemId = "pet_rabbit",      modelPath = "ItemModels.Pets.Common.rabbit" },
			{ name = "Crocodile",   chance = 14, rarity = "Common", itemId = "pet_crocodile",   modelPath = "ItemModels.Pets.Common.crocodile" },
			{ name = "Parrot",      chance = 14, rarity = "Common", itemId = "pet_parrot",      modelPath = "ItemModels.Pets.Common.parrot" },
		},
		prices = {
			{ label = "1 Crate",  cost = 50,  currency = "Coins" },
			{ label = "3 Crates", cost = 130, currency = "Coins" },
			{ label = "5 Crates", cost = 199, currency = "Coins" },
		},
	},
	{
		id = "crate_pet_rare",
		name = "Rare Crate",
		iconColor = Color3.fromRGB(38, 150, 255),
		accentColor = Color3.fromRGB(108, 188, 255),
		drops = {
			{ name = "Scorpion",  chance = 20, rarity = "Rare", itemId = "pet_scorpion",  modelPath = "ItemModels.Pets.Rare.scorpion" },
			{ name = "Ray Fish",  chance = 20, rarity = "Rare", itemId = "pet_ray_fish",  modelPath = "ItemModels.Pets.Rare.ray fish" },
			{ name = "Shark",     chance = 20, rarity = "Rare", itemId = "pet_shark",     modelPath = "ItemModels.Pets.Rare.shark" },
			{ name = "Spider",    chance = 20, rarity = "Rare", itemId = "pet_spider",    modelPath = "ItemModels.Pets.Rare.spider" },
			{ name = "Eagle",     chance = 20, rarity = "Rare", itemId = "pet_eagle",     modelPath = "ItemModels.Pets.Rare.eagle" },
		},
		prices = {
			{ label = "1 Crate",  cost = 150, currency = "Coins" },
			{ label = "3 Crates", cost = 400, currency = "Coins" },
			{ label = "5 Crates", cost = 599, currency = "Coins" },
		},
	},
	{
		id = "crate_pet_epic",
		name = "Epic Crate",
		iconColor = Color3.fromRGB(178, 42, 255),
		accentColor = Color3.fromRGB(218, 128, 255),
		drops = {
			{ name = "Axolotl",  chance = 34, rarity = "Epic", itemId = "pet_axolotl", modelPath = "ItemModels.Pets.Epic.axolotl" },
			{ name = "Bat",      chance = 33, rarity = "Epic", itemId = "pet_bat",     modelPath = "ItemModels.Pets.Epic.bat" },
			{ name = "Dolphin",  chance = 33, rarity = "Epic", itemId = "pet_dolphin", modelPath = "ItemModels.Pets.Epic.dolphin" },
		},
		prices = {
			{ label = "1 Crate",  cost = 300, currency = "Coins" },
			{ label = "3 Crates", cost = 800, currency = "Coins" },
			{ label = "5 Crates", cost = 999, currency = "Robux" },
		},
	},
}

-- Debug
UIConfig.DebugLog = true

return UIConfig
