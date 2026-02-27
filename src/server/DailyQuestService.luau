--[[
	DailyQuestService
	Server-authoritative daily quest tracking and reward granting.

	Quests reset at UTC midnight. Progress stored in PlayerData.DailyQuestData
	as a JSON string: { day="YYYY_MM_DD", progress={[questId]={progress,claimed}} }

	API:
	  Init()
	  OnPlayerWon(player)           -- called when a player wins a match
	  OnSwordKill(player)           -- called when a player kills with sword
	  OnTTSSurvive(player)          -- called when TTS despawns (timer) and player is alive
	  GetStatus(player)             -- returns quest list with progress
	  TryClaim(player, questId)     -- attempts to grant reward for completed quest
]]

local HttpService       = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players           = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Server = ServerScriptService:WaitForChild("Server")

local DailyQuestConfig = require(Shared:WaitForChild("DailyQuestConfig"))
local PlayerState      = require(Shared:WaitForChild("PlayerState"))

local _PDS, _Economy, _Inventory, _PSS = nil, nil, nil, nil

local function getPDS()
	if _PDS then return _PDS end
	local ok, mod = pcall(require, Server:WaitForChild("PlayerDataService", 5))
	if ok and mod then _PDS = mod end
	return _PDS
end
local function getEconomy()
	if _Economy then return _Economy end
	local ok, mod = pcall(require, Server:WaitForChild("EconomyService", 5))
	if ok and mod then _Economy = mod end
	return _Economy
end
local function getInventory()
	if _Inventory then return _Inventory end
	local ok, mod = pcall(require, Server:WaitForChild("InventoryService", 5))
	if ok and mod then _Inventory = mod end
	return _Inventory
end
local function getPSS()
	if _PSS then return _PSS end
	local ok, mod = pcall(require, Server:WaitForChild("PlayerStateService", 5))
	if ok and mod then _PSS = mod end
	return _PSS
end

local DailyQuestService = {}
local initialized = false

local updateRemote: RemoteEvent?   = nil
local getStatusFunc: RemoteFunction? = nil
local claimFunc: RemoteFunction?   = nil

local function log(...) print("[DailyQuestService]", ...) end

-- ── DATA HELPERS ──────────────────────────────────────────────────────────────

local function getCurrentDay(): string
	return os.date("!%Y_%m_%d")
end

local function getQuestData(player: Player): { day: string, progress: { [string]: { progress: number, claimed: boolean } } }
	local PDS = getPDS()
	local raw = PDS and PDS.GetField(player, "DailyQuestData") or ""
	if raw and raw ~= "" then
		local ok, decoded = pcall(function() return HttpService:JSONDecode(raw) end)
		if ok and type(decoded) == "table" then return decoded end
	end
	return { day = "", progress = {} }
end

local function saveQuestData(player: Player, data: { [string]: any })
	local PDS = getPDS()
	if not PDS then return end
	local ok, encoded = pcall(function() return HttpService:JSONEncode(data) end)
	if ok then PDS.SetField(player, "DailyQuestData", encoded) end
end

-- Ensure quest data is initialised for today; resets at UTC midnight.
local function ensureQuestData(player: Player): { [string]: any }
	local data = getQuestData(player)
	local today = getCurrentDay()
	if data.day ~= today then
		data.day = today
		data.progress = {}
		for questId, _ in pairs(DailyQuestConfig.Quests) do
			data.progress[questId] = { progress = 0, claimed = false }
		end
		saveQuestData(player, data)
	end
	-- Backfill any new quests added after existing data was written
	if type(data.progress) ~= "table" then data.progress = {} end
	for questId, _ in pairs(DailyQuestConfig.Quests) do
		if not data.progress[questId] then
			data.progress[questId] = { progress = 0, claimed = false }
		end
	end
	return data
end

-- ── STATUS BUILDER ────────────────────────────────────────────────────────────

function DailyQuestService.GetStatus(player: Player)
	local PDS = getPDS()
	if not PDS or not PDS.IsLoaded(player) then
		return { dataLoaded = false, quests = {} }
	end

	local data = ensureQuestData(player)
	local timePlayed = PDS.GetField(player, "TimePlayedSeconds") or 0

	-- Sort quests by order
	local sorted = {}
	for questId, questDef in pairs(DailyQuestConfig.Quests) do
		table.insert(sorted, { id = questId, def = questDef })
	end
	table.sort(sorted, function(a, b) return (a.def.order or 99) < (b.def.order or 99) end)

	local questList = {}
	for _, entry in ipairs(sorted) do
		local questId  = entry.id
		local questDef = entry.def
		local p = data.progress[questId] or { progress = 0, claimed = false }

		local progress = p.progress
		if questDef.type == "TimePlayed" then
			progress = math.min(timePlayed, questDef.target)
		end

		table.insert(questList, {
			id          = questId,
			label       = questDef.label,
			description = questDef.description,
			type        = questDef.type,
			progress    = progress,
			target      = questDef.target,
			claimed     = p.claimed,
			completed   = progress >= questDef.target,
			reward      = questDef.reward,
			icon        = questDef.icon,
			iconColor   = questDef.iconColor,
			order       = questDef.order,
		})
	end

	return {
		dataLoaded = true,
		day        = data.day,
		quests     = questList,
	}
end

-- ── PROGRESS INCREMENTOR ─────────────────────────────────────────────────────

local function incrementProgress(player: Player, questType: string, amount: number?)
	local PDS = getPDS()
	if not PDS or not PDS.IsLoaded(player) then return end

	local data = ensureQuestData(player)
	local changed = false

	for questId, questDef in pairs(DailyQuestConfig.Quests) do
		if questDef.type == questType then
			local p = data.progress[questId]
			if p and not p.claimed and p.progress < questDef.target then
				p.progress = math.min(p.progress + (amount or 1), questDef.target)
				log(string.format("Progress: %s %s %d/%d", player.Name, questId, p.progress, questDef.target))
				changed = true
			end
		end
	end

	if changed then
		saveQuestData(player, data)
		if updateRemote then
			updateRemote:FireClient(player, DailyQuestService.GetStatus(player))
		end
	end
end

-- ── PUBLIC HOOKS (called by other services) ───────────────────────────────────

function DailyQuestService.OnPlayerWon(player: Player)
	incrementProgress(player, "WinsToday")
end

function DailyQuestService.OnSwordKill(player: Player)
	incrementProgress(player, "SwordKillsToday")
end

-- Called when TTS despawns due to timer — reward all alive InMatch players
function DailyQuestService.OnTTSSurvive(player: Player)
	incrementProgress(player, "TTSSurvivalsToday")
end

-- ── CLAIM ─────────────────────────────────────────────────────────────────────

function DailyQuestService.TryClaim(player: Player, questId: string)
	local PDS = getPDS()
	if not PDS or not PDS.IsLoaded(player) then
		return { success = false, reason = "Data not loaded" }
	end

	local questDef = DailyQuestConfig.Quests[questId]
	if not questDef then
		return { success = false, reason = "Unknown quest" }
	end

	local data = ensureQuestData(player)
	local p = data.progress[questId]
	if not p then return { success = false, reason = "Quest state missing" } end

	if p.claimed then
		return { success = false, reason = "Already claimed" }
	end

	-- Evaluate completion
	local progress = p.progress
	if questDef.type == "TimePlayed" then
		progress = math.min(PDS.GetField(player, "TimePlayedSeconds") or 0, questDef.target)
	end

	if progress < questDef.target then
		return { success = false, reason = "Quest not completed yet" }
	end

	-- Grant reward
	local reward = questDef.reward
	local granted = false

	if reward.type == "Coins" then
		local eco = getEconomy()
		if eco then
			eco.AwardCoins(player, reward.amount, "DailyQuest_" .. questId, true)
			granted = true
		end
	elseif reward.type == "Pet" then
		local inv = getInventory()
		if inv then
			inv.GrantItem(player, "Pets", reward.itemId)
			granted = true
		end
	elseif reward.type == "Crown" then
		local inv = getInventory()
		if inv then
			inv.GrantItem(player, "Crowns", reward.itemId)
			granted = true
		end
	end

	if not granted then
		return { success = false, reason = "Reward grant failed" }
	end

	p.claimed = true
	saveQuestData(player, data)

	if updateRemote then
		updateRemote:FireClient(player, DailyQuestService.GetStatus(player))
	end

	log(string.format("%s claimed quest %s (reward %s)", player.Name, questId, reward.type))
	return { success = true, reward = reward }
end

-- ── INIT ──────────────────────────────────────────────────────────────────────

function DailyQuestService.Init()
	if initialized then return end
	initialized = true

	local remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
	if not remotes then
		warn("[DailyQuestService] Remotes folder not found")
		return
	end

	-- Push updates from server to client
	updateRemote = Instance.new("RemoteEvent")
	updateRemote.Name   = "DailyQuest_Update"
	updateRemote.Parent = remotes

	-- Client fetches status
	getStatusFunc = Instance.new("RemoteFunction")
	getStatusFunc.Name   = "DailyQuest_GetStatus"
	getStatusFunc.Parent = remotes
	getStatusFunc.OnServerInvoke = function(player)
		return DailyQuestService.GetStatus(player)
	end

	-- Client claims a completed quest
	claimFunc = Instance.new("RemoteFunction")
	claimFunc.Name   = "DailyQuest_Claim"
	claimFunc.Parent = remotes
	claimFunc.OnServerInvoke = function(player, questId)
		if type(questId) ~= "string" then
			return { success = false, reason = "Invalid questId" }
		end
		return DailyQuestService.TryClaim(player, questId)
	end

	-- Send initial status when player data is loaded
	Players.PlayerAdded:Connect(function(player)
		task.spawn(function()
			local PDS = getPDS()
			if PDS then
				for _ = 1, 20 do
					if PDS.IsLoaded(player) then break end
					task.wait(0.5)
				end
			end
			task.wait(1)
			if player.Parent and updateRemote then
				updateRemote:FireClient(player, DailyQuestService.GetStatus(player))
			end
		end)
	end)

	log("Initialized")
end

return DailyQuestService
