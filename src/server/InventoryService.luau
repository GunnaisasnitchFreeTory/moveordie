--[[
	InventoryService
	Server-side ownership + equip / unequip for pets, crowns, and icons.

	All actions validated against:
	  • PlayerDataService (ownership data)
	  • ItemCatalog (item existence)

	Leaderboard updates sent via DIRECT MODULE CALL to
	GlobalLeaderboardService.ReportStatById() — no BindableEvent.

	API:
		Init()
		OwnsItem(player, category, id)        → boolean
		GrantItem(player, category, id)        → boolean
		EquipItem(player, category, id)        → { success, reason? }
		UnequipItem(player, category)          → { success, reason? }
		GetEquipped(player, category)          → string?
]]

local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Server = ServerScriptService:WaitForChild("Server")

local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))

local ItemCatalogModule = Shared:WaitForChild("ItemCatalog", 10)
local ItemCatalog
if ItemCatalogModule then
	local ok, mod = pcall(require, ItemCatalogModule)
	if ok then ItemCatalog = mod else warn("[InventoryService] ItemCatalog failed:", mod) end
end
if not ItemCatalog then
	warn("[InventoryService] ItemCatalog not found — equip validation limited")
	ItemCatalog = { Get = function() return nil end }
end

local InventoryService = {}
local initialized = false

local DEBUG_LOG = true
local function log(...)
	if DEBUG_LOG then print("[InventoryService]", ...) end
end

-- ── GLBS direct call (lazy require, no BindableEvent) ──
local _GLBS = nil
local function getGLBS()
	if _GLBS ~= nil then return _GLBS end
	local ok, mod = pcall(function()
		return require(Server:WaitForChild("GlobalLeaderboardService", 10))
	end)
	if ok and mod then
		_GLBS = mod
		warn("[InventoryService] GLBS loaded via direct require")
	else
		_GLBS = false
		warn("[InventoryService] GLBS not available:", tostring(mod))
	end
	return _GLBS
end

local function reportStats(userId: number, username: string, updates: { [string]: number })
	local GLBS = getGLBS()
	if not GLBS or GLBS == false then return end

	for statKey, value in pairs(updates) do
		local callOk, callErr = pcall(function()
			GLBS.ReportStatById(userId, statKey, value)
		end)
		if callOk then
			log(string.format("DIRECT CALL OK: ReportStatById(%d, '%s', %d)", userId, statKey, value))
		else
			warn(string.format("[InventoryService] DIRECT CALL FAILED: ReportStatById(%d, '%s', %d) err=%s",
				userId, statKey, value, tostring(callErr)))
		end
	end
end

local CATEGORY_MAP = {
	Pets       = { ownedKey = "OwnedPets",       equippedKey = "EquippedPet",       catalogCategory = "Pets"       },
	Crowns     = { ownedKey = "OwnedCrowns",     equippedKey = "EquippedCrown",     catalogCategory = "Crowns"     },
	Icons      = { ownedKey = "OwnedIcons",      equippedKey = "EquippedIcon",      catalogCategory = "Icons"      },
	IconImages = { ownedKey = "OwnedIconImages", equippedKey = "EquippedIconImage", catalogCategory = "IconImages" },
}

function InventoryService.Init()
	if initialized then return end
	initialized = true

	-- Pre-warm GLBS reference (non-blocking)
	task.spawn(function()
		getGLBS()
	end)

	log("Initialized (leaderboard updates via direct GLBS calls)")
end

function InventoryService.OwnsItem(player: Player, category: string, id: string): boolean
	local mapping = CATEGORY_MAP[category]
	if not mapping then return false end

	local data = PlayerDataService.GetData(player)
	if not data then return false end

	local ownedList = data[mapping.ownedKey]
	if not ownedList then return false end

	for _, ownedId in ipairs(ownedList) do
		if ownedId == id then return true end
	end
	return false
end

function InventoryService.GrantItem(player: Player, category: string, id: string): boolean
	local mapping = CATEGORY_MAP[category]
	if not mapping then
		warn("[InventoryService] Invalid category:", category)
		return false
	end

	local catalogEntry = ItemCatalog.Get(mapping.catalogCategory, id)
	if not catalogEntry then
		warn(string.format("[InventoryService] Item not in catalog: %s/%s", category, id))
		return false
	end

	local data = PlayerDataService.GetData(player)
	if not data then
		warn("[InventoryService] Data not loaded for", player.Name)
		return false
	end

	local ownedList = data[mapping.ownedKey]
	if not ownedList then
		ownedList = {}
		data[mapping.ownedKey] = ownedList
	end

	for _, ownedId in ipairs(ownedList) do
		if ownedId == id then
			log(string.format("%s already owns %s/%s", player.Name, category, id))
			return true
		end
	end
	if category == "Pets" then
		table.insert(ownedList, id)
	else
		table.insert(ownedList, id)
	end

	PlayerDataService.SetField(player, mapping.ownedKey, ownedList)
	log(string.format("GRANTED %s/%s to %s (total %d)", category, id, player.Name, #ownedList))

	-- Report CrownsFound to global leaderboard via direct call
	if category == "Crowns" then
		reportStats(player.UserId, player.Name, {
			CrownsFound = #ownedList,
		})
	end

	return true
end

function InventoryService.EquipItem(player: Player, category: string, id: string): { success: boolean, reason: string? }
	local mapping = CATEGORY_MAP[category]
	if not mapping then
		return { success = false, reason = "Invalid category" }
	end

	if not InventoryService.OwnsItem(player, category, id) then
		return { success = false, reason = "Item not owned" }
	end

	local catalogEntry = ItemCatalog.Get(mapping.catalogCategory, id)
	if not catalogEntry then
		return { success = false, reason = "Item not in catalog" }
	end

	PlayerDataService.SetField(player, mapping.equippedKey, id)
	log(string.format("%s equipped %s/%s", player.Name, category, id))
	return { success = true }
end

function InventoryService.UnequipItem(player: Player, category: string): { success: boolean, reason: string? }
	local mapping = CATEGORY_MAP[category]
	if not mapping then
		return { success = false, reason = "Invalid category" }
	end

	PlayerDataService.SetField(player, mapping.equippedKey, nil)
	log(string.format("%s unequipped %s", player.Name, category))
	return { success = true }
end

function InventoryService.GetEquipped(player: Player, category: string): string?
	local mapping = CATEGORY_MAP[category]
	if not mapping then return nil end
	return PlayerDataService.GetField(player, mapping.equippedKey)
end

return InventoryService