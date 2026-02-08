--[[
	SpinWheelService
	Server-authoritative spin wheel logic.

	Responsibilities:
	  • Track per-player spin data (free spin timer, purchased spins)
	  • Validate spin requests
	  • Weighted RNG for reward selection
	  • Award rewards (Fate Coins via player attribute)
	  • Persist data via DataStore (with pcall fallback)

	API:
	  Init()
	  GetPlayerData(player) → { freeSpinAvailable, nextFreeSpinTime, purchasedSpins }
	  RequestSpin(player)   → { success, segmentIndex, rewardName, coinsAwarded } | { success=false, reason }
	  BuySpins(player, packageIndex) → { success, newSpinCount } | { success=false, reason }
	  SavePlayer(player)    → saves data to DataStore
]]

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SpinWheelConfig = require(Shared:WaitForChild("SpinWheelConfig"))

local spinDataStore = nil
pcall(function()
	spinDataStore = DataStoreService:GetDataStore("SpinWheelData_v1")
end)

-- In-memory cache: [userId] → { lastFreeSpinTime: number, purchasedSpins: number }
local playerCache: { [number]: { lastFreeSpinTime: number, purchasedSpins: number } } = {}

local SpinWheelService = {}

local function log(...)
	print("[SpinWheelService]", ...)
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
-- WEIGHTED RNG
-- ═══════════════════════════════════════════

local function getRandomSegment(): number
	local segments = SpinWheelConfig.Segments
	local totalWeight = 0
	for _, seg in ipairs(segments) do
		totalWeight = totalWeight + seg.chance
	end

	local roll = math.random() * totalWeight
	local cumulative = 0
	for i, seg in ipairs(segments) do
		cumulative = cumulative + seg.chance
		if roll <= cumulative then
			return i
		end
	end
	return 1 -- fallback
end

-- ═══════════════════════════════════════════
-- PUBLIC API
-- ═══════════════════════════════════════════

function SpinWheelService.Init()
	log("Initialized")
end

function SpinWheelService.OnPlayerJoined(player: Player)
	local data = loadData(player.UserId)
	playerCache[player.UserId] = data
	log(string.format("%s loaded — lastFreeSpin: %d, purchasedSpins: %d",
		player.Name, data.lastFreeSpinTime, data.purchasedSpins))
end

function SpinWheelService.OnPlayerLeaving(player: Player)
	local data = playerCache[player.UserId]
	if data then
		saveData(player.UserId, data)
		playerCache[player.UserId] = nil
		log(player.Name .. " data saved")
	end
end

function SpinWheelService.GetPlayerData(player: Player): { freeSpinAvailable: boolean, nextFreeSpinTime: number, purchasedSpins: number }
	local data = playerCache[player.UserId]
	if not data then
		data = loadData(player.UserId)
		playerCache[player.UserId] = data
	end

	local now = os.time()
	local elapsed = now - data.lastFreeSpinTime
	local freeAvailable = elapsed >= SpinWheelConfig.FREE_SPIN_COOLDOWN
	local nextFreeTime = freeAvailable and 0 or (data.lastFreeSpinTime + SpinWheelConfig.FREE_SPIN_COOLDOWN - now)

	return {
		freeSpinAvailable = freeAvailable,
		nextFreeSpinTime = math.max(0, nextFreeTime),
		purchasedSpins = data.purchasedSpins,
	}
end

function SpinWheelService.RequestSpin(player: Player): { success: boolean, segmentIndex: number?, rewardName: string?, coinsAwarded: number?, reason: string? }
	log(string.format("RequestSpin from %s — validating...", player.Name))

	local data = playerCache[player.UserId]
	if not data then
		log(player.Name .. " — DENIED: data not loaded")
		return { success = false, reason = "Data not loaded" }
	end

	-- Check availability
	local now = os.time()
	local hasFree = (now - data.lastFreeSpinTime) >= SpinWheelConfig.FREE_SPIN_COOLDOWN
	local hasPurchased = data.purchasedSpins > 0

	log(string.format("  %s — hasFree: %s (elapsed: %ds), hasPurchased: %s (%d)",
		player.Name, tostring(hasFree), now - data.lastFreeSpinTime, tostring(hasPurchased), data.purchasedSpins))

	if not hasFree and not hasPurchased then
		log(player.Name .. " — DENIED: no spins available")
		return { success = false, reason = "No spins available" }
	end

	-- Consume spin
	local spinType = "free"
	if hasFree then
		data.lastFreeSpinTime = now
	else
		data.purchasedSpins = data.purchasedSpins - 1
		spinType = "purchased"
	end

	-- RNG
	local segIndex = getRandomSegment()
	local segment = SpinWheelConfig.Segments[segIndex]
	local coinsToAward = segment.amount

	-- Award coins
	local currentCoins = player:GetAttribute("Coins") or 0
	player:SetAttribute("Coins", currentCoins + coinsToAward)

	-- Save
	task.spawn(function()
		saveData(player.UserId, data)
	end)

	log(string.format("  %s — APPROVED: segment %d (%s) → +%d coins (was %d, now %d) [%s spin]",
		player.Name, segIndex, segment.name, coinsToAward, currentCoins, currentCoins + coinsToAward, spinType))

	return {
		success = true,
		segmentIndex = segIndex,
		rewardName = segment.name,
		coinsAwarded = coinsToAward,
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

	log(string.format("%s bought %d spins for %d coins (total: %d)",
		player.Name, pkg.spins, pkg.coins, data.purchasedSpins))

	return {
		success = true,
		newSpinCount = data.purchasedSpins,
	}
end

function SpinWheelService.SaveAll()
	for userId, data in pairs(playerCache) do
		saveData(userId, data)
	end
	log("All player data saved")
end

return SpinWheelService

