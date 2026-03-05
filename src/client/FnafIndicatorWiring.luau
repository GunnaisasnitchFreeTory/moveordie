local FnafIndicatorWiring = {}
local initialized = false
local wireInProgress = false
local fnafPromptConn: RBXScriptConnection? = nil
local fnafPromptLastOpenAt = 0

local function getShopPanel()
	local ui = script.Parent:FindFirstChild("UI")
	if not ui then
		return nil
	end
	local shopPanelModule = ui:FindFirstChild("ShopPanel")
	if not shopPanelModule then
		return nil
	end
	local ok, result = pcall(require, shopPanelModule)
	if ok then
		return result
	end
	return nil
end

local function findBrainrotIndicator(): BillboardGui?
	for _, inst in ipairs(workspace:GetDescendants()) do
		if inst:IsA("BillboardGui") then
			local label = inst:FindFirstChild("Badge")
			label = label and label:FindFirstChild("Label")
			if label and label:IsA("TextLabel") and label.Text == "BRAINROT BUNDLE" then
				return inst
			end
		end
	end
	return nil
end

local function findBrainrotPrompt(): ProximityPrompt?
	local brainrot = workspace:FindFirstChild("Brainrot Game Bun")
	if not brainrot then
		return nil
	end
	for _, inst in ipairs(brainrot:GetDescendants()) do
		if inst:IsA("ProximityPrompt") then
			return inst
		end
	end
	return nil
end

local function findFnafModel(): Instance?
	local exact = workspace:FindFirstChild("FNAFGameBun") or workspace:FindFirstChild("FNAF Game Bun")
	if exact then
		if exact:IsA("Model") or exact:IsA("Folder") then
			return exact
		end
		local ancestorContainer = exact:FindFirstAncestorWhichIsA("Model") or exact:FindFirstAncestorWhichIsA("Folder")
		if ancestorContainer then
			return ancestorContainer
		end
	end
	for _, d in ipairs(workspace:GetDescendants()) do
		local n = string.lower(d.Name)
		if (d:IsA("Model") or d:IsA("Folder")) and string.find(n, "fnaf", 1, true) and string.find(n, "bun", 1, true) then
			return d
		end
	end
	return nil
end

local function findFnafAnchorPart(model: Instance): BasePart?
	local explicit = model:FindFirstChild("PromptPart")
	if explicit and explicit:IsA("BasePart") then
		return explicit
	end

	local preferredNames = {
		"freddyfzber",
		"freddyfazber",
		"freddyfazbear",
		"poster",
		"sign",
	}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			local lower = string.lower(d.Name)
			for _, needle in ipairs(preferredNames) do
				if string.find(lower, needle, 1, true) then
					return d
				end
			end
		end
	end

	local poster = model:FindFirstChild("Poster")
	if poster then
		local posterPart = poster:FindFirstChildWhichIsA("BasePart", true)
		if posterPart then return posterPart end
	end

	local bestPart: BasePart? = nil
	local bestY = -math.huge
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and d.Position.Y > bestY then
			bestY = d.Position.Y
			bestPart = d
		end
	end
	if bestPart then
		return bestPart
	end

	return model:FindFirstChildWhichIsA("BasePart", true)
end

local function createPromptPart(model: Instance): BasePart?
	local parent: Instance = model
	if not (parent:IsA("Model") or parent:IsA("Folder")) then
		local ancestorContainer = model:FindFirstAncestorWhichIsA("Model") or model:FindFirstAncestorWhichIsA("Folder")
		if ancestorContainer then
			parent = ancestorContainer
		else
			parent = workspace
		end
	end
	if not parent then
		return nil
	end

	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	local found = false
	local refPart: BasePart? = nil
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and d.Transparency < 1 then
			local ln = string.lower(d.Name)
			if string.find(ln, "freddy", 1, true)
				or string.find(ln, "bonnie", 1, true)
				or string.find(ln, "chica", 1, true)
				or string.find(ln, "poster", 1, true)
				or string.find(ln, "sign", 1, true)
			then
				refPart = d
				break
			end
		end
	end
	if model:IsA("BasePart") then
		found = true
		local p = model.Position
		local h = model.Size * 0.5
		minX = math.min(minX, p.X - h.X)
		minY = math.min(minY, p.Y - h.Y)
		minZ = math.min(minZ, p.Z - h.Z)
		maxX = math.max(maxX, p.X + h.X)
		maxY = math.max(maxY, p.Y + h.Y)
		maxZ = math.max(maxZ, p.Z + h.Z)
	end
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			found = true
			local p = d.Position
			local h = d.Size * 0.5
			minX = math.min(minX, p.X - h.X)
			minY = math.min(minY, p.Y - h.Y)
			minZ = math.min(minZ, p.Z - h.Z)
			maxX = math.max(maxX, p.X + h.X)
			maxY = math.max(maxY, p.Y + h.Y)
			maxZ = math.max(maxZ, p.Z + h.Z)
		end
	end
	-- Place interaction anchor above the bundle display (head/chest readable zone).
	local origin = found and Vector3.new((minX + maxX) * 0.5, maxY + 1.5, (minZ + maxZ) * 0.5) or Vector3.new(0, 6, 0)
	if refPart then
		origin = refPart.Position + Vector3.new(0, 3.5, 0)
	end

	local promptPart = parent:FindFirstChild("PromptPart")
	local created = false
	if not (promptPart and promptPart:IsA("BasePart")) then
		promptPart = Instance.new("Part")
		promptPart.Name = "PromptPart"
		promptPart.Parent = parent
		created = true
	end
	promptPart.Name = "PromptPart"
	promptPart.Size = Vector3.new(2, 2, 2)
	promptPart.Anchored = true
	promptPart.CanCollide = false
	promptPart.CanQuery = true
	promptPart.CanTouch = false
	promptPart.Transparency = 1
	-- Keep anchor stable once created; do not keep re-positioning every rewire cycle.
	-- Reposition only when first created or currently invalid.
	if created or (promptPart.Position.X ~= promptPart.Position.X) then
		promptPart.Position = origin
	end
	return promptPart
end

local function copyPromptWiring(sourcePrompt: ProximityPrompt?, model: Instance, anchor: BasePart): ProximityPrompt?
	local targetPrompt: ProximityPrompt? = nil
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("ProximityPrompt") then
			targetPrompt = d
			break
		end
	end

	if not targetPrompt then
		if sourcePrompt then
			targetPrompt = sourcePrompt:Clone()
		else
			targetPrompt = Instance.new("ProximityPrompt")
			targetPrompt.Name = "FNAFBundlePrompt"
			targetPrompt.HoldDuration = 0
			targetPrompt.MaxActivationDistance = 10
			targetPrompt.RequiresLineOfSight = false
			targetPrompt.KeyboardKeyCode = Enum.KeyCode.E
			targetPrompt.GamepadKeyCode = Enum.KeyCode.ButtonX
			targetPrompt.Style = Enum.ProximityPromptStyle.Default
		end
	end

	if sourcePrompt then
		targetPrompt.ActionText = sourcePrompt.ActionText
		targetPrompt.ObjectText = sourcePrompt.ObjectText
		targetPrompt.HoldDuration = sourcePrompt.HoldDuration
		targetPrompt.MaxActivationDistance = sourcePrompt.MaxActivationDistance
		targetPrompt.RequiresLineOfSight = sourcePrompt.RequiresLineOfSight
		targetPrompt.KeyboardKeyCode = sourcePrompt.KeyboardKeyCode
		targetPrompt.GamepadKeyCode = sourcePrompt.GamepadKeyCode
		targetPrompt.Style = sourcePrompt.Style
	end
	targetPrompt.Enabled = true

	-- Requested text override only.
	targetPrompt.ActionText = "Buy"
	targetPrompt.ObjectText = "FNAF Pets"
	targetPrompt.MaxActivationDistance = math.max(10, targetPrompt.MaxActivationDistance)
	targetPrompt.RequiresLineOfSight = false
	targetPrompt.HoldDuration = 0
	targetPrompt.Parent = anchor

	return targetPrompt
end

local function copyIndicatorWiring(sourceIndicator: BillboardGui?, model: Instance, anchor: BasePart): BillboardGui?
	local existing: BillboardGui? = nil
	for _, child in ipairs(model:GetDescendants()) do
		if child:IsA("BillboardGui") then
			local lbl = child:FindFirstChild("Badge")
			lbl = lbl and lbl:FindFirstChild("Label")
			if lbl and lbl:IsA("TextLabel") and lbl.Text == "FNAF Pets" then
				existing = child
				break
			end
		end
	end

	local target = existing
	if not target then
		if sourceIndicator then
			target = sourceIndicator:Clone()
		else
			target = Instance.new("BillboardGui")
			target.Name = "FNAFBundleIndicator"
			target.Size = UDim2.fromOffset(240, 70)
			target.StudsOffset = Vector3.new(0, 3, 0)
			target.AlwaysOnTop = true
			target.LightInfluence = 0
			target.MaxDistance = 100

			local badge = Instance.new("Frame")
			badge.Name = "Badge"
			badge.Size = UDim2.fromScale(1, 1)
			badge.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
			badge.BackgroundTransparency = 0.35
			badge.BorderSizePixel = 0
			badge.Parent = target
			Instance.new("UICorner", badge).CornerRadius = UDim.new(0, 10)

			local label2 = Instance.new("TextLabel")
			label2.Name = "Label"
			label2.BackgroundTransparency = 1
			label2.Size = UDim2.fromScale(1, 1)
			label2.Font = Enum.Font.GothamBold
			label2.Text = "FNAF Pets"
			label2.TextScaled = true
			label2.TextColor3 = Color3.fromRGB(255, 255, 255)
			label2.Parent = badge
		end
	end
	local badge = target:FindFirstChild("Badge")
	if not (badge and badge:IsA("Frame")) then
		badge = Instance.new("Frame")
		badge.Name = "Badge"
		badge.Size = UDim2.fromScale(1, 1)
		badge.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		badge.BackgroundTransparency = 0.35
		badge.BorderSizePixel = 0
		badge.Parent = target
		Instance.new("UICorner", badge).CornerRadius = UDim.new(0, 10)
	end
	local label = badge:FindFirstChild("Label")
	if not (label and label:IsA("TextLabel")) then
		label = Instance.new("TextLabel")
		label.Name = "Label"
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.Font = Enum.Font.GothamBold
		label.TextScaled = true
		label.TextColor3 = Color3.fromRGB(255, 255, 255)
		label.Parent = badge
	end
	label.Text = "FNAF Pets"
	target.Enabled = true
	target.Active = false
	if sourceIndicator then
		target.AlwaysOnTop = sourceIndicator.AlwaysOnTop
		target.LightInfluence = sourceIndicator.LightInfluence
		target.MaxDistance = sourceIndicator.MaxDistance
		target.Size = sourceIndicator.Size
		target.StudsOffset = Vector3.new(
			sourceIndicator.StudsOffset.X,
			sourceIndicator.StudsOffset.Y + 2,
			sourceIndicator.StudsOffset.Z
		)
		target.ExtentsOffsetWorldSpace = sourceIndicator.ExtentsOffsetWorldSpace
	else
		target.AlwaysOnTop = true
		target.LightInfluence = 0
		target.MaxDistance = 200
		target.Size = UDim2.fromOffset(170, 50)
		target.StudsOffset = Vector3.new(0, 4, 0)
	end
	target.Adornee = anchor
	if target.Parent ~= anchor then
		target.Parent = anchor
	end
	return target
end

local function bindFnafPrompt(prompt: ProximityPrompt?)
	if not prompt then
		return
	end
	if fnafPromptConn then
		fnafPromptConn:Disconnect()
		fnafPromptConn = nil
	end
	fnafPromptConn = prompt.Triggered:Connect(function(playerWhoTriggered)
		local Players = game:GetService("Players")
		local localPlayer = Players.LocalPlayer
		if playerWhoTriggered and playerWhoTriggered ~= localPlayer then
			return
		end
		local now = os.clock()
		if (now - fnafPromptLastOpenAt) < 0.75 then
			return
		end
		fnafPromptLastOpenAt = now
		local ShopPanel = getShopPanel()
		if not ShopPanel then
			return
		end
		print("[ShopOpen] source=FNAFPrompt action=OPEN")
		if ShopPanel.Show then
			ShopPanel.Show()
		end
		if ShopPanel.ActivateBundleTab then
			ShopPanel.ActivateBundleTab("fnaf_pets_bundle")
		end
	end)
end

local function wireNow()
	if wireInProgress then
		return
	end
	wireInProgress = true
	local ok, err = pcall(function()
		local sourcePrompt: ProximityPrompt? = nil
		for _ = 1, 5 do
			sourcePrompt = findBrainrotPrompt()
			if sourcePrompt then break end
			task.wait(0.2)
		end

		local sourceIndicator: BillboardGui? = nil
		for _ = 1, 5 do
			sourceIndicator = findBrainrotIndicator()
			if sourceIndicator then break end
			task.wait(0.2)
		end

		local fnafModel: Instance? = nil
		for _ = 1, 30 do
			fnafModel = findFnafModel()
			if fnafModel then break end
			task.wait(1)
		end
		if not fnafModel then
			warn("[Indicator] FNAF bundle model not found")
			return
		end
		print(string.format("[FNAFWire] ModelResolved=%s class=%s", fnafModel:GetFullName(), fnafModel.ClassName))

		-- Always use a dedicated explicit anchor at Workspace.FNAFGameBun.PromptPart.
		local anchor = createPromptPart(fnafModel) or findFnafAnchorPart(fnafModel)
		if not anchor then
			warn("[FNAFWire] FNAF anchor part not found")
			return
		end

		print(string.format("[FNAFAnchor] Using anchor=%s pos=%s",
			anchor:GetFullName(), tostring(anchor.Position)))

		local prompt = copyPromptWiring(sourcePrompt, fnafModel, anchor)
		local indicator = copyIndicatorWiring(sourceIndicator, fnafModel, anchor)
		bindFnafPrompt(prompt)
		local promptParentPath = prompt and prompt.Parent and prompt.Parent:GetFullName() or "nil"
		local indicatorParentPath = indicator and indicator.Parent and indicator.Parent:GetFullName() or "nil"
		print(string.format("[FNAFAnchor] PromptParent=%s IndicatorParent=%s",
			promptParentPath, indicatorParentPath))
		if indicator then
			print(string.format("[BundleIndicator] bundle=fnaf visible=true part=%s", anchor:GetFullName()))
		end
	end)
	if not ok then
		warn("[FNAFWire] wireNow failed:", err)
	end
	wireInProgress = false
end

function FnafIndicatorWiring.Init()
	if initialized then
		return
	end
	initialized = true
	task.spawn(function()
		while true do
			wireNow()
			task.wait(8)
		end
	end)
	workspace.DescendantAdded:Connect(function(inst)
		local n = string.lower(inst.Name)
		if string.find(n, "fnaf", 1, true)
			or string.find(n, "bun", 1, true)
			or string.find(n, "prompt", 1, true)
			or inst:IsA("BillboardGui")
		then
			task.delay(0.2, wireNow)
		end
	end)
end

return FnafIndicatorWiring
