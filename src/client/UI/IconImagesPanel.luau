--[[
	IconImagesPanel
	Placeholder panel for future icon/image content (crowns/pets/icons).

	• Grid layout matching other panels
	• Placeholder cards with "Coming Soon" styling
	• Same glossy/vibrant theme

	Used by: UIController (sidebar "Icons" button)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UIConfig = require(Shared:WaitForChild("UIConfig"))

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

local PLACEHOLDER_ICONS = {
	{ name = "???", icon = "🖼", color = C.Common },
	{ name = "???", icon = "🖼", color = C.Uncommon },
	{ name = "???", icon = "🖼", color = C.Rare },
	{ name = "???", icon = "🖼", color = C.Epic },
	{ name = "???", icon = "🖼", color = C.Legendary },
	{ name = "???", icon = "🖼", color = C.Common },
	{ name = "???", icon = "🖼", color = C.Uncommon },
	{ name = "???", icon = "🖼", color = C.Rare },
	{ name = "???", icon = "🖼", color = C.Epic },
	{ name = "???", icon = "🖼", color = C.Legendary },
	{ name = "???", icon = "🖼", color = C.Common },
	{ name = "???", icon = "🖼", color = C.Rare },
}

local function populateGrid()
	for _, child in ipairs(contentFrame:GetChildren()) do
		if child:IsA("Frame") then child:Destroy() end
	end

	for i, item in ipairs(PLACEHOLDER_ICONS) do
		Components.CreateItemCard(contentFrame, {
			name = item.name,
			rarity = "Common",
			iconColor = item.color,
			iconText = item.icon,
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
	canvas, uiScale, content, closeBtn = Components.CreatePanel(screenGui, "🖼 ICON IMAGES", C.HeaderIcons)
	contentFrame = content

	Components.AddGridLayout(content)

	AnimUtil.WireButton(closeBtn, function()
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

