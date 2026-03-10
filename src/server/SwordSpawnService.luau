--[[
	SwordSpawnService
	Server-side sword spawning during rounds 1-7.

	- Spawns immediately at round start (if below cap), then recurs every
	  SPAWN_INTERVAL_MIN–SPAWN_INTERVAL_MAX seconds while the round is active.
	- Hard cap: MAX_SWORDS_ALIVE uncollected pickups at once (no pileups).
	- Pickup is a hovering world model (client handles animation).
	- On collection: clone ClassicSword from ServerStorage into Backpack.
	- First kill with sword: +50 coins, sword removed immediately.
	- Swords auto-removed after 2 rounds or at round 8+.
	- All swords cleaned up on match end.

	Works in BOTH Normal and Brainrot modes.

	API:
		Init()
		OnRoundStart(roundNumber: number)
		OnRoundEnd()
		OnMatchEnd()
]]

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local ServerScriptService = game:GetService("ServerScriptService")

local Server = ServerScriptService:WaitForChild("Server")
local MapManager = require(Server:WaitForChild("MapManager"))
local EconomyService = require(Server:WaitForChild("EconomyService"))
local StatService = require(Server:WaitForChild("StatService"))
local PlayerState = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlayerState"))
local PlayerStateService = require(Server:WaitForChild("PlayerStateService"))
local EliminationTracker = require(Server:WaitForChild("EliminationTracker"))

local MAX_SPAWN_ROUND = 7
local SWORD_LIFESPAN_ROUNDS = 2
local KILL_BONUS = 50
local SOUND_ID = "rbxassetid://93965767748928"
local SWORD_WALKSPEED_OVERRIDE_KEY = "SwordHold"
local SWORD_WALKSPEED = 18

-- Spawn frequency: one attempt every SPAWN_INTERVAL_MIN–MAX seconds while a round is active
local SPAWN_INTERVAL_MIN = 16
local SPAWN_INTERVAL_MAX = 22
-- Hard cap: never have more than this many uncollected pickups in the world at once
local MAX_SWORDS_ALIVE = 1
-- Probability (0–1) that a sword spawns immediately when a round starts.
-- Combined with the per-round cap this keeps sword presence at ~40-60% of rounds.
local INITIAL_SPAWN_CHANCE = 0.50

local PICKUP_FOLDER_NAME = "SwordPickups"
local SPAWN_Y_OFFSET = 3.0
local EDGE_MARGIN = 6
local RAYCAST_HEIGHT = 80

local GLOW_FILL_COLOR = Color3.fromRGB(0, 200, 255)
local GLOW_FILL_TRANSPARENCY = 0.5
local GLOW_OUTLINE_COLOR = Color3.fromRGB(255, 255, 255)
local GLOW_OUTLINE_TRANSPARENCY = 0.1

local BEACON_HEIGHT = 50
local RING_DIAMETER = 8
local RING_COLOR = Color3.fromRGB(0, 200, 255)
local DENIED_COOLDOWN = 3

local _DQS = nil
local function getDQS()
	if _DQS ~= nil then return _DQS end
	local ok, mod = pcall(require, Server:FindFirstChild("DailyQuestService"))
	if ok and mod then _DQS = mod else _DQS = false end
	return _DQS
end

local SwordSpawnService = {}

local initialized = false
local pickupsFolder: Folder? = nil
local touchConnections: { RBXScriptConnection } = {}

local activePickups: { { model: Model, spawnRound: number } } = {}
local swordHolders: { [Player]: { tool: Tool, spawnRound: number, deathConn: RBXScriptConnection?, unequippedConn: RBXScriptConnection? } } = {}

local swordSpawnedRemote: RemoteEvent? = nil
local swordDeniedCooldowns: { [number]: number } = {}
local fireSwordSpawnMatchAlert: (() -> ())? = nil

local _spawnLoopActive = false
local _currentRound = 0
-- Hard cap: at most one sword pickup spawns per round
local _swordsSpawnedThisRound = 0

local function log(...)
	print("[SwordSpawn]", ...)
end

local function countActivePickups(): number
	local count = 0
	for _, entry in ipairs(activePickups) do
		if entry.model and entry.model.Parent then
			count += 1
		end
	end
	return count
end

local function getPickupsFolder(): Folder
	if pickupsFolder and pickupsFolder.Parent then return pickupsFolder end
	local existing = Workspace:FindFirstChild(PICKUP_FOLDER_NAME)
	if existing then
		pickupsFolder = existing
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = PICKUP_FOLDER_NAME
	folder.Parent = Workspace
	pickupsFolder = folder
	return folder
end

local function clearPickupsFolder()
	local folder = Workspace:FindFirstChild(PICKUP_FOLDER_NAME)
	if folder then
		folder:Destroy()
		pickupsFolder = nil
	end
end

local function disconnectTouched()
	for _, conn in ipairs(touchConnections) do
		if conn.Connected then conn:Disconnect() end
	end
	touchConnections = {}
end

local function getRandomArenaPosition(): Vector3?
	local bounds = MapManager.GetActiveBounds()
	if not bounds then
		warn("[SwordSpawn] No active bounds available")
		return nil
	end

	local centerX = bounds.cframe.Position.X
	local centerZ = bounds.cframe.Position.Z
	local topY = bounds.topY

	local halfX = (bounds.sizeX / 2) - EDGE_MARGIN
	local halfZ = (bounds.sizeZ / 2) - EDGE_MARGIN
	halfX = math.max(halfX, 2)
	halfZ = math.max(halfZ, 2)

	local x = centerX + (math.random() * 2 - 1) * halfX
	local z = centerZ + (math.random() * 2 - 1) * halfZ

	local rayOrigin = Vector3.new(x, topY + RAYCAST_HEIGHT, z)
	local rayDir = Vector3.new(0, -(RAYCAST_HEIGHT * 2), 0)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local folder = Workspace:FindFirstChild(PICKUP_FOLDER_NAME)
	if folder then
		params.FilterDescendantsInstances = { folder }
	end

	local result = Workspace:Raycast(rayOrigin, rayDir, params)
	local y = result and (result.Position.Y + SPAWN_Y_OFFSET) or (topY + SPAWN_Y_OFFSET)
	return Vector3.new(x, y, z)
end

local function scheduleWalkSpeedRestore(player: Player, reason: string)
	local function stillHasSword(): boolean
		if swordHolders[player] then return true end
		local backpack = player:FindFirstChild("Backpack")
		if backpack then
			for _, item in ipairs(backpack:GetChildren()) do
				if item:IsA("Tool") and item.Name == "ClassicSword" then
					return true
				end
			end
		end
		local character = player.Character
		if character then
			for _, item in ipairs(character:GetChildren()) do
				if item:IsA("Tool") and item.Name == "ClassicSword" then
					return true
				end
			end
		end
		return false
	end

	task.spawn(function()
		for _ = 1, 32 do
			if not player.Parent then
				return
			end
			if stillHasSword() then
				return
			end
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.Health > 0 then
				if humanoid.WalkSpeed == 0 and humanoid.JumpPower == 0 then
					task.wait(0.2)
					continue
				end
				StatService.RecalculateStats(player)
				log(string.format(
					"[SwordMoveGuard] player=%s swordRemoved=true walkSpeedRestored=true reason=%s",
					player.Name,
					reason
				))
				return
			end
			task.wait(0.2)
		end
	end)
end

local function removeSwordFromPlayer(player: Player)
	local data = swordHolders[player]
	if not data then return end

	if data.deathConn then
		data.deathConn:Disconnect()
	end
	if data.unequippedConn then
		data.unequippedConn:Disconnect()
	end

	if data.tool and data.tool.Parent then
		data.tool:Destroy()
	end

	if player.Parent then
		local backpack = player:FindFirstChild("Backpack")
		if backpack then
			for _, item in ipairs(backpack:GetChildren()) do
				if item:IsA("Tool") and item.Name == "ClassicSword" then
					item:Destroy()
				end
			end
		end
		local character = player.Character
		if character then
			for _, item in ipairs(character:GetChildren()) do
				if item:IsA("Tool") and item.Name == "ClassicSword" then
					item:Destroy()
				end
			end
		end
	end

	swordHolders[player] = nil
	StatService.ClearWalkSpeedOverride(player, SWORD_WALKSPEED_OVERRIDE_KEY)
	scheduleWalkSpeedRestore(player, "SwordRemoved")
	log(string.format(
		"[SwordMoveGuard] player=%s swordRemoved=true walkSpeedOverrideCleared=true",
		player.Name
	))
	log(player.Name, "sword removed")
end

local function removeAllSwords()
	for player, _ in pairs(swordHolders) do
		removeSwordFromPlayer(player)
	end
	swordHolders = {}
end

local function playerHasSword(player: Player): boolean
	if swordHolders[player] then return true end
	local backpack = player:FindFirstChild("Backpack")
	if backpack then
		for _, item in ipairs(backpack:GetChildren()) do
			if item:IsA("Tool") and item.Name == "ClassicSword" then
				return true
			end
		end
	end
	local character = player.Character
	if character then
		for _, item in ipairs(character:GetChildren()) do
			if item:IsA("Tool") and item.Name == "ClassicSword" then
				return true
			end
		end
	end
	return false
end

local function onSwordKill(killer: Player, victim: Player)
	log(string.format("%s killed %s with sword! +%d coins", killer.Name, victim.Name, KILL_BONUS))
	EconomyService.AwardCoins(killer, KILL_BONUS, "SwordKill", true)
	EconomyService.TrackMatchCoins(killer, KILL_BONUS)
	removeSwordFromPlayer(killer)
	local dqs = getDQS()
	if dqs and dqs.OnSwordKill then pcall(dqs.OnSwordKill, killer) end
end

local function giveSwordToPlayer(player: Player, spawnRound: number)
	local toolsFolder = ServerStorage:FindFirstChild("Tools")
	local template = toolsFolder and toolsFolder:FindFirstChild("ClassicSword")
	if not template then
		warn("[SwordSpawn] ClassicSword not found in ServerStorage.Tools")
		return
	end

	local clone = template:Clone()
	clone:SetAttribute("SwordSpawnRound", spawnRound)
	clone.CanBeDropped = false

	local backpack = player:FindFirstChild("Backpack")
	if backpack then
		clone.Parent = backpack
	end

	local deathConn: RBXScriptConnection? = nil
	local unequippedConn: RBXScriptConnection? = nil
	local character = player.Character
	if character then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			-- Guard: sword must stay visibly equipped once picked up.
			humanoid:EquipTool(clone)

			unequippedConn = clone.Unequipped:Connect(function()
				local holder = swordHolders[player]
				if not holder or holder.tool ~= clone then return end
				if not player.Parent then return end
				local currentCharacter = player.Character
				if not currentCharacter then return end
				local currentHumanoid = currentCharacter:FindFirstChildOfClass("Humanoid")
				if not currentHumanoid or currentHumanoid.Health <= 0 then return end
				task.defer(function()
					local latest = swordHolders[player]
					if not latest or latest.tool ~= clone then return end
					if clone.Parent ~= currentCharacter then
						currentHumanoid:EquipTool(clone)
						log(string.format("%s sword re-equipped (hide guard)", player.Name))
					end
				end)
			end)

			deathConn = humanoid.Died:Connect(function()
				removeSwordFromPlayer(player)
			end)
		end
	end

	swordHolders[player] = {
		tool = clone,
		spawnRound = spawnRound,
		deathConn = deathConn,
		unequippedConn = unequippedConn,
	}
	StatService.SetWalkSpeedOverride(player, SWORD_WALKSPEED_OVERRIDE_KEY, SWORD_WALKSPEED)
	log(string.format(
		"[SwordMoveGuard] player=%s swordAcquired=true walkSpeedOverride=%.1f",
		player.Name,
		SWORD_WALKSPEED
	))

	log(string.format("%s picked up sword (spawned round %d)", player.Name, spawnRound))
end

local function spawnSwordPickup(roundNumber: number)
	local spawnPos = getRandomArenaPosition()
	if not spawnPos then return end

	local toolsFolder = ServerStorage:FindFirstChild("Tools")
	local template = toolsFolder and toolsFolder:FindFirstChild("ClassicSword")
	if not template then
		warn("[SwordSpawn] ClassicSword not found in ServerStorage.Tools")
		return
	end

	local handleTemplate = template:FindFirstChild("Handle")
	if not handleTemplate then
		warn("[SwordSpawn] ClassicSword has no Handle")
		return
	end

	local pickupModel = Instance.new("Model")
	pickupModel.Name = "SwordPickup"

	local handleClone = handleTemplate:Clone()
	handleClone.Anchored = true
	handleClone.CanCollide = false
	handleClone.CFrame = CFrame.new(spawnPos) * CFrame.Angles(0, math.rad(math.random(0, 360)), 0)
	handleClone.Parent = pickupModel
	pickupModel.PrimaryPart = handleClone

	pickupModel:SetAttribute("SwordPickup", true)
	pickupModel:SetAttribute("SpawnRound", roundNumber)

	local highlight = Instance.new("Highlight")
	highlight.Name = "SwordGlow"
	highlight.Adornee = pickupModel
	highlight.FillColor = GLOW_FILL_COLOR
	highlight.FillTransparency = GLOW_FILL_TRANSPARENCY
	highlight.OutlineColor = GLOW_OUTLINE_COLOR
	highlight.OutlineTransparency = GLOW_OUTLINE_TRANSPARENCY
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Parent = pickupModel

	local particles = Instance.new("ParticleEmitter")
	particles.Name = "SwordSparkle"
	particles.Color = ColorSequence.new(Color3.fromRGB(0, 200, 255), Color3.fromRGB(255, 255, 255))
	particles.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(1, 0),
	})
	particles.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	particles.Lifetime = NumberRange.new(0.6, 1.2)
	particles.Rate = 8
	particles.Speed = NumberRange.new(1, 3)
	particles.SpreadAngle = Vector2.new(180, 180)
	particles.LightEmission = 0.8
	particles.LightInfluence = 0.3
	particles.Parent = handleClone

	local groundY = spawnPos.Y - SPAWN_Y_OFFSET

	local beaconAnchor = Instance.new("Part")
	beaconAnchor.Name = "BeaconAnchor"
	beaconAnchor.Anchored = true
	beaconAnchor.CanCollide = false
	beaconAnchor.Transparency = 1
	beaconAnchor.Size = Vector3.new(0.1, 0.1, 0.1)
	beaconAnchor.CFrame = CFrame.new(spawnPos.X, groundY + BEACON_HEIGHT, spawnPos.Z)
	beaconAnchor:SetAttribute("NoAnimate", true)
	beaconAnchor.Parent = pickupModel

	local attachBottom = Instance.new("Attachment")
	attachBottom.Name = "BeaconBottom"
	attachBottom.Parent = handleClone

	local attachTop = Instance.new("Attachment")
	attachTop.Name = "BeaconTop"
	attachTop.Parent = beaconAnchor

	local beam = Instance.new("Beam")
	beam.Name = "SwordBeacon"
	beam.Attachment0 = attachBottom
	beam.Attachment1 = attachTop
	beam.Color = ColorSequence.new(RING_COLOR, Color3.fromRGB(100, 240, 255))
	beam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(0.8, 0.6),
		NumberSequenceKeypoint.new(1, 1),
	})
	beam.LightEmission = 1
	beam.LightInfluence = 0
	beam.Width0 = 4
	beam.Width1 = 1
	beam.FaceCamera = true
	beam.Parent = pickupModel

	local ring = Instance.new("Part")
	ring.Name = "GroundRing"
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.CanCollide = false
	ring.Size = Vector3.new(0.15, RING_DIAMETER, RING_DIAMETER)
	ring.CFrame = CFrame.new(spawnPos.X, groundY + 0.1, spawnPos.Z) * CFrame.Angles(0, 0, math.rad(90))
	ring.Material = Enum.Material.Neon
	ring.Color = RING_COLOR
	ring.Transparency = 0.3
	ring:SetAttribute("NoAnimate", true)
	ring.Parent = pickupModel

	local collected = false
	local conn = handleClone.Touched:Connect(function(hit)
		if collected then return end

		local character = hit.Parent
		if not character then return end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then return end

		local player = Players:GetPlayerFromCharacter(character)
		if not player then return end

		if playerHasSword(player) then
			local userId = player.UserId
			local now = tick()
			if not swordDeniedCooldowns[userId] or (now - swordDeniedCooldowns[userId]) >= DENIED_COOLDOWN then
				swordDeniedCooldowns[userId] = now
				if swordSpawnedRemote then
					swordSpawnedRemote:FireClient(player, { denied = true })
				end
			end
			return
		end

		collected = true
		pickupModel:Destroy()

		giveSwordToPlayer(player, roundNumber)
	end)
	table.insert(touchConnections, conn)

	pickupModel.Parent = getPickupsFolder()

	_swordsSpawnedThisRound += 1
	table.insert(activePickups, { model = pickupModel, spawnRound = roundNumber })

	log(string.format(
		"Sword pickup spawned at (%.0f, %.0f, %.0f) for round %d (round total: %d)",
		spawnPos.X, spawnPos.Y, spawnPos.Z, roundNumber, _swordsSpawnedThisRound
	))

	if swordSpawnedRemote then
		fireSwordSpawnMatchAlert()
	end
end

local function cleanupExpiredSwords(currentRound: number)
	local remaining = {}
	for _, entry in ipairs(activePickups) do
		if currentRound >= entry.spawnRound + SWORD_LIFESPAN_ROUNDS then
			if entry.model and entry.model.Parent then
				entry.model:Destroy()
				log(string.format("Expired pickup from round %d (now round %d)", entry.spawnRound, currentRound))
			end
		else
			table.insert(remaining, entry)
		end
	end
	activePickups = remaining

	for player, data in pairs(swordHolders) do
		if currentRound >= data.spawnRound + SWORD_LIFESPAN_ROUNDS then
			log(string.format(
				"Expired sword from %s (spawned round %d, now round %d)",
				player.Name, data.spawnRound, currentRound
			))
			removeSwordFromPlayer(player)
		end
	end
end

local function onAnyPlayerDied(victim: Player)
	local character = victim.Character
	if not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	local creatorTag = humanoid:FindFirstChild("creator")
	if not creatorTag or not creatorTag:IsA("ObjectValue") then return end

	local killer = creatorTag.Value
	if not killer or not killer:IsA("Player") then return end

	if PlayerStateService.GetState(victim) ~= PlayerState.States.InMatch then
		return
	end
	if EliminationTracker.IsEliminated(victim) then
		log(string.format("[ElimSkip] player=%s skippedCause=Sword reason=already_eliminated", victim.Name))
		return
	end

	local round = math.max(_currentRound, 1)
	EliminationTracker.RecordElimination(victim, round, "Sword", killer)
	PlayerStateService.SetState(victim, PlayerState.States.Lobby)

	local aliveCount = #PlayerStateService.GetPlayersInState(PlayerState.States.InMatch)
	log(string.format("[SwordElim] killer=%s victim=%s authoritative=true", killer.Name, victim.Name))
	log(string.format("[RoundAlive] aliveCount=%d", aliveCount))
	if aliveCount <= 1 then
		log("[RoundEnd] triggerCause=SwordFinalKill")
	end

	onSwordKill(killer, victim)
end

fireSwordSpawnMatchAlert = function()
	if not swordSpawnedRemote then
		return
	end
	local recipients = {}
	local recipientNames = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local state = PlayerStateService.GetState(player)
		if state == PlayerState.States.InMatch then
			table.insert(recipients, player)
			table.insert(recipientNames, player.Name)
		else
			log(string.format("[MatchAlertSkip] player=%s state=%s reason=not_in_match", player.Name, tostring(state)))
		end
	end
	for _, player in ipairs(recipients) do
		swordSpawnedRemote:FireClient(player, {
			soundId = SOUND_ID,
			matchOnly = true,
			alertType = "SwordSpawn",
		})
	end
	log(string.format(
		"[MatchAlert] type=SwordSpawn recipients=%s",
		(#recipientNames > 0) and table.concat(recipientNames, ",") or "none"
	))
end

function SwordSpawnService.Init()
	if initialized then return end
	initialized = true

	local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotesFolder then
		remotesFolder = Instance.new("Folder")
		remotesFolder.Name = "Remotes"
		remotesFolder.Parent = ReplicatedStorage
	end

	local existing = remotesFolder:FindFirstChild("SwordSpawned")
	if not existing then
		swordSpawnedRemote = Instance.new("RemoteEvent")
		swordSpawnedRemote.Name = "SwordSpawned"
		swordSpawnedRemote.Parent = remotesFolder
	else
		swordSpawnedRemote = existing
	end

	local function hookPlayer(player: Player)
		player.CharacterAdded:Connect(function(character)
			local humanoid = character:WaitForChild("Humanoid", 10)
			if humanoid then
				humanoid.Died:Connect(function()
					onAnyPlayerDied(player)
				end)
			end
		end)
		if player.Character then
			local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoid.Died:Connect(function()
					onAnyPlayerDied(player)
				end)
			end
		end
	end

	for _, player in ipairs(Players:GetPlayers()) do
		hookPlayer(player)
	end
	Players.PlayerAdded:Connect(hookPlayer)

	Players.PlayerRemoving:Connect(function(player)
		if swordHolders[player] then
			removeSwordFromPlayer(player)
		end
		swordDeniedCooldowns[player.UserId] = nil
	end)

	log(string.format("Initialized — interval=%d–%ds, maxAlive=%d, initialChance=%.0f%%",
		SPAWN_INTERVAL_MIN, SPAWN_INTERVAL_MAX, MAX_SWORDS_ALIVE, INITIAL_SPAWN_CHANCE * 100))
end

function SwordSpawnService.OnRoundStart(roundNumber: number)
	cleanupExpiredSwords(roundNumber)

	-- Stop any loop from the previous round before setting new state
	_spawnLoopActive = false
	_currentRound = roundNumber
	_swordsSpawnedThisRound = 0

	if roundNumber > MAX_SPAWN_ROUND then
		log(string.format("Round %d > %d — force removing all swords", roundNumber, MAX_SPAWN_ROUND))
		removeAllSwords()
		clearPickupsFolder()
		disconnectTouched()
		activePickups = {}
		return
	end

	-- 50% chance of an immediate spawn at round start (prevents swords every single round)
	if math.random() < INITIAL_SPAWN_CHANCE and countActivePickups() < MAX_SWORDS_ALIVE then
		spawnSwordPickup(roundNumber)
	else
		log(string.format("Round %d: skipping initial spawn (chance or cap)", roundNumber))
	end

	-- Periodic loop: one attempt every 16–22 s, capped at 1 sword total per round
	_spawnLoopActive = true
	task.spawn(function()
		while _spawnLoopActive and _currentRound == roundNumber do
			local interval = SPAWN_INTERVAL_MIN + math.random() * (SPAWN_INTERVAL_MAX - SPAWN_INTERVAL_MIN)
			task.wait(interval)
			if not _spawnLoopActive or _currentRound ~= roundNumber then break end
			if _swordsSpawnedThisRound >= 1 then
				log(string.format("Round %d: per-round cap reached — no further spawns", roundNumber))
				break
			end
			local alive = countActivePickups()
			if alive < MAX_SWORDS_ALIVE then
				spawnSwordPickup(roundNumber)
			else
				log(string.format("Round %d: %d/%d swords active — skipping periodic spawn", roundNumber, alive, MAX_SWORDS_ALIVE))
			end
		end
		log(string.format("Spawn loop ended for round %d", roundNumber))
	end)
end

function SwordSpawnService.OnRoundEnd()
	_spawnLoopActive = false
	for _, entry in ipairs(activePickups) do
		if entry.model and entry.model.Parent then
			entry.model:Destroy()
			log(string.format("Round ended — despawned unpicked sword from round %d", entry.spawnRound))
		end
	end
	activePickups = {}
end

function SwordSpawnService.OnMatchEnd()
	_spawnLoopActive = false
	removeAllSwords()
	clearPickupsFolder()
	disconnectTouched()
	activePickups = {}
	log("Match ended — all swords cleaned up")
end

return SwordSpawnService
