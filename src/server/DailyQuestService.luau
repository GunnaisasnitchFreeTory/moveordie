--[[
	DailyQuestService
	Server-authoritative daily quest tracking and reward granting.

	Quests reset at UTC midnight. The active set is generated once per day from
	DailyQuestConfig.GenerateDailyQuests(day), seeded by the date -- identical
	for all players on the same day, automatically different every day.

	Player progress is stored in PlayerData.DailyQuestData as a JSON string:
	  {
	    day="YYYY_MM_DD",
	    progress={[questId]={progress=N, claimed=bool}},
	    oneTimeClaimed={[questId]=true}
	  }

	API:
	  Init()
	  GetStatus(player)              -- quest list with live progress
	  TryClaim(player, questId)      -- grant reward, return result
	  OnMatchStart(players)          -- resets single-match survival run trackers
	  OnMatchEnd()                   -- clears single-match survival run trackers
	  OnPlayerWon(player)            -- hook from MatchManager
	  OnSwordKill(player)            -- hook from SwordSpawnService
	  OnTTSSurvive(player)           -- hook from TungTungSahurService
	  OnElimination(player)          -- general kill hook
	  OnRoundSurvived(player)        -- hook from RoundManager
	OnIndexOpened(player)          -- hook from client Index panel open
	OnCratePurchased(player)       -- hook from CrateService successful purchase
	OnBrainrotPetPickup(player, petId, modeName) -- hook from BrainrotModeService
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
local ItemCatalog = require(Shared:WaitForChild("ItemCatalog"))

-- Lazy service loaders
local _PDS, _Economy, _Inventory, _Crate, _Spin, _Feedback = nil, nil, nil, nil, nil, nil

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
local function getFeedback()
	if _Feedback ~= nil then return _Feedback end
	local ok, m = pcall(require, Server:FindFirstChild("MatchFeedbackService"))
	if ok and m then _Feedback = m else _Feedback = false end
	return _Feedback
end

local DailyQuestService = {}
local initialized  = false

local updateRemote:    RemoteEvent?    = nil
local getStatusFunc:   RemoteFunction? = nil
local claimFunc:       RemoteFunction? = nil
local debugRemote:     RemoteFunction? = nil
local actionRemote:    RemoteEvent?    = nil

local function log(...) print("[DailyQuestService]", ...) end
local STARTER_QUEST = DailyQuestConfig.StarterQuest
local STARTER_QUEST_ID = tostring(STARTER_QUEST and STARTER_QUEST.id or "starter_survive_1_round")
local STARTER_QUEST_STATE_UNCLASSIFIED = "Unclassified"
local STARTER_QUEST_STATE_ELIGIBLE = "Eligible"
local STARTER_QUEST_STATE_INELIGIBLE = "Ineligible"
local STARTER_QUEST_STATE_COMPLETED = "Completed"
local STARTER_QUEST_REWARD_REASON = "StarterQuest_Survive1Round_700Coins"

local CRATE_ID_ALIASES: { [string]: string } = {
	crate_pet = "crate_pet_common",
}

local function resolveQuestCrateId(rawId: any): string
	local crateId = if type(rawId) == "string" and rawId ~= "" then rawId else "crate_pet_common"
	return CRATE_ID_ALIASES[crateId] or crateId
end

-- Today's quest cache -- regenerated when the UTC day rolls over
local _cachedDay:    string = ""
local _cachedQuests: { { [string]: any } } = {}
local _cachedById:   { [string]: { [string]: any } } = {}
local _sessionJoinTimeByUserId: { [number]: number } = {}
local _studioDayOffsetDays: number = 0
local _singleMatchSurvivalRoundsByUserId: { [number]: number } = {}
local _singleMatchParticipantByUserId: { [number]: boolean } = {}
local _lastSingleMatchSweepRound: number = -1
local _starterQuestAssignedLoggedByUserId: { [number]: boolean } = {}
local _lastQuestPayloadSignatureByUserId: { [number]: string } = {}
local _starterJoinTraceLoggedByUserId: { [number]: boolean } = {}

local MATCH_SCOPED_SURVIVAL_TYPES: { [string]: boolean } = {
	SurviveRoundsSingleMatch12 = true,
	SurviveRoundsSingleMatch15 = true,
}

local function getCurrentDay(): string
	if RunService:IsStudio() and _studioDayOffsetDays ~= 0 then
		local nowUtc = DateTime.now().UnixTimestamp
		return os.date("!%Y_%m_%d", nowUtc + (_studioDayOffsetDays * 86400))
	end
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

local function isMatchScopedSurvivalQuestType(questType: string): boolean
	return MATCH_SCOPED_SURVIVAL_TYPES[questType] == true
end

local function isPlayerInActiveSingleMatchRun(player: Player): boolean
	if _singleMatchParticipantByUserId[player.UserId] ~= true then
		return false
	end
	return player:GetAttribute("PlayerState") == "InMatch"
end

local function getSingleMatchSurvivalRounds(player: Player): number
	if not isPlayerInActiveSingleMatchRun(player) then
		return 0
	end
	return _singleMatchSurvivalRoundsByUserId[player.UserId] or 0
end

local function isOneTimeQuestRewardOwned(player: Player, questDef: { [string]: any }): boolean
	if type(questDef) ~= "table" or questDef.oneTime ~= true then
		return false
	end
	local reward = questDef.reward
	if type(reward) ~= "table" then
		return false
	end
	local inv = getInventory()
	if not inv or type(inv.OwnsItem) ~= "function" then
		return false
	end
	if reward.type == "Crown" and type(reward.itemId) == "string" and reward.itemId ~= "" then
		return inv.OwnsItem(player, "Crowns", reward.itemId) == true
	end
	if reward.type == "Pet" and type(reward.itemId) == "string" and reward.itemId ~= "" then
		return inv.OwnsItem(player, "Pets", reward.itemId) == true
	end
	if reward.type == "IconImage" and type(reward.itemId) == "string" and reward.itemId ~= "" then
		return inv.OwnsItem(player, "IconImages", reward.itemId) == true
	end
	return false
end

local function countListEntries(value: any): number
	if type(value) ~= "table" then
		return 0
	end
	return #value
end

local function getStarterQuestState(player: Player): string
	local PDS = getPDS()
	local rawState = PDS and PDS.GetField(player, "StarterQuestState") or STARTER_QUEST_STATE_UNCLASSIFIED
	local starterQuestState = tostring(rawState or STARTER_QUEST_STATE_UNCLASSIFIED)
	if starterQuestState ~= STARTER_QUEST_STATE_UNCLASSIFIED
		and starterQuestState ~= STARTER_QUEST_STATE_ELIGIBLE
		and starterQuestState ~= STARTER_QUEST_STATE_INELIGIBLE
		and starterQuestState ~= STARTER_QUEST_STATE_COMPLETED
	then
		starterQuestState = STARTER_QUEST_STATE_UNCLASSIFIED
	end
	return starterQuestState
end

local function setStarterQuestState(player: Player, starterQuestState: string): boolean
	local PDS = getPDS()
	if not PDS then
		return false
	end
	return PDS.SetField(player, "StarterQuestState", starterQuestState) == true
end

local function getStarterCompletionSnapshot(player: Player): (boolean, string)
	local state = getStarterQuestState(player)
	if state == STARTER_QUEST_STATE_COMPLETED then
		return true, "starter_state_completed"
	end

	local data = { day = "", progress = {}, oneTimeClaimed = {} }
	local PDS = getPDS()
	local raw = PDS and PDS.GetField(player, "DailyQuestData") or ""
	if raw and raw ~= "" then
		local ok, decoded = pcall(function()
			return HttpService:JSONDecode(raw)
		end)
		if ok and type(decoded) == "table" then
			data = decoded
		end
	end
	local oneTimeClaimed = type(data.oneTimeClaimed) == "table" and data.oneTimeClaimed[STARTER_QUEST_ID] == true
	if oneTimeClaimed then
		return true, "dailyquest_onetime_claimed"
	end

	local progressState = type(data.progress) == "table" and data.progress[STARTER_QUEST_ID] or nil
	if type(progressState) == "table" and progressState.claimed == true then
		return true, "dailyquest_progress_claimed"
	end

	return false, "starter_not_completed"
end

local function resolveStarterQuestState(player: Player): string
	local PDS = getPDS()
	if not PDS or not PDS.IsLoaded(player) then
		return STARTER_QUEST_STATE_UNCLASSIFIED
	end

	local currentState = getStarterQuestState(player)
	if currentState == STARTER_QUEST_STATE_COMPLETED or currentState == STARTER_QUEST_STATE_ELIGIBLE then
		return currentState
	end

	local completed, completionReason = getStarterCompletionSnapshot(player)
	local nextState = if completed then STARTER_QUEST_STATE_COMPLETED else STARTER_QUEST_STATE_ELIGIBLE
	setStarterQuestState(player, nextState)

	log(string.format(
		"[StarterQuestEligibility] player=%s eligible=%s reason=%s assignedState=%s gate=quest_completion_only",
		player.Name,
		tostring(not completed),
		completionReason,
		nextState
	))

	return nextState
end

local function syncStarterQuestProgressEntry(data: { [string]: any }, starterQuestState: string): boolean
	if not STARTER_QUEST then
		return false
	end
	if type(data.progress) ~= "table" then
		data.progress = {}
	end
	if type(data.oneTimeClaimed) ~= "table" then
		data.oneTimeClaimed = {}
	end

	local progressState = data.progress[STARTER_QUEST_ID]
	local mutated = false
	if type(progressState) ~= "table" then
		progressState = { progress = 0, claimed = false }
		data.progress[STARTER_QUEST_ID] = progressState
		mutated = true
	end

	if data.oneTimeClaimed[STARTER_QUEST_ID] == true or starterQuestState == STARTER_QUEST_STATE_COMPLETED then
		if (tonumber(progressState.progress) or 0) < STARTER_QUEST.target then
			progressState.progress = STARTER_QUEST.target
			mutated = true
		end
		if progressState.claimed ~= true then
			progressState.claimed = true
			mutated = true
		end
		if data.oneTimeClaimed[STARTER_QUEST_ID] ~= true then
			data.oneTimeClaimed[STARTER_QUEST_ID] = true
			mutated = true
		end
	end

	return mutated
end

local function shouldIncludeStarterQuestInStatus(data: { [string]: any }, starterQuestState: string): boolean
	if not STARTER_QUEST or type(data.progress) ~= "table" then
		return false
	end
	if starterQuestState == STARTER_QUEST_STATE_ELIGIBLE then
		return true
	end
	local progressState = data.progress[STARTER_QUEST_ID]
	return type(progressState) == "table"
		and progressState.claimed ~= true
		and (tonumber(progressState.progress) or 0) > 0
end

local function buildStarterQuestStatus(progressState: { [string]: any }): { [string]: any }
	local progress = math.max(0, math.floor(tonumber(progressState and progressState.progress) or 0))
	local claimed = progressState and progressState.claimed == true or false
	return {
		id = STARTER_QUEST.id,
		label = STARTER_QUEST.label,
		description = STARTER_QUEST.description,
		type = STARTER_QUEST.type,
		progress = progress,
		target = STARTER_QUEST.target,
		claimed = claimed,
		completed = progress >= STARTER_QUEST.target,
		reward = STARTER_QUEST.reward,
		icon = STARTER_QUEST.icon,
		iconColor = STARTER_QUEST.iconColor,
		order = STARTER_QUEST.order,
	}
end

-- Player data helpers

local function getQuestData(player: Player): { [string]: any }
	local PDS = getPDS()
	local raw = PDS and PDS.GetField(player, "DailyQuestData") or ""
	if raw and raw ~= "" then
		local ok, decoded = pcall(function() return HttpService:JSONDecode(raw) end)
		if ok and type(decoded) == "table" then return decoded end
	end
	return { day = "", progress = {}, oneTimeClaimed = {} }
end

local function saveQuestData(player: Player, data: { [string]: any })
	local PDS = getPDS()
	if not PDS then return end
	local ok, encoded = pcall(function() return HttpService:JSONEncode(data) end)
	if ok then PDS.SetField(player, "DailyQuestData", encoded) end
end

-- Returns the player's quest data, resetting if the UTC day has changed.
local function ensureQuestData(player: Player, starterQuestStateOverride: string?): { [string]: any }
	local data   = getQuestData(player)
	local today  = getCurrentDay()
	local quests = getTodayQuests()
	local starterQuestState = if type(starterQuestStateOverride) == "string" and starterQuestStateOverride ~= ""
		then starterQuestStateOverride
		else getStarterQuestState(player)
	local mutated = false
	if type(data.oneTimeClaimed) ~= "table" then
		data.oneTimeClaimed = {}
		mutated = true
	end

	if data.day ~= today then
		data.day      = today
		data.progress = {}
		for _, q in ipairs(quests) do
			data.progress[q.id] = { progress = 0, claimed = false }
		end
		mutated = true
	end

	if type(data.progress) ~= "table" then
		data.progress = {}
		mutated = true
	end
	for _, q in ipairs(quests) do
		if not data.progress[q.id] then
			data.progress[q.id] = { progress = 0, claimed = false }
			mutated = true
		end
		if q.oneTime == true and data.oneTimeClaimed[q.id] == true then
			local p = data.progress[q.id]
			p.progress = math.max(tonumber(p.progress) or 0, q.target)
			p.claimed = true
		end
		if isMatchScopedSurvivalQuestType(q.type) then
			local p = data.progress[q.id]
			if p and not p.claimed and (tonumber(p.progress) or 0) ~= 0 then
				p.progress = 0
			end
		end
	end
	if syncStarterQuestProgressEntry(data, starterQuestState) then
		mutated = true
	end
	if mutated then
		saveQuestData(player, data)
	end
	return data
end

local function resolveQuestProgress(player: Player, questDef: { [string]: any }, progressState: { [string]: any }): number
	-- Claimed quests are inactive immediately and must never continue progressing.
	if progressState.claimed then
		return questDef.target
	end
	if questDef.type == "TimePlayed" then
		return math.min(getSessionPlayedSeconds(player), questDef.target)
	end
	if isMatchScopedSurvivalQuestType(questDef.type) then
		local persisted = tonumber(progressState.progress) or 0
		if persisted >= questDef.target then
			return questDef.target
		end
		return math.min(getSingleMatchSurvivalRounds(player), questDef.target)
	end
	return progressState.progress or 0
end

local function buildQuestPayloadSummary(questList: { { [string]: any } }): (string, boolean, string)
	local entries = table.create(#questList)
	local starterPresent = false
	for _, quest in ipairs(questList) do
		local questId = tostring(quest.id or "")
		local questLabel = tostring(quest.label or questId)
		if questId == STARTER_QUEST_ID then
			starterPresent = true
		end
		table.insert(entries, questId .. ":" .. questLabel)
	end
	local payloadSummary = table.concat(entries, " | ")
	local payloadSignature = tostring(#questList) .. "::" .. payloadSummary
	return payloadSignature, starterPresent, payloadSummary
end

-- Status builder

function DailyQuestService.GetStatus(player: Player)
	local PDS = getPDS()
	if not PDS or not PDS.IsLoaded(player) then
		return { dataLoaded = false, quests = {} }
	end

	local starterQuestState = resolveStarterQuestState(player)
	local data       = ensureQuestData(player, starterQuestState)
	local quests     = getTodayQuests()
	local mutated    = false
	local statusScope = "join_or_refresh"
	local starterCompleted, starterDecisionReason = getStarterCompletionSnapshot(player)
	local starterEligible = not starterCompleted

	local questList = {}

	for _, questDef in ipairs(quests) do
		local p = data.progress[questDef.id] or { progress = 0, claimed = false }
		local oneTimeClaimed = (questDef.oneTime == true) and (data.oneTimeClaimed[questDef.id] == true)
		local rewardOwned = isOneTimeQuestRewardOwned(player, questDef)

		-- One-time quest migration safety:
		-- If reward is already owned or this quest was previously completed,
		-- mark this daily entry as claimed so it never appears again.
		if questDef.oneTime == true and (oneTimeClaimed or rewardOwned) and not p.claimed then
			p.progress = questDef.target
			p.claimed = true
			data.oneTimeClaimed[questDef.id] = true
			mutated = true
			log(string.format(
				"[DailyQuestOneTime] autoMarkClaimed player=%s quest=%s rewardOwned=%s priorOneTimeClaimed=%s",
				player.Name,
				questDef.id,
				tostring(rewardOwned),
				tostring(oneTimeClaimed)
			))
		end
		if isMatchScopedSurvivalQuestType(questDef.type) and not p.claimed and (tonumber(p.progress) or 0) ~= 0 then
			p.progress = 0
			mutated = true
			log(string.format(
				"[SingleMatchQuest] resetStoredPartial player=%s quest=%s",
				player.Name,
				questDef.id
			))
		end

		local progress = resolveQuestProgress(player, questDef, p)
		-- Claimed quests are hidden from the active quest feed.
		if p.claimed then
			continue
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

	local beforeStarterSignature, beforeStarterPresent, beforeStarterSummary = buildQuestPayloadSummary(questList)
	local shouldIncludeStarter = shouldIncludeStarterQuestInStatus(data, starterQuestState) and STARTER_QUEST ~= nil
	local starterQuestCreated = shouldIncludeStarter and data.progress[STARTER_QUEST_ID] ~= nil
	local starterInserted = false
	if shouldIncludeStarter and STARTER_QUEST then
		local starterProgressState = data.progress[STARTER_QUEST_ID] or { progress = 0, claimed = false }
		table.insert(questList, buildStarterQuestStatus(starterProgressState))
		starterInserted = true
		if _starterQuestAssignedLoggedByUserId[player.UserId] ~= true then
			_starterQuestAssignedLoggedByUserId[player.UserId] = true
			log(string.format(
				"[StarterQuestAssignment] player=%s questCreated=%s questId=%s label=%s reward=%s",
				player.Name,
				tostring(starterQuestCreated),
				STARTER_QUEST_ID,
				tostring(STARTER_QUEST.label),
				DailyQuestConfig.GetRewardLabel(STARTER_QUEST.reward)
			))
		end
	end

	table.sort(questList, function(a, b) return (a.order or 99) < (b.order or 99) end)
	if mutated then
		saveQuestData(player, data)
	end

	local payloadSignature, starterPresent, payloadSummary = buildQuestPayloadSummary(questList)
	if _lastQuestPayloadSignatureByUserId[player.UserId] ~= payloadSignature then
		_lastQuestPayloadSignatureByUserId[player.UserId] = payloadSignature
		log(string.format(
			"[QuestPayload] player=%s source=GetStatus starterState=%s starterPresent=%s activeQuestCount=%d quests=%s",
			player.Name,
			starterQuestState,
			tostring(starterPresent),
			#questList,
			payloadSummary
		))
	end
	if _starterJoinTraceLoggedByUserId[player.UserId] ~= true then
		_starterJoinTraceLoggedByUserId[player.UserId] = true
		log(string.format(
			"[StarterQuestJoinTrace] player=%s scope=%s eligible=%s reason=%s state=%s questCreated=%s insertedIntoActiveQuestList=%s beforeStarterPresent=%s beforeCountSig=%s beforeList=%s finalStarterPresent=%s finalActiveList=%s",
			player.Name,
			statusScope,
			tostring(starterEligible),
			starterDecisionReason,
			starterQuestState,
			tostring(starterQuestCreated),
			tostring(starterInserted),
			tostring(beforeStarterPresent),
			beforeStarterSignature,
			beforeStarterSummary,
			tostring(starterPresent),
			payloadSummary
		))
	end

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

	local starterQuestState = resolveStarterQuestState(player)
	local data    = ensureQuestData(player, starterQuestState)
	local quests  = getTodayQuests()
	local changed = false
	local incrementAmount = amount or 1

	if STARTER_QUEST
		and STARTER_QUEST.type == questType
		and starterQuestState == STARTER_QUEST_STATE_ELIGIBLE
	then
		local starterProgress = data.progress[STARTER_QUEST_ID]
		if starterProgress and starterProgress.claimed ~= true and (tonumber(starterProgress.progress) or 0) < STARTER_QUEST.target then
			local previousProgress = tonumber(starterProgress.progress) or 0
			starterProgress.progress = math.min(previousProgress + incrementAmount, STARTER_QUEST.target)
			log(string.format("Progress: %s %s %d/%d",
				player.Name, STARTER_QUEST_ID, starterProgress.progress, STARTER_QUEST.target))
			if previousProgress < STARTER_QUEST.target and starterProgress.progress >= STARTER_QUEST.target then
				log(string.format("[StarterQuest] player=%s completed=true quest=%s", player.Name, STARTER_QUEST_ID))
				local feedback = getFeedback()
				if feedback and feedback.OnQuestCompleted then
					pcall(feedback.OnQuestCompleted, player, STARTER_QUEST)
				end
			elseif previousProgress < starterProgress.progress then
				local feedback = getFeedback()
				if feedback and feedback.OnQuestProgressUpdated then
					pcall(feedback.OnQuestProgressUpdated, player, STARTER_QUEST, starterProgress.progress, STARTER_QUEST.target)
				end
			end
			changed = true
		end
	end

	for _, questDef in ipairs(quests) do
		if questDef.type == questType then
			if isMatchScopedSurvivalQuestType(questDef.type) then
				continue
			end
			local p = data.progress[questDef.id]
			if p and questDef.oneTime == true and (data.oneTimeClaimed[questDef.id] == true or isOneTimeQuestRewardOwned(player, questDef)) then
				if not p.claimed then
					p.progress = questDef.target
					p.claimed = true
					data.oneTimeClaimed[questDef.id] = true
					changed = true
				end
				continue
			end
			if p and not p.claimed and p.progress < questDef.target then
				local prevProgress = p.progress
				p.progress = math.min(prevProgress + incrementAmount, questDef.target)
				log(string.format("Progress: %s %s %d/%d",
					player.Name, questDef.id, p.progress, questDef.target))
				if prevProgress < questDef.target and p.progress >= questDef.target then
					log(string.format("Quest completed: %s %s", player.Name, questDef.id))
					local feedback = getFeedback()
					if feedback and feedback.OnQuestCompleted then
						pcall(feedback.OnQuestCompleted, player, questDef)
					end
				elseif prevProgress < p.progress then
					local feedback = getFeedback()
					if feedback and feedback.OnQuestProgressUpdated then
						pcall(feedback.OnQuestProgressUpdated, player, questDef, p.progress, questDef.target)
					end
				end
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

local function applySingleMatchSurvivalProgress(player: Player, roundsSurvived: number)
	local PDS = getPDS()
	if not PDS or not PDS.IsLoaded(player) then
		return
	end
	local data = ensureQuestData(player)
	local quests = getTodayQuests()
	local changed = false

	for _, questDef in ipairs(quests) do
		if isMatchScopedSurvivalQuestType(questDef.type) then
			local p = data.progress[questDef.id]
			if p and not p.claimed and roundsSurvived >= (questDef.target or 0) then
				p.progress = questDef.target
				changed = true
				log(string.format(
					"[SingleMatchQuest] player=%s quest=%s completed=true roundsSurvived=%d target=%d",
					player.Name,
					questDef.id,
					roundsSurvived,
					questDef.target or 0
				))
				local feedback = getFeedback()
				if feedback and feedback.OnQuestCompleted then
					pcall(feedback.OnQuestCompleted, player, questDef)
				end
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

local function sweepSingleMatchRunFailures(roundNumber: number?)
	local sweepRound = tonumber(roundNumber) or -1
	if sweepRound >= 0 and _lastSingleMatchSweepRound == sweepRound then
		return
	end
	_lastSingleMatchSweepRound = sweepRound
	for userId, active in pairs(_singleMatchParticipantByUserId) do
		if active then
			local trackedPlayer = Players:GetPlayerByUserId(userId)
			local stillInMatch = trackedPlayer and trackedPlayer:GetAttribute("PlayerState") == "InMatch"
			if not stillInMatch then
				_singleMatchParticipantByUserId[userId] = nil
				_singleMatchSurvivalRoundsByUserId[userId] = nil
				if trackedPlayer then
					log(string.format(
						"[SingleMatchQuest] player=%s runReset=true reason=left_inmatch_state round=%s",
						trackedPlayer.Name,
						tostring(roundNumber or "?")
					))
				end
			end
		end
	end
end

function DailyQuestService.OnMatchStart(players: { Player }?)
	_singleMatchSurvivalRoundsByUserId = {}
	_singleMatchParticipantByUserId = {}
	_lastSingleMatchSweepRound = -1
	if type(players) == "table" then
		for _, player in ipairs(players) do
			if player and player.Parent then
				_singleMatchParticipantByUserId[player.UserId] = true
				_singleMatchSurvivalRoundsByUserId[player.UserId] = 0
				log(string.format("[SingleMatchQuest] player=%s matchStart=true roundsSurvived=0", player.Name))
			end
		end
	end
end

function DailyQuestService.OnMatchEnd()
	if next(_singleMatchParticipantByUserId) ~= nil then
		for _, player in ipairs(Players:GetPlayers()) do
			if _singleMatchParticipantByUserId[player.UserId] == true then
				log(string.format(
					"[SingleMatchQuest] player=%s matchEnd=true roundsSurvived=%d",
					player.Name,
					_singleMatchSurvivalRoundsByUserId[player.UserId] or 0
				))
			end
		end
	end
	_singleMatchParticipantByUserId = {}
	_singleMatchSurvivalRoundsByUserId = {}
	_lastSingleMatchSweepRound = -1
end

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

function DailyQuestService.OnRoundSurvived(player: Player, roundNumber: number?)
	incrementProgress(player, "SurviveRoundsToday")
	incrementProgress(player, "StarterSurviveRound")
	sweepSingleMatchRunFailures(roundNumber)
	if not isPlayerInActiveSingleMatchRun(player) then
		return
	end
	local roundsSurvived = (_singleMatchSurvivalRoundsByUserId[player.UserId] or 0) + 1
	_singleMatchSurvivalRoundsByUserId[player.UserId] = roundsSurvived
	log(string.format(
		"[SingleMatchQuest] player=%s roundSurvived=true round=%s roundsSurvived=%d event=RoundsSurvivedIncrement",
		player.Name,
		tostring(roundNumber or "?"),
		roundsSurvived
	))
	applySingleMatchSurvivalProgress(player, roundsSurvived)
end

function DailyQuestService.OnIndexOpened(player: Player)
	if not player or not player.Parent then
		return
	end
	local PDS = getPDS()
	if not PDS or not PDS.IsLoaded(player) then
		-- Join-time UI can open before profile load; retry briefly so first open still counts.
		task.spawn(function()
			for _ = 1, 20 do
				local retryPDS = getPDS()
				if not player.Parent then
					return
				end
				if retryPDS and retryPDS.IsLoaded(player) then
					incrementProgress(player, "FirstIndexOpen", 1)
					log(string.format("[QuestAction] player=%s action=IndexOpened result=applied_after_retry", player.Name))
					return
				end
				task.wait(0.25)
			end
			log(string.format("[QuestAction] player=%s action=IndexOpened result=skipped_data_not_loaded", player.Name))
		end)
		return
	end

	incrementProgress(player, "FirstIndexOpen", 1)
	log(string.format("[QuestAction] player=%s action=IndexOpened result=applied_immediate", player.Name))
end

function DailyQuestService.OnCratePurchased(player: Player)
	if not player or not player.Parent then
		return
	end
	incrementProgress(player, "FirstCratePurchase", 1)
end

function DailyQuestService.OnBrainrotPetPickup(player: Player, petId: string, modeName: string?)
	if type(petId) ~= "string" then return end
	if modeName and modeName ~= "Brainrot" then
		return
	end
	if petId ~= "pet_brainrot_ishowspeed" then
		return
	end
	log(string.format("[QuestHook] Brainrot pickup accepted player=%s petId=%s mode=%s",
		player.Name,
		petId,
		tostring(modeName or "Brainrot")))
	incrementProgress(player, "BrainrotIShowSpeedPickupsToday", 1)
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

	local starterQuestState = resolveStarterQuestState(player)
	local data = ensureQuestData(player, starterQuestState)
	local questDef = nil
	if questId == STARTER_QUEST_ID and STARTER_QUEST and shouldIncludeStarterQuestInStatus(data, starterQuestState) then
		questDef = STARTER_QUEST
	else
		questDef = getTodayQuestById(questId)
	end
	if not questDef then
		return { success = false, reason = "Unknown quest: " .. questId }
	end

	local p    = data.progress[questId]
	if not p then return { success = false, reason = "Quest state missing" } end

	if p.claimed then
		return { success = false, reason = "Already claimed" }
	end

	local progress = p.progress
	progress = resolveQuestProgress(player, questDef, p)

	if progress < questDef.target then
		return { success = false, reason = "Quest not completed yet" }
	end

	-- Grant reward
	local reward  = questDef.reward
	local granted = false
	local extra   = {}
	local failReason = "Reward grant failed"
	local rewardType = tostring(reward and reward.type or "")
	local rewardId = ""
	local rewardAmount = 1
	if rewardType == "Coins" then
		rewardAmount = tonumber(reward.amount) or 0
		rewardId = "fate_coins"
	elseif rewardType == "Spin" then
		rewardAmount = tonumber(reward.count) or 0
		rewardId = "spin_purchased"
	elseif rewardType == "Crate" then
		rewardAmount = tonumber(reward.count) or 1
		rewardId = tostring(reward.crateId or reward.itemId or "")
	else
		rewardAmount = 1
		rewardId = tostring(reward and reward.itemId or "")
	end
	log(string.format("[DailyQuestGrant] quest=%s rewardType=%s rewardId=%s amount=%s",
		tostring(questId), rewardType, rewardId, tostring(rewardAmount)))

	if reward.type == "Coins" then
		local eco = getEconomy()
		if eco then
			local source = "DailyQuest_" .. questId
			local baseAmount = tonumber(reward.amount) or 0
			local useExactPolicy = reward.exact == true
			local ok, actualAmount
			if useExactPolicy then
				ok, actualAmount = eco.AwardCoins(player, baseAmount, source, true)
			else
				ok, actualAmount = eco.AwardVipOnlyCoins(player, baseAmount, source)
			end
			granted = ok == true
			if granted then
				extra.actualAmount = actualAmount or baseAmount
				log(string.format(
					"[DailyQuestGrantAudit] player=%s quest=%s base=%d policy=%s final=%d source=%s",
					player.Name,
					questId,
					baseAmount,
					if useExactPolicy then "exact" else "vip_only",
					tonumber(extra.actualAmount) or 0,
					source
				))
			end
			if not granted then
				failReason = "COIN_GRANT_FAILED"
			end
		else
			failReason = "ECONOMY_UNAVAILABLE"
		end

	elseif reward.type == "Pet" then
		local inv = getInventory()
		if inv then
			granted = inv.GrantItem(player, "Pets", reward.itemId) == true
			if not granted then
				failReason = "PET_GRANT_FAILED"
			end
		else
			failReason = "INVENTORY_UNAVAILABLE"
		end

	elseif reward.type == "IconImage" then
		local inv = getInventory()
		if inv then
			granted = inv.GrantItem(player, "IconImages", reward.itemId) == true
			if granted then
				local iconDef = ItemCatalog.IconImages and ItemCatalog.IconImages[reward.itemId]
				log(string.format("[DailyQuestGrant] iconImageUnlocked player=%s itemId=%s image=%s",
					player.Name,
					tostring(reward.itemId),
					tostring(iconDef and iconDef.image or "")))
			else
				failReason = "ICONIMAGE_GRANT_FAILED"
			end
		else
			failReason = "INVENTORY_UNAVAILABLE"
		end

	elseif reward.type == "Crown" then
		local inv = getInventory()
		if inv then
			granted = inv.GrantItem(player, "Crowns", reward.itemId) == true
			if not granted then
				failReason = "CROWN_GRANT_FAILED"
			end
		else
			failReason = "INVENTORY_UNAVAILABLE"
		end

	elseif reward.type == "Crate" then
		local crate = getCrate()
		if crate then
			local crateId = resolveQuestCrateId(reward.crateId or reward.itemId)
			local qty     = reward.count or 1
			local crateDefFound = ItemCatalog.Crates and ItemCatalog.Crates[crateId] ~= nil
			local result  = crate.RollCrateFree(player, crateId, qty)
			local outcomes = if result and type(result.results) == "table" then result.results else {}
			local chosenOutcome = outcomes[1]
			if chosenOutcome then
				for _, r in ipairs(outcomes) do
					if r and r.grantSuccess == true then
						chosenOutcome = r
						break
					end
				end
			end

			if result and result.success and chosenOutcome and type(chosenOutcome.itemId) == "string" and chosenOutcome.itemId ~= "" then
				local grantSuccess = chosenOutcome.grantSuccess == true
				local isDuplicate = chosenOutcome.isDuplicate == true
				-- Existing crate duplicate behavior is preserved: duplicate is a valid resolved outcome.
				granted = grantSuccess or isDuplicate
				extra.crateGrant = {
					itemId      = chosenOutcome.itemId,
					displayName = chosenOutcome.displayName,
					rarity      = chosenOutcome.rarity,
					category    = chosenOutcome.category,
					isDuplicate = isDuplicate,
					grantSuccess = grantSuccess,
				}
				extra.crateResults = outcomes
				extra.crateResolved = {
					crateId = crateId,
					crateDefinitionFound = crateDefFound,
					quantity = qty,
					rollSuccess = result.success == true,
				}
			end
			if not granted then
				failReason = tostring(result and result.error or "CRATE_GRANT_FAILED")
			end

			log(string.format(
				"[QuestCrate] quest=%s rewardType=Crate rewardId=%s resolvedCrateId=%s crateDefFound=%s granted=%s outcome=%s duplicate=%s",
				tostring(questId),
				tostring(reward.crateId or reward.itemId or "nil"),
				tostring(crateId),
				tostring(crateDefFound),
				tostring(granted),
				tostring(extra.crateGrant and extra.crateGrant.itemId or "nil"),
				tostring(extra.crateGrant and extra.crateGrant.isDuplicate or false)
			))
		else
			failReason = "CRATE_SERVICE_UNAVAILABLE"
		end

	elseif reward.type == "Spin" then
		local sws = getSpin()
		if sws then
			if type(sws.GetPlayerData) == "function" then
				pcall(function()
					sws.GetPlayerData(player)
				end)
			end
			granted = sws.GrantRobuxSpins(player, reward.count or 1) == true
			if not granted then
				failReason = "SPIN_GRANT_FAILED"
			end
		else
			failReason = "SPIN_SERVICE_UNAVAILABLE"
		end
	else
		failReason = "UNSUPPORTED_REWARD_TYPE"
	end

	if not granted then
		log(string.format("[DailyQuestGrant] player=%s result=FAIL reason=%s",
			player.Name, tostring(failReason)))
		return { success = false, reason = tostring(failReason) }
	end

	-- Deactivate immediately at lifecycle level.
	p.progress = questDef.target
	p.claimed = true
	if questDef.oneTime == true then
		if type(data.oneTimeClaimed) ~= "table" then
			data.oneTimeClaimed = {}
		end
		data.oneTimeClaimed[questId] = true
		if questId == STARTER_QUEST_ID then
			setStarterQuestState(player, STARTER_QUEST_STATE_COMPLETED)
		end
	end
	saveQuestData(player, data)
	log(string.format("[DailyQuest] quest=%s claimed=true deactivated=true", tostring(questId)))
	log(string.format("[DailyQuest] quest=%s trackerStopped=true", tostring(questId)))
	if questId == STARTER_QUEST_ID then
		log(string.format(
			"[StarterQuest] player=%s rewardGranted=%d reason=%s",
			player.Name,
			tonumber(extra.actualAmount) or (tonumber(reward.amount) or 0),
			STARTER_QUEST_REWARD_REASON
		))
	end

	if updateRemote then
		updateRemote:FireClient(player, DailyQuestService.GetStatus(player))
	end

	log(string.format("%s claimed %s (reward: %s)",
		player.Name, questId, DailyQuestConfig.GetRewardLabel(reward)))
	log(string.format("[DailyQuestGrant] player=%s result=SUCCESS", player.Name))

	if reward.type == "Coins" and type(extra.actualAmount) == "number" then
		local rewardPayload = table.clone(reward)
		rewardPayload.amount = extra.actualAmount
		reward = rewardPayload
	end

	return { success = true, reward = reward, extra = extra }
end

-- Debug commands (Studio-only)

function DailyQuestService.DebugForceNewDay()
	_cachedDay    = ""
	_cachedQuests = {}
	_cachedById   = {}
	log(string.format("[DEBUG] Forced new-day cache clear (offset=%d)", _studioDayOffsetDays))
	for _, player in ipairs(Players:GetPlayers()) do
		local PDS = getPDS()
		if PDS and PDS.IsLoaded(player) then
			PDS.SetField(player, "DailyQuestData", "")
		end
	end
end

function DailyQuestService.DebugForceNextDay()
	if not RunService:IsStudio() then return end
	_studioDayOffsetDays += 1
	DailyQuestService.DebugForceNewDay()
	log(string.format("[DEBUG] Forced next day (offset now %d)", _studioDayOffsetDays))
end

function DailyQuestService.DebugForceRandomQuests()
	if not RunService:IsStudio() then return end
	local rng = Random.new()
	_studioDayOffsetDays = rng:NextInteger(1, 3650)
	DailyQuestService.DebugForceNewDay()
	log(string.format("[DEBUG] Forced random quest day (offset now %d)", _studioDayOffsetDays))
end

function DailyQuestService.DebugResetProgress(player: Player)
	local PDS = getPDS()
	if PDS then
		PDS.SetField(player, "DailyQuestData", "")
		PDS.SetField(player, "StarterQuestState", STARTER_QUEST_STATE_UNCLASSIFIED)
		_starterQuestAssignedLoggedByUserId[player.UserId] = nil
		_lastQuestPayloadSignatureByUserId[player.UserId] = nil
		log("[DEBUG] Reset quest progress for " .. player.Name)
		if updateRemote then
			updateRemote:FireClient(player, DailyQuestService.GetStatus(player))
		end
	end
end

function DailyQuestService.DebugCompleteQuest(player: Player, questId: string)
	local PDS = getPDS()
	if not PDS or not PDS.IsLoaded(player) then return end
	local starterQuestState = resolveStarterQuestState(player)
	local data = ensureQuestData(player, starterQuestState)
	local qdef = if questId == STARTER_QUEST_ID and STARTER_QUEST then STARTER_QUEST else getTodayQuestById(questId)
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

	local existingAction = remotes:FindFirstChild("DailyQuest_Action")
	if existingAction and not existingAction:IsA("RemoteEvent") then
		warn(string.format(
			"[DailyQuestService] DailyQuest_Action had wrong class=%s, recreating as RemoteEvent",
			existingAction.ClassName
		))
		existingAction:Destroy()
		existingAction = nil
	end
	if not existingAction then
		actionRemote = Instance.new("RemoteEvent")
		actionRemote.Name = "DailyQuest_Action"
		actionRemote.Parent = remotes
	else
		actionRemote = existingAction
	end
	if actionRemote then
		actionRemote.OnServerEvent:Connect(function(player, actionName)
			if type(actionName) ~= "string" then
				log(string.format("[QuestAction] player=%s action=invalid_type", player.Name))
				return
			end
			log(string.format("[QuestAction] player=%s action=%s result=received", player.Name, actionName))
			if actionName == "IndexOpened" then
				DailyQuestService.OnIndexOpened(player)
			end
		end)
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
			elseif cmd == "ForceNextDay" then
				DailyQuestService.DebugForceNextDay()
				return { ok = true, msg = "Next day forced (new quest set)" }
			elseif cmd == "ForceRandomQuests" then
				DailyQuestService.DebugForceRandomQuests()
				return { ok = true, msg = "Random quest day forced (new quest set)" }
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
		_starterQuestAssignedLoggedByUserId[player.UserId] = nil
		_lastQuestPayloadSignatureByUserId[player.UserId] = nil
		_starterJoinTraceLoggedByUserId[player.UserId] = nil
		task.spawn(function()
			while player.Parent do
				local PDS = getPDS()
				if PDS and PDS.IsLoaded(player) then
					task.wait(1)
					if player.Parent and updateRemote then
						local status = DailyQuestService.GetStatus(player)
						updateRemote:FireClient(player, status)
						local _, starterPresent, payloadSummary = buildQuestPayloadSummary(status.quests or {})
						log(string.format(
							"[StarterQuestReplication] player=%s source=PlayerAdded payloadStarterPresent=%s payloadQuests=%s",
							player.Name,
							tostring(starterPresent),
							payloadSummary
						))
					end
					return
				end
				task.wait(0.5)
			end
		end)
	end)

	Players.PlayerRemoving:Connect(function(player)
		_singleMatchParticipantByUserId[player.UserId] = nil
		_singleMatchSurvivalRoundsByUserId[player.UserId] = nil
		_lastQuestPayloadSignatureByUserId[player.UserId] = nil
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
		_starterJoinTraceLoggedByUserId[player.UserId] = nil
		task.spawn(function()
			while player.Parent do
				local PDS = getPDS()
				if PDS and PDS.IsLoaded(player) then
					task.wait(0.25)
					if player.Parent and updateRemote then
						local status = DailyQuestService.GetStatus(player)
						updateRemote:FireClient(player, status)
						local _, starterPresent, payloadSummary = buildQuestPayloadSummary(status.quests or {})
						log(string.format(
							"[StarterQuestReplication] player=%s source=InitBackfillExistingPlayer payloadStarterPresent=%s payloadQuests=%s",
							player.Name,
							tostring(starterPresent),
							payloadSummary
						))
					end
					return
				end
				task.wait(0.25)
			end
		end)
	end

	log("Initialized -- " .. #getTodayQuests() .. " quests active today")
end

return DailyQuestService
