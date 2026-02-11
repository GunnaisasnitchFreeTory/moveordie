--[[
	ItemCatalog
	Single source of truth for item metadata + images + stat modifiers.

	Used by: SpinWheelService (server), SpinWheelScript (client),
	         PetsPanel, IndexPanel, ShopPanel, CrateShopPanel,
	         FateCrownsPanel, IconImagesPanel, StatService

	HOW TO ADD REAL IMAGES:
	  Upload a Decal in Roblox, copy the rbxassetid, then set the
	  corresponding entry's `image` field.  All UIs will pick it up
	  automatically through GetImage / GetImageById.

	STAT MODIFIERS (Step 10):
	  Pets and Crowns may have a `stats` table with optional keys:
	    WalkSpeed      → additive (e.g. +2 walk speed)
	    JumpPower      → additive (e.g. +5 jump power)
	    CoinMultiplier → multiplicative (e.g. 1.10 = +10% coins)
	  Icons are cosmetic only (no stats).
	  StatService reads these tables. No hardcoded stats elsewhere.
]]

local ItemCatalog = {}

-- ═══════════════════════════════════════════════════════════════════
-- FALLBACK PLACEHOLDER
-- ═══════════════════════════════════════════════════════════════════

ItemCatalog.FALLBACK_IMAGE = ""

-- ═══════════════════════════════════════════════════════════════════
-- PET DEFINITIONS  (used by SpinWheel, PetsPanel, IndexPanel, StatService)
-- ═══════════════════════════════════════════════════════════════════

ItemCatalog.Pets = {
	PUPPY_COMMON = {
		id        = "PUPPY_COMMON",
		name      = "Puppy",
		type      = "Pet",
		rarity    = "Common",
		image     = "",
		iconText  = "\240\159\144\182",
		iconColor = Color3.fromRGB(198, 158, 118),
		stats     = { CoinMultiplier = 1.02 },  -- +2% coins
	},
	CHICK_COMMON = {
		id        = "CHICK_COMMON",
		name      = "Chick",
		type      = "Pet",
		rarity    = "Common",
		image     = "",
		iconText  = "\240\159\144\163",
		iconColor = Color3.fromRGB(255, 228, 78),
		stats     = { WalkSpeed = 1 },           -- +1 walk speed
	},
}

-- ═══════════════════════════════════════════════════════════════════
-- COIN IMAGE  (used by SpinWheel segments + Premium Shop coin cards)
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
-- CROWN DEFINITIONS  (keyed by UIConfig.MockCrowns ids)
-- ═══════════════════════════════════════════════════════════════════

ItemCatalog.Crowns = {
	crown_basic   = { id = "crown_basic",   name = "Basic Crown",   type = "Crown", rarity = "Common",    image = "", iconText = "\240\159\145\145", iconColor = Color3.fromRGB(195, 198, 218), stats = nil },
	crown_flame   = { id = "crown_flame",   name = "Flame Crown",   type = "Crown", rarity = "Rare",      image = "", iconText = "\240\159\145\145", iconColor = Color3.fromRGB(255, 98, 28),   stats = { CoinMultiplier = 1.05 } },
	crown_frost   = { id = "crown_frost",   name = "Frost Crown",   type = "Crown", rarity = "Rare",      image = "", iconText = "\240\159\145\145", iconColor = Color3.fromRGB(112, 198, 255), stats = { WalkSpeed = 1 } },
	crown_shadow  = { id = "crown_shadow",  name = "Shadow Crown",  type = "Crown", rarity = "Epic",      image = "", iconText = "\240\159\145\145", iconColor = Color3.fromRGB(88, 42, 128),   stats = { JumpPower = 3 } },
	crown_golden  = { id = "crown_golden",  name = "Golden Crown",  type = "Crown", rarity = "Legendary", image = "", iconText = "\240\159\145\145", iconColor = Color3.fromRGB(255, 208, 48),  stats = { CoinMultiplier = 1.10 } },
	crown_neon    = { id = "crown_neon",    name = "Neon Crown",    type = "Crown", rarity = "Uncommon",  image = "", iconText = "\240\159\145\145", iconColor = Color3.fromRGB(98, 255, 178),  stats = { WalkSpeed = 1 } },
	crown_pixel   = { id = "crown_pixel",   name = "Pixel Crown",   type = "Crown", rarity = "Common",    image = "", iconText = "\240\159\145\145", iconColor = Color3.fromRGB(148, 218, 98),  stats = nil },
	crown_galaxy  = { id = "crown_galaxy",  name = "Galaxy Crown",  type = "Crown", rarity = "Epic",      image = "", iconText = "\240\159\145\145", iconColor = Color3.fromRGB(82, 52, 185),   stats = { CoinMultiplier = 1.08, WalkSpeed = 1 } },
	crown_thunder = { id = "crown_thunder", name = "Thunder Crown", type = "Crown", rarity = "Rare",      image = "", iconText = "\240\159\145\145", iconColor = Color3.fromRGB(255, 228, 58),  stats = { JumpPower = 2 } },
	crown_crystal = { id = "crown_crystal", name = "Crystal Crown", type = "Crown", rarity = "Uncommon",  image = "", iconText = "\240\159\145\145", iconColor = Color3.fromRGB(178, 228, 255), stats = nil },
	crown_phantom = { id = "crown_phantom", name = "Phantom Crown", type = "Crown", rarity = "Legendary", image = "", iconText = "\240\159\145\145", iconColor = Color3.fromRGB(198, 158, 255), stats = { CoinMultiplier = 1.12, JumpPower = 3 } },
	crown_nature  = { id = "crown_nature",  name = "Nature Crown",  type = "Crown", rarity = "Common",    image = "", iconText = "\240\159\145\145", iconColor = Color3.fromRGB(78, 185, 78),   stats = nil },
}

-- ═══════════════════════════════════════════════════════════════════
-- PREMIUM SHOP DEFINITIONS
-- ═══════════════════════════════════════════════════════════════════

ItemCatalog.Premium = {
	coins_500      = { id = "coins_500",      name = "500 Fate Coins",   type = "Currency",       image = "rbxassetid://111156188787000", iconText = "F", iconColor = Color3.fromRGB(255, 218, 48) },
	coins_2000     = { id = "coins_2000",     name = "2,000 Fate Coins", type = "Currency",       image = "rbxassetid://111156188787000", iconText = "F", iconColor = Color3.fromRGB(255, 198, 28) },
	coins_5000     = { id = "coins_5000",     name = "5,000 Fate Coins", type = "Currency",       image = "rbxassetid://111156188787000", iconText = "F", iconColor = Color3.fromRGB(255, 178, 18) },
	crown_royal    = { id = "crown_royal",    name = "Royal Crown",      type = "ExclusiveCrown", image = "", iconText = "\240\159\145\145", iconColor = Color3.fromRGB(218, 48, 255) },
	crown_divine   = { id = "crown_divine",   name = "Divine Crown",     type = "ExclusiveCrown", image = "", iconText = "\240\159\145\145", iconColor = Color3.fromRGB(255, 215, 48) },
	pet_cosmic     = { id = "pet_cosmic",     name = "Cosmic Dragon",    type = "ExclusivePet",   image = "", iconText = "\240\159\144\137", iconColor = Color3.fromRGB(58, 198, 255) },
	pet_nebula     = { id = "pet_nebula",     name = "Nebula Cat",       type = "ExclusivePet",   image = "", iconText = "\240\159\144\177", iconColor = Color3.fromRGB(185, 98, 255) },
	bundle_vip     = { id = "bundle_vip",     name = "VIP Bundle",       type = "Bundle",         image = "", iconText = "\240\159\142\129", iconColor = Color3.fromRGB(255, 215, 78) },
	bundle_starter = { id = "bundle_starter", name = "Starter Pack",     type = "Bundle",         image = "", iconText = "\240\159\142\129", iconColor = Color3.fromRGB(78, 208, 255) },
}

-- ═══════════════════════════════════════════════════════════════════
-- CRATE DEFINITIONS
-- ═══════════════════════════════════════════════════════════════════

ItemCatalog.Crates = {
	crate_crown = { id = "crate_crown", name = "Crown Crate", image = "", iconText = "\240\159\147\166", iconColor = Color3.fromRGB(185, 68, 235) },
	crate_pet   = { id = "crate_pet",   name = "Pet Crate",   image = "", iconText = "\240\159\147\166", iconColor = Color3.fromRGB(255, 145, 35) },
	crate_mega  = { id = "crate_mega",  name = "Mega Crate",  image = "", iconText = "\240\159\147\166", iconColor = Color3.fromRGB(255, 48, 68) },
}

-- ═══════════════════════════════════════════════════════════════════
-- ICON DEFINITIONS  (cosmetic only — no stats)
-- ═══════════════════════════════════════════════════════════════════

ItemCatalog.Icons = {
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
	"icon_placeholder_1", "icon_placeholder_2", "icon_placeholder_3",
	"icon_placeholder_4", "icon_placeholder_5", "icon_placeholder_6",
	"icon_placeholder_7", "icon_placeholder_8", "icon_placeholder_9",
	"icon_placeholder_10", "icon_placeholder_11", "icon_placeholder_12",
}

-- ═══════════════════════════════════════════════════════════════════
-- NAME -> ID MAPPING  (backwards compatibility for crate drops, etc.)
-- ═══════════════════════════════════════════════════════════════════

ItemCatalog.NameToId = {
	["Basic Crown"]   = { category = "Crowns", id = "crown_basic" },
	["Flame Crown"]   = { category = "Crowns", id = "crown_flame" },
	["Frost Crown"]   = { category = "Crowns", id = "crown_frost" },
	["Shadow Crown"]  = { category = "Crowns", id = "crown_shadow" },
	["Golden Crown"]  = { category = "Crowns", id = "crown_golden" },
	["Neon Crown"]    = { category = "Crowns", id = "crown_neon" },
	["Pixel Crown"]   = { category = "Crowns", id = "crown_pixel" },
	["Galaxy Crown"]  = { category = "Crowns", id = "crown_galaxy" },
	["Thunder Crown"] = { category = "Crowns", id = "crown_thunder" },
	["Crystal Crown"] = { category = "Crowns", id = "crown_crystal" },
	["Phantom Crown"] = { category = "Crowns", id = "crown_phantom" },
	["Nature Crown"]  = { category = "Crowns", id = "crown_nature" },
	["Chick"]         = { category = "Pets",   id = "CHICK_COMMON" },
	["Puppy"]         = { category = "Pets",   id = "PUPPY_COMMON" },
}

-- ═══════════════════════════════════════════════════════════════════
-- HELPER FUNCTIONS
-- ═══════════════════════════════════════════════════════════════════

local TABLES = {
	Pets     = ItemCatalog.Pets,
	Crowns   = ItemCatalog.Crowns,
	Premium  = ItemCatalog.Premium,
	Crates   = ItemCatalog.Crates,
	Icons    = ItemCatalog.Icons,
	Currency = ItemCatalog.Currency,
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
	}
	return colors[rarity] or colors.Common
end

function ItemCatalog.GetAllPetsSorted(): { any }
	local list = {}
	for _, pet in pairs(ItemCatalog.Pets) do
		table.insert(list, pet)
	end
	table.sort(list, function(a, b)
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

return ItemCatalog
