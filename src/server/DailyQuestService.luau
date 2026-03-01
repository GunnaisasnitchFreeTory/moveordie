--[[
	DailyQuestService
	Server-authoritative daily quest tracking and reward granting.

	Quests reset at UTC midnight. The active set is generated once per day from
	DailyQuestConfig.GenerateDailyQuests(day), seeded by the date -- identical
	for all players on the same day, automatically different every day.

	Player progress is stored in PlayerData.DailyQuestData as a JSON string:
	  { day="YYYY_MM_DD", progress={[questId]={progress=N, claimed=bool}} }

	API:
	  Init()
	  GetStatus(player)              -- quest list with live progress
	  TryClaim(player, questId)      -- grant reward, return result
	  OnPlayerWon(player)            -- hook from MatchManager
	  OnSwordKill(player)            -- hook from SwordSpawnService
	  OnTTSSurvive(player)           -- hook from TungTungSahurService
	  OnElimination(player)          -- general kill hook
	  OnRoundSurvived(player)        -- hook from RoundManager
	  DebugForceNewDay()             -- [Studio] reset cached day
	  DebugResetProgress(player)     -- [Studio] wipe today's progress
	  DebugCompleteQuest(p, questId) -- [Studio] max-out a quest
]]

local HttpService         = game:GetService("HttpService")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService          = game:GetService("RunService")
local Players             = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Server = ServerScriptService:WaitForChild("Server")

local DailyQuestConfig = require(Shared:WaitForChild("DailyQuestConfig"))

-- Lazy service loaders
local _PDS, _Economy, _Inventory, _Crate, _Spin = nil, nil, nil, nil, nil

local function getPDS()
	if _PDS then return _PDS end
	local ok, m = pcall(require, Server:WaitForChild("PlayerDataService", 5))
	if ok and m then _PDS = m end; return _PDS
end
local function getEconomy()
	if _Economy then return _Economy end
	local ok, m = pcall(require, Server:WaitForChild("EconomyService", 5))
	if ok and m then _Economy = m end; return _Economy
end
local function getInventory()
	if _Inventory then return _Inventory end
	local ok, m = pcall(require, Server:WaitForChild("InventoryService", 5))
	if ok and m then _Inventory = m end; return _Inventory
end
local function getCrate()
	if _Crate then return _Crate end
	local ok, m = pcall(require, Server:WaitForChild("CrateService", 5))
	if ok and m then _Crate = m end; return _Crate
end
local function getSpin()
	if _Spin then return _Spin end
	local ok, m = pcall(require, Server:WaitForChild("SpinWheelService", 5))
	if ok and m then _Spin = m end; return _Spin
end

local DailyQuestService = {}
local initialized  = false

local updateRemote:    RemoteEvent?    = nil
local getStatusFunc:   RemoteFunction? = nil
local claimFunc:       RemoteFunction? = nil
local debugRemote:     RemoteFunction? = nil

local function log(...) print("[DailyQuestService]", ...) end

-- Today's quest cache -- regenerated when the UTC day rolls over
local _cachedDay:    string = ""
local _cachedQuests: { { [string]: any } } = {}
local _cachedById:   { [string]: { [string]: any } } = {}
local _sessionJoinTimeByUserId: { [number]: number } = {}

local function getCurrentDay(): string
	return os.date("!%Y_%m_%d")
end

local function getTodayQuests(): { { [string]: any } }
	local today = getCurrentDay()
	if today ~= _cachedDay then
		_cachedDay    = today
		_cachedQuests = DailyQuestConfig.GenerateDailyQuests(today)
		_cachedById   = {}
		for _, q in ipairs(_cachedQuests) do
			_cachedById[q.id] = q
		end
		log(string.format("Generated quests for %s (%d quests)", today, #_cachedQuests))
		for _, q in ipairs(_cachedQuests) do
			log(string.format("  [%s] %s (%s x%d) -> %s",
				q.id, q.label, q.type, q.target,
				DailyQuestConfig.GetRewardLabel(q.reward)))
		end
	end
	return _cachedQuests
end

local function getTodayQuestById(id: string): { [string]: any }?
	getTodayQuests()
	return _cachedById[id]
end

local function getSessionPlayedSeconds(player: Player): number
	local joinTime = _sessionJoinTimeByUserId[player.UserId]
	if not joinTime then
		joinTime = os.time()
		_sessionJoinTimeByUserId[player.UserId] = joinTime
	end
	return math.max(0, os.time() - joinTime)
end

-- Player data helpers

local function getQuestData(player: Player): { [string]: any }
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

-- Returns the player's quest data, resetting if the UTC day has changed.
local function ensureQuestData(player: Player): { [string]: any }
	local data   = getQuestData(player)
	local today  = getCurrentDay()
	local quests = getTodayQuests()

	if data.day ~= today then
		data.day      = today
		data.progress = {}
		for _, q in ipairs(quests) do
			data.progress[q.id] = { progress = 0, claimed = false }
		end
		saveQuestData(player, data)
	end

	if type(data.progress) ~= "table" then data.progress = {} end
	for _, q in ipairs(quests) do
		if not data.progress[q.id] then
			data.progress[q.id] = { progress = 0, claimed = false }
		end
	end
	return data
end

-- Status builder

function DailyQuestService.GetStatus(player: Player)
	local PDS = getPDS()
	if not PDS or not PDS.IsLoaded(player) then
		return { dataLoaded = false, quests = {} }
	end

	local data       = ensureQuestData(player)
	local quests     = getTodayQuests()

	local questList = {}
	for _, questDef in ipairs(quests) do
		local p = data.progress[questDef.id] or { progress = 0, claimed = false }

		local progress = p.progress
		if questDef.type == "TimePlayed" then
			progress = math.min(getSessionPlayedSeconds(player), questDef.target)
		end

		table.insert(questList, {
			id          = questDef.id,
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

	table.sort(questList, function(a, b) return (a.order or 99) < (b.order or 99) end)

	return {
		dataLoaded = true,
		day        = data.day,
		quests     = questList,
	}
end

-- Progress incrementor

local function incrementProgress(player: Player, questType: string, amount: number?)
	local PDS = getPDS()
	if not PDS or not PDS.IsLoaded(player) then return end

	local data    = ensureQuestData(player)
	local quests  = getTodayQuests()
	local changed = false

	for _, questDef in ipairs(quests) do
		if questDef.type == questType then
			local p = data.progress[questDef.id]
			if p and not p.claimed and p.progress < questDef.target then
				p.progress = math.min(p.progress + (amount or 1), questDef.target)
				log(string.format("Progress: %s %s %d/%d",
					player.Name, questDef.id, p.progress, questDef.target))
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

-- Public event hooks (called by other services)

function DailyQuestService.OnPlayerWon(player: Player)
	incrementProgress(player, "WinsToday")
end

function DailyQuestService.OnSwordKill(player: Player)
	incrementProgress(player, "SwordKillsToday")
	incrementProgress(player, "EliminationsToday")
end

function DailyQuestService.OnTTSSurvive(player: Player)
	incrementProgress(player, "TTSSurvivalsToday")
end

function DailyQuestService.OnElimination(player: Player)
	incrementProgress(player, "EliminationsToday")
end

function DailyQuestService.OnRoundSurvived(player: Player)
	incrementProgress(player, "SurviveRoundsToday")
end

-- Claim

function DailyQuestService.TryClaim(player: Player, questId: string)
	local PDS = getPDS()
	if not PDS or not PDS.IsLoaded(player) then
		return { success = false, reason = "Data not loaded" }
	end

	if type(questId) ~= "string" then
		return { success = false, reason = "Invalid questId" }
	end

	local questDef = getTodayQuestById(questId)
	if not questDef then
		return { success = false, reason = "Unknown quest: " .. questId }
	end

	local data = ensureQuestData(player)
	local p    = data.progress[questId]
	if not p then return { success = false, reason = "Quest state missing" } end

	if p.claimed then
		return { success = false, reason = "Already claimed" }
	end

	local progress = p.progress
	if questDef.type == "TimePlayed" then
		progress = math.min(getSessionPlayedSeconds(player), questDef.target)
	end

	if progress < questDef.target then
		return { success = false, reason = "Quest not completed yet" }
	end

	-- Grant reward
	local reward  = questDef.reward
	local granted = false
	local extra   = {}

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

	elseif reward.type == "Crate" then
		local crate = getCrate()
		if crate then
			local crateId = reward.crateId or "crate_pet"
			local qty     = reward.count or 1
			local result  = crate.RollCrateFree(player, crateId, qty)
			if result and result.success and #result.results > 0 then
				granted = true
				local r = result.results[1]
				extra.crateGrant = {
					itemId      = r.itemId,
					displayName = r.displayName,
					rarity      = r.rarity,
					category    = r.category,
					isDuplicate = r.isDuplicate,
				}
			end
		end

	elseif reward.type == "Spin" then
		local sws = getSpin()
		if sws then
			sws.GrantRobuxSpins(player, reward.count or 1)
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

	log(string.format("%s claimed %s (reward: %s)",
		player.Name, questId, DailyQuestConfig.GetRewardLabel(reward)))

	return { success = true, reward = reward, extra = extra }
end

-- Debug commands (Studio-only)

function DailyQuestService.DebugForceNewDay()
	_cachedDay    = ""
	_cachedQuests = {}
	_cachedById   = {}
	log("[DEBUG] Forced new-day cache clear")
	for _, player in ipairs(Players:GetPlayers()) do
		local PDS = getPDS()
		if PDS and PDS.IsLoaded(player) then
			PDS.SetField(player, "DailyQuestData", "")
		end
	end
end

function DailyQuestService.DebugResetProgress(player: Player)
	local PDS = getPDS()
	if PDS then
		PDS.SetField(player, "DailyQuestData", "")
		log("[DEBUG] Reset quest progress for " .. player.Name)
		if updateRemote then
			updateRemote:FireClient(player, DailyQuestService.GetStatus(player))
		end
	end
end

function DailyQuestService.DebugCompleteQuest(player: Player, questId: string)
	local PDS = getPDS()
	if not PDS or not PDS.IsLoaded(player) then return end
	local data = ensureQuestData(player)
	local qdef = getTodayQuestById(questId)
	if not qdef then
		log("[DEBUG] Unknown questId: " .. tostring(questId))
		return
	end
	local p = data.progress[questId]
	if p then
		p.progress = qdef.target
		saveQuestData(player, data)
		log("[DEBUG] Completed quest " .. questId .. " for " .. player.Name)
		if updateRemote then
			updateRemote:FireClient(player, DailyQuestService.GetStatus(player))
		end
	end
end

-- Init

function DailyQuestService.Init()
	if initialized then return end
	initialized = true

	getTodayQuests()

	local remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
	if not remotes then
		warn("[DailyQuestService] Remotes folder not found")
		return
	end

	if not remotes:FindFirstChild("DailyQuest_Update") then
		updateRemote = Instance.new("RemoteEvent")
		updateRemote.Name   = "DailyQuest_Update"
		updateRemote.Parent = remotes
	else
		updateRemote = remotes:FindFirstChild("DailyQuest_Update")
	end

	if not remotes:FindFirstChild("DailyQuest_GetStatus") then
		getStatusFunc = Instance.new("RemoteFunction")
		getStatusFunc.Name   = "DailyQuest_GetStatus"
		getStatusFunc.Parent = remotes
	else
		getStatusFunc = remotes:FindFirstChild("DailyQuest_GetStatus")
	end
	getStatusFunc.OnServerInvoke = function(player)
		return DailyQuestService.GetStatus(player)
	end

	if not remotes:FindFirstChild("DailyQuest_Claim") then
		claimFunc = Instance.new("RemoteFunction")
		claimFunc.Name   = "DailyQuest_Claim"
		claimFunc.Parent = remotes
	else
		claimFunc = remotes:FindFirstChild("DailyQuest_Claim")
	end
	claimFunc.OnServerInvoke = function(player, questId)
		if type(questId) ~= "string" then
			return { success = false, reason = "Invalid questId" }
		end
		return DailyQuestService.TryClaim(player, questId)
	end

	if RunService:IsStudio() then
		if not remotes:FindFirstChild("DailyQuest_Debug") then
			debugRemote = Instance.new("RemoteFunction")
			debugRemote.Name   = "DailyQuest_Debug"
			debugRemote.Parent = remotes
		else
			debugRemote = remotes:FindFirstChild("DailyQuest_Debug")
		end
		debugRemote.OnServerInvoke = function(player, cmd, arg)
			if cmd == "ForceNewDay" then
				DailyQuestService.DebugForceNewDay()
				return { ok = true, msg = "New day forced" }
			elseif cmd == "ResetProgress" then
				DailyQuestService.DebugResetProgress(player)
				return { ok = true, msg = "Progress reset" }
			elseif cmd == "CompleteQuest" then
				if type(arg) == "string" then
					DailyQuestService.DebugCompleteQuest(player, arg)
					return { ok = true, msg = "Quest completed: " .. arg }
				end
			end
			return { ok = false, msg = "Unknown command" }
		end
	end

	Players.PlayerAdded:Connect(function(player)
		_sessionJoinTimeByUserId[player.UserId] = os.time()
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

	Players.PlayerRemoving:Connect(function(player)
		local PDS = getPDS()
		if PDS and PDS.IsLoaded(player) then
			local data = ensureQuestData(player)
			local quests = getTodayQuests()
			local sessionPlayed = getSessionPlayedSeconds(player)
			local changed = false

			for _, questDef in ipairs(quests) do
				if questDef.type == "TimePlayed" then
					local p = data.progress[questDef.id]
					if p and not p.claimed and sessionPlayed < questDef.target and p.progress ~= 0 then
						p.progress = 0
						changed = true
					end
				end
			end

			if changed then
				saveQuestData(player, data)
			end
		end
		_sessionJoinTimeByUserId[player.UserId] = nil
	end)

	for _, player in ipairs(Players:GetPlayers()) do
		_sessionJoinTimeByUserId[player.UserId] = os.time()
	end

	log("Initialized -- " .. #getTodayQuests() .. " quests active today")
end

return DailyQuestService
