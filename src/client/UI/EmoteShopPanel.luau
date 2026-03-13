local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared", 60)
if not Shared then
	warn("[EmoteShopPanel] Shared not found")
	return {
		Init = function() end,
		Show = function() end,
		Hide = function() end,
		IsVisible = function() return false end,
		Toggle = function() end,
	}
end

local UIConfig = require(Shared:WaitForChild("UIConfig"))

local Client = script.Parent
local AnimUtil = require(Client:WaitForChild("AnimUtil"))
local SoundUtil = require(Client:WaitForChild("SoundUtil"))
local Components = require(Client:WaitForChild("Components"))

local C = UIConfig.Colors

local EmoteShopPanel = {}

local HEADER_COLOR = Color3.fromRGB(255, 96, 190)
local CARD_BG = Color3.fromRGB(26, 12, 44)
local CARD_BG_ALT = Color3.fromRGB(42, 18, 70)
local CARD_STROKE = Color3.fromRGB(255, 164, 230)
local MESSAGE_TEXT = Color3.fromRGB(255, 234, 250)
local MUTED_TEXT = Color3.fromRGB(215, 180, 220)

local canvas: CanvasGroup? = nil
local uiScale: UIScale? = nil
local overlay: TextButton? = nil
local visible = false
local closeCallback: (() -> ())? = nil

function EmoteShopPanel.Init(screenGui: ScreenGui, onClose: () -> ())
	closeCallback = onClose

	overlay = Components.CreateDimOverlay(screenGui, function()
		EmoteShopPanel.Hide()
	end)

	local content: ScrollingFrame
	local closeBtn: TextButton
	canvas, uiScale, content, closeBtn = Components.CreatePanel(screenGui, "EMOTE SHOP", HEADER_COLOR, "Icons")
	canvas.Size = UDim2.fromScale(0.52, 0.46)
	content.AutomaticCanvasSize = Enum.AutomaticSize.None
	content.ScrollingEnabled = false
	content.CanvasSize = UDim2.fromScale(0, 0)
	content.ScrollBarThickness = 0

	AnimUtil.WireButton(closeBtn, function()
		EmoteShopPanel.Hide()
	end)

	local wrapper = Instance.new("Frame")
	wrapper.Name = "Wrapper"
	wrapper.AnchorPoint = Vector2.new(0.5, 0)
	wrapper.Position = UDim2.new(0.5, 0, 0, 12)
	wrapper.Size = UDim2.new(1, -12, 1, -12)
	wrapper.BackgroundTransparency = 1
	wrapper.BorderSizePixel = 0
	wrapper.Parent = content

	local bodyLayout = Instance.new("UIListLayout")
	bodyLayout.FillDirection = Enum.FillDirection.Vertical
	bodyLayout.Padding = UDim.new(0, 14)
	bodyLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	bodyLayout.VerticalAlignment = Enum.VerticalAlignment.Top
	bodyLayout.Parent = wrapper

	local intro = Instance.new("TextLabel")
	intro.Size = UDim2.new(1, -10, 0, 22)
	intro.BackgroundTransparency = 1
	intro.Font = Enum.Font.GothamSemibold
	intro.Text = "Some Guy can send players here from the lobby."
	intro.TextColor3 = MUTED_TEXT
	intro.TextSize = 14
	intro.TextWrapped = true
	intro.LayoutOrder = 1
	intro.Parent = wrapper

	local card = Instance.new("Frame")
	card.Name = "ComingSoonCard"
	card.Size = UDim2.new(1, -8, 0, 190)
	card.BackgroundColor3 = CARD_BG
	card.BorderSizePixel = 0
	card.LayoutOrder = 2
	card.Parent = wrapper
	Instance.new("UICorner", card).CornerRadius = UDim.new(0, 14)

	local stroke = Instance.new("UIStroke")
	stroke.Color = CARD_STROKE
	stroke.Thickness = 2
	stroke.Transparency = 0.16
	stroke.Parent = card

	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, CARD_BG_ALT),
		ColorSequenceKeypoint.new(1, CARD_BG),
	})
	gradient.Rotation = 90
	gradient.Parent = card

	local badge = Instance.new("TextLabel")
	badge.AnchorPoint = Vector2.new(0.5, 0)
	badge.Position = UDim2.new(0.5, 0, 0, 18)
	badge.Size = UDim2.fromOffset(174, 28)
	badge.BackgroundColor3 = Color3.fromRGB(124, 42, 122)
	badge.BorderSizePixel = 0
	badge.Font = Enum.Font.GothamBold
	badge.Text = "LOBBY SHOP"
	badge.TextColor3 = C.TextWhite
	badge.TextSize = 13
	badge.ZIndex = 7
	badge.Parent = card
	Instance.new("UICorner", badge).CornerRadius = UDim.new(0, 12)

	local title = Instance.new("TextLabel")
	title.AnchorPoint = Vector2.new(0.5, 0)
	title.Position = UDim2.new(0.5, 0, 0, 60)
	title.Size = UDim2.new(1, -24, 0, 42)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBlack
	title.Text = "Coming Soon"
	title.TextColor3 = MESSAGE_TEXT
	title.TextScaled = true
	title.ZIndex = 7
	title.Parent = card

	local titleStroke = Instance.new("UIStroke")
	titleStroke.Color = Color3.new(0, 0, 0)
	titleStroke.Thickness = 1.8
	titleStroke.Transparency = 0.18
	titleStroke.Parent = title

	local description = Instance.new("TextLabel")
	description.AnchorPoint = Vector2.new(0.5, 0)
	description.Position = UDim2.new(0.5, 0, 0, 112)
	description.Size = UDim2.new(1, -30, 0, 42)
	description.BackgroundTransparency = 1
	description.Font = Enum.Font.GothamMedium
	description.Text = "The emote shop shell is wired up and ready for real emote listings later."
	description.TextColor3 = MUTED_TEXT
	description.TextSize = 15
	description.TextWrapped = true
	description.ZIndex = 7
	description.Parent = card
end

function EmoteShopPanel.Show()
	if not canvas or not uiScale or not overlay or visible then
		return
	end

	visible = true
	overlay.Visible = true
	SoundUtil.Open()
	AnimUtil.OpenPanel(canvas, uiScale)
end

function EmoteShopPanel.Hide()
	if not canvas or not uiScale or not overlay or not visible then
		return
	end

	visible = false
	overlay.Visible = false
	local tween = AnimUtil.ClosePanel(canvas, uiScale)
	task.spawn(function()
		tween.Completed:Wait()
		if canvas then
			canvas.Visible = false
		end
	end)

	if closeCallback then
		closeCallback()
	end
end

function EmoteShopPanel.IsVisible(): boolean
	return visible
end

function EmoteShopPanel.Toggle()
	if visible then
		EmoteShopPanel.Hide()
	else
		EmoteShopPanel.Show()
	end
end

return EmoteShopPanel
