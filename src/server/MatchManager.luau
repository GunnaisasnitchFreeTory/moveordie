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
local SpawnConfig = require(Shared:WaitForChild("SpawnConfig"))
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
	Safely teleport a player's character to a CFrame.
	Returns true on success, false if character not ready.
]]
local function safeTeleport(player: Player, targetCFrame: CFrame): boolean
	local character = player.Character
	if not character then return false end
	
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	
	if not humanoid or not rootPart then return false end
	if humanoid.Health <= 0 then return false end
	
	-- Teleport
	rootPart.CFrame = targetCFrame
	
	-- Kill velocity to prevent fling
	rootPart.AssemblyLinearVelocity = Vector3.zero
	rootPart.AssemblyAngularVelocity = Vector3.zero
	
	return true
end

--[[
	Teleport a list of players to arena spawn points.
]]
local function teleportPlayersToArena(players: { Player })
	if #players == 0 then return end
	
	local spawnCFrames = MapManager.GetArenaSpawnCFrames(#players)
	if #spawnCFrames == 0 then
		warn("[MatchManager] No arena spawn CFrames available")
		return
	end
	
	local teleported = 0
	
	for i, player in ipairs(players) do
		local spawnCFrame = spawnCFrames[((i - 1) % #spawnCFrames) + 1]
		
		-- Try immediate teleport
		if safeTeleport(player, spawnCFrame) then
			teleported = teleported + 1
		else
			-- Retry after delay
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

--[[
	Teleport a list of players back to lobby spawn.
]]
local function teleportPlayersToLobby(players: { Player })
	if #players == 0 then return end
	if not SpawnConfig.ReturnToLobbyOnEnd then return end
	
	local lobbyCFrame = MapManager.GetLobbySpawnCFrame()
	local teleported = 0
	
	for i, player in ipairs(players) do
		-- Slight spread so they don't stack
		local offset = Vector3.new(
			(i % 5 - 2) * 3,
			0,
			math.floor(i / 5) * 3
		)
		local targetCFrame = lobbyCFrame + offset
		
		if safeTeleport(player, targetCFrame) then
			teleported = teleported + 1
		else
			-- Retry after delay
			task.spawn(function()
				for _ = 1, SpawnConfig.MaxTeleportRetries do
					task.wait(SpawnConfig.TeleportRetryDelay)
					if safeTeleport(player, targetCFrame) then
						break
					end
				end
			end)
		end
	end
	
	log(string.format("Returned %d players to Lobby spawn", teleported))
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
	Set all Waiting players to InMatch and teleport them to arena.
	Called at start of Playing phase.
]]
local function setWaitingToInMatch()
	local waitingPlayers = PlayerStateService.GetPlayersInState(PlayerState.States.Waiting)
	local playersToTeleport = {}
	
	for _, player in ipairs(waitingPlayers) do
		-- Double-check they're not AFK (safety)
		if not PlayerStateService.IsAFK(player) then
			PlayerStateService.SetState(player, PlayerState.States.InMatch)
			table.insert(playersToTeleport, player)
		end
	end
	
	log(string.format("Moved %d players to InMatch", #playersToTeleport))
	
	-- Teleport to arena
	teleportPlayersToArena(playersToTeleport)
	
	return #playersToTeleport
end

--[[
	Set all remaining InMatch players back to Lobby and teleport them.
	Called at end of Playing phase.
	(Eliminated players are already in Lobby from Strike)
]]
local function setMatchPlayersToLobby()
	local inMatchPlayers = PlayerStateService.GetPlayersInState(PlayerState.States.InMatch)
	
	if #inMatchPlayers == 0 then
		log("No remaining InMatch players to return")
		return
	end
	
	-- Teleport back to lobby
	teleportPlayersToLobby(inMatchPlayers)
	
	-- Update state
	for _, player in ipairs(inMatchPlayers) do
		PlayerStateService.SetState(player, PlayerState.States.Lobby)
	end
	
	log(string.format("Returned %d remaining players to Lobby", #inMatchPlayers))
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
	log("Playing started — waiting for RoundManager to complete")
	
	-- Notify MapManager that match is starting
	MapManager.OnMatchStart()
	
	-- Move all waiting players into the match (includes teleport)
	setWaitingToInMatch()
	
	-- Start the round loop
	RoundManager.StartRoundLoop()
	
	-- Wait for RoundManager to complete (winner, no winners, or cap reached)
	-- RoundManager handles its own time/round caps internally
	while RoundManager.IsRunning() do
		task.wait(0.5)
	end
	
	-- Get the end reason
	local endReason = RoundManager.GetMatchEndReason()
	log(string.format("Round loop completed — reason: %s", endReason or "unknown"))
	
	-- Notify MapManager that match is ending
	MapManager.OnMatchEnd()
	
	return true -- Signal to continue to Ending
end

local function runEnding()
	setMatchState(MatchState.States.Ending)
	phaseEndTime = tick() + Config.EndingSeconds
	
	-- Log match result
	local matchEndReason = RoundManager.GetMatchEndReason()
	local winner = RoundManager.GetWinner()
	
	if matchEndReason == "Winner" and winner then
		log(string.format("Ending started (%ds) — WINNER: %s", Config.EndingSeconds, winner.Name))
	elseif matchEndReason == "NoWinners" then
		log(string.format("Ending started (%ds) — No winners", Config.EndingSeconds))
	else
		log(string.format("Ending started (%ds)", Config.EndingSeconds))
	end
	
	-- Return all InMatch and Spectating players to Lobby (includes teleport)
	setMatchPlayersToLobby()
	
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
