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
local PENDING_INTENT_TIMEOUT_SECONDS = 120

local initialized = false
local requestRemote: RemoteEvent? = nil
local requestCooldownByUserId: { [number]: number } = {}
local pendingPurchaseByUserId: { [number]: { abilityId: string, createdAt: number } } = {}

local function log(message: string)
	print("[AbilityProduct] " .. message)
end

local function ensureRemotes(): RemoteEvent
	local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotesFolder then
		remotesFolder = Instance.new("Folder")
		remotesFolder.Name = "Remotes"
		remotesFolder.Parent = ReplicatedStorage
	end

	local existing = remotesFolder:FindFirstChild("PerkProductPromptRequest")
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = "PerkProductPromptRequest"
	remote.Parent = remotesFolder
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

local function clearPending(userId: number)
	pendingPurchaseByUserId[userId] = nil
end

local function getActivePending(userId: number, now: number)
	local pending = pendingPurchaseByUserId[userId]
	if not pending then
		return nil
	end
	if (now - pending.createdAt) > PENDING_INTENT_TIMEOUT_SECONDS then
		pendingPurchaseByUserId[userId] = nil
		return nil
	end
	return pending
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

	local pending = pendingPurchaseByUserId[player.UserId]
	clearPending(player.UserId)

	if not pending then
		log(string.format(
			"[ReceiptRejected] player=%s receipt=%s reason=NO_PENDING_ABILITY_PURCHASE",
			player.Name,
			tostring(receiptKey)
		))
		return true, "NO_PENDING_ABILITY_PURCHASE"
	end

	if expectedAbilityId and pending.abilityId ~= expectedAbilityId then
		log(string.format(
			"[ReceiptRejected] player=%s receipt=%s pending=%s expected=%s reason=ABILITY_ID_MISMATCH",
			player.Name,
			tostring(receiptKey),
			pending.abilityId,
			expectedAbilityId
		))
		return true, "ABILITY_ID_MISMATCH"
	end

	local queueOk, queueReason = PerkMatchEffectService.QueuePerk(player, pending.abilityId)
	log(string.format(
		"[ReceiptConsume] player=%s receipt=%s ability=%s result=%s reason=%s",
		player.Name,
		tostring(receiptKey),
		pending.abilityId,
		tostring(queueOk),
		queueReason
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

		if getActivePending(player.UserId, now) then
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

		pendingPurchaseByUserId[player.UserId] = {
			abilityId = abilityId,
			createdAt = now,
		}

		log(string.format(
			"[PurchaseOpen] player=%s ability=%s productId=%d",
			player.Name,
			abilityId,
			productId
		))
		MarketplaceService:PromptProductPurchase(player, productId)
	end)

	Players.PlayerRemoving:Connect(function(player)
		clearPending(player.UserId)
		requestCooldownByUserId[player.UserId] = nil
	end)

	initialized = true
	log("Initialized")
end

return PerkProductService
