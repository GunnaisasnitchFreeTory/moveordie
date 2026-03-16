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
	SpawnChanceAfterFirstMultiplier = 0.4, -- reduce re-spawn odds after first spawn in a match
	DurationSeconds = 30,
	RoundsAllowed   = {2, 3, 4, 5, 6},
	Damage          = 55,    -- per hit; two hits to kill a 100-HP player
	WalkSpeed       = 26,    -- noticeably faster than a running player (default 16)
	AttackRange     = 5,     -- studs: distance that triggers a swing
	AttackResolveRange = 6.0, -- studs: guaranteed close-range kill handoff radius
	AttackProximityFallbackRange = 6.5, -- studs: per-tick radial fallback so overlap always resolves
	AttackCooldown  = 1.25,  -- seconds between attacks on same player
	ChaseInterval   = 0.2,   -- re-evaluate target every 0.2s (logic still throttles MoveTo calls)
	RepathInterval  = 0.45,  -- minimum interval between MoveTo updates
	RepathTargetMoveDelta = 4.0, -- or when target moved this far since last MoveTo
	AttackDisengageRange = 6.5, -- hysteresis to avoid rapid chase/attack flipping
	-- Lunge: speed burst when player is within LungeRange studs
	LungeRange      = 12,    -- studs: triggers lunge
	LungeCooldown   = 3.0,   -- seconds between lunges
	LungeSpeed      = 55,    -- WalkSpeed during lunge burst
	LungeDuration   = 0.6,   -- seconds lunge lasts
	-- Contact damage: applied when a player physically touches the NPC body
	ContactDamage   = 30,    -- damage per body-touch event
	ContactCooldown = 0.8,   -- cooldown per player to prevent rapid stacking
	-- Arm-swing phases (seconds): total = ArmWindup + ArmSwing + ArmRecovery
	ArmWindup       = 0.10,
	ArmSwing        = 0.12,
	ArmRecovery     = 0.20,
	WalkAnimId      = "rbxassetid://507777826",
	FreezeDanceAnimIds = {
		"rbxassetid://507771019",
		"rbxassetid://507776043",
		"rbxassetid://507777268",
	},
	NpcFolderName   = "TungTungSahurNPC",
	RemoteName      = "TungTungSahurEvent",
	-- Brainrot-only NPC presentation + obstacle jump tuning
	BrainrotScale   = 1.85,  -- clear visual size increase for Save a Brainrot
	ObstacleJumpEnabled = true,
	ObstacleJumpCooldown = 1.2,
	ObstacleProbeDistance = 6.0,
	ObstacleProbeHeights = { 1.2, 2.6, 4.0 }, -- multi-height forward probes for varied obstacle heights
	ObstacleBlockedForwardSpeedThreshold = 2.2, -- forward speed considered "stuck"
	ObstacleBlockedChecksRequired = 2,   -- require repeated obstruction checks
	ObstacleBlockedResetSeconds = 0.8,
	ObstacleJumpPower = 72,
	ObstacleMinStepHeight = 1.1,         -- ignore tiny edges/steps
	ObstacleMaxJumpHeight = 7.5,         -- ignore very tall blockers for jump trigger
	-- Close-range anti-jitter tuning
	CloseRangeHoldEnterDistance = 6.5,   -- enter close-hold when within this range
	CloseRangeHoldExitDistance = 8.0,    -- exit hold only after this distance (hysteresis)
	ChaseStandOffDistance = 4.2,         -- keep pressure without pushing into target center
	CloseRangeNoJumpDistance = 8.0,      -- blocked-path jump disabled near target
	StateLogInterval = 0.8,              -- throttle debug state logs
}

-- --- INTERNAL STATE -----------------------------------------------------------
local initialized  = false
local active       = false
local frozen       = false
local spawnRound   = 0
local currentRound = 0
local npcModel:    Model?                  = nil
local chaseThread: thread?                = nil
local timerThread: thread?                = nil
local healthConn:  RBXScriptConnection?   = nil
local moveToConn:  RBXScriptConnection?   = nil
local walkTrack:   AnimationTrack?        = nil
local freezeDanceTrack: AnimationTrack?   = nil
local hitDebounce:     {[number]: number} = {}
local contactDebounce: {[number]: number} = {}
local contactConns:    {RBXScriptConnection} = {}
local lastLungeTick:   number = 0
local npcFolder:   Folder?               = nil
local eventRemote: RemoteEvent?          = nil
local killFeedRemote: RemoteEvent?       = nil
local hasSpawnedThisMatch: boolean       = false
local spawnCountThisMatch: number        = 0
local lastObstacleJumpAt: number         = 0
local lastBlockedObstacleKey: string?    = nil
local blockedObstacleChecks: number      = 0
local lastBlockedCheckAt: number         = 0

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

local function stopFreezeDanceAnim(reason: string?)
	if freezeDanceTrack then
		pcall(function()
			freezeDanceTrack:Stop(0.18)
		end)
		freezeDanceTrack = nil
		log(string.format("[TTS FreezeDance] stopped reason=%s", tostring(reason or "unspecified")))
	end
end

local function startFreezeDanceAnim()
	if not npcModel or not frozen then
		return
	end
	local animator = getAnimator()
	if not animator then
		warn("[TungTungSahur] Freeze dance start skipped: missing animator")
		return
	end

	stopFreezeDanceAnim("replace_existing")
	local danceIds = Config.FreezeDanceAnimIds or {}
	if #danceIds == 0 then
		return
	end

	local animationId = danceIds[math.random(1, #danceIds)]
	local animation = Instance.new("Animation")
	animation.AnimationId = animationId
	local okLoad, trackOrErr = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	animation:Destroy()
	if not okLoad or not trackOrErr then
		warn(string.format("[TungTungSahur] Freeze dance failed to load: %s", tostring(trackOrErr)))
		return
	end

	local track: AnimationTrack = trackOrErr
	track.Priority = Enum.AnimationPriority.Action
	track.Looped = true
	local okPlay, playErr = pcall(function()
		track:Play(0.12, 1, 1)
	end)
	if not okPlay then
		warn(string.format("[TungTungSahur] Freeze dance failed to play: %s", tostring(playErr)))
		return
	end

	freezeDanceTrack = track
	log(string.format("[TTS FreezeDance] started animationId=%s", animationId))
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

local function applyBrainrotScale()
	if not npcModel then return end
	local scale = Config.BrainrotScale or 1
	if scale <= 1 then return end

	local appliedWithModelScale = false
	local okScale, errScale = pcall(function()
		npcModel:ScaleTo(scale)
		appliedWithModelScale = true
	end)
	if not okScale then
		warn("[TungTungSahur] Model:ScaleTo failed, using fallback part scaling:", tostring(errScale))
	end

	-- Fallback for rigs/templates that do not respond reliably to ScaleTo at runtime.
	if not appliedWithModelScale then
		for _, desc in ipairs(npcModel:GetDescendants()) do
			if desc:IsA("BasePart") then
				desc.Size = desc.Size * scale
			end
		end
	end

	-- Do NOT scale HipHeight directly; that can create hover/floating behavior.

	local reportedScale = 0
	local okGetScale, gotScale = pcall(function()
		return npcModel:GetScale()
	end)
	if okGetScale and type(gotScale) == "number" then
		reportedScale = gotScale
	end
	log(string.format(
		"[TTS Scale] applied mode=Brainrot requested=%.2f reported=%.2f method=%s",
		scale, reportedScale, appliedWithModelScale and "ScaleTo" or "FallbackParts"
	))
end

local function isHumanoidGrounded(hum: Humanoid): boolean
	if hum.FloorMaterial == Enum.Material.Air then
		return false
	end
	local st = hum:GetState()
	if st == Enum.HumanoidStateType.Jumping
		or st == Enum.HumanoidStateType.Freefall
		or st == Enum.HumanoidStateType.FallingDown
	then
		return false
	end
	return true
end

local function getCharacterOwnerFromPart(part: Instance?): Player?
	if not part then return nil end
	local model = part:FindFirstAncestorOfClass("Model")
	if not model then return nil end
	return Players:GetPlayerFromCharacter(model)
end

local function maybeJumpObstacle(hum: Humanoid, targetPos: Vector3, distToTarget: number?)
	if not Config.ObstacleJumpEnabled then return end
	if not npcModel or not npcModel.PrimaryPart then return end
	if distToTarget and distToTarget <= Config.CloseRangeNoJumpDistance then
		lastBlockedObstacleKey = nil
		blockedObstacleChecks = 0
		return
	end
	local now = tick()
	if (now - lastObstacleJumpAt) < Config.ObstacleJumpCooldown then
		return
	end
	if not isHumanoidGrounded(hum) then
		log(string.format("[TTS Obstacle] jump request blocked state=airborne dist=%.2f",
			(distToTarget or -1)))
		return
	end

	local root = npcModel.PrimaryPart
	local toTarget = targetPos - root.Position
	local flatToTarget = Vector3.new(toTarget.X, 0, toTarget.Z)
	local flatDistance = flatToTarget.Magnitude
	if flatDistance < 1 then return end

	local direction = flatToTarget.Unit
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { npcModel }

	local hit = nil
	for _, probeY in ipairs(Config.ObstacleProbeHeights) do
		local origin = root.Position + Vector3.new(0, probeY, 0)
		local r = Workspace:Raycast(origin, direction * Config.ObstacleProbeDistance, params)
		if r and r.Instance then
			hit = r
			break
		end
	end

	if not hit or not hit.Instance then
		lastBlockedObstacleKey = nil
		blockedObstacleChecks = 0
		return
	end

	local owner = getCharacterOwnerFromPart(hit.Instance)
	if owner then
		log(string.format("[TTS Obstacle] player obstruction ignored player=%s part=%s",
			owner.Name, hit.Instance.Name))
		lastBlockedObstacleKey = nil
		blockedObstacleChecks = 0
		return
	end

	if hit.Instance:IsA("BasePart") and not hit.Instance.CanCollide then
		return
	end

	local blockerClass = hit.Instance.ClassName
	local blockerType = "world_geometry"
	local obstacleHeight = 0
	local rootBottomY = root.Position.Y - (root.Size.Y * 0.5)
	if hit.Instance:IsA("BasePart") then
		local topY = hit.Instance.Position.Y + (hit.Instance.Size.Y * 0.5)
		obstacleHeight = topY - rootBottomY
	end
	if obstacleHeight > 0 and obstacleHeight < Config.ObstacleMinStepHeight then
		log(string.format(
			"[TTS Obstacle] ignored type=%s class=%s reason=trivial_height obstacleHeight=%.2f",
			blockerType, blockerClass, obstacleHeight
		))
		return
	end
	if obstacleHeight > Config.ObstacleMaxJumpHeight then
		log(string.format(
			"[TTS Obstacle] ignored type=%s class=%s reason=too_tall obstacleHeight=%.2f",
			blockerType, blockerClass, obstacleHeight
		))
		return
	end

	local forwardSpeed = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z):Dot(direction)
	local obstacleKey = string.format("%s|%s", hit.Instance:GetFullName(), hit.Instance.ClassName)
	if (now - lastBlockedCheckAt) > Config.ObstacleBlockedResetSeconds or lastBlockedObstacleKey ~= obstacleKey then
		blockedObstacleChecks = 0
	end
	lastBlockedCheckAt = now
	lastBlockedObstacleKey = obstacleKey
	blockedObstacleChecks += 1

	log(string.format(
		"[TTS Obstacle] detected type=%s part=%s class=%s checks=%d forwardSpeed=%.2f obstacleHeight=%.2f grounded=%s",
		blockerType, hit.Instance.Name, blockerClass, blockedObstacleChecks, forwardSpeed, obstacleHeight,
		tostring(isHumanoidGrounded(hum))
	))

	if blockedObstacleChecks < Config.ObstacleBlockedChecksRequired then
		return
	end
	if forwardSpeed > Config.ObstacleBlockedForwardSpeedThreshold then
		return
	end

	hum.UseJumpPower = true
	hum.JumpPower = math.max(hum.JumpPower, Config.ObstacleJumpPower)
	hum.Jump = true
	hum:ChangeState(Enum.HumanoidStateType.Jumping)
	lastObstacleJumpAt = now
	blockedObstacleChecks = 0
	log(string.format("[TTS Obstacle] jump triggered over=%s jumpPower=%.1f",
		hit.Instance.Name, hum.JumpPower))
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
	if moveToConn then
		pcall(function() moveToConn:Disconnect() end)
		moveToConn = nil
	end
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

local function fireMatchOnlyEvent(action: string, extraArg: any, alertType: string)
	if not eventRemote then
		return
	end
	local recipients = {}
	local recipientNames = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local ok, state = pcall(function()
			return PlayerStateService.GetState(player)
		end)
		if ok and state == PlayerState.States.InMatch then
			table.insert(recipients, player)
			table.insert(recipientNames, player.Name)
		else
			log(string.format("[MatchAlertSkip] player=%s state=%s reason=not_in_match", player.Name, tostring(state)))
		end
	end
	for _, player in ipairs(recipients) do
		eventRemote:FireClient(player, action, extraArg)
	end
	log(string.format(
		"[MatchAlert] type=%s recipients=%s",
		alertType,
		(#recipientNames > 0) and table.concat(recipientNames, ",") or "none"
	))
end

local function fireCleanupEventAll(action: string, extraArg: any, alertType: string)
	if not eventRemote then
		return
	end
	local recipients = {}
	for _, player in ipairs(Players:GetPlayers()) do
		table.insert(recipients, player.Name)
		eventRemote:FireClient(player, action, extraArg)
	end
	log(string.format(
		"[TungCleanup] reason=%s activeBefore=true timerStopped=true npcDespawned=true uiHidden=true recipients=%s",
		alertType,
		(#recipients > 0) and table.concat(recipients, ",") or "none"
	))
end

local function despawn(reason: string)
	if not active then return end
	active = false
	frozen = false
	log("Despawning:", reason)

	disconnectAll()
	stopWalkAnim()
	stopFreezeDanceAnim("despawn")
	hitDebounce    = {}
	contactDebounce = {}
	lastLungeTick  = 0
	lastObstacleJumpAt = 0
	lastBlockedObstacleKey = nil
	blockedObstacleChecks = 0
	lastBlockedCheckAt = 0

	if npcModel and npcModel.Parent then
		npcModel:Destroy()
	end
	npcModel = nil

	-- Despawn/cleanup must reach everyone, including players already moved out of InMatch,
	-- so stale countdown UI cannot persist into results/lobby.
	fireCleanupEventAll("Despawn", reason == "timer", "TungTungSahurDespawn")

	-- Quest: reward all alive InMatch players when TTS ends due timer OR round-6 cleanup.
	if reason == "timer" or reason == "round6" then
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
local function eliminateVictim(player: Player, humanoid: Humanoid, source: string)
	if humanoid.Health > 0 then
		humanoid.Health = 0
	end

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
	log(string.format("[TTS Kill] source=%s victim=%s round=%d", source, player.Name, currentRound))
end

local function applyHitDamage(player: Player, humanoid: Humanoid, source: string)
	if humanoid.Health <= 0 then
		return
	end

	local damage = Config.Damage
	if source == "ContactTouch" then
		damage = Config.ContactDamage
	end
	damage = math.max(1, tonumber(damage) or 1)

	local before = humanoid.Health
	humanoid:TakeDamage(damage)
	local after = humanoid.Health
	log(string.format("[TTS Hit] source=%s target=%s damage=%d health=%.1f->%.1f",
		source, player.Name, damage, before, after))

	if after <= 0 then
		eliminateVictim(player, humanoid, source)
	end
end

local function tryResolveCloseRangeKill(target: Player, source: string, maxRange: number?): boolean
	if not active then
		log(string.format("[TTS AttackRejected] source=%s reason=npc_inactive", source))
		return false
	end
	if frozen then
		log(string.format("[TTS AttackRejected] source=%s reason=npc_frozen", source))
		return false
	end
	if not target or not target.Parent then
		log(string.format("[TTS AttackRejected] source=%s reason=target_missing", source))
		return false
	end
	local okState, state = pcall(function()
		return PlayerStateService.GetState(target)
	end)
	if not okState or state ~= PlayerState.States.InMatch then
		log(string.format("[TTS AttackRejected] source=%s target=%s reason=invalid_state state=%s",
			source, target.Name, tostring(state)))
		return false
	end
	local char = target.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hum or hum.Health <= 0 or not hrp then
		log(string.format("[TTS AttackRejected] source=%s target=%s reason=target_not_alive_or_missing_parts",
			source, target.Name))
		return false
	end
	if not npcModel or not npcModel.PrimaryPart then
		log(string.format("[TTS AttackRejected] source=%s target=%s reason=npc_missing_primary", source, target.Name))
		return false
	end
	local dist = (hrp.Position - npcModel.PrimaryPart.Position).Magnitude
	if maxRange and dist > maxRange then
		log(string.format("[TTS AttackRejected] source=%s target=%s reason=out_of_range dist=%.2f max=%.2f",
			source, target.Name, dist, maxRange))
		return false
	end

	local uid = target.UserId
	local now = tick()
	local last = hitDebounce[uid]
	if last and (now - last) < Config.AttackCooldown then
		log(string.format("[TTS AttackRejected] source=%s target=%s reason=debounce remaining=%.2f",
			source, target.Name, Config.AttackCooldown - (now - last)))
		return false
	end
	hitDebounce[uid] = now

	log(string.format("[TTS AttackAttempt] source=%s target=%s dist=%.2f", source, target.Name, dist))
	applyHitDamage(target, hum, source)
	return true
end

local function tryResolveAnyNearbyVictim(maxRange: number, source: string): boolean
	if not active or frozen then
		return false
	end
	if not npcModel or not npcModel.PrimaryPart then
		return false
	end
	local npcPos = npcModel.PrimaryPart.Position
	local bestTarget: Player? = nil
	local bestDist = math.huge

	for _, player in ipairs(Players:GetPlayers()) do
		local okState, state = pcall(function()
			return PlayerStateService.GetState(player)
		end)
		if not okState or state ~= PlayerState.States.InMatch then
			continue
		end
		local char = player.Character
		if not char then continue end
		local hum = char:FindFirstChildOfClass("Humanoid")
		local hrp = char:FindFirstChild("HumanoidRootPart")
		if not hum or hum.Health <= 0 or not hrp then
			continue
		end
		local dist = (hrp.Position - npcPos).Magnitude
		if dist <= maxRange and dist < bestDist then
			bestDist = dist
			bestTarget = player
		end
	end

	if not bestTarget then
		return false
	end

	log(string.format("[TTS ProximityFallback] target=%s dist=%.2f range=%.2f",
		bestTarget.Name, bestDist, maxRange))
	return tryResolveCloseRangeKill(bestTarget, source, maxRange)
end

--[[
	applyHit(player, humanoid)
	  - Deals Config.Damage (55) per hit.
	  - On lethal hit: records via EliminationTracker (fires KillFeedEvent
	    internally with "TungTungSahur" reason) and moves player → Lobby to
	    prevent OOB double-kill on auto-respawn.
	  - On non-lethal hit: just damages, no state change.
]]
local function applyHit(player: Player, humanoid: Humanoid)
	applyHitDamage(player, humanoid, "LegacyApplyHit")
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

-- --- CONTACT DAMAGE (anti-cheese: touching NPC body deals damage) --------------
local function setupContactDamage()
	if not npcModel then return end
	for _, c in ipairs(contactConns) do pcall(function() c:Disconnect() end) end
	contactConns = {}
	contactDebounce = {}
	local partCount = 0
	for _, part in ipairs(npcModel:GetDescendants()) do
		if part:IsA("BasePart") then
			partCount += 1
			local conn = part.Touched:Connect(function(hit)
				if not active or frozen then return end
				local char = hit.Parent
				if not char or char == npcModel then return end
				local player = Players:GetPlayerFromCharacter(char)
				if not player then return end
				local ok2, state = pcall(function() return PlayerStateService.GetState(player) end)
				if not ok2 or state ~= PlayerState.States.InMatch then return end
				local hum = char:FindFirstChildOfClass("Humanoid")
				if not hum or hum.Health <= 0 then return end
				local uid = player.UserId
				local now = tick()
				if contactDebounce[uid] and (now - contactDebounce[uid]) < Config.ContactCooldown then return end
				contactDebounce[uid] = now
				tryResolveCloseRangeKill(player, "ContactTouch", nil)
			end)
			table.insert(contactConns, conn)
		end
	end
	log(string.format("Contact damage wired to %d parts (cooldown=%.1fs dmg=%d)", partCount, Config.ContactCooldown, Config.ContactDamage))
end

-- --- CHASE + ATTACK LOOP ------------------------------------------------------
local function startChaseLoop()
	cancelThread(chaseThread)
	if moveToConn then
		pcall(function() moveToConn:Disconnect() end)
		moveToConn = nil
	end
	lastLungeTick = 0

	chaseThread = task.spawn(function()
		local lunging = false
		local lastMoveToAt = 0
		local lastMoveToTargetPos: Vector3? = nil
		local inAttackRange = false
		local previousInAttackRange = false
		local inCloseHold = false
		local movementState = "Idle"
		local lastStateLogAt = 0
		local lastTargetUserId: number? = nil

		local hum = npcModel and npcModel:FindFirstChildOfClass("Humanoid")

		while active and npcModel and npcModel.Parent do
			if not frozen then
				-- Fallback: if anyone is physically in kill radius, resolve immediately.
				-- This prevents overlap/touch timing gaps where NPC appears to walk on a player.
				if tryResolveAnyNearbyVictim(Config.AttackProximityFallbackRange, "ProximityFallback") then
					task.wait(Config.ChaseInterval)
					continue
				end

				local target = getNearestPlayer()
				if target and target.Character and npcModel and npcModel.PrimaryPart then
					if lastTargetUserId ~= target.UserId then
						lastTargetUserId = target.UserId
						log(string.format("[TTS TargetAcquired] target=%s", target.Name))
					end
					local hrp = target.Character:FindFirstChild("HumanoidRootPart")
					if hrp then
						hum = npcModel:FindFirstChildOfClass("Humanoid")
						if hum and hum.Health > 0 then
							local dist = (hrp.Position - npcModel.PrimaryPart.Position).Magnitude

							if dist <= Config.AttackRange then
								inAttackRange = true
							elseif dist >= Config.AttackDisengageRange then
								inAttackRange = false
							end

							if inAttackRange then
								if not previousInAttackRange then
									log(string.format("[TTS AttackRangeEntered] target=%s dist=%.2f range=%.2f",
										target.Name, dist, Config.AttackResolveRange))
								end
								movementState = "AttackHold"
								-- Melee attack
								lunging = false
								local now  = tick()
								-- Stop issuing movement while in attack hold (anti-jitter near target).
								hum:Move(Vector3.zero, false)
								if (now - lastMoveToAt) >= Config.RepathInterval then
									hum:MoveTo(npcModel.PrimaryPart.Position)
									lastMoveToAt = now
									lastMoveToTargetPos = nil
								end
								if tryResolveCloseRangeKill(target, "AttackRangeHandoff", Config.AttackResolveRange) then
									hum.WalkSpeed = 0
									playAttackAnim()
									if active and not frozen and npcModel then
										local hum3 = npcModel:FindFirstChildOfClass("Humanoid")
										if hum3 then hum3.WalkSpeed = Config.WalkSpeed end
									end
								end
							else
								-- Chase with stand-off target to prevent close-range shove jitter.
								local now = tick()
								local toTarget = hrp.Position - npcModel.PrimaryPart.Position
								local chaseTargetPos = hrp.Position
								if toTarget.Magnitude > 0.01 then
									chaseTargetPos = hrp.Position - toTarget.Unit * Config.ChaseStandOffDistance
								end

								if inCloseHold then
									if dist >= Config.CloseRangeHoldExitDistance then
										inCloseHold = false
									end
								else
									if dist <= Config.CloseRangeHoldEnterDistance then
										inCloseHold = true
									end
								end

								if inCloseHold then
									movementState = "CloseHold"
									lunging = false
									hum.WalkSpeed = Config.WalkSpeed
									hum:Move(Vector3.zero, false)
									if (now - lastMoveToAt) >= Config.RepathInterval then
										hum:MoveTo(npcModel.PrimaryPart.Position)
										lastMoveToAt = now
									end
									lastMoveToTargetPos = nil
									if (now - lastStateLogAt) >= Config.StateLogInterval then
										lastStateLogAt = now
										log(string.format(
											"[TTS Move] state=%s dist=%.2f grounded=%s blockedKey=%s repathAge=%.2f",
											movementState, dist, tostring(isHumanoidGrounded(hum)), tostring(lastBlockedObstacleKey), now - lastMoveToAt
										))
									end
									task.wait(Config.ChaseInterval)
									continue
								end

								-- Chase — trigger lunge only when not in close approach range.
								if not lunging
									and dist <= Config.LungeRange
									and dist > (Config.CloseRangeHoldEnterDistance + 1.0)
									and (now - lastLungeTick) >= Config.LungeCooldown
								then
									lastLungeTick = now
									lunging = true
									movementState = "Lunge"
									hum.WalkSpeed = Config.LungeSpeed
									log(string.format("[TTS] Lunge! dist=%.1f studs", dist))
									task.delay(Config.LungeDuration, function()
										lunging = false
										if active and not frozen and npcModel then
											local h = npcModel:FindFirstChildOfClass("Humanoid")
											if h then h.WalkSpeed = Config.WalkSpeed end
										end
									end)
								elseif not lunging then
									movementState = "Chase"
									hum.WalkSpeed = Config.WalkSpeed
								end
								local shouldRepath = false
								if (now - lastMoveToAt) >= Config.RepathInterval then
									shouldRepath = true
								elseif lastMoveToTargetPos and (chaseTargetPos - lastMoveToTargetPos).Magnitude >= Config.RepathTargetMoveDelta then
									shouldRepath = true
								elseif not lastMoveToTargetPos then
									shouldRepath = true
								end

								if shouldRepath then
									local repathAge = now - lastMoveToAt
									hum:MoveTo(chaseTargetPos)
									lastMoveToAt = now
									lastMoveToTargetPos = chaseTargetPos
									if (now - lastStateLogAt) >= Config.StateLogInterval then
										lastStateLogAt = now
										log(string.format(
											"[TTS Move] state=%s dist=%.2f grounded=%s moveToIssued=true moveTo=(%.1f,%.1f,%.1f) repathAge=%.2f",
											movementState, dist, tostring(isHumanoidGrounded(hum)), chaseTargetPos.X, chaseTargetPos.Y, chaseTargetPos.Z, repathAge
										))
									end
								end
								maybeJumpObstacle(hum, chaseTargetPos, dist)
							end
							previousInAttackRange = inAttackRange
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

	applyBrainrotScale()
	setupSwordImmunity()
	setupNameplate()
	startWalkAnim()
	startChaseLoop()
	startDurationTimer()

	fireMatchOnlyEvent("Spawn", Config.DurationSeconds, "TungTungSahurSpawn")
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
	if roundNumber <= 1 then
		-- Safety reset in case match teardown callback was skipped.
		hasSpawnedThisMatch = false
		spawnCountThisMatch = 0
	end
	if not Config.Enabled then return end
	if mode ~= "Brainrot" then return end
	if not isRoundAllowed(roundNumber) then
		log(string.format("Round %d: not in allowed list -- skip spawn", roundNumber))
		return
	end

	local spawnChance = Config.SpawnChance
	if hasSpawnedThisMatch then
		spawnChance = spawnChance * Config.SpawnChanceAfterFirstMultiplier
	end

	local roll = math.random()
	if roll >= spawnChance then
		log(string.format(
			"Round %d: roll %.2f >= %.2f -- spawn skipped (spawnedBefore=%s count=%d)",
			roundNumber,
			roll,
			spawnChance,
			tostring(hasSpawnedThisMatch),
			spawnCountThisMatch
		))
		return
	end

	log(string.format(
		"Round %d: roll %.2f < %.2f -- spawning! (spawnedBefore=%s count=%d)",
		roundNumber,
		roll,
		spawnChance,
		tostring(hasSpawnedThisMatch),
		spawnCountThisMatch
	))
	hasSpawnedThisMatch = true
	spawnCountThisMatch += 1
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
	hasSpawnedThisMatch = false
	spawnCountThisMatch = 0
end

function TungTungSahurService.OnFreezeBegin()
	if not active or frozen then return end
	if currentRound <= 0 then return end
	frozen = true
	log(string.format("[SaveTheBrainrot] freeze_started round=%d", currentRound))

	if npcModel then
		local hum = npcModel:FindFirstChildOfClass("Humanoid")
		if hum then
			hum.WalkSpeed = 0
			hum:MoveTo(hum.RootPart and hum.RootPart.Position or npcModel.PrimaryPart.Position)
		end
	end

	stopWalkAnim()
	startFreezeDanceAnim()
end

function TungTungSahurService.OnFreezeEnd()
	if not active or not frozen then return end
	frozen = false
	log(string.format("[SaveTheBrainrot] freeze_ended round=%d", currentRound))

	if npcModel then
		local hum = npcModel:FindFirstChildOfClass("Humanoid")
		if hum then hum.WalkSpeed = Config.WalkSpeed end
	end

	stopFreezeDanceAnim("freeze_end")
	startWalkAnim()
end

return TungTungSahurService
