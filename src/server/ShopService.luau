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
	brainrot_all = "brainrot_bundle",
	brainrot_bundle = "brainrot_bundle",
}

local COIN_BUNDLE_CONFIG: { [string]: { requestId: string, logId: string, basePrice: number, perOwnedDiscount: number, successName: string } } = {
	fnaf_pets_bundle = {
		requestId = "fnaf_all",
		logId = "fnaf_all",
		basePrice = 150000,
		perOwnedDiscount = 0.10,
		successName = "All Animatronic Pets unlocked",
	},
	brainrot_bundle = {
		requestId = "brainrot_all",
		logId = "brainrot",
		basePrice = 150000,
		perOwnedDiscount = 0.10,
		successName = "Brainrot Bundle",
	},
}
local BRAINROT_BUNDLE_ID = "brainrot_bundle"
local BRAINROT_ITEM_PRICE = 75000

local function toGrantType(category: string): string?
	if category == "Pets" then return "Pet" end
	if category == "Crowns" then return "Crown" end
	if category == "IconImages" then return "IconImage" end
	return nil
end

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

local function getCoinBundleQuote(player: Player, bundleId: string): { ok: boolean, reason: string?, price: number, ownedCount: number, totalCount: number, missingCount: number }
	local cfg = COIN_BUNDLE_CONFIG[bundleId]
	local bundle = BundleCatalog.Get(bundleId)
	if not cfg or not bundle then
		return { ok = false, reason = "BUNDLE_NOT_SUPPORTED", price = 0, ownedCount = 0, totalCount = 0, missingCount = 0 }
	end

	local IS = getInventory()
	if not IS then
		local total = #(bundle.includes or {})
		return { ok = false, reason = "InventoryService unavailable", price = cfg.basePrice, ownedCount = 0, totalCount = total, missingCount = total }
	end

	local ownedCount = 0
	local totalCount = 0
	for _, inc in ipairs(bundle.includes or {}) do
		local grantType = toGrantType(inc.category)
		if grantType and inc.itemId then
			totalCount += 1
			if IS.OwnsItem(player, inc.category, inc.itemId) then
				ownedCount += 1
			end
		end
	end
	local missingCount = math.max(0, totalCount - ownedCount)
	if missingCount == 0 then
		print(string.format("[BundleQuote] bundle=%s owned=%d/%d price=0", cfg.logId, ownedCount, totalCount))
		return {
			ok = false,
			reason = "ALREADY_OWNED",
			price = 0,
			ownedCount = ownedCount,
			totalCount = totalCount,
			missingCount = missingCount,
		}
	end

	local discountPercent = ownedCount * cfg.perOwnedDiscount
	local finalPrice = math.floor(cfg.basePrice * (1 - discountPercent))
	finalPrice = math.max(0, finalPrice)

	print(string.format("[BundleQuote] bundle=%s owned=%d/%d price=%d", cfg.logId, ownedCount, totalCount, finalPrice))
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
	if COIN_BUNDLE_CONFIG[bundleId] then
		return getCoinBundleQuote(player, bundleId)
	end
	return { ok = false, reason = "BUNDLE_NOT_SUPPORTED", price = 0, ownedCount = 0, totalCount = 0, missingCount = 0 }
end

local function buyBundleWithCoins(player: Player, requestBundleId: string): { success: boolean, reason: string?, grantedCount: number?, grantedItemIds: {string}?, productId: number?, shortage: number?, recommendedCoins: number? }
	local bundleId = BUNDLE_ALIASES[requestBundleId] or requestBundleId
	local cfg = COIN_BUNDLE_CONFIG[bundleId]
	local bundle = BundleCatalog.Get(bundleId)
	if not bundle or not cfg then
		return { success = false, reason = "Bundle is not available for Fate Coins" }
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

	local quote = getCoinBundleQuote(player, bundleId)
	local ownedCount = quote.ownedCount
	local totalCount = quote.totalCount
	local missingCount = quote.missingCount
	local finalCost = quote.price
	if not quote.ok then
		print(string.format("[BundleBuy] bundle=%s cost=%d result=FAIL reason=%s",
			cfg.logId, finalCost, tostring(quote.reason)))
		_bundleBuyInFlight[inFlightKey] = nil
		return {
			success = false,
			reason = quote.reason or "ALREADY_OWNED",
			finalCost = finalCost,
			missingCount = missingCount,
			ownedCount = ownedCount,
			totalCount = totalCount,
		}
	end

	local toGrant = {}
	for _, inc in ipairs(bundle.includes or {}) do
		local grantType = toGrantType(inc.category)
		if grantType and inc.itemId and not IS.OwnsItem(player, inc.category, inc.itemId) then
			table.insert(toGrant, inc)
		end
	end
	if #toGrant == 0 then
		print(string.format("[BundleBuy] bundle=%s cost=%d result=FAIL reason=ALREADY_OWNED",
			cfg.logId, finalCost))
		_bundleBuyInFlight[inFlightKey] = nil
		return { success = false, reason = "ALREADY_OWNED" }
	end

	local balance = ES.GetCoins(player)
	if balance < finalCost then
		local shortage = finalCost - balance
		local productId, recommendedCoins = findTopUpProduct(shortage)
		print(string.format("[BundleBuy] bundle=%s cost=%d result=FAIL reason=INSUFFICIENT_COINS",
			cfg.logId, finalCost))
		print(string.format("[BundleBuy] insufficient coins shortage=%d suggestedProductId=%s",
			shortage, tostring(productId)))
		_bundleBuyInFlight[inFlightKey] = nil
		return {
			success = false,
			reason = "INSUFFICIENT_COINS",
			productId = productId,
			shortage = shortage,
			recommendedCoins = recommendedCoins,
			finalCost = finalCost,
			missingCount = missingCount,
			ownedCount = ownedCount,
			totalCount = totalCount,
		}
	end

	local deducted = ES.DeductCoins(player, finalCost, "BundlePurchase:" .. bundleId)
	if not deducted then
		_bundleBuyInFlight[inFlightKey] = nil
		return { success = false, reason = "Failed to deduct coins" }
	end

	local grantedCount = 0
	local grantedItemIds = {}
	for _, inc in ipairs(toGrant) do
		local grantType = toGrantType(inc.category)
		if grantType then
			local grantRes = GS.GrantItem(player, grantType, inc.itemId, "Bundle", {
				fireReward = false,
				idempotencyKey = string.format("bundle:%s:%s:%s", tostring(player.UserId), bundleId, inc.itemId),
			})
			if grantRes.success then
				grantedCount += 1
				table.insert(grantedItemIds, inc.itemId)
			end
		end
	end

	if grantedCount == 0 then
		ES.AwardCoins(player, finalCost, "BundleRefund:" .. bundleId, true)
		_bundleBuyInFlight[inFlightKey] = nil
		print(string.format("[BundleBuy] bundle=%s cost=%d result=FAIL reason=FAILED_TO_GRANT",
			cfg.logId, finalCost))
		return { success = false, reason = "Failed to grant bundle items" }
	end

	print(string.format("[BundleBuy] bundle=%s cost=%d result=SUCCESS", cfg.logId, finalCost))
	GS.EmitBundlePurchaseConfirmed(player, cfg.requestId, {
		token = HttpService:GenerateGUID(false),
		title = "PURCHASED!",
		name = cfg.successName,
		itemType = "Bundle",
		itemId = cfg.requestId,
		rarityText = (cfg.logId == "brainrot") and "Legendary" or "Common",
		icon = bundle.coverImage,
		okText = "NICE!",
	})
	_bundleBuyInFlight[inFlightKey] = nil
	return {
		success = true,
		grantedCount = grantedCount,
		grantedItemIds = grantedItemIds,
		finalCost = finalCost,
		missingCount = missingCount,
		ownedCount = ownedCount,
		totalCount = totalCount,
	}
end

local function getBundleInclude(bundleId: string, itemId: string)
	local bundle = BundleCatalog.Get(bundleId)
	if not bundle then return nil end
	for _, inc in ipairs(bundle.includes or {}) do
		if inc.itemId == itemId then
			return inc
		end
	end
	return nil
end

function ShopService.BuyBrainrotItem(player: Player, itemId: string): { success: boolean, reason: string?, productId: number?, shortage: number?, recommendedCoins: number? }
	if type(itemId) ~= "string" or itemId == "" then
		return { success = false, reason = "Invalid item" }
	end
	local include = getBundleInclude(BRAINROT_BUNDLE_ID, itemId)
	if not include then
		return { success = false, reason = "Item not in brainrot bundle" }
	end

	local grantType = toGrantType(include.category)
	if not grantType then
		return { success = false, reason = "Unsupported bundle item category" }
	end

	local ES = getEconomy()
	local IS = getInventory()
	local GS = getGrant()
	if not ES or not IS or not GS then
		return { success = false, reason = "Shop services unavailable" }
	end

	if IS.OwnsItem(player, include.category, itemId) then
		print(string.format("[ItemBuy] bundle=brainrot item=%s cost=%d result=FAIL reason=ALREADY_OWNED", itemId, BRAINROT_ITEM_PRICE))
		return { success = false, reason = "ALREADY_OWNED" }
	end

	local balance = ES.GetCoins(player)
	if balance < BRAINROT_ITEM_PRICE then
		local shortage = BRAINROT_ITEM_PRICE - balance
		local productId, recommendedCoins = findTopUpProduct(shortage)
		print(string.format("[ItemBuy] bundle=brainrot item=%s cost=%d result=FAIL reason=INSUFFICIENT_COINS", itemId, BRAINROT_ITEM_PRICE))
		return {
			success = false,
			reason = "INSUFFICIENT_COINS",
			productId = productId,
			shortage = shortage,
			recommendedCoins = recommendedCoins,
		}
	end

	local deducted = ES.DeductCoins(player, BRAINROT_ITEM_PRICE, "BundleItemPurchase:" .. itemId)
	if not deducted then
		print(string.format("[ItemBuy] bundle=brainrot item=%s cost=%d result=FAIL reason=DEDUCT_FAILED", itemId, BRAINROT_ITEM_PRICE))
		return { success = false, reason = "Failed to deduct coins" }
	end

	local grantRes = GS.GrantItem(player, grantType, itemId, "BundleItem", {
		fireReward = false,
		idempotencyKey = string.format("bundleitem:%s:%s", tostring(player.UserId), itemId),
	})
	if not grantRes.success then
		ES.AwardCoins(player, BRAINROT_ITEM_PRICE, "BundleItemRefund:" .. itemId, true)
		print(string.format("[ItemBuy] bundle=brainrot item=%s cost=%d result=FAIL reason=%s", itemId, BRAINROT_ITEM_PRICE, tostring(grantRes.reason)))
		return { success = false, reason = tostring(grantRes.reason or "Grant failed") }
	end
	if grantRes.payload and type(GS.EmitPurchaseGranted) == "function" then
		GS.EmitPurchaseGranted(player, grantRes.payload)
	end

	print(string.format("[ItemBuy] bundle=brainrot item=%s cost=%d result=SUCCESS", itemId, BRAINROT_ITEM_PRICE))
	return { success = true }
end

function ShopService.BuyWithCoins(player: Player, itemId: string, itemType: string): { success: boolean, reason: string?, productId: number?, shortage: number?, recommendedCoins: number? }
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
		local shortage = price - balance
		local productId, recommendedCoins = findTopUpProduct(shortage)
		return {
			success = false,
			reason = "INSUFFICIENT_COINS",
			productId = productId,
			shortage = shortage,
			recommendedCoins = recommendedCoins,
		}
	end

	local deducted = ES.DeductCoins(player, price, "ShopPurchase:" .. itemId)
	if not deducted then
		return { success = false, reason = "Failed to deduct coins" }
	end

	local grantType = (category == "Crowns") and "Crown" or "Pet"
	local grantRes = GS.GrantItem(player, grantType, itemId, "Shop", {
		fireReward = false,
		idempotencyKey = string.format("shop:%s:%s:%s", tostring(player.UserId), category, itemId),
	})
	if not grantRes.success then
		-- Refund on grant failure
		ES.AwardCoins(player, price, "ShopRefund:" .. itemId, true)
		return { success = false, reason = "Failed to grant item: " .. tostring(grantRes.reason) }
	end
	if grantRes.payload and type(GS.EmitPurchaseGranted) == "function" then
		GS.EmitPurchaseGranted(player, grantRes.payload)
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
	local buyBrainrotItemRF = remotes:FindFirstChild("BuyBrainrotItem")
	if not buyBrainrotItemRF then
		buyBrainrotItemRF = Instance.new("RemoteFunction")
		buyBrainrotItemRF.Name = "BuyBrainrotItem"
		buyBrainrotItemRF.Parent = remotes
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
	buyBrainrotItemRF.OnServerInvoke = function(player: Player, itemId: string)
		local ok, result = pcall(ShopService.BuyBrainrotItem, player, itemId)
		if ok then return result end
		warn("[ShopService] BuyBrainrotItem error:", result)
		return { success = false, reason = "Internal error" }
	end

	print("[ShopService] Initialized")
end

return ShopService
