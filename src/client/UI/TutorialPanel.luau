--[[
	TutorialPanel
	Blocking first-join tutorial modal.

	API:
	  Init(screenGui, callbacks)
	  Show()
	  Hide()
	  IsVisible()
	  SetBusy(isBusy)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
if not Shared then
	warn("[TutorialPanel] Shared not found")
	return {
		Init = function() end,
		Show = function() end,
		Hide = function() end,
		IsVisible = function() return false end,
		SetBusy = function() end,
	}
end

local UIConfig = require(Shared:WaitForChild("UIConfig", 10))

local Client = script.Parent
local AnimUtil = require(Client:WaitForChild("AnimUtil"))
local Components = require(Client:WaitForChild("Components"))
local SoundUtil = require(Client:WaitForChild("SoundUtil"))

local TutorialPanel = {}

local HEADER_COLOR = Color3.fromRGB(255, 166, 30)
local BODY_BG = Color3.fromRGB(18, 14, 36)
local STEP_BG = Color3.fromRGB(24, 20, 46)
local STEP_STROKE = Color3.fromRGB(255, 184, 64)
local GOAL_BG = Color3.fromRGB(34, 28, 64)
local GOAL_TEXT = Color3.fromRGB(255, 232, 132)
local BUTTON_BG = Color3.fromRGB(42, 198, 98)
local BUTTON_STROKE = Color3.fromRGB(170, 255, 194)

local visible = false
local isBusy = false

local overlay: TextButton? = nil
local canvas: CanvasGroup? = nil
local uiScale: UIScale? = nil
local acknowledgeButton: TextButton? = nil

local acknowledgeCallback = nil
local closedCallback = nil

local function applyBodyText(label: TextLabel, text: string, size: number)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.Text = text
	label.TextWrapped = true
	label.TextColor3 = UIConfig.Colors.TextWhite
	label.TextSize = size
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.AutomaticSize = Enum.AutomaticSize.Y
	label.Size = UDim2.new(1, 0, 0, 0)
	label.ZIndex = 7

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(0, 0, 0)
	stroke.Thickness = 1.5
	stroke.Transparency = 0.25
	stroke.Parent = label
end

local function buildStep(parent: Instance, stepNumber: number, text: string)
	local card = Instance.new("Frame")
	card.Name = "Step" .. tostring(stepNumber)
	card.BackgroundColor3 = STEP_BG
	card.BorderSizePixel = 0
	card.AutomaticSize = Enum.AutomaticSize.Y
	card.Size = UDim2.new(1, 0, 0, 0)
	card.ZIndex = 6
	card.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 14)
	corner.Parent = card

	local stroke = Instance.new("UIStroke")
	stroke.Color = STEP_STROKE
	stroke.Thickness = 1.5
	stroke.Transparency = 0.3
	stroke.Parent = card

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 12)
	padding.PaddingBottom = UDim.new(0, 12)
	padding.PaddingLeft = UDim.new(0, 14)
	padding.PaddingRight = UDim.new(0, 14)
	padding.Parent = card

	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.AutomaticSize = Enum.AutomaticSize.Y
	row.Size = UDim2.new(1, 0, 0, 0)
	row.ZIndex = 7
	row.Parent = card

	local rowLayout = Instance.new("UIListLayout")
	rowLayout.FillDirection = Enum.FillDirection.Horizontal
	rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	rowLayout.VerticalAlignment = Enum.VerticalAlignment.Top
	rowLayout.Padding = UDim.new(0, 10)
	rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rowLayout.Parent = row

	local badge = Instance.new("TextLabel")
	badge.Name = "Badge"
	badge.Size = UDim2.fromOffset(34, 34)
	badge.BackgroundColor3 = HEADER_COLOR
	badge.BorderSizePixel = 0
	badge.Font = Enum.Font.GothamBlack
	badge.Text = tostring(stepNumber)
	badge.TextColor3 = Color3.fromRGB(255, 255, 255)
	badge.TextSize = 18
	badge.ZIndex = 8
	badge.Parent = row

	local badgeCorner = Instance.new("UICorner")
	badgeCorner.CornerRadius = UDim.new(1, 0)
	badgeCorner.Parent = badge

	local badgeStroke = Instance.new("UIStroke")
	badgeStroke.Color = Color3.fromRGB(255, 245, 210)
	badgeStroke.Thickness = 1.4
	badgeStroke.Transparency = 0.25
	badgeStroke.Parent = badge

	local textLabel = Instance.new("TextLabel")
	textLabel.LayoutOrder = 2
	textLabel.Parent = row
	applyBodyText(textLabel, text, 20)
	textLabel.Size = UDim2.new(1, -44, 0, 0)
end

function TutorialPanel.Init(screenGui: ScreenGui, callbacks)
	acknowledgeCallback = callbacks and callbacks.onAcknowledge or nil
	closedCallback = callbacks and callbacks.onClosed or nil

	overlay = Instance.new("TextButton")
	overlay.Name = "TutorialOverlay"
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.Position = UDim2.fromScale(0, 0)
	overlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	overlay.BackgroundTransparency = 0.32
	overlay.BorderSizePixel = 0
	overlay.Text = ""
	overlay.Active = true
	overlay.AutoButtonColor = false
	overlay.Modal = true
	overlay.ZIndex = 4
	overlay.Visible = false
	overlay.Parent = screenGui

	local closeButton
	local content
	canvas, uiScale, content, closeButton = Components.CreatePanel(screenGui, "HOW TO PLAY", HEADER_COLOR, "Daily")
	canvas.Size = UDim2.new(0.62, 0, 0.72, 0)
	closeButton.Visible = false
	closeButton.Active = false

	if content then
		content.ScrollingDirection = Enum.ScrollingDirection.Y
		content.ScrollBarThickness = 4
		content.ScrollBarImageColor3 = Color3.fromRGB(118, 132, 205)
	end

	local background = Instance.new("Frame")
	background.Name = "TutorialBody"
	background.Size = UDim2.fromScale(1, 1)
	background.BackgroundColor3 = BODY_BG
	background.BackgroundTransparency = 0.12
	background.BorderSizePixel = 0
	background.ZIndex = 5
	background.Parent = content

	local backgroundCorner = Instance.new("UICorner")
	backgroundCorner.CornerRadius = UDim.new(0, 12)
	backgroundCorner.Parent = background

	local backgroundStroke = Instance.new("UIStroke")
	backgroundStroke.Color = Color3.fromRGB(126, 142, 234)
	backgroundStroke.Thickness = 1.2
	backgroundStroke.Transparency = 0.45
	backgroundStroke.Parent = background

	local layoutFrame = Instance.new("Frame")
	layoutFrame.Name = "LayoutFrame"
	layoutFrame.BackgroundTransparency = 1
	layoutFrame.AutomaticSize = Enum.AutomaticSize.Y
	layoutFrame.Size = UDim2.new(1, -24, 0, 0)
	layoutFrame.Position = UDim2.new(0, 12, 0, 10)
	layoutFrame.ZIndex = 6
	layoutFrame.Parent = content

	local layoutPadding = Instance.new("UIPadding")
	layoutPadding.PaddingBottom = UDim.new(0, 10)
	layoutPadding.Parent = layoutFrame

	local listLayout = Instance.new("UIListLayout")
	listLayout.FillDirection = Enum.FillDirection.Vertical
	listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	listLayout.Padding = UDim.new(0, 12)
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Parent = layoutFrame

	local intro = Instance.new("TextLabel")
	intro.Name = "Intro"
	intro.Parent = layoutFrame
	applyBodyText(intro, "Stay moving, watch the danger tiles, and survive longer than everyone else.", 22)

	buildStep(layoutFrame, 1, "Move on the platform")
	buildStep(layoutFrame, 2, "Watch the red tiles")
	buildStep(layoutFrame, 3, "Don't stand on red tiles or beams will eliminate you")

	local goalCard = Instance.new("Frame")
	goalCard.Name = "GoalCard"
	goalCard.BackgroundColor3 = GOAL_BG
	goalCard.BorderSizePixel = 0
	goalCard.AutomaticSize = Enum.AutomaticSize.Y
	goalCard.Size = UDim2.new(1, 0, 0, 0)
	goalCard.ZIndex = 6
	goalCard.Parent = layoutFrame

	local goalCorner = Instance.new("UICorner")
	goalCorner.CornerRadius = UDim.new(0, 14)
	goalCorner.Parent = goalCard

	local goalStroke = Instance.new("UIStroke")
	goalStroke.Color = GOAL_TEXT
	goalStroke.Thickness = 1.6
	goalStroke.Transparency = 0.28
	goalStroke.Parent = goalCard

	local goalPadding = Instance.new("UIPadding")
	goalPadding.PaddingTop = UDim.new(0, 14)
	goalPadding.PaddingBottom = UDim.new(0, 14)
	goalPadding.PaddingLeft = UDim.new(0, 16)
	goalPadding.PaddingRight = UDim.new(0, 16)
	goalPadding.Parent = goalCard

	local goalLabel = Instance.new("TextLabel")
	goalLabel.Name = "GoalLabel"
	goalLabel.Parent = goalCard
	applyBodyText(goalLabel, "GOAL: Be the last player alive to win", 22)
	goalLabel.TextColor3 = GOAL_TEXT

	acknowledgeButton = Instance.new("TextButton")
	acknowledgeButton.Name = "GotItButton"
	acknowledgeButton.Size = UDim2.new(0.46, 0, 0, 54)
	acknowledgeButton.AutomaticSize = Enum.AutomaticSize.None
	acknowledgeButton.BackgroundColor3 = BUTTON_BG
	acknowledgeButton.BorderSizePixel = 0
	acknowledgeButton.Font = Enum.Font.GothamBlack
	acknowledgeButton.Text = "GOT IT"
	acknowledgeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	acknowledgeButton.TextSize = 24
	acknowledgeButton.AutoButtonColor = true
	acknowledgeButton.ZIndex = 8
	acknowledgeButton.Parent = layoutFrame

	local buttonCorner = Instance.new("UICorner")
	buttonCorner.CornerRadius = UDim.new(0, 14)
	buttonCorner.Parent = acknowledgeButton

	local buttonStroke = Instance.new("UIStroke")
	buttonStroke.Color = BUTTON_STROKE
	buttonStroke.Thickness = 1.8
	buttonStroke.Transparency = 0.2
	buttonStroke.Parent = acknowledgeButton

	local buttonConstraint = Instance.new("UISizeConstraint")
	buttonConstraint.MinSize = Vector2.new(220, 54)
	buttonConstraint.MaxSize = Vector2.new(360, 54)
	buttonConstraint.Parent = acknowledgeButton

	AnimUtil.WireButton(acknowledgeButton, function()
		if isBusy then
			return
		end

		SoundUtil.Click()
		if acknowledgeCallback then
			acknowledgeCallback()
		end
	end)
end

function TutorialPanel.SetBusy(nextBusy: boolean)
	isBusy = nextBusy == true
	if not acknowledgeButton then
		return
	end

	acknowledgeButton.Active = not isBusy
	acknowledgeButton.AutoButtonColor = not isBusy
	acknowledgeButton.Text = isBusy and "SAVING..." or "GOT IT"
	acknowledgeButton.BackgroundColor3 = isBusy and Color3.fromRGB(70, 92, 120) or BUTTON_BG
end

function TutorialPanel.Show()
	if visible or not overlay or not canvas or not uiScale then
		return
	end

	visible = true
	TutorialPanel.SetBusy(false)
	overlay.Visible = true
	SoundUtil.Open()
	AnimUtil.OpenPanel(canvas, uiScale)
end

function TutorialPanel.Hide()
	if not visible or not overlay or not canvas or not uiScale then
		return
	end

	visible = false
	overlay.Visible = false
	SoundUtil.Close()
	local tween = AnimUtil.ClosePanel(canvas, uiScale)
	task.spawn(function()
		tween.Completed:Wait()
		canvas.Visible = false
		if closedCallback then
			closedCallback()
		end
	end)
end

function TutorialPanel.IsVisible()
	return visible
end

return TutorialPanel
