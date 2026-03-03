--[[
	IndexPanel
	Discovery/collection grid -- ALL crowns AND pets in the game.
	  * Owned  -> full-color ViewportFrame + name + rarity
	  * Locked -> greyed-out ViewportFrame + lock overlay + source label

	Features:
	  * Tab bar: Crowns / Pets / Icon Images
	  * All tabs sourced from ItemCatalog (single source of truth)
	  * Ownership from player attributes (OwnedCrowns / OwnedPets / OwnedIconImages)
	  * ViewportFrame 3D model previews for all items
	  * Live refresh on ownership changes + InventoryUpdated event

	Used by: UIController (sidebar "Index" button)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local Shared = ReplicatedStorage:WaitForChild("Shared", 60)
if not Shared then
	warn("[IndexPanel] Shared not found after 60s -- disabled")
	return { Init = function() end, Show = function() end, Hide = function() end,
		IsVisible = function() return false end, Toggle = function() end }
end

local CDPModule = Shared:WaitForChild("ClientDepsProvider", 60)
if not CDPModule then
	warn("[IndexPanel] ClientDepsProvider MISSING")
	return { Init = function() end, Show = function() end, Hide = function() end,
		IsVisible = function() return false end, Toggle = function() end }
end

local ok, Deps = pcall(require, CDPModule)
if not ok or not Deps then
	warn("[IndexPanel] require(ClientDepsProvider) FAILED:", Deps)
	return { Init = function() end, Show = function() end, Hide = function() end,
		IsVisible = function() return false end, Toggle = function() end }
end
local UIConfig = Deps.UIConfig
local ItemCatalog = Deps.ItemCatalog

if not UIConfig then
	warn("[IndexPanel] UIConfig not available -- disabled")
	return { Init = function() end, Show = function() end, Hide = function() end,
		IsVisible = function() return false end, Toggle = function() end }
end

local Client = script.Parent
local AnimUtil          = require(Client:WaitForChild("AnimUtil"))
local SoundUtil         = require(Client:WaitForChild("SoundUtil"))
local Components        = require(Client:WaitForChild("Components"))
local ThumbnailRenderer = require(Client:WaitForChild("ThumbnailRenderer"))

local C = UIConfig.Colors
local S = UIConfig.Sizes

local player = Players.LocalPlayer

local canvas: CanvasGroup = nil
local uiScale: UIScale = nil
local overlay: Frame = nil
local contentFrame: ScrollingFrame = nil
local visible = false
local closeCallback: (() -> ())? = nil
local activeTab = 1

local TABS = {
	{ label = "Crowns" },
	{ label = "Pets" },
	{ label = "Icon Images" },
}

local IndexPanel = {}

local function clearCards()
	if not contentFrame then return end
	for _, child in ipairs(contentFrame:GetChildren()) do
		if child:IsA("Frame") then child:Destroy() end
	end
end

local function ensureGrid()
	if not contentFrame then return end
	if not contentFrame:FindFirstChildOfClass("UIGridLayout") then
		Components.AddGridLayout(contentFrame)
	end
end

local function getOwnedSet(attrName: string): { [string]: boolean }
	local json = player:GetAttribute(attrName) or "[]"
	local decOk, list = pcall(HttpService.JSONDecode, HttpService, json)
	if not decOk or type(list) ~= "table" then return {} end
	local set = {}
	for _, id in ipairs(list) do
		set[id] = true
	end
	return set
end

--- Apply desaturation + grey overlay + lock icon on a ViewportFrame for locked items
local function applyLockOverlay(vpFrame: ViewportFrame)
	-- Desaturate the viewport rendering
	vpFrame.ImageColor3 = Color3.fromRGB(90, 90, 90)
	vpFrame.ImageTransparency = 0.15

	-- Semi-transparent dark overlay
	local greyOverlay = Instance.new("Frame")
	greyOverlay.Name = "LockOverlay"
	greyOverlay.Size = UDim2.fromScale(1, 1)
	greyOverlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	greyOverlay.BackgroundTransparency = 0.55
	greyOverlay.BorderSizePixel = 0
	greyOverlay.ZIndex = 2
	greyOverlay.Parent = vpFrame
	local oc = Instance.new("UICorner")
	oc.CornerRadius = UDim.new(0, 10)
	oc.Parent = greyOverlay

	-- Lock icon on top
	local lockIcon = Instance.new("TextLabel")
	lockIcon.Name = "LockIcon"
	lockIcon.Size = UDim2.fromOffset(32, 32)
	lockIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	lockIcon.Position = UDim2.fromScale(0.5, 0.5)
	lockIcon.BackgroundTransparency = 1
	lockIcon.Font = Enum.Font.GothamBold
	lockIcon.Text = ""
	lockIcon.TextColor3 = Color3.fromRGB(160, 165, 190)
	lockIcon.TextSize = 28
	lockIcon.ZIndex = 3
	lockIcon.Parent = vpFrame
end

--- Build sub-label for unowned crowns (delegates to ItemCatalog)
local function getCrownSubLabel(crown): string?
	return ItemCatalog.GetCrownAcquisitionLabel(crown.id)
end

local function populateCrowns()
	clearCards()
	ensureGrid()

	local allCrowns = ItemCatalog.GetAllCrownsSorted()
	local ownedSet = getOwnedSet("OwnedCrowns")

	for i, crown in ipairs(allCrowns) do
		local isOwned = ownedSet[crown.id] == true
		local resolved = ItemCatalog.ResolveCrownOrPetImage and ItemCatalog.ResolveCrownOrPetImage(crown.id, "CROWN") or nil
		local resolvedImage = (resolved and resolved.mode == "STATIC" and resolved.image) or ItemCatalog.GetImage(crown)
		local resolvedModelPath = (resolved and resolved.mode == "RENDERER" and resolved.rendererKey) or nil
		local subLabel = nil
		if not isOwned then
			subLabel = getCrownSubLabel(crown)
		end

		local card = Components.CreateViewportItemCard(contentFrame, {
			name = crown.name,
			rarity = crown.rarity,
			iconColor = crown.iconColor,
			thumbnailBgColor = crown.thumbnailBgColor,
			iconText = crown.iconText or "",
			image = resolvedImage,
			modelPath = resolvedModelPath,
			locked = not isOwned,
			owned = isOwned,
			subLabel = subLabel,
		})
		card.LayoutOrder = i

		-- Only use ThumbnailRenderer if the item has NO static image asset
		local hasStaticImage = (type(resolvedImage) == "string" and resolvedImage ~= "")
		if not hasStaticImage then
			local vpFrame = card:FindFirstChild("ModelPreview", true)
			if vpFrame and vpFrame:IsA("ViewportFrame") then
				ThumbnailRenderer.RenderItemToViewport(vpFrame, crown)
			end
		end
		if not isOwned then
			local vpFrame = card:FindFirstChild("ModelPreview", true)
			if vpFrame then applyLockOverlay(vpFrame) end
		end
	end
end

local function populatePets()
	clearCards()
	ensureGrid()

	local allPets = ItemCatalog.GetAllPetsSorted()
	local ownedSet = getOwnedSet("OwnedPets")

	for i, pet in ipairs(allPets) do
		local isOwned = ownedSet[pet.id] == true
		local resolved = ItemCatalog.ResolveCrownOrPetImage and ItemCatalog.ResolveCrownOrPetImage(pet.id, "PET") or nil
		local resolvedImage = (resolved and resolved.mode == "STATIC" and resolved.image) or ItemCatalog.GetImage(pet)
		local resolvedModelPath = (resolved and resolved.mode == "RENDERER" and resolved.rendererKey) or nil
		local isFNAFPet = pet.collection == "FNAF"
		local subLabel = nil
		if not isOwned then
			subLabel = ItemCatalog.GetPetAcquisitionLabel(pet.id)
		end

		local card = Components.CreateViewportItemCard(contentFrame, {
			name = pet.name,
			rarity = pet.rarity,
			iconColor = pet.iconColor,
			thumbnailBgColor = pet.thumbnailBgColor,
			iconText = pet.iconText or "",
			image = resolvedImage,
			modelPath = resolvedModelPath,
			locked = not isOwned,
			owned = isOwned,
			subLabel = subLabel,
		})
		card.LayoutOrder = i

		-- Only use ThumbnailRenderer if the item has NO static image asset
		local hasStaticImage = (type(resolvedImage) == "string" and resolvedImage ~= "")
		if not hasStaticImage then
			local vpFrame = card:FindFirstChild("ModelPreview", true)
			if vpFrame and vpFrame:IsA("ViewportFrame") and not isFNAFPet then
				ThumbnailRenderer.RenderItemToViewport(vpFrame, pet)
			end
		end
		if not isOwned then
			local vpFrame = card:FindFirstChild("ModelPreview", true)
			if vpFrame then applyLockOverlay(vpFrame) end
		end
	end
end

local function populateIconImages()
	clearCards()
	ensureGrid()

	local allIconImages = {}
	if ItemCatalog.GetAllIconImagesSorted then
		allIconImages = ItemCatalog.GetAllIconImagesSorted()
	end
	local ownedSet = getOwnedSet("OwnedIconImages")

	for i, iconImg in ipairs(allIconImages) do
		local isOwned = ownedSet[iconImg.id] == true
		local subLabel = nil
		if not isOwned then
			subLabel = ItemCatalog.GetIconImageAcquisitionLabel(iconImg.id)
		end

		local card = Components.CreateViewportItemCard(contentFrame, {
			name = iconImg.name,
			rarity = iconImg.rarity,
			iconColor = iconImg.iconColor,
			iconText = iconImg.iconText or "",
			image = ItemCatalog.GetImage(iconImg),
			modelPath = iconImg.modelPath,
			locked = not isOwned,
			owned = isOwned,
			subLabel = subLabel,
		})
		card.LayoutOrder = i

		if not isOwned then
			local vpFrame = card:FindFirstChild("ModelPreview", true)
			if vpFrame then applyLockOverlay(vpFrame) end
		end
	end
end

local function showTab(idx: number)
	if idx == 1 then
		populateCrowns()
	elseif idx == 2 then
		populatePets()
	elseif idx == 3 then
		populateIconImages()
	end
end

function IndexPanel.Init(screenGui: ScreenGui, onClose: () -> ())
	closeCallback = onClose

	overlay = Components.CreateDimOverlay(screenGui, function()
		IndexPanel.Hide()
	end)

	local content, closeBtn
	canvas, uiScale, content, closeBtn = Components.CreatePanel(screenGui, "INDEX", C.HeaderIndex, "Index")
	contentFrame = content

	if closeBtn then
		AnimUtil.WireButton(closeBtn, function()
			SoundUtil.Close()
			IndexPanel.Hide()
		end)
	end

	-- Override stud texture to Fate Beams asset (only this panel)
	do
		local stud = canvas:FindFirstChild("StudTexture")
		if stud then
			stud.Image = "rbxassetid://70851348312450"
			stud.TileSize = UDim2.fromOffset(96, 96)
			stud.ImageTransparency = 0.88
			stud.ImageColor3 = Color3.fromRGB(255, 255, 255)
		end
	end

	local setActiveTab: ((number) -> ())? = nil
	local tabBar
	tabBar, setActiveTab = Components.CreateTabBar(canvas, TABS, function(idx)
		activeTab = idx
		if type(setActiveTab) == "function" then
			setActiveTab(idx)
		end
		showTab(idx)
	end)

	if tabBar then
		tabBar.AnchorPoint = Vector2.new(0.5, 0)
		tabBar.Position = UDim2.new(0.5, 0, 0, S.PanelHeaderHeight + 4)
		tabBar.Size = UDim2.new(1, -20, 0, S.TabHeight + 8)
	end

	if content then
		content.Position = UDim2.new(0, 12, 0, S.PanelHeaderHeight + S.TabHeight + 18)
		content.Size = UDim2.new(1, -24, 1, -(S.PanelHeaderHeight + S.TabHeight + 28))
	end

	Components.AddGridLayout(contentFrame)
	if type(setActiveTab) == "function" then
		setActiveTab(1)
	end
	showTab(1)

	-- Live refresh on ownership changes
	player:GetAttributeChangedSignal("OwnedPets"):Connect(function()
		if visible and activeTab == 2 then showTab(2) end
	end)
	player:GetAttributeChangedSignal("OwnedCrowns"):Connect(function()
		if visible and activeTab == 1 then showTab(1) end
	end)
	player:GetAttributeChangedSignal("OwnedIconImages"):Connect(function()
		if visible and activeTab == 3 then showTab(3) end
	end)

	-- Listen for InventoryUpdated remote
	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
		if remotes then
			local invUpdate = remotes:FindFirstChild("InventoryUpdated")
			if invUpdate and invUpdate:IsA("RemoteEvent") then
				invUpdate.OnClientEvent:Connect(function()
					if visible then showTab(activeTab) end
				end)
			end
		end
	end)
end

function IndexPanel.Show()
	if visible then return end
	visible = true
	if overlay then overlay.Visible = true end
	showTab(activeTab)
	SoundUtil.Open()
	if canvas and uiScale then
		AnimUtil.OpenPanel(canvas, uiScale)
	end
end

function IndexPanel.Hide()
	if not visible then return end
	visible = false
	if overlay then overlay.Visible = false end
	if canvas and uiScale then
		local t = AnimUtil.ClosePanel(canvas, uiScale)
		task.spawn(function()
			t.Completed:Wait()
			canvas.Visible = false
		end)
	end
	if closeCallback then closeCallback() end
end

function IndexPanel.IsVisible(): boolean
	return visible
end

function IndexPanel.Toggle()
	if visible then IndexPanel.Hide() else IndexPanel.Show() end
end

return IndexPanel