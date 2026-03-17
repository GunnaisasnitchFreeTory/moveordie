--[[
	SpinWheelBootstrap
	Server script that initializes the Spin The Wheel system.

	Creates:
	  • RemoteFunction: SpinWheel_GetData
	  • RemoteFunction: SpinWheel_RequestSpin
	  • RemoteFunction: SpinWheel_BuySpins
	  • ProximityPrompt on a ground-level invisible anchor near SpinTheWheel

	Also:
	  • Removes ClickDetectors from SpinTheWheel (no click-to-spin)
	  • Removes/disables embedded Scripts/LocalScripts (bad sound assets, old logic)
	  • Handles MarketplaceService.ProcessReceipt for Robux spin purchases

	FIX: ProximityPrompt is now on a dedicated invisible anchor Part at ground level
	     so the "Press E" UI is visible from all angles and distance measurements
	     are consistent between the prompt trigger and the auto-close check.

	Wires player join/leave for data persistence.
]]

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local RunService = game:GetService("RunService")

-- Ensure Remotes folder
local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
if not remotesFolder then
	remotesFolder = Instance.new("Folder")
	remotesFolder.Name = "Remotes"
	remotesFolder.Parent = ReplicatedStorage
end
local purchaseGrantedRE = remotesFolder:FindFirstChild("PurchaseGranted")
if not purchaseGrantedRE then
	purchaseGrantedRE = Instance.new("RemoteEvent")
	purchaseGrantedRE.Name = "PurchaseGranted"
	purchaseGrantedRE.Parent = remotesFolder
end

-- Create RemoteFunctions
local function ensureRemoteFunc(name: string): RemoteFunction
	local rf = remotesFolder:FindFirstChild(name)
	if not rf then
		rf = Instance.new("RemoteFunction")
		rf.Name = name
		rf.Parent = remotesFolder
	end
	return rf
end

local getDataRF    = ensureRemoteFunc("SpinWheel_GetData")
local requestSpinRF = ensureRemoteFunc("SpinWheel_RequestSpin")
local buySpinsRF    = ensureRemoteFunc("SpinWheel_BuySpins")
local canPurchaseGamepassRF = ensureRemoteFunc("CanPurchaseGamepassReward")

-- Load service + config
local Server = ServerScriptService:WaitForChild("Server")
local SpinWheelService = require(Server:WaitForChild("SpinWheelService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SpinWheelConfig = require(Shared:WaitForChild("SpinWheelConfig"))
local UIConfig = require(Shared:WaitForChild("UIConfig"))
local MonetizationConfig = require(Shared:WaitForChild("MonetizationConfig"))
local DeveloperProductConfig = require(Shared:WaitForChild("DeveloperProductConfig"))
local PerkCatalog = require(Shared:WaitForChild("PerkCatalog"))
local FreezePlayerProductService = require(Server:WaitForChild("FreezePlayerProductService"))
local ForceNextModeProductService = require(Server:WaitForChild("ForceNextModeProductService"))
local PerkProductService = require(Server:WaitForChild("PerkProductService"))

SpinWheelService.Init()
FreezePlayerProductService.Init()
ForceNextModeProductService.Init()
PerkProductService.Init()

-- Wire RemoteFunctions
getDataRF.OnServerInvoke = function(player)
	print("[SpinWheelBootstrap] GetData requested by", player.Name)
	return SpinWheelService.GetPlayerData(player)
end

requestSpinRF.OnServerInvoke = function(player)
	print("[SpinWheelBootstrap] RequestSpin from", player.Name)
	local result = SpinWheelService.RequestSpin(player)
	print("[SpinWheelBootstrap] RequestSpin result:", result.success, result.rewardName or result.reason or "")
	return result
end

buySpinsRF.OnServerInvoke = function(player, packageIndex)
	if type(packageIndex) ~= "number" then return { success = false, reason = "Invalid input" } end
	print("[SpinWheelBootstrap] BuySpins from", player.Name, "package:", packageIndex)
	return SpinWheelService.BuySpins(player, packageIndex)
end

-- Wire player events
Players.PlayerAdded:Connect(function(player)
	SpinWheelService.OnPlayerJoined(player)
end)

-- Handle players already in game (Studio)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(function()
		SpinWheelService.OnPlayerJoined(player)
	end)
end

Players.PlayerRemoving:Connect(function(player)
	SpinWheelService.OnPlayerLeaving(player)
end)

-- Save all on shutdown
game:BindToClose(function()
	SpinWheelService.SaveAll()
end)

-- ═══════════════════════════════════════════════════════════════════
-- SHARED SERVICE REFERENCES (lazy-loaded)
-- ═══════════════════════════════════════════════════════════════════

local _InventoryService, _EconomyService, _CrateService, _ItemCatalog, _PlayerDataService, _GrantService, _StatService
local GAMEPASS_REWARD_MAP: { [number]: { type: string, [string]: any } }
local _BundleCatalog

local function getInventoryService()
	if not _InventoryService then
		_InventoryService = require(Server:WaitForChild("InventoryService", 5))
	end
	return _InventoryService
end

local function getEconomyService()
	if not _EconomyService then
		_EconomyService = require(Server:WaitForChild("EconomyService", 5))
	end
	return _EconomyService
end

local function getCrateService()
	if not _CrateService then
		_CrateService = require(Server:WaitForChild("CrateService", 5))
	end
	return _CrateService
end

local function getPlayerDataService()
	if not _PlayerDataService then
		_PlayerDataService = require(Server:WaitForChild("PlayerDataService", 5))
	end
	return _PlayerDataService
end

local function getGrantService()
	if not _GrantService then
		_GrantService = require(Server:WaitForChild("GrantService", 5))
	end
	return _GrantService
end

local function getStatService()
	if not _StatService then
		_StatService = require(Server:WaitForChild("StatService", 5))
	end
	return _StatService
end

local function getItemCatalog()
	if not _ItemCatalog then
		local SharedMod = ReplicatedStorage:FindFirstChild("Shared")
		if SharedMod then
			local mod = SharedMod:FindFirstChild("ItemCatalog")
			if mod then _ItemCatalog = require(mod) end
		end
	end
	return _ItemCatalog
end

local function getBundleCatalog()
	if not _BundleCatalog then
		local SharedMod = ReplicatedStorage:FindFirstChild("Shared")
		if SharedMod then
			local mod = SharedMod:FindFirstChild("BundleCatalog")
			if mod then _BundleCatalog = require(mod) end
		end
	end
	return _BundleCatalog
end

local function notifyClient(player: Player, reason: string, data: any?)
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local invUpdate = remotes and remotes:FindFirstChild("InventoryUpdated")
	if invUpdate then
		invUpdate:FireClient(player, reason, data)
	end
end

local function syncVipBundleEntitlement(player: Player, reward: { [string]: any }, source: string)
	if type(reward) ~= "table" or tostring(reward.bundleId or "") ~= "bundle_vip" then
		return
	end

	local stat = getStatService()
	if stat and type(stat.SetVipOwnership) == "function" then
		stat.SetVipOwnership(player, true, source)
	else
		player:SetAttribute("OwnsVIP", true)
	end

	print(string.format("[VIPSync] player=%s bundle=%s source=%s vip=true",
		player.Name, tostring(reward.bundleId), tostring(source)))
	warn(string.format("[VIPPersistence] player=%s vipBundleOwned=%s purchase=true",
		player.Name, tostring(player:GetAttribute("VIPBundleOwned") == true)))
end

local function isVipBundleReward(reward: { [string]: any }?): boolean
	return type(reward) == "table" and tostring(reward.bundleId or "") == "bundle_vip"
end

local function hasVipBundleEntitlement(player: Player): boolean
	local stat = getStatService()
	if stat and type(stat.HasVipEntitlement) == "function" then
		return stat.HasVipEntitlement(player) == true
	end

	return player:GetAttribute("VIPBundleOwned") == true or player:GetAttribute("OwnsVIP") == true
end

local function getGamepassPurchaseGate(player: Player, gamepassId: number): { allowed: boolean, alreadyOwned: boolean, vipOwned: boolean, marketplaceOwned: boolean, reason: string? }
	local reward = GAMEPASS_REWARD_MAP[gamepassId]
	if not reward then
		return {
			allowed = false,
			alreadyOwned = false,
			vipOwned = false,
			marketplaceOwned = false,
			reason = "UNKNOWN_GAMEPASS",
		}
	end

	local vipOwned = isVipBundleReward(reward) and hasVipBundleEntitlement(player)
	local marketplaceOwned = false
	local okOwns, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, gamepassId)
	end)
	if okOwns then
		marketplaceOwned = owns == true
	end

	local alreadyOwned = vipOwned or marketplaceOwned
	local reason = alreadyOwned and "ALREADY_OWNED" or nil
	warn(string.format(
		"[VIPPurchaseGate] player=%s gamepassId=%d vipOwned=%s marketplaceOwned=%s purchaseBlocked=%s",
		player.Name,
		gamepassId,
		tostring(vipOwned),
		tostring(marketplaceOwned),
		tostring(alreadyOwned)
	))

	return {
		allowed = not alreadyOwned,
		alreadyOwned = alreadyOwned,
		vipOwned = vipOwned,
		marketplaceOwned = marketplaceOwned,
		reason = reason,
	}
end

local function toRewardTypeFromCategory(category: string): string
	if category == "Crowns" then return "Crown" end
	if category == "Pets" then return "Pet" end
	if category == "IconImages" then return "IconImage" end
	return "Pet"
end

local function emitShopPurchaseGranted(player: Player, gamepassId: number, reward: { [string]: any })
	if reward.type == "Bundle" then
		return
	end
	local itemCatalog = getItemCatalog()
	local category = tostring(reward.category or "")
	local itemId = tostring(reward.itemId or "")
	local entry = itemCatalog and itemCatalog.Get and itemCatalog.Get(category, itemId) or nil
	local payload = {
		type = toRewardTypeFromCategory(category),
		id = itemId,
		category = category,
		name = entry and entry.name or tostring(reward.label or itemId),
		rarity = entry and entry.rarity or "Common",
		imageAssetId = entry and entry.image or "",
		source = "GamePass",
		gamepassId = gamepassId,
	}
	print(string.format("[ShopGrant] type=%s id=%s passId=%d result=SUCCESS",
		tostring(payload.type), itemId, tonumber(gamepassId) or 0))
	if purchaseGrantedRE then
		purchaseGrantedRE:FireClient(player, payload)
	end
end

-- ═══════════════════════════════════════════════════════════════════
-- CENTRAL PRODUCT_REWARD_MAP (Developer Products → rewards)
--
-- All Developer Product IDs and their reward logic in one table.
-- ProcessReceipt looks up productId here before falling back.
-- ═══════════════════════════════════════════════════════════════════

local PRODUCT_REWARD_MAP: { [number]: { type: string, [string]: any } } = {}

local function registerConfigProductReward(configId: string, reward: { type: string, [string]: any })
	local productId = MonetizationConfig.GetDeveloperProductId(configId)
	if type(productId) == "number" and productId > 0 then
		PRODUCT_REWARD_MAP[productId] = reward
	else
		warn(string.format("[PurchaseSystem] Missing developer product config for %s", configId))
	end
end

registerConfigProductReward("crate_crown_6", { type = "Crate", crateId = "crate_crown",      quantity = 6, label = "6 Crown Crates" })
registerConfigProductReward("crate_pet_common_6", { type = "Crate", crateId = "crate_pet_common", quantity = 6, label = "6 Common Pet Crates" })
registerConfigProductReward("crate_pet_rare_6", { type = "Crate", crateId = "crate_pet_rare",   quantity = 6, label = "6 Rare Pet Crates" })
registerConfigProductReward("crate_pet_epic_6", { type = "Crate", crateId = "crate_pet_epic",   quantity = 6, label = "6 Epic Pet Crates" })

local freezeProductId = tonumber(DeveloperProductConfig.FreezePlayer.productId) or 0
if freezeProductId > 0 then
	PRODUCT_REWARD_MAP[freezeProductId] = {
		type = "FreezePlayer",
		label = tostring(DeveloperProductConfig.FreezePlayer.name or "Freeze Player"),
	}
else
	warn("[PurchaseSystem] FreezePlayer productId is not configured (>0 required)")
end

local forceNextModeProductId = tonumber(DeveloperProductConfig.ForceNextMode.productId) or 0
if forceNextModeProductId > 0 then
	PRODUCT_REWARD_MAP[forceNextModeProductId] = {
		type = "ForceNextMode",
		label = tostring(DeveloperProductConfig.ForceNextMode.name or "FORCE NEXT MODE!"),
	}
else
	warn("[PurchaseSystem] ForceNextMode productId is not configured (>0 required)")
end

local function registerAbilityProduct(configKey: string, abilityId: string)
	local config = DeveloperProductConfig[configKey]
	local productId = config and tonumber(config.productId) or 0
	if productId > 0 then
		PRODUCT_REWARD_MAP[productId] = {
			type = "Ability",
			abilityId = abilityId,
			label = tostring(config.name or abilityId),
		}
	else
		warn(string.format("[PurchaseSystem] %s productId is not configured (>0 required)", configKey))
	end
end

registerAbilityProduct("PerkSpeed", PerkCatalog.Speed.id)
registerAbilityProduct("PerkJump", PerkCatalog.Jump.id)

-- Auto-populate Fate Coin developer products from UIConfig (single source for shop UI + receipts)
for _, item in ipairs(UIConfig.MockPremiumItems or {}) do
	if item.type == "Currency" and type(item.productId) == "number" and item.productId > 0 then
		local amount = tonumber(item.coinsAmount) or 0
		if amount > 0 then
			PRODUCT_REWARD_MAP[item.productId] = {
				type = "Coins",
				amount = amount,
				label = tostring(item.name or (tostring(amount) .. " Fate Coins")),
			}
		end
	end
end

-- Auto-populate spin products from config
for _, pkg in ipairs(SpinWheelConfig.SpinPrices) do
	if pkg.productId and pkg.productId > 0 then
		PRODUCT_REWARD_MAP[pkg.productId] = { type = "Spins", amount = pkg.spins, label = pkg.label }
	end
end

print(string.format("[PurchaseSystem] PRODUCT_REWARD_MAP built: %d entries", (function()
	local n = 0; for _ in pairs(PRODUCT_REWARD_MAP) do n += 1 end; return n
end)()))

local function validateConfiguredRobuxProducts()
	-- Coins from shop config
	for _, entry in ipairs(UIConfig.MockPremiumItems or {}) do
		if entry.type == "Currency" and type(entry.productId) == "number" and entry.productId > 0 then
			if not PRODUCT_REWARD_MAP[entry.productId] then
				warn(string.format("[ReceiptMap] Missing mapping for coin productId=%d (%s)",
					entry.productId, tostring(entry.id)))
			end
		end
	end

	-- Crates from crate shop config
	for _, crate in ipairs(UIConfig.MockCrates or {}) do
		for _, price in ipairs(crate.prices or {}) do
			if price.currency == "Robux" and type(price.productId) == "number" and price.productId > 0 then
				if not PRODUCT_REWARD_MAP[price.productId] then
					warn(string.format("[ReceiptMap] Missing mapping for crate productId=%d (%s)",
						price.productId, tostring(crate.id)))
				end
			end
		end
	end

	-- Spins from spin config
	for _, pkg in ipairs(SpinWheelConfig.SpinPrices or {}) do
		if type(pkg.productId) == "number" and pkg.productId > 0 then
			if not PRODUCT_REWARD_MAP[pkg.productId] then
				warn(string.format("[ReceiptMap] Missing mapping for spin productId=%d (%s)",
					pkg.productId, tostring(pkg.label)))
			end
		end
	end
end

validateConfiguredRobuxProducts()

-- ═══════════════════════════════════════════════════════════════════
-- GAMEPASS_REWARD_MAP (Gamepasses → permanent unlocks)
--
-- Maps gamepassId → item category + id for granting via InventoryService.
-- Bundles map to a list of items to grant.
-- ═══════════════════════════════════════════════════════════════════

GAMEPASS_REWARD_MAP = {}

local function registerGamePassReward(configId: string, reward: { type: string, [string]: any })
	local gamepassId = MonetizationConfig.GetGamePassId(configId)
	if type(gamepassId) == "number" and gamepassId > 0 then
		GAMEPASS_REWARD_MAP[gamepassId] = reward
	else
		warn(string.format("[PurchaseSystem] Missing gamepass config for %s", configId))
	end
end

registerGamePassReward("pet_dark_falcon", { type = "Pet", category = "Pets", itemId = "pet_dark_falcon", label = "Dark Goblem" })
registerGamePassReward("pet_dark_winged_dragon", { type = "Pet", category = "Pets", itemId = "pet_dark_winged_dragon", label = "Music Winged Dragon" })
registerGamePassReward("pet_pink_butterfly", { type = "Pet", category = "Pets", itemId = "pet_pink_butterfly", label = "Pink Butterfly" })
registerGamePassReward("pet_glitched_dragon", { type = "Pet", category = "Pets", itemId = "pet_glitched_dragon", label = "Glitched Dragon" })
registerGamePassReward("pet_freddy_fazbear", { type = "Pet", category = "Pets", itemId = "pet_freddy_fazbear", label = "AnimatronicBear" })
registerGamePassReward("pet_bonnie", { type = "Pet", category = "Pets", itemId = "pet_bonnie", label = "AnimatronicBunny" })
registerGamePassReward("pet_chica", { type = "Pet", category = "Pets", itemId = "pet_chica", label = "AnimatronicChicken" })
registerGamePassReward("pet_foxy", { type = "Pet", category = "Pets", itemId = "pet_foxy", label = "AnimatronicFox" })
registerGamePassReward("pet_golden_freddy", { type = "Pet", category = "Pets", itemId = "pet_golden_freddy", label = "TheOneYouShouldntHaveKilled" })
registerGamePassReward("pet_the_puppet", { type = "Pet", category = "Pets", itemId = "pet_the_puppet", label = "AnimatronicPuppet" })
registerGamePassReward("pet_cupcake", { type = "Pet", category = "Pets", itemId = "pet_cupcake", label = "HauntedCupcake" })

registerGamePassReward("crown_ultra", { type = "Crown", category = "Crowns", itemId = "crown_ultra", label = "Ultra Crown" })
registerGamePassReward("crown_fire_circle", { type = "Crown", category = "Crowns", itemId = "crown_fire_circle", label = "Fire Circle Crown" })
registerGamePassReward("crown_nen_x_killua", { type = "Crown", category = "Crowns", itemId = "crown_nen_x_killua", label = "Nen X Killua Crown" })
registerGamePassReward("crown_slashes", { type = "Crown", category = "Crowns", itemId = "crown_slashes", label = "Slashes Crown" })
	-- Electric Crown (1717992747) removed from migration map.
	-- It is now purchasable with Fate Coins via ShopService. Existing holders
	-- who joined before this change already had the crown migrated to OwnedCrowns.
	-- Removing this entry prevents repeated re-grants when OwnedCrowns is cleared.
registerGamePassReward("crown_rengoku", { type = "Crown", category = "Crowns", itemId = "crown_rengoku", label = "Rengoku Crown" })
registerGamePassReward("crown_infinite_void", { type = "Crown", category = "Crowns", itemId = "crown_infinite_void", label = "Infinite Void Crown" })

registerGamePassReward("brainrot_bundle", {
	type = "Bundle",
	bundleId = "brainrot_bundle",
	label = "Brainrot Bundle",
	items = {
		{ category = "Pets",       itemId = "pet_67" },
		{ category = "Pets",       itemId = "pet_dragon_cannelloni" },
		{ category = "Pets",       itemId = "pet_frigo_camelo" },
		{ category = "Pets",       itemId = "pet_tigroligre_frutonni" },
		{ category = "Pets",       itemId = "pet_trenostruzzo_turbo_3000" },
		{ category = "Crowns",     itemId = "crown_67" },
		{ category = "IconImages", itemId = "icon_67_kid" },
		{ category = "IconImages", itemId = "icon_steve_harrington" },
	},
})
registerGamePassReward("fnaf_pets_bundle", {
	type = "Bundle",
	bundleId = "FNAF_PETS_BUNDLE",
	label = "Animatronic Pets Bundle",
	items = {
		{ category = "Pets", itemId = "pet_freddy_fazbear" },
		{ category = "Pets", itemId = "pet_bonnie" },
		{ category = "Pets", itemId = "pet_chica" },
		{ category = "Pets", itemId = "pet_foxy" },
		{ category = "Pets", itemId = "pet_golden_freddy" },
		{ category = "Pets", itemId = "pet_the_puppet" },
		{ category = "Pets", itemId = "pet_cupcake" },
	},
})
registerGamePassReward("bundle_vip", {
	type = "Bundle",
	bundleId = "bundle_vip",
	label = "VIP Bundle",
	items = {
		{ category = "Crowns", itemId = "crown_vip" },
		{ category = "Crowns", itemId = "crown_whiteeyed" },
		{ category = "IconImages", itemId = "icon_flights_laugh" },
		{ category = "Pets", itemId = "pet_all_knowing_eye" },
		{ type = "Currency", amount = 8000, label = "8000 Fate Coins", popupImageOverride = "rbxassetid://81959864063463", imageAssetId = "rbxassetid://81959864063463" },
	},
})

-- ═══════════════════════════════════════════════════════════════════
-- GAMEPASS GRANT LOGIC
-- ═══════════════════════════════════════════════════════════════════

local function grantGamepassReward(player: Player, gamepassId: number, emitPurchaseGranted: boolean?): boolean
	local reward = GAMEPASS_REWARD_MAP[gamepassId]
	if not reward then return false end

	local grant = getGrantService()
	if not grant then
		warn("[PurchaseSystem] GrantService unavailable for gamepass grant")
		return false
	end

	if reward.type == "Bundle" then
		syncVipBundleEntitlement(player, reward, "GamePassGrant:" .. tostring(gamepassId))

		local grantedItems = {}
		for _, item in ipairs(reward.items) do
			local grantType = nil
			local grantValue = nil
			local grantKey = nil
			if item.type == "Currency" then
				grantType = "Currency"
				grantValue = tonumber(item.amount) or 0
				grantKey = string.format("coins:%d", grantValue)
			elseif item.category and item.itemId then
				grantType = toRewardTypeFromCategory(item.category)
				grantValue = item.itemId
				grantKey = tostring(item.itemId)
			end
			if not grantType or grantValue == nil or grantKey == nil or (grantType == "Currency" and grantValue <= 0) then
				warn(string.format("[PurchaseSystem] Gamepass bundle item invalid: pass=%d label=%s",
					gamepassId, tostring(item.label or item.itemId or item.type)))
				return false
			end
			local okGrant = grant.GrantItem(player, grantType, grantValue, "GamePass", {
				fireReward = false,
				idempotencyKey = string.format("gamepass:%d:%d:%s", player.UserId, gamepassId, grantKey),
			})
			if not okGrant.success then
				warn(string.format("[PurchaseSystem] Gamepass bundle grant failed: %s/%s for %s reason=%s",
					tostring(item.category or item.type), tostring(item.itemId or item.amount), player.Name, tostring(okGrant.reason)))
				return false
			end
			local grantedPayload = okGrant.payload or {
				type = grantType,
				id = item.itemId or "fate_coins",
				category = item.category,
				amount = grantType == "Currency" and tonumber(grantValue) or nil,
				source = "GamePass",
			}
			if item.popupImageOverride and item.popupImageOverride ~= "" then
				grantedPayload.popupImageOverride = item.popupImageOverride
			end
			if item.imageAssetId and item.imageAssetId ~= "" then
				grantedPayload.imageAssetId = item.imageAssetId
			end
			table.insert(grantedItems, grantedPayload)
		end
		if #grantedItems > 0 then
			grant.EmitRewardGranted(player, {
				type = "Bundle",
				id = reward.bundleId or tostring(gamepassId),
				source = "GamePass",
				batchItems = grantedItems,
			})
		end
	else
		local grantType = toRewardTypeFromCategory(reward.category)
		local okGrant = grant.GrantItem(player, grantType, reward.itemId, "GamePass", {
			fireReward = false,
			idempotencyKey = string.format("gamepass:%d:%d:%s", player.UserId, gamepassId, reward.itemId),
		})
		if not okGrant.success then
			warn(string.format("[PurchaseSystem] Gamepass grant failed: %s/%s for %s reason=%s",
				reward.category, reward.itemId, player.Name, tostring(okGrant.reason)))
			return false
		end
		if emitPurchaseGranted == true and not okGrant.alreadyOwned then
			emitShopPurchaseGranted(player, gamepassId, reward)
		end
	end

	notifyClient(player, "GamepassPurchase", { gamepassId = gamepassId })
	print(string.format("[PurchaseSystem] Gamepass %d (%s) granted to %s", gamepassId, reward.label, player.Name))
	return true
end

-- Check all gamepasses on player join and grant any owned items
local function checkGamepassOwnership(player: Player)
	for gamepassId, reward in pairs(GAMEPASS_REWARD_MAP) do
		local ok, owns = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, gamepassId)
		end)
		if ok and owns then
			grantGamepassReward(player, gamepassId, false)
		elseif not ok then
			warn(string.format("[PurchaseSystem] UserOwnsGamePassAsync failed for %s gamepass %d: %s",
				player.Name, gamepassId, tostring(owns)))
		end
	end
end

MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player: Player, gamepassId: number, wasPurchased: boolean)
	print(string.format("[GamePass] FINISHED passId=%d player=%s purchased=%s",
		tonumber(gamepassId) or 0,
		player and player.Name or "unknown",
		tostring(wasPurchased)))
	if not wasPurchased then
		return
	end
	if not player or not player.Parent then
		return
	end
	if GAMEPASS_REWARD_MAP[gamepassId] then
		local granted = grantGamepassReward(player, gamepassId, true)
		if not granted then
			warn(string.format("[GamePass] Grant failed passId=%d player=%s", gamepassId, player.Name))
		end
	end
end)

-- Create remote for client to request gamepass verification after purchase
local gamepassVerifyRF = remotesFolder:FindFirstChild("VerifyGamepassPurchase")
if not gamepassVerifyRF then
	gamepassVerifyRF = Instance.new("RemoteFunction")
	gamepassVerifyRF.Name = "VerifyGamepassPurchase"
	gamepassVerifyRF.Parent = remotesFolder
end

canPurchaseGamepassRF.OnServerInvoke = function(player: Player, gamepassId: number)
	if type(gamepassId) ~= "number" then
		return { allowed = false, reason = "INVALID_GAMEPASS" }
	end

	return getGamepassPurchaseGate(player, gamepassId)
end

gamepassVerifyRF.OnServerInvoke = function(player: Player, gamepassId: number)
	if type(gamepassId) ~= "number" then return { success = false } end

	local reward = GAMEPASS_REWARD_MAP[gamepassId]
	if not reward then return { success = false, reason = "Unknown gamepass" } end

	local gate = getGamepassPurchaseGate(player, gamepassId)
	if isVipBundleReward(reward) and gate.vipOwned == true then
		warn(string.format(
			"[VIPPurchaseGate] player=%s gamepassId=%d vipOwned=%s purchaseBlocked=%s verifyShortCircuit=true",
			player.Name,
			gamepassId,
			tostring(gate.vipOwned),
			tostring(gate.alreadyOwned)
		))
		return { success = true, alreadyOwned = true, reason = "Already owned" }
	end

	local ok, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, gamepassId)
	end)

	if ok and owns then
		local granted = grantGamepassReward(player, gamepassId, true)
		if granted then
			return { success = true }
		end
		return { success = false, reason = "Grant failed" }
	end

	return { success = false, reason = "Not owned" }
end

-- Hook into PlayerAdded for gamepass ownership checks
Players.PlayerAdded:Connect(function(player)
	task.defer(function()
		checkGamepassOwnership(player)
	end)
end)

-- Check existing players (Studio)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(function()
		checkGamepassOwnership(player)
	end)
end

-- ═══════════════════════════════════════════════════════════════════
-- DEVELOPER PRODUCT RECEIPT HANDLING (ProcessReceipt)
--
-- Idempotent: tracks PurchaseId in-memory to prevent double-granting.
-- Uses PRODUCT_REWARD_MAP for centralized reward lookup.
-- ═══════════════════════════════════════════════════════════════════

local processedReceipts: { [string]: boolean } = {}

MarketplaceService.ProcessReceipt = function(receiptInfo)
	local receiptKey = tostring(receiptInfo.PurchaseId)
	local productId = receiptInfo.ProductId
	print(string.format("[Receipt] START productId=%d playerId=%d purchaseId=%s", productId, receiptInfo.PlayerId, receiptKey))

	if processedReceipts[receiptKey] then
		print("[PurchaseSystem] Receipt already processed:", receiptKey)
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		print("[PurchaseSystem] Player not in game for receipt:", receiptKey, "userId:", receiptInfo.PlayerId)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	print(string.format("[Receipt] START productId=%d player=%s purchaseId=%s", productId, player.Name, receiptKey))

	local pds = getPlayerDataService()
	if pds then
		local pdata = pds.GetData(player)
		local processed = pdata and pdata.ProcessedReceipts
		if type(processed) == "table" and processed[receiptKey] then
			processedReceipts[receiptKey] = true
			print(string.format("[Receipt] player=%s productId=%d alreadyProcessed=true", player.Name, productId))
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end
	end

	local reward = PRODUCT_REWARD_MAP[productId]

	if not reward then
		print(string.format("[Receipt] productId=%d result=FAIL reason=UNKNOWN_PRODUCT", productId))
		warn(string.format("[CoinsProduct] player=%s productId=%d grant=0 result=FAIL reason=UNKNOWN_PRODUCT",
			player.Name, productId))
		warn("[PurchaseSystem] Unknown productId:", productId, "receipt:", receiptKey)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	print(string.format("[Receipt] productId=%d resolvedGrant type=%s id=%s amount=%s",
		productId,
		tostring(reward.type),
		tostring(reward.itemId or reward.crateId or ""),
		tostring(reward.amount or reward.quantity or 0)
	))

	local granted = false
	local ok, err = pcall(function()
		local grant = getGrantService()
		if not grant then
			error("GrantService unavailable")
		end
		if reward.type == "Spins" then
			local g = grant.GrantItem(player, "Spin", reward.amount, "DevProduct", {
				idempotencyKey = "receipt:" .. receiptKey,
			})
			granted = g.success

		elseif reward.type == "Coins" then
			local g = grant.GrantItem(player, "Currency", reward.amount, "DevProduct", {
				idempotencyKey = "receipt:" .. receiptKey,
			})
			granted = g.success
			if granted then
				print(string.format("[CoinsProduct] player=%s productId=%d grant=%d result=SUCCESS",
					player.Name, productId, reward.amount))
			end

		elseif reward.type == "Crate" then
			local crate = getCrateService()
			if crate then
				local result = crate.AddCrates(player, reward.crateId, reward.quantity, "DevProduct")
				if result and result.success then
					local remotes = ReplicatedStorage:FindFirstChild("Remotes")
					local invUpdate = remotes and remotes:FindFirstChild("InventoryUpdated")
					if invUpdate and invUpdate:IsA("RemoteEvent") then
						invUpdate:FireClient(player, "CrateBalance", {
							crateId = reward.crateId,
							newCount = result.newCount,
							counts = crate.GetCrateCounts(player),
							qty = reward.quantity,
						})
					end
					granted = true
				else
					warn("[PurchaseSystem] AddCrates failed:", result and result.reason or "unknown")
				end
			end
		elseif reward.type == "FreezePlayer" then
			local consumeOk, consumeReason = FreezePlayerProductService.ConsumePendingReceipt(player, receiptKey)
			granted = consumeOk
			print(string.format(
				"[FreezeProductReceipt] purchaser=%s productId=%d result=%s reason=%s",
				player.Name,
				productId,
				tostring(granted),
				tostring(consumeReason)
			))

		elseif reward.type == "ForceNextMode" then
			local consumeOk, consumeReason = ForceNextModeProductService.ConsumePendingReceipt(player, receiptKey)
			granted = consumeOk
			print(string.format(
				"[ForceNextModeReceipt] purchaser=%s productId=%d result=%s reason=%s",
				player.Name,
				productId,
				tostring(granted),
				tostring(consumeReason)
			))
		elseif reward.type == "Ability" then
			local consumeOk, consumeReason = PerkProductService.ConsumePendingReceipt(
				player,
				receiptKey,
				tostring(reward.abilityId or "")
			)
			granted = consumeOk
			print(string.format(
				"[AbilityProductReceipt] purchaser=%s productId=%d ability=%s result=%s reason=%s",
				player.Name,
				productId,
				tostring(reward.abilityId),
				tostring(granted),
				tostring(consumeReason)
			))
		end
	end)

	if not ok then
		print(string.format("[Receipt] productId=%d result=FAIL reason=%s", productId, tostring(err)))
		warn("[PurchaseSystem] Error granting reward for productId", productId, ":", err)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if granted then
		processedReceipts[receiptKey] = true
		if pds then
			local pdata = pds.GetData(player)
			if pdata then
				local processed = pdata.ProcessedReceipts
				if type(processed) ~= "table" then
					processed = {}
				end
				processed[receiptKey] = true
				pds.SetField(player, "ProcessedReceipts", processed)
			end
		end
		print(string.format("[Receipt] productId=%d result=SUCCESS", productId))
		print(string.format("[PurchaseSystem] Granted: %s (%s) to %s, receipt=%s",
			reward.label, reward.type, player.Name, receiptKey))
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	print(string.format("[Receipt] productId=%d result=FAIL reason=GRANT_RETURNED_FALSE", productId))
	warn("[PurchaseSystem] Failed to grant reward for productId:", productId, "receipt:", receiptKey)
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

print("[PurchaseSystem] ProcessReceipt + Gamepass handlers installed")

-- ═══════════════════════════════════════════════════════════════════
-- SPIN THE WHEEL: CLEANUP + PROXIMITY PROMPT SETUP
-- ═══════════════════════════════════════════════════════════════════

task.defer(function()
	local spinModel = workspace:FindFirstChild("SpinTheWheel", true)
	if not spinModel then
		-- Retry a few times (streaming may delay)
		for i = 1, 5 do
			task.wait(2)
			spinModel = workspace:FindFirstChild("SpinTheWheel", true)
			if spinModel then break end
		end
	end

	if not spinModel then
		warn("[SpinWheelBootstrap] SpinTheWheel model NOT FOUND in Workspace — ProximityPrompt not created")
		return
	end

	print("[SpinWheelBootstrap] SpinTheWheel found:", spinModel:GetFullName())

	-- A) REMOVE all ClickDetectors (disable click-to-spin in the 3D world)
	local clickDetectorsRemoved = 0
	for _, desc in ipairs(spinModel:GetDescendants()) do
		if desc:IsA("ClickDetector") then
			print("[SpinWheelBootstrap] REMOVING ClickDetector:", desc:GetFullName())
			desc:Destroy()
			clickDetectorsRemoved += 1
		end
	end
	if clickDetectorsRemoved > 0 then
		print("[SpinWheelBootstrap] Removed", clickDetectorsRemoved, "ClickDetector(s)")
	end

	-- B) DISABLE/REMOVE embedded Scripts and LocalScripts
	--    These may contain old click-to-spin logic or unauthorized sound assets
	local scriptsRemoved = 0
	for _, desc in ipairs(spinModel:GetDescendants()) do
		if desc:IsA("Script") or desc:IsA("LocalScript") then
			print("[SpinWheelBootstrap] REMOVING embedded script:", desc:GetFullName(), "(" .. desc.ClassName .. ")")
			desc.Disabled = true
			desc:Destroy()
			scriptsRemoved += 1
		end
	end
	if scriptsRemoved > 0 then
		print("[SpinWheelBootstrap] Removed", scriptsRemoved, "embedded script(s)")
	end

	-- C) REMOVE any existing ProximityPrompts (we'll create a fresh one)
	for _, desc in ipairs(spinModel:GetDescendants()) do
		if desc:IsA("ProximityPrompt") then
			print("[SpinWheelBootstrap] Removing old ProximityPrompt:", desc:GetFullName())
			desc:Destroy()
		end
	end

	-- D) Find the GROUND-LEVEL center position of the spin wheel model
	--    The actual wheel is elevated (Y ~16.5 studs), which causes distance
	--    mismatch between the prompt and auto-close checks.
	--    We create an invisible anchor Part at GROUND LEVEL so:
	--    1) The "Press E" prompt renders at a visible height (not behind the wheel)
	--    2) Distance measurements are consistent (horizontal, not affected by elevation)
	local wheelCenter = nil

	-- Try to find the model center
	local anyPart = spinModel:FindFirstChildWhichIsA("BasePart", true)
	if anyPart then
		-- Use horizontal position of any part, but force Y to near-ground level
		wheelCenter = Vector3.new(anyPart.Position.X, 5, anyPart.Position.Z)
		print("[SpinWheelBootstrap] Reference part:", anyPart:GetFullName(), "at", anyPart.Position)
	end

	if not wheelCenter then
		warn("[SpinWheelBootstrap] No BasePart found in SpinTheWheel — cannot create ProximityPrompt")
		return
	end

	-- Create an invisible anchor Part at ground level
	local anchor = Instance.new("Part")
	anchor.Name = "SpinWheelPromptAnchor"
	anchor.Size = Vector3.new(2, 2, 2)
	anchor.Position = wheelCenter
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1 -- invisible
	anchor.Parent = spinModel

	print("[SpinWheelBootstrap] Created invisible anchor at:", wheelCenter)

	-- Create ProximityPrompt on the ground-level anchor
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "SpinWheelPrompt"
	prompt.ActionText = "Spin"
	prompt.ObjectText = "Spin The Wheel"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 14
	prompt.RequiresLineOfSight = false
	prompt.Parent = anchor

	print("[SpinWheelBootstrap] ProximityPrompt created on:", anchor:GetFullName(), "at Y =", wheelCenter.Y)
	print("[SpinWheelBootstrap] Spin The Wheel system fully ready ✓")
end)

print("[SpinWheelBootstrap] Spin The Wheel remotes ready")
