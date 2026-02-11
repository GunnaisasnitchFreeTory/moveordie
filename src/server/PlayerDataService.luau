--[[
	PlayerDataService
	Server-authoritative persistent player data.

	Loads from DataStore on PlayerAdded, saves on PlayerRemoving and
	server shutdown.  In-memory cache for fast access.  Replicates key
	fields to client via player attributes.

	API:
		Init()
		LoadPlayer(player)        → data table
		SavePlayer(player)        → boolean
		UnloadPlayer(player)
		GetData(player)           → data table | nil
		IsLoaded(player)          → boolean
		SetField(player, key, v)  → boolean
		GetField(player, key)     → value
		SaveAll()
]]

local DataStoreService = game:GetService("DataStoreService")
local Players          = game:GetService("Players")
local HttpService      = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared     = ReplicatedStorage:WaitForChild("Shared")
local PlayerData = require(Shared:WaitForChild("PlayerData"))

local PlayerDataService = {}

local dataStore: DataStore? = nil
local playerCache: { [number]: { [string]: any } } = {}
local loadedPlayers: { [number]: boolean } = {}
local initialized = false

local DEBUG_LOG          = true
local RETRY_ATTEMPTS     = 3
local RETRY_DELAY        = 1
local AUTO_SAVE_INTERVAL = 300

local function log(...)
	if DEBUG_LOG then print("[PlayerDataService]", ...) end
end

-- ═══════════════════════════════════════════════════════════════════
-- ATTRIBUTE REPLICATION
-- ═══════════════════════════════════════════════════════════════════

local function replicateToClient(player: Player, data: { [string]: any })
	local A = PlayerData.Attributes

	player:SetAttribute(A.Coins,         data.Coins or 0)
	player:SetAttribute(A.LifetimeWins,  data.LifetimeWins or 0)
	player:SetAttribute(A.CoinMultiplier, 1)

	player:SetAttribute(A.LifetimeCoinsAchieved, data.LifetimeCoinsAchieved or 0)
	player:SetAttribute(A.WeeklyWins,             data.WeeklyWins or 0)
	player:SetAttribute(A.WeeklyCoinsAchieved,    data.WeeklyCoinsAchieved or 0)

	player:SetAttribute(A.EquippedPet,   data.EquippedPet or "")
	player:SetAttribute(A.EquippedCrown, data.EquippedCrown or "")
	player:SetAttribute(A.EquippedIcon,  data.EquippedIcon or "")

	player:SetAttribute(A.OwnedPets,   HttpService:JSONEncode(data.OwnedPets or {}))
	player:SetAttribute(A.OwnedCrowns, HttpService:JSONEncode(data.OwnedCrowns or {}))
	player:SetAttribute(A.OwnedIcons,  HttpService:JSONEncode(data.OwnedIcons or {}))
end

local function replicateField(player: Player, key: string, value: any)
	local A = PlayerData.Attributes

	if key == "Coins" then
		player:SetAttribute(A.Coins, value or 0)
	elseif key == "LifetimeWins" then
		player:SetAttribute(A.LifetimeWins, value or 0)
	elseif key == "LifetimeCoinsAchieved" then
		player:SetAttribute(A.LifetimeCoinsAchieved, value or 0)
	elseif key == "WeeklyWins" then
		player:SetAttribute(A.WeeklyWins, value or 0)
	elseif key == "WeeklyCoinsAchieved" then
		player:SetAttribute(A.WeeklyCoinsAchieved, value or 0)
	elseif key == "EquippedPet" then
		player:SetAttribute(A.EquippedPet, value or "")
	elseif key == "EquippedCrown" then
		player:SetAttribute(A.EquippedCrown, value or "")
	elseif key == "EquippedIcon" then
		player:SetAttribute(A.EquippedIcon, value or "")
	elseif key == "OwnedPets" then
		player:SetAttribute(A.OwnedPets, HttpService:JSONEncode(value or {}))
	elseif key == "OwnedCrowns" then
		player:SetAttribute(A.OwnedCrowns, HttpService:JSONEncode(value or {}))
	elseif key == "OwnedIcons" then
		player:SetAttribute(A.OwnedIcons, HttpService:JSONEncode(value or {}))
	end
end

-- ═══════════════════════════════════════════════════════════════════
-- DATASTORE OPERATIONS
-- ═══════════════════════════════════════════════════════════════════

local function getKey(userId: number): string
	return PlayerData.KEY_PREFIX .. tostring(userId)
end

local function loadFromStore(userId: number): { [string]: any }?
	if not dataStore then return nil end

	local key = getKey(userId)
	for attempt = 1, RETRY_ATTEMPTS do
		local ok, result = pcall(function()
			return dataStore:GetAsync(key)
		end)
		if ok then return result end
		warn(string.format("[PlayerDataService] Load attempt %d/%d failed for userId %d: %s",
			attempt, RETRY_ATTEMPTS, userId, tostring(result)))
		if attempt < RETRY_ATTEMPTS then task.wait(RETRY_DELAY) end
	end
	warn(string.format("[PlayerDataService] All load attempts failed for userId %d", userId))
	return nil
end

local function saveToStore(userId: number, data: { [string]: any }): boolean
	if not dataStore then return false end

	local key = getKey(userId)
	for attempt = 1, RETRY_ATTEMPTS do
		local ok, err = pcall(function()
			dataStore:SetAsync(key, data)
		end)
		if ok then return true end
		warn(string.format("[PlayerDataService] Save attempt %d/%d failed for userId %d: %s",
			attempt, RETRY_ATTEMPTS, userId, tostring(err)))
		if attempt < RETRY_ATTEMPTS then task.wait(RETRY_DELAY) end
	end
	warn(string.format("[PlayerDataService] All save attempts failed for userId %d", userId))
	return false
end

-- ═══════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ═══════════════════════════════════════════════════════════════════

function PlayerDataService.Init()
	if initialized then
		warn("[PlayerDataService] Already initialized")
		return
	end
	initialized = true

	local ok, store = pcall(function()
		return DataStoreService:GetDataStore(PlayerData.STORE_NAME)
	end)
	if ok then
		dataStore = store
		log("DataStore connected:", PlayerData.STORE_NAME)
	else
		warn("[PlayerDataService] DataStore unavailable:", tostring(store))
	end

	task.spawn(function()
		while true do
			task.wait(AUTO_SAVE_INTERVAL)
			PlayerDataService.SaveAll()
		end
	end)

	log("Initialized")
end

function PlayerDataService.LoadPlayer(player: Player): { [string]: any }
	local userId = player.UserId
	if playerCache[userId] then
		log(player.Name, "already loaded — returning cached data")
		return playerCache[userId]
	end

	local rawData = loadFromStore(userId)
	local data: { [string]: any }

	if rawData and type(rawData) == "table" then
		data = PlayerData.Validate(rawData)
		log(string.format("%s loaded from DataStore (Coins=%d Pets=%d Crowns=%d Wins=%d)",
			player.Name, data.Coins, #data.OwnedPets, #data.OwnedCrowns, data.LifetimeWins))
	else
		data = PlayerData.GetDefaults()
		log(string.format("%s — new player, using defaults", player.Name))
	end

	playerCache[userId]  = data
	loadedPlayers[userId] = true

	replicateToClient(player, data)
	return data
end

function PlayerDataService.SavePlayer(player: Player): boolean
	local userId = player.UserId
	local data = playerCache[userId]
	if not data then
		log(player.Name, "— no cached data to save")
		return false
	end
	local success = saveToStore(userId, data)
	if success then log(player.Name, "saved") end
	return success
end

function PlayerDataService.UnloadPlayer(player: Player)
	local userId = player.UserId
	playerCache[userId]   = nil
	loadedPlayers[userId] = nil
end

function PlayerDataService.GetData(player: Player): { [string]: any }?
	return playerCache[player.UserId]
end

function PlayerDataService.IsLoaded(player: Player): boolean
	return loadedPlayers[player.UserId] == true
end

function PlayerDataService.SetField(player: Player, key: string, value: any): boolean
	local data = playerCache[player.UserId]
	if not data then
		warn("[PlayerDataService] SetField failed — data not loaded for", player.Name)
		return false
	end
	data[key] = value
	replicateField(player, key, value)
	return true
end

function PlayerDataService.GetField(player: Player, key: string): any
	local data = playerCache[player.UserId]
	if not data then return nil end
	return data[key]
end

function PlayerDataService.SaveAll()
	local count = 0
	for userId, data in pairs(playerCache) do
		local success = saveToStore(userId, data)
		if success then count += 1 end
	end
	if count > 0 then
		log(string.format("Saved %d player(s)", count))
	end
end

return PlayerDataService
