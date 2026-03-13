local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CloudConfig = require(Shared:WaitForChild("CloudConfig"))

if not CloudConfig.Enabled then
	return
end

local function getInstanceCenter(inst: Instance): Vector3?
	if inst:IsA("BasePart") then
		return inst.Position
	end
	if inst:IsA("Model") then
		return inst:GetPivot().Position
	end

	local minBound: Vector3? = nil
	local maxBound: Vector3? = nil
	for _, descendant in ipairs(inst:GetDescendants()) do
		if descendant:IsA("BasePart") then
			local half = descendant.Size * 0.5
			local partMin = descendant.Position - half
			local partMax = descendant.Position + half
			if not minBound then
				minBound = partMin
				maxBound = partMax
			else
				minBound = Vector3.new(
					math.min(minBound.X, partMin.X),
					math.min(minBound.Y, partMin.Y),
					math.min(minBound.Z, partMin.Z)
				)
				maxBound = Vector3.new(
					math.max(maxBound.X, partMax.X),
					math.max(maxBound.Y, partMax.Y),
					math.max(maxBound.Z, partMax.Z)
				)
			end
		end
	end

	if minBound and maxBound then
		return (minBound + maxBound) * 0.5
	end

	return nil
end

local function resolveCloudCenter(): Vector3
	for _, targetName in ipairs(CloudConfig.CenterTargets or {}) do
		local inst = Workspace:FindFirstChild(targetName, true)
		local center = inst and getInstanceCenter(inst)
		if center then
			return Vector3.new(center.X, 0, center.Z)
		end
	end
	local fallback = CloudConfig.FallbackCenter or Vector3.zero
	return Vector3.new(fallback.X, 0, fallback.Z)
end

local function ensureContainer(): Folder
	local existing = Workspace:FindFirstChild(CloudConfig.ContainerName)
	if existing and not existing:IsA("Folder") then
		existing:Destroy()
		existing = nil
	end

	local folder = existing
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = CloudConfig.ContainerName
		folder.Parent = Workspace
	end
	folder:ClearAllChildren()
	return folder
end

local function createTexture(parent: BasePart, face: Enum.NormalId, layerConfig, layerIndex: number)
	local texture = Instance.new("Texture")
	texture.Name = face.Name .. "CloudTexture"
	texture.Face = face
	texture.Texture = layerConfig.texture
	texture.StudsPerTileU = layerConfig.tile.X
	texture.StudsPerTileV = layerConfig.tile.Y
	texture.OffsetStudsU = layerConfig.baseOffset.X
	texture.OffsetStudsV = layerConfig.baseOffset.Y
	texture.Transparency = layerConfig.textureTransparency
	texture.Color3 = layerConfig.color
	texture.Parent = parent

	texture:SetAttribute("CloudAnimated", true)
	texture:SetAttribute("LayerIndex", layerIndex)
	texture:SetAttribute("BaseOffsetU", layerConfig.baseOffset.X)
	texture:SetAttribute("BaseOffsetV", layerConfig.baseOffset.Y)
	texture:SetAttribute("ScrollSpeedU", layerConfig.speed.X)
	texture:SetAttribute("ScrollSpeedV", layerConfig.speed.Y)
	texture:SetAttribute("WrapU", layerConfig.tile.X)
	texture:SetAttribute("WrapV", layerConfig.tile.Y)
end

local function createLayer(container: Folder, center: Vector3, layerConfig, layerIndex: number)
	local part = Instance.new("Part")
	part.Name = layerConfig.name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	part.Color = layerConfig.color
	part.Transparency = 1
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Size = Vector3.new(layerConfig.size.X, layerConfig.thickness, layerConfig.size.Y)
	part.CFrame = CFrame.new(
		center.X + layerConfig.offset.X,
		layerConfig.height,
		center.Z + layerConfig.offset.Y
	) * CFrame.Angles(0, math.rad(layerConfig.rotation or 0), 0)
	part.Parent = container

	part:SetAttribute("CloudLayer", true)
	part:SetAttribute("LayerIndex", layerIndex)

	createTexture(part, Enum.NormalId.Top, layerConfig, layerIndex)
	createTexture(part, Enum.NormalId.Bottom, layerConfig, layerIndex)
end

local container = ensureContainer()
local center = resolveCloudCenter()

container:SetAttribute("CloudSystemEnabled", true)
container:SetAttribute("CloudCenterX", center.X)
container:SetAttribute("CloudCenterZ", center.Z)

local createdLayers = 0
for index, layerConfig in ipairs(CloudConfig.Layers or {}) do
	if layerConfig.enabled ~= false then
		createLayer(container, center, layerConfig, index)
		createdLayers += 1
	end
end

print(string.format("[SkyCloudBootstrap] Built %d cloud layers in Workspace.%s", createdLayers, CloudConfig.ContainerName))
