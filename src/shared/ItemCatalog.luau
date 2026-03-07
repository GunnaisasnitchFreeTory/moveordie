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
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage:FindFirstChild("Shared") or ReplicatedStorage:WaitForChild("Shared", 5)
local UIConfig = Shared and require(Shared:WaitForChild("UIConfig")) or { DebugLogs = false }
local DEBUG_LOGS = UIConfig.DebugLogs == true
local _fnafStaticLogPrinted = false
local FORCED_STATIC_PET_IMAGES: { [string]: string } = {
	pet_dark_winged_dragon = "rbxassetid://128329301968992",
	pet_dark_falcon = "rbxassetid://82837073973871",
	pet_glitched_dragon = "rbxassetid://96913318777670",
	pet_pink_butterfly = "rbxassetid://96693122849195",
}

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
		id        = "pet_bald_guest",
		name      = "Bald Guest",
		modelName = "Bald Guest",
		type      = "Pet",
		rarity    = "Common",
		modelPath = "ItemModels.Pets.Common.Bald Guest",
		image     = "",
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
		iconColor = Color3.fromRGB(78, 168, 218),
		stats     = { WalkSpeed = 3, CoinMultiplier = 1.07 },
	},
	pet_unicorn = {
		id        = "pet_unicorn",
		name      = "Unicorn",
		modelName = "Unicorn",
		type      = "Pet",
		rarity    = "Epic",
		modelPath = "ItemModels.Pets.Epic.Unicorn",
		image     = "",
		iconText = "",
		iconColor = Color3.fromRGB(240, 180, 255),
		stats     = { CoinMultiplier = 1.08, JumpPower = 4 },
		source    = "CRATE",
		crateId   = "crate_pet_epic",
	},
	pet_steve = {
		id        = "pet_steve",
		name      = "Steve",
		modelName = "Steve",
		type      = "Pet",
		rarity    = "Epic",
		modelPath = "ItemModels.Pets.Epic.Steve",
		image     = "",
		iconText = "",
		iconColor = Color3.fromRGB(88, 188, 255),
		stats     = { WalkSpeed = 2, CoinMultiplier = 1.08 },
		source    = "CRATE",
		crateId   = "crate_pet_epic",
	},
	pet_zombie = {
		id        = "pet_zombie",
		name      = "Zombie",
		modelName = "Zombie",
		type      = "Pet",
		rarity    = "Epic",
		modelPath = "ItemModels.Pets.Epic.Zombie",
		image     = "",
		iconText = "",
		iconColor = Color3.fromRGB(90, 170, 90),
		stats     = { CoinMultiplier = 1.08, WalkSpeed = 2 },
		source    = "CRATE",
		crateId   = "crate_pet_epic",
	},
	pet_foxy_plush = {
		id        = "pet_foxy_plush",
		name      = "FoxyPlush",
		modelName = "FoxyPlush",
		type      = "Pet",
		rarity    = "Epic",
		modelPath = "ItemModels.Pets.Epic.FoxyPlush",
		image     = "",
		iconText = "",
		iconColor = Color3.fromRGB(212, 78, 58),
		stats     = { CoinMultiplier = 1.08, WalkSpeed = 2 },
		source    = "CRATE",
		crateId   = "crate_pet_epic",
	},
	pet_chica_plush = {
		id        = "pet_chica_plush",
		name      = "ChicaPlush",
		modelName = "ChicaPlush",
		type      = "Pet",
		rarity    = "Epic",
		modelPath = "ItemModels.Pets.Epic.ChicaPlush",
		image     = "",
		iconText = "",
		iconColor = Color3.fromRGB(238, 198, 78),
		stats     = { CoinMultiplier = 1.08, WalkSpeed = 2 },
		source    = "CRATE",
		crateId   = "crate_pet_epic",
	},
	pet_freddy_plush = {
		id        = "pet_freddy_plush",
		name      = "FreddyPlush",
		modelName = "FreddyPlush",
		type      = "Pet",
		rarity    = "Epic",
		modelPath = "ItemModels.Pets.Epic.FreddyPlush",
		image     = "",
		iconText = "",
		iconColor = Color3.fromRGB(165, 108, 72),
		stats     = { CoinMultiplier = 1.08, WalkSpeed = 2 },
		source    = "CRATE",
		crateId   = "crate_pet_epic",
	},
	pet_bonnie_plush = {
		id        = "pet_bonnie_plush",
		name      = "BonniePlush",
		modelName = "BonniePlush",
		type      = "Pet",
		rarity    = "Epic",
		modelPath = "ItemModels.Pets.Epic.BonniePlush",
		image     = "",
		iconText = "",
		iconColor = Color3.fromRGB(118, 88, 228),
		stats     = { CoinMultiplier = 1.08, WalkSpeed = 2 },
		source    = "CRATE",
		crateId   = "crate_pet_epic",
	},
	pet_fredbear_plush = {
		id        = "pet_fredbear_plush",
		name      = "FredbearPlush",
		modelName = "FredbearPlush",
		type      = "Pet",
		rarity    = "Epic",
		modelPath = "ItemModels.Pets.Epic.FredbearPlush",
		image     = "rbxassetid://74636973353299",
		iconText = "",
		iconColor = Color3.fromRGB(238, 188, 58),
		stats     = { CoinMultiplier = 1.08, WalkSpeed = 2 },
		source    = "CRATE",
		crateId   = "crate_pet_epic",
	},
	pet_huggy_wuggy = {
		id        = "pet_huggy_wuggy",
		name      = "HuggyWuggy",
		modelName = "HuggyWuggy",
		type      = "Pet",
		rarity    = "Epic",
		modelPath = "ItemModels.Pets.Epic.HuggyWuggy",
		image     = "rbxassetid://135200249029461",
		iconText = "",
		iconColor = Color3.fromRGB(88, 188, 255),
		stats     = { CoinMultiplier = 1.08, WalkSpeed = 2 },
		source    = "CRATE",
		crateId   = "crate_pet_epic",
	},
	-- ── Epic (FNAF Collection) ──
	pet_freddy_fazbear = {
		id         = "pet_freddy_fazbear",
		name       = "Freddy Fazbear",
		modelName  = "FreddyFazbear",
		type       = "Pet",
		rarity     = "Epic",
		collection = "FNAF",
		modelPath  = "ItemModels.Pets.Epic.FNAF.FreddyFazbear",
		image      = "rbxassetid://84840145874928",
		iconText   = "",
		iconColor  = Color3.fromRGB(165, 108, 72),
		stats      = { CoinMultiplier = 1.08, WalkSpeed = 2 },
		shopOnly   = true,
		source     = "Shop",
	},
	pet_bonnie = {
		id         = "pet_bonnie",
		name       = "Bonnie",
		modelName  = "Bonnie",
		type       = "Pet",
		rarity     = "Epic",
		collection = "FNAF",
		modelPath  = "ItemModels.Pets.Epic.FNAF.Bonnie",
		image      = "rbxassetid://82413653261556",
		iconText   = "",
		iconColor  = Color3.fromRGB(118, 88, 228),
		stats      = { CoinMultiplier = 1.08, JumpPower = 4 },
		shopOnly   = true,
		source     = "Shop",
	},
	pet_chica = {
		id         = "pet_chica",
		name       = "Chica",
		modelName  = "Chica",
		type       = "Pet",
		rarity     = "Epic",
		collection = "FNAF",
		modelPath  = "ItemModels.Pets.Epic.FNAF.Chica",
		image      = "rbxassetid://85911772941715",
		iconText   = "",
		iconColor  = Color3.fromRGB(238, 198, 78),
		stats      = { CoinMultiplier = 1.09, WalkSpeed = 2 },
		shopOnly   = true,
		source     = "Shop",
	},
	pet_foxy = {
		id         = "pet_foxy",
		name       = "Foxy",
		modelName  = "Foxy",
		type       = "Pet",
		rarity     = "Epic",
		collection = "FNAF",
		modelPath  = "ItemModels.Pets.Epic.FNAF.Foxy",
		image      = "rbxassetid://71660947006015",
		iconText   = "",
		iconColor  = Color3.fromRGB(212, 78, 58),
		stats      = { WalkSpeed = 3, CoinMultiplier = 1.08 },
		shopOnly   = true,
		source     = "Shop",
	},
	pet_golden_freddy = {
		id         = "pet_golden_freddy",
		name       = "Golden Freddy",
		modelName  = "GoldenFreddy",
		type       = "Pet",
		rarity     = "Epic",
		collection = "FNAF",
		modelPath  = "ItemModels.Pets.Epic.FNAF.GoldenFreddy",
		image      = "rbxassetid://131523893063613",
		iconText   = "",
		iconColor  = Color3.fromRGB(238, 188, 58),
		stats      = { CoinMultiplier = 1.10, WalkSpeed = 2, JumpPower = 4 },
		shopOnly   = true,
		source     = "Shop",
	},
	pet_the_puppet = {
		id         = "pet_the_puppet",
		name       = "ThePuppet",
		modelName  = "ThePuppet",
		type       = "Pet",
		rarity     = "Epic",
		collection = "FNAF",
		modelPath  = "ItemModels.Pets.Epic.FNAF.ThePuppet",
		image      = "rbxassetid://131311210371413",
		iconText   = "",
		iconColor  = Color3.fromRGB(220, 220, 220),
		stats      = { CoinMultiplier = 1.08, JumpPower = 4 },
		shopOnly   = true,
		source     = "Shop",
	},
	pet_cupcake = {
		id         = "pet_cupcake",
		name       = "Cupcake",
		modelName  = "Cupcake",
		type       = "Pet",
		rarity     = "Epic",
		collection = "FNAF",
		modelPath  = "ItemModels.Pets.Epic.FNAF.Cupcake",
		image      = "rbxassetid://90262618148713",
		iconText   = "",
		iconColor  = Color3.fromRGB(255, 148, 188),
		stats      = { CoinMultiplier = 1.08, WalkSpeed = 2 },
		shopOnly   = true,
		source     = "Shop",
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
		iconText = "",
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
		iconText = "",
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
		modelAssetId = 96913318777670,
		image     = "",
		iconText = "",
		iconColor = Color3.fromRGB(58, 255, 128),
		stats     = { CoinMultiplier = 1.15, WalkSpeed = 3, JumpPower = 5 },
		shopOnly  = true,
	},
	pet_dark_winged_dragon = {
		id        = "pet_dark_winged_dragon",
		name      = "Music Winged Dragon",
		modelName = "Music Winged Dragon",
		type      = "Pet",
		rarity    = "Legendary",
		modelPath = "ItemModels.Pets.Legendary.Music Winged Dragon",
		modelAssetId = 128329301968992,
		image     = "",
		iconText = "",
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
		modelAssetId = 96693122849195,
		image     = "",
		iconText = "",
		iconColor = Color3.fromRGB(255, 148, 208),
		stats     = { CoinMultiplier = 1.12, WalkSpeed = 4 },
		shopOnly  = true,
	},
	pet_dark_falcon = {
		id        = "pet_dark_falcon",
		name      = "Dark Goblem",
		modelName = "Dark Goblem",
		type      = "Pet",
		rarity    = "Legendary",
		modelPath = "ItemModels.Pets.Legendary.Dark Goblem",
		modelAssetId = 82837073973871,
		image     = "",
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
		iconColor = Color3.fromRGB(188, 128, 68),
		stats     = { CoinMultiplier = 1.10, WalkSpeed = 2 },
		obtainable = false,
		source    = "brainrot_mode",
	},

	-- ── Quest-exclusive Pets ──
	pet_chill_face = {
		id        = "pet_chill_face",
		name      = "Chill Face",
		modelName = "Chill Face",
		type      = "Pet",
		rarity    = "Epic",
		modelPath = "ItemModels.Pets.Epic.Quests.Chill Face",
		image     = "rbxassetid://75985773259235",
		iconText = "",
		iconColor = Color3.fromRGB(88, 200, 255),
		stats     = { CoinMultiplier = 1.10, WalkSpeed = 2 },
		obtainable = false,
		source    = "quest_only",
	},
	pet_tungtungsahur = {
		id        = "pet_tungtungsahur",
		name      = "TungTungSahur",
		modelName = "TUNGTUNGSAHUR",
		type      = "Pet",
		rarity    = "Legendary",
		modelPath = "ItemModels.Pets.Legendary.Brainrots.TUNGTUNGSAHUR",
		image     = "",
		iconText = "",
		iconColor = Color3.fromRGB(255, 60, 60),
		stats     = { CoinMultiplier = 1.20, WalkSpeed = 3, JumpPower = 5 },
		obtainable = false,
		source    = "quest_only",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
		iconColor = Color3.fromRGB(255, 228, 148),
		thumbnailBgColor = Color3.fromRGB(38, 32, 18),
		stats     = nil,
	},

	-- ── New Findable Crowns (4) — Crown Crate + Spin Wheel ──
	crown_mystic_art = {
		id        = "crown_mystic_art",
		name      = "Mystic Art Crown",
		modelName = "Mystic Art Crown",
		type      = "Crown",
		rarity    = "Rare",
		source    = "Findable",
		modelPath = "ItemModels.Crowns.Findable.Mystic Art Crown",
		image     = "rbxassetid://125752788430653",
		iconText = "",
		iconColor = Color3.fromRGB(180, 100, 255),
		thumbnailBgColor = Color3.fromRGB(22, 10, 35),
		stats     = { CoinMultiplier = 1.04 },
	},
	crown_orb = {
		id        = "crown_orb",
		name      = "Orb Crown",
		modelName = "Orb Crown",
		type      = "Crown",
		rarity    = "Rare",
		source    = "Findable",
		modelPath = "ItemModels.Crowns.Findable.Orb Crown",
		image     = "rbxassetid://107881312872800",
		iconText = "",
		iconColor = Color3.fromRGB(48, 200, 255),
		thumbnailBgColor = Color3.fromRGB(10, 22, 38),
		stats     = { JumpPower = 2 },
	},
	crown_pop = {
		id        = "crown_pop",
		name      = "Pop Crown",
		modelName = "Pop Crown",
		type      = "Crown",
		rarity    = "Rare",
		source    = "Findable",
		modelPath = "ItemModels.Crowns.Findable.Pop Crown",
		image     = "rbxassetid://97639748967905",
		iconText = "",
		iconColor = Color3.fromRGB(255, 80, 180),
		thumbnailBgColor = Color3.fromRGB(38, 10, 25),
		stats     = { WalkSpeed = 1 },
	},
	crown_cartoon_smoke = {
		id        = "crown_cartoon_smoke",
		name      = "Cartoon Smoke Crown",
		modelName = "Cartoon Smoke Crown",
		type      = "Crown",
		rarity    = "Rare",
		source    = "Findable",
		modelPath = "ItemModels.Crowns.Findable.Cartoon Smoke Crown",
		image     = "rbxassetid://79501308232884",
		iconText = "",
		iconColor = Color3.fromRGB(160, 160, 160),
		thumbnailBgColor = Color3.fromRGB(20, 20, 22),
		stats     = { CoinMultiplier = 1.03 },
	},

	-- ── Quest Crowns — only via daily quest rewards ──
	crown_disco_party = {
		id        = "crown_disco_party",
		name      = "Disco Party Crown",
		modelName = "Disco Party Crown",
		type      = "Crown",
		rarity    = "Epic",
		source    = "Quest",
		modelPath = "ItemModels.Crowns.Quests.Disco Party Crown",
		image     = "rbxassetid://139778425360139",
		iconText = "",
		iconColor = Color3.fromRGB(255, 180, 48),
		thumbnailBgColor = Color3.fromRGB(38, 30, 10),
		stats     = { CoinMultiplier = 1.08, WalkSpeed = 1 },
		obtainable = false,
	},
	crown_tornado = {
		id        = "crown_tornado",
		name      = "Tornado Crown",
		modelName = "Tornado Crown",
		type      = "Crown",
		rarity    = "Epic",
		source    = "Quest",
		modelPath = "ItemModels.Crowns.Quests.Tornado Crown",
		image     = "rbxassetid://133022094267861",
		iconText = "",
		iconColor = Color3.fromRGB(120, 200, 255),
		thumbnailBgColor = Color3.fromRGB(10, 18, 30),
		stats     = { CoinMultiplier = 1.08, WalkSpeed = 1 },
		obtainable = false,
	},
	crown_black_swirl = {
		id        = "crown_black_swirl",
		name      = "Black Swirl Crown",
		modelName = "Black Swirl Crown",
		type      = "Crown",
		rarity    = "Epic",
		source    = "Quest",
		modelPath = "ItemModels.Crowns.Quests.Black Swirl Crown",
		image     = "rbxassetid://76313910758364",
		iconText = "",
		iconColor = Color3.fromRGB(60, 60, 80),
		thumbnailBgColor = Color3.fromRGB(8, 8, 12),
		stats     = { CoinMultiplier = 1.08, JumpPower = 3 },
		obtainable = false,
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
		iconColor = Color3.fromRGB(48, 198, 255),
		thumbnailBgColor = Color3.fromRGB(18, 25, 42),
		stats     = { CoinMultiplier = 1.10, WalkSpeed = 2 },
		shopOnly  = true,
		fateCoins = 40000,
	},
	crown_portal = {
		id        = "crown_portal",
		name      = "Portal Crown",
		modelName = "Portal Crown",
		type      = "Crown",
		rarity    = "Legendary",
		source    = "Exclusive",
		modelPath = "ItemModels.Crowns.Exclusive.Portal Crown",
		image     = "rbxassetid://81166013366597",
		iconText = "",
		iconColor = Color3.fromRGB(88, 255, 200),
		thumbnailBgColor = Color3.fromRGB(8, 30, 25),
		stats     = { CoinMultiplier = 1.14, WalkSpeed = 3 },
		shopOnly  = true,
		fateCoins = 75000,
	},
	crown_freddy_mask = {
		id        = "crown_freddy_mask",
		name      = "FreddyMaskCrown",
		modelName = "FreddyMaskCrown",
		type      = "Crown",
		rarity    = "Legendary",
		source    = "CROWN_SHOP",
		modelPath = "ItemModels.Crowns.Exclusive.FreddyMaskCrown",
		image     = "rbxassetid://73872999924845",
		iconText = "",
		iconColor = Color3.fromRGB(186, 132, 92),
		thumbnailBgColor = Color3.fromRGB(30, 20, 14),
		stats     = { CoinMultiplier = 1.11, WalkSpeed = 2 },
		shopOnly  = true,
		fateCoins = 80000,
	},
	crown_6am = {
		id        = "crown_6am",
		name      = "6AMCrown",
		modelName = "6AMCrown",
		type      = "Crown",
		rarity    = "Epic",
		source    = "CROWN_SHOP",
		modelPath = "ItemModels.Crowns.Exclusive.6AMCrown",
		image     = "rbxassetid://123607214574977",
		iconText = "",
		iconColor = Color3.fromRGB(120, 185, 255),
		thumbnailBgColor = Color3.fromRGB(12, 20, 32),
		stats     = { CoinMultiplier = 1.08, JumpPower = 3 },
		shopOnly  = true,
		fateCoins = 5000,
	},
	crown_fire_circle = {
		id         = "crown_fire_circle",
		name       = "Fire Circle Crown",
		modelName  = "Fire Circle Crown",
		type       = "Crown",
		rarity     = "Legendary",
		source     = "Exclusive",
		modelPath  = "ItemModels.Crowns.Exclusive.Fire Circle Crown",
		image      = "rbxassetid://121758348091203",
		iconText = "",
		iconColor  = Color3.fromRGB(255, 90, 30),
		thumbnailBgColor = Color3.fromRGB(38, 15, 5),
		stats      = { CoinMultiplier = 1.12, WalkSpeed = 2 },
		shopOnly   = true,
		gamepassId = 1728155288,
	},
	crown_nen_x_killua = {
		id         = "crown_nen_x_killua",
		name       = "Nen X Killua Crown",
		modelName  = "Nen X Killua Crown",
		type       = "Crown",
		rarity     = "Legendary",
		source     = "Exclusive",
		modelPath  = "ItemModels.Crowns.Exclusive.Nen X Killua Crown",
		image      = "rbxassetid://111628191491649",
		iconText = "",
		iconColor  = Color3.fromRGB(140, 200, 255),
		thumbnailBgColor = Color3.fromRGB(10, 18, 38),
		stats      = { CoinMultiplier = 1.12, JumpPower = 4 },
		shopOnly   = true,
		gamepassId = 1728821173,
	},
	crown_slashes = {
		id         = "crown_slashes",
		name       = "Slashes Crown",
		modelName  = "Slashes Crown",
		type       = "Crown",
		rarity     = "Legendary",
		source     = "Exclusive",
		modelPath  = "ItemModels.Crowns.Exclusive.Slashes Crown",
		image      = "rbxassetid://132744048265245",
		iconText = "",
		iconColor  = Color3.fromRGB(255, 215, 255),
		thumbnailBgColor = Color3.fromRGB(28, 18, 38),
		stats      = { CoinMultiplier = 1.10, WalkSpeed = 2 },
		shopOnly   = true,
		gamepassId = 1727051517,
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		iconText = "",
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
		image     = "rbxassetid://108812530080296",
		iconText = "",
		iconColor = Color3.fromRGB(185, 68, 235),
	},
	crate_pet_common = {
		id        = "crate_pet_common",
		name      = "Common Pet Crate",
		image     = "rbxassetid://108812530080296",
		iconText = "",
		iconColor = Color3.fromRGB(68, 198, 68),
	},
	crate_pet_rare = {
		id        = "crate_pet_rare",
		name      = "Rare Pet Crate",
		image     = "rbxassetid://108812530080296",
		iconText = "",
		iconColor = Color3.fromRGB(38, 150, 255),
	},
	crate_pet_epic = {
		id        = "crate_pet_epic",
		name      = "Epic Pet Crate",
		image     = "rbxassetid://108812530080296",
		iconText = "",
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
	coins_500    = { id = "coins_500",    name = "500 Fate Coins",     type = "Currency", image = "rbxassetid://111156188787000", iconText = "F", iconColor = Color3.fromRGB(255, 218, 48), robux = 100,  productId = 3539712298, tag = "POPULAR",    coinsAmount = 500 },
	coins_2000   = { id = "coins_2000",   name = "2,000 Fate Coins",   type = "Currency", image = "rbxassetid://111156188787000", iconText = "F", iconColor = Color3.fromRGB(255, 198, 28), robux = 200,  productId = 3539713007, tag = "",           coinsAmount = 2000 },
	coins_5000   = { id = "coins_5000",   name = "5,000 Fate Coins",   type = "Currency", image = "rbxassetid://111156188787000", iconText = "F", iconColor = Color3.fromRGB(255, 178, 18), robux = 400,  productId = 3539713203, tag = "",           coinsAmount = 5000 },
	coins_10000  = { id = "coins_10000",  name = "10,000 Fate Coins",  type = "Currency", image = "rbxassetid://111156188787000", iconText = "F", iconColor = Color3.fromRGB(255, 170, 24), robux = 500,  productId = 3548924617, tag = "",           coinsAmount = 10000 },
	coins_20000  = { id = "coins_20000",  name = "20,000 Fate Coins",  type = "Currency", image = "rbxassetid://111156188787000", iconText = "F", iconColor = Color3.fromRGB(255, 160, 24), robux = 600,  productId = 3548924750, tag = "",           coinsAmount = 20000 },
	coins_80000  = { id = "coins_80000",  name = "80,000 Fate Coins",  type = "Currency", image = "rbxassetid://111156188787000", iconText = "F", iconColor = Color3.fromRGB(255, 150, 24), robux = 800,  productId = 3548924909, tag = "",           coinsAmount = 80000 },
	coins_100000 = { id = "coins_100000", name = "100,000 Fate Coins", type = "Currency", image = "rbxassetid://111156188787000", iconText = "F", iconColor = Color3.fromRGB(255, 140, 24), robux = 1000, productId = 3548925138, tag = "",           coinsAmount = 100000 },
	coins_150000 = { id = "coins_150000", name = "150,000 Fate Coins", type = "Currency", image = "rbxassetid://111156188787000", iconText = "F", iconColor = Color3.fromRGB(255, 130, 24), robux = 1200, productId = 3548925310, tag = "",           coinsAmount = 150000 },
	coins_200000 = { id = "coins_200000", name = "200,000 Fate Coins", type = "Currency", image = "rbxassetid://111156188787000", iconText = "F", iconColor = Color3.fromRGB(255, 120, 24), robux = 2000, productId = 3548925433, tag = "",           coinsAmount = 200000 },

	-- Legendary Pets (Gamepasses)
	pet_glitched_dragon    = { id = "pet_glitched_dragon",    name = "Glitched Dragon",      type = "ExclusivePet", rarity = "Legendary", image = "rbxassetid://96913318777670",  iconText = "", iconColor = Color3.fromRGB(58, 255, 128),  thumbnailBgColor = Color3.fromRGB(12, 32, 22), robux = 250, gamepassId = 1718832641, tag = "EXCLUSIVE", modelPath = "ItemModels.Pets.Legendary.Glitched Dragon", modelAssetId = 96913318777670 },
	pet_dark_winged_dragon = { id = "pet_dark_winged_dragon", name = "Music Winged Dragon", type = "ExclusivePet", rarity = "Legendary", image = "rbxassetid://128329301968992", iconText = "", iconColor = Color3.fromRGB(48, 28, 68),    thumbnailBgColor = Color3.fromRGB(15, 10, 25), robux = 300, gamepassId = 1717772785, tag = "EXCLUSIVE", modelPath = "ItemModels.Pets.Legendary.Music Winged Dragon", modelAssetId = 128329301968992 },
	pet_pink_butterfly     = { id = "pet_pink_butterfly",     name = "Pink Butterfly",       type = "ExclusivePet", rarity = "Legendary", image = "rbxassetid://96693122849195",  iconText = "", iconColor = Color3.fromRGB(255, 148, 208), thumbnailBgColor = Color3.fromRGB(35, 15, 28), robux = 200, gamepassId = 1716864887, tag = "NEW",       modelPath = "ItemModels.Pets.Legendary.Pink Butterfly", modelAssetId = 96693122849195 },
	pet_dark_falcon        = { id = "pet_dark_falcon",        name = "Dark Goblem",          type = "ExclusivePet", rarity = "Legendary", image = "rbxassetid://82837073973871",  iconText = "", iconColor = Color3.fromRGB(38, 28, 48),    thumbnailBgColor = Color3.fromRGB(12, 10, 18), robux = 250, gamepassId = 1716313058, tag = "EXCLUSIVE", modelPath = "ItemModels.Pets.Legendary.Dark Goblem", modelAssetId = 82837073973871 },
	-- FNAF Epic Pets (temporary Robux pricing)
	pet_freddy_fazbear     = { id = "pet_freddy_fazbear",     name = "Freddy Fazbear",      type = "ExclusivePet", rarity = "Epic",      image = "rbxassetid://84840145874928",  iconText = "", iconColor = Color3.fromRGB(165, 108, 72), thumbnailBgColor = Color3.fromRGB(30, 22, 16), robux = 400, gamepassId = 1885101001, fateCoins = 70000, tag = "NEW", modelPath = "ItemModels.Pets.Epic.FNAF.FreddyFazbear" },
	pet_bonnie             = { id = "pet_bonnie",             name = "Bonnie",              type = "ExclusivePet", rarity = "Epic",      image = "rbxassetid://82413653261556",  iconText = "", iconColor = Color3.fromRGB(118, 88, 228), thumbnailBgColor = Color3.fromRGB(20, 16, 34), robux = 400, gamepassId = 1885101002, fateCoins = 70000, tag = "NEW", modelPath = "ItemModels.Pets.Epic.FNAF.Bonnie" },
	pet_chica              = { id = "pet_chica",              name = "Chica",               type = "ExclusivePet", rarity = "Epic",      image = "rbxassetid://85911772941715",  iconText = "", iconColor = Color3.fromRGB(238, 198, 78), thumbnailBgColor = Color3.fromRGB(34, 28, 12), robux = 400, gamepassId = 1885101003, fateCoins = 70000, tag = "NEW", modelPath = "ItemModels.Pets.Epic.FNAF.Chica" },
	pet_foxy               = { id = "pet_foxy",               name = "Foxy",                type = "ExclusivePet", rarity = "Epic",      image = "rbxassetid://71660947006015",  iconText = "", iconColor = Color3.fromRGB(212, 78, 58),  thumbnailBgColor = Color3.fromRGB(36, 14, 12), robux = 400, gamepassId = 1885101004, fateCoins = 70000, tag = "NEW", modelPath = "ItemModels.Pets.Epic.FNAF.Foxy" },
	pet_golden_freddy      = { id = "pet_golden_freddy",      name = "Golden Freddy",       type = "ExclusivePet", rarity = "Epic",      image = "rbxassetid://131523893063613", iconText = "", iconColor = Color3.fromRGB(238, 188, 58), thumbnailBgColor = Color3.fromRGB(38, 30, 10), robux = 400, gamepassId = 1885101005, fateCoins = 70000, tag = "NEW", modelPath = "ItemModels.Pets.Epic.FNAF.GoldenFreddy" },
	pet_the_puppet         = { id = "pet_the_puppet",         name = "ThePuppet",           type = "ExclusivePet", rarity = "Epic",      image = "rbxassetid://131311210371413", iconText = "", iconColor = Color3.fromRGB(220, 220, 220), thumbnailBgColor = Color3.fromRGB(20, 20, 24), robux = 400, gamepassId = 1885101006, fateCoins = 70000, tag = "NEW", modelPath = "ItemModels.Pets.Epic.FNAF.ThePuppet" },
	pet_cupcake            = { id = "pet_cupcake",            name = "Cupcake",             type = "ExclusivePet", rarity = "Epic",      image = "rbxassetid://90262618148713", iconText = "", iconColor = Color3.fromRGB(255, 148, 188), thumbnailBgColor = Color3.fromRGB(30, 14, 22), robux = 400, gamepassId = 1885101007, fateCoins = 70000, tag = "NEW", modelPath = "ItemModels.Pets.Epic.FNAF.Cupcake" },

	-- Exclusive Crowns (Gamepasses + FateCoins)
	crown_electric      = { id = "crown_electric",      name = "Electric Crown",      type = "ExclusiveCrown", rarity = "Legendary", image = "rbxassetid://76259359648400",  iconText = "", iconColor = Color3.fromRGB(48, 198, 255),  thumbnailBgColor = Color3.fromRGB(18, 25, 42), fateCoins = 40000, tag = "EXCLUSIVE", modelPath = "ItemModels.Crowns.Exclusive.Electric Crown" },
	crown_portal        = { id = "crown_portal",        name = "Portal Crown",        type = "ExclusiveCrown", rarity = "Legendary", image = "rbxassetid://81166013366597",  iconText = "", iconColor = Color3.fromRGB(88, 255, 200),  thumbnailBgColor = Color3.fromRGB(8, 30, 25),  fateCoins = 75000, tag = "EXCLUSIVE", modelPath = "ItemModels.Crowns.Exclusive.Portal Crown" },
	crown_freddy_mask   = { id = "crown_freddy_mask",   name = "FreddyMaskCrown",     type = "ExclusiveCrown", rarity = "Legendary", image = "rbxassetid://73872999924845", iconText = "", iconColor = Color3.fromRGB(186, 132, 92), thumbnailBgColor = Color3.fromRGB(30, 20, 14), fateCoins = 80000, tag = "NEW", modelPath = "ItemModels.Crowns.Exclusive.FreddyMaskCrown" },
	crown_6am           = { id = "crown_6am",           name = "6AMCrown",             type = "ExclusiveCrown", rarity = "Epic",      image = "rbxassetid://123607214574977", iconText = "", iconColor = Color3.fromRGB(120, 185, 255), thumbnailBgColor = Color3.fromRGB(12, 20, 32), fateCoins = 5000, tag = "NEW", modelPath = "ItemModels.Crowns.Exclusive.6AMCrown" },
	crown_fire_circle   = { id = "crown_fire_circle",   name = "Fire Circle Crown",   type = "ExclusiveCrown", rarity = "Legendary", image = "rbxassetid://121758348091203", iconText = "", iconColor = Color3.fromRGB(255, 90, 30),   thumbnailBgColor = Color3.fromRGB(38, 15, 5),  robux = 450, gamepassId = 1728155288, tag = "NEW",       modelPath = "ItemModels.Crowns.Exclusive.Fire Circle Crown" },
	crown_nen_x_killua  = { id = "crown_nen_x_killua",  name = "Nen X Killua Crown",  type = "ExclusiveCrown", rarity = "Legendary", image = "rbxassetid://111628191491649", iconText = "", iconColor = Color3.fromRGB(140, 200, 255), thumbnailBgColor = Color3.fromRGB(10, 18, 38), robux = 400, gamepassId = 1728821173, tag = "EXCLUSIVE", modelPath = "ItemModels.Crowns.Exclusive.Nen X Killua Crown" },
	crown_slashes       = { id = "crown_slashes",       name = "Slashes Crown",       type = "ExclusiveCrown", rarity = "Legendary", image = "rbxassetid://132744048265245", iconText = "", iconColor = Color3.fromRGB(255, 215, 255), thumbnailBgColor = Color3.fromRGB(28, 18, 38), robux = 300, gamepassId = 1727051517, tag = "EXCLUSIVE", modelPath = "ItemModels.Crowns.Exclusive.Slashes Crown" },
	crown_infinite_void = { id = "crown_infinite_void", name = "Infinite Void Crown", type = "ExclusiveCrown", rarity = "Legendary", image = "rbxassetid://86806758712291",  iconText = "", iconColor = Color3.fromRGB(18, 8, 38),    thumbnailBgColor = Color3.fromRGB(8, 5, 18),   robux = 250, gamepassId = 1717662811, tag = "LIMITED",   modelPath = "ItemModels.Crowns.Exclusive.Infinite Void Crown" },
	crown_rengoku       = { id = "crown_rengoku",       name = "Rengoku Crown",       type = "ExclusiveCrown", rarity = "Legendary", image = "rbxassetid://129928434935830", iconText = "", iconColor = Color3.fromRGB(255, 128, 28),  thumbnailBgColor = Color3.fromRGB(35, 18, 10), robux = 200, gamepassId = 1716918881, tag = "NEW",       modelPath = "ItemModels.Crowns.Exclusive.Rengoku Crown" },
	crown_ultra         = { id = "crown_ultra",         name = "Ultra Crown",         type = "ExclusiveCrown", rarity = "Legendary", image = "rbxassetid://113224946425402", iconText = "", iconColor = Color3.fromRGB(218, 48, 255),  thumbnailBgColor = Color3.fromRGB(28, 15, 42), robux = 300, gamepassId = 1717864767, tag = "EXCLUSIVE", modelPath = "ItemModels.Crowns.Exclusive.Ultra Crown" },

	-- Bundles
	bundle_vip     = { id = "bundle_vip",     name = "VIP Bundle",  type = "Bundle", image = "", iconText = "", iconColor = Color3.fromRGB(255, 215, 78),  robux = 500, tag = "VIP",  rarity = "Legendary" },
	bundle_starter = { id = "bundle_starter", name = "Starter Pack", type = "Bundle", image = "", iconText = "", iconColor = Color3.fromRGB(78, 208, 255),  robux = 100, tag = "DEAL", rarity = "Rare" },
}

-- ═══════════════════════════════════════════════════════════════════
-- ICON DEFINITIONS  (cosmetic only — no stats)
-- ═══════════════════════════════════════════════════════════════════

ItemCatalog.Icons = {
	-- Brainrot Bundle Icons (real images)
	icon_67_kid            = { id = "icon_67_kid",            name = "67 Kid",            image = "rbxassetid://108813228966097", iconText = "", rarity = "Legendary", source = "brainrot_bundle" },
	icon_steve_harrington  = { id = "icon_steve_harrington",  name = "Steve Harrington",  image = "rbxassetid://135833855438688", iconText = "", rarity = "Legendary", source = "brainrot_bundle" },
	-- Placeholders
	icon_placeholder_1  = { id = "icon_placeholder_1",  name = "Coming Soon", image = "", iconText = "", rarity = "Common", placeholder = true },
	icon_placeholder_2  = { id = "icon_placeholder_2",  name = "Coming Soon", image = "", iconText = "", rarity = "Uncommon", placeholder = true },
	icon_placeholder_3  = { id = "icon_placeholder_3",  name = "Coming Soon", image = "", iconText = "", rarity = "Rare", placeholder = true },
	icon_placeholder_4  = { id = "icon_placeholder_4",  name = "Coming Soon", image = "", iconText = "", rarity = "Epic", placeholder = true },
	icon_placeholder_5  = { id = "icon_placeholder_5",  name = "Coming Soon", image = "", iconText = "", rarity = "Legendary", placeholder = true },
	icon_placeholder_6  = { id = "icon_placeholder_6",  name = "Coming Soon", image = "", iconText = "", rarity = "Common", placeholder = true },
	icon_placeholder_7  = { id = "icon_placeholder_7",  name = "Coming Soon", image = "", iconText = "", rarity = "Uncommon", placeholder = true },
	icon_placeholder_8  = { id = "icon_placeholder_8",  name = "Coming Soon", image = "", iconText = "", rarity = "Rare", placeholder = true },
	icon_placeholder_9  = { id = "icon_placeholder_9",  name = "Coming Soon", image = "", iconText = "", rarity = "Epic", placeholder = true },
	icon_placeholder_10 = { id = "icon_placeholder_10", name = "Coming Soon", image = "", iconText = "", rarity = "Legendary", placeholder = true },
	icon_placeholder_11 = { id = "icon_placeholder_11", name = "Coming Soon", image = "", iconText = "", rarity = "Common", placeholder = true },
	icon_placeholder_12 = { id = "icon_placeholder_12", name = "Coming Soon", image = "", iconText = "", rarity = "Rare", placeholder = true },
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
		iconText = "",
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
		iconText = "",
		iconColor = Color3.fromRGB(128, 78, 255),
		stats     = {},
		obtainable = false,
	},
	-- Coming soon placeholders (locked grey cards in the Icon Images panel)
	icon_coming_soon_1 = { id = "icon_coming_soon_1", name = "Coming Soon", type = "IconImage", rarity = "Rare",      source = "coming_soon", image = "", iconText = "", iconColor = Color3.fromRGB(80, 160, 255),  stats = {}, obtainable = false },
	icon_coming_soon_2 = { id = "icon_coming_soon_2", name = "Coming Soon", type = "IconImage", rarity = "Epic",      source = "coming_soon", image = "", iconText = "", iconColor = Color3.fromRGB(180, 80, 255),  stats = {}, obtainable = false },
	icon_coming_soon_3 = { id = "icon_coming_soon_3", name = "Coming Soon", type = "IconImage", rarity = "Legendary", source = "coming_soon", image = "", iconText = "", iconColor = Color3.fromRGB(255, 200, 60),  stats = {}, obtainable = false },
	icon_coming_soon_4 = { id = "icon_coming_soon_4", name = "Coming Soon", type = "IconImage", rarity = "Uncommon",  source = "coming_soon", image = "", iconText = "", iconColor = Color3.fromRGB(80, 220, 120),  stats = {}, obtainable = false },
	icon_coming_soon_5 = { id = "icon_coming_soon_5", name = "Coming Soon", type = "IconImage", rarity = "Rare",      source = "coming_soon", image = "", iconText = "", iconColor = Color3.fromRGB(60, 200, 255),  stats = {}, obtainable = false },
	icon_coming_soon_6 = { id = "icon_coming_soon_6", name = "Coming Soon", type = "IconImage", rarity = "Legendary", source = "coming_soon", image = "", iconText = "", iconColor = Color3.fromRGB(255, 80, 160),  stats = {}, obtainable = false },
}

ItemCatalog._iconImageOrder = {
	"icon_67_kid", "icon_steve_harrington",
	"icon_coming_soon_1", "icon_coming_soon_2", "icon_coming_soon_3",
	"icon_coming_soon_4", "icon_coming_soon_5", "icon_coming_soon_6",
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

-- Server startup audit for requested pet model asset IDs.
if RunService:IsServer() then
	print("[PetCatalog] ===== model asset audit =====")
	local auditIds = {
		"pet_dark_winged_dragon",
		"pet_pink_butterfly",
		"pet_dark_falcon",
		"pet_glitched_dragon",
	}
	for _, id in ipairs(auditIds) do
		local pet = ItemCatalog.Pets[id]
		if pet then
			print(string.format("[PetCatalog] %s modelAssetId=%s", id, tostring(pet.modelAssetId or "")))
			if pet.image and pet.image ~= "" then
				print(string.format("[ImageRules] STATIC: %s -> %s", id, pet.image))
			else
				print(string.format("[ImageRules] RENDERER: %s", id))
			end
		end
	end
	print("[PetCatalog] ============================")
end

-- Startup visibility for renderer-only FNAF pets.
do
	local fnafIds = {
		"pet_freddy_fazbear",
		"pet_bonnie",
		"pet_chica",
		"pet_foxy",
		"pet_golden_freddy",
		"pet_the_puppet",
		"pet_cupcake",
	}
	if DEBUG_LOGS then
		for _, id in ipairs(fnafIds) do
			local pet = ItemCatalog.Pets[id]
			if pet then
				if pet.image and pet.image ~= "" then
					print(string.format("[ImageRules] STATIC: %s -> %s", id, pet.image))
				elseif pet.modelPath and pet.modelPath ~= "" then
					print(string.format("[ImageRules] RENDERER: %s -> %s", id, pet.modelPath))
				end
			end
		end
	end

	-- Startup scan for resolver rule verification.
	local rendererNameLogs = {
		{ id = "pet_unicorn", item = ItemCatalog.Pets["pet_unicorn"] },
		{ id = "pet_steve", item = ItemCatalog.Pets["pet_steve"] },
		{ id = "pet_zombie", item = ItemCatalog.Pets["pet_zombie"] },
		{ id = "pet_foxy_plush", item = ItemCatalog.Pets["pet_foxy_plush"] },
		{ id = "pet_chica_plush", item = ItemCatalog.Pets["pet_chica_plush"] },
		{ id = "pet_freddy_plush", item = ItemCatalog.Pets["pet_freddy_plush"] },
		{ id = "pet_bonnie_plush", item = ItemCatalog.Pets["pet_bonnie_plush"] },
		{ id = "pet_fredbear_plush", item = ItemCatalog.Pets["pet_fredbear_plush"] },
		{ id = "pet_huggy_wuggy", item = ItemCatalog.Pets["pet_huggy_wuggy"] },
		{ id = "pet_the_puppet", item = ItemCatalog.Pets["pet_the_puppet"] },
		{ id = "pet_cupcake", item = ItemCatalog.Pets["pet_cupcake"] },
		{ id = "crown_freddy_mask", item = ItemCatalog.Crowns["crown_freddy_mask"] },
		{ id = "crown_6am", item = ItemCatalog.Crowns["crown_6am"] },
	}
	if DEBUG_LOGS then
		for _, entry in ipairs(rendererNameLogs) do
			local item = entry.item
			if item and item.image and item.image ~= "" then
				print(string.format("[ImageRules] STATIC: %s -> %s", entry.id, item.image))
			elseif item and (item.image == nil or item.image == "") and item.modelPath and item.modelPath ~= "" then
				print(string.format("[ImageRules] RENDERER: %s", entry.id))
			end
		end
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

-- Resolves whether an item should use a static image or ThumbnailRenderer.
-- Rule: explicit catalog image always wins and MUST skip renderer.
function ItemCatalog.ResolveCrownOrPetImage(itemId: string, itemType: string)
	local normalized = string.upper(itemType or "")
	local item = nil
	if normalized == "PET" or normalized == "PETS" then
		item = ItemCatalog.Pets[itemId]
	elseif normalized == "CROWN" or normalized == "CROWNS" then
		item = ItemCatalog.Crowns[itemId]
	end

	if not item then
		return { mode = "MISSING", image = "", rendererKey = nil, item = nil }
	end

	if normalized == "PET" then
		local forcedImage = FORCED_STATIC_PET_IMAGES[itemId]
		if forcedImage and forcedImage ~= "" then
			return {
				mode = "STATIC",
				image = forcedImage,
				rendererKey = nil,
				item = item,
			}
		end
	end

	-- Hard rule: FNAF pets always use static images; never ThumbnailRenderer.
	if normalized == "PET" and item.collection == "FNAF" then
		if RunService:IsStudio() and not _fnafStaticLogPrinted then
			_fnafStaticLogPrinted = true
			print("[FNAFImages] Using static images (ThumbnailRenderer disabled for FNAF).")
		end
		local staticImage = (type(item.image) == "string" and item.image ~= "") and item.image or ItemCatalog.FALLBACK_IMAGE
		return {
			mode = "STATIC",
			image = staticImage,
			rendererKey = nil,
			item = item,
		}
	end

	local explicitImage = (type(item.image) == "string" and item.image ~= "") and item.image or ""
	if explicitImage ~= "" then
		return {
			mode = "STATIC",
			image = explicitImage,
			rendererKey = nil,
			item = item,
		}
	end

	local modelPath = (type(item.modelPath) == "string" and item.modelPath ~= "") and item.modelPath or nil
	if modelPath then
		return {
			mode = "RENDERER",
			image = "",
			rendererKey = modelPath,
			item = item,
		}
	end

	return { mode = "MISSING", image = "", rendererKey = nil, item = item }
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

--- Crowns obtainable from the Spin Wheel (catalogId values from SpinWheelConfig).
--- Maintained here so FateCrownsPanel doesn't need to require SpinWheelConfig.
ItemCatalog._spinWheelCrownIds = {
	["crown_sparkle"] = true,
}

--- Pets obtainable from the Spin Wheel (catalogId values from SpinWheelConfig).
ItemCatalog._spinWheelPetIds = {
	["pet_dog"] = true,
	["pet_noob"] = true,
	["pet_penguin"] = true,
}

--- Single source-of-truth label describing how a crown is obtained.
function ItemCatalog.GetCrownAcquisitionLabel(crownId: string): string?
	local crown = ItemCatalog.Crowns[crownId]
	if not crown then return nil end

	if crown.source == "Level" then
		local milestone = ItemCatalog.GetMilestoneWins(crownId)
		if milestone then
			return tostring(milestone) .. (milestone == 1 and " Win" or " Wins")
		end
		return "Wins Milestone"
	elseif crown.source == "Findable" then
		if ItemCatalog._spinWheelCrownIds[crownId] then
			return "Crown Crate / Spin Wheel"
		end
		return "Crown Crate"
	elseif crown.source == "CROWN_SHOP" then
		return "Crown Shop"
	elseif crown.source == "Exclusive" then
		return "Shop"
	elseif crown.source == "DailyReward" then
		return "Daily Reward"
	elseif crown.source == "brainrot_bundle" then
		return "Brainrot Bundle"
	elseif crown.source == "Quest" then
		return "Quests"
	end
	return nil
end

--- Single source-of-truth label describing how a pet is obtained.
function ItemCatalog.GetPetAcquisitionLabel(petId: string): string?
	local pet = ItemCatalog.Pets[petId]
	if not pet then return nil end

	if pet.source == "brainrot_bundle" then
		return "Brainrot Bundle"
	elseif pet.source == "brainrot_mode" then
		return "Save the Brainrot Mode"
	elseif pet.source == "bundle_future" then
		return "Coming Soon"
	elseif pet.source == "CRATE" then
		if pet.crateId == "crate_pet_epic" then
			return "Epic Pet Crate"
		end
		return "Pet Crate"
	elseif pet.shopOnly then
		return "Shop"
	else
		if ItemCatalog._spinWheelPetIds[petId] then
			return "Pet Crate / Spin Wheel"
		end
		return "Pet Crate"
	end
end

--- Single source-of-truth label describing how an icon image is obtained.
function ItemCatalog.GetIconImageAcquisitionLabel(iconImageId: string): string?
	local iconImage = ItemCatalog.IconImages and ItemCatalog.IconImages[iconImageId]
	if not iconImage then return nil end

	local source = iconImage.source
	if source == "brainrot_bundle" then
		return "Brainrot Bundle"
	elseif source == "coming_soon" then
		return "Coming Soon"
	elseif source == "shop" or iconImage.shopOnly then
		return "Shop"
	elseif source == "daily_reward" then
		return "Daily Reward"
	elseif source == "spin_wheel" then
		return "Spin Wheel"
	elseif source and source ~= "" then
		return source:sub(1, 1):upper() .. source:sub(2):gsub("_", " ")
	end
	return "Exclusive"
end

--- Generic dispatcher — resolves acquisition label for any item type.
--- Returns (displayText, badgeType) where badgeType is a canonical enum string.
function ItemCatalog.GetItemAcquisitionInfo(itemType: string, itemId: string): (string?, string?)
	local label: string? = nil

	if itemType == "Crowns" then
		label = ItemCatalog.GetCrownAcquisitionLabel(itemId)
	elseif itemType == "Pets" then
		label = ItemCatalog.GetPetAcquisitionLabel(itemId)
	elseif itemType == "IconImages" then
		label = ItemCatalog.GetIconImageAcquisitionLabel(itemId)
	end

	if not label then return nil, nil end

	local badgeType: string? = nil
	if label == "Brainrot Bundle" then
		badgeType = "EXCLUSIVE_BUNDLE"
	elseif label == "Save the Brainrot Mode" then
		badgeType = "SAVE_BRAINROT_MODE"
	elseif label == "Shop" or label == "Crown Shop" then
		badgeType = "SHOP"
	end

	return label, badgeType
end

--- Startup validation: logs resolution counts per source for each item type.
function ItemCatalog.ValidateAcquisitionLabels()
	local results = { Crowns = {}, Pets = {}, IconImages = {} }
	local failures = {}

	if ItemCatalog.Crowns then
		for id in pairs(ItemCatalog.Crowns) do
			local label = ItemCatalog.GetCrownAcquisitionLabel(id)
			if label then
				results.Crowns[label] = (results.Crowns[label] or 0) + 1
			else
				table.insert(failures, "Crown:" .. id)
			end
		end
	end

	if ItemCatalog.Pets then
		for id in pairs(ItemCatalog.Pets) do
			local label = ItemCatalog.GetPetAcquisitionLabel(id)
			if label then
				results.Pets[label] = (results.Pets[label] or 0) + 1
			else
				table.insert(failures, "Pet:" .. id)
			end
		end
	end

	if ItemCatalog.IconImages then
		for id in pairs(ItemCatalog.IconImages) do
			local label = ItemCatalog.GetIconImageAcquisitionLabel(id)
			if label then
				results.IconImages[label] = (results.IconImages[label] or 0) + 1
			end
		end
	end

	for itemType, counts in pairs(results) do
		for source, count in pairs(counts) do
			print(string.format("[ItemCatalog:Validate] %s -> %s: %d items", itemType, source, count))
		end
	end

	if #failures > 0 then
		warn(string.format("[ItemCatalog:Validate] %d items with no acquisition label: %s",
			#failures, table.concat(failures, ", ")))
	else
		print("[ItemCatalog:Validate] All items have valid acquisition labels")
	end
end

return ItemCatalog