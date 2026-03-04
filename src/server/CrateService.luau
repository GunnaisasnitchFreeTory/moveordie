--[[
	CrateService
	Server-authoritative crate opening logic.

	Handles:
	  * Coin deduction for crate purchases
	  * Weighted random rolling from explicit per-item reward tables
	  * Duplicate detection (crowns: reroll up to 5 attempts; pets: single roll)
	  * Duplicates receive NO refund — client shows "Already Owned"
	  * Item granting via InventoryService
	  * Returns result array to caller (for RemoteFunction response)

	Reward tables use explicit per-item weights for easy tuning.
	To adjust drop rates, edit REWARD_TABLES below.

	API:
		Init()
		OpenCrate(player, crateId, quantity) → { results: {}, success: boolean, error: string? }
		RollCrateFree(player, crateId, quantity) → { results: {}, success: boolean, error: string? }
		DebugSimulate(crateId, rolls)  — Studio-only: simulate N rolls, print distribution
]]

local RunService           = game:GetService("RunService")
local ReplicatedStorage    = game:GetService("ReplicatedStorage")
local ServerScriptService  = game:GetService("ServerScriptService")
local HttpService          = game:GetService("HttpService")

local Shared      = ReplicatedStorage:WaitForChild("Shared")
local Server      = ServerScriptService:WaitForChild("Server")
local ItemCatalog = require(Shared:WaitForChild("ItemCatalog"))

local CrateService = {}
local initialized = false

local MAX_REROLL   = 5
local MAX_QUANTITY = 10

-- ── Lazy loaders ──
local _EconomyService = nil
local _InventoryService = nil
local _GrantService = nil
local _PlayerDataService = nil

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

local function getGrantService()
	if _GrantService then return _GrantService end
	local ok, mod = pcall(require, Server:WaitForChild("GrantService", 10))
	if ok and mod then _GrantService = mod end
	return _GrantService
end

local function getPlayerData()
	if _PlayerDataService then return _PlayerDataService end
	local ok, mod = pcall(require, Server:WaitForChild("PlayerDataService", 10))
	if ok and mod then _PlayerDataService = mod end
	return _PlayerDataService
end

local function log(...)
	print("[CrateService]", ...)
end

-- ═══════════════════════════════════════════════════════════════════
-- REWARD TABLES  (explicit per-item weights — easy to tune)
-- ═══════════════════════════════════════════════════════════════════

local REWARD_TABLES = {
	-- Weights tuned for heavy grind: Rare ~0.3%, Epic ~0.15%, Aura ~0.07%
	crate_crown = {
		{ itemId = "crown_red",            category = "Crowns", weight = 50 },
		{ itemId = "crown_blue",           category = "Crowns", weight = 50 },
		{ itemId = "crown_green",          category = "Crowns", weight = 50 },
		{ itemId = "crown_purple",         category = "Crowns", weight = 50 },
		{ itemId = "crown_pink",           category = "Crowns", weight = 50 },
		{ itemId = "crown_white",          category = "Crowns", weight = 50 },
		{ itemId = "crown_orange",         category = "Crowns", weight = 50 },
		{ itemId = "crown_sparkle",        category = "Crowns", weight = 3 },
		{ itemId = "crown_anime_lines",    category = "Crowns", weight = 1 },
		{ itemId = "crown_darkness",       category = "Crowns", weight = 1 },
		{ itemId = "crown_love",           category = "Crowns", weight = 1 },
		{ itemId = "crown_mystic_art",     category = "Crowns", weight = 1 },
		{ itemId = "crown_orb",            category = "Crowns", weight = 1 },
		{ itemId = "crown_pop",            category = "Crowns", weight = 1 },
		{ itemId = "crown_cartoon_smoke",  category = "Crowns", weight = 1 },
		{ itemId = "crown_glitch",         category = "Crowns", weight = 1 },
		{ itemId = "crown_mystical",       category = "Crowns", weight = 1 },
		{ itemId = "crown_aura",           category = "Crowns", weight = 1 },
	},
	crate_pet_common = {
		{ itemId = "pet_bald_guest", category = "Pets", weight = 15 },
		{ itemId = "pet_dog",        category = "Pets", weight = 15 },
		{ itemId = "pet_noob",       category = "Pets", weight = 14 },
		{ itemId = "pet_duck",       category = "Pets", weight = 14 },
		{ itemId = "pet_rabbit",     category = "Pets", weight = 14 },
		{ itemId = "pet_crocodile",  category = "Pets", weight = 14 },
		{ itemId = "pet_parrot",     category = "Pets", weight = 14 },
	},
	crate_pet_rare = {
		{ itemId = "pet_scorpion",  category = "Pets", weight = 20 },
		{ itemId = "pet_ray_fish",  category = "Pets", weight = 20 },
		{ itemId = "pet_shark",     category = "Pets", weight = 20 },
		{ itemId = "pet_spider",    category = "Pets", weight = 20 },
		{ itemId = "pet_eagle",     category = "Pets", weight = 20 },
	},
	crate_pet_epic = {
		{ itemId = "pet_axolotl",       category = "Pets", weight = 10 },
		{ itemId = "pet_bat",           category = "Pets", weight = 10 },
		{ itemId = "pet_dolphin",       category = "Pets", weight = 10 },
		{ itemId = "pet_unicorn",       category = "Pets", weight = 10 },
		{ itemId = "pet_steve",         category = "Pets", weight = 10 },
		{ itemId = "pet_zombie",        category = "Pets", weight = 10 },
		{ itemId = "pet_foxy_plush",    category = "Pets", weight = 10 },
		{ itemId = "pet_chica_plush",   category = "Pets", weight = 10 },
		{ itemId = "pet_freddy_plush",  category = "Pets", weight = 7 },
		{ itemId = "pet_bonnie_plush",  category = "Pets", weight = 7 },
		{ itemId = "pet_fredbear_plush", category = "Pets", weight = 3 },
		{ itemId = "pet_huggy_wuggy",   category = "Pets", weight = 3 },
	},
}

-- ═══════════════════════════════════════════════════════════════════
-- WEIGHTED ROLL HELPERS
-- ═══════════════════════════════════════════════════════════════════

local function totalWeight(entries): number
	local t = 0
	for _, e in ipairs(entries) do t += e.weight end
	return t
end

local function normalizeWeights(entries)
	local tw = totalWeight(entries)
	local result = {}
	for _, e in ipairs(entries) do
		table.insert(result, {
			itemId = e.itemId,
			weight = e.weight,
			pct = if tw > 0 then (e.weight / tw) * 100 else 0,
		})
	end
	return result
end

local function weightedRoll(entries)
	local tw = totalWeight(entries)
	if tw <= 0 then return entries[1] end
	local roll = math.random() * tw
	local cumulative = 0
	for _, e in ipairs(entries) do
		cumulative += e.weight
		if roll <= cumulative then return e end
	end
	return entries[#entries]
end

-- ═══════════════════════════════════════════════════════════════════
-- ROLLING LOGIC
-- ═══════════════════════════════════════════════════════════════════

local function rollItem(player: Player, crateId: string): (string, string, boolean)
	local entries = REWARD_TABLES[crateId]
	if not entries or #entries == 0 then
		warn("[CrateService] No reward table for crate:", crateId)
		return "", "Pets", true
	end

	local inv = getInventory()
	local isCrown = (crateId == "crate_crown")

	if isCrown and inv then
		for _ = 1, MAX_REROLL do
			local entry = weightedRoll(entries)
			if not inv.OwnsItem(player, entry.category, entry.itemId) then
				return entry.itemId, entry.category, false
			end
		end
		local entry = weightedRoll(entries)
		return entry.itemId, entry.category, true
	else
		local entry = weightedRoll(entries)
		local isDup = false
		if inv and inv.OwnsItem(player, entry.category, entry.itemId) then
			isDup = true
		end
		return entry.itemId, entry.category, isDup
	end
end

-- ═══════════════════════════════════════════════════════════════════
-- PRICE LOOKUP
-- ═══════════════════════════════════════════════════════════════════

local UNIFIED_PRICES = {
	{ quantity = 1, cost = 500, currency = "Coins" },
	{ quantity = 3, cost = 800, currency = "Coins" },
	{ quantity = 6, cost = 400, currency = "Robux" },
}

local RARE_PET_PRICES = {
	{ quantity = 1, cost = 800, currency = "Coins" },
	{ quantity = 3, cost = 1400, currency = "Coins" },
	{ quantity = 6, cost = 400, currency = "Robux" },
}

local EPIC_PET_PRICES = {
	{ quantity = 1, cost = 1400, currency = "Coins" },
	{ quantity = 3, cost = 1950, currency = "Coins" },
	{ quantity = 6, cost = 400, currency = "Robux" },
}

local CRATE_PRICES = {
	crate_crown      = UNIFIED_PRICES,
	crate_pet_common = UNIFIED_PRICES,
	crate_pet_rare   = RARE_PET_PRICES,
	crate_pet_epic   = EPIC_PET_PRICES,
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

	local priceIds, rewardIds, catalogIds = {}, {}, {}
	for id in pairs(CRATE_PRICES) do table.insert(priceIds, id) end
	for id in pairs(REWARD_TABLES) do table.insert(rewardIds, id) end
	for id in pairs(ItemCatalog.Crates) do table.insert(catalogIds, id) end
	table.sort(priceIds); table.sort(rewardIds); table.sort(catalogIds)

	log("=== Crate ID sanity check ===")
	log("  CRATE_PRICES:       ", table.concat(priceIds, ", "))
	log("  REWARD_TABLES:      ", table.concat(rewardIds, ", "))
	log("  ItemCatalog.Crates: ", table.concat(catalogIds, ", "))

	local priceSet, rewardSet, catalogSet = {}, {}, {}
	for _, id in ipairs(priceIds) do priceSet[id] = true end
	for _, id in ipairs(rewardIds) do rewardSet[id] = true end
	for _, id in ipairs(catalogIds) do catalogSet[id] = true end

	for id in pairs(priceSet) do
		if not catalogSet[id] then warn("[CrateService] MISMATCH:", id, "in CRATE_PRICES but NOT in ItemCatalog.Crates") end
		if not rewardSet[id] then warn("[CrateService] MISMATCH:", id, "in CRATE_PRICES but NOT in REWARD_TABLES") end
	end
	for id in pairs(rewardSet) do
		if not priceSet[id] then warn("[CrateService] MISMATCH:", id, "in REWARD_TABLES but NOT in CRATE_PRICES") end
	end

	for _, crateId in ipairs(rewardIds) do
		local nw = normalizeWeights(REWARD_TABLES[crateId])
		local parts = {}
		for _, e in ipairs(nw) do
			table.insert(parts, string.format("%s=%.1f%%", e.itemId, e.pct))
		end
		log("  Weights [" .. crateId .. "]: " .. table.concat(parts, ", "))
	end

	log("Initialized —", #priceIds, "crate types")
end

function CrateService.GetCrateCounts(player: Player): { [string]: number }
	local pds = getPlayerData()
	if not pds then return {} end
	local data = pds.GetData(player)
	if not data then return {} end
	local owned = data.OwnedCrates
	if type(owned) ~= "table" then
		owned = {}
		pds.SetField(player, "OwnedCrates", owned)
	end
	return owned
end

function CrateService.GetCrateCount(player: Player, crateId: string): number
	local counts = CrateService.GetCrateCounts(player)
	local n = tonumber(counts[crateId]) or 0
	return math.max(0, math.floor(n))
end

function CrateService.AddCrates(player: Player, crateId: string, quantity: number, source: string?): { success: boolean, reason: string?, newCount: number? }
	quantity = math.max(1, math.floor(quantity or 0))
	if not ItemCatalog.Crates[crateId] then
		return { success = false, reason = "Unknown crate type" }
	end
	local pds = getPlayerData()
	if not pds or not pds.IsLoaded(player) then
		return { success = false, reason = "Data not loaded" }
	end

	local data = pds.GetData(player)
	if not data then
		return { success = false, reason = "Data not loaded" }
	end
	local counts = data.OwnedCrates
	if type(counts) ~= "table" then
		counts = {}
	end
	local current = tonumber(counts[crateId]) or 0
	local newCount = current + quantity
	counts[crateId] = newCount
	pds.SetField(player, "OwnedCrates", counts)

	print(string.format("[CrateBuy] SUCCESS player=%s crateType=%s qty=%d newCount=%d source=%s",
		player.Name, crateId, quantity, newCount, tostring(source or "Unknown")))
	return { success = true, newCount = newCount }
end

function CrateService.OpenOwnedCrates(player: Player, crateId: string, quantity: number): { results: { any }, success: boolean, error: string?, newCount: number? }
	if type(crateId) ~= "string" or type(quantity) ~= "number" then
		return { results = {}, success = false, error = "Invalid arguments" }
	end
	quantity = math.clamp(math.floor(quantity), 1, MAX_QUANTITY)
	if not ItemCatalog.Crates[crateId] then
		return { results = {}, success = false, error = "Unknown crate: " .. tostring(crateId) }
	end

	local pds = getPlayerData()
	if not pds or not pds.IsLoaded(player) then
		return { results = {}, success = false, error = "Data not loaded" }
	end
	local data = pds.GetData(player)
	if not data then
		return { results = {}, success = false, error = "Data not loaded" }
	end

	local counts = data.OwnedCrates
	if type(counts) ~= "table" then
		counts = {}
	end
	local current = math.max(0, math.floor(tonumber(counts[crateId]) or 0))
	if current < quantity then
		return { results = {}, success = false, error = "Not enough owned crates" }
	end

	local newCount = current - quantity
	counts[crateId] = newCount
	pds.SetField(player, "OwnedCrates", counts)

	local rolled = CrateService.RollCrateFree(player, crateId, quantity)
	if not rolled.success then
		-- Roll failed after consume: restore crate balance.
		counts[crateId] = current
		pds.SetField(player, "OwnedCrates", counts)
		return { results = {}, success = false, error = rolled.error or "Open failed" }
	end

	return {
		results = rolled.results or {},
		success = true,
		newCount = newCount,
	}
end

function CrateService.BuyCrateWithCoins(player: Player, crateId: string, quantity: number): { success: boolean, reason: string?, newCount: number?, cost: number? }
	if type(crateId) ~= "string" or type(quantity) ~= "number" then
		print(string.format("[CrateBuy] FAIL reason=%s", "Invalid arguments"))
		return { success = false, reason = "Invalid arguments" }
	end
	quantity = math.clamp(math.floor(quantity), 1, MAX_QUANTITY)
	local price = findPrice(crateId, quantity)
	if not price then
		print(string.format("[CrateBuy] FAIL reason=%s", "No price for quantity"))
		return { success = false, reason = "No price for quantity" }
	end
	if price.currency ~= "Coins" then
		print(string.format("[CrateBuy] FAIL reason=%s", "Robux purchase required"))
		return { success = false, reason = "Robux purchase required" }
	end
	local economy = getEconomy()
	if not economy then
		print(string.format("[CrateBuy] FAIL reason=%s", "Economy service unavailable"))
		return { success = false, reason = "Economy service unavailable" }
	end
	if not economy.DeductCoins(player, price.cost, "CrateBuy:" .. crateId .. "x" .. quantity) then
		print(string.format("[CrateBuy] FAIL reason=%s", "INSUFFICIENT_FUNDS"))
		return { success = false, reason = "INSUFFICIENT_FUNDS" }
	end
	local add = CrateService.AddCrates(player, crateId, quantity, "Coins")
	if not add.success then
		economy.AwardCoins(player, price.cost, "CrateBuyRefund:" .. crateId, true)
		print(string.format("[CrateBuy] FAIL reason=%s", tostring(add.reason or "AddCrates failed")))
		return { success = false, reason = add.reason or "AddCrates failed" }
	end
	return { success = true, newCount = add.newCount, cost = price.cost }
end

function CrateService.OpenCrate(player: Player, crateId: string, quantity: number): { results: { any }, success: boolean, error: string? }
	if type(crateId) ~= "string" or type(quantity) ~= "number" then
		return { results = {}, success = false, error = "Invalid arguments" }
	end

	quantity = math.clamp(math.floor(quantity), 1, MAX_QUANTITY)

	if not ItemCatalog.Crates[crateId] then
		return { results = {}, success = false, error = "Unknown crate: " .. tostring(crateId) }
	end

	local price = findPrice(crateId, quantity)
	if not price then
		return { results = {}, success = false, error = "No price for quantity " .. tostring(quantity) }
	end

	if price.currency == "Robux" then
		return { results = {}, success = false, error = "Robux crates must be purchased through the shop" }
	end

	local economy = getEconomy()
	if not economy then
		return { results = {}, success = false, error = "Economy service unavailable" }
	end

	if not economy.DeductCoins(player, price.cost, "Crate:" .. crateId .. "x" .. quantity) then
		return { results = {}, success = false, error = "Not enough coins" }
	end

	local grant = getGrantService()
	if not grant then
		return { results = {}, success = false, error = "Grant service unavailable" }
	end

	local crateTxnId = HttpService:GenerateGUID(false)
	local results = {}
	local grantedPopupItems = {}

	for rollIndex = 1, quantity do
		local itemId, category, isDuplicate = rollItem(player, crateId)

		local catalogEntry = ItemCatalog.Get(category, itemId)
		local result = {
			itemId = itemId,
			category = category,
			isDuplicate = isDuplicate,
			coinsAwarded = 0,
			displayName = catalogEntry and catalogEntry.name or itemId,
			rarity = catalogEntry and catalogEntry.rarity or "Common",
		}

		if isDuplicate or itemId == "" then
			log(string.format("%s opened %s — already owned: %s (%s)",
				player.Name, crateId, itemId, category))
		else
			local grantType = (category == "Crowns") and "Crown" or "Pet"
			local grantRes = grant.GrantItem(player, grantType, itemId, "Crate", {
				fireReward = false,
				idempotencyKey = string.format("crate:%s:%s:%d:%s", player.UserId, crateTxnId, rollIndex, itemId),
				payload = {
					type = grantType,
					id = itemId,
					category = category,
					source = "Crate",
					rarity = result.rarity,
					name = result.displayName,
				},
			})
			if grantRes.success then
				result.grantSuccess = true
				table.insert(grantedPopupItems, {
					type = grantType,
					id = itemId,
					category = category,
					source = "Crate",
					rarity = result.rarity,
					name = result.displayName,
				})
			else
				result.grantSuccess = false
				result.grantFailReason = grantRes.reason or "UNKNOWN"
				warn(string.format("[CrateService] Grant failed player=%s crate=%s roll=%d item=%s reason=%s",
					player.Name, crateId, rollIndex, itemId, tostring(grantRes.reason)))
			end
			local entry = ItemCatalog.Get(category, itemId)
			log(string.format("%s opened %s — got %s (%s)",
				player.Name, crateId, entry and entry.name or itemId, category))
		end

		table.insert(results, result)
	end

	if #grantedPopupItems > 0 then
		grant.EmitRewardGranted(player, {
			type = "Crate",
			id = crateId,
			source = "Crate",
			batchItems = grantedPopupItems,
		})
	end

	return { results = results, success = true }
end

--[[
	RollCrateFree — rolls crates WITHOUT charging coins.
	Used by DailyRewardService for reward crates.
	Same rolling + granting logic as OpenCrate, but no price lookup / coin deduction.
]]
function CrateService.RollCrateFree(player: Player, crateId: string, quantity: number): { results: { any }, success: boolean, error: string? }
	if type(crateId) ~= "string" or type(quantity) ~= "number" then
		return { results = {}, success = false, error = "Invalid arguments" }
	end

	quantity = math.clamp(math.floor(quantity), 1, MAX_QUANTITY)

	if not REWARD_TABLES[crateId] then
		return { results = {}, success = false, error = "Unknown crate: " .. tostring(crateId) }
	end

	local grant = getGrantService()
	if not grant then
		return { results = {}, success = false, error = "Grant service unavailable" }
	end

	local crateTxnId = HttpService:GenerateGUID(false)
	local results = {}
	local grantedPopupItems = {}

	for i = 1, quantity do
		local itemId, category, isDuplicate = rollItem(player, crateId)

		local catalogEntry = ItemCatalog.Get(category, itemId)
		local result = {
			itemId = itemId,
			category = category,
			isDuplicate = isDuplicate,
			coinsAwarded = 0,
			displayName = catalogEntry and catalogEntry.name or itemId,
			rarity = catalogEntry and catalogEntry.rarity or "Common",
		}

		if isDuplicate or itemId == "" then
			log(string.format("%s FREE roll #%d %s — already owned: %s (%s)",
				player.Name, i, crateId, itemId, category))
		else
			local grantType = (category == "Crowns") and "Crown" or "Pet"
			local grantRes = grant.GrantItem(player, grantType, itemId, "Crate", {
				fireReward = false,
				idempotencyKey = string.format("cratefree:%s:%s:%d:%s", player.UserId, crateTxnId, i, itemId),
				payload = {
					type = grantType,
					id = itemId,
					category = category,
					source = "Crate",
					rarity = result.rarity,
					name = result.displayName,
				},
			})
			if grantRes.success then
				result.grantSuccess = true
				table.insert(grantedPopupItems, {
					type = grantType,
					id = itemId,
					category = category,
					source = "Crate",
					rarity = result.rarity,
					name = result.displayName,
				})
			else
				result.grantSuccess = false
				result.grantFailReason = grantRes.reason or "UNKNOWN"
				warn(string.format("[CrateService] Free grant failed player=%s crate=%s roll=%d item=%s reason=%s",
					player.Name, crateId, i, itemId, tostring(grantRes.reason)))
			end
			log(string.format("%s FREE roll #%d %s — got %s (%s)",
				player.Name, i, crateId, catalogEntry and catalogEntry.name or itemId, category))
		end

		table.insert(results, result)
	end

	if #grantedPopupItems > 0 then
		grant.EmitRewardGranted(player, {
			type = "Crate",
			id = crateId,
			source = "Crate",
			batchItems = grantedPopupItems,
		})
	end

	return { results = results, success = true }
end

-- ═══════════════════════════════════════════════════════════════════
-- DEBUG: Simulate rolls (Studio only)
-- ═══════════════════════════════════════════════════════════════════

function CrateService.DebugSimulate(crateId: string, rolls: number?)
	if not RunService:IsStudio() then
		warn("[CrateService] DebugSimulate is Studio-only")
		return
	end

	rolls = rolls or 10000

	local entries = REWARD_TABLES[crateId]
	if not entries then
		warn("[CrateService] No reward table for:", crateId)
		return
	end

	local counts: { [string]: number } = {}
	for _ = 1, rolls do
		local entry = weightedRoll(entries)
		counts[entry.itemId] = (counts[entry.itemId] or 0) + 1
	end

	local tw = totalWeight(entries)
	log(string.format("=== Simulated %d rolls for %s ===", rolls, crateId))
	for _, e in ipairs(entries) do
		local actual = counts[e.itemId] or 0
		local actualPct = (actual / rolls) * 100
		local expectedPct = if tw > 0 then (e.weight / tw) * 100 else 0
		log(string.format("  %-25s w=%3d  expected=%.1f%%  actual=%.1f%% (%d)",
			e.itemId, e.weight, expectedPct, actualPct, actual))
	end
	log("=== End simulation ===")
end

return CrateService
