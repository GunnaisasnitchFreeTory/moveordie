--[[
	SpinWheelService
	Server-authoritative spin wheel logic.

	Responsibilities:
	  * Track per-player spin data (free spin timer, purchased spins)
	  * Validate spin requests
	  * Weighted RNG for reward selection (uses segment.weight)
	  * Award rewards AFTER spin animation completes (pending spin system)
	    – Coins → EconomyService.AwardCoins
	    – Pets  → InventoryService.GrantItem
	  * Persist spin data via DataStore (with pcall fallback)
	  * Grant spins purchased via Robux (called from ProcessReceipt)

	API:
	  Init()
	  GetPlayerData(player) → { freeSpinAvailable, nextFreeSpinTime, purchasedSpins }
	  RequestSpin(player)   → { success, segmentIndex, rewardName, rewardType,
	                             coinsAwarded, catalogId, rarity, spinId }
	                           | { success=false, reason }
	  BuySpins(player, packageIndex) → { success, newSpinCount } | { success=false, reason }
	  GrantRobuxSpins(player, spinsToAdd) → boolean
	  SavePlayer(player)    → saves data to DataStore
]]

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
if not Shared then
	warn("[SpinWheelService] ReplicatedStorage.Shared not found after 10s — spin wheel disabled")
	return {
		Init = function() end, OnPlayerJoined = function() end, OnPlayerLeaving = function() end,
		GetPlayerData = function() return { freeSpinAvailable = false, nextFreeSpinTime = 0, purchasedSpins = 0 } end,
		RequestSpin = function() return { success = false, reason = "Service unavailable" } end,
		BuySpins = function() return { success = false, reason = "Service unavailable" } end,
		GrantRobuxSpins = function() return false end, SaveAll = function() end,
	}
end

local SpinWheelConfigModule = Shared:WaitForChild("SpinWheelConfig", 10)
local SpinWheelConfig
if SpinWheelConfigModule then
	local ok, mod = pcall(require, SpinWheelConfigModule)
	if ok then SpinWheelConfig = mod else warn("[SpinWheelService] SpinWheelConfig failed to load:", mod) end
end
if not SpinWheelConfig then
	warn("[SpinWheelService] SpinWheelConfig not found — spin wheel will not function")
	return {
		Init = function() end, OnPlayerJoined = function() end, OnPlayerLeaving = function() end,
		GetPlayerData = function() return { freeSpinAvailable = false, nextFreeSpinTime = 0, purchasedSpins = 0 } end,
		RequestSpin = function() return { success = false, reason = "Config missing" } end,
		BuySpins = function() return { success = false, reason = "Config missing" } end,
		GrantRobuxSpins = function() return false end, SaveAll = function() end,
	}
end

local ItemCatalogModule = Shared:WaitForChild("ItemCatalog", 10)
local ItemCatalog
if ItemCatalogModule then
	local ok, mod = pcall(require, ItemCatalogModule)
	if ok then ItemCatalog = mod else warn("[SpinWheelService] ItemCatalog failed to load:", mod) end
end
if not ItemCatalog then
	warn("[SpinWheelService] ItemCatalog not found — pet rewards will use raw catalog IDs")
	ItemCatalog = { GetPet = function() return nil end }
end

local spinDataStore = nil
pcall(function()
	spinDataStore = DataStoreService:GetDataStore("SpinWheelData_v1")
end)

local _EconomyService = nil
local _InventoryService = nil

local function getEconomyService()
	if _EconomyService ~= nil then return _EconomyService end
	local ok, mod = pcall(function()
		local Server = ServerScriptService:WaitForChild("Server", 5)
		return require(Server:WaitForChild("EconomyService", 5))
	end)
	if ok and mod then _EconomyService = mod else _EconomyService = false end
	return _EconomyService
end

local function getInventoryService()
	if _InventoryService ~= nil then return _InventoryService end
	local ok, mod = pcall(function()
		local Server = ServerScriptService:WaitForChild("Server", 5)
		return require(Server:WaitForChild("InventoryService", 5))
	end)
	if ok and mod then _InventoryService = mod else _InventoryService = false end
	return _InventoryService
end

local SPIN_DURATION_SECONDS = 11

local playerCache: { [number]: { lastFreeSpinTime: number, purchasedSpins: number } } = {}
local spinInProgress: { [number]: boolean } = {}
local pendingSpin: {
	[number]: {
		spinId: string,
		segmentIndex: number,
		rewardName: string,
		rewardType: string,
		coinsAwarded: number,
		catalogId: string?,
		createdAt: number,
		grantAtTime: number,
	}
} = {}

local SpinWheelService = {}

local function log(...)
	print("[SpinWheelService]", ...)
end

local function isUnlimitedSpinsEnabled(): boolean
	return RunService:IsStudio() or SpinWheelConfig.DEBUG_UNLIMITED_SPINS == true
end

-- ═══════════════════════════════════════════
-- PET GRANT (delegates to InventoryService)
-- ═══════════════════════════════════════════

local function grantPet(player: Player, catalogId: string)
	local IS = getInventoryService()
	if IS and type(IS.GrantItem) == "function" then
		IS.GrantItem(player, "Pets", catalogId)
		log(string.format("PET GRANTED via InventoryService: %s → %s", player.Name, catalogId))
	else
		local raw = player:GetAttribute("OwnedPets")
		local pets = {}
		if raw and type(raw) == "string" and raw ~= "" then
			local ok2, list = pcall(function() return HttpService:JSONDecode(raw) end)
			if ok2 and type(list) == "table" then pets = list end
		end
		table.insert(pets, catalogId)
		player:SetAttribute("OwnedPets", HttpService:JSONEncode(pets))
		log(string.format("PET GRANTED via fallback: %s → %s (total: %d)", player.Name, catalogId, #pets))
	end
end

-- ═══════════════════════════════════════════
-- DATA PERSISTENCE (spin-specific)
-- ═══════════════════════════════════════════

local function loadData(userId: number): { lastFreeSpinTime: number, purchasedSpins: number }
	local data = { lastFreeSpinTime = 0, purchasedSpins = 0 }
	if spinDataStore then
		local ok, saved = pcall(function()
			return spinDataStore:GetAsync("SpinWheel_" .. tostring(userId))
		end)
		if ok and saved and type(saved) == "table" then
			data.lastFreeSpinTime = saved.lastFreeSpinTime or 0
			data.purchasedSpins = saved.purchasedSpins or 0
		end
	end
	return data
end

local function saveData(userId: number, data: { lastFreeSpinTime: number, purchasedSpins: number })
	if not spinDataStore then return end
	pcall(function()
		spinDataStore:SetAsync("SpinWheel_" .. tostring(userId), {
			lastFreeSpinTime = data.lastFreeSpinTime,
			purchasedSpins = data.purchasedSpins,
		})
	end)
end

-- ═══════════════════════════════════════════
-- WEIGHTED RNG
-- ═══════════════════════════════════════════

local function getRandomSegment(): number
	local segments = SpinWheelConfig.Segments
	local totalWeight = 0
	for _, seg in ipairs(segments) do
		totalWeight = totalWeight + (seg.weight or seg.chance or 1)
	end
	local roll = math.random() * totalWeight
	local cumulative = 0
	for i, seg in ipairs(segments) do
		cumulative = cumulative + (seg.weight or seg.chance or 1)
		if roll <= cumulative then
			return i
		end
	end
	return 1
end

local function clearPending(userId: number, reason: string?)
	local p = pendingSpin[userId]
	if p then
		pendingSpin[userId] = nil
		spinInProgress[userId] = nil
		if reason then
			log(string.format("PENDING CLEARED spinId=%s userId=%d reason=%s", p.spinId, userId, reason))
		end
	end
end

-- ═══════════════════════════════════════════
-- PUBLIC API
-- ═══════════════════════════════════════════

function SpinWheelService.Init()
	log("Initialized")
	if isUnlimitedSpinsEnabled() then
		log("DEBUG: Unlimited spins ENABLED")
	end
end

function SpinWheelService.OnPlayerJoined(player: Player)
	local data = loadData(player.UserId)
	playerCache[player.UserId] = data
	log(string.format("%s loaded — lastFreeSpin: %d, purchasedSpins: %d",
		player.Name, data.lastFreeSpinTime, data.purchasedSpins))
end

function SpinWheelService.OnPlayerLeaving(player: Player)
	local userId = player.UserId
	clearPending(userId, "PlayerLeaving")
	local data = playerCache[userId]
	if data then
		saveData(userId, data)
		playerCache[userId] = nil
		spinInProgress[userId] = nil
		log(player.Name .. " spin data saved")
	end
end

function SpinWheelService.GetPlayerData(player: Player): { freeSpinAvailable: boolean, nextFreeSpinTime: number, purchasedSpins: number }
	local data = playerCache[player.UserId]
	if not data then
		data = loadData(player.UserId)
		playerCache[player.UserId] = data
	end

	if isUnlimitedSpinsEnabled() then
		return {
			freeSpinAvailable = true,
			nextFreeSpinTime = 0,
			nextFreeSpinAt = 0, -- absolute timestamp (0 = available now)
			purchasedSpins = data.purchasedSpins,
		}
	end

	local now = os.time()
	local elapsed = now - data.lastFreeSpinTime
	local freeAvailable = elapsed >= SpinWheelConfig.FREE_SPIN_COOLDOWN
	local nextFreeTime = freeAvailable and 0 or (data.lastFreeSpinTime + SpinWheelConfig.FREE_SPIN_COOLDOWN - now)
	local absoluteNextFree = freeAvailable and 0 or (data.lastFreeSpinTime + SpinWheelConfig.FREE_SPIN_COOLDOWN)

	return {
		freeSpinAvailable = freeAvailable,
		nextFreeSpinTime = math.max(0, nextFreeTime),
		nextFreeSpinAt = absoluteNextFree, -- absolute unix timestamp for drift-free client timer
		purchasedSpins = data.purchasedSpins,
	}
end

function SpinWheelService.RequestSpin(player: Player)
	log(string.format("RequestSpin from %s — validating...", player.Name))

	local userId = player.UserId

	if spinInProgress[userId] then
		return { success = false, reason = "Spin already in progress" }
	end
	if pendingSpin[userId] then
		return { success = false, reason = "Spin already in progress" }
	end

	local data = playerCache[userId]
	if not data then
		return { success = false, reason = "Data not loaded" }
	end

	local debugUnlimited = isUnlimitedSpinsEnabled()
	local now = os.time()
	local hasFree = (now - data.lastFreeSpinTime) >= SpinWheelConfig.FREE_SPIN_COOLDOWN
	local hasPurchased = data.purchasedSpins > 0

	if debugUnlimited then
		hasFree = true
		hasPurchased = true
	end

	if not hasFree and not hasPurchased then
		return { success = false, reason = "No spins available" }
	end

	spinInProgress[userId] = true

	local spinType = "free"
	if debugUnlimited then
		spinType = "debug"
	else
		if hasFree then
			data.lastFreeSpinTime = now
		else
			data.purchasedSpins = data.purchasedSpins - 1
			spinType = "purchased"
		end
	end

	local segIndex = getRandomSegment()
	local segment = SpinWheelConfig.Segments[segIndex]
	local rewardType = segment.reward
	local rewardName = segment.name
	local coinsToAward = segment.amount or 0
	local catalogId = segment.catalogId
	local rarity = segment.rarity or "Common"

	if rewardType == "Pet" and catalogId then
		local petInfo = ItemCatalog.GetPet(catalogId)
		if petInfo then
			rewardName = petInfo.name .. " (" .. petInfo.rarity .. ")"
		end
	end

	local spinId = HttpService:GenerateGUID(false)
	local createdAt = os.time()
	local grantAtTime = createdAt + SPIN_DURATION_SECONDS

	pendingSpin[userId] = {
		spinId = spinId,
		segmentIndex = segIndex,
		rewardName = rewardName,
		rewardType = rewardType,
		coinsAwarded = coinsToAward,
		catalogId = catalogId,
		createdAt = createdAt,
		grantAtTime = grantAtTime,
	}

	if not debugUnlimited then
		task.spawn(function() saveData(userId, data) end)
	end

	task.delay(SPIN_DURATION_SECONDS, function()
		local pending = pendingSpin[userId]
		if not pending or pending.spinId ~= spinId then return end

		pendingSpin[userId] = nil

		local livePlayer = Players:GetPlayerByUserId(userId)
		if not livePlayer then
			spinInProgress[userId] = nil
			return
		end

		if pending.rewardType == "Pet" and pending.catalogId then
			grantPet(livePlayer, pending.catalogId)
			log(string.format("GRANTED spinId=%s Pet %s to %s", spinId, pending.catalogId, livePlayer.Name))
		elseif pending.rewardType == "Crown" and pending.catalogId then
			-- Grant crown via InventoryService (same pattern as pets)
			local IS = getInventoryService()
			if IS and type(IS.GrantItem) == "function" then
				IS.GrantItem(livePlayer, "Crowns", pending.catalogId)
			end
			log(string.format("GRANTED spinId=%s Crown %s to %s", spinId, pending.catalogId, livePlayer.Name))
		else
			-- Coins reward
			local ES = getEconomyService()
			if ES and type(ES.AwardCoins) == "function" then
				ES.AwardCoins(livePlayer, pending.coinsAwarded, "SpinWheel")
			else
				local currentCoins = livePlayer:GetAttribute("Coins") or 0
				livePlayer:SetAttribute("Coins", currentCoins + pending.coinsAwarded)
			end
			log(string.format("GRANTED spinId=%s %s to %s (+%d coins)",
				spinId, pending.rewardName, livePlayer.Name, pending.coinsAwarded))
		end

		spinInProgress[userId] = nil
	end)

	return {
		success = true,
		segmentIndex = segIndex,
		rewardName = rewardName,
		rewardType = rewardType,
		coinsAwarded = coinsToAward,
		catalogId = catalogId,
		rarity = rarity,
		wheelImage = segment.wheelImage or "",
		spinId = spinId,
	}
end

function SpinWheelService.BuySpins(player: Player, packageIndex: number): { success: boolean, newSpinCount: number?, reason: string? }
	local data = playerCache[player.UserId]
	if not data then
		return { success = false, reason = "Data not loaded" }
	end

	local pkg = SpinWheelConfig.SpinPrices[packageIndex]
	if not pkg then
		return { success = false, reason = "Invalid package" }
	end

	local ES = getEconomyService()
	if ES and type(ES.DeductCoins) == "function" then
		local ok = ES.DeductCoins(player, pkg.coins, "BuySpins")
		if not ok then
			return { success = false, reason = "Not enough Fate Coins" }
		end
	else
		local currentCoins = player:GetAttribute("Coins") or 0
		if currentCoins < pkg.coins then
			return { success = false, reason = "Not enough Fate Coins" }
		end
		player:SetAttribute("Coins", currentCoins - pkg.coins)
	end

	data.purchasedSpins = data.purchasedSpins + pkg.spins

	task.spawn(function() saveData(player.UserId, data) end)

	log(string.format("Bought spins: option=%d cost=%d spins=+%d total=%d player=%s",
		packageIndex, pkg.coins, pkg.spins, data.purchasedSpins, player.Name))

	return {
		success = true,
		newSpinCount = data.purchasedSpins,
	}
end

function SpinWheelService.GrantRobuxSpins(player: Player, spinsToAdd: number): boolean
	local data = playerCache[player.UserId]
	if not data then
		warn("[SpinWheelService] GrantRobuxSpins failed — no cached data for", player.Name)
		return false
	end

	data.purchasedSpins = data.purchasedSpins + spinsToAdd

	task.spawn(function() saveData(player.UserId, data) end)

	log(string.format("Robux spins granted: +%d total=%d player=%s",
		spinsToAdd, data.purchasedSpins, player.Name))

	return true
end

function SpinWheelService.SaveAll()
	for userId, data in pairs(playerCache) do
		saveData(userId, data)
	end
	log("All spin data saved")
end

return SpinWheelService
