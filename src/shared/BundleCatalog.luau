--[[
	BundleCatalog
	Data module listing all purchasable bundles.
	Used only by BundlePanel for rendering the bundle shop UI.

	Each bundle entry contains:
	  id           – unique string identifier
	  displayName  – UI-visible name
	  coverImage   – rbxassetid for the hero cover art
	  isAvailable  – whether the bundle can currently be purchased
	  isLimited    – show LIMITED badge
	  priceRobux   – Robux price (display only; actual charge via gamepassId/productId)
	  gamepassId   – Game Pass ID for permanent bundles (nil = not yet wired)
	  productId    – Developer Product ID for consumable bundles (nil = not yet wired)
	  tag          – badge text ("NEW", "VIP", "DEAL", "LIMITED", etc.)
	  rarity       – rarity string for border color
	  includes     – ordered list of { category, itemId } pairs

	API:
	  BundleCatalog.GetAll()   → ordered array of bundle entries
	  BundleCatalog.Get(id)    → single entry or nil
]]

local BundleCatalog = {}

local _bundles = {
	{
		id           = "fnaf_pets_bundle",
		displayName  = "FNAF Pets",
		coverImage   = "rbxassetid://72168519670720",
		isAvailable  = true,
		isLimited    = false,
		priceRobux   = 500,
		gamepassId   = 1732407562,
		productId    = nil,
		tag          = "NEW",
		rarity       = "Epic",
		includes     = {
			{ category = "Pets", itemId = "pet_freddy_fazbear" },
			{ category = "Pets", itemId = "pet_bonnie" },
			{ category = "Pets", itemId = "pet_chica" },
			{ category = "Pets", itemId = "pet_foxy" },
			{ category = "Pets", itemId = "pet_golden_freddy" },
			{ category = "Pets", itemId = "pet_the_puppet" },
			{ category = "Pets", itemId = "pet_cupcake" },
		},
	},
	{
		id           = "brainrot_bundle",
		displayName  = "Brainrot Bundle",
		coverImage   = "rbxassetid://137027689618122",
		isAvailable  = true,
		isLimited    = false,
		priceRobux   = 800,
		gamepassId   = 1714491142,
		productId    = nil,
		tag          = "NEW",
		rarity       = "Legendary",
		includes     = {
			{ category = "Pets",       itemId = "pet_67" },
			{ category = "Pets",       itemId = "pet_dragon_cannelloni" },
			{ category = "Pets",       itemId = "pet_frigo_camelo" },
			{ category = "Pets",       itemId = "pet_tigroligre_frutonni" },
			{ category = "Pets",       itemId = "pet_trenostruzzo_turbo_3000" },
			{ category = "Crowns",     itemId = "crown_67" },
			{ category = "IconImages", itemId = "icon_67_kid" },
			{ category = "IconImages", itemId = "icon_steve_harrington" },
		},
	},
	{
		id           = "jjk_bundle",
		displayName  = "JJK Bundle",
		coverImage   = "rbxassetid://98977461567105",
		isAvailable  = false,
		isLimited    = false,
		priceRobux   = 1000,
		productId    = nil,
		tag          = "",
		rarity       = "Legendary",
		includes     = {},
	},
	{
		id           = "bundle_vip",
		displayName  = "VIP Bundle",
		coverImage   = "",
		isAvailable  = false,
		isLimited    = false,
		priceRobux   = 500,
		productId    = nil,
		tag          = "VIP",
		rarity       = "Legendary",
		includes     = {},
	},
	{
		id           = "bundle_starter",
		displayName  = "Starter Pack",
		coverImage   = "",
		isAvailable  = false,
		isLimited    = false,
		priceRobux   = 100,
		productId    = nil,
		tag          = "DEAL",
		rarity       = "Rare",
		includes     = {},
	},
}

local _byId: { [string]: any } = {}
for _, bundle in ipairs(_bundles) do
	_byId[bundle.id] = bundle
end

function BundleCatalog.GetAll()
	return _bundles
end

function BundleCatalog.Get(id: string)
	return _byId[id]
end

return BundleCatalog