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

-- Freeze state storage (player -> original values)
local frozenPlayers: { [Player]: { WalkSpeed: number, JumpPower: number, JumpHeight: number } } = {}

local RoundManager = {}

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

--[[
	Freeze a single player (store original values, set to 0).
]]
local function freezePlayer(player: Player)
	local character = player.Character
	if not character then return end
	
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end
	
	-- Store original values
	frozenPlayers[player] = {
		WalkSpeed = humanoid.WalkSpeed,
		JumpPower = humanoid.JumpPower,
		JumpHeight = humanoid.JumpHeight,
	}
	
	-- Freeze
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0
	humanoid.JumpHeight = 0
end

--[[
	Unfreeze a single player (restore original values).
]]
local function unfreezePlayer(player: Player)
	local stored = frozenPlayers[player]
	if not stored then return end
	
	local character = player.Character
	if character then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.WalkSpeed = stored.WalkSpeed
			humanoid.JumpPower = stored.JumpPower
			humanoid.JumpHeight = stored.JumpHeight
		end
	end
	
	frozenPlayers[player] = nil
end

--[[
	Freeze all InMatch players.
]]
local function freezeAllPlayers()
	local players = getInMatchPlayers()
	for _, player in ipairs(players) do
		freezePlayer(player)
	end
	log(string.format("Froze %d players", #players))
end

--[[
	Unfreeze all frozen players.
]]
local function unfreezeAllPlayers()
	local count = 0
	for player, _ in pairs(frozenPlayers) do
		unfreezePlayer(player)
		count = count + 1
	end
	frozenPlayers = {}
	if count > 0 then
		log(string.format("Unfroze %d players", count))
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
	
	-- Check caps before round starts
	if checkMatchEnd() then
		running = false
		return false
	end
	
	-- Phase 1: FreeMove (players can reposition)
	if not runPhase(Phase.FreeMove, RoundConfig.FreeMoveSeconds) then
		HazardManager.Cleanup()
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
			unfreezeAllPlayers()
			HazardManager.Cleanup()
			return false
		end
	end

	-- Freeze players after grace ends
	freezeAllPlayers()
	log(string.format("Round %d: Grace ended — players frozen", currentRound))
	
	-- Phase 2: Telegraph remainder (tile warnings continue — NO beams yet)
	local remainingTelegraph = math.max(0, RoundConfig.TelegraphSeconds - graceTime)
	if not runPhase(Phase.Telegraph, remainingTelegraph) then
		unfreezeAllPlayers()
		HazardManager.Cleanup()
		return false
	end
	
	-- Phase 3: BeamWarning (tile warnings vanish instantly, beams appear)
	HazardManager.HideTelegraph()
	HazardManager.SpawnBeams()
	local beamWarningTime = math.max(0, RoundConfig.FreezeSeconds - RoundConfig.TelegraphSeconds)
	if not runPhase(Phase.BeamWarning, beamWarningTime) then
		unfreezeAllPlayers()
		HazardManager.Cleanup()
		return false
	end
	
	-- Phase 4: Strike (beam fires, eliminate players in unsafe zones)
	HazardManager.Strike()
	if not runPhase(Phase.Strike, RoundConfig.StrikeSeconds) then
		unfreezeAllPlayers()
		HazardManager.Cleanup()
		return false
	end
	unfreezeAllPlayers()
	
	-- Check for winner after Strike
	if checkMatchEnd() then
		HazardManager.Cleanup()
		running = false  -- Stop the loop
		return false
	end
	
	-- Phase 5: Recovery (brief pause, cleanup beams)
	HazardManager.ClearBeams()
	if not runPhase(Phase.Recovery, RoundConfig.RecoverySeconds) then
		HazardManager.Cleanup()
		return false
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
	
	initialized = true
	log("Initialized")
	
	-- Clean up frozen players if they leave
	Players.PlayerRemoving:Connect(function(player)
		if frozenPlayers[player] then
			frozenPlayers[player] = nil
		end
	end)
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

function RoundManager.StartRoundLoop()
	if running then
		warn("[RoundManager] Loop already running")
		return
	end
	
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
		unfreezeAllPlayers()
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
