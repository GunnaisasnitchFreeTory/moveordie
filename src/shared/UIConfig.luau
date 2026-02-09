--[[
	UIConfig
	Shared configuration for the client UI system.

	REFINED + MODERN theme — front-page Roblox quality:
	  • Dark, clean panel backgrounds with subtle depth
	  • Thin refined borders (NOT heavy/thick outlines)
	  • Smooth gradients, soft shadows
	  • Subtle stud texture overlay
	  • Animated sunburst / radial glow (subtle)
	  • High-contrast white text with dark strokes
	  • Consistent corner radius and spacing

	Used by every UI module.
]]

local UIConfig = {}

-- ═══════════════════════════════════════════════════════════════════
-- COLOURS
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

	-- Per-panel accent (header gradient base)
	HeaderShop    = Color3.fromRGB(235, 55, 80),
	HeaderCrowns  = Color3.fromRGB(152, 48, 225),
	HeaderPets    = Color3.fromRGB(238, 138, 30),
	HeaderIndex   = Color3.fromRGB(38, 182, 62),
	HeaderCrate   = Color3.fromRGB(238, 158, 25),
	HeaderSpin    = Color3.fromRGB(68, 168, 242),

	-- Accents
	Gold   = Color3.fromRGB(250, 210, 42),
	Blue   = Color3.fromRGB(58, 168, 248),
	Green  = Color3.fromRGB(60, 218, 72),
	Red    = Color3.fromRGB(232, 45, 45),
	Pink   = Color3.fromRGB(248, 98, 145),
	Orange = Color3.fromRGB(248, 148, 35),
	Cyan   = Color3.fromRGB(50, 222, 222),
	Purple = Color3.fromRGB(168, 72, 248),

	-- Text hierarchy
	TextWhite = Color3.fromRGB(255, 255, 255),
	TextLight = Color3.fromRGB(210, 215, 235),
	TextMuted = Color3.fromRGB(155, 162, 192),
	TextDark  = Color3.fromRGB(18, 18, 32),

	-- Buttons
	BuyButton        = Color3.fromRGB(52, 205, 52),
	BuyButtonHover   = Color3.fromRGB(75, 235, 75),
	EquipButton      = Color3.fromRGB(55, 162, 248),
	EquipButtonHover = Color3.fromRGB(85, 190, 248),
	RobuxButton      = Color3.fromRGB(45, 195, 90),
	RobuxButtonHover = Color3.fromRGB(62, 225, 110),
	CloseBtn         = Color3.fromRGB(235, 42, 55),
	CloseBtnHover    = Color3.fromRGB(248, 65, 78),
	DisabledBtn      = Color3.fromRGB(68, 72, 95),

	-- HUD
	HudCoinBg  = Color3.fromRGB(32, 38, 65),
	HudRoundBg = Color3.fromRGB(248, 162, 42),

	-- Sidebar
	SidebarBg      = Color3.fromRGB(42, 48, 78),
	SidebarBgAlpha = 0.08,

	-- Sidebar button colors
	SideShop     = Color3.fromRGB(232, 62, 80),
	SideCrowns   = Color3.fromRGB(178, 70, 242),
	SidePets     = Color3.fromRGB(235, 148, 45),
	SideIndex    = Color3.fromRGB(55, 200, 72),
	SideSpectate = Color3.fromRGB(58, 165, 242),
	SideSettings = Color3.fromRGB(128, 138, 158),
	SideAFK      = Color3.fromRGB(242, 192, 50),
	SideIcons    = Color3.fromRGB(238, 100, 168),

	-- Extra panel header accents
	HeaderSpectate = Color3.fromRGB(58, 165, 242),
	HeaderSettings = Color3.fromRGB(128, 138, 158),
	HeaderIcons    = Color3.fromRGB(238, 100, 168),

	-- Rarity palette
	Common    = Color3.fromRGB(165, 172, 195),
	Uncommon  = Color3.fromRGB(60, 218, 65),
	Rare      = Color3.fromRGB(42, 145, 248),
	Epic      = Color3.fromRGB(172, 45, 248),
	Legendary = Color3.fromRGB(250, 192, 20),

	-- Tab pills
	TabActive       = Color3.fromRGB(255, 255, 255),
	TabInactive     = Color3.fromRGB(62, 68, 100),
	TabTextActive   = Color3.fromRGB(18, 18, 32),
	TabTextInactive = Color3.fromRGB(178, 185, 212),

	-- Intermission
	IntermissionBg     = Color3.fromRGB(32, 155, 248),
	IntermissionBg2    = Color3.fromRGB(78, 188, 248),
	IntermissionText   = Color3.fromRGB(255, 255, 255),
	IntermissionStroke = Color3.fromRGB(18, 92, 172),
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
-- STUD TEXTURE  (very subtle — barely visible)
-- ═══════════════════════════════════════════════════════════════════

UIConfig.StudTexture = {
	AssetId      = "rbxassetid://14861368908",
	TileSize     = UDim2.fromOffset(78, 78),
	Transparency = 0.82,
	Color        = Color3.fromRGB(68, 75, 110),
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
-- MOCK DATA — FATE CROWNS
-- ═══════════════════════════════════════════════════════════════════

UIConfig.MockCrowns = {
	{ id = "crown_basic",    name = "Basic Crown",   rarity = "Common",    iconColor = Color3.fromRGB(195, 198, 218), owned = true,  equipped = true  },
	{ id = "crown_flame",    name = "Flame Crown",   rarity = "Rare",      iconColor = Color3.fromRGB(255, 98, 28),   owned = true,  equipped = false },
	{ id = "crown_frost",    name = "Frost Crown",   rarity = "Rare",      iconColor = Color3.fromRGB(112, 198, 255), owned = false, equipped = false },
	{ id = "crown_shadow",   name = "Shadow Crown",  rarity = "Epic",      iconColor = Color3.fromRGB(88, 42, 128),   owned = false, equipped = false },
	{ id = "crown_golden",   name = "Golden Crown",  rarity = "Legendary", iconColor = Color3.fromRGB(255, 208, 48),  owned = false, equipped = false },
	{ id = "crown_neon",     name = "Neon Crown",    rarity = "Uncommon",  iconColor = Color3.fromRGB(98, 255, 178),  owned = false, equipped = false },
	{ id = "crown_pixel",    name = "Pixel Crown",   rarity = "Common",    iconColor = Color3.fromRGB(148, 218, 98),  owned = false, equipped = false },
	{ id = "crown_galaxy",   name = "Galaxy Crown",  rarity = "Epic",      iconColor = Color3.fromRGB(82, 52, 185),   owned = false, equipped = false },
	{ id = "crown_thunder",  name = "Thunder Crown", rarity = "Rare",      iconColor = Color3.fromRGB(255, 228, 58),  owned = false, equipped = false },
	{ id = "crown_crystal",  name = "Crystal Crown", rarity = "Uncommon",  iconColor = Color3.fromRGB(178, 228, 255), owned = false, equipped = false },
	{ id = "crown_phantom",  name = "Phantom Crown", rarity = "Legendary", iconColor = Color3.fromRGB(198, 158, 255), owned = false, equipped = false },
	{ id = "crown_nature",   name = "Nature Crown",  rarity = "Common",    iconColor = Color3.fromRGB(78, 185, 78),   owned = false, equipped = false },
}

-- ═══════════════════════════════════════════════════════════════════
-- MOCK DATA — PETS
-- ═══════════════════════════════════════════════════════════════════

UIConfig.MockPets = {
	{ id = "pet_chick",    name = "Chick",        rarity = "Common",    iconColor = Color3.fromRGB(255, 228, 78),  owned = true,  equipped = true  },
	{ id = "pet_puppy",    name = "Puppy",        rarity = "Common",    iconColor = Color3.fromRGB(198, 158, 118), owned = true,  equipped = false },
	{ id = "pet_kitty",    name = "Kitty",        rarity = "Uncommon",  iconColor = Color3.fromRGB(255, 178, 198), owned = false, equipped = false },
	{ id = "pet_dragon",   name = "Baby Dragon",  rarity = "Legendary", iconColor = Color3.fromRGB(255, 68, 28),  owned = false, equipped = false },
	{ id = "pet_bunny",    name = "Bunny",        rarity = "Uncommon",  iconColor = Color3.fromRGB(228, 228, 238), owned = false, equipped = false },
	{ id = "pet_phoenix",  name = "Phoenix",      rarity = "Epic",      iconColor = Color3.fromRGB(255, 138, 28), owned = false, equipped = false },
	{ id = "pet_fox",      name = "Fox",          rarity = "Rare",      iconColor = Color3.fromRGB(228, 128, 48), owned = false, equipped = false },
	{ id = "pet_wolf",     name = "Shadow Wolf",  rarity = "Epic",      iconColor = Color3.fromRGB(58, 48, 88),   owned = false, equipped = false },
	{ id = "pet_unicorn",  name = "Unicorn",      rarity = "Legendary", iconColor = Color3.fromRGB(228, 178, 255), owned = false, equipped = false },
	{ id = "pet_owl",      name = "Owl",          rarity = "Rare",      iconColor = Color3.fromRGB(138, 98, 68),  owned = false, equipped = false },
}

-- ═══════════════════════════════════════════════════════════════════
-- MOCK DATA — PREMIUM SHOP
-- ═══════════════════════════════════════════════════════════════════

UIConfig.MockPremiumItems = {
	{ id = "coins_500",     name = "500 Fate Coins",   type = "Currency",       robux = 99,  iconColor = Color3.fromRGB(255, 218, 48),  tag = "POPULAR" },
	{ id = "coins_2000",    name = "2,000 Fate Coins", type = "Currency",       robux = 299, iconColor = Color3.fromRGB(255, 198, 28),  tag = "BEST VALUE" },
	{ id = "coins_5000",    name = "5,000 Fate Coins", type = "Currency",       robux = 599, iconColor = Color3.fromRGB(255, 178, 18),  tag = "" },
	{ id = "crown_royal",   name = "Royal Crown",      type = "ExclusiveCrown", robux = 149, iconColor = Color3.fromRGB(218, 48, 255),  tag = "EXCLUSIVE", rarity = "Legendary" },
	{ id = "crown_divine",  name = "Divine Crown",     type = "ExclusiveCrown", robux = 249, iconColor = Color3.fromRGB(255, 215, 48),  tag = "LIMITED",   rarity = "Legendary" },
	{ id = "pet_cosmic",    name = "Cosmic Dragon",    type = "ExclusivePet",   robux = 199, iconColor = Color3.fromRGB(58, 198, 255),  tag = "EXCLUSIVE", rarity = "Legendary" },
	{ id = "pet_nebula",    name = "Nebula Cat",       type = "ExclusivePet",   robux = 149, iconColor = Color3.fromRGB(185, 98, 255),  tag = "NEW",       rarity = "Epic" },
	{ id = "bundle_vip",    name = "VIP Bundle",       type = "Bundle",         robux = 499, iconColor = Color3.fromRGB(255, 215, 78),  tag = "VIP",       rarity = "Legendary" },
	{ id = "bundle_starter", name = "Starter Pack",    type = "Bundle",         robux = 99,  iconColor = Color3.fromRGB(78, 208, 255),  tag = "DEAL",      rarity = "Rare" },
}

-- ═══════════════════════════════════════════════════════════════════
-- MOCK DATA — CRATES
-- ═══════════════════════════════════════════════════════════════════

UIConfig.MockCrates = {
	{
		id = "crate_crown",
		name = "Crown Crate",
		iconColor = Color3.fromRGB(185, 68, 235),
		accentColor = Color3.fromRGB(218, 128, 255),
		drops = {
			{ name = "Basic Crown",  chance = 55, rarity = "Common" },
			{ name = "Flame Crown",  chance = 25, rarity = "Rare" },
			{ name = "Shadow Crown", chance = 15, rarity = "Epic" },
			{ name = "Golden Crown", chance = 5,  rarity = "Legendary" },
		},
		prices = {
			{ label = "1 Crate",  cost = 100, currency = "Coins" },
			{ label = "3 Crates", cost = 250, currency = "Coins" },
			{ label = "5 Crates", cost = 399, currency = "Robux" },
		},
	},
	{
		id = "crate_pet",
		name = "Pet Crate",
		iconColor = Color3.fromRGB(255, 145, 35),
		accentColor = Color3.fromRGB(255, 188, 98),
		drops = {
			{ name = "Chick",   chance = 45, rarity = "Common" },
			{ name = "Fox",     chance = 30, rarity = "Rare" },
			{ name = "Phoenix", chance = 18, rarity = "Epic" },
			{ name = "Dragon",  chance = 7,  rarity = "Legendary" },
		},
		prices = {
			{ label = "1 Crate",  cost = 100, currency = "Coins" },
			{ label = "3 Crates", cost = 250, currency = "Coins" },
			{ label = "5 Crates", cost = 399, currency = "Robux" },
		},
	},
	{
		id = "crate_mega",
		name = "Mega Crate",
		iconColor = Color3.fromRGB(255, 48, 68),
		accentColor = Color3.fromRGB(255, 118, 128),
		drops = {
			{ name = "Rare Crown/Pet",  chance = 40, rarity = "Rare" },
			{ name = "Epic Crown/Pet",  chance = 35, rarity = "Epic" },
			{ name = "Legendary Item",  chance = 25, rarity = "Legendary" },
		},
		prices = {
			{ label = "1 Crate",  cost = 500,  currency = "Coins" },
			{ label = "3 Crates", cost = 1200, currency = "Coins" },
			{ label = "1 Crate",  cost = 199,  currency = "Robux" },
		},
	},
}

-- Debug
UIConfig.DebugLog = true

return UIConfig
