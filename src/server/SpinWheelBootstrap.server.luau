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

-- Ensure Remotes folder
local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
if not remotesFolder then
	remotesFolder = Instance.new("Folder")
	remotesFolder.Name = "Remotes"
	remotesFolder.Parent = ReplicatedStorage
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

-- Load service + config
local Server = ServerScriptService:WaitForChild("Server")
local SpinWheelService = require(Server:WaitForChild("SpinWheelService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SpinWheelConfig = require(Shared:WaitForChild("SpinWheelConfig"))
local UIConfig = require(Shared:WaitForChild("UIConfig"))

SpinWheelService.Init()

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

local _InventoryService, _EconomyService, _CrateService, _ItemCatalog, _PlayerDataService, _GrantService
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

-- ═══════════════════════════════════════════════════════════════════
-- CENTRAL PRODUCT_REWARD_MAP (Developer Products → rewards)
--
-- All Developer Product IDs and their reward logic in one table.
-- ProcessReceipt looks up productId here before falling back.
-- ═══════════════════════════════════════════════════════════════════

local PRODUCT_REWARD_MAP: { [number]: { type: string, [string]: any } } = {
	-- Spins (auto-populated from SpinWheelConfig below)

	-- Crate Bundles (6x each, uses CrateService.RollCrateFree)
	[3539706736] = { type = "Crate", crateId = "crate_crown",      quantity = 6, label = "6 Crown Crates" },
	[3539709447] = { type = "Crate", crateId = "crate_pet_common", quantity = 6, label = "6 Common Pet Crates" },
	[3539710049] = { type = "Crate", crateId = "crate_pet_rare",   quantity = 6, label = "6 Rare Pet Crates" },
	[3539710471] = { type = "Crate", crateId = "crate_pet_epic",   quantity = 6, label = "6 Epic Pet Crates" },
}

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

local GAMEPASS_REWARD_MAP: { [number]: { type: string, [string]: any } } = {
	-- Exclusive Pets
	[1716313058] = { type = "Pet",   category = "Pets",   itemId = "pet_dark_falcon",        label = "Dark Goblem" },
	[1717772785] = { type = "Pet",   category = "Pets",   itemId = "pet_dark_winged_dragon",  label = "Music Winged Dragon" },
	[1716864887] = { type = "Pet",   category = "Pets",   itemId = "pet_pink_butterfly",      label = "Pink Butterfly" },
	[1718832641] = { type = "Pet",   category = "Pets",   itemId = "pet_glitched_dragon",     label = "Glitched Dragon" },
	[1885101001] = { type = "Pet",   category = "Pets",   itemId = "pet_freddy_fazbear",      label = "Freddy Fazbear" },
	[1885101002] = { type = "Pet",   category = "Pets",   itemId = "pet_bonnie",              label = "Bonnie" },
	[1885101003] = { type = "Pet",   category = "Pets",   itemId = "pet_chica",               label = "Chica" },
	[1885101004] = { type = "Pet",   category = "Pets",   itemId = "pet_foxy",                label = "Foxy" },
	[1885101005] = { type = "Pet",   category = "Pets",   itemId = "pet_golden_freddy",       label = "Golden Freddy" },
	[1885101006] = { type = "Pet",   category = "Pets",   itemId = "pet_the_puppet",          label = "ThePuppet" },
	[1885101007] = { type = "Pet",   category = "Pets",   itemId = "pet_cupcake",             label = "Cupcake" },

	-- Exclusive Crowns
	[1717864767] = { type = "Crown", category = "Crowns", itemId = "crown_ultra",             label = "Ultra Crown" },
	[1728155288] = { type = "Crown", category = "Crowns", itemId = "crown_fire_circle",        label = "Fire Circle Crown" },
	[1728821173] = { type = "Crown", category = "Crowns", itemId = "crown_nen_x_killua",       label = "Nen X Killua Crown" },
	[1727051517] = { type = "Crown", category = "Crowns", itemId = "crown_slashes",            label = "Slashes Crown" },
	-- Electric Crown (1717992747) removed from migration map.
	-- It is now purchasable with Fate Coins via ShopService. Existing holders
	-- who joined before this change already had the crown migrated to OwnedCrowns.
	-- Removing this entry prevents repeated re-grants when OwnedCrowns is cleared.
	[1716918881] = { type = "Crown", category = "Crowns", itemId = "crown_rengoku",           label = "Rengoku Crown" },
	[1717662811] = { type = "Crown", category = "Crowns", itemId = "crown_infinite_void",     label = "Infinite Void Crown" },

	-- Brainrot Bundle (grants multiple items)
	[1714491142] = {
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
	},
	[1732407562] = {
		type = "Bundle",
		bundleId = "FNAF_PETS_BUNDLE",
		label = "FNAF Pets Bundle",
		items = {
			{ category = "Pets", itemId = "pet_freddy_fazbear" },
			{ category = "Pets", itemId = "pet_bonnie" },
			{ category = "Pets", itemId = "pet_chica" },
			{ category = "Pets", itemId = "pet_foxy" },
			{ category = "Pets", itemId = "pet_golden_freddy" },
			{ category = "Pets", itemId = "pet_the_puppet" },
			{ category = "Pets", itemId = "pet_cupcake" },
		},
	},
}

-- ═══════════════════════════════════════════════════════════════════
-- GAMEPASS GRANT LOGIC
-- ═══════════════════════════════════════════════════════════════════

local function grantGamepassReward(player: Player, gamepassId: number): boolean
	local reward = GAMEPASS_REWARD_MAP[gamepassId]
	if not reward then return false end

	local grant = getGrantService()
	if not grant then
		warn("[PurchaseSystem] GrantService unavailable for gamepass grant")
		return false
	end

	if reward.type == "Bundle" then
		local grantedItems = {}
		for _, item in ipairs(reward.items) do
			local grantType = (item.category == "Crowns") and "Crown" or "Pet"
			local okGrant = grant.GrantItem(player, grantType, item.itemId, "GamePass", {
				fireReward = false,
				idempotencyKey = string.format("gamepass:%d:%d:%s", player.UserId, gamepassId, item.itemId),
			})
			if not okGrant.success then
				warn(string.format("[PurchaseSystem] Gamepass bundle grant failed: %s/%s for %s reason=%s",
					item.category, item.itemId, player.Name, tostring(okGrant.reason)))
				return false
			end
			table.insert(grantedItems, {
				type = grantType,
				id = item.itemId,
				category = item.category,
				source = "GamePass",
			})
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
		local grantType = (reward.category == "Crowns") and "Crown" or "Pet"
		local okGrant = grant.GrantItem(player, grantType, reward.itemId, "GamePass", {
			idempotencyKey = string.format("gamepass:%d:%d:%s", player.UserId, gamepassId, reward.itemId),
		})
		if not okGrant.success then
			warn(string.format("[PurchaseSystem] Gamepass grant failed: %s/%s for %s reason=%s",
				reward.category, reward.itemId, player.Name, tostring(okGrant.reason)))
			return false
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
			grantGamepassReward(player, gamepassId)
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
		local granted = grantGamepassReward(player, gamepassId)
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

gamepassVerifyRF.OnServerInvoke = function(player: Player, gamepassId: number)
	if type(gamepassId) ~= "number" then return { success = false } end

	local reward = GAMEPASS_REWARD_MAP[gamepassId]
	if not reward then return { success = false, reason = "Unknown gamepass" } end

	local ok, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, gamepassId)
	end)

	if ok and owns then
		local granted = grantGamepassReward(player, gamepassId)
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
