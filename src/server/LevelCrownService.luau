--[[
	LevelCrownService
	Server-side wins-milestone crown granting.

	Checks player's LifetimeWins against ItemCatalog.LevelCrownMilestones
	and grants any earned but unowned crowns.

	Triggered:
	  • On player join (after data load) — catch up on missed milestones
	  • On wins increment — check if new milestone crossed

	API:
		Init()
		CheckMilestones(player) → { granted: { string } }
]]

local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared      = ReplicatedStorage:WaitForChild("Shared")
local Server      = ServerScriptService:WaitForChild("Server")
local ItemCatalog = require(Shared:WaitForChild("ItemCatalog"))

local LevelCrownService = {}
local initialized = false

-- ── Lazy loaders ──
local _InventoryService = nil
local _PlayerDataService = nil

local function getInventory()
	if _InventoryService then return _InventoryService end
	local ok, mod = pcall(require, Server:WaitForChild("InventoryService", 10))
	if ok and mod then _InventoryService = mod end
	return _InventoryService
end

local function getPDS()
	if _PlayerDataService then return _PlayerDataService end
	local ok, mod = pcall(require, Server:WaitForChild("PlayerDataService", 10))
	if ok and mod then _PlayerDataService = mod end
	return _PlayerDataService
end

local function log(...)
	print("[LevelCrownService]", ...)
end

-- ═══════════════════════════════════════════════════════════════════
-- MILESTONE CHECK
-- ═══════════════════════════════════════════════════════════════════

function LevelCrownService.CheckMilestones(player: Player): { granted: { string } }
	local granted = {}

	local pds = getPDS()
	if not pds or not pds.IsLoaded(player) then
		return { granted = granted }
	end

	local wins = pds.GetField(player, "LifetimeWins") or 0
	local inv = getInventory()
	if not inv then
		return { granted = granted }
	end

	for _, milestone in ipairs(ItemCatalog.LevelCrownMilestones) do
		if wins >= milestone.wins then
			if not inv.OwnsItem(player, "Crowns", milestone.crownId) then
				local success = inv.GrantItem(player, "Crowns", milestone.crownId)
				if success then
					table.insert(granted, milestone.crownId)
					local entry = ItemCatalog.Crowns[milestone.crownId]
					log(string.format("%s earned %s (%d wins milestone)",
						player.Name, entry and entry.name or milestone.crownId, milestone.wins))
				end
			end
		end
	end

	return { granted = granted }
end

-- ═══════════════════════════════════════════════════════════════════
-- INIT
-- ═══════════════════════════════════════════════════════════════════

function LevelCrownService.Init()
	if initialized then return end
	initialized = true
	log("Initialized")
end

return LevelCrownService
