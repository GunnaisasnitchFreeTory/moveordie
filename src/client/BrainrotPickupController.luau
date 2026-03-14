--[[
	BrainrotPickupController
	Client-side controller for brainrot mode pickups.

	Handles:
	  * Watching BrainrotPickups folder for spawned models
	  * Floating idle animation (sine wave bob + slow Y rotation)
	  * Dedicated brainrot pickup popup (static images preferred, ThumbnailRenderer fallback)
	  * Cleanup on despawn (no memory leaks)

	Popup is self-contained and renders above ALL other UI (DisplayOrder 135).
	Image priority: static imageAssetId -> ThumbnailRenderer (ViewportFrame) -> placeholder.

	API:
		Init()
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AnimUtil = require(script.Parent:WaitForChild("UI"):WaitForChild("AnimUtil"))

local BrainrotPickupController = {}

local player = Players.LocalPlayer
local initialized = false

local _ThumbnailRenderer = nil
local function getThumbnailRenderer()
	if _ThumbnailRenderer then return _ThumbnailRenderer end
	pcall(function()
		local playerScripts = player:FindFirstChild("PlayerScripts")
		local clientUI = playerScripts and playerScripts:FindFirstChild("Client")
		clientUI = clientUI and clientUI:FindFirstChild("UI")
		local mod = clientUI and clientUI:FindFirstChild("ThumbnailRenderer")
		if mod then _ThumbnailRenderer = require(mod) end
	end)
	return _ThumbnailRenderer
end

local FOLDER_NAME    = "BrainrotPickups"
local BOB_AMPLITUDE  = 0.4    -- ±0.4 studs max, well within ±0.35-0.6 spec
local BOB_SPEED      = 2.5
local ROTATION_SPEED = 25
local HOVER_ABOVE_GROUND = 3.0  -- studs above floor to lock baseY

local POPUP_DISPLAY_ORDER = 135
local POPUP_DURATION = 3.0
local BRAINROT_FALLBACK_IMAGE = "rbxassetid://99759801373492"

-- Image holder styling (deep purple, no placeholder vibe)
local ICON_BG_COLOR = Color3.fromRGB(48, 16, 70)
local ICON_STROKE_COLOR = Color3.fromRGB(90, 45, 130)
local ICON_STROKE_THICKNESS = 2
local ICON_STROKE_TRANSPARENCY = 0.15

local activeAnimations = {}
local _popupGui = nil
local _activePopup = nil

-- Raycast params: ignore the model itself + its descendants
local function makeRaycastParams(model): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then table.insert(exclude, d) end
	end
	if model:IsA("BasePart") then table.insert(exclude, model) end
	params.FilterDescendantsInstances = exclude
	return params
end

-- Find ground Y below a given world position; returns nil if no ground found.
local function findGroundY(worldPos: Vector3, model): number?
	local params = makeRaycastParams(model)
	local result = Workspace:Raycast(worldPos, Vector3.new(0, -300, 0), params)
	if result then
		return result.Position.Y
	end
	return nil
end

local function startAnimation(model)
	if activeAnimations[model] then return end

	-- Ensure PrimaryPart is set so PivotTo works correctly for the whole model
	local primaryPart
	if model:IsA("Model") then
		primaryPart = model.PrimaryPart
		if not primaryPart then
			primaryPart = model:FindFirstChildWhichIsA("BasePart", true)
			if primaryPart then
				model.PrimaryPart = primaryPart
			end
		end
	elseif model:IsA("BasePart") then
		primaryPart = model
	end

	if not primaryPart then
		warn("[Brainrot] No BasePart found — cannot animate:", model.Name)
		return
	end

	local baseCFrame = primaryPart.CFrame
	local spawnPos   = baseCFrame.Position

	-- Find ground to determine correct hover baseY
	local groundY = findGroundY(spawnPos, model)
	local baseY: number
	if groundY then
		baseY = groundY + HOVER_ABOVE_GROUND
		print(string.format("[BrainrotHover] BaseY=%.3f (ground=%.3f + %.1f offset)", baseY, groundY, HOVER_ABOVE_GROUND))
	else
		-- Fallback: use spawn position as-is
		baseY = spawnPos.Y
		print(string.format("[BrainrotHover] BaseY=%.3f (no ground found, using spawn Y)", baseY))
	end

	-- Snap model to correct hover height immediately
	local correctedCF = CFrame.new(spawnPos.X, baseY, spawnPos.Z) * (baseCFrame - baseCFrame.Position)
	if model:IsA("Model") then
		model:PivotTo(correctedCF)
	else
		model.CFrame = correctedCF
	end
	baseCFrame = correctedCF  -- update reference

	local startTime = tick()

	local conn = RunService.Heartbeat:Connect(function()
		if not model or not model.Parent then return end

		local elapsed = tick() - startTime
		-- Pure sine — oscillates between -BOB_AMPLITUDE and +BOB_AMPLITUDE, NEVER accumulates
		local bobOffset = math.sin(elapsed * BOB_SPEED) * BOB_AMPLITUDE
		-- Hard clamp so drift from any source cannot push Y outside ±amplitude
		local clampedY = math.clamp(baseY + bobOffset, baseY - BOB_AMPLITUDE, baseY + BOB_AMPLITUDE)
		local rotationAngle = math.rad(elapsed * ROTATION_SPEED)

		local animCFrame = CFrame.new(baseCFrame.Position.X, clampedY, baseCFrame.Position.Z)
			* CFrame.Angles(0, rotationAngle, 0)

		if model:IsA("Model") then
			model:PivotTo(animCFrame)
		else
			model.CFrame = animCFrame
		end
	end)

	activeAnimations[model] = {
		connection = conn,
		baseCFrame = baseCFrame,
		startTime = startTime,
	}
end

local function stopAnimation(model)
	local anim = activeAnimations[model]
	if anim then
		if anim.connection and anim.connection.Connected then
			anim.connection:Disconnect()
		end
		activeAnimations[model] = nil
	end
end

local function onModelAdded(model)
	if not model:GetAttribute("BrainrotPetId") then return end
	task.defer(function()
		if model and model.Parent then
			startAnimation(model)
		end
	end)
end

local function onModelRemoved(model)
	stopAnimation(model)
end

local function watchFolder(folder)
	for _, child in ipairs(folder:GetChildren()) do
		onModelAdded(child)
	end
	folder.ChildAdded:Connect(onModelAdded)
	folder.ChildRemoved:Connect(onModelRemoved)
end

local function getPopupGui()
	if _popupGui and _popupGui.Parent then return _popupGui end
	local pg = player:FindFirstChild("PlayerGui")
	if not pg then return nil end
	local existing = pg:FindFirstChild("BrainrotPickupGui")
	if existing then _popupGui = existing; return existing end
	local sg = Instance.new("ScreenGui")
	sg.Name = "BrainrotPickupGui"
	sg.DisplayOrder = POPUP_DISPLAY_ORDER
	sg.IgnoreGuiInset = true
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Parent = pg
	_popupGui = sg
	return sg
end

local function dismissPopup()
	if not _activePopup or not _activePopup.Parent then return end
	local popup = _activePopup
	_activePopup = nil

	AnimUtil.PopupClose(popup, popup)
end

local function showPickupPopup(data)
	if not data then return end

	local gui = getPopupGui()
	if not gui then
		warn("[BrainrotPickup] Could not get popup ScreenGui")
		return
	end

	if _activePopup and _activePopup.Parent then
		_activePopup:Destroy()
		_activePopup = nil
	end

	local imageId = data.imageAssetId or ""
	local displayName = data.petName or "MISSING ITEM"
	local coinsAwarded = data.coins or 0
	local alreadyOwned = data.alreadyOwned or false
	local isNew = data.isNew

	local ownerText
	if isNew == true or alreadyOwned == false then
		ownerText = "NEW PET UNLOCKED!"
	else
		ownerText = "ALREADY OWNED (DUPLICATE)!"
	end

	print(string.format("[BrainrotPickup] Popup: %s | image=%s | coins=%d | owned=%s",
		displayName, imageId, coinsAwarded, tostring(alreadyOwned)))

	local card = Instance.new("Frame")
	card.Name = "BrainrotPopup"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.45)
	card.Size = UDim2.fromOffset(280, 340)
	card.BackgroundColor3 = Color3.fromRGB(22, 18, 38)
	card.BackgroundTransparency = 0.02
	card.BorderSizePixel = 0
	card.ZIndex = 51
	card.Parent = gui
	_activePopup = card

	Instance.new("UICorner", card).CornerRadius = UDim.new(0, 18)

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(178, 48, 255)
	stroke.Thickness = 2.5
	stroke.Transparency = 0.2
	stroke.Parent = card

	AnimUtil.PopupOpen(card)

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.AnchorPoint = Vector2.new(0.5, 0)
	title.Position = UDim2.new(0.5, 0, 0, 14)
	title.Size = UDim2.new(1, -20, 0, 28)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextColor3 = Color3.fromRGB(255, 215, 48)
	title.TextSize = 20
	title.Text = "BRAINROT COLLECTED!"
	title.ZIndex = 52
	title.Parent = card

	local titleStroke = Instance.new("UIStroke")
	titleStroke.Color = Color3.fromRGB(0, 0, 0)
	titleStroke.Thickness = 2
	titleStroke.Parent = title

	local hasStaticImage = imageId ~= "" and imageId ~= BRAINROT_FALLBACK_IMAGE
	local usedRenderer = false
	local modelPath = data.modelPath or ""

	if not hasStaticImage and modelPath ~= "" then
		local TR = getThumbnailRenderer()
		if TR then
			local vpFrame = Instance.new("ViewportFrame")
			vpFrame.Name = "BrainrotIcon"
			vpFrame.AnchorPoint = Vector2.new(0.5, 0)
			vpFrame.Position = UDim2.new(0.5, 0, 0, 50)
			vpFrame.Size = UDim2.fromOffset(110, 110)
			vpFrame.BackgroundColor3 = ICON_BG_COLOR
			vpFrame.BackgroundTransparency = 0
			vpFrame.ZIndex = 52
			vpFrame.Parent = card

			Instance.new("UICorner", vpFrame).CornerRadius = UDim.new(0, 14)
			local vpStroke = Instance.new("UIStroke")
			vpStroke.Color = ICON_STROKE_COLOR
			vpStroke.Thickness = ICON_STROKE_THICKNESS
			vpStroke.Transparency = ICON_STROKE_TRANSPARENCY
			vpStroke.Parent = vpFrame
			Instance.new("UIAspectRatioConstraint", vpFrame).AspectRatio = 1

			local renderOk = TR.RenderItemToViewport(vpFrame, {
				modelPath = modelPath,
				id = data.petId,
				name = displayName,
				type = "Pet",
				rarity = data.rarity or "Legendary",
			})
			if renderOk then
				usedRenderer = true
				print(string.format("[BrainrotPickup] ThumbnailRenderer used for: %s", modelPath))
			else
				warn(string.format("[BrainrotPickup] ThumbnailRenderer failed for: %s", modelPath))
				vpFrame:Destroy()
			end
		end
	end

	if not usedRenderer then
		if imageId == "" then imageId = BRAINROT_FALLBACK_IMAGE end
		local icon = Instance.new("ImageLabel")
		icon.Name = "BrainrotIcon"
		icon.AnchorPoint = Vector2.new(0.5, 0)
		icon.Position = UDim2.new(0.5, 0, 0, 50)
		icon.Size = UDim2.fromOffset(110, 110)
		icon.BackgroundColor3 = ICON_BG_COLOR
		icon.BackgroundTransparency = 0
		icon.Image = imageId
		icon.ImageTransparency = 0
		icon.ScaleType = Enum.ScaleType.Fit
		icon.ZIndex = 52
		icon.Parent = card

		Instance.new("UICorner", icon).CornerRadius = UDim.new(0, 14)
		local iconStroke = Instance.new("UIStroke")
		iconStroke.Color = ICON_STROKE_COLOR
		iconStroke.Thickness = ICON_STROKE_THICKNESS
		iconStroke.Transparency = ICON_STROKE_TRANSPARENCY
		iconStroke.Parent = icon
		Instance.new("UIAspectRatioConstraint", icon).AspectRatio = 1
	end

	local nameLbl = Instance.new("TextLabel")
	nameLbl.Name = "PetName"
	nameLbl.AnchorPoint = Vector2.new(0.5, 0)
	nameLbl.Position = UDim2.new(0.5, 0, 0, 170)
	nameLbl.Size = UDim2.new(1, -24, 0, 28)
	nameLbl.BackgroundTransparency = 1
	nameLbl.Font = Enum.Font.GothamBold
	nameLbl.TextColor3 = Color3.fromRGB(255, 255, 255)
	nameLbl.TextSize = 18
	nameLbl.Text = displayName
	nameLbl.TextWrapped = true
	nameLbl.ZIndex = 52
	nameLbl.Parent = card

	local nameStroke = Instance.new("UIStroke")
	nameStroke.Color = Color3.fromRGB(0, 0, 0)
	nameStroke.Thickness = 1.5
	nameStroke.Parent = nameLbl

	local coinsLbl = Instance.new("TextLabel")
	coinsLbl.Name = "CoinsLine"
	coinsLbl.AnchorPoint = Vector2.new(0.5, 0)
	coinsLbl.Position = UDim2.new(0.5, 0, 0, 202)
	coinsLbl.Size = UDim2.new(1, -24, 0, 24)
	coinsLbl.BackgroundTransparency = 1
	coinsLbl.Font = Enum.Font.GothamBold
	coinsLbl.TextColor3 = Color3.fromRGB(255, 215, 48)
	coinsLbl.TextSize = 18
	coinsLbl.Text = "+" .. tostring(coinsAwarded) .. " coins"
	coinsLbl.ZIndex = 52
	coinsLbl.Parent = card

	local coinsStroke = Instance.new("UIStroke")
	coinsStroke.Color = Color3.fromRGB(0, 0, 0)
	coinsStroke.Thickness = 1.5
	coinsStroke.Parent = coinsLbl

	local ownerLbl = Instance.new("TextLabel")
	ownerLbl.Name = "OwnerLine"
	ownerLbl.AnchorPoint = Vector2.new(0.5, 0)
	ownerLbl.Position = UDim2.new(0.5, 0, 0, 230)
	ownerLbl.Size = UDim2.new(1, -24, 0, 22)
	ownerLbl.BackgroundTransparency = 1
	ownerLbl.Font = Enum.Font.GothamSemibold
	ownerLbl.TextSize = 14
	ownerLbl.TextWrapped = true
	ownerLbl.ZIndex = 52
	ownerLbl.Parent = card

	if alreadyOwned then
		ownerLbl.TextColor3 = Color3.fromRGB(255, 180, 40)
		ownerLbl.Text = ownerText
	else
		ownerLbl.TextColor3 = Color3.fromRGB(80, 255, 120)
		ownerLbl.Text = ownerText
	end

	local ownerStroke = Instance.new("UIStroke")
	ownerStroke.Color = Color3.fromRGB(0, 0, 0)
	ownerStroke.Thickness = 1
	ownerStroke.Parent = ownerLbl

	local rarLbl = Instance.new("TextLabel")
	rarLbl.Name = "Rarity"
	rarLbl.AnchorPoint = Vector2.new(0.5, 0)
	rarLbl.Position = UDim2.new(0.5, 0, 0, 256)
	rarLbl.Size = UDim2.new(1, -24, 0, 18)
	rarLbl.BackgroundTransparency = 1
	rarLbl.Font = Enum.Font.GothamSemibold
	rarLbl.TextColor3 = Color3.fromRGB(255, 198, 18)
	rarLbl.TextSize = 13
	rarLbl.Text = data.rarity or "Legendary"
	rarLbl.ZIndex = 52
	rarLbl.Parent = card

	local okBtn = Instance.new("TextButton")
	okBtn.Name = "OkBtn"
	okBtn.AnchorPoint = Vector2.new(0.5, 1)
	okBtn.Position = UDim2.new(0.5, 0, 1, -14)
	okBtn.Size = UDim2.new(1, -50, 0, 38)
	okBtn.BackgroundColor3 = Color3.fromRGB(178, 48, 255)
	okBtn.Font = Enum.Font.GothamBold
	okBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	okBtn.TextSize = 16
	okBtn.Text = "NICE!"
	okBtn.BorderSizePixel = 0
	okBtn.AutoButtonColor = true
	okBtn.ZIndex = 52
	okBtn.Parent = card

	Instance.new("UICorner", okBtn).CornerRadius = UDim.new(0, 10)
	okBtn.MouseButton1Click:Connect(dismissPopup)

	local thisPopup = card
	task.delay(POPUP_DURATION, function()
		if _activePopup == thisPopup then
			dismissPopup()
		end
	end)
end

function BrainrotPickupController.Init()
	if initialized then return end
	initialized = true

	task.spawn(function()
		local folder = Workspace:WaitForChild(FOLDER_NAME, 60)
		if folder then
			watchFolder(folder)
			print("[BrainrotPickup] Watching folder")
		else
			local conn
			conn = Workspace.ChildAdded:Connect(function(child)
				if child.Name == FOLDER_NAME and child:IsA("Folder") then
					watchFolder(child)
					print("[BrainrotPickup] Folder appeared -- watching")
					if conn then conn:Disconnect() end
				end
			end)
		end
	end)

	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
		if not remotes then return end

		local collectRemote = remotes:WaitForChild("BrainrotCollected", 15)
		if not collectRemote then return end

		collectRemote.OnClientEvent:Connect(function(data)
			if data then
				showPickupPopup(data)
			end
		end)

		print("[BrainrotPickup] Connected to BrainrotCollected remote")
	end)

	task.spawn(function()
		local Shared = ReplicatedStorage:FindFirstChild("Shared")
		if not Shared then return end
		local IC = nil
		pcall(function() IC = require(Shared:WaitForChild("ItemCatalog", 5)) end)
		if not IC or not IC.Pets then return end

		for id, pet in pairs(IC.Pets) do
			if pet.source == "brainrot_mode" then
				if pet.image and pet.image ~= "" then
					print(string.format("[ImageRules] STATIC: %s -> %s", id, pet.image))
				elseif pet.modelPath and pet.modelPath ~= "" then
					print(string.format("[ImageRules] RENDERER: %s -> %s", id, pet.modelPath))
				else
					print(string.format("[ImageRules] PLACEHOLDER: %s -> %s", id, BRAINROT_FALLBACK_IMAGE))
				end
			end
		end
	end)

	print("[BrainrotPickupController] Initialized")
end

return BrainrotPickupController
