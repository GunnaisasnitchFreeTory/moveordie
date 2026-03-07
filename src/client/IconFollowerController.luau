--[[
	IconFollowerController
	Client-side Icon Image follower -- spawns equipped icon image models
	for ALL visible players, with smooth follow + bobble animation.

	Mirrors PetFollowerController but uses the OPPOSITE side offset
	so pet and icon image can coexist without overlapping.

	Pet uses +X (right side), Icon Image uses -X (left side).

	Reads: player:GetAttribute("EquippedIconImage")
	Catalog: ItemCatalog.IconImages[iconId]
	Registry: ItemModelRegistry.Get(modelPath)

	API:
	  IconFollowerController.Init()
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared            = ReplicatedStorage:WaitForChild("Shared")
local ItemCatalog       = require(Shared:WaitForChild("ItemCatalog"))
local ItemModelRegistry = require(Shared:WaitForChild("ItemModelRegistry"))

local TAG = "[IconFollower]"
local ICON_INSTANCE_NAME = "_EquippedIconImage"

local IconFollowerController = {}

-- =====================================================================
-- FOLLOW TUNING  (mirrors pet but on opposite X side)
-- =====================================================================

local ICON_OFFSET         = CFrame.new(-3, 2.5, 2)  -- left side (pet is +3)
local LERP_ALPHA          = 0.08
local BOBBLE_SPEED        = 3.0
local BOBBLE_AMPLITUDE    = 0.4
local YAW_WOBBLE_SPEED    = 1.5
local YAW_WOBBLE_AMP      = 5
local ROLL_WOBBLE_SPEED   = 2.0
local ROLL_WOBBLE_AMP     = 3

-- =====================================================================
-- SIZE NORMALIZATION
-- =====================================================================

local TARGET_MAX_DIM = 3.0
local SCALE_FLOOR    = 0.02
local SCALE_CEIL     = 1.0

-- =====================================================================
-- STATE (per-player icon tracking)
-- =====================================================================

local _activeIcons: { [Player]: {
	icon: Instance,
	conn: RBXScriptConnection?,
	cf: CFrame,
	t0: number,
} } = {}

local _playerConns: { [Player]: { RBXScriptConnection } } = {}

local function log(...)
	print(TAG, ...)
end

local function ensureValidBeam(beam: Beam): boolean
	local function invalidate()
		if beam.Parent then
			beam:Destroy()
		end
	end
	local function isAttachmentValid(att: Attachment?): boolean
		return att ~= nil and att.Parent ~= nil and att:IsDescendantOf(game)
	end
	local function validateNow()
		if not beam.Parent then
			return false
		end
		local a0 = beam.Attachment0
		local a1 = beam.Attachment1
		if not isAttachmentValid(a0) or not isAttachmentValid(a1) then
			invalidate()
			return false
		end
		return true
	end

	if not validateNow() then
		return false
	end

	beam:GetPropertyChangedSignal("Attachment0"):Connect(validateNow)
	beam:GetPropertyChangedSignal("Attachment1"):Connect(validateNow)
	local a0 = beam.Attachment0
	local a1 = beam.Attachment1
	if a0 then
		a0.AncestryChanged:Connect(validateNow)
	end
	if a1 then
		a1.AncestryChanged:Connect(validateNow)
	end
	beam.AncestryChanged:Connect(function()
		if beam.Parent then
			validateNow()
		end
	end)

	return true
end

-- =====================================================================
-- HELPERS
-- =====================================================================

local function getBBoxSize(inst: Instance): Vector3?
	if inst:IsA("Model") then
		local ok, _, sz = pcall(inst.GetBoundingBox, inst)
		if ok and typeof(sz) == "Vector3" then return sz end
		local ok2, ext = pcall(inst.GetExtentsSize, inst)
		if ok2 and typeof(ext) == "Vector3" then return ext end
		return nil
	elseif inst:IsA("BasePart") then
		return inst.Size
	end
	return nil
end

local function applyScale(inst: Instance, factor: number): boolean
	if factor == 1 then return true end
	if inst:IsA("Model") then
		local ok = pcall(function()
			local cur = inst:GetScale()
			inst:ScaleTo(cur * factor)
		end)
		if ok then return true end
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

local function yawOnly(cf: CFrame): number
	local _, ry, _ = cf:ToEulerAnglesYXZ()
	return ry
end

-- =====================================================================
-- ICON SPAWN / DESTROY
-- =====================================================================

local function getIconDef(iconId: string)
	if not iconId or iconId == "" then return nil end
	return ItemCatalog.IconImages and ItemCatalog.IconImages[iconId]
end

local function destroyIconFor(player: Player)
	local entry = _activeIcons[player]
	if not entry then return end
	if entry.conn then entry.conn:Disconnect() end
	if entry.icon and entry.icon.Parent then entry.icon:Destroy() end
	_activeIcons[player] = nil
end

local function spawnIconFor(player: Player, iconId: string)
	local existing = _activeIcons[player]
	if existing and existing.icon and existing.icon.Parent then
		if existing.icon:GetAttribute("_iconImageId") == iconId then return end
	end

	destroyIconFor(player)

	if not iconId or iconId == "" then return end

	local iconDef = getIconDef(iconId)
	if not iconDef then
		warn(TAG, "Icon image not in catalog:", iconId)
		return
	end

	local modelPath = iconDef.modelPath
	if not modelPath or modelPath == "" then
		warn(TAG, "No modelPath for icon image:", iconId,
			"| catalogEntry:", iconDef.name or "?", "rarity:", iconDef.rarity or "?",
			"| image:", iconDef.image or "nil", "| modelName:", iconDef.modelName or "nil")
		return
	end

	log("Resolving model for", iconId, "| modelPath:", modelPath, "| registry count:", ItemModelRegistry.GetCount())
	local sourceModel = ItemModelRegistry.Get(modelPath)
	if not sourceModel then
		warn(TAG, "modelPath exists but model NOT FOUND in registry:", modelPath,
			"| iconId:", iconId, "| Try checking ReplicatedStorage.ItemModels hierarchy")
		log("Dumping registry keys for debug:")
		ItemModelRegistry.DumpKeys()
		return
	end
	log("Model resolved OK:", sourceModel:GetFullName(), "for icon:", iconId)

	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return end

	log("Spawning icon image for", player.Name .. ":", iconId, "path:", modelPath)

	local clone = sourceModel:Clone()

	-- Unwrap Accessory
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

	-- Wrap bare BaseParts into a Model
	if clone:IsA("BasePart") and not clone:IsA("Model") then
		local wrapper = Instance.new("Model")
		wrapper.Name = clone.Name
		clone.Parent = wrapper
		wrapper.PrimaryPart = clone
		clone = wrapper
	end

	-- Make all parts non-interactive and anchored
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

	-- Enable VFX
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("ParticleEmitter") or d:IsA("Fire") or d:IsA("Sparkles")
			or d:IsA("Smoke") or d:IsA("Beam") or d:IsA("Trail") then
			if d:IsA("Beam") then
				if ensureValidBeam(d) then
					d.Enabled = true
				end
			else
				d.Enabled = true
			end
		elseif d:IsA("Script") or d:IsA("LocalScript") then
			d:Destroy()
		end
	end

	-- SIZE NORMALIZATION
	local preBBox = getBBoxSize(clone)
	local iconScale = 1

	do
		if preBBox then
			local maxDim = math.max(preBBox.X, preBBox.Y, preBBox.Z, 0.01)
			if maxDim > TARGET_MAX_DIM then
				iconScale = TARGET_MAX_DIM / maxDim
			end
		end

		iconScale = math.clamp(iconScale, SCALE_FLOOR, SCALE_CEIL)

		if iconScale < 1 then
			applyScale(clone, iconScale)
		end

		-- Post-scale verification
		local postBBox = getBBoxSize(clone)
		if postBBox then
			local postMax = math.max(postBBox.X, postBBox.Y, postBBox.Z)
			if postMax > TARGET_MAX_DIM then
				local correction = (TARGET_MAX_DIM / postMax) * 0.95
				correction = math.max(correction, SCALE_FLOOR)
				applyScale(clone, correction)
				iconScale = iconScale * correction
				log("Post-scale correction for", iconId,
					string.format("extra %.3fx (was %.1f studs)", correction, postMax))
			end
		end
	end

	log("Scaled icon image", iconId, string.format("%.3fx", iconScale),
		preBBox and string.format("(pre-bbox: %.1f x %.1f x %.1f)", preBBox.X, preBBox.Y, preBBox.Z) or "(no bbox)")

	-- FOLLOW OFFSET (scaled to icon size)
	local offsetMul = 0.4 + 0.6 * iconScale
	local iconOffset = CFrame.new(
		ICON_OFFSET.X * offsetMul,
		ICON_OFFSET.Y * offsetMul,
		ICON_OFFSET.Z * offsetMul
	)
	local iconBobbleAmp = BOBBLE_AMPLITUDE * math.max(iconScale, 0.4)

	-- INITIAL POSITION
	local hrpYaw = yawOnly(rootPart.CFrame)
	local startPos = (rootPart.CFrame * iconOffset).Position
	local startCF = CFrame.new(startPos) * CFrame.Angles(0, hrpYaw, 0)

	if clone:IsA("Model") then
		clone:PivotTo(startCF)
	elseif clone:IsA("BasePart") then
		clone.CFrame = startCF
	end

	clone.Name = ICON_INSTANCE_NAME
	clone:SetAttribute("_iconImageId", iconId)
	clone:SetAttribute("_owner", player.Name)
	clone.Parent = workspace

	-- FOLLOW + BOBBLE LOOP
	local currentCF = startCF
	local t0 = tick()

	local followConn = RunService.Heartbeat:Connect(function()
		if not clone or not clone.Parent then
			destroyIconFor(player)
			return
		end
		local char = player.Character
		if not char then return end
		local hrp = char:FindFirstChild("HumanoidRootPart")
		if not hrp then return end

		local t = tick() - t0

		local targetPos = (hrp.CFrame * iconOffset).Position
		local bobbleY = math.sin(t * BOBBLE_SPEED) * iconBobbleAmp
		targetPos = targetPos + Vector3.new(0, bobbleY, 0)

		local playerYaw = yawOnly(hrp.CFrame)

		local yawW = math.sin(t * YAW_WOBBLE_SPEED) * math.rad(YAW_WOBBLE_AMP)
		local rollW = math.sin(t * ROLL_WOBBLE_SPEED) * math.rad(ROLL_WOBBLE_AMP)
		local finalYaw = playerYaw + yawW

		local targetCF = CFrame.new(targetPos) * CFrame.Angles(0, finalYaw, rollW)

		currentCF = currentCF:Lerp(targetCF, LERP_ALPHA)

		if clone:IsA("Model") then
			clone:PivotTo(currentCF)
		elseif clone:IsA("BasePart") then
			clone.CFrame = currentCF
		end
	end)

	_activeIcons[player] = {
		icon = clone,
		conn = followConn,
		cf = currentCF,
		t0 = t0,
	}

	log("Icon image spawned for", player.Name .. ":", iconId)
end

-- =====================================================================
-- PER-PLAYER LIFECYCLE
-- =====================================================================

local function updateIconFor(player: Player)
	local iconId = player:GetAttribute("EquippedIconImage")
	log("updateIconFor", player.Name, "| EquippedIconImage attr =", tostring(iconId))
	if iconId and iconId ~= "" then
		spawnIconFor(player, iconId)
	else
		log("No equipped icon image for", player.Name, "-- destroying any active icon")
		destroyIconFor(player)
	end
end

local function setupPlayer(player: Player)
	local conns: { RBXScriptConnection } = {}

	table.insert(conns, player:GetAttributeChangedSignal("EquippedIconImage"):Connect(function()
		local newVal = player:GetAttribute("EquippedIconImage")
		log("EquippedIconImage CHANGED for", player.Name, "->", tostring(newVal))
		updateIconFor(player)
	end))

	table.insert(conns, player.CharacterAdded:Connect(function(character)
		character:WaitForChild("HumanoidRootPart", 10)
		task.wait(0.5)
		updateIconFor(player)
	end))

	table.insert(conns, player.CharacterRemoving:Connect(function()
		destroyIconFor(player)
	end))

	_playerConns[player] = conns

	if player.Character and player.Character:FindFirstChild("HumanoidRootPart") then
		task.spawn(function()
			task.wait(0.3)
			updateIconFor(player)
		end)
	end
end

local function cleanupPlayer(player: Player)
	destroyIconFor(player)
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

function IconFollowerController.Init()
	log("Initializing...")

	Players.PlayerAdded:Connect(setupPlayer)
	Players.PlayerRemoving:Connect(cleanupPlayer)

	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(setupPlayer, player)
	end

	log("Ready -- tracking icon images for all players")
end

return IconFollowerController