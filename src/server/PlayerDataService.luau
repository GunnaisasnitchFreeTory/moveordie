--[[
	PlayerDataService
	Server-authoritative persistent player data.

	Loads from DataStore on PlayerAdded, saves on PlayerRemoving and
	server shutdown.  In-memory cache for fast access.  Replicates key
	fields to client via player attributes.

	API:
		Init()
		LoadPlayer(player)        -> data table
		SavePlayer(player)        -> boolean
		UnloadPlayer(player)
		GetData(player)           -> data table | nil
		IsLoaded(player)          -> boolean
		SetField(player, key, v)  -> boolean
		GetField(player, key)     -> value
		SaveAll()
]]

local DataStoreService  = game:GetService("DataStoreService")
local Players           = game:GetService("Players")
local HttpService       = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local IS_STUDIO = RunService:IsStudio()

local Shared     = ReplicatedStorage:WaitForChild("Shared")
local PlayerData = require(Shared:WaitForChild("PlayerData"))
local ItemCatalog = require(Shared:WaitForChild("ItemCatalog"))

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

local function listContainsString(listValue: any, needle: string): boolean
	if type(listValue) ~= "table" or type(needle) ~= "string" or needle == "" then
		return false
	end
	for _, entry in ipairs(listValue) do
		if entry == needle then
			return true
		end
	end
	return false
end

local function sanitizeEquippedCosmeticOwnership(data: { [string]: any }, playerName: string, context: string): boolean
	local changed = false

	local mappings = {
		{
			equippedKey = "EquippedPet",
			ownedKey = "OwnedPets",
			catalogCategory = "Pets",
		},
		{
			equippedKey = "EquippedCrown",
			ownedKey = "OwnedCrowns",
			catalogCategory = "Crowns",
		},
		{
			equippedKey = "EquippedIconImage",
			ownedKey = "OwnedIconImages",
			catalogCategory = "IconImages",
		},
	}

	for _, mapping in ipairs(mappings) do
		local equippedId = data[mapping.equippedKey]
		if type(equippedId) == "string" and equippedId ~= "" then
			local ownsEquipped = listContainsString(data[mapping.ownedKey], equippedId)
			local inCatalog = ItemCatalog.Get(mapping.catalogCategory, equippedId) ~= nil
			if not ownsEquipped or not inCatalog then
				data[mapping.equippedKey] = nil
				changed = true
				warn(string.format(
					"[PlayerDataService] Cleared invalid equipped item player=%s context=%s equippedKey=%s equippedId=%s owns=%s inCatalog=%s",
					playerName,
					context,
					mapping.equippedKey,
					equippedId,
					tostring(ownsEquipped),
					tostring(inCatalog)
				))
			end
		end
	end

	return changed
end

-- =====================================================================
-- ATTRIBUTE REPLICATION
-- =====================================================================

local function replicateToClient(player: Player, data: { [string]: any })
	local A = PlayerData.Attributes

	player:SetAttribute(A.Coins,         data.Coins or 0)
	player:SetAttribute(A.LifetimeWins,  data.LifetimeWins or 0)
	player:SetAttribute(A.CoinMultiplier, 1)
	player:SetAttribute(A.VIPBundleOwned, data.VIPBundleOwned == true)

	player:SetAttribute(A.LifetimeCoinsAchieved, data.LifetimeCoinsAchieved or 0)
	player:SetAttribute(A.WeeklyWins,             data.WeeklyWins or 0)
	player:SetAttribute(A.WeeklyCoinsAchieved,    data.WeeklyCoinsAchieved or 0)

	player:SetAttribute(A.EquippedPet,   data.EquippedPet or "")
	player:SetAttribute(A.EquippedCrown, data.EquippedCrown or "")
	player:SetAttribute(A.EquippedIcon,  data.EquippedIcon or "")

	player:SetAttribute(A.OwnedPets,   HttpService:JSONEncode(data.OwnedPets or {}))
	player:SetAttribute(A.OwnedCrowns, HttpService:JSONEncode(data.OwnedCrowns or {}))
	player:SetAttribute(A.OwnedIcons,  HttpService:JSONEncode(data.OwnedIcons or {}))

	player:SetAttribute(A.EquippedIconImage, data.EquippedIconImage or "")
	player:SetAttribute(A.OwnedIconImages,   HttpService:JSONEncode(data.OwnedIconImages or {}))
	player:SetAttribute(A.OwnedCrates,       HttpService:JSONEncode(data.OwnedCrates or {}))

	player:SetAttribute(A.LifetimeDeaths,    data.LifetimeDeaths or 0)
	player:SetAttribute(A.TimePlayedSeconds, data.TimePlayedSeconds or 0)
end

local function replicateField(player: Player, key: string, value: any)
	local A = PlayerData.Attributes

	if key == "Coins" then
		player:SetAttribute(A.Coins, value or 0)
	elseif key == "LifetimeWins" then
		player:SetAttribute(A.LifetimeWins, value or 0)
	elseif key == "VIPBundleOwned" then
		player:SetAttribute(A.VIPBundleOwned, value == true)
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
	elseif key == "EquippedIconImage" then
		player:SetAttribute(A.EquippedIconImage, value or "")
	elseif key == "OwnedIconImages" then
		player:SetAttribute(A.OwnedIconImages, HttpService:JSONEncode(value or {}))
	elseif key == "OwnedCrates" then
		player:SetAttribute(A.OwnedCrates, HttpService:JSONEncode(value or {}))
	elseif key == "LifetimeDeaths" then
		player:SetAttribute(A.LifetimeDeaths, value or 0)
	elseif key == "TimePlayedSeconds" then
		player:SetAttribute(A.TimePlayedSeconds, value or 0)
	end
end

-- =====================================================================
-- DATASTORE OPERATIONS
-- =====================================================================

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

-- =====================================================================
-- PUBLIC API
-- =====================================================================

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
		log(player.Name, "already loaded -- returning cached data")
		return playerCache[userId]
	end

	local rawData = loadFromStore(userId)
	local data: { [string]: any }

	if rawData and type(rawData) == "table" then
		data = PlayerData.Validate(rawData)
		sanitizeEquippedCosmeticOwnership(data, player.Name, "LoadPlayer")
		log(string.format("%s loaded from DataStore (Coins=%d Pets=%d Crowns=%d Wins=%d)",
			player.Name, data.Coins, #data.OwnedPets, #data.OwnedCrowns, data.LifetimeWins))
	else
		data = PlayerData.GetDefaults()
		log(string.format("%s -- new player, using defaults", player.Name))
	end

	playerCache[userId]  = data
	loadedPlayers[userId] = true

	replicateToClient(player, data)
	warn(string.format("[VIPPersistence] player=%s vipBundleOwned=%s loaded=true",
		player.Name, tostring(data.VIPBundleOwned == true)))
	return data
end

function PlayerDataService.SavePlayer(player: Player): boolean
	local userId = player.UserId
	local data = playerCache[userId]
	if not data then
		log(player.Name, "-- no cached data to save")
		return false
	end
	local success = saveToStore(userId, data)
	if success then
		log(player.Name, "saved")
		warn(string.format("[VIPPersistence] player=%s vipBundleOwned=%s saved=true",
			player.Name, tostring(data.VIPBundleOwned == true)))
	end
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
		warn("[PlayerDataService] SetField failed -- data not loaded for", player.Name)
		return false
	end
	data[key] = value
	if key == "VIPBundleOwned" then
		warn(string.format("[VIPPersistence] player=%s vipBundleOwned=%s saved=true",
			player.Name, tostring(value == true)))
	end
	local corrected = sanitizeEquippedCosmeticOwnership(data, player.Name, "SetField_" .. key)
	replicateField(player, key, data[key])
	if corrected then
		replicateField(player, "EquippedPet", data.EquippedPet)
		replicateField(player, "EquippedCrown", data.EquippedCrown)
		replicateField(player, "EquippedIconImage", data.EquippedIconImage)
	end
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
