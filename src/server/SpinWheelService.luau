--[[
	SpinWheelService
	Server-authoritative spin wheel logic.

	Responsibilities:
	  • Track per-player spin data (free spin timer, purchased spins)
	  • Validate spin requests
	  • Weighted RNG for reward selection (uses segment.weight)
	  • Award rewards AFTER spin animation completes (pending spin system)
	    – Coins → player "Coins" attribute
	    – Pets  → player "OwnedPets" attribute (JSON array of catalog IDs)
	  • Persist data via DataStore (with pcall fallback)
	  • Grant spins purchased via Robux (called from ProcessReceipt)

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

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SpinWheelConfig = require(Shared:WaitForChild("SpinWheelConfig"))
local ItemCatalog     = require(Shared:WaitForChild("ItemCatalog"))

local spinDataStore = nil
pcall(function()
	spinDataStore = DataStoreService:GetDataStore("SpinWheelData_v1")
end)

-- NOTE:
-- Server payout is deliberately delayed until the wheel finishes animating.
-- This must match the client wheel animation duration (currently `spinDuration = 11` in SpinWheelScript).
local SPIN_DURATION_SECONDS = 11

-- In-memory cache: [userId] → { lastFreeSpinTime: number, purchasedSpins: number }
local playerCache: { [number]: { lastFreeSpinTime: number, purchasedSpins: number } } = {}

-- Anti-spam: track players currently mid-spin
local spinInProgress: { [number]: boolean } = {}

-- Pending spins: [userId] → pending record
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
-- PET OWNERSHIP HELPERS
-- Pets are stored as a JSON array in player attribute "OwnedPets".
-- e.g. ["PUPPY_COMMON","CHICK_COMMON"]
-- ═══════════════════════════════════════════

local function getOwnedPets(player: Player): { string }
	local raw = player:GetAttribute("OwnedPets")
	if raw and type(raw) == "string" and raw ~= "" then
		local ok, list = pcall(function() return HttpService:JSONDecode(raw) end)
		if ok and type(list) == "table" then
			return list
		end
	end
	return {}
end

local function setOwnedPets(player: Player, list: { string })
	local json = HttpService:JSONEncode(list)
	player:SetAttribute("OwnedPets", json)
end

local function grantPet(player: Player, catalogId: string)
	local pets = getOwnedPets(player)
	-- Allow duplicates (player can win the same pet twice); if you
	-- prefer unique-only, add a check here.
	table.insert(pets, catalogId)
	setOwnedPets(player, pets)
	log(string.format("PET GRANTED: %s now owns %s (total pets: %d)", player.Name, catalogId, #pets))
end

-- Initialise a new player with default owned pets (matching UIConfig.MockPets owned=true)
local function ensureDefaultPets(player: Player)
	local pets = getOwnedPets(player)
	if #pets == 0 then
		-- Give starter pets so the Pets UI isn't empty on first login
		local starters = { "CHICK_COMMON", "PUPPY_COMMON" }
		setOwnedPets(player, starters)
		log(player.Name .. " received starter pets: " .. table.concat(starters, ", "))
	end
end

-- ═══════════════════════════════════════════
-- DATA PERSISTENCE
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
-- WEIGHTED RNG  (uses segment.weight)
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
	return 1 -- fallback
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
		log("DEBUG: Unlimited spins ENABLED (Studio or SpinWheelConfig.DEBUG_UNLIMITED_SPINS)")
	end
end

function SpinWheelService.OnPlayerJoined(player: Player)
	local data = loadData(player.UserId)
	playerCache[player.UserId] = data
	ensureDefaultPets(player)
	log(string.format("%s loaded — lastFreeSpin: %d, purchasedSpins: %d",
		player.Name, data.lastFreeSpinTime, data.purchasedSpins))
end

function SpinWheelService.OnPlayerLeaving(player: Player)
	local userId = player.UserId

	-- Cleanup pending spin so no delayed payout can occur after leaving
	clearPending(userId, "PlayerLeaving")

	local data = playerCache[userId]
	if data then
		saveData(userId, data)
		playerCache[userId] = nil
		spinInProgress[userId] = nil
		log(player.Name .. " data saved")
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
			purchasedSpins = data.purchasedSpins,
		}
	end

	local now = os.time()
	local elapsed = now - data.lastFreeSpinTime
	local freeAvailable = elapsed >= SpinWheelConfig.FREE_SPIN_COOLDOWN
	local nextFreeTime = freeAvailable and 0 or (data.lastFreeSpinTime + SpinWheelConfig.FREE_SPIN_COOLDOWN - now)

	log(string.format("Status for %s: freeReady=%s, nextFree=%ds, purchased=%d",
		player.Name, tostring(freeAvailable), math.max(0, nextFreeTime), data.purchasedSpins))

	return {
		freeSpinAvailable = freeAvailable,
		nextFreeSpinTime = math.max(0, nextFreeTime),
		purchasedSpins = data.purchasedSpins,
	}
end

function SpinWheelService.RequestSpin(player: Player)
	log(string.format("RequestSpin from %s — validating...", player.Name))

	local userId = player.UserId

	-- Anti-spam: prevent concurrent spins
	if spinInProgress[userId] then
		log(player.Name .. " — DENIED: spin already in progress")
		return { success = false, reason = "Spin already in progress" }
	end

	if pendingSpin[userId] then
		log(player.Name .. " — DENIED: pending spin exists")
		return { success = false, reason = "Spin already in progress" }
	end

	local data = playerCache[userId]
	if not data then
		log(player.Name .. " — DENIED: data not loaded")
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

	log(string.format("  %s — hasFree: %s (elapsed: %ds), hasPurchased: %s (%d)%s",
		player.Name, tostring(hasFree), now - data.lastFreeSpinTime, tostring(hasPurchased), data.purchasedSpins,
		debugUnlimited and " [DEBUG unlimited]" or ""))

	if not hasFree and not hasPurchased then
		log(player.Name .. " — DENIED: no spins available")
		return { success = false, reason = "No spins available" }
	end

	-- Mark spin in progress
	spinInProgress[userId] = true

	-- Consume spin
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

	-- RNG
	local segIndex = getRandomSegment()
	local segment = SpinWheelConfig.Segments[segIndex]
	local rewardType = segment.reward -- "Coins" or "Pet"
	local rewardName = segment.name
	local coinsToAward = segment.amount or 0
	local catalogId = segment.catalogId -- nil for Coins segments
	local rarity = segment.rarity or "Common"

	-- Build display-friendly reward name
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

	log(string.format(
		"APPROVED (PENDING) spinId=%s player=%s segment=%d (%s) rewardType=%s catalogId=%s amount=%d grantIn=%ds [%s spin]",
		spinId, player.Name, segIndex, rewardName, rewardType, tostring(catalogId), coinsToAward, SPIN_DURATION_SECONDS, spinType
	))

	-- Save
	if not debugUnlimited then
		task.spawn(function()
			saveData(userId, data)
		end)
	end

	-- Schedule server-side payout after the spin animation duration.
	task.delay(SPIN_DURATION_SECONDS, function()
		local pending = pendingSpin[userId]
		if not pending or pending.spinId ~= spinId then
			return
		end

		-- Remove pending first
		pendingSpin[userId] = nil

		local livePlayer = Players:GetPlayerByUserId(userId)
		if not livePlayer then
			spinInProgress[userId] = nil
			return
		end

		-- Grant reward based on type
		if pending.rewardType == "Pet" and pending.catalogId then
			-- Grant pet ownership
			grantPet(livePlayer, pending.catalogId)
			log(string.format(
				"GRANTED (AFTER SPIN) spinId=%s Pet=%s to %s",
				spinId, pending.catalogId, livePlayer.Name
			))
		else
			-- Grant coins
			local currentCoins = livePlayer:GetAttribute("Coins") or 0
			livePlayer:SetAttribute("Coins", currentCoins + pending.coinsAwarded)
			log(string.format(
				"GRANTED (AFTER SPIN) spinId=%s %s to %s (+%d Fate Coins, balance: %d → %d)",
				spinId, pending.rewardName, livePlayer.Name, pending.coinsAwarded, currentCoins, currentCoins + pending.coinsAwarded
			))
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

	-- Deduct Fate Coins
	local currentCoins = player:GetAttribute("Coins") or 0
	if currentCoins < pkg.coins then
		return { success = false, reason = "Not enough Fate Coins" }
	end

	player:SetAttribute("Coins", currentCoins - pkg.coins)
	data.purchasedSpins = data.purchasedSpins + pkg.spins

	task.spawn(function()
		saveData(player.UserId, data)
	end)

	log(string.format("Bought spins with coins: option=%d, cost=%d, spins=+%d, newPurchased=%d (player=%s)",
		packageIndex, pkg.coins, pkg.spins, data.purchasedSpins, player.Name))

	return {
		success = true,
		newSpinCount = data.purchasedSpins,
	}
end

--- Grant spins from a Robux Developer Product purchase.
--- Called by SpinWheelBootstrap's ProcessReceipt handler.
function SpinWheelService.GrantRobuxSpins(player: Player, spinsToAdd: number): boolean
	local data = playerCache[player.UserId]
	if not data then
		warn("[SpinWheelService] GrantRobuxSpins failed — no cached data for", player.Name)
		return false
	end

	data.purchasedSpins = data.purchasedSpins + spinsToAdd

	task.spawn(function()
		saveData(player.UserId, data)
	end)

	log(string.format("Robux purchase granted: spins=+%d, newPurchased=%d (player=%s)",
		spinsToAdd, data.purchasedSpins, player.Name))

	return true
end

function SpinWheelService.SaveAll()
	for userId, data in pairs(playerCache) do
		saveData(userId, data)
	end
	log("All player data saved")
end

return SpinWheelService
