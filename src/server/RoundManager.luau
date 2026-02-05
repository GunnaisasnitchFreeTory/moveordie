--[[
	RoundManager
	Server-side round loop controller.
	
	Runs during Playing phase only.
	Loop: Freeze → Telegraph → Strike → Recovery → repeat
	
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

--[[ PHASE CONSTANTS ]]
local Phase = {
	Freeze = "Freeze",
	Telegraph = "Telegraph",
	Strike = "Strike",
	Recovery = "Recovery",
}

--[[ INTERNAL STATE ]]
local initialized = false
local running = false
local currentRound = 0
local currentPhase: string? = nil

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
	Run a single round cycle: Freeze → Telegraph → Strike → Recovery
	Returns false if cancelled.
]]
local function runRoundCycle(): boolean
	currentRound = currentRound + 1
	log(string.format("=== Round %d starting ===", currentRound))
	
	-- Phase 1: Freeze
	freezeAllPlayers()
	if not runPhase(Phase.Freeze, RoundConfig.FreezeSeconds) then
		unfreezeAllPlayers()
		return false
	end
	unfreezeAllPlayers()
	
	-- Phase 2: Telegraph (visual warning - placeholder for now)
	if not runPhase(Phase.Telegraph, RoundConfig.TelegraphSeconds) then
		return false
	end
	-- Future: Select unsafe tiles, show warning effects
	
	-- Phase 3: Strike (beam fires - placeholder for now)
	if not runPhase(Phase.Strike, RoundConfig.StrikeSeconds) then
		return false
	end
	-- Future: Eliminate players on unsafe tiles
	
	-- Phase 4: Recovery (brief pause)
	if not runPhase(Phase.Recovery, RoundConfig.RecoverySeconds) then
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

function RoundManager.StartRoundLoop()
	if running then
		warn("[RoundManager] Loop already running")
		return
	end
	
	running = true
	currentRound = 0
	currentPhase = nil
	
	log("Round loop started")
	
	task.spawn(function()
		while running do
			-- Run a round cycle
			local completed = runRoundCycle()
			
			if not completed then
				break -- Cancelled
			end
			
			-- Check max rounds limit
			if RoundConfig.MaxRoundsPerMatch > 0 and currentRound >= RoundConfig.MaxRoundsPerMatch then
				log(string.format("Max rounds reached (%d)", RoundConfig.MaxRoundsPerMatch))
				break
			end
		end
		
		-- Cleanup
		unfreezeAllPlayers()
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

