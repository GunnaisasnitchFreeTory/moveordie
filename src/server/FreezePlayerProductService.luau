--[[
	FreezePlayerProductService
	Server-authoritative handling for targeted Freeze Player developer product flow.

	Flow:
	  1) Client triggers prompt request with target userId.
	  2) Server validates match/round/target and opens dev product purchase.
	  3) ProcessReceipt calls ConsumePendingReceipt() for final validation + freeze apply.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Server = ServerScriptService:WaitForChild("Server")

local PlayerState = require(Shared:WaitForChild("PlayerState"))
local DeveloperProductConfig = require(Shared:WaitForChild("DeveloperProductConfig"))
local PlayerStateService = require(Server:WaitForChild("PlayerStateService"))
local RoundManager = require(Server:WaitForChild("RoundManager"))

local FreezePlayerProductService = {}

local REQUEST_COOLDOWN_SECONDS = 0.8

type PendingFreezePurchase = {
	targetUserId: number,
	targetName: string,
	round: number,
	matchState: string,
	createdAt: number,
}

local initialized = false
local requestRemote: RemoteEvent? = nil
local matchStatusFolder: Instance? = nil
local stateValue: StringValue? = nil
local roundValue: IntValue? = nil
local modeValue: StringValue? = nil

local pendingByPurchaserUserId: { [number]: PendingFreezePurchase } = {}
local requestCooldownByUserId: { [number]: number } = {}

local function log(message: string)
	print("[FreezeProduct] " .. message)
end

local function ensureRemotes(): RemoteEvent
	local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotesFolder then
		remotesFolder = Instance.new("Folder")
		remotesFolder.Name = "Remotes"
		remotesFolder.Parent = ReplicatedStorage
	end

	local existing = remotesFolder:FindFirstChild("FreezePlayerPromptRequest")
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = "FreezePlayerPromptRequest"
	remote.Parent = remotesFolder
	return remote
end

local function ensureMatchStatusRefs()
	if matchStatusFolder and matchStatusFolder.Parent and stateValue and roundValue and modeValue then
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
	local roundInst = matchStatusFolder:FindFirstChild("Round")
	local modeInst = matchStatusFolder:FindFirstChild("Mode")
	if stateInst and stateInst:IsA("StringValue") then
		stateValue = stateInst
	end
	if roundInst and roundInst:IsA("IntValue") then
		roundValue = roundInst
	end
	if modeInst and modeInst:IsA("StringValue") then
		modeValue = modeInst
	end
end

local function getCurrentMatchState(): string
	ensureMatchStatusRefs()
	if stateValue then
		return stateValue.Value
	end
	return "Intermission"
end

local function getCurrentRound(): number
	ensureMatchStatusRefs()
	if roundValue then
		return roundValue.Value
	end
	return 0
end

local function getCurrentMode(): string
	ensureMatchStatusRefs()
	if modeValue then
		return modeValue.Value
	end
	return "Normal"
end

local function isFreezeRoundAllowed(): boolean
	local state = getCurrentMatchState()
	local round = getCurrentRound()
	local mode = getCurrentMode()
	return state == "Playing" and round > 0 and round < 7 and mode ~= "Brainrot"
end

local function isValidTargetPlayer(purchaser: Player, target: Player?): (boolean, string)
	if not purchaser or not purchaser.Parent then
		return false, "PURCHASER_MISSING"
	end
	if not target or not target.Parent then
		return false, "TARGET_MISSING"
	end
	if purchaser == target then
		return false, "TARGET_SELF"
	end
	if PlayerStateService.IsAFK(target) then
		return false, "TARGET_AFK"
	end
	local targetState = PlayerStateService.GetState(target)
	if targetState ~= PlayerState.States.InMatch then
		return false, "TARGET_NOT_INMATCH"
	end
	local purchaserState = PlayerStateService.GetState(purchaser)
	if purchaserState ~= PlayerState.States.InMatch then
		return false, "PURCHASER_NOT_INMATCH"
	end

	local targetHum = target.Character and target.Character:FindFirstChildOfClass("Humanoid")
	if not targetHum or targetHum.Health <= 0 then
		return false, "TARGET_DEAD_OR_NO_HUMANOID"
	end

	return true, "OK"
end

local function clearPendingForUserId(userId: number)
	pendingByPurchaserUserId[userId] = nil
end

local function clearPendingByTargetUserId(targetUserId: number)
	for purchaserUserId, pending in pairs(pendingByPurchaserUserId) do
		if pending.targetUserId == targetUserId then
			pendingByPurchaserUserId[purchaserUserId] = nil
		end
	end
end

function FreezePlayerProductService.GetProductId(): number
	return tonumber(DeveloperProductConfig.FreezePlayer.productId) or 0
end

function FreezePlayerProductService.GetProductLabel(): string
	return tostring(DeveloperProductConfig.FreezePlayer.name or "Freeze Player")
end

function FreezePlayerProductService.ConsumePendingReceipt(player: Player, receiptKey: string): (boolean, string)
	local state = getCurrentMatchState()
	local round = getCurrentRound()
	local mode = getCurrentMode()
	local purchaserUserId = player.UserId
	local pending = pendingByPurchaserUserId[purchaserUserId]
	clearPendingForUserId(purchaserUserId)

	if not pending then
		log(string.format(
			"[ReceiptRejected] purchaser=%s receipt=%s state=%s round=%d reason=NO_PENDING_TARGET",
			player.Name,
			tostring(receiptKey),
			state,
			round
		))
		return true, "NO_PENDING_TARGET"
	end

	local target = Players:GetPlayerByUserId(pending.targetUserId)
	local validTarget, targetReason = isValidTargetPlayer(player, target)
	if not validTarget then
		log(string.format(
			"[ReceiptRejected] purchaser=%s target=%s state=%s round=%d reason=%s",
			player.Name,
			tostring(pending.targetName),
			state,
			round,
			targetReason
		))
		return true, targetReason
	end

	if not isFreezeRoundAllowed() then
		log(string.format(
			"[ReceiptRejected] purchaser=%s target=%s state=%s round=%d mode=%s reason=ROUND_OR_STATE_INVALID_OR_MODE_BLOCKED",
			player.Name,
			target.Name,
			state,
			round,
			mode
		))
		return true, "ROUND_OR_STATE_INVALID_OR_MODE_BLOCKED"
	end

	if pending.round ~= round or pending.matchState ~= "Playing" then
		log(string.format(
			"[ReceiptRejected] purchaser=%s target=%s state=%s round=%d pendingRound=%d reason=STALE_PENDING",
			player.Name,
			target.Name,
			state,
			round,
			pending.round
		))
		return true, "STALE_PENDING"
	end

	local okFreeze, reason = RoundManager.TryApplyTargetedRoundFreeze(player, target)
	if not okFreeze then
		log(string.format(
			"[ReceiptRejected] purchaser=%s target=%s state=%s round=%d reason=%s",
			player.Name,
			target.Name,
			state,
			round,
			tostring(reason)
		))
		return true, tostring(reason)
	end

	log(string.format(
		"[FreezeApplied] purchaser=%s target=%s state=%s round=%d receipt=%s",
		player.Name,
		target.Name,
		state,
		round,
		tostring(receiptKey)
	))
	return true, "APPLIED"
end

function FreezePlayerProductService.Init()
	if initialized then
		return
	end

	requestRemote = ensureRemotes()
	ensureMatchStatusRefs()

	requestRemote.OnServerEvent:Connect(function(purchaser: Player, targetUserId: number)
		local now = tick()
		local cooldownUntil = requestCooldownByUserId[purchaser.UserId] or 0
		if now < cooldownUntil then
			return
		end
		requestCooldownByUserId[purchaser.UserId] = now + REQUEST_COOLDOWN_SECONDS

		local state = getCurrentMatchState()
		local round = getCurrentRound()
		local mode = getCurrentMode()
		if not isFreezeRoundAllowed() then
			log(string.format(
				"[PromptRejected] purchaser=%s state=%s round=%d mode=%s reason=ROUND_OR_STATE_INVALID_OR_MODE_BLOCKED",
				purchaser.Name,
				state,
				round,
				mode
			))
			return
		end

		if type(targetUserId) ~= "number" then
			log(string.format(
				"[PromptRejected] purchaser=%s state=%s round=%d reason=BAD_TARGET_TYPE",
				purchaser.Name,
				state,
				round
			))
			return
		end

		local target = Players:GetPlayerByUserId(targetUserId)
		local validTarget, reason = isValidTargetPlayer(purchaser, target)
		if not validTarget then
			log(string.format(
				"[PromptRejected] purchaser=%s targetUserId=%d state=%s round=%d reason=%s",
				purchaser.Name,
				targetUserId,
				state,
				round,
				reason
			))
			return
		end

		local productId = FreezePlayerProductService.GetProductId()
		if productId <= 0 then
			log(string.format(
				"[PromptRejected] purchaser=%s target=%s state=%s round=%d reason=PRODUCT_ID_NOT_CONFIGURED",
				purchaser.Name,
				target.Name,
				state,
				round
			))
			return
		end

		pendingByPurchaserUserId[purchaser.UserId] = {
			targetUserId = target.UserId,
			targetName = target.Name,
			round = round,
			matchState = state,
			createdAt = now,
		}

		log(string.format(
			"[PurchaseOpen] purchaser=%s target=%s state=%s round=%d productId=%d",
			purchaser.Name,
			target.Name,
			state,
			round,
			productId
		))
		MarketplaceService:PromptProductPurchase(purchaser, productId)
	end)

	Players.PlayerRemoving:Connect(function(player)
		clearPendingForUserId(player.UserId)
		clearPendingByTargetUserId(player.UserId)
		requestCooldownByUserId[player.UserId] = nil
	end)

	initialized = true
	log(string.format(
		"Initialized productId=%d label=%s robux=%d",
		FreezePlayerProductService.GetProductId(),
		FreezePlayerProductService.GetProductLabel(),
		tonumber(DeveloperProductConfig.FreezePlayer.robux) or 15
	))
end

return FreezePlayerProductService
