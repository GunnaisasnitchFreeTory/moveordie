--[[
	CrateService
	Server-authoritative crate opening logic.

	Handles:
	  • Coin deduction for crate purchases
	  • Weighted random rolling from correct item pool
	  • Duplicate reroll (crowns only, up to 5 attempts)
	  • Duplicate-to-coins fallback (25 coins per dupe)
	  • Item granting via InventoryService
	  • Returns result array to caller (for RemoteFunction response)

	API:
		Init()
		OpenCrate(player, crateId, quantity) → { results: {}, success: boolean, error: string? }
]]

local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared      = ReplicatedStorage:WaitForChild("Shared")
local Server      = ServerScriptService:WaitForChild("Server")
local ItemCatalog = require(Shared:WaitForChild("ItemCatalog"))

local CrateService = {}
local initialized = false

local DUPLICATE_COIN_VALUE = 25
local MAX_REROLL = 5
local MAX_QUANTITY = 10

-- ── Lazy loaders ──
local _EconomyService = nil
local _InventoryService = nil

local function getEconomy()
	if _EconomyService then return _EconomyService end
	local ok, mod = pcall(require, Server:WaitForChild("EconomyService", 10))
	if ok and mod then _EconomyService = mod end
	return _EconomyService
end

local function getInventory()
	if _InventoryService then return _InventoryService end
	local ok, mod = pcall(require, Server:WaitForChild("InventoryService", 10))
	if ok and mod then _InventoryService = mod end
	return _InventoryService
end

local function log(...)
	print("[CrateService]", ...)
end

-- ═══════════════════════════════════════════════════════════════════
-- ROLLING LOGIC
-- ═══════════════════════════════════════════════════════════════════

--- Roll a random pet from a specific rarity pool
local function rollPetCrateByRarity(rarity: string): (string, string) -- (itemId, category)
	local petsOfRarity = ItemCatalog.GetPetsByRarity(rarity)
	if #petsOfRarity == 0 then
		-- Fallback to Common
		petsOfRarity = ItemCatalog.GetPetsByRarity("Common")
	end
	local chosen = petsOfRarity[math.random(1, #petsOfRarity)]
	return chosen.id, "Pets"
end

--- Map crate IDs to their rarity pool
local CRATE_RARITY_MAP = {
	crate_pet_common = "Common",
	crate_pet_rare   = "Rare",
	crate_pet_epic   = "Epic",
}

--- Roll a random crown from the crown crate pool (Findable crowns, equal weight)
local function rollCrownCrate(player: Player): (string, string, boolean) -- (itemId, category, isDuplicate)
	local findableCrowns = ItemCatalog.GetCrownsBySource("Findable")
	if #findableCrowns == 0 then
		return "", "Crowns", true
	end

	local inv = getInventory()

	-- Try rolling with reroll on duplicates
	for attempt = 1, MAX_REROLL do
		local chosen = findableCrowns[math.random(1, #findableCrowns)]
		if not inv or not inv.OwnsItem(player, "Crowns", chosen.id) then
			return chosen.id, "Crowns", false
		end
		-- Already owned — reroll
	end

	-- All attempts were duplicates — pick any and mark as duplicate
	local chosen = findableCrowns[math.random(1, #findableCrowns)]
	return chosen.id, "Crowns", true
end

-- ═══════════════════════════════════════════════════════════════════
-- PRICE LOOKUP
-- ═══════════════════════════════════════════════════════════════════

local CRATE_PRICES = {
	crate_crown = {
		{ quantity = 1, cost = 100, currency = "Coins" },
		{ quantity = 3, cost = 250, currency = "Coins" },
		{ quantity = 5, cost = 399, currency = "Robux" },
	},
	crate_pet_common = {
		{ quantity = 1, cost = 50,  currency = "Coins" },
		{ quantity = 3, cost = 130, currency = "Coins" },
		{ quantity = 5, cost = 199, currency = "Coins" },
	},
	crate_pet_rare = {
		{ quantity = 1, cost = 150, currency = "Coins" },
		{ quantity = 3, cost = 400, currency = "Coins" },
		{ quantity = 5, cost = 599, currency = "Coins" },
	},
	crate_pet_epic = {
		{ quantity = 1, cost = 300, currency = "Coins" },
		{ quantity = 3, cost = 800, currency = "Coins" },
		{ quantity = 5, cost = 999, currency = "Robux" },
	},
}

local function findPrice(crateId: string, quantity: number): { cost: number, currency: string }?
	local prices = CRATE_PRICES[crateId]
	if not prices then return nil end
	for _, p in ipairs(prices) do
		if p.quantity == quantity then
			return p
		end
	end
	return nil
end

-- ═══════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ═══════════════════════════════════════════════════════════════════

function CrateService.Init()
	if initialized then return end
	initialized = true
	log("Initialized")
end

function CrateService.OpenCrate(player: Player, crateId: string, quantity: number): { results: { any }, success: boolean, error: string? }
	-- Validate inputs
	if type(crateId) ~= "string" or type(quantity) ~= "number" then
		return { results = {}, success = false, error = "Invalid arguments" }
	end

	quantity = math.clamp(math.floor(quantity), 1, MAX_QUANTITY)

	if not ItemCatalog.Crates[crateId] then
		return { results = {}, success = false, error = "Unknown crate: " .. tostring(crateId) }
	end

	-- Find price
	local price = findPrice(crateId, quantity)
	if not price then
		return { results = {}, success = false, error = "No price for quantity " .. tostring(quantity) }
	end

	-- Only handle Coins currency server-side (Robux handled by ProcessReceipt)
	if price.currency == "Robux" then
		return { results = {}, success = false, error = "Robux crates must be purchased through the shop" }
	end

	-- Deduct coins
	local economy = getEconomy()
	if not economy then
		return { results = {}, success = false, error = "Economy service unavailable" }
	end

	if not economy.DeductCoins(player, price.cost, "Crate:" .. crateId .. "x" .. quantity) then
		return { results = {}, success = false, error = "Not enough coins" }
	end

	-- Roll items
	local inv = getInventory()
	local results = {}

	for _ = 1, quantity do
		local itemId, category, isDuplicate

		local petRarity = CRATE_RARITY_MAP[crateId]
		if petRarity then
			itemId, category = rollPetCrateByRarity(petRarity)
			isDuplicate = false  -- Pets allow duplicates
		elseif crateId == "crate_crown" then
			itemId, category, isDuplicate = rollCrownCrate(player)
		else
			-- Fallback
			itemId, category, isDuplicate = "", "Pets", true
		end

		local result = {
			itemId = itemId,
			category = category,
			isDuplicate = isDuplicate,
			coinsAwarded = 0,
		}

		if isDuplicate or itemId == "" then
			-- Convert duplicate to coins
			result.coinsAwarded = DUPLICATE_COIN_VALUE
			economy.AwardCoins(player, DUPLICATE_COIN_VALUE, "CrateDuplicate:" .. crateId)
			log(string.format("%s opened %s — duplicate %s, awarded %d coins",
				player.Name, crateId, itemId, DUPLICATE_COIN_VALUE))
		else
			-- Grant item
			if inv then
				inv.GrantItem(player, category, itemId)
			end
			local entry = ItemCatalog.Get(category, itemId)
			log(string.format("%s opened %s — got %s (%s)",
				player.Name, crateId, entry and entry.name or itemId, category))
		end

		table.insert(results, result)
	end

	return { results = results, success = true }
end

return CrateService
