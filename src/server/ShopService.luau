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

local ShopService = {}
local initialized = false

local _EconomyService   = nil
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

-- Map shop item type → catalog category
local TYPE_TO_CATEGORY = {
	ExclusiveCrown = "Crowns",
	ExclusivePet   = "Pets",
}

function ShopService.BuyWithCoins(player: Player, itemId: string, itemType: string): { success: boolean, reason: string? }
	if not itemId or not itemType then
		return { success = false, reason = "Invalid request" }
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
