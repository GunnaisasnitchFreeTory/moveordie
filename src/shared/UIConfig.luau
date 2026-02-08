--[[
	UIConfig
	Shared configuration for the client UI system.

	VIBRANT + READABLE theme — front-page Roblox quality:
	  • Dark-ish but VISIBLE panel backgrounds (not pitch-black navy)
	  • Thick vibrant coloured borders & headers
	  • Glossy gradients, highlights, soft shadows
	  • Clearly visible stud texture overlay
	  • Animated sunburst / radial glow inside panels
	  • High-contrast white text with dark strokes
	  • Neon buy buttons, rarity-coloured borders
	  • Satisfying hover / click / open / close SFX
	  • Intermission = single bright horizontal bar (like reference)

	Used by every UI module.
]]

local UIConfig = {}

-- ═══════════════════════════════════════════════════════════════════
-- COLOURS  (vibrant, readable — front-page quality, high contrast)
-- ═══════════════════════════════════════════════════════════════════

UIConfig.Colors = {
	-- Panel chrome — rich dark blue (cards should contrast against panel)
	PanelBg         = Color3.fromRGB(28, 32, 58),
	PanelBgInner    = Color3.fromRGB(35, 40, 68),
	CardBg          = Color3.fromRGB(48, 55, 88),
	CardBgLighter   = Color3.fromRGB(65, 72, 108),
	CardBgDark      = Color3.fromRGB(30, 34, 55),
	CardStroke      = Color3.fromRGB(82, 90, 125),
	Overlay         = Color3.fromRGB(0, 0, 0),
	OverlayTransparency = 0.35,

	-- Per-panel accent (thick border + header gradient base)
	HeaderShop    = Color3.fromRGB(255, 48, 82),
	HeaderCrowns  = Color3.fromRGB(168, 42, 245),
	HeaderPets    = Color3.fromRGB(255, 138, 22),
	HeaderIndex   = Color3.fromRGB(32, 198, 62),
	HeaderCrate   = Color3.fromRGB(255, 168, 18),
	HeaderSpin    = Color3.fromRGB(72, 180, 255),

	-- Accents
	Gold   = Color3.fromRGB(255, 215, 38),
	Blue   = Color3.fromRGB(58, 172, 255),
	Green  = Color3.fromRGB(62, 225, 75),
	Red    = Color3.fromRGB(240, 42, 42),
	Pink   = Color3.fromRGB(255, 98, 148),
	Orange = Color3.fromRGB(255, 152, 32),
	Cyan   = Color3.fromRGB(48, 228, 228),
	Purple = Color3.fromRGB(172, 72, 255),

	-- Text  (high contrast on dark backgrounds)
	TextWhite = Color3.fromRGB(255, 255, 255),
	TextLight = Color3.fromRGB(225, 228, 242),
	TextMuted = Color3.fromRGB(175, 182, 208),
	TextDark  = Color3.fromRGB(18, 18, 32),

	-- Buttons (bright and vivid — text must be readable)
	BuyButton        = Color3.fromRGB(55, 210, 55),
	BuyButtonHover   = Color3.fromRGB(80, 240, 80),
	EquipButton      = Color3.fromRGB(55, 165, 255),
	EquipButtonHover = Color3.fromRGB(90, 195, 255),
	RobuxButton      = Color3.fromRGB(45, 200, 95),
	RobuxButtonHover = Color3.fromRGB(65, 230, 115),
	CloseBtn         = Color3.fromRGB(242, 38, 52),
	CloseBtnHover    = Color3.fromRGB(255, 68, 82),
	DisabledBtn      = Color3.fromRGB(72, 75, 98),

	-- HUD
	HudCoinBg  = Color3.fromRGB(32, 38, 65),
	HudRoundBg = Color3.fromRGB(255, 165, 42),

	-- Sidebar backdrop (semi-opaque panel behind the 2x2 buttons)
	SidebarBg     = Color3.fromRGB(42, 48, 78),
	SidebarBgAlpha = 0.08,  -- slightly more visible backdrop

	-- Sidebar button colors (VERY bright, fully saturated, chunky)
	SideShop     = Color3.fromRGB(255, 55, 75),
	SideCrowns   = Color3.fromRGB(195, 65, 255),
	SidePets     = Color3.fromRGB(255, 155, 35),
	SideIndex    = Color3.fromRGB(55, 220, 75),
	SideSpectate = Color3.fromRGB(58, 172, 255),
	SideSettings = Color3.fromRGB(135, 145, 165),
	SideAFK      = Color3.fromRGB(255, 198, 48),
	SideIcons    = Color3.fromRGB(255, 98, 178),

	-- Extra panel header accents
	HeaderSpectate = Color3.fromRGB(58, 172, 255),
	HeaderSettings = Color3.fromRGB(135, 145, 165),
	HeaderIcons    = Color3.fromRGB(255, 98, 178),

	-- Rarity palette
	Common    = Color3.fromRGB(168, 175, 198),
	Uncommon  = Color3.fromRGB(62, 225, 68),
	Rare      = Color3.fromRGB(42, 148, 255),
	Epic      = Color3.fromRGB(178, 42, 255),
	Legendary = Color3.fromRGB(255, 195, 18),

	-- Tab pills
	TabActive      = Color3.fromRGB(255, 255, 255),
	TabInactive    = Color3.fromRGB(68, 75, 108),
	TabTextActive  = Color3.fromRGB(18, 18, 32),
	TabTextInactive = Color3.fromRGB(185, 192, 218),

	-- Intermission (single bright horizontal bar)
	IntermissionBg     = Color3.fromRGB(32, 158, 255),
	IntermissionBg2    = Color3.fromRGB(82, 192, 255),
	IntermissionText   = Color3.fromRGB(255, 255, 255),
	IntermissionStroke = Color3.fromRGB(18, 95, 178),
}

-- ═══════════════════════════════════════════════════════════════════
-- SIZES
-- ═══════════════════════════════════════════════════════════════════

UIConfig.Sizes = {
	PanelWidth        = 0.64,
	PanelHeight       = 0.80,
	PanelCorner       = 20,
	PanelStroke       = 6,
	PanelHeaderHeight = 64,

	CardWidth  = 142,
	CardHeight = 185,
	CardCorner = 14,
	CardPad    = 12,

	CrateSectionHeight = 225,

	BtnHeight   = 44,
	BtnCorner   = 12,
	SmBtnCorner = 10,

	HudCoinW  = 172,
	HudCoinH  = 50,
	HudRoundW = 190,
	HudRoundH = 46,
	HudCorner = 14,

	SideBtnW = 86,
	SideBtnH = 86,
	SideBtnGap = 8,
	SideBtnCorner = 16,

	CloseBtnSize = 44,

	TabHeight = 34,
	TabCorner = 17,

	-- Intermission horizontal bar
	IntermissionW = 380,
	IntermissionH = 52,
	IntermissionCorner = 26,
}

-- ═══════════════════════════════════════════════════════════════════
-- STUD TEXTURE  (clearly visible on dark panels)
-- ═══════════════════════════════════════════════════════════════════

UIConfig.StudTexture = {
	AssetId      = "rbxassetid://14861368908",
	TileSize     = UDim2.fromOffset(78, 78),
	Transparency = 0.62,
	Color        = Color3.fromRGB(92, 98, 140),
}

-- ═══════════════════════════════════════════════════════════════════
-- ANIMATION
-- ═══════════════════════════════════════════════════════════════════

UIConfig.Anim = {
	OpenDuration   = 0.28,
	CloseDuration  = 0.18,
	OpenStartScale = 0.92,
	OpenEase       = Enum.EasingStyle.Back,
	CloseEase      = Enum.EasingStyle.Quad,

	HoverScale     = 1.08,
	HoverDuration  = 0.12,
	ClickScale     = 0.88,
	ClickDuration  = 0.06,
	BounceDuration = 0.22,
	BtnEase        = Enum.EasingStyle.Quad,

	CoinBumpScale    = 1.18,
	CoinBumpDuration = 0.25,

	RoundSlideDuration = 0.3,

	SunburstSpeed = 12,
}

-- ═══════════════════════════════════════════════════════════════════
-- SOUNDS
-- ═══════════════════════════════════════════════════════════════════

UIConfig.Sounds = {
	Hover       = { Id = "rbxassetid://9119713951", Volume = 0.12, Speed = 1.6 },
	Click       = { Id = "rbxassetid://9119713951", Volume = 0.32, Speed = 1.1 },
	Open        = { Id = "rbxassetid://9119713951", Volume = 0.26, Speed = 0.60 },
	Close       = { Id = "rbxassetid://9119713951", Volume = 0.20, Speed = 1.30 },
	CoinCollect = { Id = "rbxassetid://9119713951", Volume = 0.36, Speed = 1.80 },
	Equip       = { Id = "rbxassetid://9119713951", Volume = 0.28, Speed = 1.40 },
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
-- MOCK DATA — PREMIUM SHOP (Robux items)
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
-- MOCK DATA — CRATES (walk-up lobby shop, with drop tables)
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
