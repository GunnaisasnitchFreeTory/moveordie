local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Server = ServerScriptService:WaitForChild("Server")

local AbilityCatalog = require(Shared:WaitForChild("PerkCatalog"))
local StatService = require(Server:WaitForChild("StatService"))

local PerkMatchEffectService = {}

local STATUS_NONE = "None"
local STATUS_QUEUED = "Queued"
local STATUS_ACTIVE = "Active"

local SPEED_BONUS_KEY = "PerkSpeed"
local JUMP_BONUS_KEY = "PerkJump"

local initialized = false
local characterConnections: { [number]: RBXScriptConnection } = {}
local playerStateConnections: { [number]: RBXScriptConnection } = {}
local pendingAbilityByUserId: { [number]: string } = {}
local activeMatchAbilityByUserId: { [number]: string } = {}

local function log(message: string)
	print("[AbilityMatchEffect] " .. message)
end

local function getAbility(abilityId: string)
	return AbilityCatalog.Get(abilityId)
end

local function getAbilityStatusAttribute(abilityId: string): string?
	local ability = getAbility(abilityId)
	return ability and ability.statusAttribute or nil
end

local function getPendingAbilityId(player: Player): string?
	return pendingAbilityByUserId[player.UserId]
end

local function getActiveAbilityId(player: Player): string?
	return activeMatchAbilityByUserId[player.UserId]
end

local function isQueued(player: Player, abilityId: string): boolean
	return getPendingAbilityId(player) == abilityId
end

local function isActive(player: Player, abilityId: string): boolean
	return getActiveAbilityId(player) == abilityId
end

local function setAbilityStatus(player: Player, abilityId: string, status: string)
	local attributeName = getAbilityStatusAttribute(abilityId)
	if attributeName then
		player:SetAttribute(attributeName, status)
	end
end

local function refreshPlayerStatuses(player: Player)
	for _, ability in ipairs(AbilityCatalog.All) do
		local status = STATUS_NONE
		if isActive(player, ability.id) then
			status = STATUS_ACTIVE
		elseif isQueued(player, ability.id) then
			status = STATUS_QUEUED
		end
		setAbilityStatus(player, ability.id, status)
	end
end

local function playerHasSword(player: Player): boolean
	local backpack = player:FindFirstChild("Backpack")
	if backpack then
		for _, child in ipairs(backpack:GetChildren()) do
			if child:IsA("Tool") and child.Name == "ClassicSword" then
				return true
			end
		end
	end

	local character = player.Character
	if character then
		for _, child in ipairs(character:GetChildren()) do
			if child:IsA("Tool") and child.Name == "ClassicSword" then
				return true
			end
		end
	end

	return false
end

local function applyActiveAbility(player: Player, abilityId: string, reason: string)
	local ability = getAbility(abilityId)
	if not ability then
		return
	end

	if abilityId == AbilityCatalog.Speed.id then
		local hasSword = playerHasSword(player)
		local walkSpeedBonus = hasSword and (ability.swordWalkSpeedBonus or 0) or (ability.walkSpeedBonus or 0)
		StatService.SetTemporaryMovementBonus(player, SPEED_BONUS_KEY, {
			WalkSpeed = walkSpeedBonus,
		})
		log(string.format(
			"[SpeedApply] player=%s ability=%s sword=%s walkBonus=%.1f reason=%s",
			player.Name,
			abilityId,
			tostring(hasSword),
			walkSpeedBonus,
			reason
		))
	elseif abilityId == AbilityCatalog.Jump.id then
		local jumpPowerBonus = tonumber(ability.jumpPowerBonus) or 0
		StatService.SetTemporaryMovementBonus(player, JUMP_BONUS_KEY, {
			JumpPower = jumpPowerBonus,
		})
		log(string.format(
			"[JumpApply] player=%s ability=%s jumpBonus=%.1f reason=%s",
			player.Name,
			abilityId,
			jumpPowerBonus,
			reason
		))
	end
end

local function clearActiveAbility(player: Player, abilityId: string, reason: string)
	if abilityId == AbilityCatalog.Speed.id then
		StatService.ClearTemporaryMovementBonus(player, SPEED_BONUS_KEY)
	elseif abilityId == AbilityCatalog.Jump.id then
		StatService.ClearTemporaryMovementBonus(player, JUMP_BONUS_KEY)
	end

	log(string.format("[AbilityClear] player=%s ability=%s reason=%s", player.Name, abilityId, reason))
end

local function bindCharacter(player: Player)
	local existing = characterConnections[player.UserId]
	if existing then
		existing:Disconnect()
	end

	characterConnections[player.UserId] = player.CharacterAdded:Connect(function()
		task.delay(0.2, function()
			if not player.Parent then
				return
			end
			local activeAbilityId = activeMatchAbilityByUserId[player.UserId]
			if not activeAbilityId then
				return
			end
			applyActiveAbility(player, activeAbilityId, "CharacterAdded")
		end)
	end)
end

local function bindPlayerState(player: Player)
	local existing = playerStateConnections[player.UserId]
	if existing then
		existing:Disconnect()
	end

	playerStateConnections[player.UserId] = player:GetAttributeChangedSignal("PlayerState"):Connect(function()
		if player:GetAttribute("PlayerState") == "InMatch" then
			return
		end

		local activeAbilityId = activeMatchAbilityByUserId[player.UserId]
		if not activeAbilityId then
			return
		end

		clearActiveAbility(player, activeAbilityId, "PlayerStateChanged")
		activeMatchAbilityByUserId[player.UserId] = nil
		refreshPlayerStatuses(player)
		log(string.format(
			"[PlayerStateExit] player=%s state=%s clearedActiveAbility=%s",
			player.Name,
			tostring(player:GetAttribute("PlayerState")),
			activeAbilityId
		))
	end)
end

local function registerPlayer(player: Player)
	for _, ability in ipairs(AbilityCatalog.All) do
		setAbilityStatus(player, ability.id, STATUS_NONE)
	end
	bindCharacter(player)
	bindPlayerState(player)
end

function PerkMatchEffectService.Init()
	if initialized then
		return
	end

	for _, player in ipairs(Players:GetPlayers()) do
		registerPlayer(player)
	end

	Players.PlayerAdded:Connect(registerPlayer)
	Players.PlayerRemoving:Connect(function(player)
		PerkMatchEffectService.OnPlayerRemoving(player)
	end)

	initialized = true
	log("Initialized")
end

function PerkMatchEffectService.GetPendingAbility(player: Player): string?
	return getPendingAbilityId(player)
end

function PerkMatchEffectService.GetActiveAbility(player: Player): string?
	return getActiveAbilityId(player)
end

function PerkMatchEffectService.HasPendingOrActiveAbility(player: Player): boolean
	return getPendingAbilityId(player) ~= nil or getActiveAbilityId(player) ~= nil
end

function PerkMatchEffectService.GetPendingAbilityActivationMessage(player: Player): string?
	local abilityId = getPendingAbilityId(player)
	local ability = abilityId and getAbility(abilityId) or nil
	if not ability then
		return nil
	end
	return string.format("%s active this match", tostring(ability.name or "Ability"))
end

function PerkMatchEffectService.IsQueuedOrActive(player: Player, abilityId: string): boolean
	return isQueued(player, abilityId) or isActive(player, abilityId)
end

function PerkMatchEffectService.QueuePerk(player: Player, abilityId: string): (boolean, string)
	PerkMatchEffectService.Init()

	local ability = getAbility(abilityId)
	if not ability then
		return false, "UNKNOWN_ABILITY"
	end

	local pendingAbilityId = getPendingAbilityId(player)
	if pendingAbilityId then
		if pendingAbilityId == abilityId then
			return false, "ALREADY_QUEUED"
		end
		return false, "PENDING_ABILITY_EXISTS"
	end

	local activeAbilityId = getActiveAbilityId(player)
	if activeAbilityId then
		if activeAbilityId == abilityId then
			return false, "ALREADY_ACTIVE"
		end
		return false, "ACTIVE_ABILITY_EXISTS"
	end

	pendingAbilityByUserId[player.UserId] = abilityId
	refreshPlayerStatuses(player)
	log(string.format("[QueueAdd] player=%s ability=%s queued=true", player.Name, abilityId))
	return true, "QUEUED"
end

function PerkMatchEffectService.ActivatePendingAbilities(matchPlayers: { Player }, matchId: number): { { player: Player, abilityId: string } }
	PerkMatchEffectService.Init()

	local activated = {}
	for _, player in ipairs(matchPlayers) do
		local pendingAbilityId = getPendingAbilityId(player)
		if pendingAbilityId and not getActiveAbilityId(player) then
			pendingAbilityByUserId[player.UserId] = nil
			activeMatchAbilityByUserId[player.UserId] = pendingAbilityId
			applyActiveAbility(player, pendingAbilityId, string.format("MatchStart#%d", matchId))
			table.insert(activated, {
				player = player,
				abilityId = pendingAbilityId,
			})
		end
		refreshPlayerStatuses(player)
	end

	log(string.format("[MatchStart] matchId=%d activatedAbilities=%d participants=%d", matchId, #activated, #matchPlayers))
	return activated
end

function PerkMatchEffectService.OnMatchStart(matchPlayers: { Player }, matchId: number)
	PerkMatchEffectService.ActivatePendingAbilities(matchPlayers, matchId)
end

function PerkMatchEffectService.OnMatchEnd()
	PerkMatchEffectService.Init()

	for userId, abilityId in pairs(activeMatchAbilityByUserId) do
		local player = Players:GetPlayerByUserId(userId)
		if player then
			clearActiveAbility(player, abilityId, "MatchEnd")
			refreshPlayerStatuses(player)
		end
	end

	activeMatchAbilityByUserId = {}
	log("[MatchEnd] clearedActiveAbilities=true")
end

function PerkMatchEffectService.OnSwordStateChanged(player: Player, _hasSword: boolean, reason: string?)
	PerkMatchEffectService.Init()

	if not isActive(player, AbilityCatalog.Speed.id) then
		return
	end

	applyActiveAbility(player, AbilityCatalog.Speed.id, reason or "SwordStateChanged")
end

function PerkMatchEffectService.OnPlayerRemoving(player: Player)
	local userId = player.UserId
	local activeAbilityId = activeMatchAbilityByUserId[userId]
	if activeAbilityId and player.Parent then
		clearActiveAbility(player, activeAbilityId, "PlayerRemoving")
	end

	activeMatchAbilityByUserId[userId] = nil
	pendingAbilityByUserId[userId] = nil

	local connection = characterConnections[userId]
	if connection then
		connection:Disconnect()
		characterConnections[userId] = nil
	end

	local stateConnection = playerStateConnections[userId]
	if stateConnection then
		stateConnection:Disconnect()
		playerStateConnections[userId] = nil
	end
end

return PerkMatchEffectService
