local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
if not Shared then
	error("[CloudLayerController] Shared not found")
end

local CloudConfig = require(Shared:WaitForChild("CloudConfig"))

local CloudLayerController = {}

local initialized = false
local container: Folder? = nil
local containerConnections: { RBXScriptConnection } = {}
local workspaceConnections: { RBXScriptConnection } = {}
local animatedTextures: { [Texture]: { baseU: number, baseV: number, speedU: number, speedV: number, wrapU: number, wrapV: number } } = {}
local elapsedTime = 0

local function disconnectConnections(connections)
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function wrapOffset(value: number, wrapAmount: number): number
	if wrapAmount <= 0 then
		return value
	end
	local wrapped = value % wrapAmount
	if wrapped < 0 then
		wrapped += wrapAmount
	end
	return wrapped
end

local function unregisterTexture(descendant: Instance)
	if descendant:IsA("Texture") then
		animatedTextures[descendant] = nil
	end
end

local function applyTextureOffset(texture: Texture, data, elapsed: number)
	texture.OffsetStudsU = wrapOffset(data.baseU + elapsed * data.speedU, data.wrapU)
	texture.OffsetStudsV = wrapOffset(data.baseV + elapsed * data.speedV, data.wrapV)
end

local function registerTexture(descendant: Instance)
	if not descendant:IsA("Texture") then
		return
	end
	if descendant:GetAttribute("CloudAnimated") ~= true then
		return
	end

	animatedTextures[descendant] = {
		baseU = tonumber(descendant:GetAttribute("BaseOffsetU")) or descendant.OffsetStudsU,
		baseV = tonumber(descendant:GetAttribute("BaseOffsetV")) or descendant.OffsetStudsV,
		speedU = tonumber(descendant:GetAttribute("ScrollSpeedU")) or 0,
		speedV = tonumber(descendant:GetAttribute("ScrollSpeedV")) or 0,
		wrapU = tonumber(descendant:GetAttribute("WrapU")) or descendant.StudsPerTileU,
		wrapV = tonumber(descendant:GetAttribute("WrapV")) or descendant.StudsPerTileV,
	}

	applyTextureOffset(descendant, animatedTextures[descendant], elapsedTime)
end

local function bindContainer(nextContainer: Instance?)
	if container == nextContainer then
		return
	end

	container = nil
	table.clear(animatedTextures)
	disconnectConnections(containerConnections)

	if not nextContainer or not nextContainer:IsA("Folder") then
		return
	end

	container = nextContainer
	for _, descendant in ipairs(nextContainer:GetDescendants()) do
		registerTexture(descendant)
	end

	table.insert(containerConnections, nextContainer.DescendantAdded:Connect(registerTexture))
	table.insert(containerConnections, nextContainer.DescendantRemoving:Connect(unregisterTexture))
end

local function trackWorkspaceContainer()
	local existing = Workspace:FindFirstChild(CloudConfig.ContainerName)
	if existing then
		bindContainer(existing)
	end

	table.insert(workspaceConnections, Workspace.ChildAdded:Connect(function(child)
		if child.Name == CloudConfig.ContainerName then
			bindContainer(child)
		end
	end))

	table.insert(workspaceConnections, Workspace.ChildRemoved:Connect(function(child)
		if child == container then
			bindContainer(nil)
		end
	end))
end

function CloudLayerController.Init()
	if initialized or not CloudConfig.Enabled then
		return
	end
	initialized = true
	elapsedTime = 0

	trackWorkspaceContainer()

	task.spawn(function()
		while initialized do
			local dt = task.wait(CloudConfig.UpdateInterval)
			elapsedTime += dt
			for texture, data in pairs(animatedTextures) do
				if texture.Parent then
					applyTextureOffset(texture, data, elapsedTime)
				else
					animatedTextures[texture] = nil
				end
			end
		end
	end)
end

function CloudLayerController.Destroy()
	initialized = false
	container = nil
	elapsedTime = 0
	table.clear(animatedTextures)
	disconnectConnections(containerConnections)
	disconnectConnections(workspaceConnections)
end

return CloudLayerController
