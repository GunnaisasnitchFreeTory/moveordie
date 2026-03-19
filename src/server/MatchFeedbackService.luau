local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Server = ServerScriptService:WaitForChild("Server")

local FeedbackConfig = require(Shared:WaitForChild("FeedbackConfig"))
local EconomyService = require(Server:WaitForChild("EconomyService"))
local PlayerState = require(Shared:WaitForChild("PlayerState"))
local PlayerStateService = require(Server:WaitForChild("PlayerStateService"))
local ItemCatalog = require(Shared:WaitForChild("ItemCatalog"))
local UIConfig = require(Shared:WaitForChild("UIConfig"))
local ProgressionGoalResolver = require(Shared:WaitForChild("ProgressionGoalResolver"))

local MatchFeedbackService = {}

local initialized = false
local announcementRemote: RemoteEvent? = nil
local firstMatchTipTriggerRemote: RemoteEvent? = nil
local currentMatchMode = "Normal"
local firstMatchPlayers: { [number]: boolean } = {}
local firstMatchTipCounts: { [number]: { [string]: number } } = {}
local firstMatchTipTriggerCooldowns: { [number]: { [string]: number } } = {}
local round6BonusGranted: { [number]: boolean } = {}
local narrowDodgeGrantedByPlayer: { [number]: { [number]: boolean } } = {}
local pendingPostStrikeAnnouncements: { [number]: { [number]: { player: Player, payload: { [string]: any } } } } = {}
local announcedQuestCompletions: { [number]: { [string]: boolean } } = {}
local questProgressSessionStateByUserId: { [number]: { [string]: { lastProgress: number, lastAnnouncedProgress: number, lastAnnouncedAt: number, closeAnnounced: boolean } } } = {}
local progressionStateByUserId: { [number]: { lastAffordableCrateId: string, lastAffordableUnlockId: string, pendingCrate: { [string]: any }?, pendingUnlock: { [string]: any }? } } = {}
local progressionNudgeCooldowns: { [number]: { [string]: number } } = {}
local questReminderNextAtByUserId: { [number]: number } = {}

local _PDS = nil
local _DQS = nil
local function getPDS()
	if _PDS ~= nil then
		return _PDS
	end
	local ok, mod = pcall(require, Server:FindFirstChild("PlayerDataService"))
	if ok and mod then
		_PDS = mod
	else
		_PDS = false
	end
	return _PDS
end

local function getDQS()
	if _DQS ~= nil then
		return _DQS
	end
	local ok, mod = pcall(require, Server:FindFirstChild("DailyQuestService"))
	if ok and mod then
		_DQS = mod
	else
		_DQS = false
	end
	return _DQS
end

local function log(message: string)
	print("[MatchFeedbackService] " .. message)
end

local FIRST_MATCH_TIP_MAX_PER_KIND = 2
local FIRST_MATCH_TIP_TRIGGER_DEBOUNCE_SECONDS = 6
local PROGRESSION_SCAN_SECONDS = 5
local PROGRESSION_NUDGE_COOLDOWN_SECONDS = 75
local PROGRESSION_CRATE_REMINDER_SECONDS = 240
local MAX_FIRST_MATCH_TIP_MATCHES = 2
local QUEST_REMINDER_INTERVAL_SECONDS = 120

local function getTipCountState(player: Player): { [string]: number }
	local userId = player.UserId
	local tipState = firstMatchTipCounts[userId]
	if tipState then
		return tipState
	end
	tipState = {
		sword_tip = 0,
		coin_tip = 0,
		beam_tip = 0,
	}
	firstMatchTipCounts[userId] = tipState
	return tipState
end

local function getTipTriggerCooldownState(player: Player): { [string]: number }
	local userId = player.UserId
	local state = firstMatchTipTriggerCooldowns[userId]
	if state then
		return state
	end
	state = {}
	firstMatchTipTriggerCooldowns[userId] = state
	return state
end

local function queueAnnouncement(player: Player, payload: { [string]: any }, source: string): boolean
	if not player or not player.Parent then
		log(string.format("announcement_skipped reason=missing_player source=%s", source))
		return false
	end
	if not announcementRemote then
		log(string.format("announcement_skipped reason=remote_missing source=%s player=%s", source, player.Name))
		return false
	end
	announcementRemote:FireClient(player, payload)
	log(string.format("announcement_queued source=%s player=%s text=%s", source, player.Name, tostring(payload.text or "")))
	return true
end

local function buildAnnouncementPayload(text: string, style: string, priority: number, durationSeconds: number, dedupeKey: string, cooldownSeconds: number, requiresInMatch: boolean?): { [string]: any }
	return {
		text = text,
		style = style,
		priority = priority,
		durationSeconds = durationSeconds,
		dedupeKey = dedupeKey,
		cooldownSeconds = cooldownSeconds,
		requiresInMatch = requiresInMatch == true,
	}
end

local function getQuestProgressSessionState(player: Player): { [string]: { lastProgress: number, lastAnnouncedProgress: number, lastAnnouncedAt: number, closeAnnounced: boolean } }
	local state = questProgressSessionStateByUserId[player.UserId]
	if state then
		return state
	end
	state = {}
	questProgressSessionStateByUserId[player.UserId] = state
	return state
end

local function getQuestAnnouncementName(questDef: { [string]: any }): string
	local label = tostring(questDef.label or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if label ~= "" then
		return label
	end
	return formatQuestObjective(questDef)
end

local function awardBonus(player: Player, amount: number, reason: string): number
	local awardedOk, actualAmount = EconomyService.AwardCoins(player, amount, reason, true)
	if not awardedOk then
		return 0
	end
	local finalAmount = tonumber(actualAmount) or amount
	EconomyService.TrackMatchCoins(player, finalAmount)
	return finalAmount
end

local function getMatchState(): string
	local folder = ReplicatedStorage:FindFirstChild("MatchStatus")
	if not folder then
		return "Intermission"
	end
	local valueObj = folder:FindFirstChild("State")
	if valueObj and valueObj:IsA("StringValue") and valueObj.Value ~= "" then
		return valueObj.Value
	end
	return "Intermission"
end

local function isProgressionNudgeSafeState(player: Player): boolean
	local playerState = PlayerStateService.GetState(player)
	local matchState = getMatchState()
	if playerState == PlayerState.States.Waiting then
		return true
	end
	return matchState == "Intermission" and playerState == PlayerState.States.Lobby
end

local function getProgressionState(player: Player): { lastAffordableCrateId: string, lastAffordableUnlockId: string, pendingCrate: { [string]: any }?, pendingUnlock: { [string]: any }? }
	local userId = player.UserId
	local state = progressionStateByUserId[userId]
	if state then
		return state
	end
	state = {
		lastAffordableCrateId = "",
		lastAffordableUnlockId = "",
		pendingCrate = nil,
		pendingUnlock = nil,
	}
	progressionStateByUserId[userId] = state
	return state
end

local function isProgressionNudgeCoolingDown(player: Player, key: string): boolean
	local now = os.clock()
	local perPlayer = progressionNudgeCooldowns[player.UserId]
	if not perPlayer then
		return false
	end
	local expiry = perPlayer[key]
	return expiry ~= nil and expiry > now
end

local function setProgressionNudgeCooldown(player: Player, key: string)
	local perPlayer = progressionNudgeCooldowns[player.UserId]
	if not perPlayer then
		perPlayer = {}
		progressionNudgeCooldowns[player.UserId] = perPlayer
	end
	perPlayer[key] = os.clock() + PROGRESSION_NUDGE_COOLDOWN_SECONDS
end

local function resolveCheapestAffordableCrate(coins: number): { id: string, name: string, price: number }?
	local best = nil
	for _, crate in ipairs(UIConfig.MockCrates or {}) do
		local cheapest = nil
		for _, price in ipairs(crate.prices or {}) do
			if price.currency == "Coins" then
				local cost = math.max(0, math.floor(tonumber(price.cost) or 0))
				if cost > 0 and (not cheapest or cost < cheapest) then
					cheapest = cost
				end
			end
		end
		if cheapest and coins >= cheapest then
			local candidate = { id = tostring(crate.id or ""), name = tostring(crate.name or "Crate"), price = cheapest }
			if candidate.id ~= "" then
				if not best or candidate.price < best.price or (candidate.price == best.price and candidate.id < best.id) then
					best = candidate
				end
			end
		end
	end
	return best
end

local function normalizeOwnedSet(value: any): { [string]: boolean }
	local set = {}
	if type(value) ~= "table" then
		return set
	end
	for _, entry in ipairs(value) do
		if type(entry) == "string" and entry ~= "" then
			set[entry] = true
		end
	end
	return set
end

local function resolveAffordableUnlockGoal(coins: number, ownedCrowns: any, ownedPets: any, ownedIconImages: any): { id: string, name: string, category: string, price: number }?
	local best = nil
	local resolved = ProgressionGoalResolver.Resolve({
		coins = coins,
		ownedCrowns = ownedCrowns,
		ownedPets = ownedPets,
	})
	if resolved and resolved.remainingCoins <= 0 then
		local category = (resolved.type == "Pet" or resolved.type == "ExclusivePet") and "pet" or "crown"
		best = {
			id = tostring(resolved.id),
			name = tostring(resolved.name),
			category = category,
			price = math.max(0, math.floor(tonumber(resolved.price) or 0)),
		}
	end

	local ownedIconSet = normalizeOwnedSet(ownedIconImages)
	for iconId, iconDef in pairs(ItemCatalog.IconImages or {}) do
		local price = tonumber(iconDef.fateCoins)
		if type(iconId) == "string" and iconId ~= "" and price and price > 0 and not ownedIconSet[iconId] and coins >= price then
			local candidate = {
				id = iconId,
				name = tostring(iconDef.name or iconId),
				category = "icon",
				price = math.max(0, math.floor(price)),
			}
			if not best or candidate.price < best.price or (candidate.price == best.price and candidate.id < best.id) then
				best = candidate
			end
		end
	end

	return best
end

local function maybeQueueProgressionNudge(player: Player, payload: { [string]: any }, key: string, source: string, stateSafe: boolean, reason: string): boolean
	if not stateSafe then
		log(string.format("progression_nudge_deferred player=%s key=%s reason=%s", player.Name, key, reason))
		return false
	end
	if isProgressionNudgeCoolingDown(player, key) then
		log(string.format("progression_nudge_skipped player=%s key=%s reason=cooldown", player.Name, key))
		return false
	end
	local queued = queueAnnouncement(player, payload, source)
	if queued then
		setProgressionNudgeCooldown(player, key)
	end
	return queued
end

local function getActiveQuestCountForReminder(player: Player): number
	local dqs = getDQS()
	if not dqs or type(dqs.GetStatus) ~= "function" then
		return 0
	end
	local ok, status = pcall(dqs.GetStatus, player)
	if not ok or type(status) ~= "table" or status.dataLoaded ~= true then
		return 0
	end
	local quests = status.quests
	if type(quests) ~= "table" then
		return 0
	end
	return #quests
end

local function maybeQueueQuestReminder(player: Player, source: string)
	if not player or not player.Parent then
		return
	end
	if not isProgressionNudgeSafeState(player) then
		return
	end

	local now = os.clock()
	local nextAt = questReminderNextAtByUserId[player.UserId] or 0
	if now < nextAt then
		return
	end

	local activeQuestCount = getActiveQuestCountForReminder(player)
	questReminderNextAtByUserId[player.UserId] = now + QUEST_REMINDER_INTERVAL_SECONDS
	if activeQuestCount <= 0 then
		return
	end

	local payload = buildAnnouncementPayload(
		string.format("You have %d quest%s to complete.", activeQuestCount, activeQuestCount == 1 and "" or "s"),
		"Tip",
		FeedbackConfig.Announcements.Priorities.Tip,
		FeedbackConfig.Announcements.TipDisplayDurationSeconds,
		string.format("quest_reminder:%d:%d", player.UserId, math.floor(now / QUEST_REMINDER_INTERVAL_SECONDS)),
		2,
		false
	)
	queueAnnouncement(player, payload, "QuestReminder:" .. source)
	log(string.format(
		"quest_reminder player=%s activeQuestCount=%d source=%s interval=%ds",
		player.Name,
		activeQuestCount,
		source,
		QUEST_REMINDER_INTERVAL_SECONDS
	))
end

local function evaluateProgressionNudges(player: Player, source: string)
	if not player or not player.Parent then
		return
	end
	local PDS = getPDS()
	if not PDS or not PDS.IsLoaded(player) then
		return
	end

	local coins = math.max(0, math.floor(tonumber(PDS.GetField(player, "Coins")) or 0))
	local ownedCrowns = PDS.GetField(player, "OwnedCrowns")
	local ownedPets = PDS.GetField(player, "OwnedPets")
	local ownedIconImages = PDS.GetField(player, "OwnedIconImages")
	local stateSafe = isProgressionNudgeSafeState(player)
	local playerState = PlayerStateService.GetState(player)
	local matchState = getMatchState()
	local state = getProgressionState(player)

	local crateGoal = resolveCheapestAffordableCrate(coins)
	if crateGoal then
		local payload = buildAnnouncementPayload(
			"You can afford a crate now! Check the Crate Shop.",
			"Tip",
			FeedbackConfig.Announcements.Priorities.Tip,
			FeedbackConfig.Announcements.TipDisplayDurationSeconds,
			"progression_crate_" .. crateGoal.id,
			PROGRESSION_CRATE_REMINDER_SECONDS,
			false
		)
		local queued = maybeQueueProgressionNudge(player, payload, "crate_affordability_reminder", "ProgressionCrate", stateSafe, "unsafe_state")
		log(string.format(
			"progression_check player=%s coins=%d category=crate detected=%s chosen=%s playerState=%s matchState=%s queued=%s deferred=%s source=%s",
			player.Name,
			coins,
			tostring(crateGoal.id),
			crateGoal.name,
			tostring(playerState),
			tostring(matchState),
			tostring(queued),
			tostring(not stateSafe),
			source
		))
		if queued then
			state.pendingCrate = nil
		elseif not stateSafe then
			state.pendingCrate = { id = crateGoal.id, name = crateGoal.name, price = crateGoal.price }
		else
			state.pendingCrate = nil
		end
	end
	state.lastAffordableCrateId = crateGoal and crateGoal.id or ""

	local unlockGoal = resolveAffordableUnlockGoal(coins, ownedCrowns, ownedPets, ownedIconImages)
	if unlockGoal and unlockGoal.id ~= state.lastAffordableUnlockId then
		local payload = buildAnnouncementPayload(
			string.format("You unlocked a new %s you can buy! Check the shop UI.", unlockGoal.category),
			"Tip",
			FeedbackConfig.Announcements.Priorities.Tip,
			FeedbackConfig.Announcements.TipDisplayDurationSeconds,
			"progression_unlock_" .. unlockGoal.id,
			35,
			false
		)
		local queued = maybeQueueProgressionNudge(player, payload, "unlock:" .. unlockGoal.id, "ProgressionUnlock", stateSafe, "unsafe_state")
		log(string.format(
			"progression_check player=%s coins=%d category=unlock detected=%s chosen=%s playerState=%s matchState=%s queued=%s deferred=%s source=%s",
			player.Name,
			coins,
			tostring(unlockGoal.category),
			tostring(unlockGoal.id),
			tostring(playerState),
			tostring(matchState),
			tostring(queued),
			tostring(not stateSafe),
			source
		))
		if queued then
			state.pendingUnlock = nil
		else
			state.pendingUnlock = { id = unlockGoal.id, category = unlockGoal.category, price = unlockGoal.price }
		end
	end
	state.lastAffordableUnlockId = unlockGoal and unlockGoal.id or ""

	if stateSafe and state.pendingCrate and crateGoal then
		local pending = state.pendingCrate
		local payload = buildAnnouncementPayload(
			"You can afford a crate now! Check the Crate Shop.",
			"Tip",
			FeedbackConfig.Announcements.Priorities.Tip,
			FeedbackConfig.Announcements.TipDisplayDurationSeconds,
			"progression_crate_" .. tostring(pending.id),
			PROGRESSION_CRATE_REMINDER_SECONDS,
			false
		)
		local queued = maybeQueueProgressionNudge(player, payload, "crate_affordability_reminder", "ProgressionCrateDeferred", true, "state_safe")
		if queued then
			state.pendingCrate = nil
		end
	elseif not crateGoal then
		state.pendingCrate = nil
	end

	if stateSafe and state.pendingUnlock then
		local pending = state.pendingUnlock
		local payload = buildAnnouncementPayload(
			string.format("You unlocked a new %s you can buy! Check the shop UI.", tostring(pending.category)),
			"Tip",
			FeedbackConfig.Announcements.Priorities.Tip,
			FeedbackConfig.Announcements.TipDisplayDurationSeconds,
			"progression_unlock_" .. tostring(pending.id),
			35,
			false
		)
		local queued = maybeQueueProgressionNudge(player, payload, "unlock:" .. tostring(pending.id), "ProgressionUnlockDeferred", true, "state_safe")
		if queued then
			state.pendingUnlock = nil
		end
	end
end

local function isPlayerFirstMatchEligible(player: Player): boolean
	local PDS = getPDS()
	if not PDS or not PDS.IsLoaded(player) then
		return false
	end

	local servedMatches = math.max(0, math.floor(tonumber(PDS.GetField(player, "FirstMatchTipMatchesServed")) or 0))
	if servedMatches >= MAX_FIRST_MATCH_TIP_MATCHES then
		log(string.format(
			"first_match_check player=%s override=false reason=served_match_cap servedMatches=%d eligible=false",
			player.Name,
			servedMatches
		))
		return false
	end

	local debugConfig = FeedbackConfig.Debug or {}
	local forceByAttribute = player:GetAttribute("DebugForceOnboardingTips") == true
	local forceInStudio = RunService:IsStudio() and debugConfig.ForceFirstMatchTipsInStudio == true
	local forceByUserId = false
	local allowlist = debugConfig.ForceFirstMatchTipsUserIds
	if type(allowlist) == "table" then
		for _, userId in ipairs(allowlist) do
			if tonumber(userId) == player.UserId then
				forceByUserId = true
				break
			end
		end
	end
	if forceByAttribute or forceInStudio or forceByUserId then
		log(string.format(
			"first_match_check player=%s override=true reason=%s servedMatches=%d eligible=true",
			player.Name,
			if forceByAttribute then "debug_force_attribute" else if forceInStudio then "debug_force_studio" else "debug_force_userid",
			servedMatches
		))
		return true
	end

	local lifetimeMatchesCompleted = tonumber(PDS.GetField(player, "LifetimeMatchesCompleted")) or 0
	local tipsShown = PDS.GetField(player, "FirstMatchTipsShown") == true
	local eligible = lifetimeMatchesCompleted <= 1 and servedMatches < MAX_FIRST_MATCH_TIP_MATCHES
	log(string.format(
		"first_match_check player=%s lifetimeMatchesCompleted=%d tipsShown=%s servedMatches=%d eligible=%s",
		player.Name,
		lifetimeMatchesCompleted,
		tostring(tipsShown),
		servedMatches,
		tostring(eligible)
	))
	return eligible
end

local function formatQuestObjective(questDef: { [string]: any }): string
	local questId = tostring(questDef.id or "")
	local questType = tostring(questDef.type or "")
	local target = math.max(1, math.floor(tonumber(questDef.target) or 1))

	if questId == "starter_survive_1_round" or questType == "StarterSurviveRound" then
		return "SURVIVE 1 ROUND"
	elseif questType == "TimePlayed" then
		local minutes = math.max(1, math.floor(target / 60 + 0.5))
		return string.format("PLAY FOR %d MINUTE%s", minutes, minutes == 1 and "" or "S")
	elseif questType == "WinsToday" then
		return string.format("WIN %d MATCH%s", target, target == 1 and "" or "ES")
	elseif questType == "SwordKillsToday" then
		return string.format("GET %d SWORD KILL%s", target, target == 1 and "" or "S")
	elseif questType == "EliminationsToday" then
		return string.format("ELIMINATE %d PLAYER%s", target, target == 1 and "" or "S")
	elseif questType == "SurviveRoundsToday" then
		return string.format("SURVIVE %d ROUND%s", target, target == 1 and "" or "S")
	elseif questType == "TTSSurvivalsToday" then
		return string.format("SURVIVE TUNGTUNG %d TIME%s", target, target == 1 and "" or "S")
	elseif questType == "BrainrotIShowSpeedPickupsToday" then
		return string.format("PICK UP ISHOWSPEED %d TIME%s", target, target == 1 and "" or "S")
	elseif questType == "SurviveRoundsSingleMatch12" or questType == "SurviveRoundsSingleMatch15" then
		return string.format("SURVIVE %d ROUNDS IN ONE MATCH", target)
	end

	local rawLabel = tostring(questDef.description or questDef.label or questId)
	rawLabel = rawLabel:gsub("(%l)(%u)", "%1 %2")
	rawLabel = rawLabel:gsub("(%u)(%u%l)", "%1 %2")
	rawLabel = rawLabel:gsub("_", " ")
	rawLabel = rawLabel:gsub("%.?%s*[Rr]eward:%s*.+$", "")
	rawLabel = rawLabel:gsub("%s+", " ")
	rawLabel = rawLabel:gsub("^%s+", ""):gsub("%s+$", "")
	return string.upper(rawLabel)
end

local function queueFirstMatchTip(player: Player, tipConfig: { [string]: any }, source: string, reason: string, triggerKey: string?)
	local eligible = firstMatchPlayers[player.UserId] == true
	if not eligible then
		log(string.format(
			"first_match_tip_check player=%s eligible=%s tip=%s reason=%s count=%d queued=false skip=ineligible source=%s",
			player.Name,
			tostring(eligible),
			tostring(tipConfig.id),
			reason,
			0,
			source
		))
		return
	end

	local tipState = getTipCountState(player)
	local currentCount = tipState[tipConfig.id] or 0
	if currentCount >= FIRST_MATCH_TIP_MAX_PER_KIND then
		log(string.format(
			"first_match_tip_check player=%s eligible=%s tip=%s reason=%s count=%d queued=false skip=cap source=%s",
			player.Name,
			tostring(eligible),
			tostring(tipConfig.id),
			reason,
			currentCount,
			source
		))
		return
	end

	if type(triggerKey) == "string" and triggerKey ~= "" then
		local cooldownState = getTipTriggerCooldownState(player)
		local now = os.clock()
		local key = tipConfig.id .. ":" .. triggerKey
		local expiry = cooldownState[key]
		if expiry and expiry > now then
			log(string.format(
				"first_match_tip_check player=%s eligible=%s tip=%s reason=%s count=%d queued=false skip=trigger_dedupe source=%s",
				player.Name,
				tostring(eligible),
				tostring(tipConfig.id),
				reason,
				currentCount,
				source
			))
			return
		end
		cooldownState[key] = now + FIRST_MATCH_TIP_TRIGGER_DEBOUNCE_SECONDS
	end

	local queued = queueAnnouncement(player, buildAnnouncementPayload(
		tipConfig.text,
		"Tip",
		tonumber(tipConfig.priority) or FeedbackConfig.Announcements.Priorities.Tip,
		tonumber(tipConfig.durationSeconds) or FeedbackConfig.Announcements.TipDisplayDurationSeconds,
		"first_match_tip:" .. tostring(tipConfig.id) .. ":" .. tostring(currentCount + 1),
		3,
		true
	), source)
	if queued then
		tipState[tipConfig.id] = currentCount + 1
	end
	log(string.format(
		"first_match_tip_check player=%s eligible=%s tip=%s reason=%s count=%d queued=%s source=%s",
		player.Name,
		tostring(eligible),
		tostring(tipConfig.id),
		reason,
		tipState[tipConfig.id] or currentCount,
		tostring(queued),
		source
	))
end

function MatchFeedbackService.Init()
	if initialized then
		return
	end
	initialized = true

	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		remotes = Instance.new("Folder")
		remotes.Name = "Remotes"
		remotes.Parent = ReplicatedStorage
	end

	local existing = remotes:FindFirstChild("PlayerAnnouncement")
	if existing and existing:IsA("RemoteEvent") then
		announcementRemote = existing
	else
		announcementRemote = Instance.new("RemoteEvent")
		announcementRemote.Name = "PlayerAnnouncement"
		announcementRemote.Parent = remotes
	end

	local triggerExisting = remotes:FindFirstChild("FirstMatchTipTrigger")
	if triggerExisting and triggerExisting:IsA("RemoteEvent") then
		firstMatchTipTriggerRemote = triggerExisting
	else
		firstMatchTipTriggerRemote = Instance.new("RemoteEvent")
		firstMatchTipTriggerRemote.Name = "FirstMatchTipTrigger"
		firstMatchTipTriggerRemote.Parent = remotes
	end

	if firstMatchTipTriggerRemote then
		firstMatchTipTriggerRemote.OnServerEvent:Connect(function(player, payload)
			if type(payload) ~= "table" then
				return
			end
			local triggerType = tostring(payload.type or "")
			if triggerType == "SwordProximity" then
				MatchFeedbackService.OnSwordProximity(player, tostring(payload.token or ""))
			end
		end)
	end

	Players.PlayerRemoving:Connect(function(player)
		firstMatchPlayers[player.UserId] = nil
		firstMatchTipCounts[player.UserId] = nil
		firstMatchTipTriggerCooldowns[player.UserId] = nil
		round6BonusGranted[player.UserId] = nil
		narrowDodgeGrantedByPlayer[player.UserId] = nil
		announcedQuestCompletions[player.UserId] = nil
		questProgressSessionStateByUserId[player.UserId] = nil
		progressionStateByUserId[player.UserId] = nil
		progressionNudgeCooldowns[player.UserId] = nil
		questReminderNextAtByUserId[player.UserId] = nil
		for _, byUserId in pairs(pendingPostStrikeAnnouncements) do
			byUserId[player.UserId] = nil
		end
	end)

	PlayerStateService.OnStateChanged(function(player)
		evaluateProgressionNudges(player, "PlayerStateChanged")
		maybeQueueQuestReminder(player, "PlayerStateChanged")
	end)

	task.spawn(function()
		while initialized do
			task.wait(PROGRESSION_SCAN_SECONDS)
			for _, player in ipairs(Players:GetPlayers()) do
				evaluateProgressionNudges(player, "Periodic")
				maybeQueueQuestReminder(player, "Periodic")
			end
		end
	end)

	log("initialized")
end

function MatchFeedbackService.OnMatchStart(players: { Player }, modeName: string?)
	currentMatchMode = if type(modeName) == "string" and modeName ~= "" then modeName else "Normal"
	firstMatchPlayers = {}
	firstMatchTipCounts = {}
	firstMatchTipTriggerCooldowns = {}
	round6BonusGranted = {}
	narrowDodgeGrantedByPlayer = {}
	pendingPostStrikeAnnouncements = {}

	for _, player in ipairs(players) do
		if player and player.Parent and isPlayerFirstMatchEligible(player) then
			firstMatchPlayers[player.UserId] = true
			firstMatchTipCounts[player.UserId] = {
				sword_tip = 0,
				coin_tip = 0,
				beam_tip = 0,
			}
			firstMatchTipTriggerCooldowns[player.UserId] = {}
			local PDS = getPDS()
			if PDS and PDS.IsLoaded(player) then
				local servedMatches = math.max(0, math.floor(tonumber(PDS.GetField(player, "FirstMatchTipMatchesServed")) or 0))
				local nextServedMatches = math.min(MAX_FIRST_MATCH_TIP_MATCHES, servedMatches + 1)
				PDS.SetField(player, "FirstMatchTipMatchesServed", nextServedMatches)
				PDS.SetField(player, "FirstMatchTipsShown", nextServedMatches >= 1)
				log(string.format(
					"first_match_window_progress player=%s servedMatches=%d/%d",
					player.Name,
					nextServedMatches,
					MAX_FIRST_MATCH_TIP_MATCHES
				))
			end
			log(string.format("first_match_player_detected player=%s mode=%s", player.Name, currentMatchMode))
		end
		evaluateProgressionNudges(player, "MatchStart")
	end
end

function MatchFeedbackService.OnMatchEnd()
	firstMatchPlayers = {}
	firstMatchTipCounts = {}
	firstMatchTipTriggerCooldowns = {}
	round6BonusGranted = {}
	narrowDodgeGrantedByPlayer = {}
	pendingPostStrikeAnnouncements = {}
	currentMatchMode = "Normal"
	log("match_feedback_cleared")
end

function MatchFeedbackService.OnRoundStart(roundNumber: number, modeName: string?)
	if type(modeName) == "string" and modeName ~= "" then
		currentMatchMode = modeName
	end
end

function MatchFeedbackService.OnTelegraphShown(roundNumber: number)
	-- Kept for compatibility; beam tip now triggers after surviving round 1.
end

function MatchFeedbackService.OnSwordSpawn(players: { Player }?)
	-- Kept for compatibility; sword tip now triggers on sword proximity.
	if players then
		return
	end
end

function MatchFeedbackService.OnSwordProximity(player: Player, swordToken: string?)
	if not player or not player.Parent then
		return
	end
	local token = tostring(swordToken or "")
	queueFirstMatchTip(
		player,
		FeedbackConfig.FirstMatchTips.SwordTip,
		"SwordProximity",
		"near_sword_pickup",
		token ~= "" and token or "no_token"
	)
end

function MatchFeedbackService.OnCoinCollected(player: Player, coinType: string?, baseCoinValue: number?)
	if not player or not player.Parent then
		return
	end
	local triggerKey = string.format("%s_%d", tostring(coinType or ""), math.max(0, math.floor(tonumber(baseCoinValue) or 0)))
	queueFirstMatchTip(
		player,
		FeedbackConfig.FirstMatchTips.CoinTip,
		"CoinCollected",
		"coin_collected",
		triggerKey
	)
end

function MatchFeedbackService.OnQuestCompleted(player: Player, questDef: { [string]: any })
	if not player or not player.Parent or type(questDef) ~= "table" then
		return
	end

	local questId = tostring(questDef.id or "")
	if questId == "" then
		return
	end

	local announcedForPlayer = announcedQuestCompletions[player.UserId]
	if not announcedForPlayer then
		announcedForPlayer = {}
		announcedQuestCompletions[player.UserId] = announcedForPlayer
	end
	if announcedForPlayer[questId] == true then
		log(string.format("quest_announcement_skipped reason=deduped player=%s quest=%s", player.Name, questId))
		return
	end

	announcedForPlayer[questId] = true
	queueAnnouncement(player, buildAnnouncementPayload(
		"QUEST COMPLETE: " .. formatQuestObjective(questDef),
		"Quest",
		FeedbackConfig.Announcements.Priorities.Quest,
		FeedbackConfig.Announcements.DisplayDurationSeconds,
		"quest_complete:" .. questId,
		30,
		false
	), "QuestComplete")
	log(string.format("quest_completion_queued player=%s quest=%s", player.Name, questId))
end

function MatchFeedbackService.OnQuestProgressUpdated(player: Player, questDef: { [string]: any }, currentProgress: number, targetProgress: number)
	if not player or not player.Parent or type(questDef) ~= "table" then
		return
	end

	local questId = tostring(questDef.id or "")
	if questId == "" then
		return
	end

	local target = math.max(1, math.floor(tonumber(targetProgress) or tonumber(questDef.target) or 1))
	local current = math.max(0, math.floor(tonumber(currentProgress) or 0))
	if current <= 0 or current >= target then
		return
	end

	local perQuestState = getQuestProgressSessionState(player)
	local state = perQuestState[questId]
	if not state then
		state = {
			lastProgress = 0,
			lastAnnouncedProgress = 0,
			lastAnnouncedAt = 0,
			closeAnnounced = false,
		}
		perQuestState[questId] = state
	end
	if current <= state.lastProgress then
		return
	end
	state.lastProgress = current

	local now = os.clock()
	local questName = getQuestAnnouncementName(questDef)
	local progressRatio = current / target
	if progressRatio >= 0.5 and progressRatio < 1 and not state.closeAnnounced then
		local queuedClose = queueAnnouncement(player, buildAnnouncementPayload(
			string.format("You're very close to completing: %s!", questName),
			"Quest",
			FeedbackConfig.Announcements.Priorities.Quest,
			FeedbackConfig.Announcements.DisplayDurationSeconds,
			"quest_close:" .. questId,
			30,
			false
		), "QuestProgressClose")
		if queuedClose then
			state.closeAnnounced = true
		end
	end

	local minStep = math.max(1, math.floor(target * 0.25))
	local progressedEnough = (current - state.lastAnnouncedProgress) >= minStep
	local isMilestone = current == 1 or current == (target - 1)
	local cooldownPassed = (now - state.lastAnnouncedAt) >= 6
	if (progressedEnough or isMilestone) and cooldownPassed then
		local queuedProgress = queueAnnouncement(player, buildAnnouncementPayload(
			string.format("Quest Progress: %s (%d/%d)", questName, current, target),
			"Quest",
			FeedbackConfig.Announcements.Priorities.Tip,
			FeedbackConfig.Announcements.DisplayDurationSeconds,
			string.format("quest_progress:%s:%d", questId, current),
			2,
			false
		), "QuestProgress")
		if queuedProgress then
			state.lastAnnouncedAt = now
			state.lastAnnouncedProgress = current
		end
	end
end

function MatchFeedbackService.OnNarrowDodge(player: Player, roundNumber: number)
	if not player or not player.Parent then
		return
	end

	local perPlayerRounds = narrowDodgeGrantedByPlayer[player.UserId]
	if not perPlayerRounds then
		perPlayerRounds = {}
		narrowDodgeGrantedByPlayer[player.UserId] = perPlayerRounds
	end
	if perPlayerRounds[roundNumber] == true then
		log(string.format("narrow_dodge_skipped reason=already_rewarded player=%s round=%d", player.Name, roundNumber))
		return
	end

	local finalAmount = awardBonus(player, FeedbackConfig.Rewards.NarrowDodgeBonusCoins, "narrow_dodge_bonus")
	if finalAmount <= 0 then
		log(string.format("narrow_dodge_skipped reason=grant_failed player=%s round=%d", player.Name, roundNumber))
		return
	end

	perPlayerRounds[roundNumber] = true
	pendingPostStrikeAnnouncements[roundNumber] = pendingPostStrikeAnnouncements[roundNumber] or {}
	pendingPostStrikeAnnouncements[roundNumber][player.UserId] = {
		player = player,
		payload = buildAnnouncementPayload(
			string.format("+%d coins for dodging beam", finalAmount),
			"Reward",
			FeedbackConfig.Announcements.Priorities.Reward,
			FeedbackConfig.Announcements.DisplayDurationSeconds,
			string.format("narrow_dodge_bonus:%d:%d", player.UserId, roundNumber),
			15,
			true
		),
	}
	log(string.format("narrow_dodge_rewarded player=%s round=%d amount=%d", player.Name, roundNumber, finalAmount))
end

function MatchFeedbackService.FlushPostStrikeAnnouncements(roundNumber: number)
	local pending = pendingPostStrikeAnnouncements[roundNumber]
	if not pending then
		return
	end
	pendingPostStrikeAnnouncements[roundNumber] = nil

	local flushedCount = 0
	for _, entry in pairs(pending) do
		queueAnnouncement(entry.player, entry.payload, "PostStrike")
		flushedCount += 1
	end
	log(string.format("post_strike_feedback_flushed round=%d count=%d", roundNumber, flushedCount))
end

function MatchFeedbackService.OnRoundSurvived(player: Player, roundNumber: number)
	if not player or not player.Parent then
		return
	end
	if roundNumber == 1 then
		queueFirstMatchTip(
			player,
			FeedbackConfig.FirstMatchTips.BeamTip,
			"RoundSurvived",
			"survived_round_1",
			"round1"
		)
	end
	if roundNumber ~= 6 or round6BonusGranted[player.UserId] == true then
		evaluateProgressionNudges(player, "RoundSurvived")
		return
	end

	local finalAmount = awardBonus(player, FeedbackConfig.Rewards.Round6BonusCoins, "round6_bonus")
	if finalAmount <= 0 then
		log(string.format("round6_bonus_skipped reason=grant_failed player=%s", player.Name))
		return
	end

	round6BonusGranted[player.UserId] = true
	queueAnnouncement(player, buildAnnouncementPayload(
		string.format("Made it to round 6 +%d coins!", finalAmount),
		"Reward",
		FeedbackConfig.Announcements.Priorities.Reward,
		FeedbackConfig.Announcements.DisplayDurationSeconds,
		"round6_bonus:" .. tostring(player.UserId),
		45,
		true
	), "Round6Bonus")
	log(string.format("round6_bonus_rewarded player=%s amount=%d", player.Name, finalAmount))
	evaluateProgressionNudges(player, "Round6Bonus")
end

function MatchFeedbackService.OnSwordElimination(killer: Player, victim: Player)
	if not killer or not killer.Parent or not victim then
		return
	end

	queueAnnouncement(killer, buildAnnouncementPayload(
		string.format("You eliminated %s", victim.Name),
		"Elimination",
		FeedbackConfig.Announcements.Priorities.Elimination,
		FeedbackConfig.Announcements.DisplayDurationSeconds,
		string.format("sword_elimination:%d:%d", killer.UserId, victim.UserId),
		3,
		true
	), "SwordElimination")
	-- Lightweight local-only impact effect trigger handled in AnnouncementController.
	queueAnnouncement(killer, {
		text = "",
		effect = "SwordKillImpact",
		priority = FeedbackConfig.Announcements.Priorities.Elimination,
		durationSeconds = 0.05,
		dedupeKey = string.format("sword_elimination_fx:%d:%d", killer.UserId, victim.UserId),
		cooldownSeconds = 0.25,
		requiresInMatch = true,
	}, "SwordEliminationFx")
	log(string.format("sword_elimination_feedback_queued killer=%s victim=%s", killer.Name, victim.Name))
	evaluateProgressionNudges(killer, "SwordElimination")
end

return MatchFeedbackService
