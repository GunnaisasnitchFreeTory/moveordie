local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared", 60)
if not Shared then
	warn("[NpcDialoguePanel] Shared not found")
	return {
		Init = function() end,
		Show = function() end,
		Hide = function() end,
		IsVisible = function() return false end,
		Toggle = function() end,
		SetDialogue = function() end,
		SetResponseHandlers = function() end,
	}
end

local UIConfig = require(Shared:WaitForChild("UIConfig"))

local Client = script.Parent
local AnimUtil = require(Client:WaitForChild("AnimUtil"))
local SoundUtil = require(Client:WaitForChild("SoundUtil"))
local Components = require(Client:WaitForChild("Components"))

local C = UIConfig.Colors

local NpcDialoguePanel = {}

local HEADER_COLOR = Color3.fromRGB(76, 182, 255)
local CARD_BG = Color3.fromRGB(14, 18, 42)
local CARD_BG_ALT = Color3.fromRGB(20, 28, 58)
local CARD_STROKE = Color3.fromRGB(122, 212, 255)
local MESSAGE_TEXT = Color3.fromRGB(240, 246, 255)
local MUTED_TEXT = Color3.fromRGB(170, 194, 228)
local YES_COLOR = Color3.fromRGB(44, 205, 114)
local NO_COLOR = Color3.fromRGB(78, 94, 138)

local canvas: CanvasGroup? = nil
local uiScale: UIScale? = nil
local overlay: TextButton? = nil
local visible = false
local closeCallback: (() -> ())? = nil
local responseHandlers = {
	onYes = nil :: ((any) -> ())?,
	onNo = nil :: ((any) -> ())?,
}
local activeDialogue = {
		title = "NPC DIALOGUE",
		speaker = "NPC",
		message = "Choose an option.",
		acceptText = "Yes",
		declineText = "No",
		nextPanel = "EmoteShop",
	}
local responseLocked = false

local titleLabel: TextLabel? = nil
local speakerLabel: TextLabel? = nil
local messageLabel: TextLabel? = nil
local yesButton: TextButton? = nil
local noButton: TextButton? = nil

local function applyDialogue(dialogueData)
	activeDialogue = dialogueData or activeDialogue

	if titleLabel then
		titleLabel.Text = tostring(activeDialogue.title or "NPC DIALOGUE")
	end
	if speakerLabel then
		speakerLabel.Text = tostring(activeDialogue.speaker or "NPC")
	end
	if messageLabel then
		messageLabel.Text = tostring(activeDialogue.message or "Choose an option.")
	end
	if yesButton then
		yesButton.Text = tostring(activeDialogue.acceptText or "Yes")
	end
	if noButton then
		noButton.Text = tostring(activeDialogue.declineText or "No")
	end
end

local function handleResponse(kind: "Yes" | "No")
	if responseLocked or not visible then
		return
	end
	responseLocked = true

	local handler = if kind == "Yes" then responseHandlers.onYes else responseHandlers.onNo
	if handler then
		handler(activeDialogue)
	else
		NpcDialoguePanel.Hide()
	end

	task.delay(0.2, function()
		responseLocked = false
	end)
end

function NpcDialoguePanel.SetDialogue(dialogueData)
	applyDialogue(dialogueData)
end

function NpcDialoguePanel.SetResponseHandlers(handlers)
	if typeof(handlers) ~= "table" then
		return
	end

	responseHandlers.onYes = handlers.onYes
	responseHandlers.onNo = handlers.onNo
end

function NpcDialoguePanel.Init(screenGui: ScreenGui, onClose: () -> ())
	closeCallback = onClose

	overlay = Components.CreateDimOverlay(screenGui, function()
		NpcDialoguePanel.Hide()
	end)

	local content: ScrollingFrame
	local closeBtn: TextButton
	canvas, uiScale, content, closeBtn = Components.CreatePanel(screenGui, "NPC DIALOGUE", HEADER_COLOR, "Spectate")
	canvas.Size = UDim2.fromScale(0.42, 0.36)
	content.Size = UDim2.new(1, -24, 1, -86)
	content.Position = UDim2.new(0, 12, 0, 68)
	content.AutomaticCanvasSize = Enum.AutomaticSize.None
	content.ScrollingEnabled = false
	content.CanvasSize = UDim2.fromScale(0, 0)
	content.ScrollBarThickness = 0

	AnimUtil.WireButton(closeBtn, function()
		NpcDialoguePanel.Hide()
	end)

	local header = canvas:FindFirstChild("Header")
	if header and header:IsA("Frame") then
		local maybeTitle = header:FindFirstChild("Title")
		if maybeTitle and maybeTitle:IsA("TextLabel") then
			titleLabel = maybeTitle
		end
	end

	local body = Instance.new("Frame")
	body.Name = "Body"
	body.AnchorPoint = Vector2.new(0.5, 0)
	body.Position = UDim2.new(0.5, 0, 0, 4)
	body.Size = UDim2.new(1, 0, 1, -4)
	body.BackgroundTransparency = 1
	body.BorderSizePixel = 0
	body.Parent = content

	local bodyLayout = Instance.new("UIListLayout")
	bodyLayout.FillDirection = Enum.FillDirection.Vertical
	bodyLayout.Padding = UDim.new(0, 12)
	bodyLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	bodyLayout.VerticalAlignment = Enum.VerticalAlignment.Top
	bodyLayout.Parent = body

	local speechCard = Instance.new("Frame")
	speechCard.Name = "SpeechCard"
	speechCard.Size = UDim2.new(1, -10, 0, 126)
	speechCard.BackgroundColor3 = CARD_BG
	speechCard.BorderSizePixel = 0
	speechCard.LayoutOrder = 1
	speechCard.Parent = body
	Instance.new("UICorner", speechCard).CornerRadius = UDim.new(0, 12)

	local speechStroke = Instance.new("UIStroke")
	speechStroke.Color = CARD_STROKE
	speechStroke.Thickness = 2
	speechStroke.Transparency = 0.18
	speechStroke.Parent = speechCard

	local speechGrad = Instance.new("UIGradient")
	speechGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, CARD_BG_ALT),
		ColorSequenceKeypoint.new(1, CARD_BG),
	})
	speechGrad.Rotation = 90
	speechGrad.Parent = speechCard

	local promptLabel = Instance.new("TextLabel")
	promptLabel.Name = "PromptLabel"
	promptLabel.AnchorPoint = Vector2.new(0.5, 0)
	promptLabel.Position = UDim2.new(0.5, 0, 0, 16)
	promptLabel.Size = UDim2.new(1, -24, 0, 18)
	promptLabel.BackgroundTransparency = 1
	promptLabel.Font = Enum.Font.GothamBold
	promptLabel.Text = "NPC"
	promptLabel.TextColor3 = CARD_STROKE
	promptLabel.TextSize = 13
	promptLabel.ZIndex = 7
	promptLabel.Parent = speechCard

	speakerLabel = Instance.new("TextLabel")
	speakerLabel.Name = "SpeakerLabel"
	speakerLabel.AnchorPoint = Vector2.new(0.5, 0)
	speakerLabel.Position = UDim2.new(0.5, 0, 0, 38)
	speakerLabel.Size = UDim2.new(1, -24, 0, 24)
	speakerLabel.BackgroundTransparency = 1
	speakerLabel.Font = Enum.Font.GothamBlack
	speakerLabel.Text = ""
	speakerLabel.TextColor3 = C.TextWhite
	speakerLabel.TextSize = 22
	speakerLabel.ZIndex = 7
	speakerLabel.Parent = speechCard

	local speakerStroke = Instance.new("UIStroke")
	speakerStroke.Color = Color3.new(0, 0, 0)
	speakerStroke.Thickness = 1.3
	speakerStroke.Transparency = 0.2
	speakerStroke.Parent = speakerLabel

	messageLabel = Instance.new("TextLabel")
	messageLabel.Name = "MessageLabel"
	messageLabel.AnchorPoint = Vector2.new(0.5, 0)
	messageLabel.Position = UDim2.new(0.5, 0, 0, 68)
	messageLabel.Size = UDim2.new(1, -30, 0, 42)
	messageLabel.BackgroundTransparency = 1
	messageLabel.Font = Enum.Font.GothamSemibold
	messageLabel.Text = ""
	messageLabel.TextWrapped = true
	messageLabel.TextColor3 = MESSAGE_TEXT
	messageLabel.TextSize = 17
	messageLabel.ZIndex = 7
	messageLabel.Parent = speechCard

	local buttonRow = Instance.new("Frame")
	buttonRow.Name = "ButtonRow"
	buttonRow.Size = UDim2.new(1, -10, 0, 54)
	buttonRow.BackgroundTransparency = 1
	buttonRow.BorderSizePixel = 0
	buttonRow.LayoutOrder = 2
	buttonRow.Parent = body

	local buttonLayout = Instance.new("UIListLayout")
	buttonLayout.FillDirection = Enum.FillDirection.Horizontal
	buttonLayout.Padding = UDim.new(0, 10)
	buttonLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	buttonLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	buttonLayout.Parent = buttonRow

	noButton = Instance.new("TextButton")
	noButton.Name = "NoButton"
	noButton.Size = UDim2.fromOffset(124, 46)
	noButton.BackgroundColor3 = NO_COLOR
	noButton.BorderSizePixel = 0
	noButton.Font = Enum.Font.GothamBold
	noButton.TextColor3 = C.TextWhite
	noButton.TextSize = 18
	noButton.LayoutOrder = 1
	noButton.Parent = buttonRow
	Instance.new("UICorner", noButton).CornerRadius = UDim.new(0, 10)

	yesButton = Instance.new("TextButton")
	yesButton.Name = "YesButton"
	yesButton.Size = UDim2.fromOffset(124, 46)
	yesButton.BackgroundColor3 = YES_COLOR
	yesButton.BorderSizePixel = 0
	yesButton.Font = Enum.Font.GothamBold
	yesButton.TextColor3 = C.TextWhite
	yesButton.TextSize = 18
	yesButton.LayoutOrder = 2
	yesButton.Parent = buttonRow
	Instance.new("UICorner", yesButton).CornerRadius = UDim.new(0, 10)

	local hintLabel = Instance.new("TextLabel")
	hintLabel.Name = "HintLabel"
	hintLabel.Size = UDim2.new(1, -10, 0, 18)
	hintLabel.BackgroundTransparency = 1
	hintLabel.Font = Enum.Font.GothamMedium
	hintLabel.Text = "Choose an option to continue."
	hintLabel.TextColor3 = MUTED_TEXT
	hintLabel.TextSize = 13
	hintLabel.LayoutOrder = 3
	hintLabel.Parent = body

	AnimUtil.WireButton(noButton, function()
		handleResponse("No")
	end)
	AnimUtil.WireButton(yesButton, function()
		handleResponse("Yes")
	end)

	applyDialogue(activeDialogue)
end

function NpcDialoguePanel.Show(dialogueData)
	if not canvas or not uiScale or not overlay then
		return
	end
	if dialogueData then
		applyDialogue(dialogueData)
	end
	if visible then
		return
	end

	responseLocked = false
	visible = true
	overlay.Visible = true
	SoundUtil.Open()
	AnimUtil.OpenPanel(canvas, uiScale)
end

function NpcDialoguePanel.Hide()
	if not canvas or not uiScale or not overlay or not visible then
		return
	end

	visible = false
	responseLocked = false
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

function NpcDialoguePanel.IsVisible(): boolean
	return visible
end

function NpcDialoguePanel.Toggle()
	if visible then
		NpcDialoguePanel.Hide()
	else
		NpcDialoguePanel.Show()
	end
end

return NpcDialoguePanel
