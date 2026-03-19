--[[
	TutorialService
	Server-side onboarding persistence bridge for the first-join tutorial.

	API:
	  Init()              -> create remotes and wire handlers
	  GetStatus(player)   -> { dataLoaded: boolean, tutorialCompleted: boolean }
	  Acknowledge(player) -> marks completion and saves immediately
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Server = ServerScriptService:WaitForChild("Server")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlayerState = require(Shared:WaitForChild("PlayerState"))

local TutorialService = {}

local initialized = false
local acknowledgeLocks: { [number]: boolean } = {}
local characterConnections: { [Player]: RBXScriptConnection } = {}

local TUTORIAL_MOVEMENT_LOCK_ATTRIBUTE = "TutorialMovementLocked"
local TUTORIAL_COMPLETED_ATTRIBUTE = "TutorialCompleted"

local _playerDataService = nil
local _playerStateService = nil
local _statService = nil

local function getPlayerDataService()
	if _playerDataService then
		return _playerDataService
	end

	local ok, mod = pcall(require, Server:WaitForChild("PlayerDataService", 5))
	if ok and mod then
		_playerDataService = mod
	end

	return _playerDataService
end

local function getPlayerStateService()
	if _playerStateService then
		return _playerStateService
	end

	local ok, mod = pcall(require, Server:WaitForChild("PlayerStateService", 5))
	if ok and mod then
		_playerStateService = mod
	end

	return _playerStateService
end

local function getStatService()
	if _statService then
		return _statService
	end

	local ok, mod = pcall(require, Server:WaitForChild("StatService", 5))
	if ok and mod then
		_statService = mod
	end

	return _statService
end

local function log(...)
	print("[TutorialService]", ...)
end

local function getHumanoid(player: Player): Humanoid?
	local character = player.Character
	if not character then
		return nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		return humanoid
	end

	local descendant = character:FindFirstChild("Humanoid", true)
	if descendant and descendant:IsA("Humanoid") then
		return descendant
	end
	return nil
end

local function applyMovementLock(player: Player)
	local humanoid = getHumanoid(player)
	if not humanoid then
		return
	end

	humanoid.UseJumpPower = true
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0
	humanoid.JumpHeight = 0

	local rootPart = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if rootPart and rootPart:IsA("BasePart") then
		rootPart.AssemblyLinearVelocity = Vector3.zero
		rootPart.AssemblyAngularVelocity = Vector3.zero
	end
end

local function setTutorialMovementLocked(player: Player, locked: boolean)
	player:SetAttribute(TUTORIAL_MOVEMENT_LOCK_ATTRIBUTE, locked)

	if locked then
		applyMovementLock(player)
		return
	end

	local statService = getStatService()
	if statService and type(statService.RecalculateStats) == "function" then
		statService.RecalculateStats(player)
	end
end

local function setTutorialState(player: Player, completed: boolean, reason: string)
	local playerStateService = getPlayerStateService()
	if not playerStateService then
		warn(string.format("[TutorialService] PlayerStateService unavailable while applying tutorial gate for %s", player.Name))
		return
	end

	local currentState = playerStateService.GetState(player)
	if completed then
		player:SetAttribute(TUTORIAL_COMPLETED_ATTRIBUTE, true)
		setTutorialMovementLocked(player, false)
		if currentState == PlayerState.States.TutorialLocked then
			playerStateService.SetState(player, PlayerState.States.Lobby)
		end
		log(string.format("Gameplay unlocked for %s reason=%s state=%s", player.Name, reason, tostring(playerStateService.GetState(player))))
		return
	end

	player:SetAttribute(TUTORIAL_COMPLETED_ATTRIBUTE, false)
	if currentState ~= PlayerState.States.TutorialLocked then
		playerStateService.SetState(player, PlayerState.States.TutorialLocked)
	end
	setTutorialMovementLocked(player, true)
	log(string.format("Gameplay locked for %s reason=%s", player.Name, reason))
end

local function bindCharacterLock(player: Player)
	local existing = characterConnections[player]
	if existing then
		existing:Disconnect()
	end

	characterConnections[player] = player.CharacterAdded:Connect(function()
		task.defer(function()
			if player.Parent and player:GetAttribute(TUTORIAL_MOVEMENT_LOCK_ATTRIBUTE) == true then
				applyMovementLock(player)
				log(string.format("Re-applied tutorial movement lock after respawn for %s", player.Name))
			end
		end)
	end)
end

function TutorialService.PrimePlayer(player: Player)
	if not player or not player.Parent then
		return
	end

	local playerDataService = getPlayerDataService()
	if playerDataService and playerDataService.IsLoaded(player) then
		local completed = playerDataService.GetField(player, "TutorialCompleted") == true
		bindCharacterLock(player)
		setTutorialState(player, completed, completed and "join_prime_loaded_complete" or "join_prime_loaded_incomplete")
		return
	end

	if player:GetAttribute(TUTORIAL_COMPLETED_ATTRIBUTE) == true and player:GetAttribute(TUTORIAL_MOVEMENT_LOCK_ATTRIBUTE) ~= true then
		bindCharacterLock(player)
		setTutorialState(player, true, "join_prime_attribute_complete")
		return
	end

	player:SetAttribute(TUTORIAL_COMPLETED_ATTRIBUTE, false)
	player:SetAttribute(TUTORIAL_MOVEMENT_LOCK_ATTRIBUTE, true)
	bindCharacterLock(player)
	setTutorialState(player, false, "join_prime")
end

function TutorialService.ApplyLoadedState(player: Player)
	bindCharacterLock(player)

	local playerDataService = getPlayerDataService()
	if not playerDataService or not playerDataService.IsLoaded(player) then
		setTutorialState(player, false, "profile_not_loaded")
		return
	end

	local completed = playerDataService.GetField(player, "TutorialCompleted") == true
	local playerStateService = getPlayerStateService()
	local currentState = if playerStateService then playerStateService.GetState(player) else nil
	if not completed and currentState == PlayerState.States.InMatch then
		player:SetAttribute(TUTORIAL_COMPLETED_ATTRIBUTE, false)
		player:SetAttribute(TUTORIAL_MOVEMENT_LOCK_ATTRIBUTE, false)
		log(string.format(
			"Skipped tutorial relock for %s reason=profile_loaded_incomplete state=%s",
			player.Name,
			tostring(currentState)
		))
		return
	end
	setTutorialState(player, completed, completed and "profile_loaded_complete" or "profile_loaded_incomplete")
end

function TutorialService.GetStatus(player: Player)
	local playerDataService = getPlayerDataService()
	if not playerDataService or not playerDataService.IsLoaded(player) then
		return {
			dataLoaded = false,
			tutorialCompleted = false,
		}
	end

	return {
		dataLoaded = true,
		tutorialCompleted = playerDataService.GetField(player, "TutorialCompleted") == true,
	}
end

function TutorialService.Acknowledge(player: Player)
	local userId = player.UserId
	if acknowledgeLocks[userId] then
		return {
			success = false,
			reason = "AlreadySaving",
		}
	end

	acknowledgeLocks[userId] = true

	local playerDataService = getPlayerDataService()
	if not playerDataService or not playerDataService.IsLoaded(player) then
		acknowledgeLocks[userId] = nil
		return {
			success = false,
			reason = "DataNotLoaded",
		}
	end

	if playerDataService.GetField(player, "TutorialCompleted") == true then
		acknowledgeLocks[userId] = nil
		setTutorialState(player, true, "ack_already_complete")
		log(string.format("Acknowledge skipped for %s -- already completed", player.Name))
		return {
			success = true,
			alreadyCompleted = true,
			persisted = true,
			tutorialCompleted = true,
		}
	end

	local setOk = playerDataService.SetField(player, "TutorialCompleted", true)
	if not setOk then
		acknowledgeLocks[userId] = nil
		warn(string.format("[TutorialService] Failed to set TutorialCompleted for %s", player.Name))
		return {
			success = false,
			reason = "SetFieldFailed",
		}
	end

	local saved = playerDataService.SavePlayer(player)
	acknowledgeLocks[userId] = nil
	setTutorialState(player, true, "acknowledged")

	if saved then
		log(string.format("Tutorial completion saved for %s", player.Name))
	else
		warn(string.format("[TutorialService] Tutorial completion marked but immediate save failed for %s", player.Name))
	end

	return {
		success = true,
		persisted = saved,
		tutorialCompleted = true,
	}
end

function TutorialService.Init()
	if initialized then
		return
	end
	initialized = true

	local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotesFolder then
		remotesFolder = Instance.new("Folder")
		remotesFolder.Name = "Remotes"
		remotesFolder.Parent = ReplicatedStorage
	end

	local getStatusFunction = remotesFolder:FindFirstChild("Tutorial_GetStatus")
	if not getStatusFunction then
		getStatusFunction = Instance.new("RemoteFunction")
		getStatusFunction.Name = "Tutorial_GetStatus"
		getStatusFunction.Parent = remotesFolder
	end
	getStatusFunction.OnServerInvoke = function(player)
		return TutorialService.GetStatus(player)
	end

	local acknowledgeFunction = remotesFolder:FindFirstChild("Tutorial_Acknowledge")
	if not acknowledgeFunction then
		acknowledgeFunction = Instance.new("RemoteFunction")
		acknowledgeFunction.Name = "Tutorial_Acknowledge"
		acknowledgeFunction.Parent = remotesFolder
	end
	acknowledgeFunction.OnServerInvoke = function(player)
		return TutorialService.Acknowledge(player)
	end

	Players.PlayerRemoving:Connect(function(player)
		acknowledgeLocks[player.UserId] = nil
		local connection = characterConnections[player]
		if connection then
			connection:Disconnect()
			characterConnections[player] = nil
		end
	end)

	log("Initialized")
end

return TutorialService
