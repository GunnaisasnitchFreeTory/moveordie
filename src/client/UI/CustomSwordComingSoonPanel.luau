--[[
	CustomSwordComingSoonPanel
	Purple coming-soon modal for the CustomSwords lobby interaction.

	API:
	  Init(screenGui, onClose)
	  Show() / Hide() / IsVisible() / Toggle()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared", 60)
if not Shared then
	warn("[CustomSwordComingSoonPanel] Shared not found")
	return {
		Init = function() end,
		Show = function() end,
		Hide = function() end,
		IsVisible = function() return false end,
		Toggle = function() end,
	}
end

local ok, Deps = pcall(require, Shared:WaitForChild("ClientDepsProvider", 60))
if not ok or not Deps then
	warn("[CustomSwordComingSoonPanel] ClientDepsProvider failed:", Deps)
	return {
		Init = function() end,
		Show = function() end,
		Hide = function() end,
		IsVisible = function() return false end,
		Toggle = function() end,
	}
end

local Client = script.Parent
local AnimUtil = require(Client:WaitForChild("AnimUtil"))
local SoundUtil = require(Client:WaitForChild("SoundUtil"))

local CustomSwordComingSoonPanel = {}

local HEADER_COLOR = Color3.fromRGB(140, 74, 220)
local HEADER_TOP = Color3.fromRGB(198, 128, 255)
local HEADER_BOT = Color3.fromRGB(88, 44, 156)
local INNER_BG = Color3.fromRGB(20, 10, 34)
local CARD_BG = Color3.fromRGB(34, 18, 58)
local CARD_TOP = Color3.fromRGB(72, 40, 120)
local CARD_BOT = Color3.fromRGB(24, 12, 40)
local CARD_STROKE = Color3.fromRGB(206, 164, 255)
local MESSAGE_COLOR = Color3.fromRGB(236, 215, 255)
local TEXT_WHITE = Color3.fromRGB(255, 255, 255)
local TEXT_MUTED = Color3.fromRGB(202, 184, 226)
local CLOSE_COLOR = Color3.fromRGB(110, 52, 170)

local canvas: CanvasGroup? = nil
local uiScale: UIScale? = nil
local overlay: Frame? = nil
local visible = false
local initialized = false
local closeCallback = nil

local function buildPanel(parent: Instance)
	canvas = Instance.new("CanvasGroup")
	canvas.Name = "CustomSwordComingSoonPanel"
	canvas.AnchorPoint = Vector2.new(0.5, 0.5)
	canvas.Position = UDim2.fromScale(0.5, 0.5)
	canvas.Size = UDim2.fromScale(0.56, 0.44)
	canvas.BackgroundColor3 = INNER_BG
	canvas.BackgroundTransparency = 0
	canvas.BorderSizePixel = 0
	canvas.GroupTransparency = 1
	canvas.Visible = false
	canvas.ZIndex = 5
	canvas.ClipsDescendants = true
	canvas.Parent = parent

	Instance.new("UICorner", canvas).CornerRadius = UDim.new(0, 14)

	local stroke = Instance.new("UIStroke")
	stroke.Color = HEADER_COLOR
	stroke.Thickness = 3
	stroke.Transparency = 0.08
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = canvas

	local shadow = Instance.new("Frame")
	shadow.AnchorPoint = Vector2.new(0.5, 0.5)
	shadow.Position = UDim2.new(0.5, 5, 0.5, 8)
	shadow.Size = UDim2.new(1, 20, 1, 20)
	shadow.BackgroundColor3 = Color3.new(0, 0, 0)
	shadow.BackgroundTransparency = 0.45
	shadow.BorderSizePixel = 0
	shadow.ZIndex = 4
	shadow.Parent = canvas
	Instance.new("UICorner", shadow).CornerRadius = UDim.new(0, 20)

	uiScale = Instance.new("UIScale")
	uiScale.Scale = 0.9
	uiScale.Parent = canvas

	overlay = Instance.new("Frame")
	overlay.Name = "Overlay"
	overlay.AnchorPoint = Vector2.new(0.5, 0.5)
	overlay.Position = UDim2.fromScale(0.5, 0.5)
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3 = Color3.new(0, 0, 0)
	overlay.BackgroundTransparency = 1
	overlay.BorderSizePixel = 0
	overlay.ZIndex = 1
	overlay.Visible = false
	overlay.Parent = parent

	local studTex = Instance.new("ImageLabel")
	studTex.Name = "StudTexture"
	studTex.AnchorPoint = Vector2.new(0, 0)
	studTex.Position = UDim2.fromScale(0, 0)
	studTex.Size = UDim2.fromScale(1, 1)
	studTex.BackgroundTransparency = 1
	studTex.Image = "rbxassetid://84772207963553"
	studTex.ImageTransparency = 0.93
	studTex.ScaleType = Enum.ScaleType.Tile
	studTex.TileSize = UDim2.fromOffset(64, 64)
	studTex.ImageColor3 = Color3.fromRGB(220, 180, 255)
	studTex.ZIndex = 6
	studTex.Parent = canvas

	local glow = Instance.new("ImageLabel")
	glow.AnchorPoint = Vector2.new(0.5, 0.5)
	glow.Position = UDim2.fromScale(0.5, 0.5)
	glow.Size = UDim2.fromScale(1.35, 1.35)
	glow.BackgroundTransparency = 1
	glow.Image = "rbxassetid://5607835947"
	glow.ImageColor3 = HEADER_COLOR
	glow.ImageTransparency = 0.84
	glow.ZIndex = 2
	glow.Parent = canvas

	local header = Instance.new("Frame")
	header.Name = "Header"
	header.AnchorPoint = Vector2.new(0, 0)
	header.Position = UDim2.fromOffset(0, 0)
	header.Size = UDim2.new(1, 0, 0, 54)
	header.BackgroundColor3 = HEADER_COLOR
	header.BorderSizePixel = 0
	header.ZIndex = 8
	header.Parent = canvas

	local hCorner = Instance.new("UICorner")
	hCorner.CornerRadius = UDim.new(0, 14)
	hCorner.Parent = header

	local hMask = Instance.new("Frame")
	hMask.Position = UDim2.new(0, 0, 0.5, 0)
	hMask.Size = UDim2.new(1, 0, 0.5, 0)
	hMask.BackgroundColor3 = HEADER_COLOR
	hMask.BorderSizePixel = 0
	hMask.ZIndex = 8
	hMask.Parent = header

	local hGrad = Instance.new("UIGradient")
	hGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, HEADER_TOP),
		ColorSequenceKeypoint.new(0.5, HEADER_COLOR),
		ColorSequenceKeypoint.new(1, HEADER_BOT),
	})
	hGrad.Rotation = 90
	hGrad.Parent = header

	local titleLabel = Instance.new("TextLabel")
	titleLabel.AnchorPoint = Vector2.new(0, 0.5)
	titleLabel.Position = UDim2.new(0, 18, 0.5, 0)
	titleLabel.Size = UDim2.new(1, -56, 1, 0)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Font = Enum.Font.GothamBold
	titleLabel.Text = "CUSTOMIZE SWORD"
	titleLabel.TextColor3 = TEXT_WHITE
	titleLabel.TextSize = 22
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.ZIndex = 9
	titleLabel.Parent = header

	local titleStroke = Instance.new("UIStroke")
	titleStroke.Color = Color3.new(0, 0, 0)
	titleStroke.Thickness = 1.8
	titleStroke.Transparency = 0.15
	titleStroke.Parent = titleLabel

	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "CloseBtn"
	closeBtn.AnchorPoint = Vector2.new(1, 0.5)
	closeBtn.Position = UDim2.new(1, -12, 0.5, 0)
	closeBtn.Size = UDim2.fromOffset(36, 36)
	closeBtn.BackgroundColor3 = CLOSE_COLOR
	closeBtn.BorderSizePixel = 0
	closeBtn.Font = Enum.Font.GothamBold
	closeBtn.Text = "X"
	closeBtn.TextColor3 = TEXT_WHITE
	closeBtn.TextSize = 22
	closeBtn.ZIndex = 9
	closeBtn.Parent = header
	Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(1, 0)

	local closeStroke = Instance.new("UIStroke")
	closeStroke.Color = Color3.fromRGB(72, 28, 120)
	closeStroke.Thickness = 1.5
	closeStroke.Parent = closeBtn

	AnimUtil.WireButton(closeBtn, function()
		if closeCallback then
			closeCallback()
		end
		CustomSwordComingSoonPanel.Hide()
	end)

	local subtitle = Instance.new("TextLabel")
	subtitle.AnchorPoint = Vector2.new(0.5, 0)
	subtitle.Position = UDim2.new(0.5, 0, 0, 70)
	subtitle.Size = UDim2.new(1, -40, 0, 20)
	subtitle.BackgroundTransparency = 1
	subtitle.Font = Enum.Font.GothamSemibold
	subtitle.Text = "Sword customization will be available here soon."
	subtitle.TextColor3 = TEXT_MUTED
	subtitle.TextSize = 13
	subtitle.TextXAlignment = Enum.TextXAlignment.Center
	subtitle.ZIndex = 7
	subtitle.Parent = canvas

	local messageCard = Instance.new("Frame")
	messageCard.Name = "MessageCard"
	messageCard.AnchorPoint = Vector2.new(0.5, 0.5)
	messageCard.Position = UDim2.new(0.5, 0, 0.62, 0)
	messageCard.Size = UDim2.new(1, -56, 0, 148)
	messageCard.BackgroundColor3 = CARD_BG
	messageCard.BorderSizePixel = 0
	messageCard.ZIndex = 7
	messageCard.Parent = canvas
	Instance.new("UICorner", messageCard).CornerRadius = UDim.new(0, 14)

	local cardStroke = Instance.new("UIStroke")
	cardStroke.Color = CARD_STROKE
	cardStroke.Thickness = 2
	cardStroke.Transparency = 0.22
	cardStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	cardStroke.Parent = messageCard

	local cardGrad = Instance.new("UIGradient")
	cardGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, CARD_TOP),
		ColorSequenceKeypoint.new(0.5, CARD_BG),
		ColorSequenceKeypoint.new(1, CARD_BOT),
	})
	cardGrad.Rotation = 90
	cardGrad.Parent = messageCard

	local badge = Instance.new("TextLabel")
	badge.Name = "Badge"
	badge.AnchorPoint = Vector2.new(0.5, 0)
	badge.Position = UDim2.new(0.5, 0, 0, 18)
	badge.Size = UDim2.fromOffset(170, 28)
	badge.BackgroundColor3 = Color3.fromRGB(90, 48, 146)
	badge.BorderSizePixel = 0
	badge.Font = Enum.Font.GothamBold
	badge.Text = "SWORD CUSTOMIZER"
	badge.TextColor3 = TEXT_WHITE
	badge.TextSize = 13
	badge.ZIndex = 8
	badge.Parent = messageCard
	Instance.new("UICorner", badge).CornerRadius = UDim.new(0, 12)

	local badgeStroke = Instance.new("UIStroke")
	badgeStroke.Color = Color3.fromRGB(225, 196, 255)
	badgeStroke.Thickness = 1.5
	badgeStroke.Transparency = 0.25
	badgeStroke.Parent = badge

	local comingSoonLabel = Instance.new("TextLabel")
	comingSoonLabel.Name = "ComingSoonLabel"
	comingSoonLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	comingSoonLabel.Position = UDim2.new(0.5, 0, 0.58, 0)
	comingSoonLabel.Size = UDim2.new(1, -24, 0, 48)
	comingSoonLabel.BackgroundTransparency = 1
	comingSoonLabel.Font = Enum.Font.GothamBlack
	comingSoonLabel.Text = "Coming Soon"
	comingSoonLabel.TextColor3 = MESSAGE_COLOR
	comingSoonLabel.TextSize = 30
	comingSoonLabel.TextScaled = true
	comingSoonLabel.ZIndex = 8
	comingSoonLabel.Parent = messageCard

	local comingSoonStroke = Instance.new("UIStroke")
	comingSoonStroke.Color = Color3.new(0, 0, 0)
	comingSoonStroke.Thickness = 2
	comingSoonStroke.Transparency = 0.12
	comingSoonStroke.Parent = comingSoonLabel

end

function CustomSwordComingSoonPanel.Show()
	if not canvas or not uiScale then
		return
	end
	if visible then
		return
	end

	visible = true
	canvas.Visible = true

	if overlay then
		overlay.Visible = true
		TweenService:Create(overlay, TweenInfo.new(0.18), { BackgroundTransparency = 0.55 }):Play()
	end

	uiScale.Scale = 0.88
	TweenService:Create(canvas, TweenInfo.new(0.18), { GroupTransparency = 0 }):Play()
	TweenService:Create(uiScale, TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()

	SoundUtil.Open()
end

function CustomSwordComingSoonPanel.Hide()
	if not canvas or not uiScale then
		return
	end
	if not visible then
		return
	end

	visible = false

	TweenService:Create(
		canvas,
		TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ GroupTransparency = 1 }
	):Play()
	TweenService:Create(
		uiScale,
		TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Scale = 0.92 }
	):Play()

	if overlay then
		TweenService:Create(overlay, TweenInfo.new(0.18), { BackgroundTransparency = 1 }):Play()
	end

	task.delay(0.2, function()
		if not visible and canvas then
			canvas.Visible = false
			if overlay then
				overlay.Visible = false
			end
		end
	end)

	SoundUtil.Close()
end

function CustomSwordComingSoonPanel.IsVisible(): boolean
	return visible
end

function CustomSwordComingSoonPanel.Toggle()
	if visible then
		CustomSwordComingSoonPanel.Hide()
	else
		CustomSwordComingSoonPanel.Show()
	end
end

function CustomSwordComingSoonPanel.Init(screenGui, onClose)
	if initialized then
		closeCallback = onClose
		return
	end

	initialized = true
	closeCallback = onClose
	buildPanel(screenGui)
end

return CustomSwordComingSoonPanel
