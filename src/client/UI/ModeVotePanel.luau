--[[
	ModeVotePanel
	Client-side mode vote overlay shown during intermission.

	Appears during the mode vote window and stays catch-up safe through
	replicated MatchStatus values for late joiners and slow-loading clients.

	Top-right layout:
	  Vote reopen btn : Y=8
	  Force next mode : Y=44
	  Stats btn       : Y=96
	  Daily btn       : Y=140
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnimUtil = require(script.Parent:WaitForChild("AnimUtil"))

local ModeVotePanel = {}

local player = Players.LocalPlayer
local initialized = false
local panelReady = false

local gui: ScreenGui? = nil
local panelFrame: Frame? = nil
local titleLabel: TextLabel? = nil
local subtitleLabel: TextLabel? = nil
local normalBtn: TextButton? = nil
local brainrotBtn: TextButton? = nil
local disasterBtn: TextButton? = nil
local normalCountLbl: TextLabel? = nil
local brainrotCountLbl: TextLabel? = nil
local voteRemote: RemoteEvent? = nil
local reopenBtn: TextButton? = nil
local voteLockedValue: BoolValue? = nil
local voteLockedModeValue: StringValue? = nil

local currentVote: string? = nil
local voteWindowOpen = false
local currentVoteLocked = false
local forcedVoteMode: string? = nil

local VOTE_DISPLAY_ORDER = 150

local eventQueue = {}

local PANEL_BG = Color3.fromRGB(22, 25, 38)
local HEADER_COLOR = Color3.fromRGB(255, 215, 48)
local BTN_NORMAL_COLOR = Color3.fromRGB(50, 160, 80)
local BTN_BRAINROT_COLOR = Color3.fromRGB(178, 48, 255)
local BTN_LOCKED_COLOR = Color3.fromRGB(95, 95, 105)
local BTN_SELECTED_STROKE = Color3.fromRGB(255, 255, 255)
local BTN_UNSELECTED_STROKE = Color3.fromRGB(60, 65, 85)
local TEXT_COLOR = Color3.fromRGB(255, 255, 255)

local NORMAL_MODE_IMAGE = "rbxassetid://140656133488408"
local BRAINROT_MODE_IMAGE = "rbxassetid://85473787445447"

local updateSelection

local function isPlayerAFK(): boolean
	local state = player:GetAttribute("PlayerState")
	return state == "AFK"
end

local function setGuiPreferredEnabled(enabled: boolean)
	if gui then
		gui:SetAttribute("PreferredEnabled", enabled)
	end
end

local function getModeDisplayName(modeName: string?): string
	if modeName == "Brainrot" then
		return "Save the Brainrot"
	end
	return "Normal Mode"
end

local function setVoteLockState(locked: boolean, forcedMode: string?)
	currentVoteLocked = locked == true
	if currentVoteLocked and (forcedMode == "Normal" or forcedMode == "Brainrot") then
		forcedVoteMode = forcedMode
	else
		forcedVoteMode = nil
	end

	if titleLabel then
		titleLabel.Text = currentVoteLocked and "NEXT MODE LOCKED" or "CHOOSE NEXT MODE"
	end

	if subtitleLabel then
		if currentVoteLocked then
			subtitleLabel.Text = string.format(
				"Voting is locked. Next match is forced to %s.",
				getModeDisplayName(forcedVoteMode)
			)
		else
			subtitleLabel.Text = "Vote for the next match mode"
		end
	end
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
	gui.Name = "ModeVoteGui"
	gui.DisplayOrder = VOTE_DISPLAY_ORDER
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Global
	gui.Enabled = false
	gui.Parent = playerGui
	setGuiPreferredEnabled(false)

	panelFrame = Instance.new("Frame")
	panelFrame.Name = "VotePanel"
	panelFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	panelFrame.Position = UDim2.fromScale(0.5, 0.42)
	panelFrame.Size = UDim2.fromOffset(580, 220)
	panelFrame.BackgroundColor3 = PANEL_BG
	panelFrame.BackgroundTransparency = 0.04
	panelFrame.BorderSizePixel = 0
	panelFrame.Visible = false
	panelFrame.ZIndex = 2
	panelFrame.ClipsDescendants = true
	panelFrame.Parent = gui

	Instance.new("UICorner", panelFrame).CornerRadius = UDim.new(0, 16)

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(60, 65, 85)
	stroke.Thickness = 2
	stroke.Transparency = 0.3
	stroke.Parent = panelFrame

	local studTex = Instance.new("ImageLabel")
	studTex.Name = "StudTexture"
	studTex.Size = UDim2.fromScale(1, 1)
	studTex.Position = UDim2.fromScale(0, 0)
	studTex.BackgroundTransparency = 1
	studTex.Image = "rbxassetid://70851348312450"
	studTex.ScaleType = Enum.ScaleType.Tile
	studTex.TileSize = UDim2.fromOffset(96, 96)
	studTex.ImageTransparency = 0.88
	studTex.ImageColor3 = Color3.fromRGB(255, 255, 255)
	studTex.ZIndex = 2
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
	closeBtn.ZIndex = 10
	closeBtn.Parent = panelFrame

	Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 8)

	local closeBtnStroke = Instance.new("UIStroke")
	closeBtnStroke.Color = Color3.fromRGB(120, 30, 30)
	closeBtnStroke.Thickness = 1.5
	closeBtnStroke.Parent = closeBtn

	closeBtn.MouseButton1Click:Connect(function()
		if panelFrame then
			AnimUtil.PopupClose(panelFrame)
		end
		task.delay(0.25, function()
			if panelFrame then
				panelFrame.Visible = false
			end
			if reopenBtn then
				reopenBtn.Visible = voteWindowOpen
			end
		end)
		print("[ModeVote] Closed by player")
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
	titleLabel.Text = "CHOOSE NEXT MODE"
	titleLabel.ZIndex = 3
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
	subtitleLabel.Text = "Vote for the next match mode"
	subtitleLabel.ZIndex = 3
	subtitleLabel.Parent = panelFrame

	local btnContainer = Instance.new("Frame")
	btnContainer.Name = "Buttons"
	btnContainer.AnchorPoint = Vector2.new(0.5, 0)
	btnContainer.Position = UDim2.new(0.5, 0, 0, 72)
	btnContainer.Size = UDim2.new(1, -32, 0, 130)
	btnContainer.BackgroundTransparency = 1
	btnContainer.ZIndex = 3
	btnContainer.Parent = panelFrame

	local listLayout = Instance.new("UIListLayout")
	listLayout.FillDirection = Enum.FillDirection.Horizontal
	listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	listLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	listLayout.Padding = UDim.new(0, 16)
	listLayout.Parent = btnContainer

	local function createVoteButton(
		buttonName: string,
		label: string,
		imageId: string,
		bgColor: Color3,
		layoutOrder: number,
		locked: boolean
	)
		local btn = Instance.new("TextButton")
		btn.Name = buttonName
		btn.Size = UDim2.fromOffset(170, 120)
		btn.BackgroundColor3 = bgColor
		btn.BackgroundTransparency = locked and 0.2 or 0.08
		btn.BorderSizePixel = 0
		btn.Text = ""
		btn.AutoButtonColor = not locked
		btn.Active = not locked
		btn.LayoutOrder = layoutOrder
		btn.ClipsDescendants = true
		btn.ZIndex = 4
		btn.Parent = btnContainer

		Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 12)

		local btnStroke = Instance.new("UIStroke")
		btnStroke.Name = "SelectStroke"
		btnStroke.Color = BTN_UNSELECTED_STROKE
		btnStroke.Thickness = 2.5
		btnStroke.Transparency = 0.3
		btnStroke.Parent = btn

		if imageId ~= "" then
			local bgImage = Instance.new("ImageLabel")
			bgImage.Name = "BackgroundImage"
			bgImage.Position = UDim2.fromScale(0, 0)
			bgImage.Size = UDim2.fromScale(1, 1)
			bgImage.BackgroundTransparency = 1
			bgImage.Image = imageId
			bgImage.ScaleType = Enum.ScaleType.Crop
			if locked then
				bgImage.ImageColor3 = Color3.fromRGB(125, 125, 125)
			end
			bgImage.ZIndex = 5
			bgImage.Parent = btn
		end

		local darkOverlay = Instance.new("Frame")
		darkOverlay.Name = "DarkOverlay"
		darkOverlay.Position = UDim2.fromScale(0, 0)
		darkOverlay.Size = UDim2.fromScale(1, 1)
		darkOverlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		darkOverlay.BackgroundTransparency = locked and 0.25 or 0.5
		darkOverlay.BorderSizePixel = 0
		darkOverlay.ZIndex = 6
		darkOverlay.Parent = btn

		local lblText = Instance.new("TextLabel")
		lblText.Name = "Label"
		lblText.AnchorPoint = Vector2.new(0.5, 0.5)
		lblText.Position = UDim2.fromScale(0.5, 0.42)
		lblText.Size = UDim2.new(1, -12, 0, 28)
		lblText.BackgroundTransparency = 1
		lblText.Font = Enum.Font.GothamBold
		lblText.TextColor3 = TEXT_COLOR
		lblText.TextSize = 15
		lblText.Text = label
		lblText.TextWrapped = true
		lblText.ZIndex = 7
		lblText.Parent = btn

		local lblStroke = Instance.new("UIStroke")
		lblStroke.Color = Color3.fromRGB(0, 0, 0)
		lblStroke.Thickness = 2
		lblStroke.Parent = lblText

		local countLbl = Instance.new("TextLabel")
		countLbl.Name = "Count"
		countLbl.AnchorPoint = Vector2.new(0.5, 1)
		countLbl.Position = UDim2.new(0.5, 0, 1, -10)
		countLbl.Size = UDim2.new(1, -12, 0, 22)
		countLbl.BackgroundTransparency = 1
		countLbl.Font = Enum.Font.GothamSemibold
		countLbl.TextColor3 = Color3.fromRGB(220, 225, 240)
		countLbl.TextSize = 16
		countLbl.Text = locked and "" or "0 votes"
		countLbl.ZIndex = 7
		countLbl.Parent = btn

		local countStroke = Instance.new("UIStroke")
		countStroke.Color = Color3.fromRGB(0, 0, 0)
		countStroke.Thickness = 1.5
		countStroke.Parent = countLbl

		if not locked then
			btn.MouseEnter:Connect(function()
				if currentVoteLocked then
					return
				end
				TweenService:Create(darkOverlay, TweenInfo.new(0.15), { BackgroundTransparency = 0.65 }):Play()
			end)
			btn.MouseLeave:Connect(function()
				if currentVoteLocked then
					return
				end
				TweenService:Create(darkOverlay, TweenInfo.new(0.15), { BackgroundTransparency = 0.5 }):Play()
			end)
		else
			local lockLbl = Instance.new("TextLabel")
			lockLbl.Name = "LockLabel"
			lockLbl.AnchorPoint = Vector2.new(0.5, 0.5)
			lockLbl.Position = UDim2.fromScale(0.5, 0.66)
			lockLbl.Size = UDim2.new(1, -12, 0, 20)
			lockLbl.BackgroundTransparency = 1
			lockLbl.Font = Enum.Font.GothamBold
			lockLbl.TextColor3 = Color3.fromRGB(230, 230, 230)
			lockLbl.TextSize = 16
			lockLbl.Text = "LOCKED"
			lockLbl.ZIndex = 7
			lockLbl.Parent = btn

			local soonLbl = Instance.new("TextLabel")
			soonLbl.Name = "ComingSoonLabel"
			soonLbl.AnchorPoint = Vector2.new(0.5, 0.5)
			soonLbl.Position = UDim2.fromScale(0.5, 0.82)
			soonLbl.Size = UDim2.new(1, -12, 0, 18)
			soonLbl.BackgroundTransparency = 1
			soonLbl.Font = Enum.Font.GothamBold
			soonLbl.TextColor3 = Color3.fromRGB(215, 215, 220)
			soonLbl.TextSize = 12
			soonLbl.Text = "coming soon"
			soonLbl.ZIndex = 7
			soonLbl.Parent = btn
		end

		return btn, countLbl
	end

	brainrotBtn, brainrotCountLbl = createVoteButton("BrainrotBtn", "Save the Brainrot", BRAINROT_MODE_IMAGE, BTN_BRAINROT_COLOR, 1, false)
	normalBtn, normalCountLbl = createVoteButton("NormalBtn", "Normal Mode", NORMAL_MODE_IMAGE, BTN_NORMAL_COLOR, 2, false)
	disasterBtn = createVoteButton("DisasterBtn", "Disaster Mode", "", BTN_LOCKED_COLOR, 3, true)
	print("[ModeVote] Added locked placeholder: Disaster Mode (disabled)")

	normalBtn.MouseButton1Click:Connect(function()
		if currentVoteLocked then
			return
		end
		if currentVote == "Normal" then
			return
		end
		currentVote = "Normal"
		updateSelection()
		if voteRemote then
			voteRemote:FireServer("Cast", "Normal")
		end
	end)

	brainrotBtn.MouseButton1Click:Connect(function()
		if currentVoteLocked then
			return
		end
		if currentVote == "Brainrot" then
			return
		end
		currentVote = "Brainrot"
		updateSelection()
		if voteRemote then
			voteRemote:FireServer("Cast", "Brainrot")
		end
	end)

	reopenBtn = Instance.new("TextButton")
	reopenBtn.Name = "ReopenVoteBtn"
	reopenBtn.AnchorPoint = Vector2.new(1, 0)
	reopenBtn.Position = UDim2.new(1, -16, 0, 8)
	reopenBtn.Size = UDim2.fromOffset(100, 36)
	reopenBtn.BackgroundColor3 = Color3.fromRGB(50, 160, 80)
	reopenBtn.BackgroundTransparency = 0.1
	reopenBtn.BorderSizePixel = 0
	reopenBtn.Font = Enum.Font.GothamBold
	reopenBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	reopenBtn.TextSize = 14
	reopenBtn.Text = "Vote"
	reopenBtn.AutoButtonColor = true
	reopenBtn.Visible = false
	reopenBtn.ZIndex = 6
	reopenBtn.Parent = gui

	Instance.new("UICorner", reopenBtn).CornerRadius = UDim.new(0, 18)

	local reopenStroke = Instance.new("UIStroke")
	reopenStroke.Color = Color3.fromRGB(30, 100, 50)
	reopenStroke.Thickness = 1.5
	reopenStroke.Parent = reopenBtn

	local reopenTextStroke = Instance.new("UIStroke")
	reopenTextStroke.Color = Color3.fromRGB(0, 0, 0)
	reopenTextStroke.Thickness = 1.5
	reopenTextStroke.Transparency = 0.2
	reopenTextStroke.Parent = reopenBtn

	reopenBtn.MouseButton1Click:Connect(function()
		if panelFrame and voteWindowOpen then
			panelFrame.BackgroundTransparency = 0.04
			panelFrame.Visible = true
			reopenBtn.Visible = false
			AnimUtil.PopupOpen(panelFrame)
			print("[ModeVote] Reopened by player")
		end
	end)
end

updateSelection = function()
	if not normalBtn or not brainrotBtn then
		return
	end

	local function applyChoiceState(btn: TextButton?, countLbl: TextLabel?, modeName: string)
		if not btn then
			return
		end

		local isForced = currentVoteLocked and forcedVoteMode == modeName
		local isSelected = (not currentVoteLocked) and currentVote == modeName
		local isHighlighted = isForced or isSelected

		local stroke = btn:FindFirstChild("SelectStroke")
		local bgImage = btn:FindFirstChild("BackgroundImage")
		local darkOverlay = btn:FindFirstChild("DarkOverlay")

		btn.Active = not currentVoteLocked
		btn.AutoButtonColor = not currentVoteLocked
		btn.BackgroundTransparency = currentVoteLocked and 0.18 or 0.08

		if stroke and stroke:IsA("UIStroke") then
			stroke.Color = isHighlighted and BTN_SELECTED_STROKE or BTN_UNSELECTED_STROKE
			stroke.Thickness = isHighlighted and 3 or 2.5
			stroke.Transparency = isHighlighted and 0 or 0.3
		end

		if bgImage and bgImage:IsA("ImageLabel") then
			bgImage.ImageColor3 = currentVoteLocked
				and (isForced and Color3.fromRGB(230, 230, 230) or Color3.fromRGB(125, 125, 125))
				or Color3.fromRGB(255, 255, 255)
		end

		if darkOverlay and darkOverlay:IsA("Frame") then
			darkOverlay.BackgroundTransparency = currentVoteLocked
				and (isForced and 0.34 or 0.18)
				or 0.5
		end

		if countLbl then
			if currentVoteLocked then
				countLbl.Text = isForced and "FORCED NEXT" or "LOCKED"
				countLbl.TextColor3 = isForced and Color3.fromRGB(255, 240, 185) or Color3.fromRGB(220, 225, 240)
			else
				countLbl.TextColor3 = Color3.fromRGB(220, 225, 240)
			end
		end
	end

	applyChoiceState(normalBtn, normalCountLbl, "Normal")
	applyChoiceState(brainrotBtn, brainrotCountLbl, "Brainrot")
end

local function showPanel(data)
	if isPlayerAFK() then
		print("[ModeVote] Skipping show -- player is AFK")
		return
	end

	if not gui then
		createGui()
	end
	if not gui or not panelFrame then
		return
	end

	currentVote = nil
	voteWindowOpen = true
	setVoteLockState(data and data.locked == true, data and data.forcedMode or nil)
	updateSelection()

	if not currentVoteLocked then
		if normalCountLbl then
			normalCountLbl.Text = "0 votes"
		end
		if brainrotCountLbl then
			brainrotCountLbl.Text = "0 votes"
		end
	end

	gui.Enabled = true
	setGuiPreferredEnabled(true)
	panelFrame.BackgroundTransparency = 0.04
	panelFrame.Visible = true
	if reopenBtn then
		reopenBtn.Visible = false
	end

	AnimUtil.PopupOpen(panelFrame)

	print(string.format(
		"[ModeVote] Showing UI displayOrder=%d enabled=%s visible=%s locked=%s forcedMode=%s",
		gui.DisplayOrder,
		tostring(gui.Enabled),
		tostring(panelFrame.Visible),
		tostring(currentVoteLocked),
		tostring(forcedVoteMode)
	))
end

local function hidePanel()
	voteWindowOpen = false
	if not gui then
		return
	end

	setGuiPreferredEnabled(false)

	if panelFrame then
		AnimUtil.PopupClose(panelFrame)
	end

	task.delay(0.25, function()
		if gui then
			gui.Enabled = false
		end
		if panelFrame then
			panelFrame.Visible = false
		end
		if reopenBtn then
			reopenBtn.Visible = false
		end
		setVoteLockState(false, nil)
	end)

	print("[ModeVote] Hidden")
end

local function updateCounts(data)
	if not data then
		return
	end

	if currentVoteLocked then
		updateSelection()
		return
	end

	local normal = data.normal or 0
	local brainrot = data.brainrot or 0

	if normalCountLbl then
		normalCountLbl.Text = normal == 1 and "1 vote" or (normal .. " votes")
	end
	if brainrotCountLbl then
		brainrotCountLbl.Text = brainrot == 1 and "1 vote" or (brainrot .. " votes")
	end
end

local function handleVoteEvent(action, data)
	print("[ModeVote] Received:", action)
	if action == "Start" then
		showPanel(data)
	elseif action == "Update" then
		updateCounts(data)
	elseif action == "End" then
		updateCounts(data)
		hidePanel()
	end
end

local function drainQueue()
	if #eventQueue == 0 then
		return
	end
	print(string.format("[ModeVote] Draining %d queued events", #eventQueue))
	for _, entry in ipairs(eventQueue) do
		handleVoteEvent(entry.action, entry.data)
	end
	table.clear(eventQueue)
end

function ModeVotePanel.Init()
	if initialized then
		return
	end
	initialized = true

	print("[ModeVote] Init starting...")
	createGui()

	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
		if not remotes then
			warn("[ModeVote] Remotes folder not found")
			return
		end

		voteRemote = remotes:WaitForChild("ModeVote", 15)
		if not voteRemote then
			warn("[ModeVote] ModeVote remote not found")
			return
		end

		voteRemote.OnClientEvent:Connect(function(action, data)
			if panelReady then
				handleVoteEvent(action, data)
			else
				table.insert(eventQueue, { action = action, data = data })
				print("[ModeVote] Queued event (panel not ready):", action)
			end
		end)

		print("[ModeVote] Connected to ModeVote remote")

		panelReady = true
		drainQueue()
		print("[ModeVote] Panel ready")

		local matchStatus = ReplicatedStorage:WaitForChild("MatchStatus", 10)
		if not matchStatus then
			warn("[ModeVote] MatchStatus folder not found - replicated catch-up disabled")
			return
		end

		local voteActiveVal = matchStatus:WaitForChild("ModeVoteActive", 5)
		local lockedVal = matchStatus:WaitForChild("ModeVoteLocked", 5)
		local lockedModeVal = matchStatus:WaitForChild("ModeVoteLockedMode", 5)

		if lockedVal and lockedVal:IsA("BoolValue") then
			voteLockedValue = lockedVal
		end
		if lockedModeVal and lockedModeVal:IsA("StringValue") then
			voteLockedModeValue = lockedModeVal
		end

		if voteActiveVal then
			if voteActiveVal.Value == true and not voteWindowOpen then
				print("[ModeVote] Replicated active detected on init - showing UI")
				showPanel({
					locked = voteLockedValue and voteLockedValue.Value or false,
					forcedMode = voteLockedModeValue and voteLockedModeValue.Value or nil,
				})
			end

			voteActiveVal.Changed:Connect(function(newVal)
				print("[ModeVote] ModeVoteActive changed to:", tostring(newVal))
				if newVal == true and not voteWindowOpen then
					print("[ModeVote] Replicated active detected - showing UI")
					showPanel({
						locked = voteLockedValue and voteLockedValue.Value or false,
						forcedMode = voteLockedModeValue and voteLockedModeValue.Value or nil,
					})
				elseif newVal == false and voteWindowOpen then
					task.delay(1.5, function()
						if not voteWindowOpen then
							return
						end
						hidePanel()
					end)
				end
			end)

			print("[ModeVote] Watching MatchStatus.ModeVoteActive for changes")
		else
			warn("[ModeVote] ModeVoteActive value not found in MatchStatus")
		end

		if voteLockedValue then
			voteLockedValue.Changed:Connect(function(newVal)
				setVoteLockState(newVal == true, voteLockedModeValue and voteLockedModeValue.Value or nil)
				updateSelection()
			end)
		end

		if voteLockedModeValue then
			voteLockedModeValue.Changed:Connect(function(newVal)
				if currentVoteLocked or (voteLockedValue and voteLockedValue.Value == true) then
					setVoteLockState(true, newVal)
					updateSelection()
				end
			end)
		end
	end)

	print("[ModeVote] Initialized")
end

return ModeVotePanel
