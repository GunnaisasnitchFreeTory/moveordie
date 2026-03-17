--[[
	GrantService
	Central server-authoritative grant pipeline for all reward types.

	API:
	  Init()
	  GrantItem(player, itemType, itemIdOrAmount, source, meta) -> { success, reason?, alreadyProcessed?, alreadyOwned?, payload? }
	  EmitRewardGranted(player, payload)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Server = ServerScriptService:WaitForChild("Server")

local ItemCatalog = require(Shared:WaitForChild("ItemCatalog"))

local GrantService = {}
local initialized = false

local _InventoryService = nil
local _EconomyService = nil
local _PlayerDataService = nil
local _SpinWheelService = nil
local _inventoryUpdatedRE: RemoteEvent? = nil
local _rewardGrantedRE: RemoteEvent? = nil
local _bundlePurchaseConfirmedRE: RemoteEvent? = nil
local _purchaseGrantedRE: RemoteEvent? = nil

local function getInventory()
	if _InventoryService then return _InventoryService end
	local ok, mod = pcall(require, Server:WaitForChild("InventoryService", 10))
	if ok and mod then _InventoryService = mod end
	return _InventoryService
end

local function getEconomy()
	if _EconomyService then return _EconomyService end
	local ok, mod = pcall(require, Server:WaitForChild("EconomyService", 10))
	if ok and mod then _EconomyService = mod end
	return _EconomyService
end

local function getPlayerData()
	if _PlayerDataService then return _PlayerDataService end
	local ok, mod = pcall(require, Server:WaitForChild("PlayerDataService", 10))
	if ok and mod then _PlayerDataService = mod end
	return _PlayerDataService
end

local function getSpinWheel()
	if _SpinWheelService then return _SpinWheelService end
	local ok, mod = pcall(require, Server:WaitForChild("SpinWheelService", 10))
	if ok and mod then _SpinWheelService = mod end
	return _SpinWheelService
end

local function ensureRemotes()
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		remotes = Instance.new("Folder")
		remotes.Name = "Remotes"
		remotes.Parent = ReplicatedStorage
	end
	local inv = remotes:FindFirstChild("InventoryUpdated")
	if not inv then
		inv = Instance.new("RemoteEvent")
		inv.Name = "InventoryUpdated"
		inv.Parent = remotes
	end
	local reward = remotes:FindFirstChild("RewardGranted")
	if not reward then
		reward = Instance.new("RemoteEvent")
		reward.Name = "RewardGranted"
		reward.Parent = remotes
	end
	local bundleConfirmed = remotes:FindFirstChild("BundlePurchaseConfirmed")
	if not bundleConfirmed then
		bundleConfirmed = Instance.new("RemoteEvent")
		bundleConfirmed.Name = "BundlePurchaseConfirmed"
		bundleConfirmed.Parent = remotes
	end
	local purchaseGranted = remotes:FindFirstChild("PurchaseGranted")
	if not purchaseGranted then
		purchaseGranted = Instance.new("RemoteEvent")
		purchaseGranted.Name = "PurchaseGranted"
		purchaseGranted.Parent = remotes
	end
	_inventoryUpdatedRE = inv
	_rewardGrantedRE = reward
	_bundlePurchaseConfirmedRE = bundleConfirmed
	_purchaseGrantedRE = purchaseGranted
end

local function toCatalogCategory(itemType: string): string?
	if itemType == "Pet" then return "Pets" end
	if itemType == "Crown" then return "Crowns" end
	if itemType == "IconImage" then return "IconImages" end
	return nil
end

local function makeDefaultPayload(itemType: string, itemIdOrAmount: any, source: string)
	if itemType == "Currency" then
		return {
			type = "Currency",
			id = "fate_coins",
			amount = tonumber(itemIdOrAmount) or 0,
			source = source,
		}
	elseif itemType == "Spin" then
		return {
			type = "Spin",
			id = "spin_purchased",
			amount = tonumber(itemIdOrAmount) or 0,
			source = source,
		}
	else
		local category = toCatalogCategory(itemType)
		local entry = category and ItemCatalog.Get(category, tostring(itemIdOrAmount)) or nil
		return {
			type = itemType,
			grantType = itemType,
			id = tostring(itemIdOrAmount),
			category = category,
			name = entry and entry.name or tostring(itemIdOrAmount),
			rarity = entry and entry.rarity or "Common",
			popupImageOverride = entry and entry.image or nil,
			imageAssetId = entry and entry.image or nil,
			source = source,
		}
	end
end

local function getGrantAmount(itemType: string, itemIdOrAmount: any): number
	if itemType == "Currency" or itemType == "Spin" then
		return tonumber(itemIdOrAmount) or 0
	end
	return 1
end

function GrantService.EmitRewardGranted(player: Player, payload: any)
	if not _rewardGrantedRE then
		ensureRemotes()
	end
	if _rewardGrantedRE then
		_rewardGrantedRE:FireClient(player, payload)
	end
end

function GrantService.EmitBundlePurchaseConfirmed(player: Player, bundleId: string, payload: any?)
	if not _bundlePurchaseConfirmedRE then
		ensureRemotes()
	end
	if _bundlePurchaseConfirmedRE then
		_bundlePurchaseConfirmedRE:FireClient(player, bundleId, payload or {})
	end
end

function GrantService.EmitPurchaseGranted(player: Player, payload: any)
	if not _purchaseGrantedRE then
		ensureRemotes()
	end
	if _purchaseGrantedRE then
		_purchaseGrantedRE:FireClient(player, payload)
	end
end

function GrantService.Init()
	if initialized then return end
	initialized = true
	ensureRemotes()
end

function GrantService.GrantItem(player: Player, itemType: string, itemIdOrAmount: any, source: string, meta: { [string]: any }?): { success: boolean, reason: string?, alreadyProcessed: boolean?, alreadyOwned: boolean?, payload: any? }
	GrantService.Init()
	meta = meta or {}

	local itemIdText = tostring(itemIdOrAmount)
	print(string.format("[Grant] player=%s type=%s id=%s source=%s result=START", player.Name, tostring(itemType), itemIdText, tostring(source)))

	local PDS = getPlayerData()
	if not PDS or not PDS.IsLoaded(player) then
		local reason = "DATA_NOT_LOADED"
		print(string.format("[Grant] player=%s type=%s id=%s source=%s result=FAIL reason=%s", player.Name, tostring(itemType), itemIdText, tostring(source), reason))
		print(string.format("[Grant] FAIL reason=%s", reason))
		return { success = false, reason = reason }
	end

	local idemKey = meta.idempotencyKey
	local data = PDS.GetData(player)
	if type(idemKey) == "string" and idemKey ~= "" and data then
		local processed = data.ProcessedGrants
		if type(processed) == "table" and processed[idemKey] then
			local allowReplay = false
			if itemType == "Pet" or itemType == "Crown" or itemType == "IconImage" then
				local category = toCatalogCategory(itemType)
				local inv = getInventory()
				if category and inv and not inv.OwnsItem(player, category, itemIdText) then
					allowReplay = true
					print(string.format("[Grant] player=%s type=%s id=%s source=%s staleIdempotencyKey=%s -> replay",
						player.Name, tostring(itemType), itemIdText, tostring(source), idemKey))
				end
			end
			if not allowReplay then
				local payload = meta.payload or makeDefaultPayload(itemType, itemIdOrAmount, source)
				print(string.format("[Grant] player=%s type=%s id=%s source=%s result=SUCCESS alreadyProcessed=true", player.Name, tostring(itemType), itemIdText, tostring(source)))
				return { success = true, alreadyProcessed = true, payload = payload }
			end
		end
	end

	local success = false
	local alreadyOwned = false
	local reason = nil
	local grantedAmount = nil

	if itemType == "Pet" or itemType == "Crown" or itemType == "IconImage" then
		local category = toCatalogCategory(itemType)
		local itemId = tostring(itemIdOrAmount)
		local entry = category and ItemCatalog.Get(category, itemId) or nil
		if not entry then
			reason = "INVALID_CATALOG_ITEM"
		else
			local inv = getInventory()
			if not inv then
				reason = "INVENTORY_UNAVAILABLE"
			else
				if inv.OwnsItem(player, category, itemId) then
					alreadyOwned = true
					success = true
				else
					success = inv.GrantItem(player, category, itemId) == true
					if not success then
						reason = "INVENTORY_GRANT_FAILED"
					end
				end
			end
		end
	elseif itemType == "Spin" then
		local spinsToAdd = tonumber(itemIdOrAmount) or 0
		if spinsToAdd <= 0 then
			reason = "INVALID_AMOUNT"
		else
			local spin = getSpinWheel()
			if not spin or type(spin.GrantRobuxSpins) ~= "function" then
				reason = "SPIN_SERVICE_UNAVAILABLE"
			else
				success = spin.GrantRobuxSpins(player, spinsToAdd) == true
				if not success then
					reason = "SPIN_GRANT_FAILED"
				end
			end
		end
	elseif itemType == "Currency" then
		local amount = tonumber(itemIdOrAmount) or 0
		if amount <= 0 then
			reason = "INVALID_AMOUNT"
		else
			local econ = getEconomy()
			if not econ then
				reason = "ECONOMY_UNAVAILABLE"
			else
				local applyVipMultiplier = meta.applyVipMultiplier == true
				local rewardSource = tostring(meta.rewardSource or ("GrantService:" .. tostring(source)))
				local awardOk, finalAmount
				if applyVipMultiplier and type(econ.AwardVipOnlyCoins) == "function" then
					awardOk, finalAmount = econ.AwardVipOnlyCoins(player, amount, rewardSource)
				else
					awardOk, finalAmount = econ.AwardCoins(player, amount, rewardSource, true)
				end
				success = awardOk == true
				grantedAmount = finalAmount or amount
				if not success then
					reason = "CURRENCY_GRANT_FAILED"
				end
			end
		end
	else
		reason = "UNSUPPORTED_TYPE"
	end

	if not success then
		local failReason = tostring(reason or "UNKNOWN")
		print(string.format("[Grant] player=%s type=%s id=%s source=%s result=FAIL reason=%s", player.Name, tostring(itemType), itemIdText, tostring(source), failReason))
		print(string.format("[Grant] FAIL reason=%s", failReason))
		return { success = false, reason = failReason }
	end

	if type(idemKey) == "string" and idemKey ~= "" then
		local latest = PDS.GetData(player)
		local processed = latest and latest.ProcessedGrants
		if type(processed) ~= "table" then
			processed = {}
		end
		processed[idemKey] = os.time()
		PDS.SetField(player, "ProcessedGrants", processed)
	end

	local payload = meta.payload or makeDefaultPayload(itemType, grantedAmount or itemIdOrAmount, source)
	if itemType == "Currency" and type(payload) == "table" then
		payload.amount = grantedAmount or tonumber(payload.amount) or 0
	end
	if meta.fireReward ~= false and not alreadyOwned then
		GrantService.EmitRewardGranted(player, payload)
	end
	if _inventoryUpdatedRE then
		_inventoryUpdatedRE:FireClient(player, "GrantConfirmed", payload)
	end

	local amount = grantedAmount or getGrantAmount(itemType, itemIdOrAmount)
	print(string.format("[Grant] player=%s type=%s id=%s source=%s result=SUCCESS", player.Name, tostring(itemType), itemIdText, tostring(source)))
	print(string.format("[Grant] SUCCESS type=%s id=%s amount=%d source=%s", tostring(itemType), itemIdText, amount, tostring(source)))
	return { success = true, alreadyOwned = alreadyOwned, payload = payload }
end

return GrantService
