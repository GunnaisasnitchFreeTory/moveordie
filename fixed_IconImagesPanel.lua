--[[
	IconImagesPanel
	Icon/image collection grid (coming soon — all locked placeholders).

	* Grid layout matching other panels
	* Placeholder cards with "Coming Soon" styling
	* Same glossy/vibrant theme
	* Icon data from ItemCatalog (single source of truth)

	Used by: UIController (sidebar "Icons" button)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
if not Shared then
	warn("[IconImagesPanel] ReplicatedStorage.Shared not found — panel disabled")
	return { Init = function() end, Show = function() end, Hide = function() end,
		IsVisible = function() return false end, Toggle = function() end }
end
local CDPModule = Shared:WaitForChild("ClientDepsProvider", 10)
if not CDPModule then
	warn("[IconImagesPanel] ClientDepsProvider not found — panel disabled")
	return { Init = function() end, Show = function() end, Hide = function() end,
		IsVisible = function() return false end, Toggle = function() end }
end
local Deps = require(CDPModule)
local UIConfig = Deps.UIConfig
local ItemCatalog = Deps.ItemCatalog

local Client = script.Parent
local AnimUtil   = require(Client:WaitForChild("AnimUtil"))
local SoundUtil  = require(Client:WaitForChild("SoundUtil"))
local Components = require(Client:WaitForChild("Components"))

local C = UIConfig.Colors
local S = UIConfig.Sizes

local canvas: CanvasGroup = nil
local uiScale: UIScale = nil
local overlay: Frame = nil
local contentFrame: ScrollingFrame = nil
local visible = false
local closeCallback: (() -> ())? = nil

local IconImagesPanel = {}

-- Rarity -> UIConfig Color mapping (for icon placeholder cards)
local RARITY_COLORS = {
	Common    = C.Common,
	Uncommon  = C.Uncommon,
	Rare      = C.Rare,
	Epic      = C.Epic,
	Legendary = C.Legendary,
}

-- Fallback icons if ItemCatalog has no Icons entries
local FALLBACK_ICONS = {
	{ name = "???", iconText = "🖼", rarity = "Common" },
	{ name = "???", iconText = "🖼", rarity = "Uncommon" },
	{ name = "???", iconText = "🖼", rarity = "Rare" },
	{ name = "???", iconText = "🖼", rarity = "Epic" },
	{ name = "???", iconText = "🖼", rarity = "Legendary" },
	{ name = "???", iconText = "🖼", rarity = "Common" },
	{ name = "???", iconText = "🖼", rarity = "Uncommon" },
	{ name = "???", iconText = "🖼", rarity = "Rare" },
	{ name = "???", iconText = "🖼", rarity = "Epic" },
	{ name = "???", iconText = "🖼", rarity = "Legendary" },
	{ name = "???", iconText = "🖼", rarity = "Common" },
	{ name = "???", iconText = "🖼", rarity = "Rare" },
}

local function populateGrid()
	for _, child in ipairs(contentFrame:GetChildren()) do
		if child:IsA("Frame") then child:Destroy() end
	end

	-- Use ItemCatalog icons if available, else fall back to local placeholders
	local icons = {}
	if ItemCatalog.GetAllIconsSorted then
		icons = ItemCatalog.GetAllIconsSorted()
	end
	if #icons == 0 then
		icons = FALLBACK_ICONS
	end

	for i, item in ipairs(icons) do
		local rarityStr = item.rarity or "Common"
		local iconColor = RARITY_COLORS[rarityStr] or C.Common
		local catalogImage = ItemCatalog.GetImage(item)

		Components.CreateItemCard(contentFrame, {
			name = item.name or "???",
			rarity = rarityStr,
			iconColor = iconColor,
			iconText = item.iconText or "🖼",
			image = catalogImage,
			locked = true,
			owned = false,
		}).LayoutOrder = i
	end
end

function IconImagesPanel.Init(screenGui: ScreenGui, onClose: () -> ())
	closeCallback = onClose

	overlay = Components.CreateDimOverlay(screenGui, function()
		IconImagesPanel.Hide()
	end)

	local content, closeBtn
	canvas, uiScale, content, closeBtn = Components.CreatePanel(screenGui, "🖼 ICON IMAGES", C.HeaderIcons, "Icons")
	contentFrame = content

	Components.AddGridLayout(content)

	-- Wire close button click (visual feedback handled by UIStyle.WireCloseButton in Components)
	closeBtn.MouseButton1Click:Connect(function()
		SoundUtil.Close()
		IconImagesPanel.Hide()
	end)

	populateGrid()
end

function IconImagesPanel.Show()
	if visible then return end
	visible = true
	overlay.Visible = true
	SoundUtil.Open()
	AnimUtil.OpenPanel(canvas, uiScale)
end

function IconImagesPanel.Hide()
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

function IconImagesPanel.IsVisible(): boolean
	return visible
end

function IconImagesPanel.Toggle()
	if visible then IconImagesPanel.Hide() else IconImagesPanel.Show() end
end

return IconImagesPanel
