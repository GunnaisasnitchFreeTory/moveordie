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
local ItemCatalog = require(Shared:WaitForChild("ItemCatalog"))
local BrainrotModeService    = require(Server:WaitForChild("BrainrotModeService"))
local RoundCoinService       = require(Server:WaitForChild("RoundCoinService"))
local SwordSpawnService      = require(Server:WaitForChild("SwordSpawnService"))
local TungTungSahurService   = require(Server:WaitForChild("TungTungSahurService"))
local ModeLightingService    = require(Server:WaitForChild("ModeLightingService"))
local FreezePlayerProductService = require(Server:WaitForChild("FreezePlayerProductService"))

local _DQS = nil
local function getDQS()
	if _DQS ~= nil then return _DQS end
	local ok, mod = pcall(require, Server:FindFirstChild("DailyQuestService"))
	if ok and mod then _DQS = mod else _DQS = false end
	return _DQS
end

--[[ CONFIGURATION ]]
local Config = {
	IntermissionSeconds = 18,
	PlayingSeconds = 20,
	EndingSeconds = 7,
	MinPlayersToStart = 1,
	MinIntermissionFloor = 10,
	VoteShowAtRemaining = 12,
	DebugLog = true,
}

--[[ INTERNAL STATE ]]
local currentState: string = MatchState.States.Intermission
local phaseEndTime: number = 0
local initialized = false
local loopRunning = false
local currentMode: string = "Normal"

local replicatedState: StringValue = nil
local replicatedRound: IntValue = nil
local replicatedPhaseEnd: NumberValue = nil
local replicatedMode: StringValue = nil
local replicatedVoteActive: BoolValue = nil
local replicatedVoteEndTime: NumberValue = nil
local matchResultsEvent: RemoteEvent = nil

-- Vote state
local voteRemote: RemoteEvent = nil
local votes: { [Player]: string } = {}
local voteActive = false

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

-- ── Mode Vote helpers ──

local function getVoteCounts(): (number, number)
	local normal, brainrot = 0, 0
	for voter, choice in pairs(votes) do
		-- Exclude AFK players from tally
		if voter and voter.Parent and not PlayerStateService.IsAFK(voter) then
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
	for _, player in ipairs(Players:GetPlayers()) do
		voteRemote:FireClient(player, "Update", { normal = normal, brainrot = brainrot })
	end
end

local function startVote()
	votes = {}
	voteActive = true

	-- Replicate vote-active state so late-joining / slow clients can catch up
	if replicatedVoteActive then
		replicatedVoteActive.Value = true
	end
	if replicatedVoteEndTime then
		replicatedVoteEndTime.Value = workspace:GetServerTimeNow() + math.max(0, phaseEndTime - tick())
	end

	if voteRemote then
		for _, player in ipairs(Players:GetPlayers()) do
			if not PlayerStateService.IsAFK(player) then
				voteRemote:FireClient(player, "Start", {})
			end
		end
	end
	log("Mode vote started")
end

local function endVote(): string
	voteActive = false

	-- Clear replicated vote state
	if replicatedVoteActive then
		replicatedVoteActive.Value = false
	end

	local normal, brainrot = getVoteCounts()
	local result = "Normal"
	if brainrot > normal then
		result = "Brainrot"
	end
	currentMode = result

	if replicatedMode then
		replicatedMode.Value = result
	end

	if voteRemote then
		for _, player in ipairs(Players:GetPlayers()) do
			voteRemote:FireClient(player, "End", { winner = result, normal = normal, brainrot = brainrot })
		end
	end

	votes = {}
	log(string.format("Mode vote ended — %s wins (Normal=%d, Brainrot=%d)", result, normal, brainrot))
	return result
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
		restoreLobbyHealth(player)
	end
	
	log(string.format("Returned %d remaining players to Lobby", #inMatchPlayers))
end

--[[ PHASE HANDLERS ]]

local function runIntermission()
	restoreEnvironment("IntermissionStart")
	setMatchState(MatchState.States.Intermission)
	phaseEndTime = tick() + Config.IntermissionSeconds
	replicatePhaseEnd(Config.IntermissionSeconds)
	replicateRound(0)

	-- Reset mode to Normal at start of intermission
	currentMode = "Normal"
	if replicatedMode then
		replicatedMode.Value = "Normal"
	end

	log(string.format("Intermission started (%ds)", Config.IntermissionSeconds))

	local knownPlayers: { [Player]: boolean } = {}
	for _, p in ipairs(Players:GetPlayers()) do
		knownPlayers[p] = true
	end
	local lastActiveCount = 0
	local voteStarted = false

	while tick() < phaseEndTime do
		setEligibleToWaiting()

		local waiting = PlayerStateService.GetPlayersInState(PlayerState.States.Waiting)
		local activeCount = 0
		local hasGenuinelyNewPlayer = false
		for _, p in ipairs(waiting) do
			if not PlayerStateService.IsAFK(p) then
				activeCount = activeCount + 1
				if not knownPlayers[p] then
					knownPlayers[p] = true
					hasGenuinelyNewPlayer = true
				end
			end
		end

		for _, p in ipairs(Players:GetPlayers()) do
			if not knownPlayers[p] then
				knownPlayers[p] = true
			end
		end

		local remaining = phaseEndTime - tick()
		local extended = false
		if hasGenuinelyNewPlayer and remaining < Config.MinIntermissionFloor then
			phaseEndTime = tick() + Config.MinIntermissionFloor
			replicatePhaseEnd(Config.MinIntermissionFloor)
			extended = true
		end

		if activeCount ~= lastActiveCount or extended then
			log(string.format(
				"Intermission tick: activeWaiting %d→%d  remaining=%.1fs  extended=%s  genuineNew=%s",
				lastActiveCount, activeCount, phaseEndTime - tick(),
				tostring(extended), tostring(hasGenuinelyNewPlayer)
			))
		end
		lastActiveCount = activeCount

		local timeLeft = phaseEndTime - tick()
		if not voteStarted and timeLeft <= Config.VoteShowAtRemaining then
			voteStarted = true
			startVote()
		end
		
		task.wait(1)
	end

	if voteStarted then
		endVote()
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
	log(string.format("Playing started (mode=%s) — waiting for RoundManager to complete", currentMode))

	local played = false
	local ok, err = xpcall(function()
		applyEnvironmentForMode(currentMode)

		MapManager.OnMatchStart()
		setWaitingToInMatch()
		do
			local dqs = getDQS()
			if dqs and dqs.OnMatchStart then
				local participants = PlayerStateService.GetPlayersInState(PlayerState.States.InMatch)
				pcall(dqs.OnMatchStart, participants)
			end
		end

		if currentMode == "Brainrot" then
			BrainrotModeService.OnMatchStart()
		end

		local matchPlayers = PlayerStateService.GetPlayersInState(PlayerState.States.InMatch)
		EliminationTracker.Reset(matchPlayers)
		EconomyService.ResetMatchCoins()

		RoundManager.StartRoundLoop(currentMode)

		while RoundManager.IsRunning() do
			task.wait(0.5)
		end

		local endReason = RoundManager.GetMatchEndReason()
		log(string.format("Round loop completed — reason: %s", endReason or "unknown"))
		do
			local dqs = getDQS()
			if dqs and dqs.OnMatchEnd then
				pcall(dqs.OnMatchEnd)
			end
		end

		if currentMode == "Brainrot" then
			BrainrotModeService.OnMatchEnd()
		end

		SwordSpawnService.OnMatchEnd()
		TungTungSahurService.OnMatchEnd()
		MapManager.OnMatchEnd()
		played = true
	end, debug.traceback)

	if not ok then
		warn("[MatchManager] runPlaying failed:", err)
		do
			local dqs = getDQS()
			if dqs and dqs.OnMatchEnd then
				pcall(dqs.OnMatchEnd)
			end
		end
		pcall(function()
			if currentMode == "Brainrot" then
				BrainrotModeService.OnMatchEnd()
			end
		end)
		pcall(function() SwordSpawnService.OnMatchEnd() end)
		pcall(function() TungTungSahurService.OnMatchEnd() end)
		pcall(function() MapManager.OnMatchEnd() end)
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
				
				if group.placement == 1 and PDS then
					local lifetimeWins = (PDS.GetField(entry.player, "LifetimeWins") or 0) + 1
					PDS.SetField(entry.player, "LifetimeWins", lifetimeWins)

					local weeklyWins = (PDS.GetField(entry.player, "WeeklyWins") or 0) + 1
					PDS.SetField(entry.player, "WeeklyWins", weeklyWins)

					local dqs = getDQS()
					if dqs and dqs.OnPlayerWon then pcall(dqs.OnPlayerWon, entry.player) end

					log(string.format("%s won! LifetimeWins=%d WeeklyWins=%d",
						entry.player.Name, lifetimeWins, weeklyWins))

					reportStats(entry.player.UserId, entry.player.Name, {
						LifetimeWins = lifetimeWins,
						WeeklyWins   = weeklyWins,
					})
					
					local _, nextM = getMilestoneContext(lifetimeWins - 1)
					if nextM and lifetimeWins >= nextM.wins then
						crownGrants[entry.playerId] = nextM.crownId
					end
				end
			end
		end
	end
	
	log(string.format("Awarded %d total coins across %d placement groups", totalAwarded, #rankings))
	
	if matchResultsEvent then
		local flatRankings = {}
		for _, group in ipairs(rankings) do
			for _, entry in ipairs(group.players) do
				table.insert(flatRankings, {
					placement = group.placement,
					playerName = entry.playerName,
					coins = group.coins,
					matchCoinsCollected = entry.player and EconomyService.GetMatchCoins(entry.player) or 0,
				})
			end
		end
		
		for _, group in ipairs(rankings) do
			for _, entry in ipairs(group.players) do
				if entry.player and entry.player.Parent then
					local lifetimeWins = 0
					if PDS then
						lifetimeWins = PDS.GetField(entry.player, "LifetimeWins") or 0
					end
					local prevM, nextM = getMilestoneContext(lifetimeWins)
					
					local payload = {
						yourPlacement = group.placement,
						yourCoins = group.coins,
						yourXP = 0,
						matchCoinsCollected = EconomyService.GetMatchCoins(entry.player),
						rankings = flatRankings,
						lifetimeWins = lifetimeWins,
						crownGranted = crownGrants[entry.playerId] or nil,
						nextMilestone = nextM,
						prevMilestone = prevM,
					}
					
					local fireOk, fireErr = pcall(function()
						matchResultsEvent:FireClient(entry.player, payload)
					end)
					if not fireOk then
						warn("[MatchManager] Failed to fire results to", entry.playerName, fireErr)
					end
				end
			end
		end
		log("Fired MatchResultsEvent to all match participants")

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

	replicatedMode = Instance.new("StringValue")
	replicatedMode.Name = "Mode"
	replicatedMode.Value = "Normal"
	replicatedMode.Parent = matchStatusFolder

	replicatedVoteActive = Instance.new("BoolValue")
	replicatedVoteActive.Name = "ModeVoteActive"
	replicatedVoteActive.Value = false
	replicatedVoteActive.Parent = matchStatusFolder

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
		if action == "Cast" and voteActive and data and typeof(data) == "string" then
			if PlayerStateService.IsAFK(player) then return end
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

	log("ModeVote remote created")

	BrainrotModeService.Init()
	ModeLightingService.Init()
	FreezePlayerProductService.Init()
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
		while loopRunning do
			local eligible = MatchManager.GetEligiblePlayers()
			if #eligible > 0 then
				log(string.format("First eligible player found (%s) — beginning match loop", eligible[1].Name))
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