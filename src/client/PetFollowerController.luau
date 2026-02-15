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
local ItemCatalog       = require(Shared:WaitForChild("ItemCatalog"))
local ItemModelRegistry = require(Shared:WaitForChild("ItemModelRegistry"))

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
}

-- Scale override: bypasses auto-scaling for models that need special treatment.
-- Value is used as a raw multiplier on the model's original scale.
local PET_SCALE_OVERRIDES: { [string]: number } = {
	pet_glitched_dragon = 0.10,  -- model is enormous; tuned to match other pets (~3 studs)
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
	pet: Instance,
	conn: RBXScriptConnection?,
	cf: CFrame,
	t0: number,
} } = {}

local _playerConns: { [Player]: { RBXScriptConnection } } = {}

local function log(...)
	print(TAG, ...)
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

local function destroyPetFor(player: Player)
	local entry = _activePets[player]
	if not entry then return end
	if entry.conn then entry.conn:Disconnect() end
	if entry.pet and entry.pet.Parent then entry.pet:Destroy() end
	_activePets[player] = nil
end

local function spawnPetFor(player: Player, petId: string)
	-- Already showing this pet? Skip.
	local existing = _activePets[player]
	if existing and existing.pet and existing.pet.Parent then
		if existing.pet:GetAttribute("_petId") == petId then return end
	end

	destroyPetFor(player)

	if not petId or petId == "" then return end

	local petDef = getPetDef(petId)
	if not petDef then
		warn(TAG, "Pet not in catalog:", petId)
		return
	end

	local modelPath = petDef.modelPath
	if not modelPath or modelPath == "" then
		warn(TAG, "No modelPath for pet:", petId,
			"| catalogEntry:", petDef.name or "?", "rarity:", petDef.rarity or "?",
			"| image:", petDef.image or "nil", "| modelName:", petDef.modelName or "nil")
		return
	end

	local sourceModel = ItemModelRegistry.Get(modelPath)
	if not sourceModel then
		warn(TAG, "modelPath exists but model NOT FOUND in registry:", modelPath,
			"| petId:", petId, "| Try checking ReplicatedStorage.ItemModels hierarchy")
		return
	end

	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return end

	log("Spawning pet for", player.Name .. ":", petId, "path:", modelPath)

	local clone = sourceModel:Clone()

	-- Unwrap Accessory → extract children into a Model wrapper
	-- (Accessories have a Handle BasePart that we want to use as PrimaryPart)
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

	-- Wrap bare BaseParts (e.g. Glitched Dragon is a Part, not a Model) into a
	-- Model so ScaleTo / GetBoundingBox / PivotTo all work uniformly.
	if clone:IsA("BasePart") and not clone:IsA("Model") then
		local wrapper = Instance.new("Model")
		wrapper.Name = clone.Name
		clone.Parent = wrapper
		wrapper.PrimaryPart = clone
		clone = wrapper
	end

	-- Make all parts non-interactive and anchored (we position via CFrame)
	local function prepPart(part: BasePart)
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true
	end

	if clone:IsA("BasePart") then prepPart(clone) end
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("BasePart") then prepPart(d) end
	end

	-- Enable VFX (they work in Workspace, unlike ViewportFrame)
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
				log("Post-scale correction for", petId,
					string.format("extra %.3fx (was %.1f studs)", correction, postMax))
			end
		end
	end

	log("Scaled pet", petId, string.format("%.3fx", petScale),
		preBBox and string.format("(pre-bbox: %.1f x %.1f x %.1f)", preBBox.X, preBBox.Y, preBBox.Z) or "(no bbox)")

	-- ── FOLLOW OFFSET (scaled to pet size) ─────────────────────────
	local offsetMul = 0.4 + 0.6 * petScale
	local petOffset = CFrame.new(
		PET_OFFSET.X * offsetMul,
		PET_OFFSET.Y * offsetMul,
		PET_OFFSET.Z * offsetMul
	)
	local petBobbleAmp = BOBBLE_AMPLITUDE * math.max(petScale, 0.4)

	-- Per-pet yaw correction (radians)
	local petYawRad = math.rad(PET_YAW_OFFSET_DEG[petId] or 0)

	-- ── INITIAL POSITION ───────────────────────────────────────────
	local hrpYaw = yawOnly(rootPart.CFrame)
	local startPos = (rootPart.CFrame * petOffset).Position
	local startCF = CFrame.new(startPos) * CFrame.Angles(0, hrpYaw + petYawRad, 0)

	if clone:IsA("Model") then
		clone:PivotTo(startCF)
	elseif clone:IsA("BasePart") then
		clone.CFrame = startCF
	end

	clone.Name = PET_INSTANCE_NAME
	clone:SetAttribute("_petId", petId)
	clone:SetAttribute("_owner", player.Name)
	clone.Parent = workspace

	-- ── FOLLOW + BOBBLE LOOP ───────────────────────────────────────
	local currentCF = startCF
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

		-- 1) Position: offset from player + vertical bobble
		local targetPos = (hrp.CFrame * petOffset).Position
		local bobbleY = math.sin(t * BOBBLE_SPEED) * petBobbleAmp
		targetPos = targetPos + Vector3.new(0, bobbleY, 0)

		-- 2) Orientation: match player HRP yaw (so pet faces same way as player)
		local playerYaw = yawOnly(hrp.CFrame)

		-- 3) Per-pet yaw correction + subtle wobble
		local yawW = math.sin(t * YAW_WOBBLE_SPEED) * math.rad(YAW_WOBBLE_AMP)
		local rollW = math.sin(t * ROLL_WOBBLE_SPEED) * math.rad(ROLL_WOBBLE_AMP)
		local finalYaw = playerYaw + petYawRad + yawW

		-- 4) Build CFrame: position + yaw-only rotation + wobble roll
		local targetCF = CFrame.new(targetPos) * CFrame.Angles(0, finalYaw, rollW)

		-- 5) Smooth interpolation
		currentCF = currentCF:Lerp(targetCF, LERP_ALPHA)

		-- 6) Apply
		if clone:IsA("Model") then
			clone:PivotTo(currentCF)
		elseif clone:IsA("BasePart") then
			clone.CFrame = currentCF
		end
	end)

	_activePets[player] = {
		pet = clone,
		conn = followConn,
		cf = currentCF,
		t0 = t0,
	}

	log("Pet spawned for", player.Name .. ":", petId)
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
	log("Initializing...")

	Players.PlayerAdded:Connect(setupPlayer)
	Players.PlayerRemoving:Connect(cleanupPlayer)

	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(setupPlayer, player)
	end

	log("Ready — tracking pets for all players")
end

return PetFollowerController
