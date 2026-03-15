--[[
	BrainrotModeService
	Server-side manager for "Save the Brainrot" match mode.

	Handles:
	  * Building a unique-per-match brainrot pool
	  * Spawning 2 brainrots per round inside the arena
	  * ProximityPrompt-based pickup (server-authoritative)
	  * Reward granting (new pet + 100 coins, duplicate → 200 coins)
	  * Per-round and per-match cleanup

	API:
		Init()
		OnMatchStart()          → called when Brainrot mode match begins
		OnRoundStart(round)     → spawn 2 brainrots for this round
		OnRoundEnd()            → despawn remaining pickups
		OnMatchEnd()            → full cleanup + pool reset
		IsActive()              → boolean
]]

local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace          = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Server = ServerScriptService:WaitForChild("Server")

local ItemCatalog       = require(Shared:WaitForChild("ItemCatalog"))
local EconomyService    = require(Server:WaitForChild("EconomyService"))
local InventoryService  = require(Server:WaitForChild("InventoryService"))
local MapManager        = require(Server:WaitForChild("MapManager"))

local BRAINROT_FOLDER_NAME = "BrainrotPickups"
local PICKUP_PROMPT_DISTANCE = 8
local EDGE_MARGIN = 8
local RAYCAST_HEIGHT = 80
local SPAWN_BOTTOM_BUFFER = 0.5

local COINS_NEW_PET = 50
local COINS_DUPLICATE = 90

local BrainrotModeService = {}

local initialized = false
local active = false
local availablePool: { string } = {}
local spawnedThisMatch: { string } = {}
local pickupsFolder: Folder? = nil
local collectRemote: RemoteEvent? = nil
local promptConnections: { RBXScriptConnection } = {}
local _DailyQuestService = nil

local function log(...)
	print("[BrainrotMode]", ...)
end

local function getDailyQuestService()
	if _DailyQuestService then return _DailyQuestService end
	local ok, mod = pcall(require, Server:FindFirstChild("DailyQuestService"))
	if ok and mod then
		_DailyQuestService = mod
	end
	return _DailyQuestService
end

local function getBrainrotPetIds(): { string }
	local ids = {}
	for id, pet in pairs(ItemCatalog.Pets) do
		if pet.source == "brainrot_mode" then
			table.insert(ids, id)
		end
	end
	return ids
end

local function shuffleArray(arr: { any })
	for i = #arr, 2, -1 do
		local j = math.random(1, i)
		arr[i], arr[j] = arr[j], arr[i]
	end
end

local function getPickupsFolder(): Folder
	if pickupsFolder and pickupsFolder.Parent then
		return pickupsFolder
	end
	local existing = Workspace:FindFirstChild(BRAINROT_FOLDER_NAME)
	if existing then
		pickupsFolder = existing
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = BRAINROT_FOLDER_NAME
	folder.Parent = Workspace
	pickupsFolder = folder
	return folder
end

local function clearPickupsFolder()
	local folder = Workspace:FindFirstChild(BRAINROT_FOLDER_NAME)
	if folder then
		for _, child in ipairs(folder:GetChildren()) do
			child:Destroy()
		end
	end
end

local function disconnectPrompts()
	for _, conn in ipairs(promptConnections) do
		if conn.Connected then
			conn:Disconnect()
		end
	end
	promptConnections = {}
end

local function getRandomArenaPosition(): Vector3?
	local bounds = MapManager.GetActiveBounds()
	if not bounds then
		warn("[BrainrotMode] No active bounds available")
		return nil
	end

	local centerX = bounds.cframe.Position.X
	local centerZ = bounds.cframe.Position.Z
	local topY = bounds.topY

	local halfX = (bounds.sizeX / 2) - EDGE_MARGIN
	local halfZ = (bounds.sizeZ / 2) - EDGE_MARGIN

	if halfX <= 0 or halfZ <= 0 then
		halfX = math.max(halfX, 2)
		halfZ = math.max(halfZ, 2)
	end

	local x = centerX + (math.random() * 2 - 1) * halfX
	local z = centerZ + (math.random() * 2 - 1) * halfZ

	-- Raycast down from well above the arena to find the floor
	local rayOrigin = Vector3.new(x, topY + RAYCAST_HEIGHT, z)
	local rayDir = Vector3.new(0, -(RAYCAST_HEIGHT * 2), 0)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local pickupsFolder_ = Workspace:FindFirstChild(BRAINROT_FOLDER_NAME)
	if pickupsFolder_ then
		params.FilterDescendantsInstances = { pickupsFolder_ }
	end

	local result = Workspace:Raycast(rayOrigin, rayDir, params)
	local y
	if result then
		y = result.Position.Y
	else
		y = topY
	end

	return Vector3.new(x, y, z)
end

local function alignSpawnedBrainrotToGround(inst: Instance, groundPos: Vector3, contextName: string)
	local desiredBottomY = groundPos.Y + SPAWN_BOTTOM_BUFFER

	if inst:IsA("Model") then
		local bboxCF, bboxSize = inst:GetBoundingBox()
		local currentBottomY = bboxCF.Position.Y - (bboxSize.Y / 2)
		local deltaY = desiredBottomY - currentBottomY
		if math.abs(deltaY) > 0.001 then
			inst:PivotTo(inst:GetPivot() + Vector3.new(0, deltaY, 0))
		end
		log(string.format(
			"[SpawnAlign] type=Model context=%s groundY=%.2f desiredBottomY=%.2f currentBottomY=%.2f deltaY=%.2f bboxY=%.2f",
			contextName,
			groundPos.Y,
			desiredBottomY,
			currentBottomY,
			deltaY,
			bboxSize.Y
		))
		return
	end

	if inst:IsA("BasePart") then
		local currentBottomY = inst.Position.Y - (inst.Size.Y / 2)
		local deltaY = desiredBottomY - currentBottomY
		if math.abs(deltaY) > 0.001 then
			inst.Position = inst.Position + Vector3.new(0, deltaY, 0)
		end
		log(string.format(
			"[SpawnAlign] type=BasePart context=%s groundY=%.2f desiredBottomY=%.2f currentBottomY=%.2f deltaY=%.2f partY=%.2f",
			contextName,
			groundPos.Y,
			desiredBottomY,
			currentBottomY,
			deltaY,
			inst.Size.Y
		))
	end
end

local function spawnBrainrot(petId: string)
	local petDef = ItemCatalog.Pets[petId]
	if not petDef then
		warn("[BrainrotMode] Pet not in catalog:", petId)
		return nil
	end

	local modelPath = petDef.modelPath
	if not modelPath then
		warn("[BrainrotMode] No modelPath for:", petId)
		return nil
	end

	local modelTemplate = nil
	local parts = string.split(modelPath, ".")
	local current: Instance = ReplicatedStorage
	for _, part in ipairs(parts) do
		current = current:FindFirstChild(part)
		if not current then
			warn("[BrainrotMode] Model not found at path:", modelPath)
			return nil
		end
	end
	modelTemplate = current

	local spawnPos = getRandomArenaPosition()
	if not spawnPos then return nil end

	local clone = modelTemplate:Clone()
	clone.Name = "Brainrot_" .. petId
	clone:SetAttribute("BrainrotPetId", petId)
	clone:SetAttribute("BrainrotPetName", petDef.name)

	if clone:IsA("Model") then
		if clone.PrimaryPart then
			local yRot = math.random() * math.pi * 2
			clone:PivotTo(CFrame.new(spawnPos) * CFrame.fromAxisAngle(Vector3.new(0, 1, 0), yRot))
		else
			local firstPart = clone:FindFirstChildWhichIsA("BasePart", true)
			if firstPart then
				local offset = spawnPos - firstPart.Position
				for _, desc in ipairs(clone:GetDescendants()) do
					if desc:IsA("BasePart") then
						desc.Position = desc.Position + offset
						desc.Anchored = true
						desc.CanCollide = false
					end
				end
			end
		end
	elseif clone:IsA("BasePart") then
		clone.Position = spawnPos
		clone.Anchored = true
		clone.CanCollide = false
	end

	for _, desc in ipairs(clone:GetDescendants()) do
		if desc:IsA("BasePart") then
			desc.Anchored = true
			desc.CanCollide = false
		end
	end

	-- Parent first so bounding box is valid, then align bottom to ground safely.
	clone.Parent = getPickupsFolder()
	alignSpawnedBrainrotToGround(clone, spawnPos, petId)

	local promptPart = nil
	if clone:IsA("Model") then
		promptPart = clone.PrimaryPart or clone:FindFirstChildWhichIsA("BasePart", true)
	elseif clone:IsA("BasePart") then
		promptPart = clone
	end

	if promptPart then
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "BrainrotPickupPrompt"
		prompt.ActionText = "Collect"
		prompt.ObjectText = petDef.name
		prompt.KeyboardKeyCode = Enum.KeyCode.E
		prompt.HoldDuration = 0
		prompt.MaxActivationDistance = PICKUP_PROMPT_DISTANCE
		prompt.RequiresLineOfSight = false
		prompt.Parent = promptPart

		local conn = prompt.Triggered:Connect(function(player)
			if not active then return end
			if not clone or not clone.Parent then return end

			local matchStatus = ReplicatedStorage:FindFirstChild("MatchStatus")
			local modeVal = matchStatus and matchStatus:FindFirstChild("Mode")
			if not modeVal or modeVal.Value ~= "Brainrot" then return end

			clone:Destroy()

			local alreadyOwned = InventoryService.OwnsItem(player, "Pets", petId)
			local coinsAwarded = 0

			if alreadyOwned then
				local _, finalAmount = EconomyService.AwardCoins(player, COINS_DUPLICATE, "BrainrotDuplicate:" .. petId)
				coinsAwarded = finalAmount or COINS_DUPLICATE
				log(string.format("%s collected DUPLICATE %s → +%d coins", player.Name, petDef.name, COINS_DUPLICATE))
			else
				InventoryService.GrantItem(player, "Pets", petId)
				local _, finalAmount = EconomyService.AwardCoins(player, COINS_NEW_PET, "BrainrotNew:" .. petId)
				coinsAwarded = finalAmount or COINS_NEW_PET
				log(string.format("%s collected NEW %s → pet + %d coins", player.Name, petDef.name, COINS_NEW_PET))
			end

			local dqs = getDailyQuestService()
			if dqs and dqs.OnBrainrotPetPickup then
				log(string.format("[QuestBridge] firing Brainrot pickup quest hook player=%s petId=%s mode=Brainrot",
					player.Name, petId))
				pcall(dqs.OnBrainrotPetPickup, player, petId, "Brainrot")
			end

			if collectRemote then
				local imageAssetId = petDef.image
				if not imageAssetId or imageAssetId == "" then
					imageAssetId = ""
				end
				collectRemote:FireClient(player, {
					petId = petId,
					petName = petDef.name,
					isNew = not alreadyOwned,
					alreadyOwned = alreadyOwned,
					coins = coinsAwarded,
					rarity = petDef.rarity,
					imageAssetId = imageAssetId,
					modelPath = petDef.modelPath or "",
				})
			end
		end)
		table.insert(promptConnections, conn)
	end

	-- Add subtle glow Highlight for visibility
	local highlight = Instance.new("Highlight")
	highlight.Name = "BrainrotGlow"
	highlight.Adornee = clone
	highlight.FillColor = Color3.fromRGB(178, 48, 255)
	highlight.FillTransparency = 0.75
	highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
	highlight.OutlineTransparency = 0.3
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Parent = clone

	log(string.format("Spawned %s at ground=(%.0f, %.0f, %.0f)", petDef.name, spawnPos.X, spawnPos.Y, spawnPos.Z))
	return clone
end

function BrainrotModeService.Init()
	if initialized then return end
	initialized = true

	local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotesFolder then
		remotesFolder = Instance.new("Folder")
		remotesFolder.Name = "Remotes"
		remotesFolder.Parent = ReplicatedStorage
	end

	local existing = remotesFolder:FindFirstChild("BrainrotCollected")
	if not existing then
		collectRemote = Instance.new("RemoteEvent")
		collectRemote.Name = "BrainrotCollected"
		collectRemote.Parent = remotesFolder
	else
		collectRemote = existing
	end

	log("Initialized")
end

function BrainrotModeService.OnMatchStart()
	active = true
	spawnedThisMatch = {}

	local allIds = getBrainrotPetIds()
	shuffleArray(allIds)
	availablePool = allIds

	log(string.format("Brainrot match started — pool has %d unique pets", #availablePool))
end

function BrainrotModeService.OnRoundStart(roundNumber: number)
	if not active then return end

	clearPickupsFolder()
	disconnectPrompts()

	if #availablePool < 2 then
		if #availablePool == 1 then
			local id = table.remove(availablePool)
			table.insert(spawnedThisMatch, id)
			spawnBrainrot(id)
			log(string.format("Round %d: Only 1 brainrot left in pool — spawned 1", roundNumber))
		else
			log(string.format("Round %d: Pool exhausted — no brainrots to spawn", roundNumber))
		end
		return
	end

	for _ = 1, 2 do
		local id = table.remove(availablePool)
		if id then
			table.insert(spawnedThisMatch, id)
			spawnBrainrot(id)
		end
	end

	log(string.format("Round %d: Spawned 2 brainrots (%d remaining in pool)", roundNumber, #availablePool))
end

function BrainrotModeService.OnRoundEnd()
	if not active then return end
	clearPickupsFolder()
	disconnectPrompts()
	log("Round cleanup complete")
end

function BrainrotModeService.OnMatchEnd()
	active = false
	clearPickupsFolder()
	disconnectPrompts()
	availablePool = {}
	spawnedThisMatch = {}
	log("Match cleanup complete — pool reset")
end

function BrainrotModeService.IsActive(): boolean
	return active
end

return BrainrotModeService
