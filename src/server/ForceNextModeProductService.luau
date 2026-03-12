--[[
	ForceNextModeProductService
	Server-authoritative handling for FORCE NEXT MODE! developer product flow.

	Flow:
	  1) Client requests a prompt for "Normal" or "Brainrot".
	  2) Server validates state, persists the pending intent, and opens the prompt.
	  3) ProcessReceipt calls ConsumePendingReceipt() to enqueue one forced next mode.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Server = ServerScriptService:WaitForChild("Server")

local DeveloperProductConfig = require(Shared:WaitForChild("DeveloperProductConfig"))
local MatchState = require(Shared:WaitForChild("MatchState"))
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local EliminationTracker = require(Server:WaitForChild("EliminationTracker"))

local ForceNextModeProductService = {}

local REQUEST_COOLDOWN_SECONDS = 0.8

type PendingForceNextModeIntent = {
	requestedMode: string,
	createdAt: number,
	availableFromMatchId: number,
}

export type ForceNextModeQueueEntry = {
	requestedMode: string,
	purchaserUserId: number,
	purchaserName: string,
	createdAt: number,
	orderIndex: number,
	receiptKey: string,
	availableFromMatchId: number,
}

local initialized = false
local requestRemote: RemoteEvent? = nil
local matchStatusFolder: Instance? = nil
local stateValue: StringValue? = nil
local voteActiveValue: BoolValue? = nil

local requestCooldownByUserId: { [number]: number } = {}
local forceQueue: { ForceNextModeQueueEntry } = {}
local handledReceiptKeys: { [string]: boolean } = {}
local nextOrderIndex = 0

local function log(message: string)
	print("[ForceNextMode] " .. message)
end

local function isSupportedMode(modeName: any): boolean
	return modeName == "Normal" or modeName == "Brainrot"
end

local function ensureRemotes(): RemoteEvent
	local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotesFolder then
		remotesFolder = Instance.new("Folder")
		remotesFolder.Name = "Remotes"
		remotesFolder.Parent = ReplicatedStorage
	end

	local existing = remotesFolder:FindFirstChild("ForceNextModePromptRequest")
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = "ForceNextModePromptRequest"
	remote.Parent = remotesFolder
	return remote
end

local function ensureMatchStatusRefs()
	if matchStatusFolder and matchStatusFolder.Parent and stateValue and voteActiveValue then
		return
	end

	matchStatusFolder = ReplicatedStorage:FindFirstChild("MatchStatus")
	if not matchStatusFolder then
		matchStatusFolder = ReplicatedStorage:WaitForChild("MatchStatus", 10)
	end
	if not matchStatusFolder then
		return
	end

	local stateInst = matchStatusFolder:FindFirstChild("State")
	local voteActiveInst = matchStatusFolder:FindFirstChild("ModeVoteActive")
	if stateInst and stateInst:IsA("StringValue") then
		stateValue = stateInst
	end
	if voteActiveInst and voteActiveInst:IsA("BoolValue") then
		voteActiveValue = voteActiveInst
	end
end

local function getCurrentMatchState(): string
	ensureMatchStatusRefs()
	if stateValue then
		return stateValue.Value
	end
	return MatchState.States.Intermission
end

local function isVoteWindowOpen(): boolean
	ensureMatchStatusRefs()
	return voteActiveValue ~= nil and voteActiveValue.Value == true
end

local function getNow(): number
	return workspace:GetServerTimeNow()
end

local function getPendingIntent(player: Player): PendingForceNextModeIntent?
	if not PlayerDataService.IsLoaded(player) then
		return nil
	end

	local data = PlayerDataService.GetData(player)
	local pending = data and data.PendingForceNextModeIntent
	if type(pending) ~= "table" then
		return nil
	end
	if not isSupportedMode(pending.requestedMode) then
		return nil
	end
	if type(pending.createdAt) ~= "number" or type(pending.availableFromMatchId) ~= "number" then
		return nil
	end

	return pending
end

local function clearPendingIntent(player: Player): boolean
	if not PlayerDataService.IsLoaded(player) then
		return false
	end
	return PlayerDataService.SetField(player, "PendingForceNextModeIntent", nil)
end

local function queueEntryCount(): number
	return #forceQueue
end

function ForceNextModeProductService.GetProductId(): number
	return tonumber(DeveloperProductConfig.ForceNextMode.productId) or 0
end

function ForceNextModeProductService.GetProductLabel(): string
	return tostring(DeveloperProductConfig.ForceNextMode.name or "FORCE NEXT MODE!")
end

function ForceNextModeProductService.PeekEligibleForUpcomingMatch(upcomingMatchId: number): ForceNextModeQueueEntry?
	if type(upcomingMatchId) ~= "number" or upcomingMatchId <= 0 then
		return nil
	end

	for _, entry in ipairs(forceQueue) do
		if entry.availableFromMatchId <= upcomingMatchId then
			return entry
		end
	end

	return nil
end

function ForceNextModeProductService.ConsumeReservedForStartedMatch(receiptKey: string, matchId: number): boolean
	if type(receiptKey) ~= "string" or receiptKey == "" then
		return false
	end

	for index, entry in ipairs(forceQueue) do
		if entry.receiptKey == receiptKey then
			table.remove(forceQueue, index)
			log(string.format(
				"[QueueConsume] matchId=%d receipt=%s mode=%s purchaser=%s remaining=%d",
				math.max(0, math.floor(matchId)),
				receiptKey,
				entry.requestedMode,
				entry.purchaserName,
				queueEntryCount()
			))
			return true
		end
	end

	log(string.format(
		"[QueueConsumeMiss] matchId=%d receipt=%s remaining=%d",
		math.max(0, math.floor(matchId)),
		receiptKey,
		queueEntryCount()
	))
	return false
end

function ForceNextModeProductService.ConsumePendingReceipt(player: Player, receiptKey: string): (boolean, string)
	if not player or not player.Parent then
		return false, "PLAYER_MISSING"
	end

	if type(receiptKey) ~= "string" or receiptKey == "" then
		return false, "BAD_RECEIPT_KEY"
	end

	if handledReceiptKeys[receiptKey] then
		clearPendingIntent(player)
		log(string.format(
			"[ReceiptDuplicate] purchaser=%s receipt=%s result=ALREADY_QUEUED",
			player.Name,
			receiptKey
		))
		return true, "ALREADY_QUEUED"
	end

	if not PlayerDataService.IsLoaded(player) then
		log(string.format(
			"[ReceiptDeferred] purchaser=%s receipt=%s reason=PLAYER_DATA_NOT_READY",
			player.Name,
			receiptKey
		))
		return false, "PLAYER_DATA_NOT_READY"
	end

	local pending = getPendingIntent(player)
	if not pending then
		log(string.format(
			"[ReceiptRejected] purchaser=%s receipt=%s reason=NO_PENDING_INTENT",
			player.Name,
			receiptKey
		))
		return true, "NO_PENDING_INTENT"
	end

	nextOrderIndex += 1
	local entry: ForceNextModeQueueEntry = {
		requestedMode = pending.requestedMode,
		purchaserUserId = player.UserId,
		purchaserName = player.Name,
		createdAt = pending.createdAt,
		orderIndex = nextOrderIndex,
		receiptKey = receiptKey,
		availableFromMatchId = pending.availableFromMatchId,
	}

	table.insert(forceQueue, entry)
	handledReceiptKeys[receiptKey] = true
	clearPendingIntent(player)

	log(string.format(
		"[ReceiptSuccess] purchaser=%s receipt=%s mode=%s availableFromMatchId=%d",
		player.Name,
		receiptKey,
		entry.requestedMode,
		entry.availableFromMatchId
	))
	log(string.format(
		"[QueueAdd] order=%d purchaser=%s receipt=%s mode=%s availableFromMatchId=%d size=%d",
		entry.orderIndex,
		entry.purchaserName,
		entry.receiptKey,
		entry.requestedMode,
		entry.availableFromMatchId,
		queueEntryCount()
	))

	return true, "QUEUED"
end

function ForceNextModeProductService.Init()
	if initialized then
		return
	end

	requestRemote = ensureRemotes()
	ensureMatchStatusRefs()

	requestRemote.OnServerEvent:Connect(function(player: Player, requestedMode: string)
		local now = getNow()
		local cooldownUntil = requestCooldownByUserId[player.UserId] or 0
		if now < cooldownUntil then
			return
		end
		requestCooldownByUserId[player.UserId] = now + REQUEST_COOLDOWN_SECONDS

		local state = getCurrentMatchState()
		local voteActive = isVoteWindowOpen()
		log(string.format(
			"[PromptIntent] purchaser=%s requestedMode=%s state=%s voteActive=%s",
			player.Name,
			tostring(requestedMode),
			state,
			tostring(voteActive)
		))

		if state == MatchState.States.Playing then
			log(string.format(
				"[PromptRejected] purchaser=%s requestedMode=%s state=%s reason=PLAYING_STATE_BLOCKED",
				player.Name,
				tostring(requestedMode),
				state
			))
			return
		end

		if not isSupportedMode(requestedMode) then
			log(string.format(
				"[PromptRejected] purchaser=%s requestedMode=%s state=%s reason=INVALID_MODE",
				player.Name,
				tostring(requestedMode),
				state
			))
			return
		end

		if not PlayerDataService.IsLoaded(player) then
			log(string.format(
				"[PromptRejected] purchaser=%s requestedMode=%s state=%s reason=PLAYER_DATA_NOT_READY",
				player.Name,
				requestedMode,
				state
			))
			return
		end

		local productId = ForceNextModeProductService.GetProductId()
		if productId <= 0 then
			log(string.format(
				"[PromptRejected] purchaser=%s requestedMode=%s state=%s reason=PRODUCT_ID_NOT_CONFIGURED",
				player.Name,
				requestedMode,
				state
			))
			return
		end

		local currentMatchId = EliminationTracker.GetMatchId()
		local availableFromMatchId = if voteActive then currentMatchId + 2 else currentMatchId + 1
		local saved = PlayerDataService.SetField(player, "PendingForceNextModeIntent", {
			requestedMode = requestedMode,
			createdAt = now,
			availableFromMatchId = availableFromMatchId,
		})
		if not saved then
			log(string.format(
				"[PromptRejected] purchaser=%s requestedMode=%s state=%s reason=PENDING_SAVE_FAILED",
				player.Name,
				requestedMode,
				state
			))
			return
		end

		log(string.format(
			"[PurchaseOpen] purchaser=%s requestedMode=%s productId=%d availableFromMatchId=%d voteActive=%s",
			player.Name,
			requestedMode,
			productId,
			availableFromMatchId,
			tostring(voteActive)
		))
		MarketplaceService:PromptProductPurchase(player, productId)
	end)

	Players.PlayerRemoving:Connect(function(player)
		requestCooldownByUserId[player.UserId] = nil
	end)

	initialized = true
	log(string.format(
		"Initialized productId=%d label=%s robux=%d",
		ForceNextModeProductService.GetProductId(),
		ForceNextModeProductService.GetProductLabel(),
		tonumber(DeveloperProductConfig.ForceNextMode.robux) or 5
	))
end

return ForceNextModeProductService
