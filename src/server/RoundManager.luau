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
local BrainrotModeService    = require(Server:WaitForChild("BrainrotModeService"))
local RoundCoinService       = require(Server:WaitForChild("RoundCoinService"))
local SwordSpawnService      = require(Server:WaitForChild("SwordSpawnService"))
local TungTungSahurService   = require(Server:WaitForChild("TungTungSahurService"))

--[[ PHASE CONSTANTS ]]
local Phase = {
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

local RoundManager = {}

local _DQS = nil
local function getDQS()
	if _DQS ~= nil then return _DQS end
	local ok, mod = pcall(require, Server:FindFirstChild("DailyQuestService"))
	if ok and mod then _DQS = mod else _DQS = false end
	return _DQS
end

--[[ HELPERS ]]

local function log(...)
	if RoundConfig.DebugLog then
		print("[RoundManager]", ...)
	end
end

--[[
	Get all players currently InMatch.
]]
local function getInMatchPlayers(): { Player }
	return PlayerStateService.GetPlayersInState(PlayerState.States.InMatch)
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
local function freezeAllPlayers()
	local players = getInMatchPlayers()
	log(string.format("[GameplayFreezeStart] round=%d players=%d", currentRound, #players))
	for _, player in ipairs(players) do
		addFreezeReason(player, FREEZE_REASON_GAMEPLAY)
	end
	if freezeRemote then
		for _, player in ipairs(players) do
			freezeRemote:FireClient(player, "Freeze", RoundConfig.FreezeSeconds)
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

--[[
	Check if match should end based on alive player count or limits.
	Returns true if match should end, sets matchEndReason and winner.
]]
local function checkMatchEnd(): boolean
	local alivePlayers = PlayerStateService.GetPlayersInState(PlayerState.States.InMatch)
	local aliveCount = #alivePlayers
	
	-- No one survived
	if aliveCount == 0 then
		winner = nil
		matchEndReason = MatchEndReason.NoWinners
		log("No winners - all players eliminated")
		return true
	end
	
	-- Winner: only if we started with 2+ players and now have 1
	if aliveCount == 1 and initialAliveCount >= RoundConfig.MinPlayersForWinner then
		winner = alivePlayers[1]
		matchEndReason = MatchEndReason.Winner
		log(string.format("WINNER: %s!", winner.Name))
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
		
		-- Check if match should end mid-phase (e.g., solo player OOB-eliminated)
		if checkMatchEnd() then
			running = false
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
	currentRound = currentRound + 1
	log(string.format("=== Round %d starting ===", currentRound))

	-- Replicate round number for client UI
	local matchStatus = ReplicatedStorage:FindFirstChild("MatchStatus")
	if matchStatus then
		local rv = matchStatus:FindFirstChild("Round")
		if rv then rv.Value = currentRound end
	end
	
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

	-- Sword spawns (both modes, rounds 1-7 only)
	SwordSpawnService.OnRoundStart(currentRound)
	
	-- Check caps before round starts
	if checkMatchEnd() then
		cleanupModeRound()
		running = false
		return false
	end
	
	-- Phase 1: FreeMove (players can reposition)
	if not runPhase(Phase.FreeMove, RoundConfig.FreeMoveSeconds) then
		clearRoundLockedFreezes(currentRound, "RoundCancelledFreeMove")
		HazardManager.Cleanup()
		cleanupModeRound()
		return false
	end
	
	-- Select unsafe zones and show telegraph BEFORE freezing (grace window)
	HazardManager.SelectUnsafeZones(currentRound)
	HazardManager.ShowTelegraph()

	-- Grace window: telegraph is visible but players can still move
	local graceTime = RoundConfig.TelegraphGraceSeconds or 0
	if graceTime > 0 then
		log(string.format("Round %d: Telegraph grace window (%.2fs — players can still move)", currentRound, graceTime))
		if not safeWait(graceTime) then
			clearRoundLockedFreezes(currentRound, "RoundCancelledGrace")
			unfreezeAllPlayers()
			HazardManager.Cleanup()
			cleanupModeRound()
			return false
		end
	end

	-- Freeze players after grace ends
	freezeAllPlayers()
	log(string.format("Round %d: Grace ended — players frozen", currentRound))
	
	-- Phase 2: Telegraph remainder (tile warnings continue — NO beams yet)
	local remainingTelegraph = math.max(0, RoundConfig.TelegraphSeconds - graceTime)
	if not runPhase(Phase.Telegraph, remainingTelegraph) then
		clearRoundLockedFreezes(currentRound, "RoundCancelledTelegraph")
		unfreezeAllPlayers()
		HazardManager.Cleanup()
		cleanupModeRound()
		return false
	end
	
	-- Phase 3: BeamWarning (tile warnings vanish instantly, beams appear)
	HazardManager.HideTelegraph()
	HazardManager.SpawnBeams()
	local beamWarningTime = math.max(0, RoundConfig.FreezeSeconds - RoundConfig.TelegraphSeconds)
	if not runPhase(Phase.BeamWarning, beamWarningTime) then
		clearRoundLockedFreezes(currentRound, "RoundCancelledBeamWarning")
		unfreezeAllPlayers()
		HazardManager.Cleanup()
		cleanupModeRound()
		return false
	end
	
	-- Phase 4: Strike (beam fires, eliminate players in unsafe zones)
	HazardManager.Strike()
	if not runPhase(Phase.Strike, RoundConfig.StrikeSeconds) then
		clearRoundLockedFreezes(currentRound, "RoundCancelledStrike")
		unfreezeAllPlayers()
		HazardManager.Cleanup()
		cleanupModeRound()
		return false
	end
	unfreezeAllPlayers()
	
	-- Check for winner after Strike
	if checkMatchEnd() then
		HazardManager.Cleanup()
		cleanupModeRound()
		running = false  -- Stop the loop
		return false
	end
	
	-- Phase 5: Recovery (brief pause, cleanup beams)
	HazardManager.ClearBeams()
	if not runPhase(Phase.Recovery, RoundConfig.RecoverySeconds) then
		clearRoundLockedFreezes(currentRound, "RoundCancelledRecovery")
		HazardManager.Cleanup()
		cleanupModeRound()
		return false
	end

	cleanupModeRound()

	-- Notify DailyQuestService: all still-alive (InMatch) players survived this round
	local dqs = getDQS()
	if dqs and dqs.OnRoundSurvived then
		local survivors = PlayerStateService.GetPlayersInState(PlayerState.States.InMatch)
		for _, p in ipairs(survivors) do
			pcall(dqs.OnRoundSurvived, p)
		end
	end

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
	matchEndReason = nil
	winner = nil
	
	-- Track match start for time limit
	matchStartTime = tick()
	
	-- Track initial player count for winner detection
	local alivePlayers = PlayerStateService.GetPlayersInState(PlayerState.States.InMatch)
	initialAliveCount = #alivePlayers
	
	log(string.format("Round loop started with %d players", initialAliveCount))
	
	task.spawn(function()
		while running do
			-- Run a round cycle
			local completed = runRoundCycle()
			
			if not completed then
				break -- Cancelled or match ended
			end
		end
		
		-- Cleanup
		unfreezeAllPlayers(true)
		HazardManager.Cleanup()
		currentPhase = nil
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
	-- The loop will detect this and exit on next safeWait check
end

return RoundManager