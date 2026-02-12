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
	MinPlayersToStart = 1,
	MinIntermissionFloor = 10,  -- min seconds a late-joining player must see
	DebugLog = true,
}

--[[ INTERNAL STATE ]]
local currentState: string = MatchState.States.Intermission
local phaseEndTime: number = 0
local initialized = false
local loopRunning = false

local replicatedState: StringValue = nil
local replicatedRound: IntValue = nil
local replicatedPhaseEnd: NumberValue = nil

local MatchManager = {}

--[[ HELPERS ]]

local function log(...)
	if Config.DebugLog then
		print("[MatchManager]", ...)
	end
end

-- ── GLBS direct call (lazy require, no BindableEvent) ──
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

local function replicatePhaseEnd(durationSeconds: number)
	if replicatedPhaseEnd then
		replicatedPhaseEnd.Value = workspace:GetServerTimeNow() + durationSeconds
		log(string.format("Replicated PhaseEndTime → +%ds (value=%.1f)", durationSeconds, replicatedPhaseEnd.Value))
	else
		log("replicatedPhaseEnd is nil — skipping replication")
	end
end

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

	if replicatedState then
		replicatedState.Value = newState
	end
end

-- ── Force-unseat: detach player from any seat before teleport ──
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
		else
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

function MatchManager.GetEligiblePlayers(): { Player }
	local eligible = {}
	
	for _, player in ipairs(Players:GetPlayers()) do
		local state = PlayerStateService.GetState(player)
		local isAFK = PlayerStateService.IsAFK(player)
		
		if not isAFK and (state == PlayerState.States.Lobby or state == PlayerState.States.Waiting) then
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

local function setWaitingToInMatch()
	local waitingPlayers = PlayerStateService.GetPlayersInState(PlayerState.States.Waiting)
	local playersToTeleport = {}
	
	for _, player in ipairs(waitingPlayers) do
		if not PlayerStateService.IsAFK(player) then
			PlayerStateService.SetState(player, PlayerState.States.InMatch)
			table.insert(playersToTeleport, player)
		end
	end
	
	log(string.format("Moved %d players to InMatch", #playersToTeleport))
	teleportPlayersToArena(playersToTeleport)
	
	return #playersToTeleport
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
	
	local lastWaitingCount = 0
	
	while tick() < phaseEndTime do
		setEligibleToWaiting()
		
		-- Floor extension: if new player(s) enter Waiting with low remaining time, extend
		local waiting = PlayerStateService.GetPlayersInState(PlayerState.States.Waiting)
		local currentCount = #waiting
		if currentCount > lastWaitingCount then
			local remaining = phaseEndTime - tick()
			if remaining < Config.MinIntermissionFloor then
				phaseEndTime = tick() + Config.MinIntermissionFloor
				replicatePhaseEnd(Config.MinIntermissionFloor)
				log(string.format("Extended intermission for new player(s) — %.0fs remaining now", Config.MinIntermissionFloor))
			end
			lastWaitingCount = currentCount
		end
		
		task.wait(1)
	end
	
	setEligibleToWaiting()
end

local function runPlaying()
	local waitingPlayers = PlayerStateService.GetPlayersInState(PlayerState.States.Waiting)
	
	if #waitingPlayers < Config.MinPlayersToStart then
		log(string.format("Not enough players (%d/%d), skipping match", #waitingPlayers, Config.MinPlayersToStart))
		for _, player in ipairs(waitingPlayers) do
			PlayerStateService.SetState(player, PlayerState.States.Lobby)
		end
		return false
	end
	
	setMatchState(MatchState.States.Playing)
	log("Playing started — waiting for RoundManager to complete")
	
	MapManager.OnMatchStart()
	setWaitingToInMatch()
	
	local matchPlayers = PlayerStateService.GetPlayersInState(PlayerState.States.InMatch)
	EliminationTracker.Reset(matchPlayers)
	
	RoundManager.StartRoundLoop()
	
	while RoundManager.IsRunning() do
		task.wait(0.5)
	end
	
	local endReason = RoundManager.GetMatchEndReason()
	log(string.format("Round loop completed — reason: %s", endReason or "unknown"))
	
	MapManager.OnMatchEnd()
	
	return true
end

local function resolveRankingsAndReward()
	local survivors = PlayerStateService.GetPlayersInState(PlayerState.States.InMatch)
	local rankings = EliminationTracker.BuildRankings(survivors)
	
	if #rankings == 0 then
		log("No rankings to process (no players)")
		return
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
	
	for _, group in ipairs(rankings) do
		for _, entry in ipairs(group.players) do
			if entry.player and entry.player.Parent then
				if group.coins > 0 then
					EconomyService.AwardCoins(
						entry.player,
						group.coins,
						string.format("Match#%d Place#%d", matchId, group.placement)
					)
					totalAwarded = totalAwarded + group.coins
				end
				
				-- Track wins for first place
				if group.placement == 1 and PDS then
					local lifetimeWins = (PDS.GetField(entry.player, "LifetimeWins") or 0) + 1
					PDS.SetField(entry.player, "LifetimeWins", lifetimeWins)

					local weeklyWins = (PDS.GetField(entry.player, "WeeklyWins") or 0) + 1
					PDS.SetField(entry.player, "WeeklyWins", weeklyWins)

					log(string.format("%s won! LifetimeWins=%d WeeklyWins=%d",
						entry.player.Name, lifetimeWins, weeklyWins))

					-- Direct module call to GLBS
					reportStats(entry.player.UserId, entry.player.Name, {
						LifetimeWins = lifetimeWins,
						WeeklyWins   = weeklyWins,
					})
				end
			end
		end
	end
	
	log(string.format("Awarded %d total coins across %d placement groups", totalAwarded, #rankings))
end

local function runEnding()
	setMatchState(MatchState.States.Ending)
	phaseEndTime = tick() + Config.EndingSeconds
	replicatePhaseEnd(Config.EndingSeconds)
	
	local matchEndReason = RoundManager.GetMatchEndReason()
	local winner = RoundManager.GetWinner()
	
	if matchEndReason == "Winner" and winner then
		log(string.format("Ending started (%ds) — WINNER: %s", Config.EndingSeconds, winner.Name))
	elseif matchEndReason == "NoWinners" then
		log(string.format("Ending started (%ds) — No winners", Config.EndingSeconds))
	else
		log(string.format("Ending started (%ds)", Config.EndingSeconds))
	end
	
	-- Fire win SFX to the winning player
	if matchEndReason == "Winner" and winner and winner.Parent then
		local remotes = ReplicatedStorage:FindFirstChild("Remotes")
		local sfxRemote = remotes and remotes:FindFirstChild("PlaySFX")
		if sfxRemote then
			sfxRemote:FireClient(winner, "Win")
		end
	end
	
	resolveRankingsAndReward()
	setMatchPlayersToLobby()
	
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

	MapManager.Init()
	RoundManager.Init()
	EconomyService.Init()
	
	PlayerStateService.OnPlayerRemoval(function(player, oldState)
		if currentState == MatchState.States.Playing and oldState == PlayerState.States.InMatch then
			local round = RoundManager.GetCurrentRound()
			EliminationTracker.RecordElimination(player, round, "Disconnect")
		end
	end)
	
	-- Pre-warm GLBS reference (non-blocking)
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
	local remaining = phaseEndTime - tick()
	return math.max(0, math.floor(remaining))
end

function MatchManager.StartLoop()
	if loopRunning then
		warn("[MatchManager] Loop already running")
		return
	end
	loopRunning = true
	log("Loop started — waiting for first eligible player before intermission")
	
	task.spawn(function()
		-- ISSUE A FIX: Do NOT start intermission until at least 1 player is in Lobby/Waiting.
		-- This prevents the 15s timer from ticking down before anyone can see it.
		while loopRunning do
			local eligible = MatchManager.GetEligiblePlayers()
			if #eligible > 0 then
				log(string.format("First eligible player found (%s) — beginning match loop", eligible[1].Name))
				break
			end
			task.wait(0.5)
		end
		
		-- Main match loop
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
	log("Loop stopped")
end

return MatchManager
