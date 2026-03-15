local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
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

local dialogueGui: ScreenGui? = nil
local clickBlocker: TextButton? = nil
local dialogueRoot: Frame? = nil
local dialogueBackdrop: Frame? = nil
local avatarFrame: ViewportFrame? = nil
local nameLabel: TextLabel? = nil
local messageLabel: TextLabel? = nil
local yesButton: TextButton? = nil
local noButton: TextButton? = nil

local visible = false
local closeCallback: (() -> ())? = nil
local responseLocked = false
local typewriterToken = 0
local holdLogTokens: {[string]: number} = {}
local propertyLogConnections: {RBXScriptConnection} = {}

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

local ROOT_POSITION = UDim2.new(0.5, 0, 0.76, 0)
local ROOT_SIZE = UDim2.fromOffset(760, 184)

local function destroyConnections()
	for _, connection in ipairs(propertyLogConnections) do
		connection:Disconnect()
	end
	table.clear(propertyLogConnections)
end

local function logRootState(eventName: string)
	if not dialogueRoot then
		return
	end

	local absPos = dialogueRoot.AbsolutePosition
	local absSize = dialogueRoot.AbsoluteSize
	print(string.format(
		"[ToolboxDialogueRoot] event=%s position=%s size=%s absPos=(%.1f,%.1f) absSize=(%.1f,%.1f)",
		eventName,
		tostring(dialogueRoot.Position),
		tostring(dialogueRoot.Size),
		absPos.X,
		absPos.Y,
		absSize.X,
		absSize.Y
	))
end

local function connectPropertyLog(instance: GuiObject, propertyName: string, eventName: string)
	local ok, signal = pcall(function()
		return instance:GetPropertyChangedSignal(propertyName)
	end)
	if ok and signal then
		table.insert(propertyLogConnections, signal:Connect(function()
			logRootState(eventName)
		end))
	end
end

local function freezeGuiObject(guiObject: GuiObject)
	guiObject.AutomaticSize = Enum.AutomaticSize.None
	pcall(function()
		guiObject.Active = false
	end)
	pcall(function()
		guiObject.Selectable = false
	end)
	pcall(function()
		guiObject.Draggable = false
	end)
end

local function configureChoiceButton(button: TextButton)
	button.AutoButtonColor = false
	button.Modal = false
	button.Selectable = false
	pcall(function()
		button.Draggable = false
	end)
end

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
	-- Dialogue portraits use an identity-pivoted rig, so standard Roblox characters face -Z here.
	-- Put the camera on the front side of the rig instead of +Z, which shows the back.
	camera.CFrame = CFrame.new(
		focusPoint + Vector3.new(-distance * 0.12, size.Y * 0.06, -distance),
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

local function setChoiceText(button: TextButton?, text: string)
	if not button then
		return
	end

	local visual = button:FindFirstChild("ButtonVisual")
	local label = visual and visual:FindFirstChild("Label")
	if label and label:IsA("TextLabel") then
		label.Text = text
	end
end

local function isPointerInside(button: GuiButton): boolean
	local pointer = UserInputService:GetMouseLocation()
	local minX = button.AbsolutePosition.X
	local minY = button.AbsolutePosition.Y
	local maxX = minX + button.AbsoluteSize.X
	local maxY = minY + button.AbsoluteSize.Y
	return pointer.X >= minX and pointer.X <= maxX and pointer.Y >= minY and pointer.Y <= maxY
end

local function stopHoldLogging(buttonName: string)
	holdLogTokens[buttonName] = (holdLogTokens[buttonName] or 0) + 1
end

local function startHoldLogging(buttonName: string)
	local token = (holdLogTokens[buttonName] or 0) + 1
	holdLogTokens[buttonName] = token
	task.spawn(function()
		while visible and holdLogTokens[buttonName] == token do
			logRootState(buttonName .. "_hold")
			task.wait(0.12)
		end
	end)
end

local function setChoiceVisualState(button: TextButton, isHovered: boolean, isPressed: boolean?)
	local visual = button:FindFirstChild("ButtonVisual")
	if not visual or not visual:IsA("Frame") then
		return
	end

	local label = visual:FindFirstChild("Label")
	local line = visual:FindFirstChild("Line")
	local stroke = visual:FindFirstChildOfClass("UIStroke")
	local scale = visual:FindFirstChildOfClass("UIScale")

	local targetScale = if isPressed then 0.985 elseif isHovered then 1.01 else 1
	local targetFillTransparency = if isPressed then 0.1 elseif isHovered then 0.16 else 0.22
	local targetStrokeTransparency = if isPressed then 0.18 elseif isHovered then 0.28 else 0.42
	local targetTextTransparency = if isPressed or isHovered then 0 else 0.03
	local targetLineTransparency = if isPressed or isHovered then 0.12 else 0.42

	if scale then
		AnimUtil.Tween(scale, { Scale = targetScale }, 0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	end
	AnimUtil.Tween(visual, { BackgroundTransparency = targetFillTransparency }, 0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	if stroke then
		AnimUtil.Tween(stroke, { Transparency = targetStrokeTransparency }, 0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	end
	if label and label:IsA("TextLabel") then
		AnimUtil.Tween(label, { TextTransparency = targetTextTransparency }, 0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	end
	if line and line:IsA("Frame") then
		AnimUtil.Tween(line, { BackgroundTransparency = targetLineTransparency }, 0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	end
end

local function createChoiceSlot(parent: Instance, name: string, position: UDim2): Frame
	local slot = Instance.new("Frame")
	slot.Name = name
	slot.AnchorPoint = Vector2.new(1, 0)
	slot.Position = position
	slot.Size = UDim2.fromOffset(136, 48)
	slot.BackgroundTransparency = 1
	slot.BorderSizePixel = 0
	freezeGuiObject(slot)
	slot.Parent = parent
	return slot
end

local function createChoiceButton(parent: Frame, name: string, text: string): TextButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.Size = UDim2.fromScale(1, 1)
	button.BackgroundTransparency = 1
	button.BorderSizePixel = 0
	button.Text = ""
	button.ZIndex = 45
	configureChoiceButton(button)
	button.Parent = parent

	local visual = Instance.new("Frame")
	visual.Name = "ButtonVisual"
	visual.AnchorPoint = Vector2.new(0.5, 0.5)
	visual.Position = UDim2.fromScale(0.5, 0.5)
	visual.Size = UDim2.new(1, -4, 1, -2)
	visual.BackgroundColor3 = Color3.fromRGB(28, 31, 42)
	visual.BackgroundTransparency = 0.22
	visual.BorderSizePixel = 0
	visual.ZIndex = 45
	freezeGuiObject(visual)
	visual.Parent = button
	Instance.new("UICorner", visual).CornerRadius = UDim.new(0, 12)

	local visualStroke = Instance.new("UIStroke")
	visualStroke.Color = Color3.fromRGB(148, 156, 182)
	visualStroke.Thickness = 1
	visualStroke.Transparency = 0.42
	visualStroke.Parent = visual

	local visualScale = Instance.new("UIScale")
	visualScale.Scale = 1
	visualScale.Parent = visual

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Position = UDim2.new(0.1, 0, 0, 0)
	label.Size = UDim2.new(0.8, 0, 1, 0)
	label.Text = text
	label.TextColor3 = C.TextWhite
	label.TextTransparency = 0.03
	label.TextSize = 28
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.FontFace = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Regular, Enum.FontStyle.Normal)
	label.ZIndex = 46
	freezeGuiObject(label)
	label.Parent = visual

	local line = Instance.new("Frame")
	line.Name = "Line"
	line.AnchorPoint = Vector2.new(0, 1)
	line.Position = UDim2.new(0.1, 0, 1, -7)
	line.Size = UDim2.new(0.66, 0, 0, 2)
	line.BackgroundColor3 = Color3.fromRGB(214, 220, 238)
	line.BackgroundTransparency = 0.42
	line.BorderSizePixel = 0
	line.ZIndex = 46
	freezeGuiObject(line)
	line.Parent = visual

	-- Fixed-slot anti-shift structure:
	-- DialogueRoot never moves, the button slot never moves, and only ButtonVisual animates.
	setChoiceVisualState(button, false, false)

	button.MouseEnter:Connect(function()
		logRootState(name .. "_hover")
		setChoiceVisualState(button, true, false)
		SoundUtil.Hover()
	end)

	button.MouseLeave:Connect(function()
		stopHoldLogging(name)
		logRootState(name .. "_leave")
		setChoiceVisualState(button, false, false)
	end)

	button.MouseButton1Down:Connect(function()
		logRootState(name .. "_down")
		startHoldLogging(name)
		setChoiceVisualState(button, true, true)
	end)

	button.MouseButton1Up:Connect(function()
		stopHoldLogging(name)
		logRootState(name .. "_up")
		if not button:IsDescendantOf(game) then
			return
		end
		setChoiceVisualState(button, isPointerInside(button), false)
	end)

	return button
end

local function applyDialogue(dialogueData, animateMessage: boolean?)
	activeDialogue = dialogueData or activeDialogue

	if nameLabel then
		nameLabel.Text = tostring(activeDialogue.speaker or "Some Guy")
	end
	setChoiceText(yesButton, tostring(activeDialogue.acceptText or "Yes"))
	setChoiceText(noButton, tostring(activeDialogue.declineText or "No"))

	local speakerModelName = activeDialogue.speakerModelName or activeDialogue.modelName or activeDialogue.speaker
	populateViewport(speakerModelName)
	if avatarFrame and not avatarFrame.Visible then
		local legacyNames = activeDialogue.legacySpeakerModelNames or activeDialogue.legacyModelNames
		if type(legacyNames) == "table" then
			for _, legacyName in ipairs(legacyNames) do
				if type(legacyName) == "string" and legacyName ~= "" then
					populateViewport(legacyName)
					if avatarFrame.Visible then
						break
					end
				end
			end
		end
	end

	local text = tostring(activeDialogue.message or "Do you want to buy emotes?")
	if animateMessage and visible then
		startTypewriter(text)
	elseif messageLabel then
		typewriterToken += 1
		messageLabel.Text = text
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

	destroyConnections()
	if dialogueGui then
		dialogueGui:Destroy()
		dialogueGui = nil
	end

	local parent = screenGui.Parent
	if not parent then
		parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	end

	dialogueGui = Instance.new("ScreenGui")
	dialogueGui.Name = "ToolboxDialogueGui"
	dialogueGui.ResetOnSpawn = false
	dialogueGui.IgnoreGuiInset = true
	dialogueGui.DisplayOrder = 120
	dialogueGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	dialogueGui.Enabled = false
	dialogueGui.Parent = parent

	clickBlocker = Instance.new("TextButton")
	clickBlocker.Name = "ToolboxDialogueClickBlocker"
	clickBlocker.Size = UDim2.fromScale(1, 1)
	clickBlocker.Position = UDim2.fromScale(0, 0)
	clickBlocker.BackgroundTransparency = 1
	clickBlocker.BorderSizePixel = 0
	clickBlocker.Text = ""
	clickBlocker.AutoButtonColor = false
	clickBlocker.Modal = false
	clickBlocker.Selectable = false
	clickBlocker.ZIndex = 39
	clickBlocker.Parent = dialogueGui

	dialogueRoot = Instance.new("Frame")
	dialogueRoot.Name = "DialogueRoot"
	dialogueRoot.AnchorPoint = Vector2.new(0.5, 0.5)
	dialogueRoot.Position = ROOT_POSITION
	dialogueRoot.Size = ROOT_SIZE
	dialogueRoot.BackgroundTransparency = 1
	dialogueRoot.BorderSizePixel = 0
	dialogueRoot.ZIndex = 42
	dialogueRoot.Visible = false
	freezeGuiObject(dialogueRoot)
	dialogueRoot.Parent = dialogueGui

	local rootConstraint = Instance.new("UISizeConstraint")
	rootConstraint.MinSize = Vector2.new(ROOT_SIZE.X.Offset, ROOT_SIZE.Y.Offset)
	rootConstraint.MaxSize = Vector2.new(ROOT_SIZE.X.Offset, ROOT_SIZE.Y.Offset)
	rootConstraint.Parent = dialogueRoot

	dialogueBackdrop = Instance.new("Frame")
	dialogueBackdrop.Name = "DialogueBackdrop"
	dialogueBackdrop.Size = UDim2.fromScale(1, 1)
	dialogueBackdrop.Position = UDim2.fromScale(0, 0)
	dialogueBackdrop.BackgroundColor3 = Color3.fromRGB(11, 12, 18)
	dialogueBackdrop.BackgroundTransparency = 0.28
	dialogueBackdrop.BorderSizePixel = 0
	dialogueBackdrop.ZIndex = 42
	freezeGuiObject(dialogueBackdrop)
	dialogueBackdrop.Parent = dialogueRoot
	Instance.new("UICorner", dialogueBackdrop).CornerRadius = UDim.new(0, 22)

	local backdropStroke = Instance.new("UIStroke")
	backdropStroke.Color = Color3.fromRGB(104, 110, 132)
	backdropStroke.Thickness = 1.2
	backdropStroke.Transparency = 0.38
	backdropStroke.Parent = dialogueBackdrop

	local backdropGradient = Instance.new("UIGradient")
	backdropGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(20, 22, 30)),
		ColorSequenceKeypoint.new(0.58, Color3.fromRGB(11, 12, 18)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(6, 7, 11)),
	})
	backdropGradient.Rotation = 90
	backdropGradient.Parent = dialogueBackdrop

	local portraitSlot = Instance.new("Frame")
	portraitSlot.Name = "PortraitSlot"
	portraitSlot.AnchorPoint = Vector2.new(0, 0.5)
	portraitSlot.Position = UDim2.new(0, 24, 0.5, 0)
	portraitSlot.Size = UDim2.fromOffset(116, 136)
	portraitSlot.BackgroundColor3 = Color3.fromRGB(20, 22, 30)
	portraitSlot.BackgroundTransparency = 0.24
	portraitSlot.BorderSizePixel = 0
	portraitSlot.ZIndex = 43
	freezeGuiObject(portraitSlot)
	portraitSlot.Parent = dialogueRoot
	Instance.new("UICorner", portraitSlot).CornerRadius = UDim.new(0, 18)

	local portraitStroke = Instance.new("UIStroke")
	portraitStroke.Color = Color3.fromRGB(90, 96, 118)
	portraitStroke.Thickness = 1
	portraitStroke.Transparency = 0.46
	portraitStroke.Parent = portraitSlot

	avatarFrame = Instance.new("ViewportFrame")
	avatarFrame.Name = "Avatar"
	avatarFrame.Size = UDim2.fromScale(1, 1)
	avatarFrame.Position = UDim2.fromScale(0, 0)
	avatarFrame.BackgroundTransparency = 1
	avatarFrame.BorderSizePixel = 0
	avatarFrame.ZIndex = 44
	freezeGuiObject(avatarFrame)
	avatarFrame.Parent = portraitSlot

	nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "NameLabel"
	nameLabel.Position = UDim2.fromOffset(156, 28)
	nameLabel.Size = UDim2.new(1, -340, 0, 34)
	nameLabel.BackgroundTransparency = 1
	nameLabel.BorderSizePixel = 0
	nameLabel.Text = ""
	nameLabel.TextColor3 = C.TextWhite
	nameLabel.TextSize = 34
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.FontFace = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.ExtraBold, Enum.FontStyle.Normal)
	nameLabel.ZIndex = 44
	freezeGuiObject(nameLabel)
	nameLabel.Parent = dialogueRoot

	local nameStroke = Instance.new("UIStroke")
	nameStroke.Color = Color3.fromRGB(0, 0, 0)
	nameStroke.Thickness = 1
	nameStroke.Transparency = 0.52
	nameStroke.Parent = nameLabel

	messageLabel = Instance.new("TextLabel")
	messageLabel.Name = "MessageLabel"
	messageLabel.Position = UDim2.fromOffset(156, 70)
	messageLabel.Size = UDim2.new(1, -340, 0, 82)
	messageLabel.BackgroundTransparency = 1
	messageLabel.BorderSizePixel = 0
	messageLabel.Text = ""
	messageLabel.TextColor3 = Color3.fromRGB(244, 246, 255)
	messageLabel.TextSize = 24
	messageLabel.TextWrapped = true
	messageLabel.TextXAlignment = Enum.TextXAlignment.Left
	messageLabel.TextYAlignment = Enum.TextYAlignment.Top
	messageLabel.FontFace = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Medium, Enum.FontStyle.Normal)
	messageLabel.ZIndex = 44
	freezeGuiObject(messageLabel)
	messageLabel.Parent = dialogueRoot

	local messageStroke = Instance.new("UIStroke")
	messageStroke.Color = Color3.fromRGB(0, 0, 0)
	messageStroke.Thickness = 1
	messageStroke.Transparency = 0.68
	messageStroke.Parent = messageLabel

	local noSlot = createChoiceSlot(dialogueRoot, "NoButtonSlot", UDim2.new(1, -24, 0, 40))
	local yesSlot = createChoiceSlot(dialogueRoot, "YesButtonSlot", UDim2.new(1, -24, 0, 96))

	noButton = createChoiceButton(noSlot, "NoButton", "No")
	yesButton = createChoiceButton(yesSlot, "YesButton", "Yes")

	noButton.MouseButton1Click:Connect(function()
		SoundUtil.Click()
		handleResponse("No")
	end)

	yesButton.MouseButton1Click:Connect(function()
		SoundUtil.Click()
		handleResponse("Yes")
	end)

	connectPropertyLog(dialogueRoot, "Position", "root_position_changed")
	connectPropertyLog(dialogueRoot, "Size", "root_size_changed")
	connectPropertyLog(dialogueRoot, "AbsolutePosition", "root_absolute_position_changed")
	connectPropertyLog(dialogueRoot, "AbsoluteSize", "root_absolute_size_changed")

	applyDialogue(activeDialogue, false)
end

function ToolboxDialoguePanel.Show(dialogueData)
	if not dialogueGui or not dialogueRoot or not avatarFrame or not nameLabel or not messageLabel or not yesButton or not noButton then
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
	dialogueGui.Enabled = true
	dialogueRoot.Visible = true

	logRootState("show")
	SoundUtil.Open()
	startTypewriter(tostring(activeDialogue.message or "Do you want to buy emotes?"))
end

function ToolboxDialoguePanel.Hide()
	if not dialogueGui or not dialogueRoot or not visible then
		return
	end

	visible = false
	responseLocked = false
	typewriterToken += 1
	stopHoldLogging("NoButton")
	stopHoldLogging("YesButton")
	logRootState("hide")

	dialogueRoot.Visible = false
	dialogueGui.Enabled = false

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
