--[[
	SwordSpawnService
	Server-side random sword spawning during rounds 1-7.

	- Random chance per eligible round to spawn a ClassicSword pickup
	- Pickup is a hovering world model (client handles animation)
	- On collection: clone ClassicSword from ServerStorage into Backpack
	- First kill with sword: +50 coins, sword removed immediately
	- Swords auto-removed after 2 rounds or at round 8+
	- All swords cleaned up on match end

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

local SPAWN_CHANCE = 0.35
local MAX_SPAWN_ROUND = 7
local SWORD_LIFESPAN_ROUNDS = 2
local KILL_BONUS = 50
local SOUND_ID = "rbxassetid://93965767748928"

local PICKUP_FOLDER_NAME = "SwordPickups"
local SPAWN_Y_OFFSET = 3.0
local EDGE_MARGIN = 6
local RAYCAST_HEIGHT = 80

local GLOW_FILL_COLOR = Color3.fromRGB(0, 200, 255)
local GLOW_FILL_TRANSPARENCY = 0.5
local GLOW_OUTLINE_COLOR = Color3.fromRGB(255, 255, 255)
local GLOW_OUTLINE_TRANSPARENCY = 0.1

local SwordSpawnService = {}

local initialized = false
local pickupsFolder: Folder? = nil
local touchConnections: { RBXScriptConnection } = {}

local activePickups: { { model: Model, spawnRound: number } } = {}
local swordHolders: { [Player]: { tool: Tool, spawnRound: number, deathConn: RBXScriptConnection? } } = {}

local swordSpawnedRemote: RemoteEvent? = nil

local function log(...)
	print("[SwordSpawn]", ...)
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

local function removeSwordFromPlayer(player: Player)
	local data = swordHolders[player]
	if not data then return end

	if data.deathConn then
		data.deathConn:Disconnect()
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
	log(player.Name, "sword removed")
end

local function removeAllSwords()
	for player, _ in pairs(swordHolders) do
		removeSwordFromPlayer(player)
	end
	swordHolders = {}
end

local function onSwordKill(killer: Player, victim: Player)
	log(string.format("%s killed %s with sword! +%d coins", killer.Name, victim.Name, KILL_BONUS))
	EconomyService.AwardCoins(killer, KILL_BONUS, "SwordKill", true)
	EconomyService.TrackMatchCoins(killer, KILL_BONUS)
	removeSwordFromPlayer(killer)
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

	local backpack = player:FindFirstChild("Backpack")
	if backpack then
		clone.Parent = backpack
	end

	local deathConn: RBXScriptConnection? = nil
	local character = player.Character
	if character then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			deathConn = humanoid.Died:Connect(function()
				removeSwordFromPlayer(player)
			end)
		end
	end

	swordHolders[player] = {
		tool = clone,
		spawnRound = spawnRound,
		deathConn = deathConn,
	}

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

	local collected = false
	local conn = handleClone.Touched:Connect(function(hit)
		if collected then return end

		local character = hit.Parent
		if not character then return end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then return end

		local player = Players:GetPlayerFromCharacter(character)
		if not player then return end

		if swordHolders[player] then return end

		collected = true
		pickupModel:Destroy()

		giveSwordToPlayer(player, roundNumber)
	end)
	table.insert(touchConnections, conn)

	pickupModel.Parent = getPickupsFolder()

	table.insert(activePickups, { model = pickupModel, spawnRound = roundNumber })

	log(string.format(
		"Sword pickup spawned at (%.0f, %.0f, %.0f) for round %d",
		spawnPos.X, spawnPos.Y, spawnPos.Z, roundNumber
	))

	if swordSpawnedRemote then
		swordSpawnedRemote:FireAllClients({ soundId = SOUND_ID })
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

	if swordHolders[killer] then
		onSwordKill(killer, victim)
	end
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
	end)

	log("Initialized")
end

function SwordSpawnService.OnRoundStart(roundNumber: number)
	cleanupExpiredSwords(roundNumber)

	if roundNumber > MAX_SPAWN_ROUND then
		log(string.format("Round %d > %d — force removing all swords", roundNumber, MAX_SPAWN_ROUND))
		removeAllSwords()
		clearPickupsFolder()
		disconnectTouched()
		activePickups = {}
		return
	end

	if math.random() <= SPAWN_CHANCE then
		spawnSwordPickup(roundNumber)
	else
		log(string.format("Round %d: No sword spawn (random)", roundNumber))
	end
end

function SwordSpawnService.OnRoundEnd()
end

function SwordSpawnService.OnMatchEnd()
	removeAllSwords()
	clearPickupsFolder()
	disconnectTouched()
	activePickups = {}
	log("Match ended — all swords cleaned up")
end

return SwordSpawnService
