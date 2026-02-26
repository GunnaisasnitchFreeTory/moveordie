--[[
	TungTungSahurService
	Server-side hazard: TungTungSahur NPC for "Brainrot" mode, rounds 2-6.

	Despawn rules (FIXED):
	  - ONLY despawns when:
	      1) 30-second timer reaches 0
	      2) Round 6 ends (if spawned during round 6)
	      3) Match ends
	  - Does NOT despawn on other round transitions.

	API:
		Init()
		OnRoundStart(roundNumber, mode)
		OnRoundEnd(roundNumber)      <- roundNumber required
		OnMatchEnd()
		OnFreezeBegin()
		OnFreezeEnd()
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Server = ServerScriptService:WaitForChild("Server")

local PlayerState        = require(Shared:WaitForChild("PlayerState"))
local PlayerStateService = require(Server:WaitForChild("PlayerStateService"))

-- --- CONFIG -------------------------------------------------------------------
local Config = {
	Enabled             = true,
	SpawnChance         = 0.70,
	DurationSeconds     = 30,
	RoundsAllowed       = {2, 3, 4, 5, 6},
	Damage              = 20,
	WalkSpeed           = 18,
	AttackDebounce      = 1.0,   -- seconds between hits on same player
	SwingDebounce       = 0.7,   -- min seconds between swing anims
	ChaseInterval       = 0.5,
	WalkAnimId          = "rbxassetid://507777826",
	SwingAnimId         = "rbxassetid://522635514",  -- R15 slash/swing
	NpcFolderName       = "TungTungSahurNPC",
	RemoteName          = "TungTungSahurEvent",
}

-- --- INTERNAL STATE -----------------------------------------------------------
local initialized   = false
local active        = false
local frozen        = false
local spawnRound    = 0        -- which round TTS spawned in
local npcModel: Model?           = nil
local chaseThread: thread?       = nil
local timerThread: thread?       = nil
local attackConns: {RBXScriptConnection} = {}
local healthConn: RBXScriptConnection?   = nil
local walkTrack: AnimationTrack?         = nil
local swingTrack: AnimationTrack?        = nil
local lastSwingTime: number              = 0
local hitDebounce: {[number]: number}    = {}  -- [userId] = lastHitTick
local npcFolder: Folder?  = nil
local eventRemote: RemoteEvent? = nil
local killFeedRemote: RemoteEvent? = nil

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
		npcFolder.Name = Config.NpcFolderName
		npcFolder.Parent = Workspace
	end
	return npcFolder
end

-- Returns the nearest InMatch alive player, or nil if none.
local function getNearestPlayer(): Player?
	if not npcModel or not npcModel.PrimaryPart then return nil end
	local npcPos = npcModel.PrimaryPart.Position
	local nearest: Player? = nil
	local nearestDist = math.huge
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
			nearest = player
		end
	end
	return nearest
end

-- --- ANIMATION ----------------------------------------------------------------

local function getAnimator(): Animator?
	if not npcModel then return nil end
	local humanoid = npcModel:FindFirstChildOfClass("Humanoid")
	if not humanoid then return nil end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
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

	local anim = Instance.new("Animation")
	anim.AnimationId = Config.WalkAnimId
	local ok, track = pcall(function() return animator:LoadAnimation(anim) end)
	anim:Destroy()
	if ok and track then
		walkTrack = track
		walkTrack.Looped = true
		walkTrack:Play()
		log("Walk animation playing")
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

local function loadSwingAnim()
	if not npcModel then return end
	local animator = getAnimator()
	if not animator then return end

	local anim = Instance.new("Animation")
	anim.AnimationId = Config.SwingAnimId
	local ok, track = pcall(function() return animator:LoadAnimation(anim) end)
	anim:Destroy()
	if ok and track then
		swingTrack = track
		swingTrack.Looped = false
		swingTrack.Priority = Enum.AnimationPriority.Action
		log("Swing animation loaded")
	else
		warn("[TungTungSahur] Swing animation failed:", tostring(track))
	end
end

local function playSwingAnim()
	if frozen then return end
	local now = tick()
	if now - lastSwingTime < Config.SwingDebounce then return end
	lastSwingTime = now
	if swingTrack then
		pcall(function() swingTrack:Play() end)
	end
end

local function stopSwingAnim()
	if swingTrack then
		pcall(function() swingTrack:Stop() end)
	end
end

-- --- NAMEPLATE ----------------------------------------------------------------

local function setupNameplate()
	if not npcModel then return end
	local rootPart = npcModel.PrimaryPart or npcModel:FindFirstChild("HumanoidRootPart")
	if not rootPart then return end

	-- Remove any existing nameplate first
	local existing = npcModel:FindFirstChild("TungTungNameplate")
	if existing then existing:Destroy() end

	local billboard = Instance.new("BillboardGui")
	billboard.Name           = "TungTungNameplate"
	billboard.Size           = UDim2.new(0, 200, 0, 48)
	billboard.StudsOffset    = Vector3.new(0, 3.5, 0)
	billboard.AlwaysOnTop    = false
	billboard.Enabled        = true
	billboard.MaxDistance    = 80
	billboard.ResetOnSpawn   = false
	billboard.Parent         = rootPart

	-- Background pill
	local bg = Instance.new("Frame")
	bg.Name                    = "NameBg"
	bg.AnchorPoint             = Vector2.new(0.5, 0.5)
	bg.Position                = UDim2.new(0.5, 0, 0.5, 0)
	bg.Size                    = UDim2.new(1, 0, 1, 0)
	bg.BackgroundColor3        = Color3.fromRGB(30, 0, 0)
	bg.BackgroundTransparency  = 0.25
	bg.BorderSizePixel         = 0
	bg.Parent                  = billboard

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = bg

	local bgStroke = Instance.new("UIStroke")
	bgStroke.Color       = Color3.fromRGB(220, 40, 40)
	bgStroke.Thickness   = 2
	bgStroke.Transparency = 0.1
	bgStroke.Parent      = bg

	-- Name label
	local label = Instance.new("TextLabel")
	label.Name                = "NameLabel"
	label.AnchorPoint         = Vector2.new(0.5, 0.5)
	label.Position            = UDim2.new(0.5, 0, 0.5, 0)
	label.Size                = UDim2.new(1, -12, 1, 0)
	label.BackgroundTransparency = 1
	label.Font                = Enum.Font.GothamBlack
	label.Text                = "TungTungSahur"
	label.TextColor3          = Color3.fromRGB(255, 220, 60)
	label.TextSize            = 18
	label.TextScaled          = false
	label.TextXAlignment      = Enum.TextXAlignment.Center
	label.Parent              = bg

	local textStroke = Instance.new("UIStroke")
	textStroke.Color       = Color3.fromRGB(80, 0, 0)
	textStroke.Thickness   = 2
	textStroke.Transparency = 0
	textStroke.Parent      = label

	log("Nameplate added")
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
	for _, conn in ipairs(attackConns) do
		pcall(function() conn:Disconnect() end)
	end
	attackConns = {}
	if healthConn then
		pcall(function() healthConn:Disconnect() end)
		healthConn = nil
	end
end

--[[
	despawn(reason)
	  reason == "timer"  -> fire "Despawn" with showSurvival=true (client checks if alive)
	  reason == "round6" -> normal despawn, no survival popup
	  reason == "match"  -> normal despawn
]]
local function despawn(reason: string)
	if not active then return end
	active = false
	frozen = false
	log("Despawning:", reason)

	disconnectAll()
	stopWalkAnim()
	stopSwingAnim()
	swingTrack = nil
	hitDebounce = {}

	if npcModel and npcModel.Parent then
		npcModel:Destroy()
	end
	npcModel = nil

	if eventRemote then
		local showSurvival = (reason == "timer")
		eventRemote:FireAllClients("Despawn", showSurvival)
	end
	log("Despawn complete -- reason:", reason)
end

-- --- ATTACK SETUP -------------------------------------------------------------

local function setupRightHandAttack()
	if not npcModel then return end
	local rightHand = npcModel:FindFirstChild("RightHand")
	if not rightHand or not rightHand:IsA("BasePart") then
		warn("[TungTungSahur] RightHand not found -- attack disabled")
		return
	end

	local conn = rightHand.Touched:Connect(function(hit: BasePart)
		if frozen or not active then return end

		local character = hit.Parent
		if not character or not character:IsA("Model") then return end

		local player = Players:GetPlayerFromCharacter(character)
		if not player then return end

		local ok, state = pcall(function() return PlayerStateService.GetState(player) end)
		if not ok or state ~= PlayerState.States.InMatch then return end

		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then return end

		-- Per-player debounce
		local now = tick()
		local uid = player.UserId
		if hitDebounce[uid] and (now - hitDebounce[uid]) < Config.AttackDebounce then return end
		hitDebounce[uid] = now

		-- Swing animation on successful hit
		playSwingAnim()

		humanoid:TakeDamage(Config.Damage)
		log(string.format("RightHand hit %s for %d", player.Name, Config.Damage))

		-- Track for killfeed: connect to Died if health is now low
		task.defer(function()
			if not humanoid or not humanoid.Parent then return end
			if humanoid.Health <= 0 then
				-- Already dead this frame
				if killFeedRemote then
					killFeedRemote:FireAllClients(player.Name, "TungTungSahur")
				end
			else
				-- Watch for death within the next 4 seconds
				local diedConn
				diedConn = humanoid.Died:Connect(function()
					if diedConn then pcall(function() diedConn:Disconnect() end) end
					-- Only credit TTS if this happened within 4s of the last TTS hit
					local hitTime = hitDebounce[uid]
					if hitTime and (tick() - hitTime) < 4.0 then
						if killFeedRemote then
							killFeedRemote:FireAllClients(player.Name, "TungTungSahur")
						end
					end
				end)
				-- Auto-disconnect after 4 seconds to avoid leaks
				task.delay(4.0, function()
					if diedConn then pcall(function() diedConn:Disconnect() end) end
				end)
			end
		end)
	end)
	table.insert(attackConns, conn)
	log("RightHand attack connected")
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

-- --- CHASE LOOP ---------------------------------------------------------------

local function startChaseLoop()
	cancelThread(chaseThread)
	chaseThread = task.spawn(function()
		while active and npcModel and npcModel.Parent do
			if not frozen then
				local target = getNearestPlayer()
				if target and target.Character then
					local hrp = target.Character:FindFirstChild("HumanoidRootPart")
					if hrp then
						local hum = npcModel:FindFirstChildOfClass("Humanoid")
						if hum and hum.Health > 0 then
							hum.WalkSpeed = Config.WalkSpeed
							hum:MoveTo(hrp.Position)
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
		if active then
			despawn("timer")
		end
	end)
end

-- --- SPAWN --------------------------------------------------------------------

local function spawnNpc(roundNumber: number)
	if active then
		log("Already active -- skipping spawn")
		return
	end

	local assets   = ReplicatedStorage:FindFirstChild("Assets")
	local hazards  = assets and assets:FindFirstChild("Hazards")
	local template = hazards and hazards:FindFirstChild("TungTungSahur")
	if not template then
		warn("[TungTungSahur] Template not found at ReplicatedStorage.Assets.Hazards.TungTungSahur")
		return
	end

	local clone = template:Clone()

	-- Disable built-in scripts
	for _, scriptName in ipairs({"Chase", "Manager", "Script"}) do
		local s = clone:FindFirstChild(scriptName)
		if s and (s:IsA("Script") or s:IsA("LocalScript")) then
			s.Enabled = false
		end
	end

	-- Tag for sword filter
	clone:SetAttribute("IsTungTungSahur", true)

	-- Spawn position
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
	clone.Parent = getOrCreateNpcFolder()
	npcModel     = clone
	active       = true
	frozen       = false
	spawnRound   = roundNumber
	hitDebounce  = {}
	lastSwingTime = 0

	log(string.format("NPC spawned for round %d at (%.0f, %.0f, %.0f)",
		roundNumber, spawnCF.Position.X, spawnCF.Position.Y, spawnCF.Position.Z))

	setupSwordImmunity()
	setupNameplate()
	setupRightHandAttack()
	startWalkAnim()
	loadSwingAnim()
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
		remotes = Instance.new("Folder")
		remotes.Name = "Remotes"
		remotes.Parent = ReplicatedStorage
	end

	local existing = remotes:FindFirstChild(Config.RemoteName)
	if existing and existing:IsA("RemoteEvent") then
		eventRemote = existing
	else
		eventRemote = Instance.new("RemoteEvent")
		eventRemote.Name = Config.RemoteName
		eventRemote.Parent = remotes
	end

	-- Grab killfeed remote for death attribution
	killFeedRemote = remotes:FindFirstChild("KillFeedEvent")
	if not killFeedRemote then
		-- Wait briefly in case it's created by another service
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
	ONLY despawns TungTungSahur if he was spawned during round 6 AND round 6 is now ending.
	If he was spawned earlier (rounds 2-5), he persists across round transitions until his
	30-second timer expires.
]]
function TungTungSahurService.OnRoundEnd(roundNumber: number)
	if not initialized then return end
	if not active then return end

	-- Only force-despawn if round 6 is ending (the last allowed round)
	if roundNumber == 6 then
		log(string.format("Round 6 ended -- force despawning TTS (was spawned in round %d)", spawnRound))
		despawn("round6")
	else
		log(string.format("Round %d ended -- TTS remains active (spawned round %d, timer still running)", roundNumber, spawnRound))
	end
end

function TungTungSahurService.OnMatchEnd()
	if not initialized then return end
	if active then
		despawn("match")
	end
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
	stopSwingAnim()
end

function TungTungSahurService.OnFreezeEnd()
	if not active or not frozen then return end
	frozen = false
	log("Freeze end -- NPC resumed")

	if npcModel then
		local hum = npcModel:FindFirstChildOfClass("Humanoid")
		if hum then
			hum.WalkSpeed = Config.WalkSpeed
		end
	end

	startWalkAnim()
end

return TungTungSahurService
