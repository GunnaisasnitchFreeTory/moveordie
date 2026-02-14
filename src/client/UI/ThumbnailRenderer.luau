--[[
	ThumbnailRenderer  (v6 — registry-only, no VFX)
	Renders 3D item models into ViewportFrames using WorldModel.

	This is a FALLBACK renderer used only when an item has no explicit
	image id in ItemCatalog. Items with static screenshot images (which
	already include VFX baked in) bypass this module entirely.

	VFX proxy was removed in v6 — static images are the source of truth
	for items that need VFX in their thumbnails.

	RESOLUTION: ItemModelRegistry.Get(path) — single hash lookup.
	CACHING:    _renderCache[vpFrame] = normalizedKey — skip re-render.
	WARNINGS:   _warnedKeys[key] = true — warn once per missing key.
	KILL-SWITCH: Set DISABLE_THUMBNAILS BoolValue in ReplicatedStorage.Shared
	             to true → all calls return false immediately, no logs.

	API (unchanged for callers):
	  ThumbnailRenderer.RenderItemToViewport(vpFrame, itemDef, options?) -> boolean
	  ThumbnailRenderer.InvalidateCache(vpFrame)
	  ThumbnailRenderer.ClearCache()

	Used by: IndexPanel, ShopPanel, CrateShopPanel (fallback only)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TAG = "[ThumbnailRenderer]"
print(TAG, "LOADED FROM:", script:GetFullName())

local ThumbnailRenderer = {}

-- =====================================================================
-- DEPENDENCIES (registry only — NO Workspace anywhere in this module)
-- =====================================================================

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemModelRegistry = require(Shared:WaitForChild("ItemModelRegistry"))

-- =====================================================================
-- KILL-SWITCH
-- =====================================================================

local _killSwitch: BoolValue? = Shared:FindFirstChild("DISABLE_THUMBNAILS") :: BoolValue?
if not _killSwitch then
	local bv = Instance.new("BoolValue")
	bv.Name = "DISABLE_THUMBNAILS"
	bv.Value = false
	bv.Parent = Shared
	_killSwitch = bv
end

local function isDisabled(): boolean
	return _killSwitch and _killSwitch.Value == true
end

-- =====================================================================
-- DEFAULTS
-- =====================================================================

local DEFAULT_CAMERA_ANGLE = Vector3.new(0.5, 0.35, 0.8)
local DEFAULT_FOV = 50
local DEFAULT_DISTANCE_MULT = 2.0
local DEFAULT_AMBIENT = Color3.fromRGB(180, 180, 200)
local DEFAULT_LIGHT_COLOR = Color3.fromRGB(255, 255, 255)
local DEFAULT_LIGHT_DIR = Vector3.new(-1, -1, -1)

-- Per-item thumbnail yaw correction (degrees).
-- Rotates the model in the ViewportFrame so its "face" points toward the camera.
-- Only affects thumbnails — does NOT change in-world orientation.
local THUMBNAIL_YAW_OFFSETS: { [string]: number } = {
	pet_dog = 180, -- Blender model faces +Z; thumbnail camera is on +Z side → flip
}

local KEEP_CLASSES = {
	UICorner = true,
	UIStroke = true,
	UIGradient = true,
	UIListLayout = true,
	UIGridLayout = true,
	UIPadding = true,
	UIAspectRatioConstraint = true,
	UIScale = true,
}

-- (VFX proxy config removed in v6 — static images include VFX)

-- =====================================================================
-- WARN-ONCE + RENDER CACHE
-- =====================================================================

local _warnedKeys: { [string]: boolean } = {}
local _renderCache: { [ViewportFrame]: string } = {}

-- =====================================================================
-- INTERNALS (rendering helpers — no model resolution here)
-- =====================================================================

local function isInsideThumbnailVFX(part: Instance, root: Instance): boolean
	local parent = part.Parent
	while parent and parent ~= root do
		if parent:IsA("Folder") and parent.Name == "ThumbnailVFX" then return true end
		parent = parent.Parent
	end
	return false
end

local function getModelBounds(root: Instance): (Vector3, Vector3)
	-- Priority A: ThumbnailCameraTarget overrides everything
	local camTarget = root:FindFirstChild("ThumbnailCameraTarget", true)
	if camTarget and camTarget:IsA("BasePart") then
		local p, h = camTarget.Position, camTarget.Size / 2
		return
			Vector3.new(p.X - h.X, p.Y - h.Y, p.Z - h.Z),
			Vector3.new(p.X + h.X, p.Y + h.Y, p.Z + h.Z)
	end

	-- Priority B: PrimaryPart if model has one
	if root:IsA("Model") and root.PrimaryPart then
		local pp = root.PrimaryPart
		local p, h = pp.Position, pp.Size / 2
		return
			Vector3.new(p.X - h.X, p.Y - h.Y, p.Z - h.Z),
			Vector3.new(p.X + h.X, p.Y + h.Y, p.Z + h.Z)
	end

	-- Priority C: All visible BaseParts, excluding ThumbnailVFX contents
	local minB = Vector3.new(math.huge, math.huge, math.huge)
	local maxB = Vector3.new(-math.huge, -math.huge, -math.huge)
	local found = false
	local function proc(part: BasePart)
		found = true
		local p, h = part.Position, part.Size / 2
		minB = Vector3.new(math.min(minB.X, p.X-h.X), math.min(minB.Y, p.Y-h.Y), math.min(minB.Z, p.Z-h.Z))
		maxB = Vector3.new(math.max(maxB.X, p.X+h.X), math.max(maxB.Y, p.Y+h.Y), math.max(maxB.Z, p.Z+h.Z))
	end
	if root:IsA("BasePart") then proc(root) end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") and not isInsideThumbnailVFX(d, root) then
			proc(d)
		end
	end
	if not found then return Vector3.zero, Vector3.new(2,2,2) end
	return minB, maxB
end

local function repositionToOrigin(clone: Instance)
	if clone:IsA("Model") and clone.PrimaryPart then
		clone:PivotTo(CFrame.new())
	elseif clone:IsA("BasePart") then
		clone.Position = Vector3.zero
	elseif clone:IsA("Model") then
		local fp = clone:FindFirstChildWhichIsA("BasePart", true)
		if fp then
			local off = fp.Position
			for _, d in ipairs(clone:GetDescendants()) do
				if d:IsA("BasePart") then d.Position = d.Position - off end
			end
		end
	end
end

local function clearViewport(vpFrame: ViewportFrame)
	for _, child in ipairs(vpFrame:GetChildren()) do
		if not KEEP_CLASSES[child.ClassName] then child:Destroy() end
	end
	vpFrame.CurrentCamera = nil
end

-- =====================================================================
-- SAFE CLONE (strips unsafe instances, anchors parts)
-- =====================================================================

local function safeClone(modelInstance: Instance): Instance?
	local ok, clone = pcall(modelInstance.Clone, modelInstance)
	if not ok or not clone then return nil end

	local descendants = clone:GetDescendants()
	for _, d in ipairs(descendants) do
		if d:IsA("Script") or d:IsA("LocalScript") or d:IsA("ModuleScript") then
			d:Destroy()
		elseif d:IsA("Humanoid") or d:IsA("Animator") or d:IsA("AnimationController") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
		end
	end

	return clone
end

-- (VFX detection, proxy parts, and glow border removed in v6)

-- =====================================================================
-- PUBLIC API
-- =====================================================================

function ThumbnailRenderer.RenderItemToViewport(
	vpFrame: ViewportFrame,
	itemDef: {
		modelPath: string?,
		id: string?,
		name: string?,
		type: string?,
		rarity: string?,
	},
	options: { cameraAngle: Vector3?, fov: number?, distanceMultiplier: number? }?
): boolean
	-- Kill-switch: instant bail, no logs
	if isDisabled() then return false end

	-- Validate
	if not vpFrame or typeof(vpFrame) ~= "Instance" or not vpFrame:IsA("ViewportFrame") then
		return false
	end
	if not itemDef or not itemDef.modelPath or itemDef.modelPath == "" then
		return false
	end

	local rawPath = itemDef.modelPath
	local key = ItemModelRegistry.Normalize(rawPath)

	-- Cache hit: already rendered this exact model into this viewport
	if _renderCache[vpFrame] == key then
		return true
	end

	-- Resolve via registry ONLY
	local modelInstance = ItemModelRegistry.Get(rawPath)
	if not modelInstance then
		if not _warnedKeys[key] then
			_warnedKeys[key] = true
			warn(TAG, "MODEL NOT FOUND:", rawPath, "(key:", key .. ")")
		end
		return false
	end

	-- Safe clone: strips scripts/humanoids, anchors parts
	local clone = safeClone(modelInstance)
	if not clone then
		if not _warnedKeys["clone:" .. key] then
			_warnedKeys["clone:" .. key] = true
			warn(TAG, "CLONE FAILED:", rawPath)
		end
		return false
	end

	-- Build viewport scene
	clearViewport(vpFrame)
	vpFrame.Ambient = DEFAULT_AMBIENT
	vpFrame.LightColor = DEFAULT_LIGHT_COLOR
	vpFrame.LightDirection = DEFAULT_LIGHT_DIR

	local wm = Instance.new("WorldModel")
	wm.Name = "ItemWorldModel"
	wm.Parent = vpFrame

	repositionToOrigin(clone)

	-- Per-item thumbnail yaw rotation (rotate model so its face points at camera).
	-- Rotates every BasePart CFrame around the world origin so it works
	-- regardless of whether the Model has a PrimaryPart or not.
	local thumbYaw = THUMBNAIL_YAW_OFFSETS[itemDef.id or ""] or 0
	if thumbYaw ~= 0 then
		local rot = CFrame.Angles(0, math.rad(thumbYaw), 0)
		if clone:IsA("Model") then
			for _, d in ipairs(clone:GetDescendants()) do
				if d:IsA("BasePart") then
					d.CFrame = rot * d.CFrame
				end
			end
		elseif clone:IsA("BasePart") then
			clone.CFrame = rot * clone.CFrame
		end
	end

	clone.Parent = wm

	-- Camera framing
	local minB, maxB = getModelBounds(clone)
	local center = (minB + maxB) / 2
	local sz = maxB - minB
	local maxDim = math.max(sz.X, sz.Y, sz.Z, 1)
	local opts = options or {}
	local angle = opts.cameraAngle or DEFAULT_CAMERA_ANGLE
	local fov = opts.fov or DEFAULT_FOV
	local dist = (opts.distanceMultiplier or DEFAULT_DISTANCE_MULT) * maxDim

	local cam = Instance.new("Camera")
	cam.CameraType = Enum.CameraType.Scriptable
	cam.CFrame = CFrame.lookAt(center + angle.Unit * dist, center)
	cam.FieldOfView = fov
	cam.Parent = vpFrame
	vpFrame.CurrentCamera = cam

	-- Update cache
	_renderCache[vpFrame] = key
	return true
end

function ThumbnailRenderer.InvalidateCache(vpFrame: ViewportFrame)
	if vpFrame then _renderCache[vpFrame] = nil end
end

function ThumbnailRenderer.ClearCache()
	table.clear(_renderCache)
end

-- =====================================================================
-- SELF-TEST (runs once on require — proves registry works)
-- =====================================================================

task.defer(function()
	print(TAG, "v6 loaded | Registry-only | No VFX | kill-switch =", isDisabled())
	print(TAG, "Registry count:", ItemModelRegistry.GetCount())

	-- Spot-check known items
	local tests = {
		{ "ItemModels.Pets.Common.noob",       "Noob" },
		{ "ItemModels.Pets.Rare.ray fish",     "Ray fish" },
		{ "ItemModels.Pets.Common.parrot",     "Parrot" },
	}
	for _, t in ipairs(tests) do
		local inst = ItemModelRegistry.Get(t[1])
		local got = inst and inst.Name or "nil"
		local isOk = inst ~= nil
		print(TAG, string.format("  SELF-TEST: Get(\"%s\") -> %s %s", t[1], got, isOk and "OK" or "MISSING"))
	end
end)

return ThumbnailRenderer
