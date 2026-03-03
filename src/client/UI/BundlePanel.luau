--[[
	BundlePanel
	Hero-style bundle content rendered INSIDE ShopPanel's content area.

	Not a standalone panel — populates into a parent ScrollingFrame when
	the Bundles tab is selected, and clears itself when another tab is chosen.
	This keeps the ShopPanel tab bar visible and clickable at all times.

	Layout:
	  * Left 68%: Hero cover art + title overlay + View/Buy buttons
	  * Right 30%: Vertical selector strip listing all bundles
	  * Detail View: Replaces hero area with item grid on "View" click

	Data-driven via BundleCatalog — supports future bundles automatically.

	API:
	  BundlePanel.Init()                    — no-op (modules loaded at require time)
	  BundlePanel.PopulateInto(parent)      — build bundle UI inside parent
	  BundlePanel.ClearContent()            — destroy bundle UI, restore parent
	  BundlePanel.Show/Hide/IsVisible/Toggle — stubs for compatibility
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ContentProvider = game:GetService("ContentProvider")
local HttpService = game:GetService("HttpService")

local STUB = {
	Init = function() end,
	PopulateInto = function() end,
	ClearContent = function() end,
	Show = function() end,
	Hide = function() end,
	IsVisible = function() return false end,
	Toggle = function() end,
}

local Shared = ReplicatedStorage:WaitForChild("Shared", 60)
if not Shared then
	warn("[BundlePanel] Shared not found after 60s -- disabled")
	return STUB
end

local CDPModule = Shared:WaitForChild("ClientDepsProvider", 60)
if not CDPModule then
	warn("[BundlePanel] ClientDepsProvider MISSING")
	return STUB
end

local ok, Deps = pcall(require, CDPModule)
if not ok or not Deps then
	warn("[BundlePanel] require(ClientDepsProvider) FAILED:", Deps)
	return STUB
end

local UIConfig = Deps.UIConfig
local ItemCatalog = Deps.ItemCatalog

local BundleCatalogModule = Shared:WaitForChild("BundleCatalog", 10)
if not BundleCatalogModule then
	warn("[BundlePanel] BundleCatalog not found in Shared")
	return STUB
end
local BundleCatalog = require(BundleCatalogModule)

local ItemModelRegistryModule = Shared:WaitForChild("ItemModelRegistry", 10)
local ItemModelRegistry = ItemModelRegistryModule and require(ItemModelRegistryModule) or nil

local Client = script.Parent
local AnimUtil   = require(Client:WaitForChild("AnimUtil"))
local SoundUtil  = require(Client:WaitForChild("SoundUtil"))
local Components = require(Client:WaitForChild("Components"))

local C = UIConfig.Colors
local S = UIConfig.Sizes

local LocalPlayer = Players.LocalPlayer
local FNAF_BUNDLE_ID = "fnaf_pets_bundle"
local FNAF_BUNDLE_COST_COINS = 150000

local ACCENT_COLOR   = Color3.fromRGB(245, 48, 72)
local SELECTED_GLOW  = Color3.fromRGB(255, 210, 50)
local BG_DARK        = Color3.fromRGB(22, 24, 42)
local BG_LIGHTER     = Color3.fromRGB(36, 40, 64)
local COVER_BG       = Color3.fromRGB(10, 12, 24)
local STRIP_BG       = Color3.fromRGB(18, 20, 38)
local ENTRY_SELECTED = Color3.fromRGB(44, 48, 78)

local contentParent: ScrollingFrame? = nil
local bundleContainer: Frame? = nil
local selectedBundleId: string = ""
local _bundleOwnedLocal: { [string]: boolean } = {}
local inDetailView = false

local coverImage: ImageLabel? = nil
local titleLabel: TextLabel? = nil
local viewBtn: TextButton? = nil
local buyBtn: TextButton? = nil
local heroFrame: Frame? = nil
local detailFrame: Frame? = nil
local selectorStrip: ScrollingFrame? = nil
local selectorEntries: { [string]: Frame } = {}

local previewOverlay: Frame? = nil
local previewRotConn: RBXScriptConnection? = nil
local externalPreviewHost: Instance? = nil
local panelOptions: {[string]: any}? = nil

local function getBundlesForPanel()
	local bundles = BundleCatalog.GetAll()
	if not panelOptions or not panelOptions.bundleIds then
		return bundles
	end
	local allow = {}
	for _, id in ipairs(panelOptions.bundleIds) do
		allow[id] = true
	end
	local filtered = {}
	for _, bundle in ipairs(bundles) do
		if allow[bundle.id] then
			table.insert(filtered, bundle)
		end
	end
	return filtered
end

local function createStyledButton(parent: Instance, text: string, color: Color3, size: UDim2, position: UDim2): TextButton
	local btn = Instance.new("TextButton")
	btn.Name = text:gsub("%s", "") .. "Btn"
	btn.Size = size
	btn.Position = position
	btn.BackgroundColor3 = color
	btn.Font = Enum.Font.GothamBold
	btn.TextColor3 = Color3.fromRGB(255, 255, 255)
	btn.TextTransparency = 0
	btn.TextSize = 18
	btn.Text = text
	btn.BorderSizePixel = 0
	btn.AutoButtonColor = false
	btn.ZIndex = 8
	btn.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = btn

	local borderStroke = Instance.new("UIStroke")
	borderStroke.Color = Color3.fromRGB(255, 255, 255)
	borderStroke.Thickness = 1.5
	borderStroke.Transparency = 0.35
	borderStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	borderStroke.Parent = btn

	local textStroke = Instance.new("UIStroke")
	textStroke.Color = Color3.fromRGB(0, 0, 0)
	textStroke.Thickness = 2
	textStroke.Transparency = 0.05
	textStroke.Parent = btn

	return btn
end

local function updateSelectorHighlight()
	for id, entry in pairs(selectorEntries) do
		local entryStroke = entry:FindFirstChildOfClass("UIStroke")
		if id == selectedBundleId then
			if entryStroke then
				entryStroke.Color = SELECTED_GLOW
				entryStroke.Thickness = 2.5
				entryStroke.Transparency = 0
			end
			entry.BackgroundColor3 = ENTRY_SELECTED
		else
			if entryStroke then
				entryStroke.Color = C.CardStroke
				entryStroke.Thickness = 1.5
				entryStroke.Transparency = 0.3
			end
			entry.BackgroundColor3 = C.CardBg
		end
	end
end

local function selectBundle(bundleId: string)
	local bundle = BundleCatalog.Get(bundleId)
	if not bundle then return end

	selectedBundleId = bundleId

	if coverImage then
		if bundle.coverImage and bundle.coverImage ~= "" then
			coverImage.Image = bundle.coverImage
			coverImage.Visible = true
		else
			coverImage.Image = ""
			coverImage.Visible = false
		end
	end

	if titleLabel then
		titleLabel.Text = bundle.displayName
	end

	if buyBtn then
		local isFnafCoinBundle = (bundle.id == FNAF_BUNDLE_ID)
		local isOwned = _bundleOwnedLocal[bundle.id] == true
		if bundle.gamepassId and not isFnafCoinBundle then
			local okChk, ownsChk = pcall(function()
				return MarketplaceService:UserOwnsGamePassAsync(LocalPlayer.UserId, bundle.gamepassId)
			end)
			isOwned = okChk and ownsChk == true
		end

		if isOwned then
			buyBtn.Text = "OWNED"
			buyBtn.BackgroundColor3 = C.DisabledBtn
			buyBtn.Active = false
		elseif not bundle.isAvailable then
			buyBtn.Text = "COMING SOON"
			buyBtn.BackgroundColor3 = C.DisabledBtn
			buyBtn.Active = false
		else
			if isFnafCoinBundle then
				buyBtn.Text = "BUY - 150K F"
				buyBtn.BackgroundColor3 = Color3.fromRGB(255, 200, 30)
			else
				buyBtn.Text = string.format("BUY - %d ROBUX", bundle.priceRobux)
				buyBtn.BackgroundColor3 = C.BuyButton
			end
			buyBtn.Active = true
		end
	end

	if viewBtn then
		local canView = bundle.isAvailable and #bundle.includes > 0
		viewBtn.Active = canView
		viewBtn.BackgroundColor3 = canView and C.Blue or C.DisabledBtn
	end

	updateSelectorHighlight()

	if inDetailView then
		if heroFrame then heroFrame.Visible = true end
		if detailFrame then detailFrame.Visible = false end
		inDetailView = false
	end
end

local function clearDetailGrid()
	if not detailFrame then return end
	for _, child in ipairs(detailFrame:GetChildren()) do
		if child:IsA("ScrollingFrame") then
			child:Destroy()
		end
	end
end

-- ═══════════════════════════════════════════════════════════════════
-- VIEWPORT PREVIEW HELPERS
-- ═══════════════════════════════════════════════════════════════════

local MIN_CAM_DIST = 4
local CAM_FOV = 50

local function cloneForViewport(modelInstance: Instance): Instance
	local clone = modelInstance:Clone()
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("Script") or d:IsA("LocalScript") or d:IsA("ModuleScript") then
			d:Destroy()
		elseif d:IsA("Humanoid") or d:IsA("Animator") or d:IsA("AnimationController") then
			d:Destroy()
		elseif d:IsA("ParticleEmitter") then
			d.Enabled = false
		elseif d:IsA("Trail") then
			d.Enabled = false
		elseif d:IsA("Beam") then
			d.Enabled = false
		elseif d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
		end
	end
	if clone:IsA("BasePart") then
		clone.Anchored = true
		clone.CanCollide = false
	end
	return clone
end

local function getVisibleBounds(root: Instance): (Vector3, Vector3, number)
	local minB = Vector3.new(math.huge, math.huge, math.huge)
	local maxB = Vector3.new(-math.huge, -math.huge, -math.huge)
	local count = 0
	local function addPart(p: BasePart)
		if p.Transparency >= 1 then return end
		count += 1
		local cf = p.CFrame
		local sz = p.Size
		for _, sxm in ipairs({-0.5, 0.5}) do
			for _, sym in ipairs({-0.5, 0.5}) do
				for _, szm in ipairs({-0.5, 0.5}) do
					local corner = cf:PointToWorldSpace(Vector3.new(sz.X * sxm, sz.Y * sym, sz.Z * szm))
					minB = Vector3.new(math.min(minB.X, corner.X), math.min(minB.Y, corner.Y), math.min(minB.Z, corner.Z))
					maxB = Vector3.new(math.max(maxB.X, corner.X), math.max(maxB.Y, corner.Y), math.max(maxB.Z, corner.Z))
				end
			end
		end
	end
	if root:IsA("BasePart") then addPart(root) end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then addPart(d) end
	end
	if count == 0 then
		return Vector3.zero, Vector3.new(2, 2, 2), 0
	end
	return minB, maxB, count
end

local function pivotToOrigin(root: Instance)
	local minB, maxB = getVisibleBounds(root)
	local center = (minB + maxB) / 2
	if center.Magnitude < 0.001 then return end
	if root:IsA("BasePart") then
		root.CFrame = root.CFrame - center
	end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			d.CFrame = d.CFrame - center
		end
	end
end

local function setupPreviewCamera(viewport: ViewportFrame, model: Instance)
	local minB, maxB = getVisibleBounds(model)
	local center = (minB + maxB) / 2
	local extents = maxB - minB
	local maxDim = math.max(extents.X, extents.Y, extents.Z, 0.1)
	local distance = math.max(maxDim * 1.8, MIN_CAM_DIST)
	local camPos = center + Vector3.new(distance * 0.5, distance * 0.35, distance * 0.8)

	local cam = Instance.new("Camera")
	cam.CameraType = Enum.CameraType.Scriptable
	cam.CFrame = CFrame.lookAt(camPos, center)
	cam.FieldOfView = CAM_FOV
	cam.Parent = viewport
	viewport.CurrentCamera = cam
end

-- ═══════════════════════════════════════════════════════════════════
-- ITEM PREVIEW OVERLAY
-- ═══════════════════════════════════════════════════════════════════

local function closeItemPreview()
	if previewRotConn then
		previewRotConn:Disconnect()
		previewRotConn = nil
	end
	if previewOverlay then
		previewOverlay:Destroy()
		previewOverlay = nil
	end
end

local function showFallbackPreview(card: Frame, itemData)
	local fallbackImg = Instance.new("ImageLabel")
	fallbackImg.Name = "FallbackImage"
	fallbackImg.Size = UDim2.new(0.7, 0, 0.7, 0)
	fallbackImg.AnchorPoint = Vector2.new(0.5, 0.5)
	fallbackImg.Position = UDim2.new(0.5, 0, 0.5, 10)
	fallbackImg.BackgroundTransparency = 1
	fallbackImg.ScaleType = Enum.ScaleType.Fit
	fallbackImg.ZIndex = 53
	fallbackImg.Parent = card

	if itemData.image and itemData.image ~= "" then
		fallbackImg.Image = itemData.image
	else
		fallbackImg.Visible = false
		local noLbl = Instance.new("TextLabel")
		noLbl.Size = UDim2.new(0.8, 0, 0, 30)
		noLbl.AnchorPoint = Vector2.new(0.5, 0.5)
		noLbl.Position = UDim2.fromScale(0.5, 0.55)
		noLbl.BackgroundTransparency = 1
		noLbl.Font = Enum.Font.GothamBold
		noLbl.TextColor3 = Color3.fromRGB(130, 140, 170)
		noLbl.TextSize = 16
		noLbl.Text = "Preview unavailable"
		noLbl.ZIndex = 53
		noLbl.Parent = card
	end
end

local function showItemPreview(itemData)
	closeItemPreview()
	local previewHost = bundleContainer or externalPreviewHost
	if not previewHost then return end

	local itemName = itemData.name or "unknown"
	local modelPath = itemData.modelPath

	warn(string.format("[BundlePanel:Preview] item='%s' modelPath=%s registry=%s",
		itemName, tostring(modelPath), tostring(ItemModelRegistry ~= nil)))

	local modelInstance = nil
	if modelPath and ItemModelRegistry then
		modelInstance = ItemModelRegistry.Get(modelPath)
		if modelInstance then
			warn(string.format("[BundlePanel:Preview] Resolved: class=%s name='%s' descendants=%d",
				modelInstance.ClassName, modelInstance.Name, #modelInstance:GetDescendants()))
		else
			warn(string.format("[BundlePanel:Preview] Registry returned nil for '%s'", modelPath))
		end
	end

	previewOverlay = Instance.new("Frame")
	previewOverlay.Name = "ItemPreviewOverlay"
	previewOverlay.Size = UDim2.fromScale(1, 1)
	previewOverlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	previewOverlay.BackgroundTransparency = 0.35
	previewOverlay.BorderSizePixel = 0
	previewOverlay.ZIndex = 50
	previewOverlay.Parent = previewHost

	local dimBtn = Instance.new("TextButton")
	dimBtn.Name = "DimClose"
	dimBtn.Size = UDim2.fromScale(1, 1)
	dimBtn.BackgroundTransparency = 1
	dimBtn.Text = ""
	dimBtn.ZIndex = 50
	dimBtn.Parent = previewOverlay
	dimBtn.MouseButton1Click:Connect(function()
		SoundUtil.Close()
		closeItemPreview()
	end)

	local card = Instance.new("Frame")
	card.Name = "PreviewCard"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Size = UDim2.new(0.55, 0, 0.8, 0)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.BackgroundColor3 = Color3.fromRGB(22, 24, 42)
	card.BackgroundTransparency = 0
	card.BorderSizePixel = 0
	card.ZIndex = 52
	card.Parent = previewOverlay

	local cardCorner = Instance.new("UICorner")
	cardCorner.CornerRadius = UDim.new(0, 14)
	cardCorner.Parent = card

	local cardStroke = Instance.new("UIStroke")
	cardStroke.Color = SELECTED_GLOW
	cardStroke.Thickness = 2
	cardStroke.Transparency = 0.1
	cardStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	cardStroke.Parent = card

	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, 44)
	header.BackgroundTransparency = 1
	header.BorderSizePixel = 0
	header.ZIndex = 53
	header.Parent = card

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "ItemName"
	nameLabel.Size = UDim2.new(1, -60, 0, 36)
	nameLabel.Position = UDim2.fromOffset(14, 4)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	nameLabel.TextTransparency = 0
	nameLabel.TextSize = 20
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
	nameLabel.Text = itemName
	nameLabel.ZIndex = 54
	nameLabel.Parent = header

	local nameStroke = Instance.new("UIStroke")
	nameStroke.Color = Color3.fromRGB(0, 0, 0)
	nameStroke.Thickness = 2
	nameStroke.Transparency = 0.1
	nameStroke.Parent = nameLabel

	local closeBtn = createStyledButton(
		header, "X", C.CloseBtn,
		UDim2.fromOffset(36, 36),
		UDim2.new(1, -42, 0, 4)
	)
	closeBtn.ZIndex = 55
	closeBtn.TextSize = 16
	AnimUtil.WireButton(closeBtn, function()
		SoundUtil.Close()
		closeItemPreview()
	end)

	local hasCoinPurchase = panelOptions
		and panelOptions.itemCoinPrice
		and itemData.itemId
		and itemData.itemType

	local purchaseBtn: TextButton? = nil
	if hasCoinPurchase then
		purchaseBtn = createStyledButton(
			card,
			string.format("BUY - %dK F", math.floor(panelOptions.itemCoinPrice / 1000)),
			Color3.fromRGB(255, 200, 30),
			UDim2.new(1, -20, 0, 42),
			UDim2.new(0, 10, 1, -50)
		)
		purchaseBtn.ZIndex = 55

		local function isOwned(): boolean
			local attrKey = (itemData.itemType == "ExclusivePet") and "OwnedPets" or "OwnedCrowns"
			local raw = LocalPlayer:GetAttribute(attrKey)
			if type(raw) ~= "string" or raw == "" then return false end
			local okDec, list = pcall(HttpService.JSONDecode, HttpService, raw)
			if not okDec or type(list) ~= "table" then return false end
			for _, id in ipairs(list) do
				if id == itemData.itemId then return true end
			end
			return false
		end

		local function refreshPurchaseState()
			if not purchaseBtn then return end
			if isOwned() then
				purchaseBtn.Text = "OWNED"
				purchaseBtn.BackgroundColor3 = C.DisabledBtn
				purchaseBtn.Active = false
			else
				purchaseBtn.Text = string.format("BUY - %dK F", math.floor(panelOptions.itemCoinPrice / 1000))
				purchaseBtn.BackgroundColor3 = Color3.fromRGB(255, 200, 30)
				purchaseBtn.Active = true
			end
		end

		refreshPurchaseState()
		AnimUtil.WireButton(purchaseBtn, function()
			if not purchaseBtn or not purchaseBtn.Active then return end
			SoundUtil.Click()
			local remotes = ReplicatedStorage:FindFirstChild("Remotes")
			local buyRF = remotes and remotes:FindFirstChild("Shop_BuyWithCoins")
			if not buyRF then return end
			local okBuy, result = pcall(buyRF.InvokeServer, buyRF, itemData.itemId, itemData.itemType)
			if okBuy and result and result.success then
				refreshPurchaseState()
				if panelOptions and panelOptions.onItemPurchased then
					pcall(panelOptions.onItemPurchased, itemData.itemId)
				end
			end
		end)
	end

	if not modelInstance then
		warn("[BundlePanel:Preview] No model — showing fallback for", itemName)
		showFallbackPreview(card, itemData)
		return
	end

	local clone = cloneForViewport(modelInstance)

	if clone:IsA("Accessory") then
		warn("[BundlePanel:Preview] Unwrapping Accessory")
		local wrapper = Instance.new("Model")
		wrapper.Name = clone.Name
		for _, child in ipairs(clone:GetChildren()) do
			child.Parent = wrapper
		end
		local handle = wrapper:FindFirstChild("Handle")
		if handle and handle:IsA("BasePart") then
			wrapper.PrimaryPart = handle
		end
		clone:Destroy()
		clone = wrapper
	end

	pivotToOrigin(clone)

	local minB, maxB, partCount = getVisibleBounds(clone)
	warn(string.format("[BundlePanel:Preview] Clone ready: %d visible BaseParts, bounds min=%s max=%s",
		partCount, tostring(minB), tostring(maxB)))

	if partCount == 0 then
		warn("[BundlePanel:Preview] No visible BaseParts — showing fallback")
		showFallbackPreview(card, itemData)
		clone:Destroy()
		return
	end

	local vpFrame = Instance.new("ViewportFrame")
	vpFrame.Name = "ModelPreview"
	vpFrame.Size = hasCoinPurchase and UDim2.new(1, -20, 1, -110) or UDim2.new(1, -20, 1, -54)
	vpFrame.Position = UDim2.fromOffset(10, 48)
	vpFrame.BackgroundColor3 = Color3.fromRGB(14, 16, 32)
	vpFrame.BackgroundTransparency = 0
	vpFrame.BorderSizePixel = 0
	vpFrame.ZIndex = 53
	vpFrame.Parent = card

	local vpCorner = Instance.new("UICorner")
	vpCorner.CornerRadius = UDim.new(0, 10)
	vpCorner.Parent = vpFrame

	local worldModel = Instance.new("WorldModel")
	worldModel.Parent = vpFrame

	clone.Parent = worldModel
	setupPreviewCamera(vpFrame, clone)

	task.spawn(function()
		ContentProvider:PreloadAsync(clone:GetDescendants())
	end)

	local center = (minB + maxB) / 2
	local extents = maxB - minB
	local maxDim = math.max(extents.X, extents.Y, extents.Z, 0.1)
	local baseDist = math.max(maxDim * 1.8, MIN_CAM_DIST)
	local angle = 0

	previewRotConn = RunService.RenderStepped:Connect(function(dt)
		angle = angle + dt * 30
		local rad = math.rad(angle)
		local camPos = center + Vector3.new(
			math.sin(rad) * baseDist * 0.8,
			baseDist * 0.35,
			math.cos(rad) * baseDist * 0.8
		)
		local cam = vpFrame.CurrentCamera
		if cam then
			cam.CFrame = CFrame.lookAt(camPos, center)
		end
	end)
end

-- ═══════════════════════════════════════════════════════════════════
-- DETAIL VIEW
-- ═══════════════════════════════════════════════════════════════════

local function showDetailView()
	local bundle = BundleCatalog.Get(selectedBundleId)
	if not bundle or #bundle.includes == 0 then return end

	inDetailView = true
	if heroFrame then heroFrame.Visible = false end
	if detailFrame then
		clearDetailGrid()
		detailFrame.Visible = true
	end

	local gridFrame = Instance.new("ScrollingFrame")
	gridFrame.Name = "IncludesGrid"
	gridFrame.Size = UDim2.new(1, 0, 1, -50)
	gridFrame.Position = UDim2.fromOffset(0, 46)
	gridFrame.BackgroundTransparency = 1
	gridFrame.BorderSizePixel = 0
	gridFrame.ScrollBarThickness = 4
	gridFrame.ScrollBarImageColor3 = Color3.fromRGB(75, 82, 108)
	gridFrame.CanvasSize = UDim2.fromScale(0, 0)
	gridFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	gridFrame.ScrollingDirection = Enum.ScrollingDirection.Y
	gridFrame.ZIndex = 12
	gridFrame.Parent = detailFrame

	Components.AddGridLayout(gridFrame, Vector2.new(S.CardWidth, S.CardHeight), S.CardPad)

	for i, inc in ipairs(bundle.includes) do
		local itemData = ItemCatalog.Get(inc.category, inc.itemId)
		if not itemData then
			warn("[BundlePanel] Missing catalog entry:", inc.category, inc.itemId)
			continue
		end

		local cardData = {
			name = itemData.name or inc.itemId,
			rarity = itemData.rarity or "Common",
			iconColor = itemData.iconColor,
			iconText = itemData.iconText,
			image = ItemCatalog.GetImage and ItemCatalog.GetImage(itemData) or itemData.image or "",
			modelPath = itemData.modelPath,
			itemId = inc.itemId,
			itemType = panelOptions and panelOptions.itemType or nil,
			coinPrice = panelOptions and panelOptions.itemCoinPrice or nil,
		}

		local card = Components.CreateItemCard(gridFrame, cardData)
		card.LayoutOrder = i

		local clickOverlay = Instance.new("TextButton")
		clickOverlay.Name = "PreviewClick"
		clickOverlay.Size = UDim2.fromScale(1, 1)
		clickOverlay.BackgroundTransparency = 1
		clickOverlay.Text = ""
		clickOverlay.ZIndex = 20
		clickOverlay.Parent = card
		clickOverlay.MouseButton1Click:Connect(function()
			SoundUtil.Click()
			showItemPreview(cardData)
		end)
	end
end

local function hideDetailView()
	inDetailView = false
	if heroFrame then heroFrame.Visible = true end
	if detailFrame then detailFrame.Visible = false end
end

local BundlePanel = {}

function BundlePanel.Init()
end

function BundlePanel.PopulateInto(parent: ScrollingFrame, options)
	BundlePanel.ClearContent()
	contentParent = parent
	panelOptions = options or nil

	for _, child in ipairs(parent:GetChildren()) do
		if child:IsA("UIGridLayout") then
			child:Destroy()
		end
	end

	parent.AutomaticCanvasSize = Enum.AutomaticSize.None
	parent.CanvasSize = UDim2.fromScale(0, 0)
	parent.ScrollBarThickness = 0
	parent.ScrollingDirection = Enum.ScrollingDirection.XY

	bundleContainer = Instance.new("Frame")
	bundleContainer.Name = "BundleContent"
	bundleContainer.Size = UDim2.fromScale(1, 1)
	bundleContainer.BackgroundColor3 = BG_DARK
	bundleContainer.BackgroundTransparency = 0.1
	bundleContainer.BorderSizePixel = 0
	bundleContainer.ZIndex = 4
	bundleContainer.Parent = parent

	local containerCorner = Instance.new("UICorner")
	containerCorner.CornerRadius = UDim.new(0, 10)
	containerCorner.Parent = bundleContainer

	local bgGrad = Instance.new("UIGradient")
	bgGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, BG_DARK),
		ColorSequenceKeypoint.new(1, BG_LIGHTER),
	})
	bgGrad.Rotation = 110
	bgGrad.Parent = bundleContainer

	heroFrame = Instance.new("Frame")
	heroFrame.Name = "HeroArea"
	heroFrame.Size = UDim2.new(0.68, -8, 1, -8)
	heroFrame.Position = UDim2.fromOffset(4, 4)
	heroFrame.BackgroundTransparency = 1
	heroFrame.BorderSizePixel = 0
	heroFrame.ZIndex = 5
	heroFrame.Parent = bundleContainer

	local coverContainer = Instance.new("Frame")
	coverContainer.Name = "CoverContainer"
	coverContainer.Size = UDim2.new(1, 0, 1, -56)
	coverContainer.Position = UDim2.fromOffset(0, 0)
	coverContainer.BackgroundColor3 = COVER_BG
	coverContainer.BorderSizePixel = 0
	coverContainer.ClipsDescendants = true
	coverContainer.ZIndex = 5
	coverContainer.Parent = heroFrame

	local ccCorner = Instance.new("UICorner")
	ccCorner.CornerRadius = UDim.new(0, 12)
	ccCorner.Parent = coverContainer

	local ccStroke = Instance.new("UIStroke")
	ccStroke.Color = ACCENT_COLOR
	ccStroke.Thickness = 2
	ccStroke.Transparency = 0.2
	ccStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	ccStroke.Parent = coverContainer

	coverImage = Instance.new("ImageLabel")
	coverImage.Name = "CoverImage"
	coverImage.Size = UDim2.fromScale(1, 1)
	coverImage.Position = UDim2.fromScale(0, 0)
	coverImage.BackgroundTransparency = 1
	coverImage.ScaleType = Enum.ScaleType.Crop
	coverImage.ZIndex = 6
	coverImage.Parent = coverContainer

	local titleBg = Instance.new("Frame")
	titleBg.Name = "TitleGradientBg"
	titleBg.Size = UDim2.new(1, 0, 0, 60)
	titleBg.Position = UDim2.fromScale(0, 0)
	titleBg.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	titleBg.BackgroundTransparency = 0.3
	titleBg.BorderSizePixel = 0
	titleBg.ZIndex = 7
	titleBg.Parent = coverContainer

	local titleBgGrad = Instance.new("UIGradient")
	titleBgGrad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	titleBgGrad.Rotation = 90
	titleBgGrad.Parent = titleBg

	titleLabel = Instance.new("TextLabel")
	titleLabel.Name = "TitleLabel"
	titleLabel.AnchorPoint = Vector2.new(0, 0)
	titleLabel.Position = UDim2.fromOffset(14, 12)
	titleLabel.Size = UDim2.new(0.8, 0, 0, 36)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Font = Enum.Font.GothamBold
	titleLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	titleLabel.TextTransparency = 0
	titleLabel.TextSize = 28
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.TextYAlignment = Enum.TextYAlignment.Top
	titleLabel.Text = ""
	titleLabel.ZIndex = 9
	titleLabel.Parent = coverContainer

	local titleStroke = Instance.new("UIStroke")
	titleStroke.Color = Color3.fromRGB(0, 0, 0)
	titleStroke.Thickness = 2.5
	titleStroke.Transparency = 0.05
	titleStroke.Parent = titleLabel

	local btnRow = Instance.new("Frame")
	btnRow.Name = "ButtonRow"
	btnRow.Size = UDim2.new(1, 0, 0, 50)
	btnRow.AnchorPoint = Vector2.new(0, 1)
	btnRow.Position = UDim2.new(0, 0, 1, 0)
	btnRow.BackgroundTransparency = 1
	btnRow.BorderSizePixel = 0
	btnRow.ZIndex = 7
	btnRow.Parent = heroFrame

	viewBtn = createStyledButton(
		btnRow, "VIEW", C.Blue,
		UDim2.new(0.48, 0, 0, 42),
		UDim2.fromOffset(0, 4)
	)
	AnimUtil.WireButton(viewBtn, function()
		SoundUtil.Click()
		showDetailView()
	end)

	buyBtn = createStyledButton(
		btnRow, "BUY", C.BuyButton,
		UDim2.new(0.48, 0, 0, 42),
		UDim2.new(0.52, 0, 0, 4)
	)
	AnimUtil.WireButton(buyBtn, function()
		SoundUtil.Click()
		local bundle = BundleCatalog.Get(selectedBundleId)
		if not bundle then return end
		if not bundle.isAvailable then return end
		if bundle.id == FNAF_BUNDLE_ID then
			local remotes = ReplicatedStorage:FindFirstChild("Remotes")
			local buyRF = remotes and remotes:FindFirstChild("Shop_BuyWithCoins")
			if not buyRF then
				warn("[BundlePanel] Shop_BuyWithCoins remote missing for FNAF bundle")
				return
			end
			local okBuy, result = pcall(buyRF.InvokeServer, buyRF, "fnaf_all", "Bundle")
			if okBuy and result and result.success then
				selectBundle(selectedBundleId)
			elseif okBuy and result and result.reason == "INSUFFICIENT_COINS" then
				local productId = tonumber(result.productId)
				if productId and productId > 0 then
					MarketplaceService:PromptProductPurchase(LocalPlayer, productId)
				else
					warn("[BundlePanel] Missing top-up productId for insufficient FNAF coins")
				end
			elseif okBuy and result and result.reason == "ALREADY_OWNED" then
				_bundleOwnedLocal[FNAF_BUNDLE_ID] = true
				selectBundle(selectedBundleId)
			end
		elseif bundle.gamepassId then
			MarketplaceService:PromptGamePassPurchase(LocalPlayer, bundle.gamepassId)
		elseif bundle.productId then
			MarketplaceService:PromptProductPurchase(LocalPlayer, bundle.productId)
		else
			print(string.format("[BundlePanel] Buy clicked: %s (%d ROBUX) -- no purchase ID set",
				bundle.id, bundle.priceRobux))
		end
	end)

	detailFrame = Instance.new("Frame")
	detailFrame.Name = "DetailView"
	detailFrame.Size = UDim2.new(0.68, -8, 1, -8)
	detailFrame.Position = UDim2.fromOffset(4, 4)
	detailFrame.BackgroundColor3 = Color3.fromRGB(20, 22, 40)
	detailFrame.BackgroundTransparency = 0.1
	detailFrame.BorderSizePixel = 0
	detailFrame.Visible = false
	detailFrame.ZIndex = 10
	detailFrame.Parent = bundleContainer

	local dfCorner = Instance.new("UICorner")
	dfCorner.CornerRadius = UDim.new(0, 12)
	dfCorner.Parent = detailFrame

	local detailHeader = Instance.new("Frame")
	detailHeader.Name = "DetailHeader"
	detailHeader.Size = UDim2.new(1, 0, 0, 42)
	detailHeader.BackgroundTransparency = 1
	detailHeader.ZIndex = 11
	detailHeader.Parent = detailFrame

	local backBtn = createStyledButton(
		detailHeader, "BACK", C.CloseBtn,
		UDim2.fromOffset(80, 34),
		UDim2.fromOffset(8, 4)
	)
	AnimUtil.WireButton(backBtn, function()
		SoundUtil.Click()
		hideDetailView()
	end)

	local detailTitle = Instance.new("TextLabel")
	detailTitle.Name = "DetailTitle"
	detailTitle.Size = UDim2.new(1, -100, 0, 34)
	detailTitle.Position = UDim2.fromOffset(96, 4)
	detailTitle.BackgroundTransparency = 1
	detailTitle.Font = Enum.Font.GothamBold
	detailTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
	detailTitle.TextTransparency = 0
	detailTitle.TextSize = 18
	detailTitle.TextXAlignment = Enum.TextXAlignment.Left
	detailTitle.Text = "BUNDLE CONTENTS"
	detailTitle.ZIndex = 11
	detailTitle.Parent = detailHeader

	local dtStroke = Instance.new("UIStroke")
	dtStroke.Color = Color3.fromRGB(0, 0, 0)
	dtStroke.Thickness = 1.5
	dtStroke.Transparency = 0.1
	dtStroke.Parent = detailTitle

	selectorStrip = Instance.new("ScrollingFrame")
	selectorStrip.Name = "SelectorStrip"
	selectorStrip.Size = UDim2.new(0.30, -4, 1, -8)
	selectorStrip.Position = UDim2.new(0.70, 0, 0, 4)
	selectorStrip.BackgroundColor3 = STRIP_BG
	selectorStrip.BackgroundTransparency = 0.2
	selectorStrip.BorderSizePixel = 0
	selectorStrip.ScrollBarThickness = 4
	selectorStrip.ScrollBarImageColor3 = Color3.fromRGB(90, 95, 130)
	selectorStrip.CanvasSize = UDim2.fromScale(0, 0)
	selectorStrip.AutomaticCanvasSize = Enum.AutomaticSize.Y
	selectorStrip.ScrollingDirection = Enum.ScrollingDirection.Y
	selectorStrip.ZIndex = 5
	selectorStrip.Parent = bundleContainer

	local ssCorner = Instance.new("UICorner")
	ssCorner.CornerRadius = UDim.new(0, 12)
	ssCorner.Parent = selectorStrip

	local ssStroke = Instance.new("UIStroke")
	ssStroke.Color = Color3.fromRGB(55, 60, 90)
	ssStroke.Thickness = 1
	ssStroke.Transparency = 0.4
	ssStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	ssStroke.Parent = selectorStrip

	local ssPad = Instance.new("UIPadding")
	ssPad.PaddingTop = UDim.new(0, 6)
	ssPad.PaddingBottom = UDim.new(0, 6)
	ssPad.PaddingLeft = UDim.new(0, 6)
	ssPad.PaddingRight = UDim.new(0, 6)
	ssPad.Parent = selectorStrip

	local ssLayout = Instance.new("UIListLayout")
	ssLayout.FillDirection = Enum.FillDirection.Vertical
	ssLayout.Padding = UDim.new(0, 6)
	ssLayout.SortOrder = Enum.SortOrder.LayoutOrder
	ssLayout.Parent = selectorStrip

	selectorEntries = {}
	local allBundles = getBundlesForPanel()
	for i, bundle in ipairs(allBundles) do
		local entry = Instance.new("Frame")
		entry.Name = "Entry_" .. bundle.id
		entry.Size = UDim2.new(1, 0, 0, 72)
		entry.BackgroundColor3 = C.CardBg
		entry.BackgroundTransparency = 0
		entry.BorderSizePixel = 0
		entry.LayoutOrder = i
		entry.ZIndex = 6
		entry.Parent = selectorStrip

		local entryCorner = Instance.new("UICorner")
		entryCorner.CornerRadius = UDim.new(0, 8)
		entryCorner.Parent = entry

		local entryStroke = Instance.new("UIStroke")
		entryStroke.Color = C.CardStroke
		entryStroke.Thickness = 1.5
		entryStroke.Transparency = 0.3
		entryStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		entryStroke.Parent = entry

		local thumb = Instance.new("ImageLabel")
		thumb.Name = "Thumb"
		thumb.Size = UDim2.fromOffset(56, 56)
		thumb.Position = UDim2.fromOffset(8, 8)
		thumb.BackgroundColor3 = Color3.fromRGB(12, 14, 28)
		thumb.BorderSizePixel = 0
		thumb.ScaleType = Enum.ScaleType.Fit
		thumb.ZIndex = 7
		thumb.Parent = entry

		if bundle.coverImage and bundle.coverImage ~= "" then
			thumb.Image = bundle.coverImage
		else
			thumb.Image = ""
			local placeholder = Instance.new("TextLabel")
			placeholder.Size = UDim2.fromScale(1, 1)
			placeholder.BackgroundTransparency = 1
			placeholder.Font = Enum.Font.GothamBold
			placeholder.Text = "?"
			placeholder.TextColor3 = Color3.fromRGB(75, 80, 110)
			placeholder.TextSize = 28
			placeholder.ZIndex = 8
			placeholder.Parent = thumb
		end

		local thumbCorner = Instance.new("UICorner")
		thumbCorner.CornerRadius = UDim.new(0, 6)
		thumbCorner.Parent = thumb

		local nameLabel = Instance.new("TextLabel")
		nameLabel.Name = "BundleName"
		nameLabel.Size = UDim2.new(1, -76, 0, 20)
		nameLabel.Position = UDim2.fromOffset(70, 10)
		nameLabel.BackgroundTransparency = 1
		nameLabel.Font = Enum.Font.GothamBold
		nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		nameLabel.TextTransparency = 0
		nameLabel.TextSize = 13
		nameLabel.TextXAlignment = Enum.TextXAlignment.Left
		nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
		nameLabel.Text = bundle.displayName
		nameLabel.ZIndex = 7
		nameLabel.Parent = entry

		local ns = Instance.new("UIStroke")
		ns.Color = Color3.fromRGB(0, 0, 0)
		ns.Thickness = 1.2
		ns.Transparency = 0.15
		ns.Parent = nameLabel

		local tagText = ""
		if not bundle.isAvailable then
			tagText = "COMING SOON"
		elseif bundle.tag and bundle.tag ~= "" then
			tagText = bundle.tag
		end

		if tagText ~= "" then
			local tagBadge = Instance.new("TextLabel")
			tagBadge.Name = "Tag"
			tagBadge.Size = UDim2.new(1, -76, 0, 18)
			tagBadge.Position = UDim2.fromOffset(70, 34)
			tagBadge.BackgroundTransparency = 1
			tagBadge.Font = Enum.Font.GothamBold
			tagBadge.TextSize = 11
			tagBadge.TextXAlignment = Enum.TextXAlignment.Left
			tagBadge.TextTransparency = 0
			tagBadge.ZIndex = 7
			tagBadge.Parent = entry

			if not bundle.isAvailable then
				tagBadge.TextColor3 = C.TextMuted
				tagBadge.Text = "COMING SOON"
			else
				tagBadge.TextColor3 = C.Gold
				tagBadge.Text = bundle.tag
			end
		end

		local priceLabel = Instance.new("TextLabel")
		priceLabel.Name = "Price"
		priceLabel.Size = UDim2.new(1, -76, 0, 16)
		priceLabel.Position = UDim2.fromOffset(70, 52)
		priceLabel.BackgroundTransparency = 1
		priceLabel.Font = Enum.Font.GothamBold
		priceLabel.TextColor3 = C.Green
		priceLabel.TextTransparency = 0
		priceLabel.TextSize = 11
		priceLabel.TextXAlignment = Enum.TextXAlignment.Left
		local selectorOwned = false
		local isFnafCoinBundle = (bundle.id == FNAF_BUNDLE_ID)
		if isFnafCoinBundle then
			selectorOwned = _bundleOwnedLocal[bundle.id] == true
		elseif bundle.gamepassId then
			local okS, ownsS = pcall(function()
				return MarketplaceService:UserOwnsGamePassAsync(LocalPlayer.UserId, bundle.gamepassId)
			end)
			selectorOwned = okS and ownsS == true
		end
		if selectorOwned then
			priceLabel.Text = "OWNED"
		elseif isFnafCoinBundle then
			priceLabel.Text = string.format("%s F", tostring(FNAF_BUNDLE_COST_COINS))
		else
			priceLabel.Text = string.format("%d R$", bundle.priceRobux)
		end
		if selectorOwned then priceLabel.TextColor3 = C.TextMuted end
		priceLabel.ZIndex = 7
		priceLabel.Parent = entry

		local clickBtn = Instance.new("TextButton")
		clickBtn.Name = "ClickArea"
		clickBtn.Size = UDim2.fromScale(1, 1)
		clickBtn.BackgroundTransparency = 1
		clickBtn.Text = ""
		clickBtn.ZIndex = 10
		clickBtn.Parent = entry

		clickBtn.MouseButton1Click:Connect(function()
			SoundUtil.Click()
			selectBundle(bundle.id)
		end)

		selectorEntries[bundle.id] = entry
	end

	if allBundles[1] then
		selectBundle(allBundles[1].id)
	end
end

function BundlePanel.SelectBundle(bundleId: string)
	selectBundle(bundleId)
end

function BundlePanel.ShowItemPreviewIn(parent: Instance, itemData)
	externalPreviewHost = parent
	showItemPreview(itemData)
end

function BundlePanel.ClearContent()
	closeItemPreview()

	if bundleContainer then
		bundleContainer:Destroy()
		bundleContainer = nil
	end

	coverImage = nil
	titleLabel = nil
	viewBtn = nil
	buyBtn = nil
	heroFrame = nil
	detailFrame = nil
	selectorStrip = nil
	selectorEntries = {}
	selectedBundleId = ""
	inDetailView = false

	if contentParent then
		contentParent.AutomaticCanvasSize = Enum.AutomaticSize.Y
		contentParent.CanvasSize = UDim2.fromScale(0, 0)
		contentParent.ScrollBarThickness = 6
		contentParent.ScrollingDirection = Enum.ScrollingDirection.Y
	end
	contentParent = nil
	panelOptions = nil
	externalPreviewHost = nil
end

function BundlePanel.Show() end
function BundlePanel.Hide() end
function BundlePanel.IsVisible() return false end
function BundlePanel.Toggle() end

MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(_player, _gamepassId, wasPurchased)
	if wasPurchased and selectedBundleId and selectedBundleId ~= "" then
		task.wait(0.5)
		local remotes = ReplicatedStorage:FindFirstChild("Remotes")
		local verifyRF = remotes and remotes:FindFirstChild("VerifyGamepassPurchase")
		if verifyRF then
			local okVerify, verifyResult = pcall(function()
				return verifyRF:InvokeServer(_gamepassId)
			end)
			if okVerify and verifyResult and verifyResult.success then
				selectBundle(selectedBundleId)
			end
		end
	end
end)

return BundlePanel