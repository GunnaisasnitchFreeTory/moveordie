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

local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local InventoryService  = require(Server:WaitForChild("InventoryService"))
local StatService       = require(Server:WaitForChild("StatService"))
local CrateService      = require(Server:WaitForChild("CrateService"))
local LevelCrownService = require(Server:WaitForChild("LevelCrownService"))

local IS_STUDIO = RunService:IsStudio()

-- Initialize services
PlayerDataService.Init()
InventoryService.Init()
StatService.Init()
CrateService.Init()
LevelCrownService.Init()

-- ═══════════════════════════════════════════════════════════════════
-- LAZY-LOAD GLBS (avoid circular require; GLBS may not be init yet)
-- ═══════════════════════════════════════════════════════════════════
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

-- Helper: match GLBS isValidUserId logic — accept negative ids in Studio
local function isValidUserId(userId: number): boolean
	if type(userId) ~= "number" then return false end
	if userId == 0 then return false end
	if userId > 0 then return true end
	-- Negative userId: only valid in Studio (test players are -1, -2, etc.)
	return IS_STUDIO
end

-- ═══════════════════════════════════════════════════════════════════
-- REMOTE EVENTS FOR EQUIP / UNEQUIP
-- ═══════════════════════════════════════════════════════════════════

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
		warn("[PlayerDataBootstrap] Equip rejected — data not loaded for", player.Name)
		return
	end

	local result = InventoryService.EquipItem(player, category, id)
	if result.success then
		StatService.RecalculateStats(player)
	else
		warn(string.format("[PlayerDataBootstrap] Equip failed %s: %s/%s — %s",
			player.Name, category, id, result.reason or "unknown"))
	end
end)

unequipEvent.OnServerEvent:Connect(function(player, category)
	if type(category) ~= "string" then return end
	if not PlayerDataService.IsLoaded(player) then return end

	local result = InventoryService.UnequipItem(player, category)
	if result.success then
		StatService.RecalculateStats(player)
	end
end)

-- ═══════════════════════════════════════════════════════════════════
-- CRATE OPENING (RemoteFunction — client needs the result back)
-- ═══════════════════════════════════════════════════════════════════

openCrateFunc.OnServerInvoke = function(player, crateId, quantity)
	if not PlayerDataService.IsLoaded(player) then
		return { results = {}, success = false, error = "Data not loaded" }
	end

	local result = CrateService.OpenCrate(player, crateId, quantity)

	-- Notify client of inventory change so UIs refresh
	if result.success and #result.results > 0 then
		inventoryUpdate:FireClient(player, "CrateOpened", result.results)
	end

	return result
end

-- ═══════════════════════════════════════════════════════════════════
-- PLAYER LIFECYCLE
-- ═══════════════════════════════════════════════════════════════════

local function onPlayerAdded(player: Player)
	-- 1) Load persistent data
	local data = PlayerDataService.LoadPlayer(player)

	-- 2) Recalculate stats
	StatService.RecalculateStats(player)

	-- 3) Check level crown milestones (grant earned but unowned crowns)
	task.spawn(function()
		local milestoneResult = LevelCrownService.CheckMilestones(player)
		if milestoneResult.granted and #milestoneResult.granted > 0 then
			inventoryUpdate:FireClient(player, "LevelCrowns", milestoneResult.granted)
			StatService.RecalculateStats(player)
		end
	end)

	-- 4) Watch for future wins changes to grant new level crowns
	player:GetAttributeChangedSignal("LifetimeWins"):Connect(function()
		if not PlayerDataService.IsLoaded(player) then return end
		local milestoneResult = LevelCrownService.CheckMilestones(player)
		if milestoneResult.granted and #milestoneResult.granted > 0 then
			inventoryUpdate:FireClient(player, "LevelCrowns", milestoneResult.granted)
			StatService.RecalculateStats(player)
		end
	end)

	-- 5) Seed leaderboard with saved stats (non-blocking)
	-- FIX: Accept negative UserIds in Studio (test players are -1, -2, etc.)
	if data and isValidUserId(player.UserId) then
		task.spawn(function()
			-- Small delay: gives MatchBootstrap time to call GLBS.Init()
			-- so boardParts are populated and rendering works.
			task.wait(1.5)

			local GLBS = getGLBS()
			if GLBS and GLBS ~= false and type(GLBS.SeedPlayerBoardsFromSavedData) == "function" then
				warn(string.format("[PlayerDataBootstrap] Seeding leaderboard for %s (userId=%d, studio=%s)", player.Name, player.UserId, tostring(IS_STUDIO)))

				-- Ensure GLBS is initialized (idempotent — safe to call multiple times)
				if type(GLBS.Init) == "function" then
					pcall(GLBS.Init)
				end

				GLBS.SeedPlayerBoardsFromSavedData(player.UserId, data)

				-- Explicit RefreshAll after seeding so boards render immediately.
				-- The seed function already schedules one, but belt-and-suspenders:
				task.delay(3, function()
					if GLBS and type(GLBS.RefreshAll) == "function" then
						warn("[PlayerDataBootstrap] Post-seed RefreshAll for " .. player.Name)
						pcall(GLBS.RefreshAll)
					end
				end)
			else
				warn("[PlayerDataBootstrap] GLBS.SeedPlayerBoardsFromSavedData not available — skipping seed")
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

print("[PlayerDataBootstrap] Persistence + equip + crate + level crowns + leaderboard seed systems ready")
