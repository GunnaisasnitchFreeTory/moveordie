local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local VIPChestPromptController = {}

local LocalPlayer = Players.LocalPlayer
local VIP_GAMEPASS_ID = 1745607323
local VIP_LABEL_MAX_DISTANCE = 40
local UPDATE_INTERVAL = 0.2

local promptConnection: RBXScriptConnection? = nil
local purchaseDebounce = false
local updateAccum = 0
local chestPrimaryPart: BasePart? = nil
local vipLabel: BillboardGui? = nil

local function getChestPrompt(): ProximityPrompt?
	local chestModel = Workspace:FindFirstChild("Golden Chest")
	if not chestModel or not chestModel:IsA("Model") then
		return nil
	end

	local primaryPart = chestModel.PrimaryPart or chestModel:FindFirstChild("chest")
	if not primaryPart or not primaryPart:IsA("BasePart") then
		return nil
	end
	chestPrimaryPart = primaryPart

	local prompt = primaryPart:FindFirstChild("VIPPurchasePrompt")
	if prompt and prompt:IsA("ProximityPrompt") then
		return prompt
	end

	return nil
end

local function getVipLabel(): BillboardGui?
	local chestModel = Workspace:FindFirstChild("Golden Chest")
	if not chestModel or not chestModel:IsA("Model") then
		return nil
	end

	local primaryPart = chestModel.PrimaryPart or chestModel:FindFirstChild("chest")
	if not primaryPart or not primaryPart:IsA("BasePart") then
		return nil
	end
	chestPrimaryPart = primaryPart

	local label = primaryPart:FindFirstChild("VIPLabel")
	if label and label:IsA("BillboardGui") then
		label.Adornee = primaryPart
		label.LightInfluence = 0
		label.MaxDistance = 0
		return label
	end

	return nil
end

local function getLocalRootPart(): BasePart?
	local character = LocalPlayer.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function updateVipLabelVisibility()
	if not vipLabel or not vipLabel.Parent then
		vipLabel = getVipLabel()
	end
	if not vipLabel or not chestPrimaryPart or not chestPrimaryPart.Parent then
		return
	end

	local root = getLocalRootPart()
	if not root then
		vipLabel.Enabled = false
		return
	end

	local distance = (root.Position - chestPrimaryPart.Position).Magnitude
	vipLabel.Enabled = distance <= VIP_LABEL_MAX_DISTANCE
end

local function connectPrompt(prompt: ProximityPrompt)
	if promptConnection then
		promptConnection:Disconnect()
		promptConnection = nil
	end

	promptConnection = prompt.Triggered:Connect(function(player: Player)
		if player ~= LocalPlayer or purchaseDebounce then
			return
		end
		if not LocalPlayer or not LocalPlayer.Parent then
			return
		end

		purchaseDebounce = true
		MarketplaceService:PromptGamePassPurchase(LocalPlayer, VIP_GAMEPASS_ID)
		task.delay(1, function()
			purchaseDebounce = false
		end)
	end)
end

function VIPChestPromptController.Init()
	task.spawn(function()
		local prompt = getChestPrompt()
		if not prompt then
			local chestModel = Workspace:WaitForChild("Golden Chest", 15)
			if chestModel and chestModel:IsA("Model") then
				local primaryPart = chestModel.PrimaryPart or chestModel:WaitForChild("chest", 15)
				if primaryPart and primaryPart:IsA("BasePart") then
					local promptInstance = primaryPart:WaitForChild("VIPPurchasePrompt", 15)
					if promptInstance and promptInstance:IsA("ProximityPrompt") then
						prompt = promptInstance
					end
				end
			end
		end

		if not prompt then
			warn("[VIPChestPromptController] VIPPurchasePrompt not found on Golden Chest")
			return
		end

		vipLabel = getVipLabel()
		connectPrompt(prompt)

		RunService.RenderStepped:Connect(function(dt: number)
			updateAccum += dt
			if updateAccum < UPDATE_INTERVAL then
				return
			end
			updateAccum = 0
			updateVipLabelVisibility()
		end)
	end)
end

return VIPChestPromptController
