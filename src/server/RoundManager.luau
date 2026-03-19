--[[
	RoundManager
	Server-side round loop controller.
	
	Runs during Playing phase only.
	Loop: FreeMove → Telegraph → BeamWarning → Strike → Recovery → repeat
	
	Telegraph tiles pulse BEFORE beams appear. When beams spawn,
	tile warnings are removed so the player only sees beams during the strike window.
	
	API:
		Init()              → Initialize the manager
		StartRoundLoop()    → Begin round cycling (only during Playing)
		StopRoundLoop()     → Cancel loop safely
		IsRunning()         → boolean
		GetCurrentRound()   → number
		GetCurrentPhase()   → string | nil
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Server = ServerScriptService:WaitForChild("Server")

local RoundConfig = require(Shared:WaitForChild("RoundConfig"))
local PlayerState = require(Shared:WaitForChild("PlayerState"))
local PlayerStateService = require(Server:WaitForChild("PlayerStateService"))
local HazardManager = require(Server:WaitForChild("HazardManager"))
local MapManager = require(Server:WaitForChild("MapManager"))
local EliminationTracker = require(Server:WaitForChild("EliminationTracker"))
local BrainrotModeService    = require(Server:WaitForChild("BrainrotModeService"))
local RoundCoinService       = require(Server:WaitForChild("RoundCoinService"))
local SwordSpawnService      = require(Server:WaitForChild("SwordSpawnService"))
local TungTungSahurService   = require(Server:WaitForChild("TungTungSahurService"))

--[[ PHASE CONSTANTS ]]
local Phase = {
	Interaction = "Interaction",
	FreeMove = "FreeMove",
	Telegraph = "Telegraph",
	BeamWarning = "BeamWarning",
	Strike = "Strike",
	Recovery = "Recovery",
}

--[[ MATCH END REASONS ]]
local MatchEndReason = {
	Winner = "Winner",
	NoWinners = "NoWinners",
	CapReached = "CapReached",
	Cancelled = "Cancelled",
}

--[[ INTERNAL STATE ]]
local initialized = false
local running = false
local currentRound = 0
local currentPhase: string? = nil
local matchEndReason: string? = nil
local winner: Player? = nil

-- Match tracking
local matchStartTime: number = 0
local initialAliveCount: number = 0
local matchMode: string = "Normal"
type RoundTimings = {
	InteractionWindowSeconds: number,
	FreeMoveSeconds: number,
	TelegraphGraceSeconds: number,
	TelegraphSeconds: number,
	FreezeSeconds: number,
	StrikeSeconds: number,
	RecoverySeconds: number,
}
local currentRoundTimings: RoundTimings = RoundConfig.GetTimingsForRound(0)

-- Freeze state storage with independent freeze reasons.
type FreezeSnapshot = { WalkSpeed: number, JumpPower: number, JumpHeight: number }
type FreezeState = { original: FreezeSnapshot, reasons: { [string]: boolean } }
local FREEZE_REASON_GAMEPLAY = "GameplayRound"
local FREEZE_REASON_DEVPRODUCT = "DevProductRound"
local freezeStates: { [Player]: FreezeState } = {}
local freezeRemote: RemoteEvent = nil
local paidFreezeNoticeRemote: RemoteEvent = nil
local targetedRoundFreezes: { [Player]: { round: number, freezerUserId: number, freezerName: string, appliedAt: number, expiresAt: number } } = {}
local DEV_PRODUCT_FREEZE_SECONDS_DEFAULT: number = 11
local DEV_PRODUCT_FREEZE_SECONDS_ROUND6: number = 7
local INACTIVITY_CHECK_ROUND: number = 3
local MEANINGFUL_MOVE_THRESHOLD_STUDS: number = 8
type MovementParticipation = {
	initialPos: Vector3?,
	hasMeaningfulMovement: boolean,
	movedAtRound: number?,
	movedAtPhase: string?,
	everDevProductFrozen: boolean,
}
local movementParticipationByPlayer: { [Player]: MovementParticipation } = {}

local RoundManager = {}

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

--[[ HELPERS ]]

local function log(...)
	if RoundConfig.DebugLog then
		print("[RoundManager]", ...)
	end
end

local function setMovementCountdownHudState(visible: boolean, durationSeconds: number?, context: string)
	local matchStatus = ReplicatedStorage:FindFirstChild("MatchStatus")
	if not matchStatus then return end
	local visibleVal = matchStatus:FindFirstChild("MovementCountdownVisible")
	local endTimeVal = matchStatus:FindFirstChild("MovementCountdownEndTime")
	if visibleVal and visibleVal:IsA("BoolValue") then
		visibleVal.Value = visible
	end
	if endTimeVal and endTimeVal:IsA("NumberValue") then
		if visible then
			endTimeVal.Value = workspace:GetServerTimeNow() + math.max(0, durationSeconds or 0)
		else
			endTimeVal.Value = 0
		end
	end
	log(string.format(
		"[MovementCountdownReplicate] context=%s visible=%s duration=%.2f endTime=%.2f",
		context,
		tostring(visible),
		tonumber(durationSeconds) or 0,
		if endTimeVal and endTimeVal:IsA("NumberValue") then endTimeVal.Value else 0
	))
end

local function setReplicatedRoundPhase(phaseName: string?)
	local matchStatus = ReplicatedStorage:FindFirstChild("MatchStatus")
	if not matchStatus then
		return
	end
	local roundPhaseValue = matchStatus:FindFirstChild("RoundPhase")
	if roundPhaseValue and roundPhaseValue:IsA("StringValue") then
		roundPhaseValue.Value = phaseName or ""
	end
end

--[[
	Get all players currently InMatch.
]]
local function getInMatchPlayers(): { Player }
	return PlayerStateService.GetPlayersInState(PlayerState.States.InMatch)
end

local function formatAlivePlayerNames(players: { Player }): string
	if #players == 0 then
		return "none"
	end

	local names = table.create(#players)
	for _, player in ipairs(players) do
		table.insert(names, player.Name)
	end
	return table.concat(names, ",")
end

local function logAliveSnapshot(context: string, extra: string?): number
	local players = getInMatchPlayers()
	log(string.format(
		"[RoundAliveSnapshot] context=%s round=%d phase=%s alive=%d players=%s extra=%s",
		context,
		currentRound,
		tostring(currentPhase),
		#players,
		formatAlivePlayerNames(players),
		tostring(extra or "")
	))
	return #players
end

local function isRoundFreezeLocked(player: Player): boolean
	local data = targetedRoundFreezes[player]
	return data ~= nil and data.round == currentRound
end

local function getHumanoid(player: Player): Humanoid?
	local character = player.Character
	if not character then return nil end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return nil end
	return humanoid
end

local function getDevProductFreezeSecondsForRound(roundNumber: number): number
	if roundNumber == 6 then
		return DEV_PRODUCT_FREEZE_SECONDS_ROUND6
	end
	return DEV_PRODUCT_FREEZE_SECONDS_DEFAULT
end

local function getRootPosition(player: Player): Vector3?
	local character = player.Character
	if not character then return nil end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil
	end
	return root.Position
end

local function isGameplayFreezePhase(phaseName: string?): boolean
	return phaseName == Phase.Telegraph
		or phaseName == Phase.BeamWarning
		or phaseName == Phase.Strike
end

local function isPlayablePhase(phaseName: string?): boolean
	return phaseName == Phase.FreeMove or phaseName == Phase.Recovery
end

local function isDevProductFrozenNow(player: Player): boolean
	if targetedRoundFreezes[player] ~= nil then
		return true
	end
	return player:GetAttribute("RoundLockedFreeze") == true
end

local function ensureMovementTracker(player: Player): MovementParticipation
	local tracker = movementParticipationByPlayer[player]
	if tracker then
		if tracker.initialPos == nil then
			tracker.initialPos = getRootPosition(player)
		end
		return tracker
	end
	tracker = {
		initialPos = getRootPosition(player),
		hasMeaningfulMovement = false,
		movedAtRound = nil,
		movedAtPhase = nil,
		everDevProductFrozen = false,
	}
	movementParticipationByPlayer[player] = tracker
	return tracker
end

local function sampleMovementParticipation()
	local playable = isPlayablePhase(currentPhase)
	local players = getInMatchPlayers()
	for _, player in ipairs(players) do
		local tracker = ensureMovementTracker(player)
		local devFrozenNow = isDevProductFrozenNow(player)
		if devFrozenNow then
			tracker.everDevProductFrozen = true
		end
		if tracker.hasMeaningfulMovement or not playable or devFrozenNow then
			continue
		end
		local pos = getRootPosition(player)
		if not pos then
			continue
		end
		if tracker.initialPos == nil then
			tracker.initialPos = pos
			continue
		end
		local dist = (pos - tracker.initialPos).Magnitude
		if dist >= MEANINGFUL_MOVE_THRESHOLD_STUDS then
			tracker.hasMeaningfulMovement = true
			tracker.movedAtRound = currentRound
			tracker.movedAtPhase = currentPhase
			log(string.format(
				"[InactivityGuardMove] player=%s moved=true distance=%.2f threshold=%.2f round=%d phase=%s",
				player.Name,
				dist,
				MEANINGFUL_MOVE_THRESHOLD_STUDS,
				currentRound,
				tostring(currentPhase)
			))
		end
	end
end

local function eliminateForInactivity(player: Player, roundNumber: number)
	local humanoid = getHumanoid(player)
	if humanoid and humanoid.Health > 0 then
		humanoid.Health = 0
	end
	EliminationTracker.RecordElimination(player, roundNumber, "InactiveNoMove")
	PlayerStateService.SetState(player, PlayerState.States.Lobby)
end

local function evaluateRound3Inactivity()
	if currentRound ~= INACTIVITY_CHECK_ROUND then
		return
	end
	local gameplayFrozenNow = isGameplayFreezePhase(currentPhase)
	local players = getInMatchPlayers()
	for _, player in ipairs(players) do
		local state = PlayerStateService.GetState(player)
		local isAFK = PlayerStateService.IsAFK(player)
		local tracker = ensureMovementTracker(player)
		local meaningfulMoved = tracker.hasMeaningfulMovement == true
		local devFreezeNow = isDevProductFrozenNow(player)
		local devFreezeSeen = tracker.everDevProductFrozen == true
		local stillActive = player.Parent ~= nil
			and state == PlayerState.States.InMatch
			and not EliminationTracker.IsEliminated(player)
		local excluded = isAFK or devFreezeNow or devFreezeSeen or gameplayFrozenNow
		local shouldEliminate = stillActive and not excluded and not meaningfulMoved
		log(string.format(
			"[InactivityGuard] player=%s matchState=%s state=%s round=%d meaningfulMoved=%s afk=%s devFreezeNow=%s devFreezeSeen=%s gameplayFreeze=%s eliminate=%s",
			player.Name,
			if running then "Playing" else "NotRunning",
			tostring(state),
			currentRound,
			tostring(meaningfulMoved),
			tostring(isAFK),
			tostring(devFreezeNow),
			tostring(devFreezeSeen),
			tostring(gameplayFrozenNow),
			tostring(shouldEliminate)
		))
		if shouldEliminate then
			eliminateForInactivity(player, math.max(currentRound, 1))
		end
	end
end

local function collectReasonKeys(reasons: { [string]: boolean }): string
	local keys = {}
	for reason, active in pairs(reasons) do
		if active then
			table.insert(keys, reason)
		end
	end
	table.sort(keys)
	return table.concat(keys, ",")
end

local function enforceMovementLock(player: Player)
	local humanoid = getHumanoid(player)
	if not humanoid then return end
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0
	humanoid.JumpHeight = 0
end

local function restoreMovementFromSnapshot(player: Player, snapshot: FreezeSnapshot)
	local humanoid = getHumanoid(player)
	if not humanoid then return end
	humanoid.WalkSpeed = snapshot.WalkSpeed
	humanoid.JumpPower = snapshot.JumpPower
	humanoid.JumpHeight = snapshot.JumpHeight
end

--[[
	Freeze a single player (store original values, set to 0).
]]
local function addFreezeReason(player: Player, reason: string): boolean
	if reason == "" then return false end
	local humanoid = getHumanoid(player)
	if not humanoid then
		return false
	end

	local state = freezeStates[player]
	if not state then
		state = {
			original = {
				WalkSpeed = humanoid.WalkSpeed,
				JumpPower = humanoid.JumpPower,
				JumpHeight = humanoid.JumpHeight,
			},
			reasons = {},
		}
		freezeStates[player] = state
	end
	if state.reasons[reason] then
		return false
	end

	state.reasons[reason] = true
	enforceMovementLock(player)
	log(string.format("[FreezeReasonAdded] player=%s source=%s activeReasons=%s",
		player.Name,
		reason,
		collectReasonKeys(state.reasons)))
	return true
end

--[[
	Unfreeze a single player (restore original values).
]]
local function removeFreezeReason(player: Player, reason: string): boolean
	local state = freezeStates[player]
	if not state or not state.reasons[reason] then
		return false
	end

	state.reasons[reason] = nil
	local stillFrozen = false
	for _, active in pairs(state.reasons) do
		if active then
			stillFrozen = true
			break
		end
	end

	log(string.format("[FreezeReasonRemoved] player=%s source=%s activeReasons=%s",
		player.Name,
		reason,
		collectReasonKeys(state.reasons)))

	if stillFrozen then
		enforceMovementLock(player)
		return false
	end

	restoreMovementFromSnapshot(player, state.original)
	freezeStates[player] = nil
	return true
end

local function clearAllFreezeReasons(player: Player): boolean
	local state = freezeStates[player]
	if not state then
		return false
	end
	restoreMovementFromSnapshot(player, state.original)
	freezeStates[player] = nil
	return true
end

--[[
	Freeze all InMatch players.
]]
local function freezeAllPlayers(freezeDuration: number, scheduledFreezeAt: number?)
	setMovementCountdownHudState(false, 0, "FreezeAllPlayers")
	local players = getInMatchPlayers()
	local actualFreezeAt = workspace:GetServerTimeNow()
	local freezeDrift = if scheduledFreezeAt then actualFreezeAt - scheduledFreezeAt else 0
	log(string.format(
		"[FreezeExecution] round=%d players=%d scheduled=%.3f actual=%.3f drift=%.3f duration=%.2f",
		currentRound,
		#players,
		scheduledFreezeAt or 0,
		actualFreezeAt,
		freezeDrift,
		freezeDuration
	))
	for _, player in ipairs(players) do
		addFreezeReason(player, FREEZE_REASON_GAMEPLAY)
	end
	if freezeRemote then
		for _, player in ipairs(players) do
			freezeRemote:FireClient(player, "Freeze", freezeDuration)
		end
	end
	log(string.format("Froze %d players", #players))
	TungTungSahurService.OnFreezeBegin()
end

--[[
	Unfreeze all frozen players.
]]
local function unfreezeAllPlayers(forceAll: boolean?)
	local count = 0
	local toNotify = {}
	log(string.format("[GameplayFreezeEnd] round=%d forceAll=%s", currentRound, tostring(forceAll == true)))
	for player, _ in pairs(freezeStates) do
		local released = false
		if forceAll then
			released = clearAllFreezeReasons(player)
		else
			released = removeFreezeReason(player, FREEZE_REASON_GAMEPLAY)
		end
		if released then
			table.insert(toNotify, player)
			count = count + 1
		end
	end
	if forceAll then
		for player, _ in pairs(targetedRoundFreezes) do
			if player then
				player:SetAttribute("RoundLockedFreeze", false)
			end
		end
		freezeStates = {}
		targetedRoundFreezes = {}
	end
	if freezeRemote then
		for _, player in ipairs(toNotify) do
			if player.Parent then
				freezeRemote:FireClient(player, "Unfreeze")
			end
		end
	end
	TungTungSahurService.OnFreezeEnd()
	if count > 0 then
		log(string.format("Unfroze %d players", count))
	end
end

local function clearRoundLockedFreezes(roundNumber: number, reason: string)
	local released = 0
	local releasedPlayers = {}
	for player, data in pairs(targetedRoundFreezes) do
		if data.round == roundNumber then
			targetedRoundFreezes[player] = nil
			player:SetAttribute("RoundLockedFreeze", false)
			if removeFreezeReason(player, FREEZE_REASON_DEVPRODUCT) then
				table.insert(releasedPlayers, player)
				released += 1
			end
		end
	end
	if freezeRemote or paidFreezeNoticeRemote then
		for _, player in ipairs(releasedPlayers) do
			if player and player.Parent then
				if freezeRemote then
					freezeRemote:FireClient(player, "Unfreeze")
				end
				if paidFreezeNoticeRemote then
					paidFreezeNoticeRemote:FireClient(player, "Hide", reason)
				end
			end
		end
	end
	if released > 0 then
		log(string.format("Released %d targeted round freezes (reason=%s round=%d)", released, reason, roundNumber))
	end
end

local function clearExpiredProductFreezes()
	local now = tick()
	local released = 0
	local releasedPlayers = {}
	for player, data in pairs(targetedRoundFreezes) do
		if now >= (data.expiresAt or 0) then
			targetedRoundFreezes[player] = nil
			if player and player.Parent then
				player:SetAttribute("RoundLockedFreeze", false)
				if removeFreezeReason(player, FREEZE_REASON_DEVPRODUCT) then
					table.insert(releasedPlayers, player)
					released += 1
				end
			end
		end
	end
	if freezeRemote or paidFreezeNoticeRemote then
		for _, player in ipairs(releasedPlayers) do
			if player and player.Parent then
				if freezeRemote then
					freezeRemote:FireClient(player, "Unfreeze")
				end
				if paidFreezeNoticeRemote then
					paidFreezeNoticeRemote:FireClient(player, "Hide", "DurationExpired")
				end
			end
		end
	end
	if released > 0 then
		log(string.format("[ProductFreezeExpired] released=%d", released))
	end
end

local function cleanupInvalidTargetedRoundFreezes()
	local releasedPlayers = {}
	for player, _ in pairs(targetedRoundFreezes) do
		local playerMissing = (not player) or (not player.Parent)
		local inMatch = (not playerMissing) and (PlayerStateService.GetState(player) == PlayerState.States.InMatch)
		if playerMissing or not inMatch then
			targetedRoundFreezes[player] = nil
			if player and player.Parent then
				player:SetAttribute("RoundLockedFreeze", false)
				if removeFreezeReason(player, FREEZE_REASON_DEVPRODUCT) then
					table.insert(releasedPlayers, player)
				end
			end
		end
	end
	if freezeRemote or paidFreezeNoticeRemote then
		for _, player in ipairs(releasedPlayers) do
			if freezeRemote then
				freezeRemote:FireClient(player, "Unfreeze")
			end
			if paidFreezeNoticeRemote then
				paidFreezeNoticeRemote:FireClient(player, "Hide", "InvalidTargetCleanup")
			end
		end
	end
end

--[[
	Check if match time limit has been exceeded.
]]
local function isMatchTimeExceeded(): boolean
	if RoundConfig.MaxMatchSeconds <= 0 then
		return false -- No limit
	end
	return (tick() - matchStartTime) >= RoundConfig.MaxMatchSeconds
end

local function logMatchEndTrigger(reason: string, aliveCount: number, extra: string?)
	local elapsed = tick() - matchStartTime
	log(string.format(
		"[MatchEndTrigger] reason=%s round=%d alive=%d initialAlive=%d elapsed=%.1fs maxRounds=%d maxSeconds=%d extra=%s",
		reason,
		currentRound,
		aliveCount,
		initialAliveCount,
		elapsed,
		tonumber(RoundConfig.MaxRoundsPerMatch) or -1,
		tonumber(RoundConfig.MaxMatchSeconds) or -1,
		tostring(extra or "")
	))
end

--[[
	Check if match should end based on alive player count or limits.
	Returns true if match should end, sets matchEndReason and winner.
]]
local function checkMatchEnd(context: string?): boolean
	local alivePlayers = PlayerStateService.GetPlayersInState(PlayerState.States.InMatch)
	local aliveCount = #alivePlayers
	local sourceContext = if type(context) == "string" and context ~= "" then context else "Unknown"
	
	-- No one survived
	if aliveCount == 0 then
		winner = nil
		matchEndReason = MatchEndReason.NoWinners
		log("No winners - all players eliminated")
		logMatchEndTrigger(MatchEndReason.NoWinners, aliveCount, string.format("context=%s all eliminated", sourceContext))
		return true
	end
	
	-- Winner: only if we started with 2+ players and now have 1
	if aliveCount == 1 and initialAliveCount >= RoundConfig.MinPlayersForWinner then
		winner = alivePlayers[1]
		matchEndReason = MatchEndReason.Winner
		log(string.format("WINNER: %s!", winner.Name))
		logMatchEndTrigger(
			MatchEndReason.Winner,
			aliveCount,
			string.format("context=%s winner=%s", sourceContext, winner.Name)
		)
		return true
	end
	
	-- Check max rounds cap
	if RoundConfig.MaxRoundsPerMatch > 0 and currentRound >= RoundConfig.MaxRoundsPerMatch then
		-- Award top survivor(s) for now, just log
		if aliveCount == 1 then
			winner = alivePlayers[1]
		else
			winner = nil
		end
		matchEndReason = MatchEndReason.CapReached
		log(string.format("Max rounds reached (%d), %d players remaining", currentRound, aliveCount))
		logMatchEndTrigger(
			MatchEndReason.CapReached,
			aliveCount,
			string.format("context=%s capType=MaxRounds currentRound=%d", sourceContext, currentRound)
		)
		return true
	end
	
	-- Check max time cap
	if isMatchTimeExceeded() then
		if aliveCount == 1 then
			winner = alivePlayers[1]
		else
			winner = nil
		end
		matchEndReason = MatchEndReason.CapReached
		log(string.format("Max time reached (%.0fs), %d players remaining", 
			tick() - matchStartTime, aliveCount))
		logMatchEndTrigger(
			MatchEndReason.CapReached,
			aliveCount,
			string.format("context=%s capType=MaxTime elapsed=%.1f", sourceContext, tick() - matchStartTime)
		)
		return true
	end
	
	return false
end

--[[
	Safely wait for duration, checking cancellation AND match-end conditions.
	Polls every 0.1s so mid-phase eliminations (OOB, hazards) are detected
	within ~0.1s instead of waiting for the next explicit checkMatchEnd() call.
	Returns true if completed, false if cancelled or match ended.
]]
local function safeWait(seconds: number): boolean
	local elapsed = 0
	local step = 0.1
	
	while elapsed < seconds do
		if not running then
			return false -- Cancelled externally
		end

		cleanupInvalidTargetedRoundFreezes()
		clearExpiredProductFreezes()
		sampleMovementParticipation()
		
		-- Check if match should end mid-phase (e.g., solo player OOB-eliminated)
		if checkMatchEnd("MidPhase:" .. tostring(currentPhase or "Unknown")) then
			running = false
			log(string.format(
				"[RoundLoopStop] source=SafeWait round=%d phase=%s matchEndReason=%s",
				currentRound,
				tostring(currentPhase),
				tostring(matchEndReason)
			))
			log("Match end detected mid-phase — aborting immediately")
			return false
		end
		
		task.wait(math.min(step, seconds - elapsed))
		elapsed = elapsed + step
	end
	
	return true
end

--[[
	Run a single phase.
	Returns false if cancelled.
]]
local function runPhase(phaseName: string, duration: number): boolean
	if not running then return false end
	
	currentPhase = phaseName
	setReplicatedRoundPhase(phaseName)
	log(string.format("Round %d: %s (%.2fs)", currentRound, phaseName, duration))
	
	return safeWait(duration)
end

--[[
	Cleanup mode-specific spawns (brainrot pickups, coins, swords) on any round exit.
]]
local function cleanupModeRound()
	if matchMode == "Brainrot" then BrainrotModeService.OnRoundEnd() end
	if matchMode == "Normal" then RoundCoinService.OnRoundEnd() end
	SwordSpawnService.OnRoundEnd()
	-- Pass currentRound so TTS only despawns on round 6, not earlier rounds
	TungTungSahurService.OnRoundEnd(currentRound)
end

--[[
	Run a single round cycle: FreeMove → Telegraph → BeamWarning → Strike → Recovery
	Returns false if cancelled.
	
	Key flow:
	  - Freeze players
	  - ShowTelegraph (tile warnings pulse — no beams yet)
	  - HideTelegraph + SpawnBeams (tiles vanish, beams appear)
	  - Strike (damage check)
	  - ClearBeams + unfreeze
	  
	Every failure path calls HazardManager.Cleanup() so nothing lingers.
]]
local function runRoundCycle(): boolean
	local nextRound = currentRound + 1
	log(string.format("[RoundLoop] NextRoundStarting round=%d", nextRound))
	currentRound = currentRound + 1
	log(string.format("=== Round %d starting ===", currentRound))
	currentRoundTimings = RoundConfig.GetTimingsForRound(currentRound)
	local pacingTier = if type(RoundConfig.GetPacingTier) == "function"
		then RoundConfig.GetPacingTier(currentRound)
		else (RoundConfig.IsEarlyOverrideRound(currentRound) and "EarlyRounds" or "Base")
	local interactionWindow = math.max(0, math.min(currentRoundTimings.InteractionWindowSeconds or 0, currentRoundTimings.FreeMoveSeconds))
	local freeMoveRemainder = math.max(0, currentRoundTimings.FreeMoveSeconds - interactionWindow)
	local beamWarningDuration = math.max(0, currentRoundTimings.FreezeSeconds - currentRoundTimings.TelegraphSeconds)
	log(string.format(
		"[RoundPacing] round=%d tier=%s interaction=%.2f freeTotal=%.2f freeRemainder=%.2f grace=%.2f telegraph=%.2f beamWarning=%.2f strike=%.2f recovery=%.2f",
		currentRound,
		tostring(pacingTier),
		interactionWindow,
		currentRoundTimings.FreeMoveSeconds,
		freeMoveRemainder,
		currentRoundTimings.TelegraphGraceSeconds,
		currentRoundTimings.TelegraphSeconds,
		beamWarningDuration,
		currentRoundTimings.StrikeSeconds,
		currentRoundTimings.RecoverySeconds
	))
	log(string.format(
		"[RoundTiming] round=%d pacingTier=%s interaction=%.2f freeTotal=%.2f freeRemainder=%.2f grace=%.2f telegraph=%.2f freeze=%.2f strike=%.2f recovery=%.2f",
		currentRound,
		tostring(pacingTier),
		interactionWindow,
		currentRoundTimings.FreeMoveSeconds,
		freeMoveRemainder,
		currentRoundTimings.TelegraphGraceSeconds,
		currentRoundTimings.TelegraphSeconds,
		currentRoundTimings.FreezeSeconds,
		currentRoundTimings.StrikeSeconds,
		currentRoundTimings.RecoverySeconds
	))

	-- Replicate round number for client UI
	local matchStatus = ReplicatedStorage:FindFirstChild("MatchStatus")
	if matchStatus then
		local rv = matchStatus:FindFirstChild("Round")
		if rv then rv.Value = currentRound end
	end
	evaluateRound3Inactivity()
	
	-- Notify MapManager of round start (handles shrinking)
	MapManager.OnRoundStart(currentRound)

	-- Brainrot mode: spawn pickups at round start
	if matchMode == "Brainrot" then
		BrainrotModeService.OnRoundStart(currentRound)
	end

	-- TungTungSahur hazard (Brainrot mode, rounds 2–6)
	TungTungSahurService.OnRoundStart(currentRound, matchMode)

	-- Normal mode: spawn collectible coins
	if matchMode == "Normal" then
		RoundCoinService.OnRoundStart(currentRound)
	end

	-- Sword spawns (both modes, rounds 2-7 only)
	SwordSpawnService.OnRoundStart(currentRound)
	local swordsSpawnedAt = workspace:GetServerTimeNow()
	log(string.format(
		"[SwordTimingCheckpoint] round=%d phase=RoundStart pacingTier=%s swordSpawnAt=%.3f",
		currentRound,
		tostring(pacingTier),
		swordsSpawnedAt
	))
	do
		local feedback = getFeedback()
		if feedback and feedback.OnRoundStart then
			pcall(feedback.OnRoundStart, currentRound, matchMode)
		end
	end
	
	-- Check caps before round starts
	logAliveSnapshot("RoundStartBeforeCapCheck")
	if checkMatchEnd("RoundStart") then
		setMovementCountdownHudState(false, 0, "RoundStartCapReached")
		cleanupModeRound()
		running = false
		return false
	end
	
	-- Phase 1A: Interaction window (sword pickup / first action opportunity)
	local freeMoveWindow = math.max(0, freeMoveRemainder + currentRoundTimings.TelegraphGraceSeconds + interactionWindow)
	local scheduledFreezeAt = workspace:GetServerTimeNow() + freeMoveWindow
	setMovementCountdownHudState(true, freeMoveWindow, string.format("FreeMoveStart_%d", currentRound))
	log(string.format(
		"[InteractionWindowStart] round=%d duration=%.2f swordSpawnAt=%.3f beamPrepStartsIn=%.2f",
		currentRound,
		interactionWindow,
		swordsSpawnedAt,
		freeMoveWindow
	))
	if interactionWindow > 0 and not runPhase(Phase.Interaction, interactionWindow) then
		setMovementCountdownHudState(false, 0, "RoundCancelledInteraction")
		clearRoundLockedFreezes(currentRound, "RoundCancelledInteraction")
		HazardManager.Cleanup()
		cleanupModeRound()
		return false
	end
	log(string.format(
		"[InteractionWindowEnd] round=%d duration=%.2f swordsToBeamDelta=%.2f",
		currentRound,
		interactionWindow,
		math.max(0, workspace:GetServerTimeNow() - swordsSpawnedAt)
	))

	-- Phase 1B: FreeMove remainder (players can keep repositioning)
	log(string.format(
		"[FreezeWarningSchedule] round=%d deadline=%.3f countdownDuration=%.2f",
		currentRound,
		scheduledFreezeAt,
		freeMoveWindow
	))
	if freeMoveRemainder > 0 and not runPhase(Phase.FreeMove, freeMoveRemainder) then
		setMovementCountdownHudState(false, 0, "RoundCancelledFreeMove")
		clearRoundLockedFreezes(currentRound, "RoundCancelledFreeMove")
		HazardManager.Cleanup()
		cleanupModeRound()
		return false
	end
	
	-- Select unsafe zones and show telegraph BEFORE freezing (grace window)
	log(string.format("[BeamPhasePrep] round=%d step=SelectUnsafeZones", currentRound))
	HazardManager.SelectUnsafeZones(currentRound)
	log(string.format("[BeamPhasePrep] round=%d unsafeZones=%d", currentRound, #HazardManager.GetUnsafeZones()))
	log(string.format("[BeamPhasePrep] round=%d step=ShowTelegraph", currentRound))
	HazardManager.ShowTelegraph()
	do
		local feedback = getFeedback()
		if feedback and feedback.OnTelegraphShown then
			pcall(feedback.OnTelegraphShown, currentRound)
		end
	end

	-- Grace window: telegraph is visible but players can still move
	local graceTime = currentRoundTimings.TelegraphGraceSeconds
	if graceTime > 0 then
		log(string.format("Round %d: Telegraph grace window (%.2fs — players can still move)", currentRound, graceTime))
		if not safeWait(graceTime) then
			setMovementCountdownHudState(false, 0, "RoundCancelledGrace")
			clearRoundLockedFreezes(currentRound, "RoundCancelledGrace")
			unfreezeAllPlayers()
			HazardManager.Cleanup()
			cleanupModeRound()
			return false
		end
	end

	-- Freeze players after grace ends
	freezeAllPlayers(currentRoundTimings.FreezeSeconds, scheduledFreezeAt)
	log(string.format("Round %d: Grace ended — players frozen", currentRound))
	
	-- Phase 2: Telegraph remainder (tile warnings continue — NO beams yet)
	local remainingTelegraph = math.max(0, currentRoundTimings.TelegraphSeconds - graceTime)
	if not runPhase(Phase.Telegraph, remainingTelegraph) then
		setMovementCountdownHudState(false, 0, "RoundCancelledTelegraph")
		clearRoundLockedFreezes(currentRound, "RoundCancelledTelegraph")
		unfreezeAllPlayers()
		HazardManager.Cleanup()
		cleanupModeRound()
		return false
	end
	
	-- Phase 3: BeamWarning (tile warnings vanish instantly, beams appear)
	log(string.format(
		"[SwordToBeamTiming] round=%d swordSpawnAt=%.3f beamStartAt=%.3f delta=%.2f",
		currentRound,
		swordsSpawnedAt,
		workspace:GetServerTimeNow(),
		math.max(0, workspace:GetServerTimeNow() - swordsSpawnedAt)
	))
	log(string.format("[BeamPhaseStart] round=%d step=HideTelegraph", currentRound))
	HazardManager.HideTelegraph()
	log(string.format("[BeamPhaseStart] round=%d step=SpawnBeams", currentRound))
	local spawnOk, spawnErr = pcall(function()
		HazardManager.SpawnBeams()
	end)
	if not spawnOk then
		warn(string.format("[RoundManager] SpawnBeams failed round=%d err=%s", currentRound, tostring(spawnErr)))
		matchEndReason = MatchEndReason.Cancelled
		setMovementCountdownHudState(false, 0, "RoundCancelledSpawnBeams")
		clearRoundLockedFreezes(currentRound, "RoundCancelledSpawnBeams")
		unfreezeAllPlayers(true)
		HazardManager.Cleanup()
		cleanupModeRound()
		running = false
		return false
	end
	local beamWarningTime = math.max(0, currentRoundTimings.FreezeSeconds - currentRoundTimings.TelegraphSeconds)
	if not runPhase(Phase.BeamWarning, beamWarningTime) then
		setMovementCountdownHudState(false, 0, "RoundCancelledBeamWarning")
		clearRoundLockedFreezes(currentRound, "RoundCancelledBeamWarning")
		unfreezeAllPlayers()
		HazardManager.Cleanup()
		cleanupModeRound()
		return false
	end
	
	-- Phase 4: Strike (beam fires, eliminate players in unsafe zones)
	log(string.format("[BeamPhaseStrike] round=%d step=Strike", currentRound))
	local strikeOk, strikeErr = pcall(function()
		HazardManager.Strike()
	end)
	if not strikeOk then
		warn(string.format("[RoundManager] Strike failed round=%d err=%s", currentRound, tostring(strikeErr)))
		log(string.format(
			"[RoundCancellation] round=%d phase=%s reason=StrikeError action=AbortRoundAndSkipSurvivorDispatch",
			currentRound,
			tostring(currentPhase)
		))
		matchEndReason = MatchEndReason.Cancelled
		setMovementCountdownHudState(false, 0, "RoundCancelledStrikeError")
		clearRoundLockedFreezes(currentRound, "RoundCancelledStrikeError")
		unfreezeAllPlayers(true)
		HazardManager.Cleanup()
		cleanupModeRound()
		running = false
		return false
	end
	if not runPhase(Phase.Strike, currentRoundTimings.StrikeSeconds) then
		setMovementCountdownHudState(false, 0, "RoundCancelledStrike")
		clearRoundLockedFreezes(currentRound, "RoundCancelledStrike")
		unfreezeAllPlayers()
		HazardManager.Cleanup()
		cleanupModeRound()
		return false
	end
	unfreezeAllPlayers()
	logAliveSnapshot("PostStrikeBeforeWinCheck")
	do
		local feedback = getFeedback()
		if feedback and feedback.FlushPostStrikeAnnouncements then
			pcall(feedback.FlushPostStrikeAnnouncements, currentRound)
		end
	end
	
	-- Check for winner after Strike
	if checkMatchEnd("AfterStrike") then
		setMovementCountdownHudState(false, 0, "MatchEndedAfterStrike")
		HazardManager.Cleanup()
		cleanupModeRound()
		running = false  -- Stop the loop
		return false
	end
	
	-- Phase 5: Recovery (brief pause, cleanup beams)
	HazardManager.ClearBeams()
	if not runPhase(Phase.Recovery, currentRoundTimings.RecoverySeconds) then
		setMovementCountdownHudState(false, 0, "RoundCancelledRecovery")
		clearRoundLockedFreezes(currentRound, "RoundCancelledRecovery")
		HazardManager.Cleanup()
		cleanupModeRound()
		return false
	end

	cleanupModeRound()
	logAliveSnapshot("PostRecovery")

	-- Notify DailyQuestService: all still-alive (InMatch) players survived this round
	local dqs = getDQS()
	local survivors = PlayerStateService.GetPlayersInState(PlayerState.States.InMatch)
	log(string.format(
		"[RoundCompletionDispatch] round=%d survivors=%d services=%s status=RoundCompletedSuccess",
		currentRound,
		#survivors,
		"DailyQuestService,MatchFeedbackService"
	))
	if dqs and dqs.OnRoundSurvived then
		for _, p in ipairs(survivors) do
			pcall(dqs.OnRoundSurvived, p, currentRound)
		end
	end
	do
		local feedback = getFeedback()
		if feedback and feedback.OnRoundSurvived then
			for _, p in ipairs(survivors) do
				pcall(feedback.OnRoundSurvived, p, currentRound)
			end
		end
	end

	log(string.format(
		"[RoundCompleted] round=%d survivedPlayers=%d nextRound=%d winCheckResult=continue",
		currentRound,
		#survivors,
		currentRound + 1
	))

	return true
end

--[[ PUBLIC API ]]

function RoundManager.Init()
	if initialized then
		warn("[RoundManager] Already initialized")
		return
	end
	
	-- Initialize HazardManager (depends on MapManager being ready)
	HazardManager.Init()

	local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotesFolder then
		remotesFolder = Instance.new("Folder")
		remotesFolder.Name = "Remotes"
		remotesFolder.Parent = ReplicatedStorage
	end
	local existingFreeze = remotesFolder:FindFirstChild("FreezeIndicator")
	if not existingFreeze then
		freezeRemote = Instance.new("RemoteEvent")
		freezeRemote.Name = "FreezeIndicator"
		freezeRemote.Parent = remotesFolder
	else
		freezeRemote = existingFreeze
	end
	local existingPaidFreezeNotice = remotesFolder:FindFirstChild("PaidFreezeNotice")
	if not existingPaidFreezeNotice then
		paidFreezeNoticeRemote = Instance.new("RemoteEvent")
		paidFreezeNoticeRemote.Name = "PaidFreezeNotice"
		paidFreezeNoticeRemote.Parent = remotesFolder
	else
		paidFreezeNoticeRemote = existingPaidFreezeNotice
	end
	
	initialized = true
	log("Initialized")
	
	-- Clean up frozen players if they leave
	Players.PlayerRemoving:Connect(function(player)
		freezeStates[player] = nil
		if targetedRoundFreezes[player] then
			targetedRoundFreezes[player] = nil
		end
	end)
end

function RoundManager.TryApplyTargetedRoundFreeze(freezer: Player, target: Player): (boolean, string)
	if not running then
		return false, "ROUND_LOOP_NOT_RUNNING"
	end
	if currentRound <= 0 then
		return false, "ROUND_NOT_STARTED"
	end
	if currentRound >= 7 then
		return false, "ROUND_LOCKED_AT_OR_AFTER_7"
	end
	if not freezer or not freezer.Parent then
		return false, "FREEZER_MISSING"
	end
	if not target or not target.Parent then
		return false, "TARGET_MISSING"
	end
	if freezer == target then
		return false, "TARGET_SELF"
	end
	if PlayerStateService.IsAFK(freezer) or PlayerStateService.IsAFK(target) then
		return false, "AFK_BLOCKED"
	end
	if PlayerStateService.GetState(freezer) ~= PlayerState.States.InMatch then
		return false, "FREEZER_NOT_INMATCH"
	end
	if PlayerStateService.GetState(target) ~= PlayerState.States.InMatch then
		return false, "TARGET_NOT_INMATCH"
	end
	if isRoundFreezeLocked(target) then
		return false, "TARGET_ALREADY_FROZEN_THIS_ROUND"
	end

	local freezeDuration = getDevProductFreezeSecondsForRound(currentRound)
	targetedRoundFreezes[target] = {
		round = currentRound,
		freezerUserId = freezer.UserId,
		freezerName = freezer.Name,
		appliedAt = tick(),
		expiresAt = tick() + freezeDuration,
	}
	target:SetAttribute("RoundLockedFreeze", true)
	addFreezeReason(target, FREEZE_REASON_DEVPRODUCT)
	log(string.format("[ProductFreezeStart] target=%s freezer=%s round=%d activeReasons=%s",
		target.Name,
		freezer.Name,
		currentRound,
		collectReasonKeys((freezeStates[target] and freezeStates[target].reasons) or {})))
	log(string.format("[ProductFreezeDuration] target=%s duration=%.2fs expiresIn=%.2fs",
		target.Name, freezeDuration, freezeDuration))

	if paidFreezeNoticeRemote then
		paidFreezeNoticeRemote:FireClient(target, "Show", freezer.Name, freezeDuration)
		log(string.format("[ProductFreezeUIShown] target=%s freezer=%s duration=%.2fs", target.Name, freezer.Name, freezeDuration))
	end

	log(string.format(
		"[TargetedFreeze] purchaser=%s target=%s phase=%s round=%d",
		freezer.Name,
		target.Name,
		tostring(currentPhase),
		currentRound
	))
	return true, "OK"
end

function RoundManager.IsRunning(): boolean
	return running
end

function RoundManager.GetCurrentRound(): number
	return currentRound
end

function RoundManager.GetCurrentPhase(): string?
	return currentPhase
end

function RoundManager.GetMatchEndReason(): string?
	return matchEndReason
end

function RoundManager.GetWinner(): Player?
	return winner
end

function RoundManager.StartRoundLoop(mode: string?)
	if running then
		warn("[RoundManager] Loop already running")
		return
	end

	matchMode = mode or "Normal"
	running = true
	currentRound = 0
	currentPhase = nil
	currentRoundTimings = RoundConfig.GetTimingsForRound(0)
	setReplicatedRoundPhase(nil)
	matchEndReason = nil
	winner = nil
	
	-- Track match start for time limit
	matchStartTime = tick()
	
	-- Track initial player count for winner detection
	local alivePlayers = PlayerStateService.GetPlayersInState(PlayerState.States.InMatch)
	initialAliveCount = #alivePlayers
	movementParticipationByPlayer = {}
	for _, player in ipairs(alivePlayers) do
		ensureMovementTracker(player)
	end
	
	log(string.format("Round loop started with %d players", initialAliveCount))
	setMovementCountdownHudState(false, 0, "StartRoundLoop")
	log(string.format(
		"[RoundLoopConfig] mode=%s maxRounds=%d maxSeconds=%d baseFree=%.2f baseGrace=%.2f baseTelegraph=%.2f baseFreeze=%.2f baseStrike=%.2f baseRecovery=%.2f pacingConfig=RoundPacingConfig",
		tostring(matchMode),
		tonumber(RoundConfig.MaxRoundsPerMatch) or -1,
		tonumber(RoundConfig.MaxMatchSeconds) or -1,
		tonumber(RoundConfig.BaseTimings.FreeMoveSeconds) or 0,
		tonumber(RoundConfig.BaseTimings.TelegraphGraceSeconds) or 0,
		tonumber(RoundConfig.BaseTimings.TelegraphSeconds) or 0,
		tonumber(RoundConfig.BaseTimings.FreezeSeconds) or 0,
		tonumber(RoundConfig.BaseTimings.StrikeSeconds) or 0,
		tonumber(RoundConfig.BaseTimings.RecoverySeconds) or 0
	))
	
	task.spawn(function()
		local loopOk, loopErr = xpcall(function()
			while running do
				local completed = runRoundCycle()
				if not completed then
					break
				end
			end
		end, debug.traceback)
		if not loopOk then
			warn("[RoundManager] Round loop crashed:", loopErr)
			matchEndReason = MatchEndReason.Cancelled
			running = false
		end
		
		-- Cleanup
		unfreezeAllPlayers(true)
		HazardManager.Cleanup()
		currentPhase = nil
		currentRoundTimings = RoundConfig.GetTimingsForRound(0)
		setReplicatedRoundPhase(nil)
		movementParticipationByPlayer = {}
		setMovementCountdownHudState(false, 0, "RoundLoopEnded")
		running = false
		log("Round loop ended")
	end)
end

function RoundManager.StopRoundLoop()
	if not running then
		return
	end
	
	log("Stopping round loop...")
	running = false
	currentPhase = nil
	currentRoundTimings = RoundConfig.GetTimingsForRound(0)
	setReplicatedRoundPhase(nil)
	setMovementCountdownHudState(false, 0, "StopRoundLoop")
	-- The loop will detect this and exit on next safeWait check
end

return RoundManager
