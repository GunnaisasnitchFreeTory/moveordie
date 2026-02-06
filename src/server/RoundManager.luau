--[[
	RoundManager
	Server-side round loop controller.
	
	Runs during Playing phase only.
	Loop: FreeMove → Freeze/Telegraph → Strike → Recovery → repeat
	
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
	FreezeTelegraph = "Freeze/Telegraph",
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
	Safely wait for duration, checking cancellation.
	Returns true if completed, false if cancelled.
]]
local function safeWait(seconds: number): boolean
	local elapsed = 0
	local step = 0.1
	
	while elapsed < seconds do
		if not running then
			return false -- Cancelled
		end
		task.wait(math.min(step, seconds - elapsed))
		elapsed = elapsed + step
	end
	
	return true
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
	Run a single round cycle: FreeMove → Freeze/Telegraph → Strike → Recovery
	Returns false if cancelled.
]]
local function runRoundCycle(): boolean
	currentRound = currentRound + 1
	log(string.format("=== Round %d starting ===", currentRound))
	
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
	
	-- Phase 2: Freeze/Telegraph (players frozen, warning visible)
	freezeAllPlayers()
	HazardManager.SelectUnsafeZones(currentRound)
	HazardManager.SpawnTelegraphs()
	if not runPhase(Phase.FreezeTelegraph, RoundConfig.FreezeSeconds) then
		unfreezeAllPlayers()
		HazardManager.Cleanup()
		return false
	end
	
	-- Phase 3: Strike (beam fires, eliminate players in unsafe zones)
	HazardManager.Strike()
	if not runPhase(Phase.Strike, RoundConfig.StrikeSeconds) then
		unfreezeAllPlayers()
		HazardManager.Cleanup()
		return false
	end
	unfreezeAllPlayers()
	
	-- Check for winner after Strike
	if checkMatchEnd() then
		HazardManager.ClearTelegraphs()
		running = false  -- Stop the loop
		return false
	end
	
	-- Phase 4: Recovery (brief pause, cleanup beams)
	HazardManager.ClearTelegraphs()
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
