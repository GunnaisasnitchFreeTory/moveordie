--[[
	HazardManager
	Server-side beam hazard system.
	
	Divides SquarePlatformMap into a grid, selects unsafe zones,
	spawns telegraph beams, and eliminates players on Strike.
	
	API:
		Init()                      → Initialize the manager
		SelectUnsafeZones(round)    → Pick unsafe cells for this round (scales with difficulty)
		SpawnTelegraphs()           → Create visible beam warnings
		Strike()                    → Eliminate players in unsafe zones
		ClearTelegraphs()           → Remove all beam visuals
		GetUnsafeZones()            → Current unsafe zone data
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Server = ServerScriptService:WaitForChild("Server")

local HazardConfig = require(Shared:WaitForChild("HazardConfig"))
local PlayerState = require(Shared:WaitForChild("PlayerState"))
local PlayerStateService = require(Server:WaitForChild("PlayerStateService"))
local MapManager = require(Server:WaitForChild("MapManager"))

--[[ TYPES ]]
export type GridCell = {
	row: number,
	col: number,
	localCenter: Vector3,
	worldCenter: Vector3,
}

--[[ INTERNAL STATE ]]
local initialized = false
local effectsFolder: Folder? = nil
local currentUnsafeZones: { GridCell } = {}

-- Base platform data (never changes)
local basePlatformData: {
	cframe: CFrame,
	size: Vector3,
	topY: number,
}? = nil

-- Active platform data (changes with shrink)
local platformData: {
	cframe: CFrame,
	size: Vector3,
	cellSizeX: number,
	cellSizeZ: number,
	topY: number,
}? = nil

-- Selected cells lookup for spacing checks (row_col -> true)
local selectedCellsLookup: { [string]: boolean } = {}

-- Spawned beam references for accurate hit detection
local spawnedBeams: { Part } = {}

local HazardManager = {}

--[[ HELPERS ]]

local function log(...)
	if HazardConfig.DebugLog then
		print("[HazardManager]", ...)
	end
end

local function cellKey(row: number, col: number): string
	return string.format("%d_%d", row, col)
end

--[[
	Convert local grid position to world position using platform CFrame.
]]
local function localToWorld(localPos: Vector3): Vector3
	if not platformData then
		error("[HazardManager] Platform data not initialized")
	end
	return platformData.cframe:PointToWorldSpace(localPos)
end

--[[
	Convert world position to local grid position.
]]
local function worldToLocal(worldPos: Vector3): Vector3
	if not platformData then
		error("[HazardManager] Platform data not initialized")
	end
	return platformData.cframe:PointToObjectSpace(worldPos)
end

--[[
	Compute grid cell data from row/col.
]]
local function getCellData(row: number, col: number): GridCell
	if not platformData then
		error("[HazardManager] Platform data not initialized")
	end
	
	local gridSize = HazardConfig.GridSize
	local halfSizeX = platformData.size.X / 2
	local halfSizeZ = platformData.size.Z / 2
	
	local localX = -halfSizeX + (col - 0.5) * platformData.cellSizeX
	local localZ = -halfSizeZ + (row - 0.5) * platformData.cellSizeZ
	local localY = platformData.size.Y / 2
	
	local localCenter = Vector3.new(localX, localY, localZ)
	local worldCenter = localToWorld(localCenter)
	
	return {
		row = row,
		col = col,
		localCenter = localCenter,
		worldCenter = worldCenter,
	}
end

--[[
	Get the grid cell a world position falls into.
]]
local function getGridCellAt(worldPosition: Vector3): (number?, number?)
	if not platformData then return nil, nil end
	
	local localPos = worldToLocal(worldPosition)
	local gridSize = HazardConfig.GridSize
	local halfSizeX = platformData.size.X / 2
	local halfSizeZ = platformData.size.Z / 2
	
	local col = math.floor((localPos.X + halfSizeX) / platformData.cellSizeX) + 1
	local row = math.floor((localPos.Z + halfSizeZ) / platformData.cellSizeZ) + 1
	
	if row < 1 or row > gridSize or col < 1 or col > gridSize then
		return nil, nil
	end
	
	return row, col
end

--[[
	Check if a grid cell is in the unsafe list.
]]
local function isCellUnsafe(row: number, col: number): boolean
	return selectedCellsLookup[cellKey(row, col)] == true
end

--[[
	Check if a cell has any selected neighbors within radius.
]]
local function hasSelectedNeighbor(row: number, col: number, radius: number): boolean
	local gridSize = HazardConfig.GridSize
	
	for dr = -radius, radius do
		for dc = -radius, radius do
			if dr == 0 and dc == 0 then continue end
			
			local nr = row + dr
			local nc = col + dc
			
			if nr >= 1 and nr <= gridSize and nc >= 1 and nc <= gridSize then
				if selectedCellsLookup[cellKey(nr, nc)] then
					return true
				end
			end
		end
	end
	
	return false
end

--[[
	Shuffle an array in place (Fisher-Yates).
]]
local function shuffle<T>(arr: { T }): { T }
	for i = #arr, 2, -1 do
		local j = math.random(1, i)
		arr[i], arr[j] = arr[j], arr[i]
	end
	return arr
end

--[[
	Get or create the effects folder.
]]
local function getEffectsFolder(): Folder
	if effectsFolder and effectsFolder.Parent then
		return effectsFolder
	end
	
	effectsFolder = Workspace:FindFirstChild(HazardConfig.EffectsFolderName)
	if not effectsFolder then
		effectsFolder = Instance.new("Folder")
		effectsFolder.Name = HazardConfig.EffectsFolderName
		effectsFolder.Parent = Workspace
	end
	
	return effectsFolder
end

--[[
	Get or create the beams folder.
]]
local function getBeamsFolder(): Folder
	local folder = getEffectsFolder()
	
	local beamsFolder = folder:FindFirstChild("TelegraphBeams")
	if not beamsFolder then
		beamsFolder = Instance.new("Folder")
		beamsFolder.Name = "TelegraphBeams"
		beamsFolder.Parent = folder
	end
	
	return beamsFolder
end

--[[ PUBLIC API ]]

--[[
	Refresh platformData from MapManager's active bounds.
	Called at start of each round to account for shrinking.
]]
local function refreshPlatformData()
	local activeBounds = MapManager.GetActiveBounds()
	if not activeBounds or not basePlatformData then
		return false
	end
	
	local gridSize = HazardConfig.GridSize
	local cellSizeX = activeBounds.sizeX / gridSize
	local cellSizeZ = activeBounds.sizeZ / gridSize
	
	platformData = {
		cframe = activeBounds.cframe,
		size = Vector3.new(activeBounds.sizeX, basePlatformData.size.Y, activeBounds.sizeZ),
		cellSizeX = cellSizeX,
		cellSizeZ = cellSizeZ,
		topY = activeBounds.topY,
	}
	
	return true
end

function HazardManager.Init()
	if initialized then
		warn("[HazardManager] Already initialized")
		return
	end
	
	local arena = MapManager.GetArena()
	if not arena then
		error("[HazardManager] Arena not found, cannot initialize")
	end
	
	local arenaCFrame: CFrame
	local arenaSize: Vector3
	
	if arena:IsA("BasePart") then
		arenaCFrame = arena.CFrame
		arenaSize = arena.Size
	elseif arena:IsA("Model") then
		local primary = arena.PrimaryPart or arena:FindFirstChildWhichIsA("BasePart")
		if primary then
			arenaCFrame = primary.CFrame
			arenaSize = primary.Size
		else
			error("[HazardManager] Arena Model has no usable BasePart")
		end
	else
		error("[HazardManager] Arena is not a BasePart or Model")
	end
	
	-- Store base platform data (never changes)
	basePlatformData = {
		cframe = arenaCFrame,
		size = arenaSize,
		topY = arenaCFrame.Position.Y + arenaSize.Y / 2,
	}
	
	-- Initialize platformData with full size
	local gridSize = HazardConfig.GridSize
	local cellSizeX = arenaSize.X / gridSize
	local cellSizeZ = arenaSize.Z / gridSize
	
	platformData = {
		cframe = arenaCFrame,
		size = arenaSize,
		cellSizeX = cellSizeX,
		cellSizeZ = cellSizeZ,
		topY = arenaCFrame.Position.Y + arenaSize.Y / 2,
	}
	
	initialized = true
	log(string.format("Initialized — Grid %dx%d, cell size %.1fx%.1f", 
		gridSize, gridSize, cellSizeX, cellSizeZ))
end

--[[
	Select random unsafe zones for this round.
	roundIndex: Current round number (1-indexed). Affects difficulty.
]]
function HazardManager.SelectUnsafeZones(roundIndex: number)
	if not initialized then
		warn("[HazardManager] Not initialized")
		return
	end
	
	roundIndex = roundIndex or 1
	
	-- Refresh platform data from active bounds (handles shrink)
	refreshPlatformData()
	
	-- Clear previous
	currentUnsafeZones = {}
	selectedCellsLookup = {}
	
	-- Calculate unsafe percent based on round (difficulty ramp)
	local basePercent = HazardConfig.MinUnsafePercent
	local rampPerRound = HazardConfig.UnsafePercentPerRound
	local maxPercent = HazardConfig.MaxUnsafePercent
	
	local unsafePercent = math.clamp(
		basePercent + (roundIndex - 1) * rampPerRound,
		basePercent,
		maxPercent
	)
	
	-- Build list of all cells
	local gridSize = HazardConfig.GridSize
	local totalCells = gridSize * gridSize
	local allCells: { { row: number, col: number } } = {}
	
	for row = 1, gridSize do
		for col = 1, gridSize do
			table.insert(allCells, { row = row, col = col })
		end
	end
	
	shuffle(allCells)
	
	local targetCount = math.max(1, math.floor(totalCells * unsafePercent))
	local useSpacing = HazardConfig.UseSpacing
	local spacingRadius = HazardConfig.SpacingRadius
	local maxAttempts = HazardConfig.MaxSelectionAttempts
	
	-- Pass 1: Select cells with spacing constraint
	local attempts = 0
	local cellIndex = 1
	
	while #currentUnsafeZones < targetCount and attempts < maxAttempts do
		if cellIndex > #allCells then
			cellIndex = 1
			shuffle(allCells)  -- Reshuffle for another pass
		end
		
		local cell = allCells[cellIndex]
		local key = cellKey(cell.row, cell.col)
		
		-- Skip if already selected
		if not selectedCellsLookup[key] then
			local canSelect = true
			
			-- Check spacing constraint
			if useSpacing and hasSelectedNeighbor(cell.row, cell.col, spacingRadius) then
				canSelect = false
			end
			
			if canSelect then
				selectedCellsLookup[key] = true
				local cellData = getCellData(cell.row, cell.col)
				table.insert(currentUnsafeZones, cellData)
			end
		end
		
		cellIndex = cellIndex + 1
		attempts = attempts + 1
	end
	
	-- Pass 2: If we didn't reach target, relax spacing and fill
	if #currentUnsafeZones < targetCount then
		shuffle(allCells)
		for _, cell in ipairs(allCells) do
			if #currentUnsafeZones >= targetCount then break end
			
			local key = cellKey(cell.row, cell.col)
			if not selectedCellsLookup[key] then
				selectedCellsLookup[key] = true
				local cellData = getCellData(cell.row, cell.col)
				table.insert(currentUnsafeZones, cellData)
			end
		end
	end
	
	log(string.format("Round %d: Selected %d unsafe zones (%.0f%% of %d)", 
		roundIndex, #currentUnsafeZones, unsafePercent * 100, totalCells))
end

--[[
	Spawn visible beam telegraphs above each unsafe zone.
]]
function HazardManager.SpawnTelegraphs()
	if not initialized or not platformData then
		warn("[HazardManager] Not initialized")
		return
	end
	
	local beamsFolder = getBeamsFolder()
	beamsFolder:ClearAllChildren()
	spawnedBeams = {}  -- Clear beam references
	
	local beamHeight = HazardConfig.BeamHeightStuds
	local beamWidth = HazardConfig.BeamWidthStuds
	
	for i, zone in ipairs(currentUnsafeZones) do
		local beam = Instance.new("Part")
		beam.Name = string.format("Beam_r%d_c%d", zone.row, zone.col)
		beam.Anchored = true
		beam.CanCollide = false
		beam.CastShadow = false
		
		-- Size: fixed width, very tall
		beam.Size = Vector3.new(beamWidth, beamHeight, beamWidth)
		
		-- Position: beam extends from platform surface upward
		local beamY = platformData.topY + beamHeight / 2
		beam.Position = Vector3.new(
			zone.worldCenter.X,
			beamY,
			zone.worldCenter.Z
		)
		
		-- Visual properties
		beam.Color = HazardConfig.BeamColor
		beam.Transparency = HazardConfig.BeamTransparency
		beam.Material = Enum.Material.Neon
		
		beam.Parent = beamsFolder
		table.insert(spawnedBeams, beam)  -- Track for hit detection
	end
	
	log(string.format("Spawned %d telegraph beams", #currentUnsafeZones))
end

--[[
	Clear all telegraph beams. Idempotent (safe to call multiple times).
]]
function HazardManager.ClearTelegraphs()
	local folder = Workspace:FindFirstChild(HazardConfig.EffectsFolderName)
	if not folder then 
		spawnedBeams = {}
		return 
	end
	
	local beamsFolder = folder:FindFirstChild("TelegraphBeams")
	if not beamsFolder then 
		spawnedBeams = {}
		return 
	end
	
	local childCount = #beamsFolder:GetChildren()
	if childCount == 0 then 
		spawnedBeams = {}
		return  -- Already clean
	end
	
	beamsFolder:ClearAllChildren()
	spawnedBeams = {}  -- Clear references
	log("Cleared telegraph beams")
end

--[[
	Check if a single point is inside a beam's kill zone.
	Uses tiny buffer to prevent flicker edge deaths.
]]
local function isPointInBeam(point: Vector3, beam: Part): boolean
	local buffer = HazardConfig.KillZoneInnerBuffer
	local beamPos = beam.Position
	local beamSize = beam.Size
	
	-- Kill zone matches visual beam with tiny edge buffer
	local killHalfX = (beamSize.X / 2) * (1 - buffer)
	local killHalfZ = (beamSize.Z / 2) * (1 - buffer)
	
	local dx = math.abs(point.X - beamPos.X)
	local dz = math.abs(point.Z - beamPos.Z)
	
	return dx <= killHalfX and dz <= killHalfZ
end

--[[
	Check if ANY body part of a character intersects ANY beam.
	Returns (beamName, bodyPartName) if hit, (nil, nil) otherwise.
]]
local function getBodyPartBeamHit(character: Model): (string?, string?)
	for _, beam in ipairs(spawnedBeams) do
		-- Check all BaseParts in the character
		for _, part in ipairs(character:GetDescendants()) do
			if not part:IsA("BasePart") then continue end
			
			-- Get the part's bounding box corners for thorough check
			local partPos = part.Position
			local partSize = part.Size
			
			-- Check center point
			if isPointInBeam(partPos, beam) then
				return beam.Name, part.Name
			end
			
			-- Check corners for larger body parts (arms, legs, torso)
			local halfX = partSize.X / 2
			local halfZ = partSize.Z / 2
			
			local corners = {
				Vector3.new(partPos.X + halfX, partPos.Y, partPos.Z + halfZ),
				Vector3.new(partPos.X + halfX, partPos.Y, partPos.Z - halfZ),
				Vector3.new(partPos.X - halfX, partPos.Y, partPos.Z + halfZ),
				Vector3.new(partPos.X - halfX, partPos.Y, partPos.Z - halfZ),
			}
			
			for _, corner in ipairs(corners) do
				if isPointInBeam(corner, beam) then
					return beam.Name, part.Name
				end
			end
		end
	end
	
	return nil, nil
end

--[[
	Fallback: check if HumanoidRootPart position is inside any beam.
]]
local function getHRPBeamHit(position: Vector3): string?
	for _, beam in ipairs(spawnedBeams) do
		if isPointInBeam(position, beam) then
			return beam.Name
		end
	end
	return nil
end

--[[
	Execute the strike: eliminate players with ANY body part in unsafe zones.
	Uses limb-accurate detection for fair hit testing.
	Eliminated players are immediately sent to Lobby (no Spectating).
	Returns number of eliminated players.
]]
function HazardManager.Strike(): number
	if not initialized then
		warn("[HazardManager] Not initialized")
		return 0
	end
	
	-- Log unsafe zones for this strike
	log(string.format("[STRIKE] Checking %d unsafe zones: %s", 
		#currentUnsafeZones,
		table.concat(
			(function()
				local names = {}
				for _, zone in ipairs(currentUnsafeZones) do
					table.insert(names, string.format("r%dc%d", zone.row, zone.col))
				end
				return names
			end)(),
			", "
		)
	))
	
	local eliminatedPlayers: { Player } = {}
	local inMatchPlayers = PlayerStateService.GetPlayersInState(PlayerState.States.InMatch)
	
	local useBodyParts = HazardConfig.UseBodyPartCheck and #spawnedBeams > 0
	
	-- Check each player for beam intersection
	for _, player in ipairs(inMatchPlayers) do
		local character = player.Character
		if not character then continue end
		
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then continue end
		
		local hitBeam: string? = nil
		local hitPart: string? = nil
		
		if useBodyParts then
			-- Limb-accurate: check ALL body parts
			hitBeam, hitPart = getBodyPartBeamHit(character)
		else
			-- Fallback: HRP-only check
			local rootPart = character:FindFirstChild("HumanoidRootPart")
			if rootPart then
				hitBeam = getHRPBeamHit(rootPart.Position)
				hitPart = "HumanoidRootPart"
			end
		end
		
		if hitBeam then
			humanoid.Health = 0
			table.insert(eliminatedPlayers, player)
			log(string.format("[HAZARD KILL] %s — Beam: %s, BodyPart: %s", 
				player.Name, hitBeam, hitPart or "unknown"))
		end
	end
	
	-- Send eliminated players to Lobby
	for _, player in ipairs(eliminatedPlayers) do
		PlayerStateService.SetState(player, PlayerState.States.Lobby)
	end
	
	local survived = #inMatchPlayers - #eliminatedPlayers
	log(string.format("Strike complete: %d eliminated, %d survived", #eliminatedPlayers, survived))
	
	return #eliminatedPlayers
end

--[[
	Get current unsafe zones (for debugging/UI).
]]
function HazardManager.GetUnsafeZones(): { GridCell }
	return currentUnsafeZones
end

--[[
	Full cleanup (call on match end or cancel). Idempotent.
]]
function HazardManager.Cleanup()
	local hadData = #currentUnsafeZones > 0
	
	HazardManager.ClearTelegraphs()
	currentUnsafeZones = {}
	selectedCellsLookup = {}
	
	-- Only log if there was something to clean
	if hadData then
		log("Full cleanup complete")
	end
end

return HazardManager
