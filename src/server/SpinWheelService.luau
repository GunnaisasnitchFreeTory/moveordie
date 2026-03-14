--[[
	SpinWheelService
	Server-authoritative spin wheel logic.

	Responsibilities:
	  * Track per-player spin data (free spin timer, purchased spins)
	  * Validate spin requests
	  * Weighted RNG for reward selection (uses segment.weight)
	  * Award rewards AFTER spin animation completes (pending spin system)
	    – Coins → EconomyService.AwardCoins (skipMultiplier=true)
	    – Pets  → InventoryService.GrantItem
	  * Persist spin data via DataStore (with pcall fallback)
	  * Grant spins purchased via Robux (called from ProcessReceipt)
	  * New players start with 1 purchased spin
	  * DATA_VERSION migration resets inflated spins for existing players

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

local IS_STUDIO = RunService:IsStudio()

local spinDataStore = nil
pcall(function()
	local storeName = IS_STUDIO and "SpinWheelData_v1_STUDIO" or "SpinWheelData_v1"
	spinDataStore = DataStoreService:GetDataStore(storeName)
end)

local _EconomyService = nil
local _InventoryService = nil
local _GrantService = nil

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

local function getGrantService()
	if _GrantService ~= nil then return _GrantService end
	local ok, mod = pcall(function()
		local Server = ServerScriptService:WaitForChild("Server", 5)
		return require(Server:WaitForChild("GrantService", 5))
	end)
	if ok and mod then _GrantService = mod else _GrantService = false end
	return _GrantService
end

local SPIN_DURATION_SECONDS = 11
local CROWN_DUPLICATE_COINS = 100
local CROWN_MAX_REROLL = 5
local NEW_PLAYER_STARTING_SPINS = 1
local DATA_VERSION = 2

local playerCache: { [number]: { lastFreeSpinTime: number, purchasedSpins: number, dataVersion: number } } = {}
local spinInProgress: { [number]: boolean } = {}

local function log(...)
	print("[SpinWheelService]", ...)
end

local _findableCrownPool: { { id: string, name: string, rarity: string, image: string? } }? = nil

local function getFindableCrownPool()
	if _findableCrownPool then return _findableCrownPool end
	_findableCrownPool = {}
	if ItemCatalog and ItemCatalog.Crowns then
		for id, entry in pairs(ItemCatalog.Crowns) do
			if entry.source == "Findable" and entry.modelPath and entry.modelPath ~= "" then
				table.insert(_findableCrownPool, {
					id    = id,
					name  = entry.name or id,
					rarity = entry.rarity or "Common",
					image = entry.image,
				})
			end
		end
	end
	log(string.format("Findable crown pool: %d crowns", #_findableCrownPool))
	return _findableCrownPool
end

-- Rarity weights for spin wheel crown selection (grind-heavy tuning)
local CROWN_RARITY_WEIGHT = {
	Common    = 50,
	Rare      = 2,
	Epic      = 1,
	Legendary = 0,
}

local function weightedPickCrown(pool: { { id: string, name: string, rarity: string, image: string? } })
	local total = 0
	for _, entry in ipairs(pool) do
		total += (CROWN_RARITY_WEIGHT[entry.rarity] or 1)
	end
	if total <= 0 then return pool[math.random(1, #pool)] end
	local roll = math.random() * total
	local cumulative = 0
	for _, entry in ipairs(pool) do
		cumulative += (CROWN_RARITY_WEIGHT[entry.rarity] or 1)
		if roll <= cumulative then return entry end
	end
	return pool[#pool]
end

local function pickRandomFindableCrown(player: Player): (string, string, string, boolean, string?)
	local pool = getFindableCrownPool()
	if #pool == 0 then
		warn("[SpinWheel] Crown pool empty — using fallback crown_sparkle")
		return "crown_sparkle", "Sparkle Crown", "Common", false, "rbxassetid://137567080814300"
	end

	local IS = getInventoryService()

	for _ = 1, CROWN_MAX_REROLL do
		local pick = weightedPickCrown(pool)
		local owns = false
		if IS and type(IS.OwnsItem) == "function" then
			local ok, result = pcall(IS.OwnsItem, IS, player, "Crowns", pick.id)
			owns = ok and result
		end
		if not owns then
			return pick.id, pick.name, pick.rarity, false, pick.image
		end
	end

	local pick = weightedPickCrown(pool)
	local isDuplicate = false
	if IS and type(IS.OwnsItem) == "function" then
		local ok, result = pcall(IS.OwnsItem, IS, player, "Crowns", pick.id)
		isDuplicate = ok and result or false
	end
	return pick.id, pick.name, pick.rarity, isDuplicate, pick.image
end
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

local function isUnlimitedSpinsEnabled(): boolean
	return SpinWheelConfig.DEBUG_UNLIMITED_SPINS == true
end

local function grantPet(player: Player, catalogId: string)
	local GS = getGrantService()
	if GS and GS ~= false and type(GS.GrantItem) == "function" then
		local res = GS.GrantItem(player, "Pet", catalogId, "SpinWheel")
		if not res.success then
			error("GrantService Pet grant failed: " .. tostring(res.reason))
		end
		log(string.format("PET GRANTED via GrantService: %s → %s", player.Name, catalogId))
		return
	end
	error("GrantService unavailable for pet grant")
end

local function loadData(userId: number): { lastFreeSpinTime: number, purchasedSpins: number, dataVersion: number }
	local data = { lastFreeSpinTime = 0, purchasedSpins = NEW_PLAYER_STARTING_SPINS, dataVersion = DATA_VERSION }

	if spinDataStore then
		local ok, saved = pcall(function()
			return spinDataStore:GetAsync("SpinWheel_" .. tostring(userId))
		end)
		if ok and saved and type(saved) == "table" then
			data.lastFreeSpinTime = saved.lastFreeSpinTime or 0
			data.purchasedSpins = saved.purchasedSpins or 0

			local savedVersion = saved.dataVersion or 0
			if savedVersion < DATA_VERSION then
				local oldSpins = data.purchasedSpins
				data.purchasedSpins = NEW_PLAYER_STARTING_SPINS
				data.dataVersion = DATA_VERSION
				warn(string.format(
					"[SPIN_AUDIT] userId=%d MIGRATION v%d->v%d | spins %d -> %d (reset) | t=%d",
					userId, savedVersion, DATA_VERSION, oldSpins, NEW_PLAYER_STARTING_SPINS, os.time()
				))
			else
				data.dataVersion = savedVersion
			end
		else
			warn(string.format("[SPIN_AUDIT] userId=%d NEW_PLAYER starting spins=%d | t=%d",
				userId, NEW_PLAYER_STARTING_SPINS, os.time()))
		end
	end

	return data
end

local function saveData(userId: number, data: { lastFreeSpinTime: number, purchasedSpins: number, dataVersion: number? })
	if not spinDataStore then return end
	pcall(function()
		spinDataStore:SetAsync("SpinWheel_" .. tostring(userId), {
			lastFreeSpinTime = data.lastFreeSpinTime,
			purchasedSpins = data.purchasedSpins,
			dataVersion = data.dataVersion or DATA_VERSION,
		})
	end)
end

local function getRandomSegment(): number?
	local segments = SpinWheelConfig.Segments
	if not segments or #segments == 0 then
		warn("[SpinWheelService] Segments table is nil or empty!")
		return nil
	end
	local totalWeight = 0
	for _, seg in ipairs(segments) do
		totalWeight = totalWeight + (seg.weight or seg.chance or 1)
	end
	if totalWeight <= 0 then return 1 end
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

function SpinWheelService.Init()
	local pool = getFindableCrownPool()
	if #pool == 0 then
		warn("[SpinWheel] ERROR: Findable crown pool is EMPTY — check ReplicatedStorage.ItemModels.Crowns.Findable")
	else
		log(string.format("Findable crown pool ready (count=%d)", #pool))
		for _, entry in ipairs(pool) do
			log(string.format("  crown: %s (%s) image=%s", entry.name, entry.id, tostring(entry.image ~= "" and "yes" or "MISSING")))
		end
	end
	log("Initialized")
	if isUnlimitedSpinsEnabled() then
		log("DEBUG: Unlimited spins ENABLED")
	end
end

function SpinWheelService.OnPlayerJoined(player: Player)
	local data = loadData(player.UserId)
	playerCache[player.UserId] = data
	warn(string.format("[SPIN_AUDIT] player=%s userId=%d LOADED lastFreeSpin=%d purchasedSpins=%d ver=%d | t=%d",
		player.Name, player.UserId, data.lastFreeSpinTime, data.purchasedSpins, data.dataVersion, os.time()))
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
			nextFreeSpinAt = 0,
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
		nextFreeSpinAt = absoluteNextFree,
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

	warn(string.format("[SPIN_AUDIT] player=%s userId=%d SPIN_USED type=%s remainingPurchased=%d | t=%d",
		player.Name, userId, spinType, data.purchasedSpins, os.time()))

	local segIndex = getRandomSegment()
	local segment = segIndex and SpinWheelConfig.Segments[segIndex]

	if not segment then
		if spinType == "free" then
			data.lastFreeSpinTime = data.lastFreeSpinTime - SpinWheelConfig.FREE_SPIN_COOLDOWN
		elseif spinType == "purchased" then
			data.purchasedSpins = data.purchasedSpins + 1
		end
		spinInProgress[userId] = nil
		warn(string.format("[SpinWheelService] SPIN FAILED: segment %s is nil for %s — spin refunded",
			tostring(segIndex), player.Name))
		return { success = false, reason = "Spin failed — try again." }
	end

	local rewardType = segment.reward or "Coins"
	local rewardName = segment.name or "Unknown Reward"
	local coinsToAward = segment.amount or 0
	local catalogId = segment.catalogId
	local rarity = segment.rarity or "Common"
	local isDuplicate = false
	local resolvedWheelImage = nil

	local resolveOk, resolveErr = pcall(function()
		if rewardType == "Pet" and catalogId then
			local petInfo = ItemCatalog and ItemCatalog.GetPet and ItemCatalog.GetPet(catalogId)
			if petInfo then
				rewardName = petInfo.name .. " (" .. petInfo.rarity .. ")"
			end
		elseif rewardType == "Crown" then
			local crownId, crownName, crownRarity, crownIsDup, crownImage = pickRandomFindableCrown(player)
			if not crownId then
				error("pickRandomFindableCrown returned nil")
			end
			catalogId = crownId
			rewardName = crownName
			rarity = crownRarity
			isDuplicate = crownIsDup
			if crownImage and crownImage ~= "" then
				resolvedWheelImage = crownImage
			end
			if isDuplicate then
				coinsToAward = CROWN_DUPLICATE_COINS
			end
			log(string.format("[SpinWheel] Crown wedge -> selected=%s (%s) dup=%s image=%s",
				crownName, crownId, tostring(isDuplicate), tostring(resolvedWheelImage ~= nil)))
		end
	end)
	if not resolveOk then
		warn(string.format("[SpinWheelService] REWARD RESOLVE FAILED for %s: %s", player.Name, tostring(resolveErr)))
		if rewardType == "Crown" then
			if spinType == "free" then
				data.lastFreeSpinTime = data.lastFreeSpinTime - SpinWheelConfig.FREE_SPIN_COOLDOWN
			elseif spinType == "purchased" then
				data.purchasedSpins = data.purchasedSpins + 1
			end
			spinInProgress[userId] = nil
			warn(string.format("[SpinWheel] Crown wedge FAILED -> %s (spin NOT consumed)", tostring(resolveErr)))
			return { success = false, reason = "Reward failed to load \xe2\x80\x94 try again" }
		end
		rewardType = "Coins"
		rewardName = segment.name or "Coins"
		coinsToAward = math.max(segment.amount or 0, 100)
		catalogId = nil
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
		isDuplicate = isDuplicate,
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

		local rType = pending.rewardType or "Coins"
		local rCoins = pending.coinsAwarded or 0
		local rCatalog = pending.catalogId
		local rName = pending.rewardName or "Unknown"

		if type(rCoins) ~= "number" then rCoins = 0 end

		local grantOk, grantErr = pcall(function()
			if rType == "Pet" and rCatalog and rCatalog ~= "" then
				grantPet(livePlayer, rCatalog)
				log(string.format("GRANTED spinId=%s Pet %s to %s", spinId, rCatalog, livePlayer.Name))
			elseif rType == "Crown" and rCatalog and rCatalog ~= "" then
				if pending.isDuplicate then
					local GS = getGrantService()
					if GS and GS ~= false and type(GS.GrantItem) == "function" then
						local g = GS.GrantItem(livePlayer, "Currency", rCoins, "SpinWheel")
						if not g.success then
							error("SpinWheel duplicate crown coin grant failed: " .. tostring(g.reason))
						end
					else
						error("GrantService unavailable for duplicate coin grant")
					end
					log(string.format("GRANTED spinId=%s Crown %s DUPLICATE to %s → +%d coins",
						spinId, rCatalog, livePlayer.Name, rCoins))
				else
					local GS = getGrantService()
					if GS and GS ~= false and type(GS.GrantItem) == "function" then
						local g = GS.GrantItem(livePlayer, "Crown", rCatalog, "SpinWheel")
						if not g.success then
							error("SpinWheel crown grant failed: " .. tostring(g.reason))
						end
					else
						error("GrantService unavailable for crown grant")
					end
					log(string.format("GRANTED spinId=%s Crown %s to %s", spinId, rCatalog, livePlayer.Name))
				end
			else
				local GS = getGrantService()
				if GS and GS ~= false and type(GS.GrantItem) == "function" then
					local g = GS.GrantItem(livePlayer, "Currency", rCoins, "SpinWheel")
					if not g.success then
						error("SpinWheel coin grant failed: " .. tostring(g.reason))
					end
				else
					error("GrantService unavailable for coin grant")
				end
				log(string.format("GRANTED spinId=%s %s to %s (+%d coins)",
					spinId, rName, livePlayer.Name, rCoins))
			end
		end)

		if not grantOk then
			warn(string.format("[SpinWheelService] GRANT FAILED spinId=%s player=%s err=%s",
				spinId, livePlayer.Name, tostring(grantErr)))
		end

		spinInProgress[userId] = nil
	end)

	return {
		success = true,
		segmentIndex = segIndex,
		rewardName = rewardName,
		rewardType = rewardType,
		coinsAwarded = coinsToAward,
		baseCoins = coinsToAward,
		catalogId = catalogId,
		rarity = rarity,
		isDuplicate = isDuplicate,
		wheelImage = resolvedWheelImage or (segment and segment.wheelImage) or "",
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

	local oldSpins = data.purchasedSpins
	data.purchasedSpins = data.purchasedSpins + pkg.spins

	task.spawn(function() saveData(player.UserId, data) end)

	warn(string.format("[SPIN_AUDIT] player=%s userId=%d BUY_SPINS pkg=%d cost=%d +%d spins | %d -> %d | t=%d",
		player.Name, player.UserId, packageIndex, pkg.coins, pkg.spins,
		oldSpins, data.purchasedSpins, os.time()))

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

	local oldSpins = data.purchasedSpins
	data.purchasedSpins = data.purchasedSpins + spinsToAdd

	task.spawn(function() saveData(player.UserId, data) end)

	warn(string.format("[SPIN_AUDIT] player=%s userId=%d GRANT_SPINS +%d | %d -> %d | t=%d",
		player.Name, player.UserId, spinsToAdd, oldSpins, data.purchasedSpins, os.time()))

	return true
end

function SpinWheelService.SaveAll()
	for userId, data in pairs(playerCache) do
		saveData(userId, data)
	end
	log("All spin data saved")
end

return SpinWheelService
