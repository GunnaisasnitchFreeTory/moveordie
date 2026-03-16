local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Server = ServerScriptService:WaitForChild("Server")

local DeveloperProductConfig = require(Shared:WaitForChild("DeveloperProductConfig"))
local AbilityCatalog = require(Shared:WaitForChild("PerkCatalog"))
local PerkMatchEffectService = require(Server:WaitForChild("PerkMatchEffectService"))

local PerkProductService = {}

local REQUEST_COOLDOWN_SECONDS = 0.8
local PROMPT_IN_FLIGHT_TIMEOUT_SECONDS = 90

local initialized = false
local requestRemote: RemoteEvent? = nil
local requestCooldownByUserId: { [number]: number } = {}
local promptInFlightByUserId: { [number]: { abilityId: string, productId: number, createdAt: number } } = {}
local abilityProductIdToAbilityId: { [number]: string } = {}

local function log(message: string)
	print("[AbilityProduct] " .. message)
end

local function ensureRemotes(): RemoteEvent
	local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotesFolder then
		remotesFolder = Instance.new("Folder")
		remotesFolder.Name = "Remotes"
		remotesFolder.Parent = ReplicatedStorage
		log("[Init] Created ReplicatedStorage.Remotes folder")
	end

	local existing = remotesFolder:FindFirstChild("PerkProductPromptRequest")
	if existing and existing:IsA("RemoteEvent") then
		log("[Init] Using existing remote Remotes.PerkProductPromptRequest")
		return existing
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = "PerkProductPromptRequest"
	remote.Parent = remotesFolder
	log("[Init] Created remote Remotes.PerkProductPromptRequest")
	return remote
end

local function getProductConfigForAbility(abilityId: string)
	local ability = AbilityCatalog.Get(abilityId)
	if not ability then
		return nil, nil
	end

	local configKey = tostring(ability.productConfigKey or "")
	if configKey == "" then
		return ability, nil
	end

	return ability, DeveloperProductConfig[configKey]
end

local function clearPromptInFlight(userId: number, reason: string?)
	local existing = promptInFlightByUserId[userId]
	promptInFlightByUserId[userId] = nil
	if existing then
		log(string.format(
			"[PromptLockCleared] userId=%d ability=%s productId=%d reason=%s",
			userId,
			tostring(existing.abilityId),
			tonumber(existing.productId) or 0,
			tostring(reason or "UNKNOWN")
		))
	end
end

local function getActivePromptInFlight(userId: number, now: number)
	local promptState = promptInFlightByUserId[userId]
	if not promptState then
		return nil
	end
	if (now - promptState.createdAt) > PROMPT_IN_FLIGHT_TIMEOUT_SECONDS then
		clearPromptInFlight(userId, "TIMEOUT")
		return nil
	end
	return promptState
end

local function buildAbilityProductIndex()
	abilityProductIdToAbilityId = {}
	for _, ability in ipairs(AbilityCatalog.All) do
		local productId = PerkProductService.GetProductId(ability.id)
		if productId > 0 then
			abilityProductIdToAbilityId[productId] = ability.id
		end
	end
end

function PerkProductService.GetProductId(abilityId: string): number
	local _, config = getProductConfigForAbility(abilityId)
	if not config then
		return 0
	end
	return tonumber(config.productId) or 0
end

function PerkProductService.ConsumePendingReceipt(player: Player, receiptKey: string, expectedAbilityId: string?): (boolean, string)
	if not player or not player.Parent then
		return false, "PLAYER_MISSING"
	end

	local pending = promptInFlightByUserId[player.UserId]
	clearPromptInFlight(player.UserId, "RECEIPT_CONSUMED")

	if not pending then
		log(string.format(
			"[ReceiptRejected] player=%s receipt=%s reason=NO_PROMPT_IN_FLIGHT",
			player.Name,
			tostring(receiptKey)
		))
		return true, "NO_PROMPT_IN_FLIGHT"
	end

	if expectedAbilityId and pending.abilityId ~= expectedAbilityId then
		log(string.format(
			"[ReceiptRejected] player=%s receipt=%s pending=%s expected=%s reason=PROMPT_ABILITY_ID_MISMATCH",
			player.Name,
			tostring(receiptKey),
			pending.abilityId,
			expectedAbilityId
		))
		return true, "PROMPT_ABILITY_ID_MISMATCH"
	end

	local queueOk, queueReason = PerkMatchEffectService.QueuePerk(player, pending.abilityId)
	log(string.format(
		"[PendingAbilityGrant] player=%s receipt=%s ability=%s result=%s reason=%s playerState=%s pending=%s active=%s",
		player.Name,
		tostring(receiptKey),
		pending.abilityId,
		tostring(queueOk),
		queueReason,
		tostring(player:GetAttribute("PlayerState")),
		tostring(PerkMatchEffectService.GetPendingAbility(player)),
		tostring(PerkMatchEffectService.GetActiveAbility(player))
	))

	return queueOk
		or queueReason == "ALREADY_QUEUED"
		or queueReason == "ALREADY_ACTIVE"
		or queueReason == "PENDING_ABILITY_EXISTS"
		or queueReason == "ACTIVE_ABILITY_EXISTS",
		queueReason
end

function PerkProductService.Init()
	if initialized then
		return
	end

	PerkMatchEffectService.Init()
	requestRemote = ensureRemotes()
	buildAbilityProductIndex()
	log(string.format(
		"[Init] RemoteReady=%s Class=%s ProductMapSize=%d",
		requestRemote:GetFullName(),
		requestRemote.ClassName,
		#AbilityCatalog.All
	))

	requestRemote.OnServerEvent:Connect(function(player: Player, abilityId: string)
		local now = workspace:GetServerTimeNow()
		local cooldownUntil = requestCooldownByUserId[player.UserId] or 0
		if now < cooldownUntil then
			return
		end
		requestCooldownByUserId[player.UserId] = now + REQUEST_COOLDOWN_SECONDS

		local ability, config = getProductConfigForAbility(abilityId)
		if not ability or not config then
			log(string.format(
				"[PromptRejected] player=%s ability=%s reason=UNKNOWN_ABILITY",
				player.Name,
				tostring(abilityId)
			))
			return
		end

		local pendingAbilityId = PerkMatchEffectService.GetPendingAbility(player)
		if pendingAbilityId then
			log(string.format(
				"[PromptRejected] player=%s ability=%s reason=PENDING_ABILITY_EXISTS current=%s",
				player.Name,
				abilityId,
				pendingAbilityId
			))
			return
		end

		local activeAbilityId = PerkMatchEffectService.GetActiveAbility(player)
		if activeAbilityId then
			log(string.format(
				"[PromptRejected] player=%s ability=%s reason=ACTIVE_ABILITY_EXISTS current=%s",
				player.Name,
				abilityId,
				activeAbilityId
			))
			return
		end

		if getActivePromptInFlight(player.UserId, now) then
			log(string.format(
				"[PromptRejected] player=%s ability=%s reason=PENDING_PURCHASE_EXISTS",
				player.Name,
				abilityId
			))
			return
		end

		local productId = tonumber(config.productId) or 0
		if productId <= 0 then
			log(string.format(
				"[PromptRejected] player=%s ability=%s reason=PRODUCT_ID_NOT_CONFIGURED",
				player.Name,
				abilityId
			))
			return
		end

		promptInFlightByUserId[player.UserId] = {
			abilityId = abilityId,
			productId = productId,
			createdAt = now,
		}

		log(string.format(
			"[PromptOpened] player=%s ability=%s productId=%d",
			player.Name,
			abilityId,
			productId
		))
		local promptOk, promptErr = pcall(function()
			MarketplaceService:PromptProductPurchase(player, productId)
		end)
		if not promptOk then
			log(string.format(
				"[PromptFailedToOpen] player=%s ability=%s productId=%d err=%s",
				player.Name,
				abilityId,
				productId,
				tostring(promptErr)
			))
			clearPromptInFlight(player.UserId, "PROMPT_OPEN_ERROR")
		end
	end)

	MarketplaceService.PromptProductPurchaseFinished:Connect(function(a, b, c)
		local userId: number? = nil
		local productId: number? = nil
		local wasPurchased: boolean? = nil

		if typeof(a) == "Instance" and a:IsA("Player") then
			userId = a.UserId
			productId = tonumber(b)
			wasPurchased = (c == true)
		else
			userId = tonumber(a)
			productId = tonumber(b)
			wasPurchased = (c == true)
		end

		if not userId or not productId or productId <= 0 then
			return
		end
		if not abilityProductIdToAbilityId[productId] then
			return
		end

		local promptState = promptInFlightByUserId[userId]
		if not promptState then
			return
		end
		if promptState.productId ~= productId then
			return
		end

		if wasPurchased then
			log(string.format(
				"[PromptSuccessAwaitingReceipt] userId=%d ability=%s productId=%d",
				userId,
				tostring(promptState.abilityId),
				productId
			))
			return
		end

		log(string.format(
			"[PromptCancelled] userId=%d ability=%s productId=%d",
			userId,
			tostring(promptState.abilityId),
			productId
		))
		clearPromptInFlight(userId, "PROMPT_CLOSED_OR_CANCELLED")
	end)

	Players.PlayerRemoving:Connect(function(player)
		clearPromptInFlight(player.UserId, "PLAYER_REMOVING")
		requestCooldownByUserId[player.UserId] = nil
	end)

	initialized = true
	log("Initialized")
end

return PerkProductService
