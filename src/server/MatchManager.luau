--[[
	MatchManager
	Server-side match lifecycle controller.
	
	Loop: Intermission -> Playing -> Ending -> repeat
	
	API:
		Init()                    -> Initialize the manager
		StartLoop()               -> Begin the infinite match loop
		GetState()                -> Current match state
		GetTimeRemaining()        -> Seconds left in current phase
		GetEligiblePlayers()      -> Players who can join next match
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Server = ServerScriptService:WaitForChild("Server")

local MatchState = require(Shared:WaitForChild("MatchState"))
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local PlayerState = require(Shared:WaitForChild("PlayerState"))
local ProgressionGoalResolver = require(Shared:WaitForChild("ProgressionGoalResolver"))
local SpawnConfig = require(Shared:WaitForChild("SpawnConfig"))
local PlayerStateService = require(Server:WaitForChild("PlayerStateService"))
local MapManager = require(Server:WaitForChild("MapManager"))
local RoundManager = require(Server:WaitForChild("RoundManager"))
local EliminationTracker = require(Server:WaitForChild("EliminationTracker"))
local EconomyService = require(Server:WaitForChild("EconomyService"))
local ItemCatalog = require(Shared:WaitForChild("ItemCatalog"))
local BrainrotModeService    = require(Server:WaitForChild("BrainrotModeService"))
local RoundCoinService       = require(Server:WaitForChild("RoundCoinService"))
local SwordSpawnService      = require(Server:WaitForChild("SwordSpawnService"))
local TungTungSahurService   = require(Server:WaitForChild("TungTungSahurService"))
local ModeLightingService    = require(Server:WaitForChild("ModeLightingService"))
local CharacterShadowService = require(Server:WaitForChild("CharacterShadowService"))
local FreezePlayerProductService = require(Server:WaitForChild("FreezePlayerProductService"))
local ForceNextModeProductService = require(Server:WaitForChild("ForceNextModeProductService"))
local PerkMatchEffectService = require(Server:WaitForChild("PerkMatchEffectService"))

local _DQS = nil
local function getDQS()
	if _DQS ~= nil then return _DQS end
	local ok, mod = pcall(require, Server:FindFirstChild("DailyQuestService"))
	if ok and mod then _DQS = mod else _DQS = false end
	return _DQS
end

local _Feedback = nil
local function getFeedback()
	if _Feedback ~= nil then return _Feedback end
	local ok, mod = pcall(require, Server:FindFirstChild("MatchFeedbackService"))
	if ok and mod then _Feedback = mod else _Feedback = false end
	return _Feedback
end

--[[ CONFIGURATION ]]
local Config = {
	EndingSeconds = 7,
	MinPlayersToStart = 1,
	DebugLog = true,
}
local FIRST_MATCH_BONUS_COINS = 100
local MATCH_RESULTS_PRESENTATION_DELAY_SECONDS = 1.5

--[[ INTERNAL STATE ]]
local currentState: string = MatchState.States.Intermission
local phaseEndTime: number = 0
local initialized = false
local loopRunning = false
local currentMode: string = "Normal"

local replicatedState: StringValue = nil
local replicatedRound: IntValue = nil
local replicatedRoundPhase: StringValue = nil
local replicatedPhaseEnd: NumberValue = nil
local replicatedMovementCountdownVisible: BoolValue = nil
local replicatedMovementCountdownEndTime: NumberValue = nil
local replicatedMode: StringValue = nil
local replicatedVoteActive: BoolValue = nil
local replicatedVoteEndTime: NumberValue = nil
local replicatedVoteLocked: BoolValue = nil
local replicatedVoteLockedMode: StringValue = nil
local matchResultsEvent: RemoteEvent = nil
local abilityActivationWarningRemote: RemoteEvent = nil

-- Vote state
local voteRemote: RemoteEvent = nil
local votes: { [Player]: string } = {}
local voteActive = false
local voteLocked = false
local lockedVoteMode: string? = nil
local lockedVoteReceiptKey: string? = nil
local lockedVoteUpcomingMatchId = 0

type PendingForcedModeReservation = {
	receiptKey: string,
	forcedMode: string,
	upcomingMatchId: number,
}

local pendingForcedModeReservation: PendingForcedModeReservation? = nil

local MatchManager = {}

--[[ HELPERS ]]

-- Get the surrounding crown milestones for a given win count
local function getMilestoneContext(wins: number)
	local milestones = ItemCatalog.LevelCrownMilestones
	local prev, next_ = nil, nil
	for _, m in ipairs(milestones) do
		if m.wins <= wins then prev = m end
		if m.wins > wins and not next_ then next_ = m end
	end
	if not prev then prev = { wins = 0, crownId = "" } end
	return prev, next_
end

local function log(...)
	if Config.DebugLog then
		print("[MatchManager]", ...)
	end
end

local function getServerTime(): number
	return workspace:GetServerTimeNow()
end

-- GLBS direct call (lazy require, no BindableEvent)
local _GLBS = nil
local function getGLBS()
	if _GLBS ~= nil then return _GLBS end
	local ok, mod = pcall(function()
		return require(Server:WaitForChild("GlobalLeaderboardService", 10))
	end)
	if ok and mod then
		_GLBS = mod
		warn("[MatchManager] GLBS loaded via direct require")
	else
		_GLBS = false
		warn("[MatchManager] GLBS not available:", tostring(mod))
	end
	return _GLBS
end

local function reportStats(userId: number, username: string, updates: { [string]: number })
	local GLBS = getGLBS()
	if not GLBS or GLBS == false then return end

	for statKey, value in pairs(updates) do
		local callOk, callErr = pcall(function()
			GLBS.ReportStatById(userId, statKey, value)
		end)
		if callOk then
			log(string.format("DIRECT CALL OK: ReportStatById(%d, '%s', %d)", userId, statKey, value))
		else
			warn(string.format("[MatchManager] DIRECT CALL FAILED: ReportStatById(%d, '%s', %d) err=%s",
				userId, statKey, value, tostring(callErr)))
		end
	end
end

local function isCanonicalMatchEndReason(reason: string?): boolean
	return reason == "Winner" or reason == "NoWinners" or reason == "CapReached"
end

-- Mode Vote helpers

local function getVoteCounts(): (number, number)
	local normal, brainrot = 0, 0
	for voter, choice in pairs(votes) do
		if voter and voter.Parent and voter:GetAttribute("TutorialCompleted") == true and not PlayerStateService.IsAFK(voter) then
			if choice == "Normal" then
				normal = normal + 1
			elseif choice == "Brainrot" then
				brainrot = brainrot + 1
			end
		end
	end
	return normal, brainrot
end

local function broadcastVoteCounts()
	if not voteRemote then return end
	local normal, brainrot = getVoteCounts()
	for _, player in ipairs(MatchManager.GetEligiblePlayers()) do
		voteRemote:FireClient(player, "Update", { normal = normal, brainrot = brainrot })
	end
end

local function setReplicatedVoteLockState(locked: boolean, forcedMode: string?)
	if replicatedVoteLocked then
		replicatedVoteLocked.Value = locked
	end
	if replicatedVoteLockedMode then
		replicatedVoteLockedMode.Value = if locked and type(forcedMode) == "string" then forcedMode else ""
	end
end

local function clearCurrentVoteLockState()
	voteLocked = false
	lockedVoteMode = nil
	lockedVoteReceiptKey = nil
	lockedVoteUpcomingMatchId = 0
	setReplicatedVoteLockState(false, nil)
end

local function startVote()
	votes = {}
	clearCurrentVoteLockState()

	local upcomingMatchId = EliminationTracker.GetMatchId() + 1
	local forcedEntry = ForceNextModeProductService.PeekEligibleForUpcomingMatch(upcomingMatchId)
	voteLocked = forcedEntry ~= nil
	voteActive = not voteLocked

	if voteLocked and forcedEntry then
		lockedVoteMode = forcedEntry.requestedMode
		lockedVoteReceiptKey = forcedEntry.receiptKey
		lockedVoteUpcomingMatchId = upcomingMatchId
		setReplicatedVoteLockState(true, lockedVoteMode)
	end

	-- Replicate vote-active state so late-joining / slow clients can catch up
	if replicatedVoteActive then
		replicatedVoteActive.Value = true
	end
	if replicatedVoteEndTime then
		replicatedVoteEndTime.Value = phaseEndTime
	end

	if voteRemote then
		for _, player in ipairs(MatchManager.GetEligiblePlayers()) do
			voteRemote:FireClient(player, "Start", {
				locked = voteLocked,
				forcedMode = lockedVoteMode,
			})
		end
	end

	if voteLocked and forcedEntry then
		log(string.format(
			"[ModeVoteLocked] upcomingMatchId=%d mode=%s receipt=%s purchaser=%s",
			upcomingMatchId,
			tostring(lockedVoteMode),
			tostring(lockedVoteReceiptKey),
			forcedEntry.purchaserName
		))
	else
		log("Mode vote started")
	end
end

local function endVote(): string
	voteActive = false

	-- Clear replicated vote state
	if replicatedVoteActive then
		replicatedVoteActive.Value = false
	end
	if replicatedVoteEndTime then
		replicatedVoteEndTime.Value = 0
	end

	local normal = 0
	local brainrot = 0
	local result = "Normal"
	local wasLocked = voteLocked and lockedVoteMode ~= nil and lockedVoteReceiptKey ~= nil
	if wasLocked then
		result = lockedVoteMode or "Normal"
		pendingForcedModeReservation = {
			receiptKey = lockedVoteReceiptKey or "",
			forcedMode = result,
			upcomingMatchId = lockedVoteUpcomingMatchId,
		}
	else
		normal, brainrot = getVoteCounts()
		if brainrot > normal then
			result = "Brainrot"
		end
	end
	currentMode = result

	if replicatedMode then
		replicatedMode.Value = result
	end

	if voteRemote then
		for _, player in ipairs(Players:GetPlayers()) do
			voteRemote:FireClient(player, "End", {
				winner = result,
				normal = normal,
				brainrot = brainrot,
				locked = wasLocked,
				forcedMode = if wasLocked then result else nil,
			})
		end
	end

	votes = {}
	if wasLocked then
		log(string.format(
			"[ModeVoteLockedResult] mode=%s receipt=%s upcomingMatchId=%d",
			result,
			tostring(lockedVoteReceiptKey),
			lockedVoteUpcomingMatchId
		))
	else
		log(string.format("Mode vote ended - %s wins (Normal=%d, Brainrot=%d)", result, normal, brainrot))
	end
	clearCurrentVoteLockState()
	return result
end

local function replicatePhaseEnd(absoluteServerTime: number)
	if replicatedPhaseEnd then
		replicatedPhaseEnd.Value = absoluteServerTime
		log(string.format("Replicated PhaseEndTime -> %.3f", replicatedPhaseEnd.Value))
	else
		log("replicatedPhaseEnd is nil - skipping replication")
	end
end

local function isIntermissionCountdownActive(): boolean
	return currentState == MatchState.States.Intermission and phaseEndTime > getServerTime()
end

local function replicateRound(round: number)
	if replicatedRound then
		replicatedRound.Value = round
		log(string.format("Replicated Round -> %d", round))
	else
		log("replicatedRound is nil - skipping replication")
	end
end

local function restoreEnvironment(context: string?)
	local ctx = if type(context) == "string" and context ~= "" then context else "unknown"
	log(string.format("[EnvRestore] context=%s", ctx))
	ModeLightingService.RestoreDefault()
	MapManager.RestoreDefaultMap()
end

local function applyEnvironmentForMode(modeName: string)
	local mode = if type(modeName) == "string" and modeName ~= "" then modeName else "Normal"
	log(string.format("[EnvApply] selectedMode=%s", mode))
	MapManager.ConfigureForMode(mode)
	ModeLightingService.ApplyForMode(mode)
end

local function setMatchState(newState: string)
	if not MatchState.IsValid(newState) then
		warn("[MatchManager] Invalid state:", newState)
		return
	end
	
	if currentState == newState then
		return
	end
	
	local oldState = currentState
	currentState = newState
	log(string.format("State: %s -> %s", oldState, newState))

	if replicatedState then
		replicatedState.Value = newState
	end
end

-- Force-unseat: detach player from any seat before teleport
local function forceUnseat(player: Player): boolean
	local character = player.Character
	if not character then return false end
	
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return false end
	
	local wasSeated = humanoid.SeatPart ~= nil
		or humanoid:GetState() == Enum.HumanoidStateType.Seated
		or humanoid.Sit
	
	if wasSeated then
		humanoid.Sit = false
		humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
		humanoid.PlatformStand = false
	end
	
	return wasSeated
end

local function safeTeleport(player: Player, targetCFrame: CFrame): boolean
	local character = player.Character
	if not character then return false end
	
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	
	if not humanoid or not rootPart then return false end
	if humanoid.Health <= 0 then return false end
	
	rootPart.CFrame = targetCFrame
	rootPart.AssemblyLinearVelocity = Vector3.zero
	rootPart.AssemblyAngularVelocity = Vector3.zero
	
	return true
end

local function restoreLobbyHealth(player: Player)
	local character = player.Character
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	if humanoid.MaxHealth <= 0 then
		return
	end
	local before = humanoid.Health
	humanoid.Health = humanoid.MaxHealth
	log(string.format("Lobby health restore: %s %.0f->%.0f", player.Name, before, humanoid.Health))
end

local function teleportPlayersToArena(players: { Player })
	if #players == 0 then return end
	
	local spawnCFrames = MapManager.GetArenaSpawnCFrames(#players)
	if #spawnCFrames == 0 then
		warn("[MatchManager] No arena spawn CFrames available")
		return
	end
	
	-- Force all players to stand up before teleporting (fixes chair/seat bug)
	local unseatedAny = false
	for _, player in ipairs(players) do
		if forceUnseat(player) then
			unseatedAny = true
		end
	end
	
	-- Brief wait so Roblox properly detaches seats from characters
	if unseatedAny then
		task.wait(0.15)
	end
	
	local teleported = 0
	
	for i, player in ipairs(players) do
		local spawnCFrame = spawnCFrames[((i - 1) % #spawnCFrames) + 1]
		
		if safeTeleport(player, spawnCFrame) then
			teleported = teleported + 1
			
			-- Post-teleport verify: ensure player is not still seated
			task.spawn(function()
				task.wait(0.1)
				local character = player.Character
				if character then
					local humanoid = character:FindFirstChildOfClass("Humanoid")
					if humanoid and (humanoid.Sit or humanoid.SeatPart ~= nil) then
						humanoid.Sit = false
						humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
						humanoid.PlatformStand = false
					end
				end
			end)
		else
			task.spawn(function()
				for _ = 1, SpawnConfig.MaxTeleportRetries do
					task.wait(SpawnConfig.TeleportRetryDelay)
					if safeTeleport(player, spawnCFrame) then
						break
					end
				end
			end)
		end
	end
	
	log(string.format("Teleported %d players to Arena", teleported))
end

local function formatPlayerNames(players: { Player }): string
	if #players == 0 then
		return "none"
	end

	local names = {}
	for _, player in ipairs(players) do
		table.insert(names, player.Name)
	end
	return table.concat(names, ",")
end

local function logMatchEntrySnapshot(tag: string, player: Player, included: boolean, reason: string)
	local state = PlayerStateService.GetState(player)
	local isAFK = PlayerStateService.IsAFK(player)
	local pendingAbility = PerkMatchEffectService.GetPendingAbility(player)
	local activeAbility = PerkMatchEffectService.GetActiveAbility(player)
	log(string.format(
		"[%s] player=%s state=%s afk=%s pendingAbility=%s activeMatchAbility=%s included=%s reason=%s",
		tag,
		player.Name,
		tostring(state),
		tostring(isAFK),
		tostring(pendingAbility),
		tostring(activeAbility),
		tostring(included),
		reason
	))
end

local function getParticipantRejectReason(player: Player): string?
	if not player or not player.Parent then
		return "unknown"
	end
	if player:GetAttribute("TutorialCompleted") ~= true then
		return "tutorial incomplete"
	end
	if PlayerStateService.IsAFK(player) then
		return "AFK"
	end

	local state = PlayerStateService.GetState(player)
	if state ~= PlayerState.States.Waiting then
		return "invalid state"
	end

	return nil
end

local function collectWaitingParticipants(): ({ Player }, { { player: Player, reason: string } })
	local waitingPlayers = PlayerStateService.GetPlayersInState(PlayerState.States.Waiting)
	log(string.format("[MatchCandidates] count=%d names=%s", #waitingPlayers, formatPlayerNames(waitingPlayers)))

	local accepted = {}
	local rejected = {}
	for _, player in ipairs(waitingPlayers) do
		local rejectReason = getParticipantRejectReason(player)
		if rejectReason then
			table.insert(rejected, {
				player = player,
				reason = rejectReason,
			})
			log(string.format("[MatchCandidate] player=%s result=rejected reason=%s", player.Name, rejectReason))
			logMatchEntrySnapshot("FinalParticipantFilter", player, false, rejectReason)
		else
			table.insert(accepted, player)
			log(string.format("[MatchCandidate] player=%s result=accepted reason=accepted", player.Name))
			logMatchEntrySnapshot("FinalParticipantFilter", player, true, "accepted")
		end
	end

	log(string.format("[MatchCandidatesFinalFilter] accepted=%d rejected=%d names=%s",
		#accepted,
		#rejected,
		formatPlayerNames(accepted)
	))
	return accepted, rejected
end

local function ensureCharacterReadyForCommit(player: Player): (Model?, Humanoid?, BasePart?, string)
	local character = player.Character
	if not character then
		local ok = pcall(function()
			player:LoadCharacter()
		end)
		if not ok then
			return nil, nil, nil, "load_character_failed"
		end
		character = player.Character or player.CharacterAdded:Wait()
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5)
	local rootPart = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 5)
	if not humanoid or not rootPart or not rootPart:IsA("BasePart") then
		return character, nil, nil, "character_not_ready"
	end
	if humanoid.Health <= 0 then
		return character, humanoid, rootPart, "not_alive_for_commit"
	end
	return character, humanoid, rootPart, "ready"
end

local function teleportPlayerToArenaWithRetry(player: Player, targetCFrame: CFrame): (boolean, string)
	local attempts = math.max(1, SpawnConfig.MaxTeleportRetries + 1)
	for attempt = 1, attempts do
		if safeTeleport(player, targetCFrame) then
			return true, string.format("attempt_%d", attempt)
		end
		if attempt < attempts then
			task.wait(SpawnConfig.TeleportRetryDelay)
		end
	end
	return false, "teleport failure"
end

local function commitWaitingParticipantsToMatch(): ({ Player }, string?)
	local accepted = collectWaitingParticipants()
	if #accepted == 0 then
		log(string.format("[MatchCommitAbort] reason=%s accepted=0 minRequired=%d", "no_valid_participants", Config.MinPlayersToStart))
		return {}, "no_valid_participants"
	end

	local spawnCFrames = MapManager.GetArenaSpawnCFrames(#accepted)
	if #spawnCFrames == 0 then
		for _, player in ipairs(accepted) do
			log(string.format("[MatchCandidate] player=%s result=rejected reason=%s", player.Name, "map/spawn unavailable"))
		end
		log(string.format("[MatchCommitAbort] reason=%s accepted=%d minRequired=%d", "map/spawn unavailable", #accepted, Config.MinPlayersToStart))
		return {}, "map/spawn unavailable"
	end

	local unseatedAny = false
	for _, player in ipairs(accepted) do
		if forceUnseat(player) then
			unseatedAny = true
		end
	end
	if unseatedAny then
		task.wait(0.15)
	end

	local committed = {}
	for index, player in ipairs(accepted) do
		local currentState = PlayerStateService.GetState(player)
		if currentState ~= PlayerState.States.Waiting then
			log(string.format("[MatchCandidate] player=%s result=rejected reason=%s", player.Name, "stale round data"))
			logMatchEntrySnapshot("ParticipantCommit", player, false, "stale round data")
			continue
		end
		local _, _, _, readinessDetail = ensureCharacterReadyForCommit(player)
		if readinessDetail ~= "ready" then
			log(string.format("[MatchCandidate] player=%s result=rejected reason=%s", player.Name, readinessDetail))
			logMatchEntrySnapshot("ParticipantCommit", player, false, readinessDetail)
			continue
		end
		log(string.format(
			"[MatchPlayerStatePreTeleport] player=%s state=%s pendingAbility=%s activeAbility=%s",
			player.Name,
			tostring(currentState),
			tostring(PerkMatchEffectService.GetPendingAbility(player)),
			tostring(PerkMatchEffectService.GetActiveAbility(player))
		))

		local spawnCFrame = spawnCFrames[((index - 1) % #spawnCFrames) + 1]
		log(string.format("[MatchTeleportStart] player=%s index=%d target=(%.1f, %.1f, %.1f)",
			player.Name,
			index,
			spawnCFrame.Position.X,
			spawnCFrame.Position.Y,
			spawnCFrame.Position.Z
		))
		local teleported, detail = teleportPlayerToArenaWithRetry(player, spawnCFrame)
		if not teleported then
			log(string.format("[MatchCandidate] player=%s result=rejected reason=%s", player.Name, detail))
			logMatchEntrySnapshot("ParticipantCommit", player, false, detail)
			continue
		end

		log(string.format("[MatchTeleportSuccess] player=%s detail=%s", player.Name, detail))
		PlayerStateService.SetState(player, PlayerState.States.InMatch)
		log(string.format(
			"[MatchPlayerCommitted] player=%s state=%s pendingAbility=%s activeAbility=%s",
			player.Name,
			tostring(PlayerStateService.GetState(player)),
			tostring(PerkMatchEffectService.GetPendingAbility(player)),
			tostring(PerkMatchEffectService.GetActiveAbility(player))
		))
		logMatchEntrySnapshot("ParticipantCommit", player, true, "teleported_and_committed")
		table.insert(committed, player)
	end

	log(string.format("[MatchParticipantsCommitted] count=%d names=%s", #committed, formatPlayerNames(committed)))
	if #committed < Config.MinPlayersToStart then
		log(string.format("[MatchCommitAbort] reason=%s committed=%d minRequired=%d initialAccepted=%d",
			"below_min_players_after_filter",
			#committed,
			Config.MinPlayersToStart,
			#accepted
		))
		return committed, "below_min_players_after_filter"
	end

	return committed, nil
end

local function teleportPlayersToLobby(players: { Player })
	if #players == 0 then return end
	if not SpawnConfig.ReturnToLobbyOnEnd then return end
	
	local lobbyCFrame = MapManager.GetLobbySpawnCFrame()
	local teleported = 0
	
	for i, player in ipairs(players) do
		local offset = Vector3.new(
			(i % 5 - 2) * 3,
			0,
			math.floor(i / 5) * 3
		)
		local targetCFrame = lobbyCFrame + offset
		
		if safeTeleport(player, targetCFrame) then
			teleported = teleported + 1
			restoreLobbyHealth(player)
		else
			task.spawn(function()
				for _ = 1, SpawnConfig.MaxTeleportRetries do
					task.wait(SpawnConfig.TeleportRetryDelay)
					if safeTeleport(player, targetCFrame) then
						restoreLobbyHealth(player)
						break
					end
				end
			end)
		end
	end
	
	log(string.format("Returned %d players to Lobby spawn", teleported))
end

local function fireAbilityActivationWarnings(players: { Player })
	if not abilityActivationWarningRemote then
		return
	end

	for _, player in ipairs(players) do
		if player and player.Parent then
			local message = PerkMatchEffectService.GetPendingAbilityActivationMessage(player)
			if message then
				abilityActivationWarningRemote:FireClient(player, message)
			end
		end
	end
end

local function forceVoteClosedForMatchStart(context: string)
	if replicatedVoteActive then
		replicatedVoteActive.Value = false
	end
	if replicatedVoteEndTime then
		replicatedVoteEndTime.Value = 0
	end
	clearCurrentVoteLockState()
	log(string.format("[ModeVoteForceClosed] context=%s active=false", context))
end

function MatchManager.GetEligiblePlayers(): { Player }
	local eligible = {}
	
	for _, player in ipairs(Players:GetPlayers()) do
		local state = PlayerStateService.GetState(player)
		local isAFK = PlayerStateService.IsAFK(player)
		local tutorialCompleted = player:GetAttribute("TutorialCompleted") == true
		
		if tutorialCompleted and not isAFK and (state == PlayerState.States.Lobby or state == PlayerState.States.Waiting) then
			table.insert(eligible, player)
		end
	end
	
	return eligible
end

local function setEligibleToWaiting()
	local eligible = MatchManager.GetEligiblePlayers()
	for _, player in ipairs(eligible) do
		local state = PlayerStateService.GetState(player)
		if state == PlayerState.States.Lobby then
			PlayerStateService.SetState(player, PlayerState.States.Waiting)
		end
	end
end

local function setMatchPlayersToLobby()
	local inMatchPlayers = PlayerStateService.GetPlayersInState(PlayerState.States.InMatch)
	
	if #inMatchPlayers == 0 then
		log("No remaining InMatch players to return")
		return
	end
	
	teleportPlayersToLobby(inMatchPlayers)
	
	for _, player in ipairs(inMatchPlayers) do
		PlayerStateService.SetState(player, PlayerState.States.Lobby)
		restoreLobbyHealth(player)
	end
	
	log(string.format("Returned %d remaining players to Lobby", #inMatchPlayers))
end

--[[ PHASE HANDLERS ]]

local function runIntermission()
	restoreEnvironment("IntermissionStart")
	setMatchState(MatchState.States.Intermission)
	phaseEndTime = getServerTime() + MatchConfig.IntermissionSeconds
	replicatePhaseEnd(phaseEndTime)
	replicateRound(0)
	clearCurrentVoteLockState()
	if replicatedVoteActive then
		replicatedVoteActive.Value = false
	end
	if replicatedVoteEndTime then
		replicatedVoteEndTime.Value = 0
	end
	-- Reset mode to Normal at start of intermission
	currentMode = "Normal"
	if replicatedMode then
		replicatedMode.Value = "Normal"
	end
	log(string.format(
		"[IntermissionStart] duration=%.1fs phaseEnd=%.3f waiting=%d mode=%s",
		MatchConfig.IntermissionSeconds,
		phaseEndTime,
		#PlayerStateService.GetPlayersInState(PlayerState.States.Waiting),
		tostring(currentMode)
	))
	local lastActiveCount = 0
	local voteStarted = false
	local abilityWarningSent = false
	while getServerTime() < phaseEndTime do
		setEligibleToWaiting()
		local waiting = PlayerStateService.GetPlayersInState(PlayerState.States.Waiting)
		local activeCount = 0
		for _, p in ipairs(waiting) do
			if not PlayerStateService.IsAFK(p) then
				activeCount = activeCount + 1
			end
		end
		if activeCount ~= lastActiveCount then
			log(string.format(
				"[IntermissionTick] activeWaiting=%d->%d remaining=%.1fs phaseEndStable=true",
				lastActiveCount,
				activeCount,
				phaseEndTime - getServerTime()
			))
		end
		lastActiveCount = activeCount
		local timeLeft = phaseEndTime - getServerTime()
		if not abilityWarningSent and timeLeft <= MatchConfig.AbilityWarningRemainingSeconds then
			abilityWarningSent = true
			fireAbilityActivationWarnings(MatchManager.GetEligiblePlayers())
		end
		if not voteStarted and timeLeft <= MatchConfig.VoteRevealRemainingSeconds then
			voteStarted = true
			log(string.format(
				"[VoteReveal] remaining=%.2fs revealAt=%.2fs phaseEnd=%.3f",
				timeLeft,
				MatchConfig.VoteRevealRemainingSeconds,
				phaseEndTime
			))
			startVote()
		end
		task.wait(MatchConfig.IntermissionTickSeconds)
	end
	log(string.format("[IntermissionEnding] waiting=%d eligible=%d mode=%s",
		#PlayerStateService.GetPlayersInState(PlayerState.States.Waiting),
		#MatchManager.GetEligiblePlayers(),
		tostring(currentMode)
	))
	if voteStarted then
		endVote()
	end
	forceVoteClosedForMatchStart("IntermissionComplete")
	setEligibleToWaiting()
end

local function runPlaying()
	setEligibleToWaiting()
	local waitingPlayers = PlayerStateService.GetPlayersInState(PlayerState.States.Waiting)
	for _, player in ipairs(waitingPlayers) do
		logMatchEntrySnapshot("RunPlayingWaitingSnapshot", player, true, "waiting_at_run_playing_start")
	end
	
	if #waitingPlayers < Config.MinPlayersToStart then
		if pendingForcedModeReservation then
			log(string.format(
				"[ForceModeHold] reason=NO_PLAYERS receipt=%s mode=%s upcomingMatchId=%d",
				pendingForcedModeReservation.receiptKey,
				pendingForcedModeReservation.forcedMode,
				pendingForcedModeReservation.upcomingMatchId
			))
			pendingForcedModeReservation = nil
		end
		log(string.format("[MatchStartAbort] reason=%s waiting=%d minRequired=%d names=%s",
			"initial_waiting_below_min",
			#waitingPlayers,
			Config.MinPlayersToStart,
			formatPlayerNames(waitingPlayers)
		))
		for _, player in ipairs(waitingPlayers) do
			PlayerStateService.SetState(player, PlayerState.States.Lobby)
		end
		return false
	end
	
	if pendingForcedModeReservation then
		local reservation = pendingForcedModeReservation
		pendingForcedModeReservation = nil
		local consumed = ForceNextModeProductService.ConsumeReservedForStartedMatch(
			reservation.receiptKey,
			reservation.upcomingMatchId
		)
		if consumed then
			log(string.format(
				"[ForceModeApplied] mode=%s receipt=%s upcomingMatchId=%d",
				reservation.forcedMode,
				reservation.receiptKey,
				reservation.upcomingMatchId
			))
		else
			warn(string.format(
				"[MatchManager] Failed to consume forced mode reservation receipt=%s mode=%s upcomingMatchId=%d",
				reservation.receiptKey,
				reservation.forcedMode,
				reservation.upcomingMatchId
			))
		end
	end
	log(string.format("[MatchStartBegin] mode=%s waitingPlayers=%d", currentMode, #waitingPlayers))

	local played = false
	local startedMatchPlayers: { Player } = {}
	local ok, err = xpcall(function()
		log(string.format("[MatchStartStep] step=%s mode=%s", "ApplyEnvironment", currentMode))
		applyEnvironmentForMode(currentMode)

		log("[MatchStartStep] step=MapManager.OnMatchStart")
		MapManager.OnMatchStart()
		forceVoteClosedForMatchStart("RunPlayingStart")
		log("[MatchStartStep] step=CommitWaitingParticipants")
		local matchPlayers, commitAbortReason = commitWaitingParticipantsToMatch()
		startedMatchPlayers = matchPlayers
		if commitAbortReason then
			error(string.format("MATCH_COMMIT_ABORT:%s", commitAbortReason))
		end
		log(string.format("[MatchStartPlayers] teleported=%d names=%s",
			#matchPlayers,
			formatPlayerNames(matchPlayers)
		))
		log("[MatchStartStep] step=EliminationTracker.Reset")
		EliminationTracker.Reset(matchPlayers)
		local matchId = EliminationTracker.GetMatchId()
		setMatchState(MatchState.States.Playing)
		log(string.format("[MatchStartCommitted] state=%s matchId=%d mode=%s", MatchState.States.Playing, matchId, currentMode))
		do
			local dqs = getDQS()
			if dqs and dqs.OnMatchStart then
				pcall(dqs.OnMatchStart, matchPlayers)
			end
		end
		do
			local feedback = getFeedback()
			if feedback and feedback.OnMatchStart then
				pcall(feedback.OnMatchStart, matchPlayers, currentMode)
			end
		end

		if currentMode == "Brainrot" then
			BrainrotModeService.OnMatchStart()
		end

		EconomyService.ResetMatchCoins()

		log(string.format("[BeamPhaseStartRequest] mode=%s players=%d", currentMode, #matchPlayers))
		RoundManager.StartRoundLoop(currentMode)
		log(string.format("[BeamPhaseStartIssued] running=%s round=%d phase=%s",
			tostring(RoundManager.IsRunning()),
			RoundManager.GetCurrentRound(),
			tostring(RoundManager.GetCurrentPhase())
		))
		if not RoundManager.IsRunning() then
			error("MATCH_COMMIT_ABORT:round_loop_not_running_after_start")
		end
		log(string.format("[MatchStartStep] step=AbilityMatchStart matchId=%d participants=%d", matchId, #matchPlayers))
		PerkMatchEffectService.OnMatchStart(matchPlayers, matchId)

		while RoundManager.IsRunning() do
			task.wait(0.5)
		end

		local endReason = RoundManager.GetMatchEndReason()
		local canonicalEnd = isCanonicalMatchEndReason(endReason)
		local remainingInMatch = #PlayerStateService.GetPlayersInState(PlayerState.States.InMatch)
		log(string.format(
			"[BeamPhaseComplete] reason=%s canonical=%s remainingInMatch=%d finalRound=%d",
			endReason or "unknown",
			tostring(canonicalEnd),
			remainingInMatch,
			RoundManager.GetCurrentRound()
		))
		do
			local dqs = getDQS()
			if dqs and dqs.OnMatchEnd then
				pcall(dqs.OnMatchEnd)
			end
		end
		do
			local feedback = getFeedback()
			if feedback and feedback.OnMatchEnd then
				pcall(feedback.OnMatchEnd)
			end
		end

		if currentMode == "Brainrot" then
			BrainrotModeService.OnMatchEnd()
		end

		PerkMatchEffectService.OnMatchEnd()
		SwordSpawnService.OnMatchEnd()
		TungTungSahurService.OnMatchEnd()
		MapManager.OnMatchEnd()
		if canonicalEnd then
			played = true
		else
			log(string.format(
				"[MatchLoopGuard] canonicalEnd=false reason=%s remainingInMatch=%d action=reset_to_lobby_without_results questProgressDispatch=blocked",
				tostring(endReason),
				remainingInMatch
			))
			if endReason == "Cancelled" then
				log("[MatchLoopGuard] cancelled_round_detected downstream_survival_credit=disabled")
			end
			setMatchPlayersToLobby()
		end
	end, debug.traceback)

	if not ok then
		warn("[MatchManager] runPlaying failed:", err)
		log(string.format("[MatchStartAbort] reason=runPlaying_failed startedPlayers=%d startedNames=%s err=%s",
			#startedMatchPlayers,
			formatPlayerNames(startedMatchPlayers),
			tostring(err)
		))
		pcall(function()
			RoundManager.StopRoundLoop()
		end)
		do
			local dqs = getDQS()
			if dqs and dqs.OnMatchEnd then
				pcall(dqs.OnMatchEnd)
			end
		end
		do
			local feedback = getFeedback()
			if feedback and feedback.OnMatchEnd then
				pcall(feedback.OnMatchEnd)
			end
		end
		pcall(function()
			if currentMode == "Brainrot" then
				BrainrotModeService.OnMatchEnd()
			end
		end)
		pcall(function() PerkMatchEffectService.OnMatchEnd() end)
		pcall(function() SwordSpawnService.OnMatchEnd() end)
		pcall(function() TungTungSahurService.OnMatchEnd() end)
		pcall(function() MapManager.OnMatchEnd() end)
		pcall(function() setMatchPlayersToLobby() end)
		pcall(function()
			for _, player in ipairs(PlayerStateService.GetPlayersInState(PlayerState.States.Waiting)) do
				log(string.format("[MatchStartAbortReset] player=%s state=%s -> Lobby", player.Name, PlayerState.States.Waiting))
				PlayerStateService.SetState(player, PlayerState.States.Lobby)
			end
		end)
	end

	restoreEnvironment("PlayingCleanup")
	return played
end

local function resolveRankingsAndReward()
	local survivors = PlayerStateService.GetPlayersInState(PlayerState.States.InMatch)
	local rankings = EliminationTracker.BuildRankings(survivors)
	
	if #rankings == 0 then
		log("No rankings to process (no players)")
		return rankings
	end
	
	local totalAwarded = 0
	local matchId = EliminationTracker.GetMatchId()
	
	local PDS = nil
	do
		local ok, mod = pcall(function()
			return require(Server:WaitForChild("PlayerDataService", 2))
		end)
		if ok and mod then PDS = mod end
	end
	
	local crownGrants: { [number]: string } = {}
	local placementAwards: { [number]: number } = {}
	local firstMatchBonusAwards: { [number]: number } = {}
	local currentCoinsAfterRewards: { [number]: number } = {}
	local nextGoalsByPlayer: { [number]: any } = {}
	local replayMessagesByPlayer: { [number]: string } = {}

	local function resolveReplayMessage(nextGoal: any): string
		if not nextGoal then
			return "Next match starts soon - go for another win."
		end
		if (nextGoal.remainingCoins or 0) > 0 then
			return string.format("Earn %d more coins for %s.", nextGoal.remainingCoins, nextGoal.name)
		end
		return string.format("You can unlock %s now.", nextGoal.name)
	end
	
	for _, group in ipairs(rankings) do
		for _, entry in ipairs(group.players) do
			if entry.player and entry.player.Parent then
				local player = entry.player
				local awardedCoins = 0
				if group.coins > 0 then
					local awardOk, finalAward = EconomyService.AwardCoins(
						player,
						group.coins,
						string.format("Match#%d Place#%d", matchId, group.placement)
					)
					if awardOk then
						awardedCoins = finalAward or 0
						totalAwarded = totalAwarded + awardedCoins
					end
				end
				placementAwards[entry.playerId] = awardedCoins

				local firstMatchBonusCoins = 0
				if PDS then
					local lifetimeMatchesCompleted = PDS.GetField(player, "LifetimeMatchesCompleted") or 0
					if lifetimeMatchesCompleted <= 0 then
						local bonusOk, finalBonus = EconomyService.AwardCoins(
							player,
							FIRST_MATCH_BONUS_COINS,
							string.format("Match#%d FirstMatchBonus", matchId),
							true
						)
						if bonusOk then
							firstMatchBonusCoins = finalBonus or FIRST_MATCH_BONUS_COINS
							totalAwarded = totalAwarded + firstMatchBonusCoins
							PDS.SetField(player, "LifetimeMatchesCompleted", 1)
							log(string.format(
								"[FirstMatchBonus] player=%s matchId=%d amount=%d",
								player.Name,
								matchId,
								firstMatchBonusCoins
							))
						else
							warn(string.format("[MatchManager] First match bonus failed for %s matchId=%d", player.Name, matchId))
						end
					else
						PDS.SetField(player, "LifetimeMatchesCompleted", lifetimeMatchesCompleted + 1)
					end
				end
				firstMatchBonusAwards[entry.playerId] = firstMatchBonusCoins
				
				if group.placement == 1 and PDS then
					local lifetimeWins = (PDS.GetField(player, "LifetimeWins") or 0) + 1
					PDS.SetField(player, "LifetimeWins", lifetimeWins)

					local weeklyWins = (PDS.GetField(player, "WeeklyWins") or 0) + 1
					PDS.SetField(player, "WeeklyWins", weeklyWins)

					local dqs = getDQS()
					if dqs and dqs.OnPlayerWon then pcall(dqs.OnPlayerWon, player) end

					log(string.format("%s won! LifetimeWins=%d WeeklyWins=%d",
						player.Name, lifetimeWins, weeklyWins))

					reportStats(player.UserId, player.Name, {
						LifetimeWins = lifetimeWins,
						WeeklyWins   = weeklyWins,
					})
					
					local _, nextM = getMilestoneContext(lifetimeWins - 1)
					if nextM and lifetimeWins >= nextM.wins then
						crownGrants[entry.playerId] = nextM.crownId
					end
				end

				local playerData = if PDS then PDS.GetData(player) else nil
				local currentCoins = EconomyService.GetCoins(player)
				currentCoinsAfterRewards[entry.playerId] = currentCoins
				local nextGoal = ProgressionGoalResolver.Resolve({
					coins = currentCoins,
					ownedCrowns = playerData and playerData.OwnedCrowns or {},
					ownedPets = playerData and playerData.OwnedPets or {},
				})
				nextGoalsByPlayer[entry.playerId] = nextGoal
				replayMessagesByPlayer[entry.playerId] = resolveReplayMessage(nextGoal)
				if nextGoal then
					log(string.format(
						"[NextGoalResolved] player=%s goalId=%s price=%d remaining=%d",
						player.Name,
						nextGoal.id,
						nextGoal.price,
						nextGoal.remainingCoins
					))
				else
					log(string.format("[NextGoalResolved] player=%s goalId=<none>", player.Name))
				end

				local matchCoinsCollected = EconomyService.GetMatchCoins(player)
				local totalCoinsEarned = awardedCoins + matchCoinsCollected + firstMatchBonusCoins
				log(string.format(
					"[RewardSummary] player=%s placement=%d placementCoins=%d matchCoins=%d firstMatchBonus=%d total=%d balance=%d",
					player.Name,
					group.placement,
					awardedCoins,
					matchCoinsCollected,
					firstMatchBonusCoins,
					totalCoinsEarned,
					currentCoins
				))
			end
		end
	end
	
	log(string.format("Awarded %d total coins across %d placement groups", totalAwarded, #rankings))
	
	if matchResultsEvent then
		local deliveries = {}
		local flatRankings = {}
		for _, group in ipairs(rankings) do
			for _, entry in ipairs(group.players) do
				table.insert(flatRankings, {
					placement = group.placement,
					playerName = entry.playerName,
					coins = placementAwards[entry.playerId] or 0,
					matchCoinsCollected = entry.player and EconomyService.GetMatchCoins(entry.player) or 0,
				})
			end
		end
		
		for _, group in ipairs(rankings) do
			for _, entry in ipairs(group.players) do
				if entry.player and entry.player.Parent then
					local player = entry.player
					local lifetimeWins = 0
					if PDS then
						lifetimeWins = PDS.GetField(player, "LifetimeWins") or 0
					end
					local prevM, nextM = getMilestoneContext(lifetimeWins)
					local matchCoinsCollected = EconomyService.GetMatchCoins(player)
					local placementCoins = placementAwards[entry.playerId] or 0
					local firstMatchBonusCoins = firstMatchBonusAwards[entry.playerId] or 0
					local totalCoinsEarned = placementCoins + matchCoinsCollected + firstMatchBonusCoins
					
					local payload = {
						yourPlacement = group.placement,
						yourCoins = placementCoins,
						placementCoins = placementCoins,
						yourXP = 0,
						matchCoinsCollected = matchCoinsCollected,
						firstMatchBonusCoins = firstMatchBonusCoins,
						firstMatchBonusGranted = firstMatchBonusCoins > 0,
						totalCoinsEarned = totalCoinsEarned,
						currentCoinsAfterRewards = currentCoinsAfterRewards[entry.playerId] or EconomyService.GetCoins(player),
						replayMessage = replayMessagesByPlayer[entry.playerId] or "Next match starts soon - go for another win.",
						nextGoal = nextGoalsByPlayer[entry.playerId],
						rankings = flatRankings,
						lifetimeWins = lifetimeWins,
						crownGranted = crownGrants[entry.playerId] or nil,
						nextMilestone = nextM,
						prevMilestone = prevM,
					}
					log(string.format(
						"[RewardPresentation] player=%s placement=%d totalCoinsEarned=%d firstMatchBonus=%d",
						player.Name,
						group.placement,
						totalCoinsEarned,
						firstMatchBonusCoins
					))
					table.insert(deliveries, {
						player = player,
						playerName = entry.playerName,
						payload = payload,
					})
				end
			end
		end
		log(string.format(
			"[MatchResultsDelay] scheduled delay=%.1fs recipients=%d",
			MATCH_RESULTS_PRESENTATION_DELAY_SECONDS,
			#deliveries
		))
		task.delay(MATCH_RESULTS_PRESENTATION_DELAY_SECONDS, function()
			for _, delivery in ipairs(deliveries) do
				if delivery.player and delivery.player.Parent then
					local fireOk, fireErr = pcall(function()
						matchResultsEvent:FireClient(delivery.player, delivery.payload)
					end)
					if not fireOk then
						warn("[MatchManager] Failed to fire results to", delivery.playerName, fireErr)
					end
				end
			end
			log("Fired MatchResultsEvent to all match participants")
		end)

		log("[MatchManager] Results -> triggering fireworks (always)")
		local remotes = ReplicatedStorage:FindFirstChild("Remotes")
		local fwRemote = remotes and remotes:FindFirstChild("PlayFireworks")
		if fwRemote then
			fwRemote:FireAllClients()
			log("[MatchManager] PlayFireworks fired to: AllClients")
		else
			warn("[MatchManager] PlayFireworks remote not found in Remotes folder")
		end
	end
	
	return rankings
end

local function runEnding()
	setMatchState(MatchState.States.Ending)
	phaseEndTime = getServerTime() + Config.EndingSeconds
	replicatePhaseEnd(phaseEndTime)
	
	local matchEndReason = RoundManager.GetMatchEndReason()
	local winner = RoundManager.GetWinner()
	
	if matchEndReason == "Winner" and winner then
		log(string.format("Ending started (%ds) - WINNER: %s", Config.EndingSeconds, winner.Name))
	elseif matchEndReason == "NoWinners" then
		log(string.format("Ending started (%ds) - No winners", Config.EndingSeconds))
	else
		log(string.format("Ending started (%ds)", Config.EndingSeconds))
	end
	
	if matchEndReason == "Winner" and winner and winner.Parent then
		local remotes = ReplicatedStorage:FindFirstChild("Remotes")
		local sfxRemote = remotes and remotes:FindFirstChild("PlaySFX")
		if sfxRemote then
			sfxRemote:FireClient(winner, "Win")
		end
	end

	resolveRankingsAndReward()
	setMatchPlayersToLobby()
	
	while getServerTime() < phaseEndTime do
		task.wait(MatchConfig.IntermissionTickSeconds)
	end
end

--[[ PUBLIC API ]]

function MatchManager.Init()
	if initialized then
		warn("[MatchManager] Already initialized")
		return
	end

	local matchStatusFolder = Instance.new("Folder")
	matchStatusFolder.Name = "MatchStatus"

	replicatedState = Instance.new("StringValue")
	replicatedState.Name = "State"
	replicatedState.Value = MatchState.States.Intermission
	replicatedState.Parent = matchStatusFolder

	replicatedRound = Instance.new("IntValue")
	replicatedRound.Name = "Round"
	replicatedRound.Value = 0
	replicatedRound.Parent = matchStatusFolder

	replicatedRoundPhase = Instance.new("StringValue")
	replicatedRoundPhase.Name = "RoundPhase"
	replicatedRoundPhase.Value = ""
	replicatedRoundPhase.Parent = matchStatusFolder

	replicatedPhaseEnd = Instance.new("NumberValue")
	replicatedPhaseEnd.Name = "PhaseEndTime"
	replicatedPhaseEnd.Value = 0
	replicatedPhaseEnd.Parent = matchStatusFolder

	replicatedMovementCountdownVisible = Instance.new("BoolValue")
	replicatedMovementCountdownVisible.Name = "MovementCountdownVisible"
	replicatedMovementCountdownVisible.Value = false
	replicatedMovementCountdownVisible.Parent = matchStatusFolder

	replicatedMovementCountdownEndTime = Instance.new("NumberValue")
	replicatedMovementCountdownEndTime.Name = "MovementCountdownEndTime"
	replicatedMovementCountdownEndTime.Value = 0
	replicatedMovementCountdownEndTime.Parent = matchStatusFolder

	replicatedMode = Instance.new("StringValue")
	replicatedMode.Name = "Mode"
	replicatedMode.Value = "Normal"
	replicatedMode.Parent = matchStatusFolder

	replicatedVoteActive = Instance.new("BoolValue")
	replicatedVoteActive.Name = "ModeVoteActive"
	replicatedVoteActive.Value = false
	replicatedVoteActive.Parent = matchStatusFolder

	replicatedVoteLocked = Instance.new("BoolValue")
	replicatedVoteLocked.Name = "ModeVoteLocked"
	replicatedVoteLocked.Value = false
	replicatedVoteLocked.Parent = matchStatusFolder

	replicatedVoteLockedMode = Instance.new("StringValue")
	replicatedVoteLockedMode.Name = "ModeVoteLockedMode"
	replicatedVoteLockedMode.Value = ""
	replicatedVoteLockedMode.Parent = matchStatusFolder

	replicatedVoteEndTime = Instance.new("NumberValue")
	replicatedVoteEndTime.Name = "ModeVoteEndTime"
	replicatedVoteEndTime.Value = 0
	replicatedVoteEndTime.Parent = matchStatusFolder

	matchStatusFolder.Parent = ReplicatedStorage
	log("MatchStatus folder + replicated values created")

	local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotesFolder then
		remotesFolder = Instance.new("Folder")
		remotesFolder.Name = "Remotes"
		remotesFolder.Parent = ReplicatedStorage
	end
	local existing = remotesFolder:FindFirstChild("MatchResultsEvent")
	if not existing then
		matchResultsEvent = Instance.new("RemoteEvent")
		matchResultsEvent.Name = "MatchResultsEvent"
		matchResultsEvent.Parent = remotesFolder
	else
		matchResultsEvent = existing
	end
	log("MatchResultsEvent remote created")

	local existingAbilityWarning = remotesFolder:FindFirstChild("AbilityActivationWarning")
	if not existingAbilityWarning then
		abilityActivationWarningRemote = Instance.new("RemoteEvent")
		abilityActivationWarningRemote.Name = "AbilityActivationWarning"
		abilityActivationWarningRemote.Parent = remotesFolder
	else
		abilityActivationWarningRemote = existingAbilityWarning
	end
	log("AbilityActivationWarning remote created")

	local existingFW = remotesFolder:FindFirstChild("PlayFireworks")
	if not existingFW then
		local fwRemote = Instance.new("RemoteEvent")
		fwRemote.Name = "PlayFireworks"
		fwRemote.Parent = remotesFolder
	end
	log("PlayFireworks remote created")

	local existingVote = remotesFolder:FindFirstChild("ModeVote")
	if not existingVote then
		voteRemote = Instance.new("RemoteEvent")
		voteRemote.Name = "ModeVote"
		voteRemote.Parent = remotesFolder
	else
		voteRemote = existingVote
	end

	voteRemote.OnServerEvent:Connect(function(player, action, data)
		if action == "Cast" and data and typeof(data) == "string" then
			if voteLocked then
				log(string.format(
					"[ModeVoteRejectedLocked] player=%s attempted=%s forcedMode=%s",
					player.Name,
					data,
					tostring(lockedVoteMode or "")
				))
				return
			end
			if not voteActive then
				return
			end
			if PlayerStateService.IsAFK(player) then return end
			if player:GetAttribute("TutorialCompleted") ~= true then
				log(string.format("[ModeVoteRejectedTutorial] player=%s attempted=%s", player.Name, data))
				return
			end
			local state = PlayerStateService.GetState(player)
			if state ~= PlayerState.States.Lobby and state ~= PlayerState.States.Waiting then
				return
			end
			if data == "Normal" or data == "Brainrot" then
				votes[player] = data
				broadcastVoteCounts()
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		if votes[player] then
			votes[player] = nil
			if voteActive then
				broadcastVoteCounts()
			end
		end
	end)

	Players.PlayerAdded:Connect(function(player)
		if not isIntermissionCountdownActive() then
			return
		end
		local serverRemaining = math.max(0, phaseEndTime - getServerTime())
		local replicatedRemaining = if replicatedPhaseEnd
			then math.max(0, replicatedPhaseEnd.Value - getServerTime())
			else 0
		log(string.format(
			"[IntermissionJoin] player=%s currentRemaining=%.1fs replicatedRemaining=%.1fs replicatedPhaseEnd=%.1f resetBlocked=true",
			player.Name,
			serverRemaining,
			replicatedRemaining,
			replicatedPhaseEnd and replicatedPhaseEnd.Value or 0
		))
	end)

	log("ModeVote remote created")

	BrainrotModeService.Init()
	ModeLightingService.Init()
	CharacterShadowService.Init()
	FreezePlayerProductService.Init()
	ForceNextModeProductService.Init()
	RoundCoinService.Init()
	TungTungSahurService.Init()

	MapManager.Init()
	RoundManager.Init()
	EconomyService.Init()
	SwordSpawnService.Init()
	
	PlayerStateService.OnPlayerRemoval(function(player, oldState)
		if currentState == MatchState.States.Playing and oldState == PlayerState.States.InMatch then
			local round = RoundManager.GetCurrentRound()
			EliminationTracker.RecordElimination(player, round, "Disconnect")
		end
	end)
	
	task.spawn(function()
		getGLBS()
	end)
	
	initialized = true
	log("Initialized (leaderboard updates via direct GLBS calls)")
end

function MatchManager.GetState(): string
	return currentState
end

function MatchManager.GetTimeRemaining(): number
	local remaining = phaseEndTime - getServerTime()
	return math.max(0, math.floor(remaining))
end

function MatchManager.StartLoop()
	if loopRunning then
		warn("[MatchManager] Loop already running")
		return
	end
	loopRunning = true
	log("Loop started - waiting for first eligible player before intermission")
	
	task.spawn(function()
		while loopRunning do
			local eligible = MatchManager.GetEligiblePlayers()
			if #eligible > 0 then
				log(string.format("First eligible player found (%s) - beginning match loop", eligible[1].Name))
				break
			end
			task.wait(0.5)
		end
		
		while loopRunning do
			runIntermission()
			local playedMatch = runPlaying()
			if playedMatch then
				runEnding()
			end
		end
	end)
end

function MatchManager.StopLoop()
	loopRunning = false
	restoreEnvironment("StopLoop")
	log("Loop stopped")
end

return MatchManager
