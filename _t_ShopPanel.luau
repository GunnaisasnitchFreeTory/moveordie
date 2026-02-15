--[[
	ShopPanel  (Premium / Robux Shop)
	Sells Fate Coins, exclusive Crowns, exclusive Pets, VIP bundles.
	All prices are in Robux.

	Features:
	  * Category tabs (Coins, Crowns, Pets, Bundles)
	  * Dark vibrant card grid with rarity borders
	  * Stud texture + sunburst background (via Components.CreatePanel)
	  * Item images from ItemCatalog (single source of truth)

	Used by: UIController (sidebar "Shop" button)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared", 60)
if not Shared then
	warn("[ShopPanel] Shared not found after 60s -- disabled")
	return { Init = function() end, Show = function() end, Hide = function() end,
		IsVisible = function() return false end, Toggle = function() end }
end

local CDPModule = Shared:WaitForChild("ClientDepsProvider", 60)
if not CDPModule then
	local _children = {}
	for _, c in ipairs(Shared:GetChildren()) do table.insert(_children, c.Name.."("..c.ClassName..")") end
	warn("[ShopPanel] ClientDepsProvider MISSING. Shared path:", Shared:GetFullName(), "| Shared children:", table.concat(_children, ", "))
	return { Init = function() end, Show = function() end, Hide = function() end,
		IsVisible = function() return false end, Toggle = function() end }
end

local ok, Deps = pcall(require, CDPModule)
if not ok or not Deps then
	warn("[ShopPanel] require(ClientDepsProvider) FAILED:", Deps)
	return { Init = function() end, Show = function() end, Hide = function() end,
		IsVisible = function() return false end, Toggle = function() end }
end
local UIConfig = Deps.UIConfig
local ItemCatalog = Deps.ItemCatalog

local Client = script.Parent
local AnimUtil          = require(Client:WaitForChild("AnimUtil"))
local SoundUtil         = require(Client:WaitForChild("SoundUtil"))
local Components        = require(Client:WaitForChild("Components"))
local ThumbnailRenderer = require(Client:WaitForChild("ThumbnailRenderer"))

local C = UIConfig.Colors
local S = UIConfig.Sizes

local canvas: CanvasGroup = nil
local uiScale: UIScale = nil
local overlay: Frame = nil
local contentFrame: ScrollingFrame = nil
local visible = false
local closeCallback: (() -> ())? = nil
local activeTab = 1

local CATEGORIES = {
	{ label = "Coins",   filter = "Currency" },
	{ label = "Crowns",  filter = "ExclusiveCrown" },
	{ label = "Pets",    filter = "ExclusivePet" },
	{ label = "Bundles", filter = "Bundle" },
}

local ShopPanel = {}

local _warnedMissing = {}

local function clearCards()
	for _, child in ipairs(contentFrame:GetChildren()) do
		if child:IsA("Frame") then child:Destroy() end
	end
end

local _fateCoinImage: string = ""
do
	local entry = ItemCatalog.Get and ItemCatalog.Get("Currency", "FATE_COINS") or nil
	if entry and type(entry.image) == "string" and entry.image ~= "" then
		_fateCoinImage = entry.image
	end

	if _fateCoinImage ~= "" then
		print(string.format("[PremiumShop] Coins icon -> type=Currency id=FATE_COINS image=%s", _fateCoinImage))
	else
		warn("[PremiumShop] Coins icon -> type=Currency id=FATE_COINS image=<EMPTY>")
		if ItemCatalog.Currency and ItemCatalog.Currency.FATE_COINS then
			local directImg = ItemCatalog.Currency.FATE_COINS.image
			if directImg and type(directImg) == "string" and directImg ~= "" then
				_fateCoinImage = directImg
				print(string.format("[PremiumShop] Coins icon (direct fallback) -> image=%s", _fateCoinImage))
			end
		end
		if _fateCoinImage == "" then
			warn("[PremiumShop] FATE_COINS image is EMPTY — coin cards will show text fallback")
		end
	end
end

local _coinLayoutLogged = false

local function fixCoinCardLayout(card: Frame, imageId: string)
	local iconFrame = card:FindFirstChild("Icon")
	if not iconFrame then return end

	local imgLabel = iconFrame:FindFirstChild("ItemImage")
	if not imgLabel or not imgLabel:IsA("ImageLabel") then
		local letterLabel = iconFrame:FindFirstChild("Letter")
		if letterLabel then letterLabel.Visible = false end

		imgLabel = Instance.new("ImageLabel")
		imgLabel.Name = "ItemImage"
		imgLabel.ZIndex = 2
		imgLabel.Parent = iconFrame
	end

	imgLabel.BackgroundTransparency = 1
	imgLabel.ImageTransparency      = 0
	imgLabel.AnchorPoint            = Vector2.new(0.25, 0.25)
	imgLabel.Position               = UDim2.fromScale(0, 0)
	imgLabel.Size                   = UDim2.fromScale(2.1, 2.1)
	imgLabel.SizeConstraint         = Enum.SizeConstraint.RelativeXY
	imgLabel.Visible                = true

	if imgLabel.Image ~= imageId then
		imgLabel.Image = imageId
	end

	for _, child in ipairs(imgLabel:GetChildren()) do
		if child:IsA("UIAspectRatioConstraint") or child:IsA("UIScale") then
			child:Destroy()
		end
	end

	local letterLabel = iconFrame:FindFirstChild("Letter")
	if letterLabel then
		letterLabel.Visible = false
	end

	if not _coinLayoutLogged then
		_coinLayoutLogged = true
		print(string.format(
			"[PremiumShop] Coins ItemImage applied: AnchorPoint=0.25,0.25 Size=2.1x2.1 Image=%s",
			imageId
		))
	end
end

--- Create a ViewportFrame inside the card's Icon area for 3D model rendering.
--- Components.CreateViewportItemCard falls back to CreateItemCard when models aren't
--- in ReplicatedStorage, so the card won't have a ViewportFrame. We create one ourselves.
local function ensureViewportInCard(card: Frame, bgColor: Color3?): ViewportFrame?
	-- Check if Components already created one (ModelPreview)
	local existing = card:FindFirstChild("ModelPreview", true)
	if existing and existing:IsA("ViewportFrame") then
		return existing
	end

	-- Find the Icon frame that CreateItemCard always produces
	local iconFrame = card:FindFirstChild("Icon")
	if not iconFrame then
		warn("[PremiumShop] Card has no Icon frame -- cannot create ViewportFrame")
		return nil
	end

	-- Clear placeholder content inside Icon (emoji text, "?" label, ImageLabel)
	for _, child in ipairs(iconFrame:GetChildren()) do
		if child:IsA("TextLabel") or child:IsA("ImageLabel") then
			child:Destroy()
		end
	end

	-- Create ViewportFrame that fills the Icon area
	local vpFrame = Instance.new("ViewportFrame")
	vpFrame.Name = "ModelPreview"
	vpFrame.Size = UDim2.fromScale(1, 1)
	vpFrame.BackgroundColor3 = bgColor or Color3.fromRGB(30, 32, 50)
	vpFrame.BackgroundTransparency = 0.3
	vpFrame.BorderSizePixel = 0
	vpFrame.Parent = iconFrame

	local vpCorner = Instance.new("UICorner")
	vpCorner.CornerRadius = UDim.new(0, 10)
	vpCorner.Parent = vpFrame

	return vpFrame
end

local function populateCards(filterType: string)
	clearCards()

	if not contentFrame:FindFirstChildOfClass("UIGridLayout") then
		Components.AddGridLayout(contentFrame)
	end

	print(string.format("[PremiumShop] populateCards called -- filterType=%s", filterType))

	local order = 0
	for _, item in ipairs(UIConfig.MockPremiumItems) do
		if item.type == filterType then
			order += 1
			local actionText = string.format("%d ROBUX", item.robux)

			local catEntry = ItemCatalog.Get("Premium", item.id)
			if not catEntry and not _warnedMissing[item.id] then
				_warnedMissing[item.id] = true
				warn(string.format("[ShopPanel] No ItemCatalog.Premium entry for '%s' -- using placeholder", item.id))
			end

			-- Determine explicit image from catalog (preferred over 3D rendering)
			local catalogImage: string
			if filterType == "Currency" then
				catalogImage = _fateCoinImage
			else
				catalogImage = catEntry and ItemCatalog.GetImage(catEntry) or ""
			end

			local modelPath = catEntry and catEntry.modelPath or nil
			local catalogIconText = catEntry and catEntry.iconText or nil

			-- If an explicit image exists, use it directly. Only fall back to
			-- ThumbnailRenderer when there is NO image (static screenshots
			-- already include VFX baked in — no need for 3D rendering).
			local hasExplicitImage = (catalogImage ~= "")
			local wantsThumbnail = (not hasExplicitImage) and modelPath
				and (filterType == "ExclusivePet" or filterType == "ExclusiveCrown")

			local cardData = {
				name = item.name,
				rarity = item.rarity or "Rare",
				iconColor = item.iconColor,
				thumbnailBgColor = catEntry and catEntry.thumbnailBgColor or nil,
				iconText = catalogIconText,
				image = catalogImage,
				modelPath = modelPath,
				tag = item.tag,
				actionText = actionText,
				actionColor = C.RobuxButton,
				onAction = function()
					print(string.format("[ShopPanel] Premium purchase: %s (%d ROBUX)", item.name, item.robux))
				end,
			}

			local card = Components.CreateItemCard(contentFrame, cardData)
			card.LayoutOrder = order

			-- Only use ThumbnailRenderer as fallback when no explicit image exists
			if wantsThumbnail then
				local vpFrame = ensureViewportInCard(card, item.iconColor)
				if vpFrame then
					ThumbnailRenderer.RenderItemToViewport(vpFrame, {
						modelPath = modelPath,
						id = item.id,
						name = item.name,
						type = filterType,
					})
				end
			end

			if filterType == "Currency" and catalogImage ~= "" then
				fixCoinCardLayout(card, catalogImage)
			end
		end
	end
end

function ShopPanel.Init(screenGui: ScreenGui, onClose: () -> ())
	closeCallback = onClose

	overlay = Components.CreateDimOverlay(screenGui, function()
		ShopPanel.Hide()
	end)

	local content, closeBtn
	canvas, uiScale, content, closeBtn = Components.CreatePanel(screenGui, "💎 PREMIUM SHOP", C.HeaderShop, "Shop")
	contentFrame = content

	closeBtn.MouseButton1Click:Connect(function()
		SoundUtil.Close()
		ShopPanel.Hide()
	end)

	local tabTitles = {}
	for _, cat in ipairs(CATEGORIES) do
		table.insert(tabTitles, { label = cat.label })
	end

	local setActiveTab: ((number) -> ())?
	local tabBar
	tabBar, setActiveTab = Components.CreateTabBar(canvas, tabTitles, function(idx)
		activeTab = idx
		if setActiveTab then
			setActiveTab(idx)
		end
		populateCards(CATEGORIES[idx].filter)
	end)
	tabBar.AnchorPoint = Vector2.new(0.5, 0)
	tabBar.Position = UDim2.new(0.5, 0, 0, S.PanelHeaderHeight + 4)
	tabBar.Size = UDim2.new(1, -20, 0, S.TabHeight + 8)

	content.Position = UDim2.new(0, 12, 0, S.PanelHeaderHeight + S.TabHeight + 18)
	content.Size = UDim2.new(1, -24, 1, -(S.PanelHeaderHeight + S.TabHeight + 28))

	Components.AddGridLayout(contentFrame)
	setActiveTab(1)
	populateCards(CATEGORIES[1].filter)
end

function ShopPanel.Show()
	if visible then return end
	visible = true
	overlay.Visible = true
	SoundUtil.Open()
	AnimUtil.OpenPanel(canvas, uiScale)
end

function ShopPanel.Hide()
	if not visible then return end
	visible = false
	overlay.Visible = false
	local t = AnimUtil.ClosePanel(canvas, uiScale)
	task.spawn(function()
		t.Completed:Wait()
		canvas.Visible = false
	end)
	if closeCallback then closeCallback() end
end

function ShopPanel.IsVisible(): boolean
	return visible
end

function ShopPanel.Toggle()
	if visible then ShopPanel.Hide() else ShopPanel.Show() end
end

return ShopPanel
