--[[
	ModeVotePanel
	Client-side mode vote overlay shown during intermission.

	Appears at 12s remaining, disappears when intermission ends.
	Players pick "Normal Mode" or "Save the Brainrot Mode".
	Live vote counts update in real-time.

	Features:
	  - Close button (X) to dismiss manually
	  - Small "Vote" button to reopen during vote window
	  - AFK players do NOT see the panel
	  - Panel auto-closes when intermission ends
	  - Resilient to timing: catches up via replicated ModeVoteActive value
	  - High DisplayOrder (150) + Global ZIndex so it renders above all panels

	NOT part of the "one panel at a time" system -- this is a
	priority overlay that floats above everything (including DailyRewards).

	Top-right layout (no overlaps):
	  Vote  reopen btn : Y=8   h=36 (ends Y=44)
	  Stats btn (HUD)  : Y=52  h=38 (ends Y=90)
	  Daily btn (HUD)  : Y=96  h=38 (ends Y=134)
	  KillFeed         : vertically centered at 45% (mid-right, no overlap)

	API:
		Init()
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnimUtil = require(script.Parent:WaitForChild("AnimUtil"))

local ModeVotePanel = {}

local player = Players.LocalPlayer
local initialized = false
local panelReady = false
local gui = nil
local panelFrame = nil
local normalBtn = nil
local brainrotBtn = nil
local normalCountLbl = nil
local brainrotCountLbl = nil
local currentVote = nil
local voteRemote = nil
local reopenBtn = nil
local voteWindowOpen = false

local VOTE_DISPLAY_ORDER = 150

-- Event queue: if remote fires before panel is ready, buffer events here
local eventQueue = {}

local PANEL_BG = Color3.fromRGB(22, 25, 38)
local HEADER_COLOR = Color3.fromRGB(255, 215, 48)
local BTN_NORMAL_COLOR = Color3.fromRGB(50, 160, 80)
local BTN_BRAINROT_COLOR = Color3.fromRGB(178, 48, 255)
local BTN_SELECTED_STROKE = Color3.fromRGB(255, 255, 255)
local BTN_UNSELECTED_STROKE = Color3.fromRGB(60, 65, 85)
local TEXT_COLOR = Color3.fromRGB(255, 255, 255)

local NORMAL_MODE_IMAGE = "rbxassetid://140656133488408"
local BRAINROT_MODE_IMAGE = "rbxassetid://85473787445447"

local updateSelection

local function isPlayerAFK()
	local state = player:GetAttribute("PlayerState")
	return state == "AFK"
end

local function createGui()
	if gui and gui.Parent then return end
	local pg = player:FindFirstChild("PlayerGui")
	if not pg then return end

	gui = Instance.new("ScreenGui")
	gui.Name = "ModeVoteGui"
	gui.DisplayOrder = VOTE_DISPLAY_ORDER
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Global
	gui.Enabled = false
	gui.Parent = pg

	panelFrame = Instance.new("Frame")
	panelFrame.Name = "VotePanel"
	panelFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	panelFrame.Position = UDim2.fromScale(0.5, 0.42)
	panelFrame.Size = UDim2.fromOffset(420, 220)
	panelFrame.BackgroundColor3 = PANEL_BG
	panelFrame.BackgroundTransparency = 0.04
	panelFrame.BorderSizePixel = 0
	panelFrame.ZIndex = 2
	panelFrame.Parent = gui

	panelFrame.ClipsDescendants = true
	Instance.new("UICorner", panelFrame).CornerRadius = UDim.new(0, 16)

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(60, 65, 85)
	stroke.Thickness = 2
	stroke.Transparency = 0.3
	stroke.Parent = panelFrame

	-- Fate Beams stud texture overlay
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
			if panelFrame then panelFrame.Visible = false end
			if reopenBtn then reopenBtn.Visible = voteWindowOpen end
		end)
		print("[ModeVote] Closed by player")
	end)

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.AnchorPoint = Vector2.new(0.5, 0)
	title.Position = UDim2.new(0.5, 0, 0, 14)
	title.Size = UDim2.new(1, -20, 0, 30)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextColor3 = HEADER_COLOR
	title.TextSize = 22
	title.Text = "CHOOSE NEXT MODE"
	title.ZIndex = 3
	title.Parent = panelFrame

	local titleStroke = Instance.new("UIStroke")
	titleStroke.Color = Color3.fromRGB(0, 0, 0)
	titleStroke.Thickness = 2
	titleStroke.Parent = title

	local subtitle = Instance.new("TextLabel")
	subtitle.Name = "Subtitle"
	subtitle.AnchorPoint = Vector2.new(0.5, 0)
	subtitle.Position = UDim2.new(0.5, 0, 0, 44)
	subtitle.Size = UDim2.new(1, -20, 0, 18)
	subtitle.BackgroundTransparency = 1
	subtitle.Font = Enum.Font.GothamSemibold
	subtitle.TextColor3 = Color3.fromRGB(180, 185, 200)
	subtitle.TextSize = 13
	subtitle.Text = "Vote for the next match mode"
	subtitle.ZIndex = 3
	subtitle.Parent = panelFrame

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

	local function createVoteButton(bName, label, imageId, bgColor, layoutOrder)
		local btn = Instance.new("TextButton")
		btn.Name = bName
		btn.Size = UDim2.fromOffset(180, 120)
		btn.BackgroundColor3 = bgColor
		btn.BackgroundTransparency = 0.08
		btn.BorderSizePixel = 0
		btn.Text = ""
		btn.AutoButtonColor = false
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

		local bgImage = Instance.new("ImageLabel")
		bgImage.Name = "BackgroundImage"
		bgImage.Position = UDim2.fromScale(0, 0)
		bgImage.Size = UDim2.fromScale(1, 1)
		bgImage.BackgroundTransparency = 1
		bgImage.Image = imageId
		bgImage.ScaleType = Enum.ScaleType.Crop
		bgImage.ZIndex = 5
		bgImage.Parent = btn

		local darkOverlay = Instance.new("Frame")
		darkOverlay.Name = "DarkOverlay"
		darkOverlay.Position = UDim2.fromScale(0, 0)
		darkOverlay.Size = UDim2.fromScale(1, 1)
		darkOverlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		darkOverlay.BackgroundTransparency = 0.5
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
		countLbl.Text = "0 votes"
		countLbl.ZIndex = 7
		countLbl.Parent = btn

		local countStroke = Instance.new("UIStroke")
		countStroke.Color = Color3.fromRGB(0, 0, 0)
		countStroke.Thickness = 1.5
		countStroke.Parent = countLbl

		btn.MouseEnter:Connect(function()
			TweenService:Create(darkOverlay, TweenInfo.new(0.15), { BackgroundTransparency = 0.65 }):Play()
		end)
		btn.MouseLeave:Connect(function()
			TweenService:Create(darkOverlay, TweenInfo.new(0.15), { BackgroundTransparency = 0.5 }):Play()
		end)

		return btn, countLbl
	end

	normalBtn, normalCountLbl = createVoteButton("NormalBtn", "Normal Mode", NORMAL_MODE_IMAGE, BTN_NORMAL_COLOR, 1)
	brainrotBtn, brainrotCountLbl = createVoteButton("BrainrotBtn", "Save the Brainrot", BRAINROT_MODE_IMAGE, BTN_BRAINROT_COLOR, 2)

	normalBtn.MouseButton1Click:Connect(function()
		if currentVote == "Normal" then return end
		currentVote = "Normal"
		updateSelection()
		if voteRemote then voteRemote:FireServer("Cast", "Normal") end
	end)

	brainrotBtn.MouseButton1Click:Connect(function()
		if currentVote == "Brainrot" then return end
		currentVote = "Brainrot"
		updateSelection()
		if voteRemote then voteRemote:FireServer("Cast", "Brainrot") end
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
	if not normalBtn or not brainrotBtn then return end

	local normalStroke = normalBtn:FindFirstChild("SelectStroke")
	local brainrotStroke = brainrotBtn:FindFirstChild("SelectStroke")

	if currentVote == "Normal" then
		if normalStroke then normalStroke.Color = BTN_SELECTED_STROKE; normalStroke.Thickness = 3; normalStroke.Transparency = 0 end
		if brainrotStroke then brainrotStroke.Color = BTN_UNSELECTED_STROKE; brainrotStroke.Thickness = 2.5; brainrotStroke.Transparency = 0.3 end
	elseif currentVote == "Brainrot" then
		if normalStroke then normalStroke.Color = BTN_UNSELECTED_STROKE; normalStroke.Thickness = 2.5; normalStroke.Transparency = 0.3 end
		if brainrotStroke then brainrotStroke.Color = BTN_SELECTED_STROKE; brainrotStroke.Thickness = 3; brainrotStroke.Transparency = 0 end
	else
		if normalStroke then normalStroke.Color = BTN_UNSELECTED_STROKE; normalStroke.Thickness = 2.5; normalStroke.Transparency = 0.3 end
		if brainrotStroke then brainrotStroke.Color = BTN_UNSELECTED_STROKE; brainrotStroke.Thickness = 2.5; brainrotStroke.Transparency = 0.3 end
	end
end

local function showPanel()
	if isPlayerAFK() then
		print("[ModeVote] Skipping show -- player is AFK")
		return
	end

	if not gui then createGui() end
	if not gui then return end

	currentVote = nil
	voteWindowOpen = true
	updateSelection()

	if normalCountLbl then normalCountLbl.Text = "0 votes" end
	if brainrotCountLbl then brainrotCountLbl.Text = "0 votes" end

	gui.Enabled = true
	if panelFrame then
		panelFrame.BackgroundTransparency = 0.04
		panelFrame.Visible = true
	end
	if reopenBtn then reopenBtn.Visible = false end

	if panelFrame then
		AnimUtil.PopupOpen(panelFrame)
	end

	print(string.format("[ModeVote] Showing UI displayOrder=%d enabled=%s visible=%s",
		gui.DisplayOrder, tostring(gui.Enabled), tostring(panelFrame and panelFrame.Visible)))
end

local function hidePanel()
	voteWindowOpen = false
	if not gui then return end

	if panelFrame then
		AnimUtil.PopupClose(panelFrame)
	end

	task.delay(0.25, function()
		if gui then gui.Enabled = false end
		if panelFrame then panelFrame.Visible = false end
		if reopenBtn then reopenBtn.Visible = false end
	end)

	print("[ModeVote] Hidden")
end

local function updateCounts(data)
	if not data then return end
	local normal = data.normal or 0
	local brainrot = data.brainrot or 0

	if normalCountLbl then
		normalCountLbl.Text = normal == 1 and "1 vote" or (normal .. " votes")
	end
	if brainrotCountLbl then
		brainrotCountLbl.Text = brainrot == 1 and "1 vote" or (brainrot .. " votes")
	end
end

-- Process a single remote event action
local function handleVoteEvent(action, data)
	print("[ModeVote] Received:", action)
	if action == "Start" then
		showPanel()
	elseif action == "Update" then
		updateCounts(data)
	elseif action == "End" then
		updateCounts(data)
		hidePanel()
	end
end

-- Drain any queued events that arrived before panel was ready
local function drainQueue()
	if #eventQueue == 0 then return end
	print(string.format("[ModeVote] Draining %d queued events", #eventQueue))
	for _, entry in ipairs(eventQueue) do
		handleVoteEvent(entry.action, entry.data)
	end
	table.clear(eventQueue)
end

function ModeVotePanel.Init()
	if initialized then return end
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

		-- Connect to the remote event
		voteRemote.OnClientEvent:Connect(function(action, data)
			if panelReady then
				handleVoteEvent(action, data)
			else
				table.insert(eventQueue, { action = action, data = data })
				print("[ModeVote] Queued event (panel not ready):", action)
			end
		end)

		print("[ModeVote] Connected to ModeVote remote")

		-- Mark panel as ready and drain any buffered events
		panelReady = true
		drainQueue()
		print("[ModeVote] Panel ready")

		-- ── Replicated state catch-up ──
		local matchStatus = ReplicatedStorage:WaitForChild("MatchStatus", 10)
		if matchStatus then
			local voteActiveVal = matchStatus:WaitForChild("ModeVoteActive", 5)

			if voteActiveVal then
				if voteActiveVal.Value == true and not voteWindowOpen then
					print("[ModeVote] Replicated active detected on init — showing UI")
					showPanel()
				end

				voteActiveVal.Changed:Connect(function(newVal)
					print("[ModeVote] ModeVoteActive changed to:", tostring(newVal))
					if newVal == true and not voteWindowOpen then
						print("[ModeVote] Replicated active detected — showing UI")
						showPanel()
					elseif newVal == false and voteWindowOpen then
						task.delay(1.5, function()
							if not voteWindowOpen then return end
							hidePanel()
						end)
					end
				end)

				print("[ModeVote] Watching MatchStatus.ModeVoteActive for changes")
			else
				warn("[ModeVote] ModeVoteActive value not found in MatchStatus")
			end
		else
			warn("[ModeVote] MatchStatus folder not found — replicated catch-up disabled")
		end
	end)

	print("[ModeVote] Initialized")
end

return ModeVotePanel
