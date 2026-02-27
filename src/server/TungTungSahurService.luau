--[[
	TungTungSahurService
	Server-side hazard: TungTungSahur NPC for "Brainrot" mode, rounds 2-6.

	Attack model:
	  - Distance-based: NPC chases player, performs a real arm-swing when within
	    AttackRange studs.
	  - Arm swing uses Motor6D.C0 tweening (RightShoulder + RightElbow) — always
	    visible regardless of animation-asset availability. Since Animator writes
	    to Motor6D.Transform and this code tweens Motor6D.C0, there is no
	    conflict; the effects are additive.
	  - Damage = 55 per hit (two hits to kill a 100-HP player).
	  - On lethal hit: records via EliminationTracker (fires KillFeedEvent
	    internally) and transitions player → Lobby to prevent OOB double-kill.

	Despawn rules:
	  - ONLY despawns when:
	      1) 30-second timer reaches 0
	      2) Round 6 ends (if spawned during round 6)
	      3) Match ends
	  - Does NOT despawn on other round transitions.

	API:
		Init()
		OnRoundStart(roundNumber, mode)
		OnRoundEnd(roundNumber)
		OnMatchEnd()
		OnFreezeBegin()
		OnFreezeEnd()
]]

local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local TweenService        = game:GetService("TweenService")
local Workspace           = game:GetService("Workspace")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Server = ServerScriptService:WaitForChild("Server")

local PlayerState        = require(Shared:WaitForChild("PlayerState"))
local PlayerStateService = require(Server:WaitForChild("PlayerStateService"))

-- Lazy-load EliminationTracker to avoid circular dependency at require time
local _EliminationTracker = nil
local function getEliminationTracker()
	if _EliminationTracker then return _EliminationTracker end
	pcall(function()
		local et = Server:FindFirstChild("EliminationTracker")
		if et then _EliminationTracker = require(et) end
	end)
	return _EliminationTracker
end

-- --- CONFIG -------------------------------------------------------------------
local Config = {
	Enabled         = true,
	SpawnChance     = 0.70,
	DurationSeconds = 30,
	RoundsAllowed   = {2, 3, 4, 5, 6},
	Damage          = 55,    -- per hit; two hits to kill a 100-HP player
	WalkSpeed       = 26,    -- noticeably faster than a running player (default 16)
	AttackRange     = 5,     -- studs: distance that triggers a swing
	AttackCooldown  = 1.25,  -- seconds between attacks on same player
	ChaseInterval   = 0.5,
	-- Arm-swing phases (seconds): total = ArmWindup + ArmSwing + ArmRecovery
	ArmWindup       = 0.10,  -- raise arm (wind-up)
	ArmSwing        = 0.12,  -- swing arm down to impact
	ArmRecovery     = 0.20,  -- return arm to rest, then restart walk
	WalkAnimId      = "rbxassetid://507777826",
	NpcFolderName   = "TungTungSahurNPC",
	RemoteName      = "TungTungSahurEvent",
}

-- --- INTERNAL STATE -----------------------------------------------------------
local initialized  = false
local active       = false
local frozen       = false
local spawnRound   = 0
local currentRound = 0  -- updated each OnRoundStart so eliminations record correctly
local npcModel:    Model?                 = nil
local chaseThread: thread?               = nil
local timerThread: thread?               = nil
local healthConn:  RBXScriptConnection?  = nil
local walkTrack:   AnimationTrack?       = nil
local hitDebounce: {[number]: number}    = {}  -- [userId] = lastHitTick
local npcFolder:   Folder?               = nil
local eventRemote: RemoteEvent?          = nil
local killFeedRemote: RemoteEvent?       = nil

local TungTungSahurService = {}

-- --- HELPERS ------------------------------------------------------------------

local function log(...)
	print("[TungTungSahur]", ...)
end

local function isRoundAllowed(round: number): boolean
	for _, r in ipairs(Config.RoundsAllowed) do
		if r == round then return true end
	end
	return false
end

local function getOrCreateNpcFolder(): Folder
	if npcFolder and npcFolder.Parent then return npcFolder end
	npcFolder = Workspace:FindFirstChild(Config.NpcFolderName)
	if not npcFolder then
		npcFolder = Instance.new("Folder")
		npcFolder.Name   = Config.NpcFolderName
		npcFolder.Parent = Workspace
	end
	return npcFolder
end

-- Returns the nearest InMatch alive player, or nil if none.
local function getNearestPlayer(): Player?
	if not npcModel or not npcModel.PrimaryPart then return nil end
	local npcPos     = npcModel.PrimaryPart.Position
	local nearest: Player? = nil
	local nearestDist      = math.huge
	for _, player in ipairs(Players:GetPlayers()) do
		local ok, state = pcall(function() return PlayerStateService.GetState(player) end)
		if not ok or state ~= PlayerState.States.InMatch then continue end
		local char = player.Character
		if not char then continue end
		local hrp = char:FindFirstChild("HumanoidRootPart")
		if not hrp then continue end
		local hum = char:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 then continue end
		local dist = (hrp.Position - npcPos).Magnitude
		if dist < nearestDist then
			nearestDist = dist
			nearest     = player
		end
	end
	return nearest
end

-- --- WALK ANIMATION -----------------------------------------------------------

local function getAnimator(): Animator?
	if not npcModel then return nil end
	local humanoid = npcModel:FindFirstChildOfClass("Humanoid")
	if not humanoid then return nil end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator        = Instance.new("Animator")
		animator.Parent = humanoid
	end
	return animator
end

local function startWalkAnim()
	if not npcModel then return end
	local animator = getAnimator()
	if not animator then return end
	if walkTrack then
		pcall(function() walkTrack:Stop() end)
		walkTrack = nil
	end
	local anim          = Instance.new("Animation")
	anim.AnimationId    = Config.WalkAnimId
	local ok, track     = pcall(function() return animator:LoadAnimation(anim) end)
	anim:Destroy()
	if ok and track then
		walkTrack        = track
		walkTrack.Looped = true
		walkTrack:Play()
	else
		warn("[TungTungSahur] Walk animation failed:", tostring(track))
	end
end

local function stopWalkAnim()
	if walkTrack then
		pcall(function() walkTrack:Stop() end)
		walkTrack = nil
	end
end

-- --- ATTACK ANIMATION (Motor6D arm swing) ------------------------------------
--[[
	playAttackAnim()
	Drives RightShoulder + RightElbow Motor6D.C0 to produce a visible club-swing.
	Animator writes to Motor6D.Transform; this code tweens Motor6D.C0 — the two
	are additive, so they do NOT conflict.

	To avoid the walk animation competing visually during the swing,
	stopWalkAnim() is called first and startWalkAnim() restarts after recovery.

	Timeline relative to playAttackAnim() call:
	  0.00s               → Wind-up begins  (arm raises back)
	  ArmWindup           → Swing begins    (arm swings down)
	  ArmWindup+ArmSwing  → IMPACT          (damage applied by caller)
	  ...+ArmRecovery     → Arm back to rest, walk restarts
]]
local function playAttackAnim()
	if frozen then return end
	if not npcModel then return end

	local shoulder = npcModel:FindFirstChild("RightShoulder", true)
	if not (shoulder and shoulder:IsA("Motor6D")) then return end
	local elbow = npcModel:FindFirstChild("RightElbow", true)
	if not (elbow   and elbow:IsA("Motor6D"))   then elbow = nil end

	-- Pause walk so the walk animation Transform doesn't visually fight C0 tween
	stopWalkAnim()

	local origS = shoulder.C0
	local origE = elbow and elbow.C0

	-- Phase 1: Wind-up — raise arm up and back
	TweenService:Create(shoulder, TweenInfo.new(Config.ArmWindup, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		C0 = origS * CFrame.Angles(-math.rad(85), 0, math.rad(15)),
	}):Play()
	if elbow and origE then
		TweenService:Create(elbow, TweenInfo.new(Config.ArmWindup, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			C0 = origE * CFrame.Angles(math.rad(45), 0, 0),
		}):Play()
	end

	-- Phase 2: Swing down to impact
	task.delay(Config.ArmWindup, function()
		if not shoulder or not shoulder.Parent then return end
		TweenService:Create(shoulder, TweenInfo.new(Config.ArmSwing, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			C0 = origS * CFrame.Angles(math.rad(55), 0, -math.rad(10)),
		}):Play()
		if elbow and origE then
			TweenService:Create(elbow, TweenInfo.new(Config.ArmSwing, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				C0 = origE * CFrame.Angles(-math.rad(35), 0, 0),
			}):Play()
		end

		-- Phase 3: Recovery — return to rest, restart walk
		task.delay(Config.ArmSwing, function()
			if not shoulder or not shoulder.Parent then return end
			TweenService:Create(shoulder, TweenInfo.new(Config.ArmRecovery, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				C0 = origS,
			}):Play()
			if elbow and origE then
				TweenService:Create(elbow, TweenInfo.new(Config.ArmRecovery, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
					C0 = origE,
				}):Play()
			end
			task.delay(Config.ArmRecovery, function()
				if active and not frozen then startWalkAnim() end
			end)
		end)
	end)
end

-- --- NAMEPLATE ----------------------------------------------------------------

local function setupNameplate()
	if not npcModel then return end
	local rootPart = npcModel.PrimaryPart or npcModel:FindFirstChild("HumanoidRootPart")
	if not rootPart then return end

	local humanoid = npcModel:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end

	for _, desc in ipairs(npcModel:GetDescendants()) do
		if desc:IsA("BillboardGui") then desc:Destroy() end
	end

	local billboard          = Instance.new("BillboardGui")
	billboard.Name           = "TungTungNameplate"
	billboard.Size           = UDim2.new(0, 200, 0, 32)
	billboard.StudsOffset    = Vector3.new(0, 2.8, 0)
	billboard.AlwaysOnTop    = true
	billboard.Enabled        = true
	billboard.MaxDistance    = 80
	billboard.ResetOnSpawn   = false
	billboard.Parent         = rootPart

	local label                     = Instance.new("TextLabel")
	label.Name                      = "NameLabel"
	label.AnchorPoint               = Vector2.new(0.5, 0.5)
	label.Position                  = UDim2.new(0.5, 0, 0.5, 0)
	label.Size                      = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency    = 1
	label.Font                      = Enum.Font.GothamBold
	label.Text                      = "TungTungSahur"
	label.TextColor3                = Color3.fromRGB(255, 80, 80)
	label.TextSize                  = 16
	label.TextScaled                = false
	label.TextXAlignment            = Enum.TextXAlignment.Center
	label.Parent                    = billboard

	local stroke             = Instance.new("UIStroke")
	stroke.Color             = Color3.fromRGB(50, 0, 0)
	stroke.Thickness         = 2
	stroke.Transparency      = 0.3
	stroke.Parent            = label

	log("[TTS Nameplate] default hidden, custom active")
end

-- --- CLEANUP ------------------------------------------------------------------

local function cancelThread(t: thread?)
	if t then pcall(task.cancel, t) end
end

local function disconnectAll()
	cancelThread(chaseThread)
	cancelThread(timerThread)
	chaseThread = nil
	timerThread = nil
	if healthConn then
		pcall(function() healthConn:Disconnect() end)
		healthConn = nil
	end
end

local _DQS = nil
local function getDQS()
	if _DQS ~= nil then return _DQS end
	local ok, mod = pcall(require, Server:FindFirstChild("DailyQuestService"))
	if ok and mod then _DQS = mod else _DQS = false end
	return _DQS
end

local function despawn(reason: string)
	if not active then return end
	active = false
	frozen = false
	log("Despawning:", reason)

	disconnectAll()
	stopWalkAnim()
	hitDebounce = {}

	if npcModel and npcModel.Parent then
		npcModel:Destroy()
	end
	npcModel = nil

	if eventRemote then
		eventRemote:FireAllClients("Despawn", reason == "timer")
	end

	-- Quest: reward all alive InMatch players when TTS timer naturally expires
	if reason == "timer" then
		local dqs = getDQS()
		if dqs and dqs.OnTTSSurvive then
			for _, player in ipairs(Players:GetPlayers()) do
				local ok2, state = pcall(function() return PlayerStateService.GetState(player) end)
				if ok2 and state == PlayerState.States.InMatch then
					local char = player.Character
					local hum  = char and char:FindFirstChildOfClass("Humanoid")
					if hum and hum.Health > 0 then
						pcall(dqs.OnTTSSurvive, player)
					end
				end
			end
		end
	end

	log("Despawn complete -- reason:", reason)
end

-- --- HIT / ELIMINATION --------------------------------------------------------
--[[
	applyHit(player, humanoid)
	  - Deals Config.Damage (55) per hit.
	  - On lethal hit: records via EliminationTracker (fires KillFeedEvent
	    internally with "TungTungSahur" reason) and moves player → Lobby to
	    prevent OOB double-kill on auto-respawn.
	  - On non-lethal hit: just damages, no state change.
]]
local function applyHit(player: Player, humanoid: Humanoid)
	humanoid:TakeDamage(Config.Damage)

	if humanoid.Health <= 0 then
		local et = getEliminationTracker()
		if et then
			et.RecordElimination(player, currentRound, "TungTungSahur")
		else
			if killFeedRemote then
				killFeedRemote:FireAllClients(player.Name, "TungTungSahur")
			end
			warn("[TungTungSahur] EliminationTracker unavailable for", player.Name)
		end
		-- Transition BEFORE character can respawn so OOB loop won't kill them again
		PlayerStateService.SetState(player, PlayerState.States.Lobby)
		log(string.format("[TTS] eliminated %s (round %d)", player.Name, currentRound))
	else
		log(string.format("[TTS] hit %s — %.0f HP remaining", player.Name, humanoid.Health))
	end
end

-- --- SWORD IMMUNITY -----------------------------------------------------------

local function setupSwordImmunity()
	if not npcModel then return end
	local humanoid = npcModel:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	humanoid.MaxHealth = 10000
	humanoid.Health    = 10000

	healthConn = humanoid.HealthChanged:Connect(function(hp: number)
		if hp < humanoid.MaxHealth then
			humanoid.Health = humanoid.MaxHealth
		end
	end)
	log("Sword immunity active (MaxHealth=10000)")
end

-- --- CHASE + ATTACK LOOP ------------------------------------------------------
local function startChaseLoop()
	cancelThread(chaseThread)
	chaseThread = task.spawn(function()
		while active and npcModel and npcModel.Parent do
			if not frozen then
				local target = getNearestPlayer()
				if target and target.Character and npcModel and npcModel.PrimaryPart then
					local hrp = target.Character:FindFirstChild("HumanoidRootPart")
					if hrp then
						local hum = npcModel:FindFirstChildOfClass("Humanoid")
						if hum and hum.Health > 0 then
							local dist = (hrp.Position - npcModel.PrimaryPart.Position).Magnitude

							if dist <= Config.AttackRange then
								local uid = target.UserId
								local now = tick()
								local lastHit = hitDebounce[uid]
								if not lastHit or (now - lastHit) >= Config.AttackCooldown then
									hitDebounce[uid] = now
									hum.WalkSpeed = 0    -- freeze NPC during swing
									playAttackAnim()     -- Motor6D arm swing (async)

									-- Wait until the arm reaches the impact point
									task.wait(Config.ArmWindup + Config.ArmSwing)

									-- Re-verify: still active, not frozen, target still close
									if active and not frozen
										and target.Character
										and npcModel and npcModel.PrimaryPart
									then
										local hrp2 = target.Character:FindFirstChild("HumanoidRootPart")
										local hum2 = target.Character:FindFirstChildOfClass("Humanoid")
										if hrp2 and hum2 and hum2.Health > 0 then
											local dist2 = (hrp2.Position - npcModel.PrimaryPart.Position).Magnitude
											if dist2 <= Config.AttackRange * 1.5 then
												applyHit(target, hum2)
											end
										end
									end

									-- Restore WalkSpeed — walk animation restarts
									-- automatically at end of ArmRecovery phase
									if active and not frozen and npcModel then
										local hum3 = npcModel:FindFirstChildOfClass("Humanoid")
										if hum3 then hum3.WalkSpeed = Config.WalkSpeed end
									end
								end
							else
								-- Chase: close in on target
								hum.WalkSpeed = Config.WalkSpeed
								hum:MoveTo(hrp.Position)
							end
						end
					end
				end
			end
			task.wait(Config.ChaseInterval)
		end
	end)
end

-- --- DURATION TIMER -----------------------------------------------------------

local function startDurationTimer()
	cancelThread(timerThread)
	timerThread = task.spawn(function()
		task.wait(Config.DurationSeconds)
		if active then despawn("timer") end
	end)
end

-- --- SPAWN --------------------------------------------------------------------

local function spawnNpc(roundNumber: number)
	if active then
		log("Already active -- skipping spawn")
		return
	end

	local assets   = ReplicatedStorage:FindFirstChild("Assets")
	local hazards  = assets  and assets:FindFirstChild("Hazards")
	local template = hazards and hazards:FindFirstChild("TungTungSahur")
	if not template then
		warn("[TungTungSahur] Template not found at ReplicatedStorage.Assets.Hazards.TungTungSahur")
		return
	end

	local clone = template:Clone()

	for _, scriptName in ipairs({"Chase", "Manager", "Script"}) do
		local s = clone:FindFirstChild(scriptName)
		if s and (s:IsA("Script") or s:IsA("LocalScript")) then
			s.Enabled = false
		end
	end

	clone:SetAttribute("IsTungTungSahur", true)

	local spawnCF = CFrame.new(0, 8, 0)
	local ok, MapManager = pcall(function()
		return require(Server:WaitForChild("MapManager", 5))
	end)
	if ok and MapManager then
		local spawnFrames = MapManager.GetArenaSpawnCFrames(1)
		if spawnFrames and spawnFrames[1] then
			spawnCF = spawnFrames[1] * CFrame.new(0, 3, 0)
		end
	end

	clone:PivotTo(spawnCF)
	clone.Parent  = getOrCreateNpcFolder()
	npcModel      = clone
	active        = true
	frozen        = false
	spawnRound    = roundNumber
	hitDebounce   = {}

	log(string.format("NPC spawned for round %d at (%.0f, %.0f, %.0f)",
		roundNumber, spawnCF.Position.X, spawnCF.Position.Y, spawnCF.Position.Z))

	setupSwordImmunity()
	setupNameplate()
	startWalkAnim()
	startChaseLoop()
	startDurationTimer()

	if eventRemote then
		eventRemote:FireAllClients("Spawn", Config.DurationSeconds)
	end
	log("Fired Spawn event to all clients")
end

-- --- PUBLIC API ---------------------------------------------------------------

function TungTungSahurService.Init()
	if initialized then return end

	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		remotes        = Instance.new("Folder")
		remotes.Name   = "Remotes"
		remotes.Parent = ReplicatedStorage
	end

	local existing = remotes:FindFirstChild(Config.RemoteName)
	if existing and existing:IsA("RemoteEvent") then
		eventRemote = existing
	else
		eventRemote        = Instance.new("RemoteEvent")
		eventRemote.Name   = Config.RemoteName
		eventRemote.Parent = remotes
	end

	killFeedRemote = remotes:FindFirstChild("KillFeedEvent")
	if not killFeedRemote then
		task.spawn(function()
			killFeedRemote = remotes:WaitForChild("KillFeedEvent", 15)
		end)
	end

	initialized = true
	log(string.format(
		"Initialized -- enabled=%s chance=%.0f%% duration=%ds rounds=%s",
		tostring(Config.Enabled),
		Config.SpawnChance * 100,
		Config.DurationSeconds,
		table.concat((function()
			local t = {}
			for _, r in ipairs(Config.RoundsAllowed) do table.insert(t, tostring(r)) end
			return t
		end)(), ",")
	))
end

function TungTungSahurService.OnRoundStart(roundNumber: number, mode: string)
	if not initialized then return end
	currentRound = roundNumber  -- always track, even when TTS doesn't spawn
	if not Config.Enabled then return end
	if mode ~= "Brainrot" then return end
	if not isRoundAllowed(roundNumber) then
		log(string.format("Round %d: not in allowed list -- skip spawn", roundNumber))
		return
	end

	local roll = math.random()
	if roll >= Config.SpawnChance then
		log(string.format("Round %d: roll %.2f >= %.2f -- spawn skipped", roundNumber, roll, Config.SpawnChance))
		return
	end

	log(string.format("Round %d: roll %.2f < %.2f -- spawning!", roundNumber, roll, Config.SpawnChance))
	spawnNpc(roundNumber)
end

--[[
	OnRoundEnd(roundNumber)
	ONLY despawns if round 6 is ending. Earlier spawns persist until 30s timer.
]]
function TungTungSahurService.OnRoundEnd(roundNumber: number)
	if not initialized then return end
	if not active then return end

	if roundNumber == 6 then
		log(string.format("Round 6 ended -- force despawning TTS (spawned in round %d)", spawnRound))
		despawn("round6")
	else
		log(string.format("Round %d ended -- TTS remains active (spawned round %d, timer still running)", roundNumber, spawnRound))
	end
end

function TungTungSahurService.OnMatchEnd()
	if not initialized then return end
	if active then despawn("match") end
end

function TungTungSahurService.OnFreezeBegin()
	if not active or frozen then return end
	frozen = true
	log("Freeze begin -- NPC paused")

	if npcModel then
		local hum = npcModel:FindFirstChildOfClass("Humanoid")
		if hum then
			hum.WalkSpeed = 0
			hum:MoveTo(hum.RootPart and hum.RootPart.Position or npcModel.PrimaryPart.Position)
		end
	end

	stopWalkAnim()
end

function TungTungSahurService.OnFreezeEnd()
	if not active or not frozen then return end
	frozen = false
	log("Freeze end -- NPC resumed")

	if npcModel then
		local hum = npcModel:FindFirstChildOfClass("Humanoid")
		if hum then hum.WalkSpeed = Config.WalkSpeed end
	end

	startWalkAnim()
end

return TungTungSahurService
