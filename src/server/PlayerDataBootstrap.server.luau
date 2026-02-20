--[[
	PlayerDataBootstrap
	Initializes the persistence + equip + crate + level crown systems and wires player events.

	Runs once on server start. Must run EARLY (before MatchBootstrap).

	Systems initialized:
	  * PlayerDataService  (DataStore load / save)
	  * InventoryService   (equip / unequip validation)
	  * StatService         (stat calculation)
	  * CrateService        (crate opening logic)
	  * LevelCrownService   (wins milestone crown granting)
	  * RemoteEvents/Functions for client equip + crate actions
	  * Leaderboard seed-on-join (via GlobalLeaderboardService)
]]

local Players             = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local RunService          = game:GetService("RunService")

local Server = ServerScriptService:WaitForChild("Server")

local PlayerDataService   = require(Server:WaitForChild("PlayerDataService"))
local InventoryService    = require(Server:WaitForChild("InventoryService"))
local StatService         = require(Server:WaitForChild("StatService"))
local CrateService        = require(Server:WaitForChild("CrateService"))
local LevelCrownService   = require(Server:WaitForChild("LevelCrownService"))
local CrownAttachService  = require(Server:WaitForChild("CrownAttachService"))
local DailyRewardService  = require(Server:WaitForChild("DailyRewardService"))

local PlayerStateService  = require(Server:WaitForChild("PlayerStateService"))

local Shared      = ReplicatedStorage:WaitForChild("Shared")
local PlayerState = require(Shared:WaitForChild("PlayerState"))
local ItemCatalog = require(Shared:WaitForChild("ItemCatalog"))

local IS_STUDIO = RunService:IsStudio()

-- =====================================================================
-- BUILD_ID + SERVER IDENTITY  (visible in-game for version verification)
-- =====================================================================
local BUILD_ID = os.date("!%Y%m%d_%H%M", os.time())
local BUILD_LABEL = string.format("v%s | Place:%s | Game:%s",
	BUILD_ID, tostring(game.PlaceId), tostring(game.GameId))

warn("[BUILD] " .. BUILD_LABEL)

do
	local buildVal = ReplicatedStorage:FindFirstChild("BUILD_ID")
	if not buildVal then
		buildVal = Instance.new("StringValue")
		buildVal.Name = "BUILD_ID"
		buildVal.Parent = ReplicatedStorage
	end
	buildVal.Value = BUILD_LABEL
end

if ItemCatalog.ValidateAcquisitionLabels then
	ItemCatalog.ValidateAcquisitionLabels()
end

-- =====================================================================
-- STUDIO DEBUG: Grant all crowns + pets on join  (set to false to disable)
-- STUDIO_RESET_STATS: Reset ALL stats to 0 on join so testing starts fresh
-- =====================================================================
local STUDIO_GRANT_ALL   = IS_STUDIO
local STUDIO_RESET_STATS = IS_STUDIO

-- Initialize services
PlayerDataService.Init()
InventoryService.Init()
StatService.Init()
CrateService.Init()
LevelCrownService.Init()
CrownAttachService.Init()
DailyRewardService.Init()

-- =====================================================================
-- LAZY-LOAD GLBS (avoid circular require; GLBS may not be init yet)
-- =====================================================================
local _GLBS = nil
local function getGLBS()
	if _GLBS ~= nil then return _GLBS end
	local ok, mod = pcall(function()
		return require(Server:WaitForChild("GlobalLeaderboardService", 10))
	end)
	if ok and mod then
		_GLBS = mod
	else
		_GLBS = false
		warn("[PlayerDataBootstrap] GLBS not available:", tostring(mod))
	end
	return _GLBS
end

local function isValidUserId(userId: number): boolean
	if type(userId) ~= "number" then return false end
	if userId == 0 then return false end
	if userId > 0 then return true end
	return IS_STUDIO
end

-- =====================================================================
-- REMOTE EVENTS FOR EQUIP / UNEQUIP
-- =====================================================================

local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
if not remotesFolder then
	remotesFolder = Instance.new("Folder")
	remotesFolder.Name = "Remotes"
	remotesFolder.Parent = ReplicatedStorage
end

local function ensureRemote(name: string): RemoteEvent
	local event = remotesFolder:FindFirstChild(name)
	if not event then
		event = Instance.new("RemoteEvent")
		event.Name = name
		event.Parent = remotesFolder
	end
	return event
end

local function ensureRemoteFunction(name: string): RemoteFunction
	local func = remotesFolder:FindFirstChild(name)
	if not func then
		func = Instance.new("RemoteFunction")
		func.Name = name
		func.Parent = remotesFolder
	end
	return func
end

local equipEvent      = ensureRemote("EquipItem")
local unequipEvent    = ensureRemote("UnequipItem")
local inventoryUpdate = ensureRemote("InventoryUpdated")
local openCrateFunc   = ensureRemoteFunction("OpenCrate")

equipEvent.OnServerEvent:Connect(function(player, category, id)
	if type(category) ~= "string" or type(id) ~= "string" then return end
	if not PlayerDataService.IsLoaded(player) then
		warn("[PlayerDataBootstrap] Equip rejected -- data not loaded for", player.Name)
		return
	end

	local state = PlayerStateService.GetState(player)
	if state == PlayerState.States.InMatch then
		warn(string.format("[PlayerDataBootstrap] Equip rejected -- %s is InMatch (cannot change %s/%s)",
			player.Name, category, id))
		return
	end

	local result = InventoryService.EquipItem(player, category, id)
	if result.success then
		StatService.RecalculateStats(player)
	else
		warn(string.format("[PlayerDataBootstrap] Equip failed %s: %s/%s -- %s",
			player.Name, category, id, result.reason or "unknown"))
	end
end)

unequipEvent.OnServerEvent:Connect(function(player, category)
	if type(category) ~= "string" then return end
	if not PlayerDataService.IsLoaded(player) then return end

	local state = PlayerStateService.GetState(player)
	if state == PlayerState.States.InMatch then
		warn(string.format("[PlayerDataBootstrap] Unequip rejected -- %s is InMatch (cannot change %s)",
			player.Name, category))
		return
	end

	local result = InventoryService.UnequipItem(player, category)
	if result.success then
		StatService.RecalculateStats(player)
	end
end)

-- =====================================================================
-- CRATE OPENING (RemoteFunction -- client needs the result back)
-- =====================================================================

openCrateFunc.OnServerInvoke = function(player, crateId, quantity)
	if not PlayerDataService.IsLoaded(player) then
		return { results = {}, success = false, error = "Data not loaded" }
	end

	local result = CrateService.OpenCrate(player, crateId, quantity)

	if result.success and #result.results > 0 then
		inventoryUpdate:FireClient(player, "CrateOpened", result.results)
	end

	return result
end

-- =====================================================================
-- PLAYER LIFECYCLE
-- =====================================================================

local function onPlayerAdded(player: Player)
	local data = PlayerDataService.LoadPlayer(player)

	if STUDIO_GRANT_ALL and data then
		local granted = 0
		if ItemCatalog.Crowns then
			for crownId, _ in pairs(ItemCatalog.Crowns) do
				if not InventoryService.OwnsItem(player, "Crowns", crownId) then
					InventoryService.GrantItem(player, "Crowns", crownId)
					granted += 1
				end
			end
		end
		if ItemCatalog.Pets then
			for petId, _ in pairs(ItemCatalog.Pets) do
				if not InventoryService.OwnsItem(player, "Pets", petId) then
					InventoryService.GrantItem(player, "Pets", petId)
					granted += 1
				end
			end
		end
		if ItemCatalog.IconImages then
			for iconId, _ in pairs(ItemCatalog.IconImages) do
				if not InventoryService.OwnsItem(player, "IconImages", iconId) then
					InventoryService.GrantItem(player, "IconImages", iconId)
					granted += 1
				end
			end
		end
		if (data.Coins or 0) < 50000 then
			data.Coins = 50000
			PlayerDataService.SetField(player, "Coins", 50000)
		end
		PlayerDataService.SetField(player, "LastDailyRewardTime", 0)
		PlayerDataService.SetField(player, "DailyStreak", 0)
		print("[DEBUG] Daily rewards RESET for", player.Name, "(Studio testing)")

		if granted > 0 then
			print(string.format("[DEBUG] Granted %d items to %s (Studio grant-all)", granted, player.Name))
		end
	end

	if STUDIO_RESET_STATS and data then
		local statsToZero = {
			"LifetimeWins", "WeeklyWins", "LifetimeCoinsAchieved",
			"WeeklyCoinsAchieved", "LifetimeDeaths", "TimePlayedSeconds",
		}
		for _, key in ipairs(statsToZero) do
			data[key] = 0
			PlayerDataService.SetField(player, key, 0)
		end
		data.Coins = 0
		PlayerDataService.SetField(player, "Coins", 0)
		data.OwnedCrowns = {}
		PlayerDataService.SetField(player, "OwnedCrowns", {})
		data.EquippedCrown = nil
		PlayerDataService.SetField(player, "EquippedCrown", nil)
		data.OwnedPets = {}
		PlayerDataService.SetField(player, "OwnedPets", {})
		data.EquippedPet = nil
		PlayerDataService.SetField(player, "EquippedPet", nil)
		data.OwnedIcons = {}
		PlayerDataService.SetField(player, "OwnedIcons", {})
		data.EquippedIcon = nil
		PlayerDataService.SetField(player, "EquippedIcon", nil)
		data.OwnedIconImages = {}
		PlayerDataService.SetField(player, "OwnedIconImages", {})
		data.EquippedIconImage = nil
		PlayerDataService.SetField(player, "EquippedIconImage", nil)
		data.LastDailyRewardTime = 0
		PlayerDataService.SetField(player, "LastDailyRewardTime", 0)
		data.DailyStreak = 0
		PlayerDataService.SetField(player, "DailyStreak", 0)
		print(string.format("[DEBUG] All stats RESET to 0 for %s (Studio clean testing)", player.Name))
	end

	StatService.RecalculateStats(player)

	task.spawn(function()
		local milestoneResult = LevelCrownService.CheckMilestones(player)
		if milestoneResult.granted and #milestoneResult.granted > 0 then
			inventoryUpdate:FireClient(player, "LevelCrowns", milestoneResult.granted)
			StatService.RecalculateStats(player)
		end
	end)

	player:GetAttributeChangedSignal("LifetimeWins"):Connect(function()
		if not PlayerDataService.IsLoaded(player) then return end
		local milestoneResult = LevelCrownService.CheckMilestones(player)
		if milestoneResult.granted and #milestoneResult.granted > 0 then
			inventoryUpdate:FireClient(player, "LevelCrowns", milestoneResult.granted)
			StatService.RecalculateStats(player)
		end
	end)

	if data and isValidUserId(player.UserId) then
		task.spawn(function()
			task.wait(1.5)

			local GLBS = getGLBS()
			if GLBS and GLBS ~= false and type(GLBS.SeedPlayerBoardsFromSavedData) == "function" then
				warn(string.format("[PlayerDataBootstrap] Seeding leaderboard for %s (userId=%d, studio=%s)", player.Name, player.UserId, tostring(IS_STUDIO)))

				if type(GLBS.Init) == "function" then
					pcall(GLBS.Init)
				end

				GLBS.SeedPlayerBoardsFromSavedData(player.UserId, data)

				task.delay(3, function()
					if GLBS and type(GLBS.RefreshAll) == "function" then
						warn("[PlayerDataBootstrap] Post-seed RefreshAll for " .. player.Name)
						pcall(GLBS.RefreshAll)
					end
				end)
			else
				warn("[PlayerDataBootstrap] GLBS.SeedPlayerBoardsFromSavedData not available -- skipping seed")
			end
		end)
	end

	player.CharacterAdded:Connect(function()
		task.wait(0.1)
		StatService.RecalculateStats(player)
	end)
end

local function onPlayerRemoving(player: Player)
	PlayerDataService.SavePlayer(player)
	StatService.OnPlayerRemoving(player)
	PlayerDataService.UnloadPlayer(player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(function()
		onPlayerAdded(player)
	end)
end

game:BindToClose(function()
	PlayerDataService.SaveAll()
end)

-- =====================================================================
-- TIME PLAYED TRACKING
-- =====================================================================
task.spawn(function()
	while true do
		task.wait(1)
		for _, player in ipairs(Players:GetPlayers()) do
			if PlayerDataService.IsLoaded(player) then
				local secs = (PlayerDataService.GetField(player, "TimePlayedSeconds") or 0) + 1
				PlayerDataService.SetField(player, "TimePlayedSeconds", secs)
			end
		end
	end
end)

-- =====================================================================
-- CREATOR-ONLY ADMIN COMMANDS (works in both Studio + Live)
--   !wipe             -- wipe own profile + own leaderboard entries
--   !wipeid <userId>  -- wipe a specific userId (profile + boards)
--   !wipeall          -- wipe ALL profiles on server + clear ALL boards
--   !boards           -- dump full leaderboard state for debugging
--   !setcoins <n>     -- set own coins
--   !shutdown          -- kick all + save
--   !purge             -- remove negative userId entries from ODS
--   !season            -- show current leaderboard season
--   !buildid           -- show build + season info
-- =====================================================================
local CREATOR_ID = game.CreatorId

local function isCreator(player: Player): boolean
	if game.CreatorType == Enum.CreatorType.User then
		return player.UserId == CREATOR_ID
	end
	return player:GetRankInGroup(CREATOR_ID) >= 255
end

local function wipePlayerProfile(targetPlayer: Player)
	local defaults = require(Shared:WaitForChild("PlayerData")).GetDefaults()
	for key, val in pairs(defaults) do
		PlayerDataService.SetField(targetPlayer, key, val)
	end
	PlayerDataService.SavePlayer(targetPlayer)
	StatService.RecalculateStats(targetPlayer)
end

local function wipeOfflineUserId(targetId: number)
	local DataStoreService = game:GetService("DataStoreService")
	local PlayerDataModule = require(Shared:WaitForChild("PlayerData"))
	local storeName = PlayerDataModule.STORE_NAME
	local key = PlayerDataModule.KEY_PREFIX .. tostring(targetId)
	local defaults = PlayerDataModule.GetDefaults()

	local ok, err = pcall(function()
		local store = DataStoreService:GetDataStore(storeName)
		store:SetAsync(key, defaults)
	end)
	if ok then
		warn(string.format("[ADMIN] Wiped offline userId=%d DataStore (%s / %s)", targetId, storeName, key))
	else
		warn(string.format("[ADMIN] FAILED to wipe offline userId=%d: %s", targetId, tostring(err)))
	end
	return ok
end

local function removeFromLeaderboards(targetId: number)
	local GLBS = getGLBS()
	if GLBS and GLBS ~= false then
		if type(GLBS.RemovePlayerEntries) == "function" then
			GLBS.RemovePlayerEntries(targetId)
			warn(string.format("[ADMIN] Leaderboard entries removed for userId=%d", targetId))
		else
			warn("[ADMIN] GLBS.RemovePlayerEntries not available!")
		end
		if type(GLBS.ClearSeedFlag) == "function" then
			GLBS.ClearSeedFlag(targetId)
		end
	else
		warn("[ADMIN] GLBS not loaded — cannot remove leaderboard entries")
	end
end

local function handleAdminCommand(player: Player, message: string)
	if not isCreator(player) then return end
	local args = string.split(string.lower(message), " ")
	local cmd = args[1]

	if cmd == "!wipe" then
		wipePlayerProfile(player)
		warn(string.format("[ADMIN] %s (userId=%d) wiped OWN profile — defaults restored, saved", player.Name, player.UserId))
		removeFromLeaderboards(player.UserId)
		warn(string.format("[ADMIN] !wipe affects only YOUR userId=%d. Use !wipeid <id> for alts, or !wipeall to nuke everything.", player.UserId))

	elseif cmd == "!wipeid" then
		local targetId = tonumber(args[2])
		if not targetId then
			warn("[ADMIN] Usage: !wipeid <userId>")
			return
		end
		targetId = math.floor(targetId)
		warn(string.format("[ADMIN] %s requested wipe of userId=%d", player.Name, targetId))

		local targetPlayer = nil
		for _, p in ipairs(Players:GetPlayers()) do
			if p.UserId == targetId then
				targetPlayer = p
				break
			end
		end

		if targetPlayer then
			wipePlayerProfile(targetPlayer)
			warn(string.format("[ADMIN] Wiped in-server player %s (userId=%d)", targetPlayer.Name, targetId))
		else
			wipeOfflineUserId(targetId)
		end

		removeFromLeaderboards(targetId)

	elseif cmd == "!wipeall" then
		warn(string.format("[ADMIN] %s requested FULL WIPE — all profiles + all boards", player.Name))

		for _, p in ipairs(Players:GetPlayers()) do
			if PlayerDataService.IsLoaded(p) then
				wipePlayerProfile(p)
				warn(string.format("[ADMIN] Wiped profile: %s (userId=%d)", p.Name, p.UserId))
			end
		end

		local GLBS = getGLBS()
		if GLBS and GLBS ~= false then
			if type(GLBS.ClearAllBoards) == "function" then
				GLBS.ClearAllBoards()
				warn("[ADMIN] All leaderboard boards CLEARED + refreshed")
			else
				for _, p in ipairs(Players:GetPlayers()) do
					removeFromLeaderboards(p.UserId)
				end
			end
		end

	elseif cmd == "!boards" then
		warn(string.format("[ADMIN] %s requested board state dump", player.Name))
		local GLBS = getGLBS()
		if GLBS and GLBS ~= false and type(GLBS.DumpBoardState) == "function" then
			GLBS.DumpBoardState()
		else
			warn("[ADMIN] GLBS.DumpBoardState not available")
		end

	elseif cmd == "!setcoins" then
		local amount = tonumber(args[2])
		if not amount then return end
		amount = math.clamp(math.floor(amount), 0, 9999999)
		PlayerDataService.SetField(player, "Coins", amount)
		warn(string.format("[ADMIN] %s set coins to %d", player.Name, amount))

	elseif cmd == "!shutdown" then
		warn(string.format("[ADMIN] %s requested server shutdown", player.Name))
		task.defer(function()
			for _, p in ipairs(Players:GetPlayers()) do
				p:Kick("Server restarting -- please rejoin for the latest version.")
			end
			task.wait(1)
			PlayerDataService.SaveAll()
		end)

	elseif cmd == "!purge" then
		warn(string.format("[ADMIN] %s requested test entry purge", player.Name))
		task.spawn(function()
			local GLBS = getGLBS()
			if GLBS and GLBS ~= false and type(GLBS.PurgeTestEntries) == "function" then
				GLBS.PurgeTestEntries()
			end
		end)

	elseif cmd == "!season" then
		local GLBS = getGLBS()
		local season = (GLBS and GLBS ~= false and GLBS.SEASON) or "?"
		warn(string.format("[ADMIN] Leaderboard season: %s  (bump LEADERBOARD_SEASON in GlobalLeaderboardService to reset all boards)", season))

	elseif cmd == "!buildid" then
		local GLBS = getGLBS()
		local season = (GLBS and GLBS ~= false and GLBS.SEASON) or "?"
		warn(string.format("[ADMIN] BUILD_ID for %s: %s  SEASON=%s", player.Name, BUILD_LABEL, season))
	end
end

Players.PlayerAdded:Connect(function(player)
	player.Chatted:Connect(function(msg)
		if string.sub(msg, 1, 1) == "!" then
			handleAdminCommand(player, msg)
		end
	end)
end)
for _, player in ipairs(Players:GetPlayers()) do
	player.Chatted:Connect(function(msg)
		if string.sub(msg, 1, 1) == "!" then
			handleAdminCommand(player, msg)
		end
	end)
end

print("[PlayerDataBootstrap] Persistence + equip + crate + level crowns + daily rewards + leaderboard seed + stats tracking + admin commands ready")
