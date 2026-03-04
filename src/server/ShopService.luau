--[[
	ShopService
	Handles in-game Fate Coins purchases from the Shop UI.

	API:
		Init()
		BuyWithCoins(player, itemId, itemType) → { success, reason? }
]]

local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local HttpService = game:GetService("HttpService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Server = ServerScriptService:WaitForChild("Server")

local ItemCatalog = require(Shared:WaitForChild("ItemCatalog"))
local BundleCatalog = require(Shared:WaitForChild("BundleCatalog"))
local UIConfig = require(Shared:WaitForChild("UIConfig"))

local ShopService = {}
local initialized = false

local _EconomyService   = nil
local _InventoryService = nil
local _GrantService = nil
local _bundleBuyInFlight: { [number]: boolean } = {}

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

local function getGrant()
	if _GrantService then return _GrantService end
	local ok, mod = pcall(require, Server:WaitForChild("GrantService", 10))
	if ok and mod then _GrantService = mod end
	return _GrantService
end

-- Map shop item type → catalog category
local TYPE_TO_CATEGORY = {
	ExclusiveCrown = "Crowns",
	ExclusivePet   = "Pets",
}

local BUNDLE_ALIASES: { [string]: string } = {
	fnaf_all = "fnaf_pets_bundle",
	fnaf_pets_bundle = "fnaf_pets_bundle",
}

local FNAF_BUNDLE_ID = "fnaf_pets_bundle"
local FNAF_BUNDLE_REQUEST_ID = "fnaf_all"
local FNAF_BASE_PRICE = 150000
local FNAF_PER_OWNED_DISCOUNT = 0.10

local FNAF_BUNDLE_PET_IDS = {
	"pet_freddy_fazbear",
	"pet_bonnie",
	"pet_chica",
	"pet_foxy",
	"pet_golden_freddy",
	"pet_the_puppet",
	"pet_cupcake",
}

local function findTopUpProduct(shortage: number): (number?, number?)
	local bestProductId: number? = nil
	local bestAmount: number? = nil
	for _, entry in ipairs(UIConfig.MockPremiumItems or {}) do
		if entry.type == "Currency" and type(entry.productId) == "number" and entry.productId > 0 then
			local amount = tonumber(entry.coinsAmount) or 0
			if amount >= shortage then
				if bestAmount == nil or amount < (bestAmount :: number) then
					bestAmount = amount
					bestProductId = entry.productId
				end
			end
		end
	end
	return bestProductId, bestAmount
end

local function getFnafQuote(player: Player): { ok: boolean, reason: string?, price: number, ownedCount: number, totalCount: number, missingCount: number }
	local IS = getInventory()
	if not IS then
		return { ok = false, reason = "InventoryService unavailable", price = FNAF_BASE_PRICE, ownedCount = 0, totalCount = #FNAF_BUNDLE_PET_IDS, missingCount = #FNAF_BUNDLE_PET_IDS }
	end

	local ownedCount = 0
	local totalCount = #FNAF_BUNDLE_PET_IDS
	for _, petId in ipairs(FNAF_BUNDLE_PET_IDS) do
		if IS.OwnsItem(player, "Pets", petId) then
			ownedCount += 1
		end
	end
	local missingCount = math.max(0, totalCount - ownedCount)
	if missingCount == 0 then
		print(string.format("[BundleQuote] bundle=%s owned=%d/%d price=0", FNAF_BUNDLE_REQUEST_ID, ownedCount, totalCount))
		return {
			ok = false,
			reason = "ALREADY_OWNED",
			price = 0,
			ownedCount = ownedCount,
			totalCount = totalCount,
			missingCount = missingCount,
		}
	end

	local discountPercent = ownedCount * FNAF_PER_OWNED_DISCOUNT
	local finalPrice = math.floor(FNAF_BASE_PRICE * (1 - discountPercent))
	finalPrice = math.max(0, finalPrice)

	print(string.format("[BundleQuote] bundle=%s owned=%d/%d price=%d", FNAF_BUNDLE_REQUEST_ID, ownedCount, totalCount, finalPrice))
	return {
		ok = true,
		price = finalPrice,
		ownedCount = ownedCount,
		totalCount = totalCount,
		missingCount = missingCount,
	}
end

function ShopService.GetBundleQuote(player: Player, requestBundleId: string)
	local bundleId = BUNDLE_ALIASES[requestBundleId] or requestBundleId
	if bundleId == FNAF_BUNDLE_ID then
		return getFnafQuote(player)
	end
	return { ok = false, reason = "BUNDLE_NOT_SUPPORTED", price = 0, ownedCount = 0, totalCount = 0, missingCount = 0 }
end

local function buyBundleWithCoins(player: Player, requestBundleId: string): { success: boolean, reason: string?, grantedCount: number?, grantedItemIds: {string}?, productId: number?, shortage: number?, recommendedCoins: number? }
	local bundleId = BUNDLE_ALIASES[requestBundleId] or requestBundleId
	local bundle = BundleCatalog.Get(bundleId)
	if not bundle then
		return { success = false, reason = "Bundle not found" }
	end

	local inFlightKey = player.UserId
	if _bundleBuyInFlight[inFlightKey] then
		return { success = false, reason = "Purchase in progress" }
	end
	_bundleBuyInFlight[inFlightKey] = true

	local ES = getEconomy()
	local IS = getInventory()
	local GS = getGrant()
	if not ES or not IS or not GS then
		_bundleBuyInFlight[inFlightKey] = nil
		return { success = false, reason = "Shop services unavailable" }
	end

	if bundleId ~= FNAF_BUNDLE_ID then
		_bundleBuyInFlight[inFlightKey] = nil
		return { success = false, reason = "Bundle is not available for Fate Coins" }
	end

	local quote = getFnafQuote(player)
	local ownedPetsCount = quote.ownedCount
	local totalPetsCount = quote.totalCount
	local missingPetsCount = quote.missingCount
	local finalCost = quote.price
	if not quote.ok then
		print(string.format("[BundleBuy] bundle=%s owned=%d missing=%d cost=%d result=FAIL reason=%s",
			FNAF_BUNDLE_REQUEST_ID, ownedPetsCount, missingPetsCount, finalCost, tostring(quote.reason)))
		_bundleBuyInFlight[inFlightKey] = nil
		return {
			success = false,
			reason = quote.reason or "ALREADY_OWNED",
			finalCost = finalCost,
			missingPetsCount = missingPetsCount,
			ownedPetsCount = ownedPetsCount,
			totalPetsCount = totalPetsCount,
		}
	end

	local totalPetsCount = 0
	local ownedPetsCount = 0
	local missingPetsCount = 0
	local toGrant = {}
	for _, inc in ipairs(bundle.includes or {}) do
		if inc.category == "Pets" and inc.itemId then
			totalPetsCount += 1
			if IS.OwnsItem(player, inc.category, inc.itemId) then
				ownedPetsCount += 1
			else
				missingPetsCount += 1
			end
		end
		if inc.category and inc.itemId and not IS.OwnsItem(player, inc.category, inc.itemId) then
			table.insert(toGrant, inc)
		end
	end
	if missingPetsCount <= 0 or #toGrant == 0 then
		print(string.format("[BundleBuy] bundle=%s owned=%d missing=%d cost=%d result=FAIL reason=ALREADY_OWNED",
			FNAF_BUNDLE_REQUEST_ID, ownedPetsCount, missingPetsCount, finalCost))
		_bundleBuyInFlight[inFlightKey] = nil
		return { success = false, reason = "ALREADY_OWNED" }
	end

	local balance = ES.GetCoins(player)
	if balance < finalCost then
		local shortage = finalCost - balance
		local productId, recommendedCoins = findTopUpProduct(shortage)
		print(string.format("[BundleBuy] bundle=%s owned=%d missing=%d cost=%d result=FAIL reason=INSUFFICIENT_COINS",
			FNAF_BUNDLE_REQUEST_ID, ownedPetsCount, missingPetsCount, finalCost))
		_bundleBuyInFlight[inFlightKey] = nil
		return {
			success = false,
			reason = "INSUFFICIENT_COINS",
			productId = productId,
			shortage = shortage,
			recommendedCoins = recommendedCoins,
			finalCost = finalCost,
			missingPetsCount = missingPetsCount,
			ownedPetsCount = ownedPetsCount,
			totalPetsCount = totalPetsCount,
		}
	end

	local deducted = ES.DeductCoins(player, finalCost, "BundlePurchase:" .. bundleId)
	if not deducted then
		_bundleBuyInFlight[inFlightKey] = nil
		return { success = false, reason = "Failed to deduct coins" }
	end

	local grantedCount = 0
	local grantedItemIds = {}
	local grantedRewards = {}
	for _, inc in ipairs(toGrant) do
		local grantType = (inc.category == "Crowns") and "Crown" or "Pet"
		local grantRes = GS.GrantItem(player, grantType, inc.itemId, "Bundle", {
			fireReward = false,
			idempotencyKey = string.format("bundle:%s:%s:%s", tostring(player.UserId), bundleId, inc.itemId),
		})
		if grantRes.success then
			grantedCount += 1
			table.insert(grantedItemIds, inc.itemId)
			table.insert(grantedRewards, {
				type = grantType,
				id = inc.itemId,
				category = inc.category,
				source = "Bundle",
			})
		end
	end

	if grantedCount == 0 then
		ES.AwardCoins(player, finalCost, "BundleRefund:" .. bundleId, true)
		_bundleBuyInFlight[inFlightKey] = nil
		return { success = false, reason = "Failed to grant bundle items" }
	end

	print(string.format("[BundleBuy] bundle=%s owned=%d missing=%d cost=%d result=SUCCESS",
		FNAF_BUNDLE_REQUEST_ID, ownedPetsCount, missingPetsCount, finalCost))
	if #grantedRewards > 0 then
		GS.EmitBundlePurchaseConfirmed(player, FNAF_BUNDLE_REQUEST_ID, {
			token = HttpService:GenerateGUID(false),
			title = "PURCHASED!",
			name = "All FNAF pets unlocked",
			itemType = "Bundle",
			itemId = FNAF_BUNDLE_REQUEST_ID,
			icon = bundle.coverImage,
			okText = "NICE!",
		})
	end
	_bundleBuyInFlight[inFlightKey] = nil
	return {
		success = true,
		grantedCount = grantedCount,
		grantedItemIds = grantedItemIds,
		finalCost = finalCost,
		missingPetsCount = missingPetsCount,
		ownedPetsCount = ownedPetsCount,
		totalPetsCount = totalPetsCount,
	}
end

function ShopService.BuyWithCoins(player: Player, itemId: string, itemType: string): { success: boolean, reason: string? }
	if not itemId or not itemType then
		return { success = false, reason = "Invalid request" }
	end

	if itemType == "Bundle" then
		return buyBundleWithCoins(player, itemId)
	end

	-- Resolve premium entry for price
	local premiumEntry = ItemCatalog.Get("Premium", itemId)
	if not premiumEntry then
		return { success = false, reason = "Item not found in shop" }
	end

	local price = premiumEntry.fateCoins
	if not price or price <= 0 then
		return { success = false, reason = "Item is not available for Fate Coins" }
	end

	local category = TYPE_TO_CATEGORY[itemType]
	if not category then
		return { success = false, reason = "Invalid item type: " .. tostring(itemType) }
	end

	local IS = getInventory()
	local GS = getGrant()
	if not IS or not GS then
		return { success = false, reason = "Grant services unavailable" }
	end

	-- Already owned?
	if IS.OwnsItem(player, category, itemId) then
		return { success = false, reason = "Already owned" }
	end

	-- Check and deduct coins
	local ES = getEconomy()
	if not ES then
		return { success = false, reason = "EconomyService unavailable" }
	end

	local balance = ES.GetCoins(player)
	if balance < price then
		return { success = false, reason = string.format("Not enough Fate Coins (%d needed, %d owned)", price, balance) }
	end

	local deducted = ES.DeductCoins(player, price, "ShopPurchase:" .. itemId)
	if not deducted then
		return { success = false, reason = "Failed to deduct coins" }
	end

	local grantType = (category == "Crowns") and "Crown" or "Pet"
	local grantRes = GS.GrantItem(player, grantType, itemId, "Shop", {
		idempotencyKey = string.format("shop:%s:%s:%s", tostring(player.UserId), category, itemId),
	})
	if not grantRes.success then
		-- Refund on grant failure
		ES.AwardCoins(player, price, "ShopRefund:" .. itemId, true)
		return { success = false, reason = "Failed to grant item: " .. tostring(grantRes.reason) }
	end

	print(string.format("[ShopService] %s purchased %s/%s for %d Fate Coins", player.Name, category, itemId, price))
	return { success = true }
end

function ShopService.Init()
	if initialized then return end
	initialized = true

	-- Create RemoteFunction
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		remotes = Instance.new("Folder")
		remotes.Name   = "Remotes"
		remotes.Parent = ReplicatedStorage
	end

	local buyRF = remotes:FindFirstChild("Shop_BuyWithCoins")
	if not buyRF then
		buyRF = Instance.new("RemoteFunction")
		buyRF.Name   = "Shop_BuyWithCoins"
		buyRF.Parent = remotes
	end

	local quoteRF = remotes:FindFirstChild("Shop_GetBundleQuote")
	if not quoteRF then
		quoteRF = Instance.new("RemoteFunction")
		quoteRF.Name = "Shop_GetBundleQuote"
		quoteRF.Parent = remotes
	end

	buyRF.OnServerInvoke = function(player: Player, itemId: string, itemType: string)
		local ok, result = pcall(ShopService.BuyWithCoins, player, itemId, itemType)
		if ok then return result end
		warn("[ShopService] BuyWithCoins error:", result)
		return { success = false, reason = "Internal error" }
	end

	quoteRF.OnServerInvoke = function(player: Player, requestBundleId: string)
		local ok, result = pcall(ShopService.GetBundleQuote, player, requestBundleId)
		if ok then return result end
		warn("[ShopService] GetBundleQuote error:", result)
		return { ok = false, reason = "Internal error", price = 0, ownedCount = 0, totalCount = 0, missingCount = 0 }
	end

	print("[ShopService] Initialized")
end

return ShopService
