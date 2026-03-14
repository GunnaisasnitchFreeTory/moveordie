--[[
	ForceNextModePanel
	Separate client-side purchase UI for the FORCE NEXT MODE! developer product.

	Uses the same mode choices as the real vote panel, but never casts votes.
	Selecting a mode only requests the server-authoritative purchase prompt.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UIConfig = require(Shared:WaitForChild("UIConfig"))
local AnimUtil = require(script.Parent:WaitForChild("AnimUtil"))

local ForceNextModePanel = {}

local player = Players.LocalPlayer
local initialized = false
local visible = false
local closeCallback = nil

local gui: ScreenGui? = nil
local backdropFrame: Frame? = nil
local panelFrame: Frame? = nil
local titleLabel: TextLabel? = nil
local subtitleLabel: TextLabel? = nil
local promptRemote: RemoteEvent? = nil
local stateValue: StringValue? = nil
local voteActiveValue: BoolValue? = nil
local panelScaleTween: Tween? = nil
local panelBackgroundTween: Tween? = nil
local lifecycleVersion = 0

local VOTE_DISPLAY_ORDER = 151
local MODAL_DISPLAY_ORDER = VOTE_DISPLAY_ORDER + 1
local BACKDROP_ZINDEX = 20
local PANEL_ZINDEX = 30
local ANIM = UIConfig.Anim

local PANEL_BG = Color3.fromRGB(30, 30, 30)
local HEADER_COLOR = Color3.fromRGB(255, 215, 48)
local BTN_NORMAL_COLOR = Color3.fromRGB(50, 160, 80)
local BTN_BRAINROT_COLOR = Color3.fromRGB(178, 48, 255)
local TEXT_COLOR = Color3.fromRGB(255, 255, 255)
local BACKDROP_BG = Color3.fromRGB(0, 0, 0)
local BACKDROP_TRANSPARENCY = 0.45
local PANEL_BG_TRANSPARENCY = 0
local PANEL_STROKE_COLOR = Color3.fromRGB(255, 255, 255)
local PANEL_STROKE_TRANSPARENCY = 0.3
local STUD_TEXTURE_TRANSPARENCY = 0.88
local BUTTON_BG_TRANSPARENCY = 0.08
local BUTTON_OVERLAY_TRANSPARENCY = 0.5
local CLOSE_BTN_TRANSPARENCY = 0.1

local NORMAL_MODE_IMAGE = "rbxassetid://90452980108887"
local BRAINROT_MODE_IMAGE = "rbxassetid://134040200136136"

local function log(...)
	print("[ForceNextModeUI]", ...)
end

local function setGuiPreferredEnabled(enabled: boolean)
	if gui then
		gui:SetAttribute("PreferredEnabled", enabled)
	end
end

local function isPlayingState(): boolean
	return stateValue ~= nil and stateValue.Value == "Playing"
end

local function getTimingSubtitle(): string
	local forFollowingMatch = voteActiveValue ~= nil and voteActiveValue.Value == true
	if forFollowingMatch then
		return "Choose a mode to buy a 5 Robux force for the following match."
	end
	return "Choose a mode to buy a 5 Robux force for the next match."
end

local function refreshSubtitle()
	if subtitleLabel then
		subtitleLabel.Text = getTimingSubtitle()
	end
end

local function cancelTween(tween: Tween?): Tween?
	if tween then
		pcall(function()
			tween:Cancel()
		end)
	end
	return nil
end

local function getPanelScale(): UIScale?
	if not panelFrame then
		return nil
	end

	local uiScale = panelFrame:FindFirstChildOfClass("UIScale")
	if uiScale and uiScale:IsA("UIScale") then
		return uiScale
	end

	uiScale = Instance.new("UIScale")
	uiScale.Parent = panelFrame
	return uiScale
end

local function logVisualState(stage: string)
	local uiScale = panelFrame and panelFrame:FindFirstChildOfClass("UIScale")
	log(string.format(
		"%s guiEnabled=%s panelVisible=%s panelBg=%.2f backdropVisible=%s backdropBg=%.2f scale=%.2f",
		stage,
		tostring(gui and gui.Enabled or false),
		tostring(panelFrame and panelFrame.Visible or false),
		panelFrame and panelFrame.BackgroundTransparency or -1,
		tostring(backdropFrame and backdropFrame.Visible or false),
		backdropFrame and backdropFrame.BackgroundTransparency or -1,
		uiScale and uiScale.Scale or -1
	))
end

local function ResetForceNextModeVisualState()
	panelScaleTween = cancelTween(panelScaleTween)
	panelBackgroundTween = cancelTween(panelBackgroundTween)

	if backdropFrame then
		backdropFrame.BackgroundColor3 = BACKDROP_BG
		backdropFrame.BackgroundTransparency = BACKDROP_TRANSPARENCY
		backdropFrame.Visible = true
		backdropFrame.Active = true
		backdropFrame.ZIndex = BACKDROP_ZINDEX
	end

	if not panelFrame then
		return
	end

	local uiScale = getPanelScale()
	if uiScale then
		uiScale.Scale = 1
	end

	panelFrame.BackgroundColor3 = PANEL_BG
	panelFrame.BackgroundTransparency = PANEL_BG_TRANSPARENCY
	panelFrame.Visible = true
	panelFrame.Active = true
	panelFrame.ZIndex = PANEL_ZINDEX

	local panelStroke = panelFrame:FindFirstChildWhichIsA("UIStroke")
	if panelStroke then
		panelStroke.Color = PANEL_STROKE_COLOR
		panelStroke.Thickness = 2
		panelStroke.Transparency = PANEL_STROKE_TRANSPARENCY
	end

	local studTex = panelFrame:FindFirstChild("StudTexture")
	if studTex and studTex:IsA("ImageLabel") then
		studTex.Visible = true
		studTex.ImageTransparency = STUD_TEXTURE_TRANSPARENCY
		studTex.ImageColor3 = Color3.fromRGB(255, 255, 255)
	end

	local closeBtn = panelFrame:FindFirstChild("CloseBtn")
	if closeBtn and closeBtn:IsA("TextButton") then
		closeBtn.Visible = true
		closeBtn.Active = true
		closeBtn.AutoButtonColor = true
		closeBtn.BackgroundTransparency = CLOSE_BTN_TRANSPARENCY
	end

	for _, buttonName in ipairs({ "BrainrotBtn", "NormalBtn" }) do
		local button = panelFrame:FindFirstChild(buttonName, true)
		if button and button:IsA("TextButton") then
			button.Visible = true
			button.Active = true
			button.AutoButtonColor = true
			button.BackgroundTransparency = BUTTON_BG_TRANSPARENCY

			local darkOverlay = button:FindFirstChild("DarkOverlay")
			if darkOverlay and darkOverlay:IsA("Frame") then
				darkOverlay.Visible = true
				darkOverlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
				darkOverlay.BackgroundTransparency = BUTTON_OVERLAY_TRANSPARENCY
			end
		end
	end

	logVisualState("ResetVisualState")
end

local function playOpenAnimation()
	local uiScale = getPanelScale()
	if not uiScale then
		return
	end

	panelScaleTween = cancelTween(panelScaleTween)
	panelBackgroundTween = cancelTween(panelBackgroundTween)

	uiScale.Scale = ANIM.PopupOpenStartScale
	panelScaleTween = AnimUtil.Tween(
		uiScale,
		{ Scale = 1 },
		ANIM.PopupOpenDuration,
		ANIM.PopupOpenEase,
		Enum.EasingDirection.Out
	)
end

local function playCloseAnimation(closeVersion: number)
	if not panelFrame then
		return
	end

	local uiScale = getPanelScale()
	panelScaleTween = cancelTween(panelScaleTween)
	panelBackgroundTween = cancelTween(panelBackgroundTween)

	if uiScale then
		panelScaleTween = AnimUtil.Tween(
			uiScale,
			{ Scale = ANIM.PopupCloseTargetScale },
			ANIM.PopupCloseDuration,
			ANIM.PopupCloseEase,
			Enum.EasingDirection.In
		)
	end

	panelBackgroundTween = AnimUtil.Tween(
		panelFrame,
		{ BackgroundTransparency = 1 },
		ANIM.PopupCloseDuration,
		Enum.EasingStyle.Quad,
		Enum.EasingDirection.In
	)

	logVisualState("HideStart")

	task.delay(ANIM.PopupCloseDuration, function()
		if lifecycleVersion ~= closeVersion or visible then
			log("Hide completion skipped due to newer lifecycle state")
			return
		end

		if gui then
			gui.Enabled = false
		end
		if backdropFrame then
			backdropFrame.Visible = false
		end
		if panelFrame then
			panelFrame.Visible = false
		end

		logVisualState("HideComplete")
	end)
end

local function hidePanel()
	if not visible then
		log("Hide skipped: panel already closed")
		return
	end

	visible = false
	setGuiPreferredEnabled(false)
	lifecycleVersion += 1
	playCloseAnimation(lifecycleVersion)

	log("Hidden")
	if closeCallback then
		closeCallback()
	end
end

local function requestForceMode(requestedMode: string)
	if promptRemote then
		promptRemote:FireServer(requestedMode)
	end
	log("Prompt requested for mode:", requestedMode)
	hidePanel()
end

local function createChoiceButton(
	parent: Instance,
	name: string,
	label: string,
	imageId: string,
	bgColor: Color3,
	layoutOrder: number,
	onClick: () -> ()
): TextButton
	local btn = Instance.new("TextButton")
	btn.Name = name
	btn.Size = UDim2.fromOffset(190, 124)
	btn.BackgroundColor3 = bgColor
	btn.BackgroundTransparency = 0.08
	btn.BorderSizePixel = 0
	btn.Text = ""
	btn.AutoButtonColor = true
	btn.LayoutOrder = layoutOrder
	btn.ClipsDescendants = true
	btn.ZIndex = PANEL_ZINDEX + 4
	btn.Parent = parent

	Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 12)

	local btnStroke = Instance.new("UIStroke")
	btnStroke.Color = Color3.fromRGB(60, 65, 85)
	btnStroke.Thickness = 2.5
	btnStroke.Transparency = 0.3
	btnStroke.Parent = btn

	local bgImage = Instance.new("ImageLabel")
	bgImage.Name = "BackgroundImage"
	bgImage.Position = UDim2.fromScale(0, 0)
	bgImage.Size = UDim2.fromScale(1, 1)
	bgImage.BackgroundTransparency = 1
	bgImage.Image = imageId
	bgImage.ScaleType = Enum.ScaleType.Crop
	bgImage.ZIndex = PANEL_ZINDEX + 5
	bgImage.Parent = btn

	local darkOverlay = Instance.new("Frame")
	darkOverlay.Name = "DarkOverlay"
	darkOverlay.Position = UDim2.fromScale(0, 0)
	darkOverlay.Size = UDim2.fromScale(1, 1)
	darkOverlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	darkOverlay.BackgroundTransparency = 0.5
	darkOverlay.BorderSizePixel = 0
	darkOverlay.ZIndex = PANEL_ZINDEX + 6
	darkOverlay.Parent = btn

	local lblText = Instance.new("TextLabel")
	lblText.Name = "Label"
	lblText.AnchorPoint = Vector2.new(0.5, 0.5)
	lblText.Position = UDim2.fromScale(0.5, 0.42)
	lblText.Size = UDim2.new(1, -16, 0, 28)
	lblText.BackgroundTransparency = 1
	lblText.Font = Enum.Font.GothamBold
	lblText.TextColor3 = TEXT_COLOR
	lblText.TextSize = 15
	lblText.Text = label
	lblText.TextWrapped = true
	lblText.ZIndex = PANEL_ZINDEX + 7
	lblText.Parent = btn

	local lblStroke = Instance.new("UIStroke")
	lblStroke.Color = Color3.fromRGB(0, 0, 0)
	lblStroke.Thickness = 2
	lblStroke.Parent = lblText

	local priceLbl = Instance.new("TextLabel")
	priceLbl.Name = "PriceLabel"
	priceLbl.AnchorPoint = Vector2.new(0.5, 1)
	priceLbl.Position = UDim2.new(0.5, 0, 1, -12)
	priceLbl.Size = UDim2.new(1, -12, 0, 22)
	priceLbl.BackgroundTransparency = 1
	priceLbl.Font = Enum.Font.GothamBold
	priceLbl.TextColor3 = Color3.fromRGB(255, 240, 185)
	priceLbl.TextSize = 15
	priceLbl.Text = "5 ROBUX"
	priceLbl.ZIndex = PANEL_ZINDEX + 7
	priceLbl.Parent = btn

	local priceStroke = Instance.new("UIStroke")
	priceStroke.Color = Color3.fromRGB(0, 0, 0)
	priceStroke.Thickness = 1.5
	priceStroke.Parent = priceLbl

	btn.MouseEnter:Connect(function()
		TweenService:Create(darkOverlay, TweenInfo.new(0.15), { BackgroundTransparency = 0.64 }):Play()
	end)

	btn.MouseLeave:Connect(function()
		TweenService:Create(darkOverlay, TweenInfo.new(0.15), { BackgroundTransparency = 0.5 }):Play()
	end)

	btn.MouseButton1Click:Connect(onClick)

	return btn
end

local function createGui()
	if gui and gui.Parent then
		return
	end

	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui then
		return
	end

	gui = Instance.new("ScreenGui")
	gui.Name = "ForceNextModeGui"
	gui.DisplayOrder = MODAL_DISPLAY_ORDER
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Global
	gui.Enabled = false
	gui.Parent = playerGui
	setGuiPreferredEnabled(false)

	backdropFrame = Instance.new("Frame")
	backdropFrame.Name = "Backdrop"
	backdropFrame.Size = UDim2.fromScale(1, 1)
	backdropFrame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	backdropFrame.BackgroundTransparency = 0.45
	backdropFrame.BorderSizePixel = 0
	backdropFrame.Visible = false
	backdropFrame.Active = true
	backdropFrame.ZIndex = BACKDROP_ZINDEX
	backdropFrame.Parent = gui

	panelFrame = Instance.new("Frame")
	panelFrame.Name = "ForceNextModePanel"
	panelFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	panelFrame.Position = UDim2.fromScale(0.5, 0.43)
	panelFrame.Size = UDim2.fromOffset(620, 228)
	panelFrame.BackgroundColor3 = PANEL_BG
	panelFrame.BackgroundTransparency = 0
	panelFrame.BorderSizePixel = 0
	panelFrame.Visible = false
	panelFrame.Active = true
	panelFrame.ZIndex = PANEL_ZINDEX
	panelFrame.ClipsDescendants = true
	panelFrame.Parent = gui

	Instance.new("UICorner", panelFrame).CornerRadius = UDim.new(0, 16)

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(255, 255, 255)
	stroke.Thickness = 2
	stroke.Transparency = 0.3
	stroke.Parent = panelFrame

	local studTex = Instance.new("ImageLabel")
	studTex.Name = "StudTexture"
	studTex.Size = UDim2.fromScale(1, 1)
	studTex.Position = UDim2.fromScale(0, 0)
	studTex.BackgroundTransparency = 1
	studTex.Image = "rbxassetid://84772207963553"
	studTex.ScaleType = Enum.ScaleType.Tile
	studTex.TileSize = UDim2.fromOffset(96, 96)
	studTex.ImageTransparency = 0.88
	studTex.ImageColor3 = Color3.fromRGB(255, 255, 255)
	studTex.ZIndex = PANEL_ZINDEX + 1
	studTex.Parent = panelFrame
	Instance.new("UICorner", studTex).CornerRadius = UDim.new(0, 16)

	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "CloseBtn"
	closeBtn.AnchorPoint = Vector2.new(1, 0)
	closeBtn.Position = UDim2.new(1, -6, 0, 6)
	closeBtn.Size = UDim2.fromOffset(30, 30)
	closeBtn.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
	closeBtn.BackgroundTransparency = 0.1
	closeBtn.BorderSizePixel = 0
	closeBtn.Font = Enum.Font.GothamBold
	closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	closeBtn.TextSize = 18
	closeBtn.Text = "X"
	closeBtn.AutoButtonColor = true
	closeBtn.ZIndex = PANEL_ZINDEX + 10
	closeBtn.Parent = panelFrame

	Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 8)

	local closeBtnStroke = Instance.new("UIStroke")
	closeBtnStroke.Color = Color3.fromRGB(120, 30, 30)
	closeBtnStroke.Thickness = 1.5
	closeBtnStroke.Parent = closeBtn

	closeBtn.MouseButton1Click:Connect(function()
		hidePanel()
	end)

	titleLabel = Instance.new("TextLabel")
	titleLabel.Name = "Title"
	titleLabel.AnchorPoint = Vector2.new(0.5, 0)
	titleLabel.Position = UDim2.new(0.5, 0, 0, 14)
	titleLabel.Size = UDim2.new(1, -20, 0, 30)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Font = Enum.Font.GothamBold
	titleLabel.TextColor3 = HEADER_COLOR
	titleLabel.TextSize = 22
	titleLabel.Text = "FORCE NEXT MODE!"
	titleLabel.ZIndex = PANEL_ZINDEX + 2
	titleLabel.Parent = panelFrame

	local titleStroke = Instance.new("UIStroke")
	titleStroke.Color = Color3.fromRGB(0, 0, 0)
	titleStroke.Thickness = 2
	titleStroke.Parent = titleLabel

	subtitleLabel = Instance.new("TextLabel")
	subtitleLabel.Name = "Subtitle"
	subtitleLabel.AnchorPoint = Vector2.new(0.5, 0)
	subtitleLabel.Position = UDim2.new(0.5, 0, 0, 44)
	subtitleLabel.Size = UDim2.new(1, -20, 0, 18)
	subtitleLabel.BackgroundTransparency = 1
	subtitleLabel.Font = Enum.Font.GothamSemibold
	subtitleLabel.TextColor3 = Color3.fromRGB(180, 185, 200)
	subtitleLabel.TextSize = 13
	subtitleLabel.Text = ""
	subtitleLabel.ZIndex = PANEL_ZINDEX + 2
	subtitleLabel.Parent = panelFrame

	local btnContainer = Instance.new("Frame")
	btnContainer.Name = "Buttons"
	btnContainer.AnchorPoint = Vector2.new(0.5, 0)
	btnContainer.Position = UDim2.new(0.5, 0, 0, 74)
	btnContainer.Size = UDim2.new(1, -32, 0, 132)
	btnContainer.BackgroundTransparency = 1
	btnContainer.ZIndex = PANEL_ZINDEX + 2
	btnContainer.Parent = panelFrame

	local listLayout = Instance.new("UIListLayout")
	listLayout.FillDirection = Enum.FillDirection.Horizontal
	listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	listLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	listLayout.Padding = UDim.new(0, 18)
	listLayout.Parent = btnContainer

	createChoiceButton(
		btnContainer,
		"BrainrotBtn",
		"Save the Brainrot",
		BRAINROT_MODE_IMAGE,
		BTN_BRAINROT_COLOR,
		1,
		function()
			requestForceMode("Brainrot")
		end
	)

	createChoiceButton(
		btnContainer,
		"NormalBtn",
		"Normal Mode",
		NORMAL_MODE_IMAGE,
		BTN_NORMAL_COLOR,
		2,
		function()
			requestForceMode("Normal")
		end
	)

	local footer = Instance.new("TextLabel")
	footer.Name = "Footer"
	footer.AnchorPoint = Vector2.new(0.5, 1)
	footer.Position = UDim2.new(0.5, 0, 1, -10)
	footer.Size = UDim2.new(1, -24, 0, 20)
	footer.BackgroundTransparency = 1
	footer.Font = Enum.Font.GothamSemibold
	footer.TextColor3 = Color3.fromRGB(220, 225, 240)
	footer.TextSize = 13
	footer.Text = "This does not cast a real vote. Purchase validation is server-side."
	footer.ZIndex = PANEL_ZINDEX + 2
	footer.Parent = panelFrame

	refreshSubtitle()
end

function ForceNextModePanel.Init(onClose)
	if initialized then
		return
	end
	initialized = true
	closeCallback = onClose

	createGui()
	ResetForceNextModeVisualState()
	if backdropFrame then
		backdropFrame.Visible = false
	end
	if panelFrame then
		panelFrame.Visible = false
	end
	if gui then
		gui.Enabled = false
	end

	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
		if remotes then
			promptRemote = remotes:WaitForChild("ForceNextModePromptRequest", 15)
		end

		local matchStatus = ReplicatedStorage:WaitForChild("MatchStatus", 15)
		if matchStatus then
			local stateInst = matchStatus:WaitForChild("State", 5)
			local voteActiveInst = matchStatus:WaitForChild("ModeVoteActive", 5)

			if stateInst and stateInst:IsA("StringValue") then
				stateValue = stateInst
				stateValue.Changed:Connect(function()
					refreshSubtitle()
					if isPlayingState() and visible then
						hidePanel()
					end
				end)
			end

			if voteActiveInst and voteActiveInst:IsA("BoolValue") then
				voteActiveValue = voteActiveInst
				voteActiveValue.Changed:Connect(function()
					refreshSubtitle()
				end)
			end
		end

		refreshSubtitle()
	end)

	log("Initialized")
end

function ForceNextModePanel.Show()
	if visible then
		log("Show skipped: panel already open")
		return
	end

	if isPlayingState() then
		log("Show skipped: match is already playing")
		return
	end

	if not gui then
		createGui()
	end
	if not gui or not panelFrame then
		return
	end

	lifecycleVersion += 1
	refreshSubtitle()
	visible = true
	setGuiPreferredEnabled(true)
	ResetForceNextModeVisualState()
	gui.Enabled = true
	playOpenAnimation()
	logVisualState("Show")
	log("Shown")
end

function ForceNextModePanel.Hide()
	hidePanel()
end

function ForceNextModePanel.Toggle()
	if visible then
		hidePanel()
	else
		ForceNextModePanel.Show()
	end
end

function ForceNextModePanel.IsVisible(): boolean
	return visible
end

return ForceNextModePanel
