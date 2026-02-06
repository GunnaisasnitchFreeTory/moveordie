--[[
	MapManager
	Server-side arena registration, lifecycle hooks, spawn utilities,
	active bounds tracking, and out-of-bounds enforcement.
	
	The arena (SquarePlatformMap) is ALWAYS visible in the world.
	Active bounds shrink each round to increase difficulty.
	Players outside active bounds are eliminated.
	
	API:
		Init()                        → Initialize and locate arena
		GetArena()                    → Instance reference
		IsActive()                    → boolean (match in progress)
		OnMatchStart()                → Called when Playing phase begins
		OnMatchEnd()                  → Called when match ends
		OnRoundStart(roundIndex)      → Called at start of each round (handles shrink)
		GetArenaSpawnCFrames(count)   → { CFrame } for spawning on arena
		GetLobbySpawnCFrame()         → CFrame for returning to lobby
		GetActiveBounds()             → { cframe, sizeX, sizeZ, topY }
		GetBaseBounds()               → { cframe, size }
		ResetBounds()                 → Reset active bounds to full size
		IsPositionInBounds(pos)       → boolean
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Server = ServerScriptService:WaitForChild("Server")

local SpawnConfig = require(Shared:WaitForChild("SpawnConfig"))
local ShrinkConfig = require(Shared:WaitForChild("ShrinkConfig"))
local PlayerState = require(Shared:WaitForChild("PlayerState"))
local PlayerStateService = require(Server:WaitForChild("PlayerStateService"))

--[[ CONFIGURATION ]]
local Config = {
	ArenaName = "SquarePlatformMap",
	DebugLog = true,
	OutOfBoundsCheckInterval = 0.25, -- Seconds between OOB checks
}

--[[ INTERNAL STATE ]]
local arena: Instance? = nil
local arenaCFrame: CFrame? = nil
local arenaSize: Vector3? = nil
local isActive: boolean = false
local initialized: boolean = false

-- Active bounds (shrinks each round)
local activeSizeX: number = 0
local activeSizeZ: number = 0
local currentShrinkStep: number = 0

-- Visual boundary (storm wall)
local boundsFolder: Folder? = nil
local boundsWalls: { Part } = {}
local stormVolume: Part? = nil

-- Out-of-bounds checking
local oobCheckConnection: RBXScriptConnection? = nil
local lastOobCheck: number = 0

local MapManager = {}

--[[ HELPERS ]]

local function log(...)
	if Config.DebugLog then
		print("[MapManager]", ...)
	end
end

local function shrinkLog(...)
	if ShrinkConfig.DebugLog then
		print("[MapManager:Shrink]", ...)
	end
end

--[[
	Check if a world position is inside the active bounds.
]]
local function isPositionInsideBounds(worldPos: Vector3): boolean
	if not arenaCFrame then return true end
	
	-- Convert to local space relative to arena center
	local localPos = arenaCFrame:PointToObjectSpace(worldPos)
	
	local halfX = activeSizeX / 2
	local halfZ = activeSizeZ / 2
	
	return localPos.X >= -halfX and localPos.X <= halfX
		and localPos.Z >= -halfZ and localPos.Z <= halfZ
end

--[[
	Create particle emitters for animated storm effect.
]]
local function createStormParticles(parent: BasePart)
	-- Main rising mist particles
	local mist = Instance.new("ParticleEmitter")
	mist.Name = "StormMist"
	mist.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 180, 100)),  -- Bright orange
		ColorSequenceKeypoint.new(0.5, ShrinkConfig.BoundsColor),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 100, 30)),   -- Deep orange
	})
	mist.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 3),
		NumberSequenceKeypoint.new(0.5, 8),
		NumberSequenceKeypoint.new(1, 12),
	})
	mist.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(0.3, 0.4),
		NumberSequenceKeypoint.new(0.7, 0.6),
		NumberSequenceKeypoint.new(1, 1),
	})
	mist.Lifetime = NumberRange.new(3, 6)
	mist.Rate = 25
	mist.Speed = NumberRange.new(8, 20)
	mist.SpreadAngle = Vector2.new(20, 60)
	mist.Rotation = NumberRange.new(0, 360)
	mist.RotSpeed = NumberRange.new(-60, 60)
	mist.Drag = 0.5
	mist.LightEmission = 0.5
	mist.LightInfluence = 0.3
	mist.Acceleration = Vector3.new(0, 5, 0)  -- Rise upward
	mist.Parent = parent
	
	-- Sparkle/energy particles for visibility
	local sparks = Instance.new("ParticleEmitter")
	sparks.Name = "StormSparks"
	sparks.Color = ColorSequence.new(Color3.fromRGB(255, 220, 150))  -- Bright yellowish
	sparks.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(0.5, 1.5),
		NumberSequenceKeypoint.new(1, 0),
	})
	sparks.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(0.5, 0.5),
		NumberSequenceKeypoint.new(1, 1),
	})
	sparks.Lifetime = NumberRange.new(1, 2.5)
	sparks.Rate = 10
	sparks.Speed = NumberRange.new(5, 15)
	sparks.SpreadAngle = Vector2.new(40, 40)
	sparks.LightEmission = 1
	sparks.LightInfluence = 0
	sparks.Parent = parent
	
	return mist
end

--[[
	Create a single wall part for the storm boundary.
]]
local function createStormWall(name: string, parent: Instance): Part
	local wall = Instance.new("Part")
	wall.Name = name
	wall.Anchored = true
	wall.CanCollide = false
	wall.CastShadow = false
	wall.Material = Enum.Material.Neon  -- Glowing neon for visibility
	wall.Color = ShrinkConfig.BoundsColor
	wall.Transparency = ShrinkConfig.BoundsTransparency
	wall.Parent = parent
	
	-- Add particle effects
	createStormParticles(wall)
	
	return wall
end

--[[
	Get or create the bounds folder.
]]
local function getBoundsFolder(): Folder
	if boundsFolder and boundsFolder.Parent then
		return boundsFolder
	end
	
	-- Get or create effects folder
	local effectsFolder = Workspace:FindFirstChild("ArenaEffects")
	if not effectsFolder then
		effectsFolder = Instance.new("Folder")
		effectsFolder.Name = "ArenaEffects"
		effectsFolder.Parent = Workspace
	end
	
	boundsFolder = effectsFolder:FindFirstChild("Bounds")
	if not boundsFolder then
		boundsFolder = Instance.new("Folder")
		boundsFolder.Name = "Bounds"
		boundsFolder.Parent = effectsFolder
	end
	
	return boundsFolder
end

--[[
	Create or update the storm boundary visuals.
]]
local function updateBoundsVisual()
	if not ShrinkConfig.ShowBoundsVisual then
		clearBoundsVisual()
		return
	end
	
	if not arenaCFrame or not arenaSize then return end
	
	local folder = getBoundsFolder()
	local wallThickness = 3
	local wallHeight = ShrinkConfig.BoundsHeight
	
	-- Create walls if needed (North, South, East, West)
	if #boundsWalls == 0 then
		table.insert(boundsWalls, createStormWall("StormWall_North", folder))
		table.insert(boundsWalls, createStormWall("StormWall_South", folder))
		table.insert(boundsWalls, createStormWall("StormWall_East", folder))
		table.insert(boundsWalls, createStormWall("StormWall_West", folder))
	end
	
	-- Create storm volume (faint vertical volume inside)
	if not stormVolume then
		stormVolume = Instance.new("Part")
		stormVolume.Name = "StormVolume"
		stormVolume.Anchored = true
		stormVolume.CanCollide = false
		stormVolume.CastShadow = false
		stormVolume.Material = Enum.Material.ForceField
		stormVolume.Color = ShrinkConfig.BoundsColor
		stormVolume.Transparency = 0.95 -- Very faint
		stormVolume.Parent = folder
	end
	
	-- Calculate positions
	local centerX = arenaCFrame.Position.X
	local centerZ = arenaCFrame.Position.Z
	local topY = arenaCFrame.Position.Y + arenaSize.Y / 2 + wallHeight / 2
	
	local halfSizeX = activeSizeX / 2
	local halfSizeZ = activeSizeZ / 2
	
	-- Update wall properties
	for _, wall in ipairs(boundsWalls) do
		wall.Color = ShrinkConfig.BoundsColor
		wall.Transparency = ShrinkConfig.BoundsTransparency
	end
	
	-- North wall (front, +Z)
	boundsWalls[1].Size = Vector3.new(activeSizeX + wallThickness * 2, wallHeight, wallThickness)
	boundsWalls[1].CFrame = CFrame.new(centerX, topY, centerZ + halfSizeZ + wallThickness / 2)
	
	-- South wall (back, -Z)
	boundsWalls[2].Size = Vector3.new(activeSizeX + wallThickness * 2, wallHeight, wallThickness)
	boundsWalls[2].CFrame = CFrame.new(centerX, topY, centerZ - halfSizeZ - wallThickness / 2)
	
	-- East wall (right, +X)
	boundsWalls[3].Size = Vector3.new(wallThickness, wallHeight, activeSizeZ)
	boundsWalls[3].CFrame = CFrame.new(centerX + halfSizeX + wallThickness / 2, topY, centerZ)
	
	-- West wall (left, -X)
	boundsWalls[4].Size = Vector3.new(wallThickness, wallHeight, activeSizeZ)
	boundsWalls[4].CFrame = CFrame.new(centerX - halfSizeX - wallThickness / 2, topY, centerZ)
	
	-- Update storm volume (covers area outside bounds up to full arena)
	-- Actually, let's skip the volume since it would cover the play area
	-- The walls alone with particles create the storm effect
	if stormVolume then
		stormVolume.Size = Vector3.new(activeSizeX, 0.1, activeSizeZ)
		stormVolume.CFrame = CFrame.new(centerX, topY + wallHeight / 2, centerZ)
		stormVolume.Transparency = 0.98
	end
end

local function clearBoundsVisual()
	for _, wall in ipairs(boundsWalls) do
		wall:Destroy()
	end
	boundsWalls = {}
	
	if stormVolume then
		stormVolume:Destroy()
		stormVolume = nil
	end
	
	if boundsFolder then
		boundsFolder:Destroy()
		boundsFolder = nil
	end
end

--[[
	Eliminate a player who is out of bounds.
]]
local function eliminateOutOfBounds(player: Player)
	local character = player.Character
	if not character then return end
	
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		humanoid.Health = 0
	end
	
	-- Set to Lobby state
	PlayerStateService.SetState(player, PlayerState.States.Lobby)
	
	shrinkLog(string.format("Eliminated %s (OutOfBounds)", player.Name))
end

--[[
	Check all InMatch players for out-of-bounds violations.
]]
local function checkOutOfBounds()
	if not isActive then return end
	
	local inMatchPlayers = PlayerStateService.GetPlayersInState(PlayerState.States.InMatch)
	
	for _, player in ipairs(inMatchPlayers) do
		local character = player.Character
		if not character then continue end
		
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then continue end
		
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then continue end
		
		if not isPositionInsideBounds(rootPart.Position) then
			eliminateOutOfBounds(player)
		end
	end
end

--[[
	Start the out-of-bounds checking loop.
]]
local function startOobChecking()
	if oobCheckConnection then return end
	
	lastOobCheck = tick()
	
	oobCheckConnection = RunService.Heartbeat:Connect(function()
		local now = tick()
		if now - lastOobCheck >= Config.OutOfBoundsCheckInterval then
			lastOobCheck = now
			checkOutOfBounds()
		end
	end)
	
	log("Out-of-bounds checking started")
end

--[[
	Stop the out-of-bounds checking loop.
]]
local function stopOobChecking()
	if oobCheckConnection then
		oobCheckConnection:Disconnect()
		oobCheckConnection = nil
	end
	log("Out-of-bounds checking stopped")
end

--[[ PUBLIC API ]]

--[[
	Initialize the MapManager.
	Locates and validates the existing arena in Workspace.
]]
function MapManager.Init()
	if initialized then
		warn("[MapManager] Already initialized")
		return
	end
	
	-- Locate the arena
	local found = Workspace:FindFirstChild(Config.ArenaName)
	
	if not found then
		error(string.format("[MapManager] Arena '%s' not found in Workspace! Create it before running.", Config.ArenaName))
	end
	
	-- Get CFrame and Size
	if found:IsA("BasePart") then
		arenaCFrame = found.CFrame
		arenaSize = found.Size
	elseif found:IsA("Model") then
		local primary = found.PrimaryPart or found:FindFirstChildWhichIsA("BasePart")
		if primary then
			arenaCFrame = primary.CFrame
			arenaSize = primary.Size
		else
			error("[MapManager] Arena Model has no usable BasePart")
		end
	else
		error(string.format("[MapManager] Arena '%s' is not a BasePart or Model", Config.ArenaName))
	end
	
	arena = found
	initialized = true
	isActive = false
	
	-- Initialize active bounds to full size
	activeSizeX = arenaSize.X
	activeSizeZ = arenaSize.Z
	currentShrinkStep = 0
	
	log(string.format("Initialized — Arena '%s' registered (%s), Size: %.0fx%.0f", 
		Config.ArenaName, found.ClassName, arenaSize.X, arenaSize.Z))
end

--[[
	Get the arena reference.
]]
function MapManager.GetArena(): Instance?
	return arena
end

--[[
	Check if a match is currently active on the arena.
]]
function MapManager.IsActive(): boolean
	return isActive
end

--[[
	Check if a world position is inside the current active bounds.
]]
function MapManager.IsPositionInBounds(worldPos: Vector3): boolean
	return isPositionInsideBounds(worldPos)
end

--[[
	Called when a match starts (Playing phase begins).
	Resets bounds to full size and starts OOB checking.
]]
function MapManager.OnMatchStart()
	if not initialized then
		warn("[MapManager] Not initialized, cannot start match")
		return
	end
	
	isActive = true
	
	-- Reset bounds at match start
	MapManager.ResetBounds()
	
	-- Show boundary visual immediately
	updateBoundsVisual()
	
	-- Start out-of-bounds checking
	startOobChecking()
	
	log("Match started — Arena active, OOB checking enabled")
end

--[[
	Called when a match ends.
	Stops OOB checking and clears visuals.
]]
function MapManager.OnMatchEnd()
	if not initialized then
		warn("[MapManager] Not initialized, cannot end match")
		return
	end
	
	isActive = false
	
	-- Stop out-of-bounds checking
	stopOobChecking()
	
	clearBoundsVisual()
	log("Match ended — Arena idle")
end

--[[
	Called at the start of each round.
	Handles shrinking logic.
]]
function MapManager.OnRoundStart(roundIndex: number)
	if not initialized or not arenaSize then return end
	
	if not ShrinkConfig.Enabled then return end
	
	if roundIndex < ShrinkConfig.StartsAtRound then
		-- Update visual even if not shrinking yet
		updateBoundsVisual()
		return
	end
	
	-- Calculate shrink amount
	local shrinkSteps = roundIndex - ShrinkConfig.StartsAtRound + 1
	local totalShrink = shrinkSteps * ShrinkConfig.ShrinkPerRoundStuds
	
	-- Apply shrink (clamped to minimum)
	local newSizeX = math.max(arenaSize.X - totalShrink, ShrinkConfig.MinSizeX)
	local newSizeZ = math.max(arenaSize.Z - totalShrink, ShrinkConfig.MinSizeZ)
	
	-- Only log if size actually changed
	if newSizeX ~= activeSizeX or newSizeZ ~= activeSizeZ then
		activeSizeX = newSizeX
		activeSizeZ = newSizeZ
		currentShrinkStep = shrinkSteps
		
		shrinkLog(string.format("Round %d shrink: Active bounds now %.0fx%.0f (step %d)", 
			roundIndex, activeSizeX, activeSizeZ, currentShrinkStep))
	end
	
	updateBoundsVisual()
end

--[[
	Reset active bounds to full arena size.
]]
function MapManager.ResetBounds()
	if not arenaSize then return end
	
	activeSizeX = arenaSize.X
	activeSizeZ = arenaSize.Z
	currentShrinkStep = 0
	
	shrinkLog(string.format("Bounds reset to full size: %.0fx%.0f", activeSizeX, activeSizeZ))
end

--[[
	Get the current active bounds.
	Used by HazardManager to compute grid within shrunken area.
]]
function MapManager.GetActiveBounds(): { cframe: CFrame, sizeX: number, sizeZ: number, topY: number }?
	if not initialized or not arenaCFrame or not arenaSize then
		return nil
	end
	
	return {
		cframe = arenaCFrame,
		sizeX = activeSizeX,
		sizeZ = activeSizeZ,
		topY = arenaCFrame.Position.Y + arenaSize.Y / 2,
	}
end

--[[
	Get the base (full) arena bounds.
	Used for reference.
]]
function MapManager.GetBaseBounds(): { cframe: CFrame, size: Vector3 }?
	if not initialized or not arenaCFrame or not arenaSize then
		return nil
	end
	
	return {
		cframe = arenaCFrame,
		size = arenaSize,
	}
end

--[[
	Get spawn CFrames on the arena surface.
	Uses ACTIVE bounds (shrunk area) for spawning.
]]
function MapManager.GetArenaSpawnCFrames(count: number): { CFrame }
	if not initialized or not arenaCFrame or not arenaSize then
		warn("[MapManager] Not initialized, cannot get spawn CFrames")
		return {}
	end
	
	local spawns: { CFrame } = {}
	local yOffset = SpawnConfig.ArenaSpawnYOffset
	
	-- Use active bounds for spread
	local spreadRadius = math.min(
		SpawnConfig.ArenaSpawnSpreadRadius, 
		activeSizeX / 2 - 5, 
		activeSizeZ / 2 - 5
	)
	
	-- Top surface Y position
	local topY = arenaCFrame.Position.Y + arenaSize.Y / 2 + yOffset
	
	-- Generate spread spawn points
	for i = 1, count do
		local angle = (i / count) * math.pi * 2 + math.random() * 0.5
		local radius = spreadRadius * (0.3 + math.random() * 0.7)
		
		local offsetX = math.cos(angle) * radius
		local offsetZ = math.sin(angle) * radius
		
		local spawnPos = Vector3.new(
			arenaCFrame.Position.X + offsetX,
			topY,
			arenaCFrame.Position.Z + offsetZ
		)
		
		-- Face toward center
		local lookAt = Vector3.new(arenaCFrame.Position.X, topY, arenaCFrame.Position.Z)
		local spawnCFrame = CFrame.lookAt(spawnPos, lookAt)
		
		table.insert(spawns, spawnCFrame)
	end
	
	return spawns
end

--[[
	Get the lobby spawn CFrame.
	Prefers SpawnLocation in Workspace, falls back to config.
]]
function MapManager.GetLobbySpawnCFrame(): CFrame
	-- Try to find SpawnLocation in Workspace
	local spawnLocation = Workspace:FindFirstChildOfClass("SpawnLocation", true)
	
	-- Also check Lobby folder
	local lobbyFolder = Workspace:FindFirstChild("Lobby")
	if lobbyFolder then
		local lobbySpawn = lobbyFolder:FindFirstChildOfClass("SpawnLocation")
		if lobbySpawn then
			spawnLocation = lobbySpawn
		end
	end
	
	if spawnLocation then
		-- Spawn slightly above the SpawnLocation
		local pos = spawnLocation.Position + Vector3.new(0, 3, 0)
		return CFrame.new(pos)
	end
	
	-- Fallback to config
	return CFrame.new(SpawnConfig.LobbySpawnPosition)
end

return MapManager
