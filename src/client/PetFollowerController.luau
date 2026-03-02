--[[
	PetFollowerController
	Client-side pet follower — spawns equipped pet models for ALL visible
	players, with smooth follow + bobble animation.

	Each client renders pets for every player (reads their EquippedPet
	attribute). This keeps movement smooth while remaining server-authoritative
	for what is equipped.

	Follow behavior:
	  - Position = HumanoidRootPart * scaled offset + vertical bobble
	  - Orientation = HRP yaw (so pet faces same direction as player)
	  - Per-pet YawOffset for models whose forward axis differs
	  - Lerp each frame for smooth motion

	Pet models:
	  - Cloned from ItemModelRegistry (same source as thumbnails)
	  - All parts Anchored, CanCollide/CanQuery/CanTouch = false
	  - VFX (ParticleEmitters etc.) kept enabled (they work in Workspace)
	  - Forced to a max bounding-box size at spawn (smaller than player)

	Handles:
	  - Equip / unequip / swap (only one pet per player)
	  - Character respawn (re-spawns pet after respawn)
	  - Player leaving (cleans up pet)

	API:
	  PetFollowerController.Init()
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared            = ReplicatedStorage:WaitForChild("Shared")
local UIConfig          = require(Shared:WaitForChild("UIConfig"))
local ItemCatalog       = require(Shared:WaitForChild("ItemCatalog"))
local ItemModelRegistry = require(Shared:WaitForChild("ItemModelRegistry"))
local PetVisualConfig   = require(Shared:WaitForChild("PetVisualConfig"))
local ItemModelsFolder  = ReplicatedStorage:WaitForChild("ItemModels")

-- Walker pet remotes — server owns all physics/animation for walkers.
local _remotes       = ReplicatedStorage:WaitForChild("Remotes")
local _equipRemote   = _remotes:WaitForChild("EquipWalkerPet")
local _unequipRemote = _remotes:WaitForChild("UnequipWalkerPet")

local TAG = "[PetFollower]"
local PET_INSTANCE_NAME = "_EquippedPet"

local PetFollowerController = {}

-- =====================================================================
-- FOLLOW TUNING
-- =====================================================================

local PET_OFFSET          = CFrame.new(3, 2.5, 2)   -- offset from HumanoidRootPart
local LERP_ALPHA          = 0.08                      -- interpolation speed per frame
local BOBBLE_SPEED        = 3.0                       -- vertical sine frequency
local BOBBLE_AMPLITUDE    = 0.4                       -- vertical sine amplitude (studs)
local YAW_WOBBLE_SPEED    = 1.5
local YAW_WOBBLE_AMP      = 5                         -- degrees
local ROLL_WOBBLE_SPEED   = 2.0
local ROLL_WOBBLE_AMP     = 3                         -- degrees

-- =====================================================================
-- PER-PET OVERRIDES
-- =====================================================================

-- Yaw correction (degrees) for models whose local "face" points the wrong way.
-- When a pet looks backwards while the player faces the camera, add 180 here.
-- When sideways, add 90 or -90, etc.  Default (absent) = 0.
-- Most Blender-exported models face +Z; Roblox forward is -Z → 180° flip.
local PET_YAW_OFFSET_DEG: { [string]: number } = {
	pet_dog              = 180,
	pet_crocodile        = 180,
	pet_rabbit           = 180,
	pet_eagle            = 180,
	pet_scorpion         = 180,
	pet_shark            = -90,  -- faces along X-axis, not Z
	pet_bat              = 180,
	pet_dolphin          = 180,
	pet_pink_butterfly   = -90,  -- faces along X-axis, not Z
	-- Steve rig forward axis requires inverse yaw to face forward in float mode.
	pet_steve            = -90,
	-- Chica float rig forward axis differs; lock with explicit yaw correction.
	pet_chica            = -90,
	-- NOTE: pet_the_puppet rotation handled via PetVisualConfig.OVERRIDES
}

-- Pets that should not receive roll wobble (keeps large/rigged models visually stable).
local PET_NO_ROLL_WOBBLE: { [string]: boolean } = {
	pet_chica            = true,
	pet_foxy             = true,
	pet_bonnie           = true,
	pet_freddy_fazbear   = true,
	pet_golden_freddy    = true,
	pet_the_puppet       = true,
	pet_cupcake          = true,
}

-- Scale override: bypasses auto-scaling for models that need special treatment.
-- Value is used as a raw multiplier on the model's original scale.
local PET_SCALE_OVERRIDES: { [string]: number } = {
	pet_glitched_dragon = 0.10,  -- model is enormous; tuned to match other pets (~3 studs)
}

local MOVEMENT_HOVER = "HOVER"
local MOVEMENT_WALKER = "WALKER_R15"

local PET_MOVEMENT_TYPE: { [string]: string } = {
	-- Reverted to floating/bobble path
	Bonnie = MOVEMENT_HOVER,
	Chica = MOVEMENT_HOVER,
	Foxy = MOVEMENT_HOVER,
	FreddyFazbear = MOVEMENT_HOVER,

	-- HOVERS (must remain existing bobble path)
	GoldenFreddy = MOVEMENT_HOVER,
	ThePuppet = MOVEMENT_HOVER,
	Cupcake = MOVEMENT_HOVER,
}

-- FNAF pets explicitly reverted to floating companions.
local FNAF_REVERTED_FLOAT_IDS: { [string]: boolean } = {
	pet_bonnie = true,
	pet_chica = true,
	pet_foxy = true,
}

-- Final follow-transform rotation fixes for hover-only path.
local PET_ROTATION_FIX: { [string]: CFrame } = {
	-- Chica tilt is lateral in float mode; correct on roll axis.
	pet_chica = CFrame.Angles(0, 0, math.rad(14)),
}

-- Explicit equip offsets for outlier models only.
-- Mirrors the existing "finalCF = uprightCF * perPetOffset" pattern.
local PET_EQUIP_OFFSET_CFRAME: { [string]: CFrame } = {
	-- Huggy also needs a small vertical settle to avoid appearing offset.
	pet_huggy_wuggy = CFrame.new(0, -0.35, 0) * CFrame.Angles(0, math.rad(180), 0),
}

-- =====================================================================
-- SIZE NORMALIZATION
-- =====================================================================

local TARGET_MAX_DIM = 3.0   -- max bounding-box dimension (studs); player is ~5
local SCALE_FLOOR    = 0.02  -- never scale below this (prevents invisible pets)
local SCALE_CEIL     = 1.0   -- never scale above original size

-- =====================================================================
-- STATE (per-player pet tracking)
-- =====================================================================

local _activePets: { [Player]: {
	pet: Instance?,
	conn: RBXScriptConnection?,
	pos: Vector3,
	t0: number,
	mover: any?,
	_isWalker: boolean?,
	_walkerPetId: string?,
} } = {}

local _playerConns: { [Player]: { RBXScriptConnection } } = {}

local DEBUG_LOGS = RunService:IsStudio() and UIConfig.DebugLogs == true
local LOG_RATE_SECONDS = tonumber(UIConfig.LogRateSeconds) or 20
local _lastLogByKey: { [string]: number } = {}
local _countByKey: { [string]: number } = {}

local function shouldLog(key: string, everySeconds: number?, everyN: number?): boolean
	if not DEBUG_LOGS then
		return false
	end
	local now = tick()
	local minInterval = everySeconds or LOG_RATE_SECONDS
	local last = _lastLogByKey[key] or 0
	if now - last >= minInterval then
		_lastLogByKey[key] = now
		_countByKey[key] = (_countByKey[key] or 0) + 1
		return true
	end
	if everyN and everyN > 0 then
		local count = (_countByKey[key] or 0) + 1
		_countByKey[key] = count
		if count % everyN == 0 then
			_lastLogByKey[key] = now
			return true
		end
	end
	return false
end

local function log(key: string, ...)
	if shouldLog(key) then
		print(TAG, ...)
	end
end

-- =====================================================================
-- HELPERS
-- =====================================================================

--- Get the bounding-box size of a model (or BasePart).
--- Returns nil on failure.
local function getBBoxSize(inst: Instance): Vector3?
	if inst:IsA("Model") then
		local ok, _, sz = pcall(inst.GetBoundingBox, inst)
		if ok and typeof(sz) == "Vector3" then return sz end
		-- Fallback to GetExtentsSize
		local ok2, ext = pcall(inst.GetExtentsSize, inst)
		if ok2 and typeof(ext) == "Vector3" then return ext end
		return nil
	elseif inst:IsA("BasePart") then
		return inst.Size
	end
	return nil
end

--- Apply uniform scale to a model or part.  Returns true on success.
--- For Models: prefers ScaleTo, falls back to manual descendant scaling.
--- For BaseParts: scales Size + SpecialMesh.Scale + Attachment positions.
local function applyScale(inst: Instance, factor: number): boolean
	if factor == 1 then return true end
	if inst:IsA("Model") then
		local ok = pcall(function()
			local cur = inst:GetScale()
			inst:ScaleTo(cur * factor)
		end)
		if ok then return true end
		-- Fallback: scale descendants manually
		for _, d in ipairs(inst:GetDescendants()) do
			if d:IsA("BasePart") then
				d.Size = d.Size * factor
			elseif d:IsA("DataModelMesh") then
				d.Scale = d.Scale * factor
				if d:FindFirstAncestorWhichIsA("BasePart") then
					d.Offset = d.Offset * factor
				end
			elseif d:IsA("Attachment") then
				d.Position = d.Position * factor
			end
		end
		return true
	elseif inst:IsA("BasePart") then
		inst.Size = inst.Size * factor
		-- Also scale child meshes (SpecialMesh etc.) and attachments
		for _, d in ipairs(inst:GetDescendants()) do
			if d:IsA("DataModelMesh") then
				d.Scale = d.Scale * factor
				d.Offset = d.Offset * factor
			elseif d:IsA("Attachment") then
				d.Position = d.Position * factor
			end
		end
		return true
	end
	return false
end

--- Extract yaw-only (Y-axis rotation) from a CFrame.
local function yawOnly(cf: CFrame): number
	local _, ry, _ = cf:ToEulerAnglesYXZ()
	return ry
end

-- =====================================================================
-- PET SPAWN / DESTROY
-- =====================================================================

local function getPetDef(petId: string)
	if not petId or petId == "" then return nil end
	return ItemCatalog.Pets and ItemCatalog.Pets[petId]
end

local function getConfiguredPetModelName(petId: string, petDef): string
	if petDef and typeof(petDef.modelName) == "string" and petDef.modelName ~= "" then
		return petDef.modelName
	end
	if petDef and typeof(petDef.name) == "string" and petDef.name ~= "" then
		return petDef.name
	end
	return petId
end

local function getMovementType(petId: string, petDef): string
	local modelName = getConfiguredPetModelName(petId, petDef)
	local explicit = PET_MOVEMENT_TYPE[modelName]
	if explicit then return explicit end
	if petDef and petDef.collection == "FNAF" then
		-- Explicit safety: unspecified FNAF defaults to hover, not walker.
		return MOVEMENT_HOVER
	end
	return MOVEMENT_HOVER
end

local function useWalkingFollower(petId: string, petDef): boolean
	return getMovementType(petId, petDef) == MOVEMENT_WALKER
end

local function shouldUseExactNameLookup(modelName: string): boolean
	-- Reverted FNAF float pets must resolve via explicit modelPath to avoid
	-- exact-name collisions with unrelated large world/NPC assets.
	if modelName == "Bonnie"
		or modelName == "Chica"
		or modelName == "Foxy"
		or modelName == "FreddyFazbear"
	then
		return false
	end
	return PET_MOVEMENT_TYPE[modelName] ~= nil
end

local function findHumanoidInModel(model: Model): Humanoid?
	local direct = model:FindFirstChildOfClass("Humanoid")
	if direct then
		return direct
	end
	local nested = model:FindFirstChild("Humanoid", true)
	if nested and nested:IsA("Humanoid") then
		return nested
	end
	return nil
end

local function findHrpInModel(model: Model): BasePart?
	local hrp = model:FindFirstChild("HumanoidRootPart", true)
	if hrp and hrp:IsA("BasePart") then
		return hrp
	end
	return nil
end

local function findWalkerRootPart(model: Model, humanoid: Humanoid?): (BasePart?, boolean)
	local hrp = findHrpInModel(model)
	if hrp then
		return hrp, true
	end
	if humanoid and humanoid.RootPart then
		return humanoid.RootPart, false
	end
	if model.PrimaryPart then
		return model.PrimaryPart, false
	end
	local anyPart = model:FindFirstChildWhichIsA("BasePart", true)
	if anyPart then
		return anyPart, false
	end
	return nil, false
end

local function ensureWalkerHumanoid(model: Model): Humanoid
	local hum = findHumanoidInModel(model)
	if hum then
		return hum
	end
	hum = Instance.new("Humanoid")
	hum.Name = "Humanoid"
	hum.Parent = model
	return hum
end

local function ensureWalkerHrp(model: Model, humanoid: Humanoid?): BasePart?
	local existing = findHrpInModel(model)
	if existing then
		return existing
	end

	local base = nil :: BasePart?
	if humanoid and humanoid.RootPart then
		base = humanoid.RootPart
	elseif model.PrimaryPart then
		base = model.PrimaryPart
	else
		base = model:FindFirstChildWhichIsA("BasePart", true)
	end
	if not base then
		return nil
	end

	local hrp = Instance.new("Part")
	hrp.Name = "HumanoidRootPart"
	hrp.Size = Vector3.new(2, 2, 1)
	hrp.Transparency = 1
	hrp.CanCollide = true
	hrp.CanQuery = false
	hrp.CanTouch = false
	hrp.Massless = false
	hrp.Anchored = false
	hrp.CFrame = base.CFrame
	hrp.Parent = model

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = hrp
	weld.Part1 = base
	weld.Parent = hrp

	model.PrimaryPart = hrp
	return hrp
end

local function destroyPetFor(player: Player)
	local entry = _activePets[player]
	if not entry then return end

	-- Walker pets live on the server; notify it to clean up.
	if entry._isWalker then
		pcall(function() _unequipRemote:FireServer() end)
		_activePets[player] = nil
		return
	end

	if entry.conn then entry.conn:Disconnect() end
	if entry.mover and entry.mover.Destroy then
		pcall(function() entry.mover:Destroy() end)
	end
	if entry.pet and entry.pet.Parent then entry.pet:Destroy() end
	_activePets[player] = nil
end

local function spawnPetFor(player: Player, petId: string)
	-- Already tracking this pet? Skip (handles both hover model and walker sentinel).
	local existing = _activePets[player]
	if existing then
		if existing._isWalker and existing._walkerPetId == petId then return end
		if not existing._isWalker and existing.pet and existing.pet.Parent
			and existing.pet:GetAttribute("_petId") == petId then return end
	end

	destroyPetFor(player)

	if not petId or petId == "" then return end

	local petDef = getPetDef(petId)
	if not petDef then
		warn(TAG, "Pet not in catalog:", petId)
		return
	end

	local movementType = getMovementType(petId, petDef)
	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		return
	end

	local modelName = getConfiguredPetModelName(petId, petDef)
	local sourceModel: Instance? = nil
	if shouldUseExactNameLookup(modelName) then
		sourceModel = ItemModelRegistry.GetByExactName(modelName)
	else
		if petDef.modelPath and petDef.modelPath ~= "" then
			sourceModel = ItemModelRegistry.Get(petDef.modelPath)
		end
		if not sourceModel and modelName ~= "" then
			sourceModel = ItemModelRegistry.Get(modelName)
		end
	end
	if DEBUG_LOGS and shouldLog("pet_spawn_lookup_" .. petId, 20) then
		local registryPath = sourceModel and sourceModel:GetFullName() or ItemModelsFolder:GetFullName()
		print(string.format("[PetSpawn] petName=%s modelFound=%s registry=%s", modelName, tostring(sourceModel ~= nil), registryPath))
	end
	if not sourceModel then
		warn(TAG, "Model not found for pet:", petId, "| modelName:", modelName, "| modelPath:", tostring(petDef.modelPath))
		return
	end

	log("spawn_begin", "Spawning pet for", player.Name .. ":", petId, "modelName:", modelName)
	local movementType = getMovementType(petId, petDef)

	-- ── WALKER PETS ────────────────────────────────────────────────────────────
	if movementType == MOVEMENT_WALKER then
		-- Non-Freddy walker fallback (currently unused): server-owned path.
		if DEBUG_LOGS and shouldLog("walker_pet_client_equip_" .. petId, 20) then
			print(string.format("[WalkerPetCL] equip petId=%s modelName=%s → firing server", petId, modelName))
		end
		_equipRemote:FireServer(petId)
		_activePets[player] = {
			pet          = nil,
			conn         = nil,
			pos          = rootPart.Position,
			t0           = tick(),
			mover        = nil,
			_isWalker    = true,
			_walkerPetId = petId,
		}
		return
	end

	local clone = sourceModel:Clone()

	-- Unwrap Accessory → extract children into a Model wrapper
	if clone:IsA("Accessory") then
		local wrapper = Instance.new("Model")
		wrapper.Name = clone.Name
		local handle = clone:FindFirstChild("Handle")
		for _, child in ipairs(clone:GetChildren()) do
			child.Parent = wrapper
		end
		if handle and handle:IsA("BasePart") then
			wrapper.PrimaryPart = handle
		else
			local firstPart = wrapper:FindFirstChildWhichIsA("BasePart", true)
			if firstPart then wrapper.PrimaryPart = firstPart end
		end
		clone:Destroy()
		clone = wrapper
	end

	-- Wrap bare BaseParts into a Model so ScaleTo / PivotTo work uniformly.
	if clone:IsA("BasePart") and not clone:IsA("Model") then
		local wrapper = Instance.new("Model")
		wrapper.Name = clone.Name
		clone.Parent = wrapper
		wrapper.PrimaryPart = clone
		clone = wrapper
	end

	-- Ensure consistent pivot behavior for per-pet offsets.
	if clone:IsA("Model") and not clone.PrimaryPart then
		local preferredRoot = clone:FindFirstChild("HumanoidRootPart", true)
		if preferredRoot and preferredRoot:IsA("BasePart") then
			clone.PrimaryPart = preferredRoot
		else
			local firstPart = clone:FindFirstChildWhichIsA("BasePart", true)
			if firstPart then
				clone.PrimaryPart = firstPart
			end
		end
	end

	local useUnanchoredFloat = FNAF_REVERTED_FLOAT_IDS[petId] == true

	-- Hover pets: default anchored; reverted FNAF floats are unanchored.
	local function prepPart(part: BasePart)
		part.Anchored   = not useUnanchoredFloat
		part.CanCollide = false
		part.CanQuery   = false
		part.CanTouch   = false
		part.Massless   = true
	end

	if clone:IsA("BasePart") then prepPart(clone) end
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("BasePart") then prepPart(d) end
	end

	-- Enable VFX; destroy embedded scripts (hover pets need no scripting).
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("ParticleEmitter") or d:IsA("Fire") or d:IsA("Sparkles")
			or d:IsA("Smoke") or d:IsA("Beam") or d:IsA("Trail") then
			d.Enabled = true
		elseif d:IsA("Script") or d:IsA("LocalScript") then
			d:Destroy()
		end
	end

	-- ── SIZE NORMALIZATION ─────────────────────────────────────────
	-- Goal: every pet ends up with max bounding-box dim <= TARGET_MAX_DIM.
	local preBBox = getBBoxSize(clone)
	local petScale = 1

	do
		local scaleOverride = PET_SCALE_OVERRIDES[petId]

		if scaleOverride then
			-- Use the explicit override
			petScale = scaleOverride
		elseif preBBox then
			local maxDim = math.max(preBBox.X, preBBox.Y, preBBox.Z, 0.01)
			if maxDim > TARGET_MAX_DIM then
				petScale = TARGET_MAX_DIM / maxDim
			end
		end

		petScale = math.clamp(petScale, SCALE_FLOOR, SCALE_CEIL)

		-- Apply the primary scale
		if petScale < 1 then
			applyScale(clone, petScale)
		end

		-- POST-SCALE VERIFICATION: re-measure and correct if still too big
		local postBBox = getBBoxSize(clone)
		if postBBox then
			local postMax = math.max(postBBox.X, postBBox.Y, postBBox.Z)
			if postMax > TARGET_MAX_DIM then
				local correction = (TARGET_MAX_DIM / postMax) * 0.95 -- 5% safety margin
				correction = math.max(correction, SCALE_FLOOR)
				applyScale(clone, correction)
				petScale = petScale * correction
				log("post_scale", "Post-scale correction for", petId,
					string.format("extra %.3fx (was %.1f studs)", correction, postMax))
			end
		end
	end

	log("scaled_pet", "Scaled pet", petId, string.format("%.3fx", petScale),
		preBBox and string.format("(pre-bbox: %.1f x %.1f x %.1f)", preBBox.X, preBBox.Y, preBBox.Z) or "(no bbox)")

	local visual = PetVisualConfig.Get(petId, petDef)

	-- Apply visual scale ONCE per spawn (never in follow loop).
	if visual.scale ~= 1 then
		applyScale(clone, visual.scale)
		petScale = petScale * visual.scale
	end

	if RunService:IsStudio() and visual.debugTag and shouldLog("pet_visual_fix_" .. petId, 20) then
		print(string.format(
			"[PetVisualFix] pet=%s appliedRot=<%.1f,%.1f,%.1f>",
			petId,
			visual.rotDeg.X,
			visual.rotDeg.Y,
			visual.rotDeg.Z
		))
	end

	-- ── FOLLOW OFFSET (scaled to pet size) ─────────────────────────
	local offsetMul = 0.4 + 0.6 * petScale
	local petOffset = CFrame.new(
		PET_OFFSET.X * offsetMul,
		PET_OFFSET.Y * offsetMul,
		PET_OFFSET.Z * offsetMul
	)
	local petBobbleAmp = BOBBLE_AMPLITUDE * math.max(petScale, 0.4)

	-- Per-pet yaw offset in radians (from table + PetVisualConfig rotation).
	-- PetVisualConfig.rotation is a pure-yaw CFrame for backwards-facing models.
	local petYawRad = math.rad(PET_YAW_OFFSET_DEG[petId] or 0)
	do
		-- Extract additional yaw from visual.rotation (ignore any pitch/roll).
		local _, vy, _ = visual.rotation:ToEulerAnglesYXZ()
		petYawRad = petYawRad + vy
	end

	if RunService:IsStudio() and shouldLog("pet_upright_" .. petId, 20) then
		print(string.format("[PetUpright] petId=%s yawOffsetDeg=%.0f",
			petId, math.deg(petYawRad)))
	end

	-- ── INITIAL POSITION ───────────────────────────────────────────
	local startPos = (rootPart.CFrame * petOffset).Position
	local look0 = rootPart.CFrame.LookVector
	local yaw0  = math.atan2(-look0.X, -look0.Z) + petYawRad
	local startCF = CFrame.new(startPos) * CFrame.Angles(0, yaw0, 0)

	if clone:IsA("Model") then
		clone:PivotTo(startCF)
	elseif clone:IsA("BasePart") then
		clone.CFrame = startCF
	end

	clone.Name = PET_INSTANCE_NAME
	clone:SetAttribute("IsPet", true)
	clone:SetAttribute("_petId", petId)
	clone:SetAttribute("_owner", player.Name)
	clone.Parent = workspace

	-- ── FOLLOW + BOBBLE LOOP ───────────────────────────────────────
	-- Position is lerped for smooth motion; orientation is rebuilt fresh
	-- every frame from the player's LookVector so pitch/roll are ALWAYS 0.
	local currentPos = startPos
	local t0 = tick()

	local followConn = RunService.Heartbeat:Connect(function()
		if not clone or not clone.Parent then
			destroyPetFor(player)
			return
		end
		local char = player.Character
		if not char then return end
		local hrp = char:FindFirstChild("HumanoidRootPart")
		if not hrp then return end

		local t = tick() - t0

		-- 1) Target position: offset from HRP + vertical bobble (position only, no rotation)
		local rawTarget = (hrp.CFrame * petOffset).Position
		local bobbleY   = math.sin(t * BOBBLE_SPEED) * petBobbleAmp
		local targetPos = Vector3.new(rawTarget.X, rawTarget.Y + bobbleY, rawTarget.Z)

		-- 2) Lerp position only (no lerp on rotation — orientation is always fresh)
		currentPos = currentPos:Lerp(targetPos, LERP_ALPHA)

		-- 3) Compute yaw from player LookVector — guaranteed pitch=0, roll=0
		local lookVec = hrp.CFrame.LookVector
		local yaw = math.atan2(-lookVec.X, -lookVec.Z) + petYawRad
		-- Small yaw wobble (wobble is yaw-only, no tilt introduced)
		yaw = yaw + math.sin(t * YAW_WOBBLE_SPEED) * math.rad(YAW_WOBBLE_AMP)

		-- 4) Upright CFrame: ONLY yaw rotation, pitch=0, roll=0 always
		local uprightCF = CFrame.new(currentPos) * CFrame.Angles(0, yaw, 0)
		local finalCF = uprightCF
			* (PET_EQUIP_OFFSET_CFRAME[petId] or CFrame.new())
			* (PET_ROTATION_FIX[petId] or CFrame.new())

		-- 5) Apply
		if clone:IsA("Model") then
			clone:PivotTo(finalCF)
		elseif clone:IsA("BasePart") then
			clone.CFrame = finalCF
		end
	end)

	_activePets[player] = {
		pet = clone,
		conn = followConn,
		pos = currentPos,
		t0 = t0,
		mover = nil,
	}

	log("spawn_done", "Pet spawned for", player.Name .. ":", petId)
end

-- =====================================================================
-- PER-PLAYER LIFECYCLE
-- =====================================================================

local function updatePetFor(player: Player)
	local petId = player:GetAttribute("EquippedPet")
	if petId and petId ~= "" then
		spawnPetFor(player, petId)
	else
		destroyPetFor(player)
	end
end

local function setupPlayer(player: Player)
	local conns: { RBXScriptConnection } = {}

	table.insert(conns, player:GetAttributeChangedSignal("EquippedPet"):Connect(function()
		updatePetFor(player)
	end))

	table.insert(conns, player.CharacterAdded:Connect(function(character)
		character:WaitForChild("HumanoidRootPart", 10)
		task.wait(0.5)
		updatePetFor(player)
	end))

	table.insert(conns, player.CharacterRemoving:Connect(function()
		destroyPetFor(player)
	end))

	_playerConns[player] = conns

	if player.Character and player.Character:FindFirstChild("HumanoidRootPart") then
		task.spawn(function()
			task.wait(0.3)
			updatePetFor(player)
		end)
	end
end

local function cleanupPlayer(player: Player)
	destroyPetFor(player)
	if _playerConns[player] then
		for _, conn in ipairs(_playerConns[player]) do
			conn:Disconnect()
		end
		_playerConns[player] = nil
	end
end

-- =====================================================================
-- PUBLIC API
-- =====================================================================

function PetFollowerController.Init()
	log("init", "Initializing...")

	Players.PlayerAdded:Connect(setupPlayer)
	Players.PlayerRemoving:Connect(cleanupPlayer)

	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(setupPlayer, player)
	end

	log("ready", "Ready — tracking pets for all players")
end

return PetFollowerController