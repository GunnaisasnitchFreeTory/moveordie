local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared", 60)
if not Shared then
	warn("[ToolboxDialoguePanel] Shared not found")
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

local C = UIConfig.Colors

local ToolboxDialoguePanel = {}

local overlay: TextButton? = nil
local canvas: CanvasGroup? = nil
local uiScale: UIScale? = nil
local visible = false
local closeCallback: (() -> ())? = nil
local responseHandlers = {
	onYes = nil :: ((any) -> ())?,
	onNo = nil :: ((any) -> ())?,
}

local activeDialogue = {
	title = "SOME GUY",
	speaker = "Some Guy",
	speakerModelName = "Some Guy",
	message = "Do you want to buy emotes?",
	acceptText = "Yes",
	declineText = "No",
	nextPanel = "EmoteShop",
}

local typewriterToken = 0
local responseLocked = false

local gradientFrame: Frame? = nil
local avatarFrame: ViewportFrame? = nil
local nameLabel: TextLabel? = nil
local messageLabel: TextLabel? = nil
local choicesFrame: Frame? = nil
local yesButton: TextButton? = nil
local noButton: TextButton? = nil

local finalGradientPos = UDim2.new(0, 0, 0.42, 0)
local finalAvatarPos = UDim2.new(0.04, 0, 0.49, 0)
local finalNamePos = UDim2.new(0.31, 0, 0.69, 0)
local finalMessagePos = UDim2.new(0.31, 0, 0.76, 0)
local finalChoicesPos = UDim2.new(0.77, 0, 0.7, 0)

local function clearViewport()
	if not avatarFrame then
		return
	end

	for _, child in ipairs(avatarFrame:GetChildren()) do
		child:Destroy()
	end
end

local function findSpeakerModel(modelName: string?): Model?
	if type(modelName) ~= "string" or modelName == "" then
		return nil
	end

	local direct = Workspace:FindFirstChild(modelName)
	if direct and direct:IsA("Model") then
		return direct
	end

	local recursive = Workspace:FindFirstChild(modelName, true)
	if recursive and recursive:IsA("Model") then
		return recursive
	end

	return nil
end

local function populateViewport(modelName: string?)
	if not avatarFrame then
		return
	end

	clearViewport()

	local sourceModel = findSpeakerModel(modelName)
	if not sourceModel then
		avatarFrame.Visible = false
		return
	end

	avatarFrame.Visible = true
	avatarFrame.Ambient = Color3.fromRGB(170, 180, 255)
	avatarFrame.LightColor = Color3.fromRGB(255, 244, 224)
	avatarFrame.LightDirection = Vector3.new(-1, -0.5, -1)

	local worldModel = Instance.new("WorldModel")
	worldModel.Parent = avatarFrame

	local originalArchivable = sourceModel.Archivable
	sourceModel.Archivable = true
	local clone = sourceModel:Clone()
	sourceModel.Archivable = originalArchivable

	for _, descendant in ipairs(clone:GetDescendants()) do
		if descendant:IsA("Script") or descendant:IsA("LocalScript") or descendant:IsA("ModuleScript") then
			descendant:Destroy()
		elseif descendant:IsA("ProximityPrompt") or descendant:IsA("Sound") then
			descendant:Destroy()
		end
	end

	clone.Parent = worldModel
	clone:PivotTo(CFrame.new())

	local camera = Instance.new("Camera")
	camera.Name = "DialogueCamera"
	camera.Parent = avatarFrame

	local focusPoint = Vector3.new(0, 1.6, 0)
	local head = clone:FindFirstChild("Head", true)
	if head and head:IsA("BasePart") then
		focusPoint = head.Position + Vector3.new(0, -0.15, 0)
	end

	local _, size = clone:GetBoundingBox()
	local distance = math.max(size.X, size.Y, size.Z) * 1.35
	camera.CFrame = CFrame.new(
		focusPoint + Vector3.new(distance * 0.35, size.Y * 0.08, distance),
		focusPoint
	)
	avatarFrame.CurrentCamera = camera
end

local function startTypewriter(text: string)
	if not messageLabel then
		return
	end

	typewriterToken += 1
	local token = typewriterToken
	messageLabel.Text = ""

	task.spawn(function()
		for index = 1, #text do
			if token ~= typewriterToken or not visible or not messageLabel then
				return
			end
			messageLabel.Text = string.sub(text, 1, index)
			task.wait(0.018)
		end
	end)
end

local function applyDialogue(dialogueData, animateMessage: boolean?)
	activeDialogue = dialogueData or activeDialogue

	if nameLabel then
		nameLabel.Text = tostring(activeDialogue.speaker or "Some Guy")
	end
	if yesButton then
		yesButton.Text = tostring(activeDialogue.acceptText or "Yes")
	end
	if noButton then
		noButton.Text = tostring(activeDialogue.declineText or "No")
	end

	populateViewport(activeDialogue.speakerModelName or activeDialogue.modelName or activeDialogue.speaker)

	local text = tostring(activeDialogue.message or "Do you want to buy emotes?")
	if animateMessage and visible then
		startTypewriter(text)
	elseif messageLabel then
		typewriterToken += 1
		messageLabel.Text = text
	end
end

local function setChoiceActive(button: TextButton, isActive: boolean)
	local line = button:FindFirstChild("Line")
	if line and line:IsA("Frame") then
		line.Visible = isActive
	end
	button.TextTransparency = if isActive then 0 else 0.08
end

local function createChoiceButton(parent: Instance, name: string, text: string): TextButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.BackgroundTransparency = 1
	button.BorderSizePixel = 0
	button.AutoButtonColor = false
	button.Size = UDim2.new(1, 0, 0, 42)
	button.Text = text
	button.TextColor3 = C.TextWhite
	button.TextSize = 28
	button.FontFace = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Regular, Enum.FontStyle.Normal)
	button.TextXAlignment = Enum.TextXAlignment.Left
	button.Parent = parent

	local line = Instance.new("Frame")
	line.Name = "Line"
	line.AnchorPoint = Vector2.new(0, 1)
	line.Position = UDim2.new(0, 0, 1, -2)
	line.Size = UDim2.new(0.72, 0, 0, 2)
	line.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	line.BorderSizePixel = 0
	line.Visible = false
	line.Parent = button

	button.MouseEnter:Connect(function()
		setChoiceActive(button, true)
		AnimUtil.Tween(button, { TextSize = 30 }, 0.12, Enum.EasingStyle.Quad)
		SoundUtil.Hover()
	end)

	button.MouseLeave:Connect(function()
		setChoiceActive(button, false)
		AnimUtil.Tween(button, { TextSize = 28 }, 0.12, Enum.EasingStyle.Quad)
	end)

	return button
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
		ToolboxDialoguePanel.Hide()
	end

	task.delay(0.2, function()
		responseLocked = false
	end)
end

function ToolboxDialoguePanel.SetDialogue(dialogueData)
	applyDialogue(dialogueData, visible)
end

function ToolboxDialoguePanel.SetResponseHandlers(handlers)
	if typeof(handlers) ~= "table" then
		return
	end

	responseHandlers.onYes = handlers.onYes
	responseHandlers.onNo = handlers.onNo
end

function ToolboxDialoguePanel.Init(screenGui: ScreenGui, onClose: () -> ())
	closeCallback = onClose

	overlay = Instance.new("TextButton")
	overlay.Name = "ToolboxDialogueOverlay"
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundTransparency = 1
	overlay.Text = ""
	overlay.AutoButtonColor = false
	overlay.Visible = false
	overlay.ZIndex = 40
	overlay.Parent = screenGui

	canvas = Instance.new("CanvasGroup")
	canvas.Name = "ToolboxDialogueCanvas"
	canvas.Size = UDim2.fromScale(1, 1)
	canvas.BackgroundTransparency = 1
	canvas.GroupTransparency = 1
	canvas.Visible = false
	canvas.Parent = overlay

	uiScale = Instance.new("UIScale")
	uiScale.Scale = 1
	uiScale.Parent = canvas

	gradientFrame = Instance.new("Frame")
	gradientFrame.Name = "GradientFrame"
	gradientFrame.AnchorPoint = Vector2.new(0, 0)
	gradientFrame.Position = finalGradientPos
	gradientFrame.Size = UDim2.new(1, 0, 0.58, 0)
	gradientFrame.BackgroundColor3 = Color3.fromRGB(5, 8, 18)
	gradientFrame.BackgroundTransparency = 0.04
	gradientFrame.BorderSizePixel = 0
	gradientFrame.ZIndex = 41
	gradientFrame.Parent = canvas

	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(0, 0, 0)),
		ColorSequenceKeypoint.new(0.22, Color3.fromRGB(18, 24, 54)),
		ColorSequenceKeypoint.new(0.65, Color3.fromRGB(10, 14, 30)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(4, 6, 12)),
	})
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.08, 0.45),
		NumberSequenceKeypoint.new(0.28, 0.02),
		NumberSequenceKeypoint.new(1, 0.02),
	})
	gradient.Rotation = 90
	gradient.Parent = gradientFrame

	avatarFrame = Instance.new("ViewportFrame")
	avatarFrame.Name = "Avatar"
	avatarFrame.AnchorPoint = Vector2.new(0, 0)
	avatarFrame.Position = finalAvatarPos
	avatarFrame.Size = UDim2.new(0.25, 0, 0.43, 0)
	avatarFrame.BackgroundTransparency = 1
	avatarFrame.BorderSizePixel = 0
	avatarFrame.ZIndex = 44
	avatarFrame.Parent = canvas

	nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "NameLabel"
	nameLabel.BackgroundTransparency = 1
	nameLabel.BorderSizePixel = 0
	nameLabel.Position = finalNamePos
	nameLabel.Size = UDim2.new(0.4, 0, 0.08, 0)
	nameLabel.Text = ""
	nameLabel.TextColor3 = C.TextWhite
	nameLabel.TextSize = 34
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.FontFace = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.ExtraBold, Enum.FontStyle.Normal)
	nameLabel.ZIndex = 44
	nameLabel.Parent = canvas

	messageLabel = Instance.new("TextLabel")
	messageLabel.Name = "MessageLabel"
	messageLabel.BackgroundTransparency = 1
	messageLabel.BorderSizePixel = 0
	messageLabel.Position = finalMessagePos
	messageLabel.Size = UDim2.new(0.44, 0, 0.19, 0)
	messageLabel.Text = ""
	messageLabel.TextColor3 = Color3.fromRGB(244, 246, 255)
	messageLabel.TextSize = 24
	messageLabel.TextWrapped = true
	messageLabel.TextXAlignment = Enum.TextXAlignment.Left
	messageLabel.TextYAlignment = Enum.TextYAlignment.Top
	messageLabel.FontFace = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Medium, Enum.FontStyle.Normal)
	messageLabel.ZIndex = 44
	messageLabel.Parent = canvas

	choicesFrame = Instance.new("Frame")
	choicesFrame.Name = "Choices"
	choicesFrame.BackgroundTransparency = 1
	choicesFrame.BorderSizePixel = 0
	choicesFrame.Position = finalChoicesPos
	choicesFrame.Size = UDim2.new(0.2, 0, 0.18, 0)
	choicesFrame.ZIndex = 44
	choicesFrame.Parent = canvas

	local choiceLayout = Instance.new("UIListLayout")
	choiceLayout.FillDirection = Enum.FillDirection.Vertical
	choiceLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	choiceLayout.VerticalAlignment = Enum.VerticalAlignment.Top
	choiceLayout.Padding = UDim.new(0, 8)
	choiceLayout.Parent = choicesFrame

	yesButton = createChoiceButton(choicesFrame, "YesButton", "Yes")
	noButton = createChoiceButton(choicesFrame, "NoButton", "No")

	yesButton.LayoutOrder = 1
	noButton.LayoutOrder = 2

	AnimUtil.WireButton(yesButton, function()
		handleResponse("Yes")
	end)
	AnimUtil.WireButton(noButton, function()
		handleResponse("No")
	end)

	applyDialogue(activeDialogue, false)
end

function ToolboxDialoguePanel.Show(dialogueData)
	if not overlay or not canvas or not uiScale or not gradientFrame or not avatarFrame or not nameLabel or not messageLabel or not choicesFrame then
		return
	end
	if visible then
		if dialogueData then
			applyDialogue(dialogueData, true)
		end
		return
	end

	if dialogueData then
		applyDialogue(dialogueData, false)
	end

	responseLocked = false
	typewriterToken += 1
	visible = true
	overlay.Visible = true
	canvas.Visible = true
	canvas.GroupTransparency = 1
	uiScale.Scale = 1.02

	gradientFrame.Position = finalGradientPos + UDim2.new(0, 0, 0.08, 0)
	avatarFrame.Position = finalAvatarPos + UDim2.new(0, 0, 0.08, 0)
	nameLabel.Position = finalNamePos + UDim2.new(0, 0, 0.04, 0)
	messageLabel.Position = finalMessagePos + UDim2.new(0, 0, 0.04, 0)
	choicesFrame.Position = finalChoicesPos + UDim2.new(0.05, 0, 0, 0)

	SoundUtil.Open()
	AnimUtil.Tween(canvas, { GroupTransparency = 0 }, 0.22, Enum.EasingStyle.Quad)
	AnimUtil.Tween(uiScale, { Scale = 1 }, 0.22, Enum.EasingStyle.Quad)
	AnimUtil.Tween(gradientFrame, { Position = finalGradientPos }, 0.32, Enum.EasingStyle.Quint)
	AnimUtil.Tween(avatarFrame, { Position = finalAvatarPos }, 0.32, Enum.EasingStyle.Quint)
	AnimUtil.Tween(nameLabel, { Position = finalNamePos }, 0.28, Enum.EasingStyle.Quad)
	AnimUtil.Tween(messageLabel, { Position = finalMessagePos }, 0.32, Enum.EasingStyle.Quad)
	AnimUtil.Tween(choicesFrame, { Position = finalChoicesPos }, 0.28, Enum.EasingStyle.Quint)

	startTypewriter(tostring(activeDialogue.message or "Do you want to buy emotes?"))
end

function ToolboxDialoguePanel.Hide()
	if not overlay or not canvas or not uiScale or not gradientFrame or not avatarFrame or not nameLabel or not messageLabel or not choicesFrame or not visible then
		return
	end

	visible = false
	responseLocked = false
	typewriterToken += 1

	AnimUtil.Tween(gradientFrame, { Position = finalGradientPos + UDim2.new(0, 0, 0.08, 0) }, 0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	AnimUtil.Tween(avatarFrame, { Position = finalAvatarPos + UDim2.new(0, 0, 0.08, 0) }, 0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	AnimUtil.Tween(nameLabel, { Position = finalNamePos + UDim2.new(0, 0, 0.04, 0) }, 0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	AnimUtil.Tween(messageLabel, { Position = finalMessagePos + UDim2.new(0, 0, 0.04, 0) }, 0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	AnimUtil.Tween(choicesFrame, { Position = finalChoicesPos + UDim2.new(0.05, 0, 0, 0) }, 0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

	local tween = AnimUtil.Tween(canvas, { GroupTransparency = 1 }, 0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	AnimUtil.Tween(uiScale, { Scale = 1.02 }, 0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

	task.spawn(function()
		tween.Completed:Wait()
		if canvas then
			canvas.Visible = false
		end
		if overlay then
			overlay.Visible = false
		end
	end)

	if closeCallback then
		closeCallback()
	end
end

function ToolboxDialoguePanel.IsVisible(): boolean
	return visible
end

function ToolboxDialoguePanel.Toggle()
	if visible then
		ToolboxDialoguePanel.Hide()
	else
		ToolboxDialoguePanel.Show()
	end
end

return ToolboxDialoguePanel
