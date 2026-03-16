local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Server = ServerScriptService:WaitForChild("Server")

local AbilityCatalog = require(Shared:WaitForChild("PerkCatalog"))
local StatService = require(Server:WaitForChild("StatService"))
local PlayerStateService = require(Server:WaitForChild("PlayerStateService"))

local PerkMatchEffectService = {}

local STATUS_NONE = "None"
local STATUS_QUEUED = "Queued"
local STATUS_ACTIVE = "Active"

local SPEED_BONUS_KEY = "PerkSpeed"
local JUMP_BONUS_KEY = "PerkJump"
local ABILITY_VFX_EMITTER_NAME = "ActiveAbilityVfx"
local ABILITY_VFX_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"

local initialized = false
local characterConnections: { [number]: RBXScriptConnection } = {}
local characterDiedConnections: { [number]: RBXScriptConnection } = {}
local playerStateConnections: { [number]: RBXScriptConnection } = {}
local pendingAbilityByUserId: { [number]: string } = {}
local activeMatchAbilityByUserId: { [number]: string } = {}
local matchParticipantsByUserId: { [number]: boolean } = {}
local activeMatchRunning = false
local activeMatchId = 0
local clearActiveAbility
local getAbilityVfxRoot

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
	local state = tostring(player:GetAttribute("PlayerState"))
	local activeAbilityId = getActiveAbilityId(player)
	local inActiveContext = state == "InMatch"
	local contextReason = if inActiveContext then "in_match" else "player_not_in_match_state"
	if activeAbilityId and not inActiveContext then
		log(string.format(
			"[AbilityStateGuard] Corrected invalid active state for player %s: playerState=%s ability=%s reason=%s -> ClearOnly",
			player.Name,
			state,
			activeAbilityId,
			contextReason
		))
		clearActiveAbility(player, activeAbilityId, "OutOfMatchNormalize")
		log(string.format("[AbilityStateGuard] player=%s action=clear_stale_active ability=%s", player.Name, activeAbilityId))
		activeMatchAbilityByUserId[player.UserId] = nil
		activeAbilityId = nil
	end

	for _, ability in ipairs(AbilityCatalog.All) do
		local attributeName = getAbilityStatusAttribute(ability.id)
		local rawStatus = if attributeName then player:GetAttribute(attributeName) else nil
		local status = STATUS_NONE
		if isActive(player, ability.id) and inActiveContext then
			status = STATUS_ACTIVE
		elseif isQueued(player, ability.id) then
			status = STATUS_QUEUED
		end
		if rawStatus == STATUS_ACTIVE and status ~= STATUS_ACTIVE then
			log(string.format(
				"[AbilityStateGuard] Invalid status attribute player=%s ability=%s rawStatus=%s playerState=%s activeMatchAbility=%s -> correctedStatus=%s",
				player.Name,
				ability.id,
				tostring(rawStatus),
				state,
				tostring(activeAbilityId),
				status
			))
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

local function getActiveCharacterAndHumanoid(player: Player): (Model?, Humanoid?, BasePart?)
	local character = player.Character
	if not character then
		return nil, nil, nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = getAbilityVfxRoot(character)
	return character, humanoid, rootPart
end

local function clearCharacterAbilityVfx(character: Model?)
	if not character then
		return
	end

	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") and descendant.Name == ABILITY_VFX_EMITTER_NAME then
			descendant:Destroy()
		end
	end
end

getAbilityVfxRoot = function(character: Model?): BasePart?
	if not character then
		return nil
	end

	return character:FindFirstChild("HumanoidRootPart")
		or character:FindFirstChild("UpperTorso")
		or character:FindFirstChild("Torso")
end

local function ensureActiveAbilityVfx(player: Player, abilityId: string, reason: string)
	if player:GetAttribute("PlayerState") ~= "InMatch" then
		clearCharacterAbilityVfx(player.Character)
		return
	end

	local character, _, rootPart = getActiveCharacterAndHumanoid(player)
	if not character or not rootPart then
		log(string.format(
			"[AbilityVfxSkipped] player=%s ability=%s reason=%s hasCharacter=%s hasRoot=%s",
			player.Name,
			abilityId,
			reason,
			tostring(character ~= nil),
			tostring(rootPart ~= nil)
		))
		return
	end

	clearCharacterAbilityVfx(character)

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = ABILITY_VFX_EMITTER_NAME
	emitter.Texture = ABILITY_VFX_TEXTURE
	emitter.Color = ColorSequence.new(
		Color3.fromRGB(112, 255, 149),
		Color3.fromRGB(196, 255, 211)
	)
	emitter.LightEmission = 0.65
	emitter.LightInfluence = 0
	emitter.Brightness = 2
	emitter.Enabled = true
	emitter.Lifetime = NumberRange.new(0.7, 1.1)
	emitter.Rate = 24
	emitter.Speed = NumberRange.new(2.5, 4)
	emitter.SpreadAngle = Vector2.new(40, 40)
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.Acceleration = Vector3.new(0, 5, 0)
	emitter.Drag = 2.5
	emitter.LockedToPart = true
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(0.6, 0.22),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.75, 0.15),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Parent = rootPart
	emitter:Emit(12)
	log(string.format(
		"[AbilityVfxAttached] player=%s ability=%s root=%s rate=%.1f reason=%s",
		player.Name,
		abilityId,
		rootPart.Name,
		emitter.Rate,
		reason
	))
end

local function enforceActiveAbilityHumanoidStats(player: Player, abilityId: string, reason: string)
	local _, humanoid = getActiveCharacterAndHumanoid(player)
	if not humanoid then
		log(string.format(
			"[AbilityHumanoidPending] player=%s ability=%s reason=%s humanoidReady=false",
			player.Name,
			abilityId,
			reason
		))
		return
	end

	if abilityId == AbilityCatalog.Jump.id then
		humanoid.UseJumpPower = true
		log(string.format(
			"[JumpApplyFinal] player=%s ability=%s finalJumpPower=%.1f useJumpPower=%s reason=%s",
			player.Name,
			abilityId,
			humanoid.JumpPower,
			tostring(humanoid.UseJumpPower),
			reason
		))
	elseif abilityId == AbilityCatalog.Speed.id then
		log(string.format(
			"[SpeedApplyFinal] player=%s ability=%s finalWalkSpeed=%.1f reason=%s",
			player.Name,
			abilityId,
			humanoid.WalkSpeed,
			reason
		))
	end
end

local function queueAbilityReapplyAfterCharacterReady(player: Player, abilityId: string, reason: string)
	task.spawn(function()
		local character = player.Character
		if not character then
			return
		end

		character:WaitForChild("Humanoid", 5)
		character:WaitForChild("HumanoidRootPart", 5)
		if not player.Parent or activeMatchAbilityByUserId[player.UserId] ~= abilityId then
			return
		end

		enforceActiveAbilityHumanoidStats(player, abilityId, reason .. ":HumanoidReady")
		ensureActiveAbilityVfx(player, abilityId, reason .. ":HumanoidReady")
	end)
end

local function clearActiveAbilityVfx(player: Player)
	clearCharacterAbilityVfx(player.Character)
end

local function clearActiveAbilityForPlayer(player: Player, reason: string)
	local activeAbilityId = activeMatchAbilityByUserId[player.UserId]
	if not activeAbilityId then
		return
	end

	clearActiveAbility(player, activeAbilityId, reason)
	activeMatchAbilityByUserId[player.UserId] = nil
	refreshPlayerStatuses(player)
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

	enforceActiveAbilityHumanoidStats(player, abilityId, reason)
	ensureActiveAbilityVfx(player, abilityId, reason)
	queueAbilityReapplyAfterCharacterReady(player, abilityId, reason)
end

clearActiveAbility = function(player: Player, abilityId: string, reason: string)
	if abilityId == AbilityCatalog.Speed.id then
		StatService.ClearTemporaryMovementBonus(player, SPEED_BONUS_KEY)
	elseif abilityId == AbilityCatalog.Jump.id then
		StatService.ClearTemporaryMovementBonus(player, JUMP_BONUS_KEY)
	end

	clearActiveAbilityVfx(player)

	log(string.format("[AbilityClear] player=%s ability=%s reason=%s", player.Name, abilityId, reason))
end

local function bindCharacterHumanoid(player: Player, character: Model?)
	local existing = characterDiedConnections[player.UserId]
	if existing then
		existing:Disconnect()
		characterDiedConnections[player.UserId] = nil
	end

	if not character then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	characterDiedConnections[player.UserId] = humanoid.Died:Connect(function()
		clearActiveAbilityForPlayer(player, "HumanoidDied")
	end)
end

local function bindCharacter(player: Player)
	local existing = characterConnections[player.UserId]
	if existing then
		existing:Disconnect()
	end

	characterConnections[player.UserId] = player.CharacterAdded:Connect(function()
		local character = player.Character
		bindCharacterHumanoid(player, character)
		task.spawn(function()
			if character then
				character:WaitForChild("Humanoid", 10)
				character:WaitForChild("HumanoidRootPart", 10)
			end
			if not player.Parent then
				return
			end
			local activeAbilityId = activeMatchAbilityByUserId[player.UserId]
			if not activeAbilityId then
				return
			end
			local ok, err = pcall(function()
				applyActiveAbility(player, activeAbilityId, "CharacterAdded")
			end)
			if not ok then
				warn(string.format(
					"[AbilityMatchEffect] applyActiveAbility failed player=%s ability=%s context=CharacterAdded err=%s",
					player.Name,
					tostring(activeAbilityId),
					tostring(err)
				))
			end
		end)
	end)
end

local function bindPlayerState(player: Player)
	local existing = playerStateConnections[player.UserId]
	if existing then
		existing:Disconnect()
	end

	playerStateConnections[player.UserId] = player:GetAttributeChangedSignal("PlayerState"):Connect(function()
		local newState = tostring(player:GetAttribute("PlayerState"))
		if newState ~= "InMatch" then
			matchParticipantsByUserId[player.UserId] = nil
		end
		local activeAbilityId = activeMatchAbilityByUserId[player.UserId]
		if newState ~= "InMatch" and activeAbilityId then
			clearActiveAbilityForPlayer(player, "PlayerStateChanged")
			log(string.format(
				"[PlayerStateExit] player=%s state=%s clearedActiveAbility=%s",
				player.Name,
				newState,
				activeAbilityId
			))
		end
		refreshPlayerStatuses(player)
	end)
end

local function registerPlayer(player: Player)
	for _, ability in ipairs(AbilityCatalog.All) do
		setAbilityStatus(player, ability.id, STATUS_NONE)
	end
	bindCharacter(player)
	bindPlayerState(player)
	bindCharacterHumanoid(player, player.Character)
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
	PlayerStateService.OnStateChanged(function(player: Player, _oldState: string?, _newState: string)
		if player and player.Parent then
			refreshPlayerStatuses(player)
		end
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
	log(string.format(
		"[AbilityLifecycle] player=%s action=pending_set ability=%s pending=%s active=%s playerState=%s",
		player.Name,
		abilityId,
		tostring(pendingAbilityByUserId[player.UserId]),
		tostring(activeMatchAbilityByUserId[player.UserId]),
		tostring(player:GetAttribute("PlayerState"))
	))
	return true, "QUEUED"
end

function PerkMatchEffectService.ActivatePendingAbilities(matchPlayers: { Player }, matchId: number): { { player: Player, abilityId: string } }
	PerkMatchEffectService.Init()

	local activated = {}
	for _, player in ipairs(matchPlayers) do
		local playerState = player:GetAttribute("PlayerState")
		if playerState ~= "InMatch" then
			log(string.format(
				"[AbilityLifecycle] player=%s action=activate_skip reason=not_in_match playerState=%s pending=%s active=%s matchId=%d",
				player.Name,
				tostring(playerState),
				tostring(getPendingAbilityId(player)),
				tostring(getActiveAbilityId(player)),
				matchId
			))
			refreshPlayerStatuses(player)
			continue
		end
		local pendingAbilityId = getPendingAbilityId(player)
		if pendingAbilityId and not getActiveAbilityId(player) then
			local ok, err = pcall(function()
				pendingAbilityByUserId[player.UserId] = nil
				activeMatchAbilityByUserId[player.UserId] = pendingAbilityId
				log(string.format(
					"[AbilityLifecycle] player=%s action=promote_pending_to_active ability=%s pending=%s active=%s matchId=%d playerState=%s",
					player.Name,
					pendingAbilityId,
					tostring(getPendingAbilityId(player)),
					tostring(getActiveAbilityId(player)),
					matchId,
					tostring(playerState)
				))
				applyActiveAbility(player, pendingAbilityId, string.format("MatchStart#%d", matchId))
			end)
			if ok then
				table.insert(activated, {
					player = player,
					abilityId = pendingAbilityId,
				})
			else
				warn(string.format(
					"[AbilityMatchEffect] ActivatePendingAbilities recoverable failure player=%s ability=%s matchId=%d err=%s",
					player.Name,
					tostring(pendingAbilityId),
					matchId,
					tostring(err)
				))
				activeMatchAbilityByUserId[player.UserId] = nil
				if not pendingAbilityByUserId[player.UserId] then
					pendingAbilityByUserId[player.UserId] = pendingAbilityId
				end
			end
		end
		refreshPlayerStatuses(player)
	end

	log(string.format("[MatchStart] matchId=%d activatedAbilities=%d participants=%d", matchId, #activated, #matchPlayers))
	return activated
end

function PerkMatchEffectService.OnMatchStart(matchPlayers: { Player }, matchId: number)
	local ok, err = pcall(function()
		PerkMatchEffectService.ActivatePendingAbilities(matchPlayers, matchId)
	end)
	if not ok then
		warn(string.format(
			"[AbilityMatchEffect] OnMatchStart ability activation failed but match continues matchId=%d err=%s",
			matchId,
			tostring(err)
		))
	end
end

function PerkMatchEffectService.OnMatchEnd()
	PerkMatchEffectService.Init()

	for userId, abilityId in pairs(activeMatchAbilityByUserId) do
		local player = Players:GetPlayerByUserId(userId)
		if player then
			log(string.format(
				"[AbilityLifecycle] player=%s action=active_consumed reason=match_end ability=%s pending=%s active=%s",
				player.Name,
				abilityId,
				tostring(getPendingAbilityId(player)),
				tostring(getActiveAbilityId(player))
			))
			clearActiveAbility(player, abilityId, "MatchEnd")
			activeMatchAbilityByUserId[userId] = nil
			refreshPlayerStatuses(player)
			log(string.format(
				"[AbilityLifecycle] player=%s action=active_cleared_post_match ability=%s pending=%s active=%s",
				player.Name,
				abilityId,
				tostring(getPendingAbilityId(player)),
				tostring(getActiveAbilityId(player))
			))
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

	local ok, err = pcall(function()
		applyActiveAbility(player, AbilityCatalog.Speed.id, reason or "SwordStateChanged")
	end)
	if not ok then
		warn(string.format(
			"[AbilityMatchEffect] OnSwordStateChanged failed player=%s err=%s",
			player.Name,
			tostring(err)
		))
	end
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

	local diedConnection = characterDiedConnections[userId]
	if diedConnection then
		diedConnection:Disconnect()
		characterDiedConnections[userId] = nil
	end
end

return PerkMatchEffectService
