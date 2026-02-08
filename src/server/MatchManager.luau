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
local EliminationTracker = require(Server:WaitForChild("EliminationTracker"))
local EconomyService = require(Server:WaitForChild("EconomyService"))

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

-- Replicated status values (created in Init, read by client UI)
local replicatedState: StringValue = nil     -- "Intermission" | "Playing" | "Ending"
local replicatedRound: IntValue = nil        -- Current round number
local replicatedPhaseEnd: NumberValue = nil  -- workspace:GetServerTimeNow() at phase end

local MatchManager = {}

--[[ HELPERS ]]

local function log(...)
	if Config.DebugLog then
		print("[MatchManager]", ...)
	end
end

--[[
	Replicate the phase end time so the client HUD can show a countdown.
	`durationSeconds` is the length of the phase starting NOW.
]]
local function replicatePhaseEnd(durationSeconds: number)
	if replicatedPhaseEnd then
		replicatedPhaseEnd.Value = workspace:GetServerTimeNow() + durationSeconds
		log(string.format("Replicated PhaseEndTime → +%ds (value=%.1f)", durationSeconds, replicatedPhaseEnd.Value))
	else
		log("replicatedPhaseEnd is nil — skipping replication")
	end
end

--[[
	Replicate the current round number for the client HUD.
]]
local function replicateRound(round: number)
	if replicatedRound then
		replicatedRound.Value = round
		log(string.format("Replicated Round → %d", round))
	else
		log("replicatedRound is nil — skipping replication")
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

	-- Replicate state for client UI
	if replicatedState then
		replicatedState.Value = newState
	end
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
	replicatePhaseEnd(Config.IntermissionSeconds)
	replicateRound(0)
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
	
	-- Initialize elimination tracking for this match
	local matchPlayers = PlayerStateService.GetPlayersInState(PlayerState.States.InMatch)
	EliminationTracker.Reset(matchPlayers)
	
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

--[[
	Build placement rankings and award coins to all match participants.
	Must be called BEFORE setMatchPlayersToLobby() (while survivors are still InMatch).
]]
local function resolveRankingsAndReward()
	-- Survivors = players still InMatch at match end
	local survivors = PlayerStateService.GetPlayersInState(PlayerState.States.InMatch)
	local rankings = EliminationTracker.BuildRankings(survivors)
	
	if #rankings == 0 then
		log("No rankings to process (no players)")
		return
	end
	
	-- Award coins
	local totalAwarded = 0
	local matchId = EliminationTracker.GetMatchId()
	
	for _, group in ipairs(rankings) do
		for _, entry in ipairs(group.players) do
			if entry.player and entry.player.Parent and group.coins > 0 then
				EconomyService.AwardCoins(
					entry.player,
					group.coins,
					string.format("Match#%d Place#%d", matchId, group.placement)
				)
				totalAwarded = totalAwarded + group.coins
			end
		end
	end
	
	log(string.format("Awarded %d total coins across %d placement groups", totalAwarded, #rankings))
end

local function runEnding()
	setMatchState(MatchState.States.Ending)
	phaseEndTime = tick() + Config.EndingSeconds
	replicatePhaseEnd(Config.EndingSeconds)
	
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
	
	-- Build rankings and award coins BEFORE returning players to lobby
	resolveRankingsAndReward()
	
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

	-- Create replicated MatchStatus folder for client UI
	local matchStatusFolder = Instance.new("Folder")
	matchStatusFolder.Name = "MatchStatus"
	matchStatusFolder.Parent = ReplicatedStorage

	replicatedState = Instance.new("StringValue")
	replicatedState.Name = "State"
	replicatedState.Value = MatchState.States.Intermission
	replicatedState.Parent = matchStatusFolder

	replicatedRound = Instance.new("IntValue")
	replicatedRound.Name = "Round"
	replicatedRound.Value = 0
	replicatedRound.Parent = matchStatusFolder

	replicatedPhaseEnd = Instance.new("NumberValue")
	replicatedPhaseEnd.Name = "PhaseEndTime"
	replicatedPhaseEnd.Value = 0
	replicatedPhaseEnd.Parent = matchStatusFolder

	log("MatchStatus folder + replicated values created")

	-- Initialize dependencies
	MapManager.Init()
	RoundManager.Init()
	EconomyService.Init()
	
	-- Register disconnect elimination tracking:
	-- When a player leaves while InMatch, record it as an elimination
	PlayerStateService.OnPlayerRemoval(function(player, oldState)
		if currentState == MatchState.States.Playing and oldState == PlayerState.States.InMatch then
			local round = RoundManager.GetCurrentRound()
			EliminationTracker.RecordElimination(player, round, "Disconnect")
		end
	end)
	
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
