--[[
	ItemCatalog
	Single source of truth for item metadata, model paths, stat modifiers,
	crate pools, and level crown milestones.

	All item definitions match the actual Workspace model folders
	(moved to ReplicatedStorage.ItemModels on server start by ModelMover).

	Used by: CrateService, LevelCrownService, InventoryService, StatService,
	         PetsPanel, FateCrownsPanel, CrateShopPanel, ShopPanel, IndexPanel,
	         SpinWheelService

	MODEL PATH FORMAT:
	  Each item has a `modelPath` like "ItemModels.Pets.Common.dog"
	  which is resolved to ReplicatedStorage:FindFirstChild("ItemModels")
	  → FindFirstChild("Pets") → FindFirstChild("Common") → FindFirstChild("dog")

	STAT MODIFIERS:
	  Pets and Crowns may have a `stats` table with optional keys:
	    WalkSpeed      → additive (e.g. +2)
	    JumpPower      → additive (e.g. +5)
	    CoinMultiplier → multiplicative (e.g. 1.10 = +10% coins)
]]

local ItemCatalog = {}

-- ═══════════════════════════════════════════════════════════════════
-- FALLBACK
-- ═══════════════════════════════════════════════════════════════════

ItemCatalog.FALLBACK_IMAGE = ""

-- ═══════════════════════════════════════════════════════════════════
-- PET DEFINITIONS  (20 pets across 4 rarities)
-- ═══════════════════════════════════════════════════════════════════

ItemCatalog.Pets = {
	-- ── Common (8) ──
	pet_bald_guest = {
		id        = "pet_bald_uest",
		name      = "Bald Guest",
		modelName = "Bald Guest",
		type      = "Pet",
		rarity    = "Common",
		modelPath = "ItemModels.Pets.Common.Bald Guest",
		image     = "",
		iconText  = "\240\159\145\164",
		iconColor = Color3.fromRGB(245, 205, 165),
		stats     = { CoinMultiplier = 1.02 },
	},
	pet_noob = {
		id        = "pet_noob",
		name      = "Noob",
		modelName = "Noob",
		type      = "Pet",
		rarity    = "Common",
		modelPath = "ItemModels.Pets.Common.Noob",
		image     = "",
		iconText  = "\240\159\152\131",
		iconColor = Color3.fromRGB(255, 228, 78),
		stats     = { WalkSpeed = 1 },
	},
	pet_dog = {
		id        = "pet_dog",
		name      = "Dog",
		modelName = "Dog",
		type      = "Pet",
		rarity    = "Common",
		modelPath = "ItemModels.Pets.Common.dog",
		image     = "",
		iconText  = "\240\159\144\182",
		iconColor = Color3.fromRGB(198, 158, 118),
		stats     = { CoinMultiplier = 1.02 },
	},
	pet_penguin = {
		id        = "pet_penguin",
		name      = "Penguin",
		modelName = "penguin",
		type      = "Pet",
		rarity    = "Common",
		modelPath = "ItemModels.Pets.Common.penguin",
		image     = "",
		iconText  = "\240\159\144\167",
		iconColor = Color3.fromRGB(45, 45, 55),
		stats     = nil,
	},
	pet_duck = {
		id        = "pet_duck",
		name      = "Duck",
		modelName = "Duck",
		type      = "Pet",
		rarity    = "Common",
		modelPath = "ItemModels.Pets.Common.Duck",
		image     = "",
		iconText  = "\240\159\166\134",
		iconColor = Color3.fromRGB(255, 228, 78),
		stats     = { WalkSpeed = 1 },
	},
	pet_rabbit = {
		id        = "pet_rabbit",
		name      = "Rabbit",
		modelName = "rabbit",
		type      = "Pet",
		rarity    = "Common",
		modelPath = "ItemModels.Pets.Common.rabbit",
		image     = "",
		iconText  = "\240\159\144\176",
		iconColor = Color3.fromRGB(235, 235, 240),
		stats     = nil,
	},
	pet_crocodile = {
		id        = "pet_crocodile",
		name      = "Crocodile",
		modelName = "crocodile",
		type      = "Pet",
		rarity    = "Common",
		modelPath = "ItemModels.Pets.Common.crocodile",
		image     = "",
		iconText  = "\240\159\144\138",
		iconColor = Color3.fromRGB(68, 148, 68),
		stats     = { CoinMultiplier = 1.01 },
	},
	pet_parrot = {
		id        = "pet_parrot",
		name      = "Parrot",
		modelName = "parrot",
		type      = "Pet",
		rarity    = "Common",
		modelPath = "ItemModels.Pets.Common.parrot",
		image     = "",
		iconText  = "\240\159\166\156",
		iconColor = Color3.fromRGB(78, 198, 68),
		stats     = { WalkSpeed = 1 },
	},

	-- ── Rare (5) ──
	pet_scorpion = {
		id        = "pet_scorpion",
		name      = "Scorpion",
		modelName = "scorpion",
		type      = "Pet",
		rarity    = "Rare",
		modelPath = "ItemModels.Pets.Rare.scorpion",
		image     = "",
		iconText  = "\240\159\166\130",
		iconColor = Color3.fromRGB(148, 58, 28),
		stats     = { CoinMultiplier = 1.05, WalkSpeed = 1 },
	},
	pet_ray_fish = {
		id        = "pet_ray_fish",
		name      = "Ray Fish",
		modelName = "ray fish",
		type      = "Pet",
		rarity    = "Rare",
		modelPath = "ItemModels.Pets.Rare.ray fish",
		image     = "",
		iconText  = "\240\159\144\159",
		iconColor = Color3.fromRGB(88, 148, 198),
		stats     = { WalkSpeed = 2 },
	},
	pet_shark = {
		id        = "pet_shark",
		name      = "Shark",
		modelName = "shark",
		type      = "Pet",
		rarity    = "Rare",
		modelPath = "ItemModels.Pets.Rare.shark",
		image     = "",
		iconText  = "\240\159\166\136",
		iconColor = Color3.fromRGB(108, 128, 158),
		stats     = { CoinMultiplier = 1.05 },
	},
	pet_spider = {
		id        = "pet_spider",
		name      = "Spider",
		modelName = "spider",
		type      = "Pet",
		rarity    = "Rare",
		modelPath = "ItemModels.Pets.Rare.spider",
		image     = "",
		iconText  = "\240\159\149\183",
		iconColor = Color3.fromRGB(38, 38, 48),
		stats     = { JumpPower = 3 },
	},
	pet_eagle = {
		id        = "pet_eagle",
		name      = "Eagle",
		modelName = "eagle",
		type      = "Pet",
		rarity    = "Rare",
		modelPath = "ItemModels.Pets.Rare.eagle",
		image     = "",
		iconText  = "\240\159\166\133",
		iconColor = Color3.fromRGB(128, 88, 48),
		stats     = { WalkSpeed = 2, CoinMultiplier = 1.03 },
	},

	-- ── Epic (3) ──
	pet_axolotl = {
		id        = "pet_axolotl",
		name      = "Axolotl",
		modelName = "axolotl",
		type      = "Pet",
		rarity    = "Epic",
		modelPath = "ItemModels.Pets.Epic.axolotl",
		image     = "",
		iconText  = "\240\159\144\155",
		iconColor = Color3.fromRGB(248, 148, 188),
		stats     = { CoinMultiplier = 1.08, WalkSpeed = 2 },
	},
	pet_bat = {
		id        = "pet_bat",
		name      = "Bat",
		modelName = "bat",
		type      = "Pet",
		rarity    = "Epic",
		modelPath = "ItemModels.Pets.Epic.bat",
		image     = "",
		iconText  = "\240\159\166\135",
		iconColor = Color3.fromRGB(58, 38, 78),
		stats     = { JumpPower = 5, CoinMultiplier = 1.06 },
	},
	pet_dolphin = {
		id        = "pet_dolphin",
		name      = "Dolphin",
		modelName = "dolphin",
		type      = "Pet",
		rarity    = "Epic",
		modelPath = "ItemModels.Pets.Epic.dolphin",
		image     = "",
		iconText  = "\240\159\144\172",
		iconColor = Color3.fromRGB(78, 168, 218),
		stats     = { WalkSpeed = 3, CoinMultiplier = 1.07 },
	},

	-- ── Legendary (6) — Shop-only / Exclusive ──
	pet_rbhp = {
		id        = "pet_rbhp",
		name      = "RBHP Pet",
		modelName = "RBHP Pet",
		type      = "Pet",
		rarity    = "Legendary",
		modelPath = "ItemModels.Pets.Legendary.RBHP Pet",
		image     = "rbxassetid://130563974863986",
		iconText  = "\240\159\148\165",
		iconColor = Color3.fromRGB(255, 58, 58),
		stats     = { CoinMultiplier = 1.20, WalkSpeed = 4, JumpPower = 8 },
		shopOnly  = true,
		obtainable = false,
		source    = "bundle_future",
	},
	pet_toji = {
		id        = "pet_toji",
		name      = "Toji Pet",
		modelName = "Toji Pet",
		type      = "Pet",
		rarity    = "Legendary",
		modelPath = "ItemModels.Pets.Epic.Toji Pet",
		image     = "rbxassetid://70371140256856",
		iconText  = "\240\159\151\161",
		iconColor = Color3.fromRGB(58, 58, 78),
		stats     = { CoinMultiplier = 1.18, WalkSpeed = 3, JumpPower = 6 },
		shopOnly  = true,
		obtainable = false,
		source    = "bundle_future",
	},
	pet_glitched_dragon = {
		id        = "pet_glitched_dragon",
		name      = "Glitched Dragon",
		modelName = "Glitched Dragon",
		type      = "Pet",
		rarity    = "Legendary",
		modelPath = "ItemModels.Pets.Legendary.Glitched Dragon",
		image     = "rbxassetid://105972642773708",
		iconText  = "\240\159\144\137",
		iconColor = Color3.fromRGB(58, 255, 128),
		stats     = { CoinMultiplier = 1.15, WalkSpeed = 3, JumpPower = 5 },
		shopOnly  = true,
	},
	pet_dark_winged_dragon = {
		id        = "pet_dark_winged_dragon",
		name      = "D.W.D",
		modelName = "Dark Winged Dragon",
		type      = "Pet",
		rarity    = "Legendary",
		modelPath = "ItemModels.Pets.Legendary.Dark Winged Dragon",
		image     = "rbxassetid://72226943594824",
		iconText  = "\240\159\144\178",
		iconColor = Color3.fromRGB(48, 28, 68),
		stats     = { CoinMultiplier = 1.15, WalkSpeed = 2, JumpPower = 8 },
		shopOnly  = true,
	},
	pet_pink_butterfly = {
		id        = "pet_pink_butterfly",
		name      = "Pink Butterfly",
		modelName = "Pink Butterfly",
		type      = "Pet",
		rarity    = "Legendary",
		modelPath = "ItemModels.Pets.Legendary.Pink Butterfly",
		image     = "rbxassetid://82261955048760",
		iconText  = "\240\159\166\139",
		iconColor = Color3.fromRGB(255, 148, 208),
		stats     = { CoinMultiplier = 1.12, WalkSpeed = 4 },
		shopOnly  = true,
	},
	pet_dark_falcon = {
		id        = "pet_dark_falcon",
		name      = "Dark Falcon",
		modelName = "Dark Falcon",
		type      = "Pet",
		rarity    = "Legendary",
		modelPath = "ItemModels.Pets.Legendary.Dark Falcon",
		image     = "rbxassetid://138265402881761",
		iconText  = "\240\159\166\133",
		iconColor = Color3.fromRGB(38, 28, 48),
		stats     = { CoinMultiplier = 1.14, WalkSpeed = 3, JumpPower = 6 },
		shopOnly  = true,
	},

	-- ── Brainrot (10) — Save the Brainrot Mode exclusives ──
	pet_brainrot_torrtuginni = {
		id        = "pet_brainrot_torrtuginni",
		name      = "Torrtuginni Dragonfrutini",
		modelName = "Torrtuginni Dragonfrutini",
		type      = "Pet",
		rarity    = "Legendary",
		modelPath = "ItemModels.Pets.Legendary.Brainrots.Torrtuginni Dragonfrutini",
		image     = "rbxassetid://140372335316821",
		iconText  = "\240\159\144\162",
		iconColor = Color3.fromRGB(255, 88, 148),
		stats     = { CoinMultiplier = 1.10, WalkSpeed = 2 },
		obtainable = false,
		source    = "brainrot_mode",
	},
	pet_brainrot_statutino = {
		id        = "pet_brainrot_statutino",
		name      = "Statutino Libertino",
		modelName = "Statutino Libertino",
		type      = "Pet",
		rarity    = "Legendary",
		modelPath = "ItemModels.Pets.Legendary.Brainrots.Statutino Libertino",
		image     = "rbxassetid://103912790516568",
		iconText  = "\240\159\151\189",
		iconColor = Color3.fromRGB(78, 198, 178),
		stats     = { CoinMultiplier = 1.10, JumpPower = 4 },
		obtainable = false,
		source    = "brainrot_mode",
	},
	pet_brainrot_lucky_block = {
		id        = "pet_brainrot_lucky_block",
		name      = "Secret Lucky Block",
		modelName = "Secret Lucky Block",
		type      = "Pet",
		rarity    = "Legendary",
		modelPath = "ItemModels.Pets.Legendary.Brainrots.Secret Lucky Block",
		image     = "",
		iconText  = "\240\159\142\178",
		iconColor = Color3.fromRGB(255, 215, 48),
		stats     = { CoinMultiplier = 1.12 },
		obtainable = false,
		source    = "brainrot_mode",
	},
	pet_brainrot_piccione = {
		id        = "pet_brainrot_piccione",
		name      = "Piccione Macchina",
		modelName = "Piccione Macchina",
		type      = "Pet",
		rarity    = "Legendary",
		modelPath = "ItemModels.Pets.Legendary.Brainrots.Piccione Macchina",
		image     = "rbxassetid://78589744798774",
		iconText  = "\240\159\144\166",
		iconColor = Color3.fromRGB(218, 58, 58),
		stats     = { WalkSpeed = 3, CoinMultiplier = 1.08 },
		obtainable = false,
		source    = "brainrot_mode",
	},
	pet_brainrot_perochello = {
		id        = "pet_brainrot_perochello",
		name      = "Perochello Lemonchello",
		modelName = "Perochello_Lemonchello",
		type      = "Pet",
		rarity    = "Legendary",
		modelPath = "ItemModels.Pets.Legendary.Brainrots.Perochello_Lemonchello",
		image     = "rbxassetid://124591576453134",
		iconText  = "\240\159\141\139",
		iconColor = Color3.fromRGB(255, 238, 68),
		stats     = { CoinMultiplier = 1.10, WalkSpeed = 2 },
		obtainable = false,
		source    = "brainrot_mode",
	},
	pet_brainrot_la_vacca = {
		id        = "pet_brainrot_la_vacca",
		name      = "La Vacca Saturno Saturnita",
		modelName = "La_Vacca_Saturno_Saturnita",
		type      = "Pet",
		rarity    = "Legendary",
		modelPath = "ItemModels.Pets.Legendary.Brainrots.La_Vacca_Saturno_Saturnita",
		image     = "rbxassetid://96497577491317",
		iconText  = "\240\159\144\132",
		iconColor = Color3.fromRGB(148, 68, 218),
		stats     = { JumpPower = 5, CoinMultiplier = 1.10 },
		obtainable = false,
		source    = "brainrot_mode",
	},
	pet_brainrot_ishowspeed = {
		id        = "pet_brainrot_ishowspeed",
		name      = "IShowSpeed",
		modelName = "IShowSpeed",
		type      = "Pet",
		rarity    = "Legendary",
		modelPath = "ItemModels.Pets.Legendary.Brainrots.IShowSpeed",
		image     = "rbxassetid://139903696167071",
		iconText  = "\226\154\161",
		iconColor = Color3.fromRGB(255, 48, 48),
		stats     = { WalkSpeed = 4, CoinMultiplier = 1.08 },
		obtainable = false,
		source    = "brainrot_mode",
	},
	pet_brainrot_gattatino = {
		id        = "pet_brainrot_gattatino",
		name      = "Gattatino Nyanino",
		modelName = "Gattatino_Nyanino",
		type      = "Pet",
		rarity    = "Legendary",
		modelPath = "ItemModels.Pets.Legendary.Brainrots.Gattatino_Nyanino",
		image     = "rbxassetid://105764581200119",
		iconText  = "\240\159\144\136",
		iconColor = Color3.fromRGB(255, 148, 198),
		stats     = { CoinMultiplier = 1.10, WalkSpeed = 2 },
		obtainable = false,
		source    = "brainrot_mode",
	},
	pet_brainrot_cavallo = {
		id        = "pet_brainrot_cavallo",
		name      = "Cavallo Virtuoso",
		modelName = "Cavallo_Virtuoso",
		type      = "Pet",
		rarity    = "Legendary",
		modelPath = "ItemModels.Pets.Legendary.Brainrots.Cavallo_Virtuoso",
		image     = "rbxassetid://136399998348620",
		iconText  = "\240\159\144\180",
		iconColor = Color3.fromRGB(68, 128, 218),
		stats     = { JumpPower = 6, CoinMultiplier = 1.08 },
		obtainable = false,
		source    = "brainrot_mode",
	},
	pet_brainrot_bandito = {
		id        = "pet_brainrot_bandito",
		name      = "Bandito Bobritto",
		modelName = "Bandito_Bobritto",
		type      = "Pet",
		rarity    = "Legendary",
		modelPath = "ItemModels.Pets.Legendary.Brainrots.Bandito_Bobritto",
		image     = "rbxassetid://140031061359562",
		iconText  = "\240\159\166\171",
		iconColor = Color3.fromRGB(148, 98, 58),
		stats     = { CoinMultiplier = 1.12, WalkSpeed = 1 },
		obtainable = false,
		source    = "brainrot_mode",
	},
	pet_brainrot_mog_rot = {
		id        = "pet_brainrot_mog_rot",
		name      = "Mog Rot",
		modelName = "Mog Rot",
		type      = "Pet",
		rarity    = "Legendary",
		modelPath = "ItemModels.Pets.Legendary.Brainrots.Mog Rot",
		image     = "rbxassetid://123729863394112",
		iconText  = "\240\159\144\177",
		iconColor = Color3.fromRGB(188, 128, 68),
		stats     = { CoinMultiplier = 1.10, WalkSpeed = 2 },
		obtainable = false,
		source    = "brainrot_mode",
	},

	-- ── Brainrot Bundle Pets (5) — obtainable via Brainrot Bundle ──
	pet_67 = {
		id        = "pet_67",
		name      = "67",
		modelName = "67",
		type      = "Pet",
		rarity    = "Legendary",
		modelPath = "Pets/Legendary/Brainrot Bundle/67",
		image     = "rbxassetid://107878258401993",
		iconText  = "\240\159\148\165",
		iconColor = Color3.fromRGB(255, 58, 58),
		stats     = { CoinMultiplier = 1.15, WalkSpeed = 3 },
		obtainable = false,
		source    = "brainrot_bundle",
	},
	pet_dragon_cannelloni = {
		id        = "pet_dragon_cannelloni",
		name      = "Dragon Cannelloni",
		modelName = "Dragon Cannelloni",
		type      = "Pet",
		rarity    = "Legendary",
		modelPath = "Pets/Legendary/Brainrot Bundle/Dragon Cannelloni",
		image     = "rbxassetid://135119007461808",
		iconText  = "\240\159\144\137",
		iconColor = Color3.fromRGB(255, 128, 28),
		stats     = { CoinMultiplier = 1.15, WalkSpeed = 3 },
		obtainable = false,
		source    = "brainrot_bundle",
	},
	pet_frigo_camelo = {
		id        = "pet_frigo_camelo",
		name      = "Frigo Camelo",
		modelName = "Frigo Camelo",
		type      = "Pet",
		rarity    = "Legendary",
		modelPath = "Pets/Legendary/Brainrot Bundle/Frigo Camelo",
		image     = "rbxassetid://129072141105154",
		iconText  = "\240\159\144\171",
		iconColor = Color3.fromRGB(78, 198, 255),
		stats     = { CoinMultiplier = 1.15, WalkSpeed = 3 },
		obtainable = false,
		source    = "brainrot_bundle",
	},
	pet_tigroligre_frutonni = {
		id        = "pet_tigroligre_frutonni",
		name      = "Tigroligre Frutonni",
		modelName = "Tigroligre Frutonni",
		type      = "Pet",
		rarity    = "Legendary",
		modelPath = "Pets/Legendary/Brainrot Bundle/Tigroligre Frutonni",
		image     = "rbxassetid://78097046812121",
		iconText  = "\240\159\144\133",
		iconColor = Color3.fromRGB(255, 168, 48),
		stats     = { CoinMultiplier = 1.15, WalkSpeed = 3 },
		obtainable = false,
		source    = "brainrot_bundle",
	},
	pet_trenostruzzo_turbo_3000 = {
		id        = "pet_trenostruzzo_turbo_3000",
		name      = "Trenostruzzo Turbo 3000",
		modelName = "Trenostruzzo Turbo 3000",
		type      = "Pet",
		rarity    = "Legendary",
		modelPath = "Pets/Legendary/Brainrot Bundle/Trenostruzzo_Turbo_3000",
		image     = "rbxassetid://137345287825523",
		iconText  = "\240\159\154\130",
		iconColor = Color3.fromRGB(48, 218, 128),
		stats     = { CoinMultiplier = 1.15, WalkSpeed = 3 },
		obtainable = false,
		source    = "brainrot_bundle",
	},
}

-- ═══════════════════════════════════════════════════════════════════
-- CROWN DEFINITIONS  (17 crowns across 3 sources)
-- ═══════════════════════════════════════════════════════════════════

ItemCatalog.Crowns = {
	-- ── Findable (6) — obtainable via Crown Crate / Spin Wheel ──
	crown_anime_lines = {
		id        = "crown_anime_lines",
		name      = "Anime Lines Crown",
		modelName = "Anime Lines Crown",
		type      = "Crown",
		rarity    = "Rare",
		source    = "Findable",
		modelPath = "ItemModels.Crowns.Findable.Anime Lines Crown",
		image     = "rbxassetid://138880142848143",
		iconText  = "\240\159\145\145",
		iconColor = Color3.fromRGB(255, 98, 128),
		thumbnailBgColor = Color3.fromRGB(38, 15, 25),
		stats     = { CoinMultiplier = 1.05 },
	},
	crown_glitch = {
		id        = "crown_glitch",
		name      = "Glitch Crown",
		modelName = "Glitch Crown",
		type      = "Crown",
		rarity    = "Epic",
		source    = "Findable",
		modelPath = "ItemModels.Crowns.Findable.Glitch Crown",
		image     = "rbxassetid://134821201044707",
		iconText  = "\240\159\145\145",
		iconColor = Color3.fromRGB(48, 255, 148),
		stats     = { CoinMultiplier = 1.08, WalkSpeed = 1 },
	},
	crown_mystical = {
		id        = "crown_mystical",
		name      = "Mystical Crown",
		modelName = "Mystical Crown",
		type      = "Crown",
		rarity    = "Epic",
		source    = "Findable",
		modelPath = "ItemModels.Crowns.Findable.Mystical Crown",
		image     = "rbxassetid://72655456102850",
		iconText  = "\240\159\145\145",
		iconColor = Color3.fromRGB(148, 88, 255),
		stats     = { JumpPower = 4, CoinMultiplier = 1.06 },
	},
	crown_darkness = {
		id        = "crown_darkness",
		name      = "Darkness Crown",
		modelName = "Darkness Crown",
		type      = "Crown",
		rarity    = "Rare",
		source    = "Findable",
		modelPath = "ItemModels.Crowns.Findable.Darkness Crown",
		image     = "rbxassetid://74957106349993",
		iconText  = "\240\159\145\145",
		iconColor = Color3.fromRGB(28, 18, 48),
		thumbnailBgColor = Color3.fromRGB(12, 8, 22),
		stats     = { JumpPower = 3 },
	},
	crown_love = {
		id        = "crown_love",
		name      = "Love Crown",
		modelName = "Love Crown",
		type      = "Crown",
		rarity    = "Rare",
		source    = "Findable",
		modelPath = "ItemModels.Crowns.Findable.Love Crown",
		image     = "rbxassetid://91234042861337",
		iconText  = "\240\159\145\145",
		iconColor = Color3.fromRGB(255, 108, 148),
		thumbnailBgColor = Color3.fromRGB(22, 8, 15),
		stats     = { CoinMultiplier = 1.04 },
	},
	crown_sparkle = {
		id        = "crown_sparkle",
		name      = "Sparkle Crown",
		modelName = "Sparkle Crown",
		type      = "Crown",
		rarity    = "Common",
		source    = "Findable",
		modelPath = "ItemModels.Crowns.Findable.Sparkle Crown",
		image     = "rbxassetid://132865723131777",
		iconText  = "\240\159\145\145",
		iconColor = Color3.fromRGB(255, 228, 148),
		thumbnailBgColor = Color3.fromRGB(38, 32, 18),
		stats     = nil,
	},

	-- ── Basic Color Crowns (7) — Common filler for Crown Crate ──
	crown_red = {
		id        = "crown_red",
		name      = "Red Crown",
		modelName = "Red Crown",
		type      = "Crown",
		rarity    = "Common",
		source    = "Findable",
		modelPath = "ItemModels.Crowns.Findable.Red Crown",
		image     = "",
		iconText  = "\240\159\145\145",
		iconColor = Color3.fromRGB(220, 40, 40),
		stats     = nil,
	},
	crown_blue = {
		id        = "crown_blue",
		name      = "Blue Crown",
		modelName = "Blue Crown",
		type      = "Crown",
		rarity    = "Common",
		source    = "Findable",
		modelPath = "ItemModels.Crowns.Findable.Blue Crown",
		image     = "",
		iconText  = "\240\159\145\145",
		iconColor = Color3.fromRGB(38, 120, 255),
		stats     = nil,
	},
	crown_green = {
		id        = "crown_green",
		name      = "Green Crown",
		modelName = "Green Crown",
		type      = "Crown",
		rarity    = "Common",
		source    = "Findable",
		modelPath = "ItemModels.Crowns.Findable.Green Crown",
		image     = "",
		iconText  = "\240\159\145\145",
		iconColor = Color3.fromRGB(48, 185, 48),
		stats     = nil,
	},
	crown_purple = {
		id        = "crown_purple",
		name      = "Purple Crown",
		modelName = "Purple Crown",
		type      = "Crown",
		rarity    = "Common",
		source    = "Findable",
		modelPath = "ItemModels.Crowns.Findable.Purple Crown",
		image     = "",
		iconText  = "\240\159\145\145",
		iconColor = Color3.fromRGB(148, 58, 218),
		stats     = nil,
	},
	crown_pink = {
		id        = "crown_pink",
		name      = "Pink Crown",
		modelName = "Pink Crown",
		type      = "Crown",
		rarity    = "Common",
		source    = "Findable",
		modelPath = "ItemModels.Crowns.Findable.Pink Crown",
		image     = "",
		iconText  = "\240\159\145\145",
		iconColor = Color3.fromRGB(255, 128, 188),
		stats     = nil,
	},
	crown_white = {
		id        = "crown_white",
		name      = "White Crown",
		modelName = "White Crown",
		type      = "Crown",
		rarity    = "Common",
		source    = "Findable",
		modelPath = "ItemModels.Crowns.Findable.White Crown",
		image     = "",
		iconText  = "\240\159\145\145",
		iconColor = Color3.fromRGB(235, 235, 245),
		stats     = nil,
	},
	crown_orange = {
		id        = "crown_orange",
		name      = "Orange Crown",
		modelName = "Orange Crown",
		type      = "Crown",
		rarity    = "Common",
		source    = "Findable",
		modelPath = "ItemModels.Crowns.Findable.Orange Crown",
		image     = "",
		iconText  = "\240\159\145\145",
		iconColor = Color3.fromRGB(255, 158, 28),
		stats     = nil,
	},

	-- ── Level (7) — earned by wins milestones ──
	crown_normal = {
		id        = "crown_normal",
		name      = "Normal Crown",
		modelName = "Normal Crown",
		type      = "Crown",
		rarity    = "Common",
		source    = "Level",
		modelPath = "ItemModels.Crowns.Level.Normal Crown",
		image     = "",
		iconText  = "\240\159\145\145",
		iconColor = Color3.fromRGB(195, 198, 218),
		stats     = nil,
	},
	crown_ice = {
		id        = "crown_ice",
		name      = "Ice Crown",
		modelName = "Ice Crown",
		type      = "Crown",
		rarity    = "Uncommon",
		source    = "Level",
		modelPath = "ItemModels.Crowns.Level.Ice Crown",
		image     = "rbxassetid://140333135289717",
		iconText  = "\240\159\145\145",
		iconColor = Color3.fromRGB(112, 198, 255),
		stats     = { WalkSpeed = 1 },
	},
	crown_fire = {
		id        = "crown_fire",
		name      = "Fire Crown",
		modelName = "Fire Crown",
		type      = "Crown",
		rarity    = "Rare",
		source    = "Level",
		modelPath = "ItemModels.Crowns.Level.Fire Crown",
		image     = "rbxassetid://125768935495662",
		iconText  = "\240\159\145\145",
		iconColor = Color3.fromRGB(255, 98, 28),
		thumbnailBgColor = Color3.fromRGB(42, 22, 10),
		stats     = { CoinMultiplier = 1.05 },
	},
	crown_slime = {
		id        = "crown_slime",
		name      = "Slime Crown",
		modelName = "Slime Crown",
		type      = "Crown",
		rarity    = "Rare",
		source    = "Level",
		modelPath = "ItemModels.Crowns.Level.Slime Crown",
		image     = "rbxassetid://133158680573826",
		iconText  = "\240\159\145\145",
		iconColor = Color3.fromRGB(88, 228, 68),
		thumbnailBgColor = Color3.fromRGB(18, 38, 15),
		stats     = { WalkSpeed = 2 },
	},
	crown_galactic = {
		id        = "crown_galactic",
		name      = "Galactic Crown",
		modelName = "Galactic Crown",
		type      = "Crown",
		rarity    = "Epic",
		source    = "Level",
		modelPath = "ItemModels.Crowns.Level.Galactic Crown",
		image     = "rbxassetid://72019482753136",
		iconText  = "\240\159\145\145",
		iconColor = Color3.fromRGB(82, 52, 185),
		thumbnailBgColor = Color3.fromRGB(18, 12, 38),
		stats     = { CoinMultiplier = 1.08, WalkSpeed = 1 },
	},
	crown_red_beam = {
		id        = "crown_red_beam",
		name      = "Red Beam Crown",
		modelName = "Red Beam Crown",
		type      = "Crown",
		rarity    = "Epic",
		source    = "Level",
		modelPath = "ItemModels.Crowns.Level.Red Beam Crown",
		image     = "rbxassetid://122813471318576",
		iconText  = "\240\159\145\145",
		iconColor = Color3.fromRGB(255, 38, 38),
		thumbnailBgColor = Color3.fromRGB(38, 12, 12),
		stats     = { JumpPower = 5, CoinMultiplier = 1.06 },
	},
	crown_gold_star = {
		id        = "crown_gold_star",
		name      = "Gold Star Crown",
		modelName = "Gold Star Crown",
		type      = "Crown",
		rarity    = "Legendary",
		source    = "Level",
		modelPath = "ItemModels.Crowns.Level.Gold Star Crown",
		image     = "rbxassetid://96348372111632",
		iconText  = "\240\159\145\145",
		iconColor = Color3.fromRGB(255, 208, 48),
		thumbnailBgColor = Color3.fromRGB(42, 35, 12),
		stats     = { CoinMultiplier = 1.12, WalkSpeed = 2, JumpPower = 3 },
	},

	-- ── Exclusive / Special (6) — Shop-only (Robux) + Daily + Crate ──
	crown_hollow_purple = {
		id        = "crown_hollow_purple",
		name      = "Hollow Purple Crown",
		modelName = "Hollow Purple Crown",
		type      = "Crown",
		rarity    = "Legendary",
		source    = "DailyReward",
		modelPath = "ItemModels.Crowns.Exclusive.Hollow Purple Crown",
		image     = "rbxassetid://71121412594159",
		iconText  = "\240\159\145\145",
		iconColor = Color3.fromRGB(148, 48, 255),
		thumbnailBgColor = Color3.fromRGB(28, 12, 48),
		stats     = { CoinMultiplier = 1.15, WalkSpeed = 3, JumpPower = 5 },
		shopOnly  = true,
		obtainable = false,
	},
	crown_aura = {
		id        = "crown_aura",
		name      = "Aura Crown",
		modelName = "Aura Crown",
		type      = "Crown",
		rarity    = "Legendary",
		source    = "Findable",
		modelPath = "ItemModels.Crowns.Findable.Aura Crown",
		image     = "rbxassetid://125632977173073",
		iconText  = "\240\159\145\145",
		iconColor = Color3.fromRGB(255, 215, 128),
		thumbnailBgColor = Color3.fromRGB(38, 32, 18),
		stats     = { CoinMultiplier = 1.14, WalkSpeed = 2, JumpPower = 4 },
	},
	crown_electric = {
		id        = "crown_electric",
		name      = "Electric Crown",
		modelName = "Electric Crown",
		type      = "Crown",
		rarity    = "Legendary",
		source    = "Exclusive",
		modelPath = "ItemModels.Crowns.Exclusive.Electric Crown",
		image     = "rbxassetid://76259359648400",
		iconText  = "\240\159\145\145",
		iconColor = Color3.fromRGB(48, 198, 255),
		thumbnailBgColor = Color3.fromRGB(18, 25, 42),
		stats     = { CoinMultiplier = 1.10, WalkSpeed = 2 },
		shopOnly  = true,
	},
	crown_infinite_void = {
		id        = "crown_infinite_void",
		name      = "Infinite Void Crown",
		modelName = "Infinite Void Crown",
		type      = "Crown",
		rarity    = "Legendary",
		source    = "Exclusive",
		modelPath = "ItemModels.Crowns.Exclusive.Infinite Void Crown",
		image     = "rbxassetid://86806758712291",
		iconText  = "\240\159\145\145",
		iconColor = Color3.fromRGB(18, 8, 38),
		stats     = { CoinMultiplier = 1.14, JumpPower = 5 },
		shopOnly  = true,
	},
	crown_rengoku = {
		id        = "crown_rengoku",
		name      = "Rengoku Crown",
		modelName = "Rengoku Crown",
		type      = "Crown",
		rarity    = "Legendary",
		source    = "Exclusive",
		modelPath = "ItemModels.Crowns.Exclusive.Rengoku Crown",
		image     = "rbxassetid://129928434935830",
		iconText  = "\240\159\145\145",
		iconColor = Color3.fromRGB(255, 128, 28),
		stats     = { CoinMultiplier = 1.12, WalkSpeed = 3 },
		shopOnly  = true,
	},
	crown_ultra = {
		id        = "crown_ultra",
		name      = "Ultra Crown",
		modelName = "Ultra Crown",
		type      = "Crown",
		rarity    = "Legendary",
		source    = "Exclusive",
		modelPath = "ItemModels.Crowns.Exclusive.Ultra Crown",
		image     = "rbxassetid://113224946425402",
		iconText  = "\240\159\145\145",
		iconColor = Color3.fromRGB(218, 48, 255),
		stats     = { CoinMultiplier = 1.15, WalkSpeed = 2, JumpPower = 4 },
		shopOnly  = true,
	},

	-- ── Brainrot Bundle Crown ──
	crown_67 = {
		id        = "crown_67",
		name      = "67 Crown",
		modelName = "67 Crown",
		type      = "Crown",
		rarity    = "Legendary",
		source    = "brainrot_bundle",
		modelPath = "Crowns/Exclusive/Brainrot Bundle/67 Crown",
		image     = "rbxassetid://131101922850312",
		iconText  = "\240\159\145\145",
		iconColor = Color3.fromRGB(255, 58, 58),
		stats     = { CoinMultiplier = 1.15, WalkSpeed = 2 },
		obtainable = false,
	},
}

-- ═══════════════════════════════════════════════════════════════════
-- LEVEL CROWN MILESTONES  (wins → crown id)
-- ═══════════════════════════════════════════════════════════════════

ItemCatalog.LevelCrownMilestones = {
	{ wins = 1,  crownId = "crown_normal" },
	{ wins = 7,  crownId = "crown_ice" },
	{ wins = 20, crownId = "crown_fire" },
	{ wins = 30, crownId = "crown_slime" },
	{ wins = 40, crownId = "crown_galactic" },
	{ wins = 50, crownId = "crown_red_beam" },
	{ wins = 65, crownId = "crown_gold_star" },
}

-- ═══════════════════════════════════════════════════════════════════
-- CRATE DEFINITIONS
-- ═══════════════════════════════════════════════════════════════════

ItemCatalog.Crates = {
	crate_crown = {
		id        = "crate_crown",
		name      = "Crown Crate",
		image     = "",
		iconText  = "\240\159\145\145",
		iconColor = Color3.fromRGB(185, 68, 235),
	},
	crate_pet_common = {
		id        = "crate_pet_common",
		name      = "Common Pet Crate",
		image     = "",
		iconText  = "\240\159\165\154",
		iconColor = Color3.fromRGB(68, 198, 68),
	},
	crate_pet_rare = {
		id        = "crate_pet_rare",
		name      = "Rare Pet Crate",
		image     = "",
		iconText  = "\240\159\165\154",
		iconColor = Color3.fromRGB(38, 150, 255),
	},
	crate_pet_epic = {
		id        = "crate_pet_epic",
		name      = "Epic Pet Crate",
		image     = "",
		iconText  = "\240\159\165\154",
		iconColor = Color3.fromRGB(178, 42, 255),
	},
}

-- ═══════════════════════════════════════════════════════════════════
-- CRATE POOLS  (used by CrateService for rolling)
-- ═══════════════════════════════════════════════════════════════════

-- DEPRECATED: CratePools — reward tables are now in CrateService (REWARD_TABLES).
-- Kept for reference only; not used at runtime.
ItemCatalog.CratePools = {
	crate_crown = {
		{ source = "Findable", weight = 1 },
	},
	crate_pet_common = {
		{ rarity = "Common", weight = 100 },
	},
	crate_pet_rare = {
		{ rarity = "Rare", weight = 100 },
	},
	crate_pet_epic = {
		{ rarity = "Epic", weight = 100 },
	},
}

-- ═══════════════════════════════════════════════════════════════════
-- COIN IMAGE
-- ═══════════════════════════════════════════════════════════════════

ItemCatalog.CoinImage = "rbxassetid://111156188787000"

-- ═══════════════════════════════════════════════════════════════════
-- CURRENCY DEFINITIONS
-- ═══════════════════════════════════════════════════════════════════

ItemCatalog.Currency = {
	FATE_COINS = {
		id        = "FATE_COINS",
		name      = "Fate Coins",
		type      = "Currency",
		image     = "rbxassetid://72345557707985",
		iconText  = "F",
		iconColor = Color3.fromRGB(255, 215, 38),
	},
}

-- ═══════════════════════════════════════════════════════════════════
-- PREMIUM SHOP DEFINITIONS  (Robux items)
-- ═══════════════════════════════════════════════════════════════════

ItemCatalog.Premium = {
	-- Coin packs (Developer Products)
	coins_500  = { id = "coins_500",  name = "500 Fate Coins",   type = "Currency", image = "rbxassetid://111156188787000", iconText = "F", iconColor = Color3.fromRGB(255, 218, 48),  robux = 100, productId = 3539712298, tag = "POPULAR" },
	coins_2000 = { id = "coins_2000", name = "2,000 Fate Coins", type = "Currency", image = "rbxassetid://111156188787000", iconText = "F", iconColor = Color3.fromRGB(255, 198, 28),  robux = 300, productId = 3539713007, tag = "BEST VALUE" },
	coins_5000 = { id = "coins_5000", name = "5,000 Fate Coins", type = "Currency", image = "rbxassetid://111156188787000", iconText = "F", iconColor = Color3.fromRGB(255, 178, 18),  robux = 600, productId = 3539713203, tag = "" },

	-- Legendary Pets (Gamepasses)
	pet_glitched_dragon    = { id = "pet_glitched_dragon",    name = "Glitched Dragon",    type = "ExclusivePet", rarity = "Legendary", image = "rbxassetid://105972642773708", iconText = "\240\159\144\137", iconColor = Color3.fromRGB(58, 255, 128),  thumbnailBgColor = Color3.fromRGB(12, 32, 22), robux = 250, gamepassId = 1718832641, tag = "EXCLUSIVE", modelPath = "ItemModels.Pets.Legendary.Glitched Dragon" },
	pet_dark_winged_dragon = { id = "pet_dark_winged_dragon", name = "D.W.D", type = "ExclusivePet", rarity = "Legendary", image = "rbxassetid://72226943594824",  iconText = "\240\159\144\178", iconColor = Color3.fromRGB(48, 28, 68),    thumbnailBgColor = Color3.fromRGB(15, 10, 25), robux = 300, gamepassId = 1717772785, tag = "EXCLUSIVE", modelPath = "ItemModels.Pets.Legendary.Dark Winged Dragon" },
	pet_pink_butterfly     = { id = "pet_pink_butterfly",     name = "Pink Butterfly",     type = "ExclusivePet", rarity = "Legendary", image = "rbxassetid://82261955048760",  iconText = "\240\159\166\139", iconColor = Color3.fromRGB(255, 148, 208), thumbnailBgColor = Color3.fromRGB(35, 15, 28), robux = 200, gamepassId = 1716864887, tag = "NEW",       modelPath = "ItemModels.Pets.Legendary.Pink Butterfly" },
	pet_dark_falcon        = { id = "pet_dark_falcon",        name = "Dark Falcon",        type = "ExclusivePet", rarity = "Legendary", image = "rbxassetid://138265402881761", iconText = "\240\159\166\133", iconColor = Color3.fromRGB(38, 28, 48),    thumbnailBgColor = Color3.fromRGB(12, 10, 18), robux = 250, gamepassId = 1716313058, tag = "EXCLUSIVE", modelPath = "ItemModels.Pets.Legendary.Dark Falcon" },

	-- Exclusive Crowns (Gamepasses)
	crown_electric      = { id = "crown_electric",      name = "Electric Crown",      type = "ExclusiveCrown", rarity = "Legendary", image = "rbxassetid://76259359648400",  iconText = "\240\159\145\145", iconColor = Color3.fromRGB(48, 198, 255),  thumbnailBgColor = Color3.fromRGB(18, 25, 42), robux = 150, gamepassId = 1717992747, tag = "EXCLUSIVE", modelPath = "ItemModels.Crowns.Exclusive.Electric Crown" },
	crown_infinite_void = { id = "crown_infinite_void", name = "Infinite Void Crown", type = "ExclusiveCrown", rarity = "Legendary", image = "rbxassetid://86806758712291",  iconText = "\240\159\145\145", iconColor = Color3.fromRGB(18, 8, 38),    thumbnailBgColor = Color3.fromRGB(8, 5, 18),   robux = 250, gamepassId = 1717662811, tag = "LIMITED",   modelPath = "ItemModels.Crowns.Exclusive.Infinite Void Crown" },
	crown_rengoku       = { id = "crown_rengoku",       name = "Rengoku Crown",       type = "ExclusiveCrown", rarity = "Legendary", image = "rbxassetid://129928434935830", iconText = "\240\159\145\145", iconColor = Color3.fromRGB(255, 128, 28),  thumbnailBgColor = Color3.fromRGB(35, 18, 10), robux = 200, gamepassId = 1716918881, tag = "NEW",       modelPath = "ItemModels.Crowns.Exclusive.Rengoku Crown" },
	crown_ultra         = { id = "crown_ultra",         name = "Ultra Crown",         type = "ExclusiveCrown", rarity = "Legendary", image = "rbxassetid://113224946425402", iconText = "\240\159\145\145", iconColor = Color3.fromRGB(218, 48, 255),  thumbnailBgColor = Color3.fromRGB(28, 15, 42), robux = 300, gamepassId = 1717864767, tag = "EXCLUSIVE", modelPath = "ItemModels.Crowns.Exclusive.Ultra Crown" },

	-- Bundles
	bundle_vip     = { id = "bundle_vip",     name = "VIP Bundle",  type = "Bundle", image = "", iconText = "\240\159\142\129", iconColor = Color3.fromRGB(255, 215, 78),  robux = 500, tag = "VIP",  rarity = "Legendary" },
	bundle_starter = { id = "bundle_starter", name = "Starter Pack", type = "Bundle", image = "", iconText = "\240\159\142\129", iconColor = Color3.fromRGB(78, 208, 255),  robux = 100, tag = "DEAL", rarity = "Rare" },
}

-- ═══════════════════════════════════════════════════════════════════
-- ICON DEFINITIONS  (cosmetic only — no stats)
-- ═══════════════════════════════════════════════════════════════════

ItemCatalog.Icons = {
	-- Brainrot Bundle Icons (real images)
	icon_67_kid            = { id = "icon_67_kid",            name = "67 Kid",            image = "rbxassetid://108813228966097", iconText = "\240\159\150\188", rarity = "Legendary", source = "brainrot_bundle" },
	icon_steve_harrington  = { id = "icon_steve_harrington",  name = "Steve Harrington",  image = "rbxassetid://135833855438688", iconText = "\240\159\150\188", rarity = "Legendary", source = "brainrot_bundle" },
	-- Placeholders
	icon_placeholder_1  = { id = "icon_placeholder_1",  name = "???", image = "", iconText = "\240\159\150\188", rarity = "Common" },
	icon_placeholder_2  = { id = "icon_placeholder_2",  name = "???", image = "", iconText = "\240\159\150\188", rarity = "Uncommon" },
	icon_placeholder_3  = { id = "icon_placeholder_3",  name = "???", image = "", iconText = "\240\159\150\188", rarity = "Rare" },
	icon_placeholder_4  = { id = "icon_placeholder_4",  name = "???", image = "", iconText = "\240\159\150\188", rarity = "Epic" },
	icon_placeholder_5  = { id = "icon_placeholder_5",  name = "???", image = "", iconText = "\240\159\150\188", rarity = "Legendary" },
	icon_placeholder_6  = { id = "icon_placeholder_6",  name = "???", image = "", iconText = "\240\159\150\188", rarity = "Common" },
	icon_placeholder_7  = { id = "icon_placeholder_7",  name = "???", image = "", iconText = "\240\159\150\188", rarity = "Uncommon" },
	icon_placeholder_8  = { id = "icon_placeholder_8",  name = "???", image = "", iconText = "\240\159\150\188", rarity = "Rare" },
	icon_placeholder_9  = { id = "icon_placeholder_9",  name = "???", image = "", iconText = "\240\159\150\188", rarity = "Epic" },
	icon_placeholder_10 = { id = "icon_placeholder_10", name = "???", image = "", iconText = "\240\159\150\188", rarity = "Legendary" },
	icon_placeholder_11 = { id = "icon_placeholder_11", name = "???", image = "", iconText = "\240\159\150\188", rarity = "Common" },
	icon_placeholder_12 = { id = "icon_placeholder_12", name = "???", image = "", iconText = "\240\159\150\188", rarity = "Rare" },
}

ItemCatalog._iconOrder = {
	"icon_67_kid", "icon_steve_harrington",
	"icon_placeholder_1", "icon_placeholder_2", "icon_placeholder_3",
	"icon_placeholder_4", "icon_placeholder_5", "icon_placeholder_6",
	"icon_placeholder_7", "icon_placeholder_8", "icon_placeholder_9",
	"icon_placeholder_10", "icon_placeholder_11", "icon_placeholder_12",
}

-- ═══════════════════════════════════════════════════════════════════
-- ICON IMAGES  (3D follower companions — equippable like pets)
-- ═══════════════════════════════════════════════════════════════════

ItemCatalog.IconImages = {
	icon_67_kid = {
		id        = "icon_67_kid",
		name      = "67 Kid Icon Image",
		modelName = "67 Kid Icon Image",
		type      = "IconImage",
		rarity    = "Legendary",
		source    = "brainrot_bundle",
		modelPath = "IconImages/Brainrot Bundle/67 Kid Icon Image",
		image     = "rbxassetid://108813228966097",
		iconText  = "\240\159\150\188",
		iconColor = Color3.fromRGB(255, 58, 58),
		stats     = {},
		obtainable = false,
	},
	icon_steve_harrington = {
		id        = "icon_steve_harrington",
		name      = "Steve Harrington Icon Image",
		modelName = "Steve Harrington Icon Image",
		type      = "IconImage",
		rarity    = "Legendary",
		source    = "brainrot_bundle",
		modelPath = "IconImages/Brainrot Bundle/Steve Harrington Icon Image",
		image     = "rbxassetid://135833855438688",
		iconText  = "\240\159\150\188",
		iconColor = Color3.fromRGB(128, 78, 255),
		stats     = {},
		obtainable = false,
	},
}

ItemCatalog._iconImageOrder = {
	"icon_67_kid", "icon_steve_harrington",
}

-- ═══════════════════════════════════════════════════════════════════
-- NAME -> ID MAPPING  (for SpinWheel compatibility)
-- ═══════════════════════════════════════════════════════════════════

ItemCatalog.NameToId = {}
-- Build automatically from Pets + Crowns + IconImages
do
	for id, pet in pairs(ItemCatalog.Pets) do
		ItemCatalog.NameToId[pet.name] = { category = "Pets", id = id }
	end
	for id, crown in pairs(ItemCatalog.Crowns) do
		ItemCatalog.NameToId[crown.name] = { category = "Crowns", id = id }
	end
	for id, iconImg in pairs(ItemCatalog.IconImages) do
		ItemCatalog.NameToId[iconImg.name] = { category = "IconImages", id = id }
	end
end

-- ═══════════════════════════════════════════════════════════════════
-- HELPER FUNCTIONS
-- ═══════════════════════════════════════════════════════════════════

local TABLES = {
	Pets       = ItemCatalog.Pets,
	Crowns     = ItemCatalog.Crowns,
	Premium    = ItemCatalog.Premium,
	Crates     = ItemCatalog.Crates,
	Icons      = ItemCatalog.Icons,
	IconImages = ItemCatalog.IconImages,
	Currency   = ItemCatalog.Currency,
}

function ItemCatalog.Get(category: string, id: string)
	local tbl = TABLES[category]
	if tbl and id then
		return tbl[id]
	end
	return nil
end

function ItemCatalog.GetPet(id: string)
	return ItemCatalog.Pets[id]
end

function ItemCatalog.GetItem(itemType: string, id: string)
	if itemType == "Pet" then
		return ItemCatalog.Pets[id]
	elseif itemType == "IconImage" then
		return ItemCatalog.IconImages[id]
	end
	return ItemCatalog.Get(itemType, id)
end

function ItemCatalog.GetImage(itemOrPet)
	if itemOrPet and type(itemOrPet) == "table" then
		local img = itemOrPet.image
		if img and type(img) == "string" and img ~= "" then
			return img
		end
	end
	return ItemCatalog.FALLBACK_IMAGE
end

function ItemCatalog.GetImageById(category: string, id: string): string
	local entry = ItemCatalog.Get(category, id)
	return ItemCatalog.GetImage(entry)
end

function ItemCatalog.GetByName(displayName: string)
	local mapping = ItemCatalog.NameToId[displayName]
	if mapping then
		return ItemCatalog.Get(mapping.category, mapping.id)
	end
	return nil
end

function ItemCatalog.GetRarityColor(rarity: string): Color3
	local colors = {
		Common    = Color3.fromRGB(170, 178, 200),
		Uncommon  = Color3.fromRGB(58, 225, 62),
		Rare      = Color3.fromRGB(38, 150, 255),
		Epic      = Color3.fromRGB(178, 42, 255),
		Legendary = Color3.fromRGB(255, 198, 18),
		Exclusive = Color3.fromRGB(255, 58, 58),
	}
	return colors[rarity] or colors.Common
end

local RARITY_ORDER = { Common = 1, Uncommon = 2, Rare = 3, Epic = 4, Legendary = 5, Exclusive = 6 }

function ItemCatalog.GetAllPetsSorted(): { any }
	local list = {}
	for _, pet in pairs(ItemCatalog.Pets) do
		table.insert(list, pet)
	end
	table.sort(list, function(a, b)
		local ra = RARITY_ORDER[a.rarity] or 0
		local rb = RARITY_ORDER[b.rarity] or 0
		if ra ~= rb then return ra < rb end
		return a.name < b.name
	end)
	return list
end

function ItemCatalog.GetAllCrownsSorted(): { any }
	local list = {}
	for _, crown in pairs(ItemCatalog.Crowns) do
		table.insert(list, crown)
	end
	-- Sort: Level first, then Findable, then Exclusive; within group by rarity then name
	local SOURCE_ORDER = { Level = 1, Findable = 2, Exclusive = 3 }
	table.sort(list, function(a, b)
		local sa = SOURCE_ORDER[a.source] or 99
		local sb = SOURCE_ORDER[b.source] or 99
		if sa ~= sb then return sa < sb end
		local ra = RARITY_ORDER[a.rarity] or 0
		local rb = RARITY_ORDER[b.rarity] or 0
		if ra ~= rb then return ra < rb end
		return a.name < b.name
	end)
	return list
end

function ItemCatalog.GetAllIconsSorted(): { any }
	local list = {}
	for _, iconId in ipairs(ItemCatalog._iconOrder) do
		local entry = ItemCatalog.Icons[iconId]
		if entry then
			table.insert(list, entry)
		end
	end
	return list
end

function ItemCatalog.GetAllIconImagesSorted(): { any }
	local list = {}
	for _, iconId in ipairs(ItemCatalog._iconImageOrder) do
		local entry = ItemCatalog.IconImages[iconId]
		if entry then
			table.insert(list, entry)
		end
	end
	return list
end

--- Get all pets of a specific rarity
function ItemCatalog.GetPetsByRarity(rarity: string): { any }
	local list = {}
	for _, pet in pairs(ItemCatalog.Pets) do
		if pet.rarity == rarity then
			table.insert(list, pet)
		end
	end
	return list
end

--- Get all crowns with a specific source
function ItemCatalog.GetCrownsBySource(source: string): { any }
	local list = {}
	for _, crown in pairs(ItemCatalog.Crowns) do
		if crown.source == source then
			table.insert(list, crown)
		end
	end
	return list
end

--- Resolve a model path to a ReplicatedStorage instance (via ItemModelRegistry)
function ItemCatalog.ResolveModelPath(modelPath: string): Instance?
	if not modelPath or modelPath == "" then return nil end
	local Shared = game:GetService("ReplicatedStorage"):FindFirstChild("Shared")
	if not Shared then return nil end
	local regModule = Shared:FindFirstChild("ItemModelRegistry")
	if not regModule then return nil end
	local ok, Registry = pcall(require, regModule)
	if ok and Registry and Registry.Get then
		return Registry.Get(modelPath)
	end
	return nil
end

--- Get the milestone wins required for a level crown (nil if not a level crown)
function ItemCatalog.GetMilestoneWins(crownId: string): number?
	for _, m in ipairs(ItemCatalog.LevelCrownMilestones) do
		if m.crownId == crownId then
			return m.wins
		end
	end
	return nil
end

return ItemCatalog