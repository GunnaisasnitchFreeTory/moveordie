local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local VIPChestPromptController = {}

local LocalPlayer = Players.LocalPlayer
local VIP_GAMEPASS_ID = 1745607323
local VIP_LABEL_MAX_DISTANCE = 60
local UPDATE_INTERVAL = 0.2

local promptConnection: RBXScriptConnection? = nil
local purchaseDebounce = false
local updateAccum = 0
local chestPrimaryPart: BasePart? = nil
local vipLabel: BillboardGui? = nil

local function getVipGateRemote(): RemoteFunction?
	local remotes = game:GetService("ReplicatedStorage"):FindFirstChild("Remotes")
	if not remotes then
		return nil
	end
	local rf = remotes:FindFirstChild("CanPurchaseGamepassReward")
	if rf and rf:IsA("RemoteFunction") then
		return rf
	end
	return nil
end

local function hasPersistedVipOwnership(): boolean
	return LocalPlayer:GetAttribute("OwnsVIP") == true
		or LocalPlayer:GetAttribute("VIPBundleOwned") == true
end

local function resolveVipAlreadyOwned(context: string): boolean
	local persistedOwned = hasPersistedVipOwnership()
	local marketplaceOwned = false
	local gateBlocked = false

	local gateRF = getVipGateRemote()
	if gateRF then
		local okGate, gateResult = pcall(function()
			return gateRF:InvokeServer(VIP_GAMEPASS_ID)
		end)
		if okGate and type(gateResult) == "table" then
			gateBlocked = gateResult.allowed == false
			local gateAlreadyOwned = gateResult.alreadyOwned == true
			marketplaceOwned = gateResult.marketplaceOwned == true
			persistedOwned = persistedOwned or gateResult.vipOwned == true
			print(string.format(
				"[VIPPromptGate] context=%s player=%s gateAllowed=%s gateAlreadyOwned=%s gateVipOwned=%s gateMarketplaceOwned=%s persistedAttr=%s",
				context,
				LocalPlayer.Name,
				tostring(gateResult.allowed == true),
				tostring(gateAlreadyOwned),
				tostring(gateResult.vipOwned == true),
				tostring(gateResult.marketplaceOwned == true),
				tostring(hasPersistedVipOwnership())
			))
			if gateAlreadyOwned then
				return true
			end
		end
	end

	if not marketplaceOwned then
		local okOwns, owns = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(LocalPlayer.UserId, VIP_GAMEPASS_ID)
		end)
		if okOwns then
			marketplaceOwned = owns == true
		end
	end

	local alreadyOwned = gateBlocked or persistedOwned or marketplaceOwned
	print(string.format(
		"[VIPPromptGate] context=%s player=%s persistedOwned=%s marketplaceOwned=%s promptBlocked=%s",
		context,
		LocalPlayer.Name,
		tostring(persistedOwned),
		tostring(marketplaceOwned),
		tostring(alreadyOwned)
	))
	return alreadyOwned
end

local function refreshVipPromptOwnedState(prompt: ProximityPrompt?)
	if not prompt then
		return
	end
	if hasPersistedVipOwnership() then
		prompt.ActionText = "Owned"
	else
		prompt.ActionText = "Buy VIP"
	end
end

local function applyVipLabelVisuals(label: BillboardGui, adorneePart: BasePart)
	label.Adornee = adorneePart
	label.LightInfluence = 0
	label.AlwaysOnTop = true
	label.Size = UDim2.new(0, 120, 0, 50)
	label.StudsOffset = Vector3.new(0, 3, 0)
	label.MaxDistance = VIP_LABEL_MAX_DISTANCE

	local textLabel = label:FindFirstChildWhichIsA("TextLabel", true)
	if textLabel then
		textLabel.TextScaled = true
		textLabel.TextStrokeTransparency = 0.4
	end
end

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

	local prompt = chestModel:FindFirstChild("VIPPurchasePrompt", true)
	if prompt and prompt:IsA("ProximityPrompt") then
		local parentPart = prompt.Parent
		if parentPart and parentPart:IsA("BasePart") then
			chestPrimaryPart = parentPart
		end
		return prompt
	end

	prompt = primaryPart:FindFirstChild("VIPPurchasePrompt")
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

	local label = chestModel:FindFirstChild("VIPLabel", true)
	if label and label:IsA("BillboardGui") then
		local parentPart = label.Parent
		if parentPart and parentPart:IsA("BasePart") then
			chestPrimaryPart = parentPart
		end
		applyVipLabelVisuals(label, chestPrimaryPart)
		label.Enabled = false
		print(string.format(
			"[VIPLabelDebug] labelFound=%s parent=%s maxDistance=%d",
			label:GetFullName(),
			chestPrimaryPart:GetFullName(),
			VIP_LABEL_MAX_DISTANCE
		))
		return label
	end

	label = primaryPart:FindFirstChild("VIPLabel") or primaryPart:FindFirstChild("VIPLabel", true)
	if label and label:IsA("BillboardGui") then
		applyVipLabelVisuals(label, primaryPart)
		label.Enabled = false
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
	applyVipLabelVisuals(vipLabel, chestPrimaryPart)

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

		print(string.format("[VIPPromptGate] context=VIPChestInteract player=%s event=triggered", LocalPlayer.Name))
		if resolveVipAlreadyOwned("VIPChestInteract") then
			refreshVipPromptOwnedState(prompt)
			print(string.format("[VIPPromptGate] context=VIPChestInteract player=%s result=BLOCKED_ALREADY_OWNED", LocalPlayer.Name))
			return
		end

		purchaseDebounce = true
		refreshVipPromptOwnedState(prompt)
		print(string.format("[VIPPromptGate] context=VIPChestInteract player=%s result=OPEN_PROMPT", LocalPlayer.Name))
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
		refreshVipPromptOwnedState(prompt)
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
