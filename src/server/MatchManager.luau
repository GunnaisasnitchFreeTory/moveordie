--[[
	MatchManager
	Server-side match lifecycle controller.
	
	Loop: Intermission → Playing → Ending → repeat
	
	API:
		Init()                    → Initialize the manager
		StartLoop()               → Begin the infinite match loop
		GetState()                → Current match state
		GetTimeRemaining()        → Seconds left in current phase
		GetEligiblePlayers()      → Players who can join next match
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Server = ServerScriptService:WaitForChild("Server")

local MatchState = require(Shared:WaitForChild("MatchState"))
local PlayerState = require(Shared:WaitForChild("PlayerState"))
local PlayerStateService = require(Server:WaitForChild("PlayerStateService"))
local MapManager = require(Server:WaitForChild("MapManager"))
local RoundManager = require(Server:WaitForChild("RoundManager"))

--[[ CONFIGURATION ]]
local Config = {
	IntermissionSeconds = 15,
	PlayingSeconds = 20,
	EndingSeconds = 5,
	MinPlayersToStart = 1,  -- For testing; increase for production
	DebugLog = true,
}

--[[ INTERNAL STATE ]]
local currentState: string = MatchState.States.Intermission
local phaseEndTime: number = 0
local initialized = false
local loopRunning = false

local MatchManager = {}

--[[ HELPERS ]]

local function log(...)
	if Config.DebugLog then
		print("[MatchManager]", ...)
	end
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
	log(string.format("State: %s → %s", oldState, newState))
end

--[[
	Get players eligible for match participation.
	Eligible = in Lobby or Waiting state, and not AFK.
]]
function MatchManager.GetEligiblePlayers(): { Player }
	local eligible = {}
	
	for _, player in ipairs(Players:GetPlayers()) do
		local state = PlayerStateService.GetState(player)
		local isAFK = PlayerStateService.IsAFK(player)
		
		-- Eligible if in Lobby or Waiting and not AFK
		if not isAFK and (state == PlayerState.States.Lobby or state == PlayerState.States.Waiting) then
			table.insert(eligible, player)
		end
	end
	
	return eligible
end

--[[
	Set all eligible players to Waiting state.
	Called during Intermission.
]]
local function setEligibleToWaiting()
	local eligible = MatchManager.GetEligiblePlayers()
	for _, player in ipairs(eligible) do
		local state = PlayerStateService.GetState(player)
		if state == PlayerState.States.Lobby then
			PlayerStateService.SetState(player, PlayerState.States.Waiting)
		end
	end
end

--[[
	Set all Waiting players to InMatch.
	Called at start of Playing phase.
]]
local function setWaitingToInMatch()
	local waitingPlayers = PlayerStateService.GetPlayersInState(PlayerState.States.Waiting)
	local count = 0
	
	for _, player in ipairs(waitingPlayers) do
		-- Double-check they're not AFK (safety)
		if not PlayerStateService.IsAFK(player) then
			PlayerStateService.SetState(player, PlayerState.States.InMatch)
			count = count + 1
		end
	end
	
	log(string.format("Moved %d players to InMatch", count))
	return count
end

--[[
	Set all InMatch players back to Lobby.
	Called at end of Playing phase (temporary until teleport/map exists).
]]
local function setInMatchToLobby()
	local inMatchPlayers = PlayerStateService.GetPlayersInState(PlayerState.States.InMatch)
	
	for _, player in ipairs(inMatchPlayers) do
		PlayerStateService.SetState(player, PlayerState.States.Lobby)
	end
	
	log(string.format("Returned %d players to Lobby", #inMatchPlayers))
end

--[[ PHASE HANDLERS ]]

local function runIntermission()
	setMatchState(MatchState.States.Intermission)
	phaseEndTime = tick() + Config.IntermissionSeconds
	log(string.format("Intermission started (%ds)", Config.IntermissionSeconds))
	
	-- Main intermission loop
	while tick() < phaseEndTime do
		-- Continuously set new eligible players to Waiting
		setEligibleToWaiting()
		task.wait(1)
	end
	
	-- Final check for eligible players
	setEligibleToWaiting()
end

local function runPlaying()
	local waitingPlayers = PlayerStateService.GetPlayersInState(PlayerState.States.Waiting)
	
	if #waitingPlayers < Config.MinPlayersToStart then
		log(string.format("Not enough players (%d/%d), skipping match", #waitingPlayers, Config.MinPlayersToStart))
		-- Return waiting players to lobby since we're skipping
		for _, player in ipairs(waitingPlayers) do
			PlayerStateService.SetState(player, PlayerState.States.Lobby)
		end
		return false -- Signal to skip Ending phase
	end
	
	setMatchState(MatchState.States.Playing)
	phaseEndTime = tick() + Config.PlayingSeconds
	log(string.format("Playing started (%ds)", Config.PlayingSeconds))
	
	-- Notify MapManager that match is starting
	MapManager.OnMatchStart()
	
	-- Move all waiting players into the match
	setWaitingToInMatch()
	
	-- Start the round loop
	RoundManager.StartRoundLoop()
	
	-- Main playing loop - wait for time to expire or rounds to complete
	while tick() < phaseEndTime do
		-- Check if round loop ended early (e.g., max rounds reached)
		if not RoundManager.IsRunning() then
			log("Round loop ended early, proceeding to Ending")
			break
		end
		task.wait(1)
	end
	
	-- Stop round loop (in case time expired before rounds finished)
	RoundManager.StopRoundLoop()
	
	-- Notify MapManager that match is ending
	MapManager.OnMatchEnd()
	
	return true -- Signal to continue to Ending
end

local function runEnding()
	setMatchState(MatchState.States.Ending)
	phaseEndTime = tick() + Config.EndingSeconds
	log(string.format("Ending started (%ds)", Config.EndingSeconds))
	
	-- Return all InMatch players to Lobby
	setInMatchToLobby()
	
	-- Wait for ending phase
	while tick() < phaseEndTime do
		task.wait(1)
	end
end

--[[ PUBLIC API ]]

function MatchManager.Init()
	if initialized then
		warn("[MatchManager] Already initialized")
		return
	end
	
	-- Initialize dependencies
	MapManager.Init()
	RoundManager.Init()
	
	initialized = true
	log("Initialized")
end

function MatchManager.GetState(): string
	return currentState
end

function MatchManager.GetTimeRemaining(): number
	local remaining = phaseEndTime - tick()
	return math.max(0, math.floor(remaining))
end

function MatchManager.StartLoop()
	if loopRunning then
		warn("[MatchManager] Loop already running")
		return
	end
	loopRunning = true
	log("Loop started")
	
	-- Run in a separate thread
	task.spawn(function()
		while loopRunning do
			-- Phase 1: Intermission
			runIntermission()
			
			-- Phase 2: Playing
			local playedMatch = runPlaying()
			
			-- Phase 3: Ending (only if match actually ran)
			if playedMatch then
				runEnding()
			end
		end
	end)
end

function MatchManager.StopLoop()
	loopRunning = false
	log("Loop stopped")
end

return MatchManager

