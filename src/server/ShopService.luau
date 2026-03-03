--[[
	ShopService
	Handles in-game Fate Coins purchases from the Shop UI.

	API:
		Init()
		BuyWithCoins(player, itemId, itemType) → { success, reason? }
]]

local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Server = ServerScriptService:WaitForChild("Server")

local ItemCatalog = require(Shared:WaitForChild("ItemCatalog"))
local BundleCatalog = require(Shared:WaitForChild("BundleCatalog"))
local UIConfig = require(Shared:WaitForChild("UIConfig"))

local ShopService = {}
local initialized = false

local _EconomyService   = nil
local _InventoryService = nil
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

-- Map shop item type → catalog category
local TYPE_TO_CATEGORY = {
	ExclusiveCrown = "Crowns",
	ExclusivePet   = "Pets",
}

local BUNDLE_ALIASES: { [string]: string } = {
	fnaf_all = "fnaf_pets_bundle",
	fnaf_pets_bundle = "fnaf_pets_bundle",
}

local BUNDLE_COIN_COSTS: { [string]: number } = {
	fnaf_pets_bundle = 150000,
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

local function buyBundleWithCoins(player: Player, requestBundleId: string): { success: boolean, reason: string?, grantedCount: number?, grantedItemIds: {string}?, productId: number?, shortage: number?, recommendedCoins: number? }
	local bundleId = BUNDLE_ALIASES[requestBundleId] or requestBundleId
	local bundle = BundleCatalog.Get(bundleId)
	if not bundle then
		return { success = false, reason = "Bundle not found" }
	end

	local price = BUNDLE_COIN_COSTS[bundleId]
	if not price or price <= 0 then
		return { success = false, reason = "Bundle is not available for Fate Coins" }
	end

	local inFlightKey = player.UserId
	if _bundleBuyInFlight[inFlightKey] then
		return { success = false, reason = "Purchase in progress" }
	end
	_bundleBuyInFlight[inFlightKey] = true

	local ES = getEconomy()
	local IS = getInventory()
	if not ES or not IS then
		_bundleBuyInFlight[inFlightKey] = nil
		return { success = false, reason = "Shop services unavailable" }
	end

	local toGrant = {}
	for _, inc in ipairs(bundle.includes or {}) do
		if inc.category and inc.itemId and not IS.OwnsItem(player, inc.category, inc.itemId) then
			table.insert(toGrant, inc)
		end
	end
	if #toGrant == 0 then
		print(string.format("[BundleBuy] player=%s bundle=%s cost=%d result=FAIL reason=ALREADY_OWNED",
			player.Name, bundleId, price))
		_bundleBuyInFlight[inFlightKey] = nil
		return { success = false, reason = "ALREADY_OWNED" }
	end

	local balance = ES.GetCoins(player)
	if balance < price then
		local shortage = price - balance
		if bundleId == "fnaf_pets_bundle" then
			local productId, recommendedCoins = findTopUpProduct(shortage)
			print(string.format("[BundleBuy] player=%s bundle=%s cost=%d result=FAIL reason=INSUFFICIENT_FUNDS shortage=%d productId=%s",
				player.Name, bundleId, price, shortage, tostring(productId)))
			_bundleBuyInFlight[inFlightKey] = nil
			return {
				success = false,
				reason = "INSUFFICIENT_COINS",
				productId = productId,
				shortage = shortage,
				recommendedCoins = recommendedCoins,
			}
		end
		print(string.format("[BundleBuy] player=%s bundle=%s cost=%d result=FAIL reason=INSUFFICIENT_FUNDS",
			player.Name, bundleId, price))
		_bundleBuyInFlight[inFlightKey] = nil
		return { success = false, reason = "Not enough Fate Coins" }
	end

	local deducted = ES.DeductCoins(player, price, "BundlePurchase:" .. bundleId)
	if not deducted then
		_bundleBuyInFlight[inFlightKey] = nil
		return { success = false, reason = "Failed to deduct coins" }
	end

	local grantedCount = 0
	local grantedItemIds = {}
	for _, inc in ipairs(toGrant) do
		if IS.GrantItem(player, inc.category, inc.itemId) then
			grantedCount += 1
			table.insert(grantedItemIds, inc.itemId)
		end
	end

	if grantedCount == 0 then
		ES.AwardCoins(player, price, "BundleRefund:" .. bundleId, true)
		_bundleBuyInFlight[inFlightKey] = nil
		return { success = false, reason = "Failed to grant bundle items" }
	end

	print(string.format("[BundleBuy] player=%s bundle=%s cost=%d result=SUCCESS grantedCount=%d",
		player.Name, bundleId, price, grantedCount))
	_bundleBuyInFlight[inFlightKey] = nil
	return { success = true, grantedCount = grantedCount, grantedItemIds = grantedItemIds }
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
	if not IS then
		return { success = false, reason = "InventoryService unavailable" }
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

	local granted = IS.GrantItem(player, category, itemId)
	if not granted then
		-- Refund on grant failure
		ES.AwardCoins(player, price, "ShopRefund:" .. itemId, true)
		return { success = false, reason = "Failed to grant item" }
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

	buyRF.OnServerInvoke = function(player: Player, itemId: string, itemType: string)
		local ok, result = pcall(ShopService.BuyWithCoins, player, itemId, itemType)
		if ok then return result end
		warn("[ShopService] BuyWithCoins error:", result)
		return { success = false, reason = "Internal error" }
	end

	print("[ShopService] Initialized")
end

return ShopService
