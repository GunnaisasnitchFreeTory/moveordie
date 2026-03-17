--[[
	MatchResultsPanel
	Auto-shows at end of match when MatchResultsEvent fires.
	Displays placement, coin rewards, player rankings, and crown progression bar.

	NOT a standard UIController panel — cannot be toggled by user.
	Self-dismisses after the results phase or on state transition.
	Can also be closed via X button, ESC, or clicking outside.

	Reliability:
	  • Uses a dedicated ScreenGui (DisplayOrder 100) so no other panel can
	    block the close button.
	  • Hooks MatchStatus.State (replicated StringValue) to auto-close when
	    the server transitions out of "Ending".
	  • Hard failsafe timer as final backup.
	  • UIScale tween starts AFTER final card size is set (no mid-tween shift).

	API:
	  Init(screenGui)  — wire up remote listener
	  Show(data)       — build + display results
	  Hide()           — fade out + destroy
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared")
local UIConfig = require(Shared:WaitForChild("UIConfig"))
local DEBUG_LOGS = RunService:IsStudio() and UIConfig.DebugLogs == true

local Client = script.Parent
local AnimUtil = require(Client:WaitForChild("AnimUtil"))

local MatchResultsPanel = {}

local _UIController = nil
local function getUIController()
	if _UIController then return _UIController end
	pcall(function()
		local playerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
		local clientFolder = playerScripts and playerScripts:FindFirstChild("Client")
		local mod = clientFolder and clientFolder:FindFirstChild("UIController")
		if mod then _UIController = require(mod) end
	end)
	return _UIController
end

local _RewardPopup = nil
local function getRewardPopup()
	if _RewardPopup then return _RewardPopup end
	pcall(function()
		local mod = script.Parent:FindFirstChild("RewardPopup")
		if mod then _RewardPopup = require(mod) end
	end)
	return _RewardPopup
end

local _gui: ScreenGui? = nil
local _overlay: Frame? = nil
local _active = false
local _hideTimer: thread? = nil
local _escConn: RBXScriptConnection? = nil
local _stateConn: RBXScriptConnection? = nil
local _globalStateConn: RBXScriptConnection? = nil
local _matchStateVal: StringValue? = nil  -- ReplicatedStorage.MatchStatus.State

-- ═══════════════════════════════════════════
-- CONSTANTS
-- ═══════════════════════════════════════════

local DISPLAY_SECONDS = 7

local PLACEMENT_SUFFIXES = { "st", "nd", "rd" }
local function ordinal(n: number): string
	if n >= 11 and n <= 13 then return tostring(n) .. "th" end
	local s = PLACEMENT_SUFFIXES[n % 10]
	return tostring(n) .. (s or "th")
end

local PLACEMENT_COLORS = {
	[1] = Color3.fromRGB(255, 215, 0),   -- gold
	[2] = Color3.fromRGB(200, 200, 210),  -- silver
	[3] = Color3.fromRGB(205, 127, 50),   -- bronze
}

-- ═══════════════════════════════════════════
-- LAZY ITEMCATALOG
-- ═══════════════════════════════════════════
local _ItemCatalog = nil
local function getItemCatalog()
	if _ItemCatalog then return _ItemCatalog end
	pcall(function()
		local Shared = ReplicatedStorage:FindFirstChild("Shared")
		if Shared then
			local cdp = Shared:FindFirstChild("ClientDepsProvider")
			if cdp then
				local Deps = require(cdp)
				_ItemCatalog = Deps and Deps.ItemCatalog
			end
		end
	end)
	return _ItemCatalog
end

-- ═══════════════════════════════════════════
-- DISMISS
-- ═══════════════════════════════════════════
local function cleanupStaleWrappers(reason: string): number
	if not _gui or not _gui.Parent then
		return 0
	end
	local removed = 0
	for _, child in ipairs(_gui:GetChildren()) do
		if child:IsA("Frame") and child.Name == "ModalWrapper" then
			child:Destroy()
			removed += 1
		end
	end
	if removed > 0 then
		print(string.format("[MatchResultsPanel] stale cleanup reason=%s removedWrappers=%d", reason, removed))
	end
	return removed
end

function MatchResultsPanel.Hide()
	local wasActive = _active
	_active = false
	if _hideTimer then
		task.cancel(_hideTimer)
		_hideTimer = nil
	end
	if _escConn then
		_escConn:Disconnect()
		_escConn = nil
	end
	if _stateConn then
		_stateConn:Disconnect()
		_stateConn = nil
	end
	local ov = _overlay
	if ov and ov.Parent then
		local panel = ov:FindFirstChild("ResultsCard")
		print("[Modal] Hide MatchResults -> tween out -> hidden")
		if panel then
			AnimUtil.PopupClose(panel, ov)
		else
			task.delay(0.25, function()
				if ov and ov.Parent then ov:Destroy() end
			end)
		end
	end
	_overlay = nil
	cleanupStaleWrappers("Hide")
	print(string.format("[MatchResultsPanel] closed wasActive=%s", tostring(wasActive)))
end

-- ═══════════════════════════════════════════
-- SHOW
-- ═══════════════════════════════════════════
function MatchResultsPanel.Show(data)
	if not data then return end

	cleanupStaleWrappers("ShowPreOpen")

	local uic = getUIController()
	if uic and uic.CloseAllPanels then uic.CloseAllPanels() end

	local rp = getRewardPopup()
	if rp and rp.IsActive and rp.IsActive() then rp.Dismiss() end

	-- Clean up existing
	if _active then
		MatchResultsPanel.Hide()
		task.wait(0.1)
	end

	if not _gui or not _gui.Parent then return end

	_active = true
	print(string.format("[MatchResultsPanel] opened placement=%s coins=%s rankings=%d",
		tostring(data.yourPlacement),
		tostring(data.yourCoins),
		type(data.rankings) == "table" and #data.rankings or 0
	))

	local wrapper = Instance.new("Frame")
	wrapper.Name = "ModalWrapper"
	wrapper.Size = UDim2.fromScale(1, 1)
	wrapper.BackgroundTransparency = 1
	wrapper.BorderSizePixel = 0
	wrapper.ZIndex = 40
	wrapper.Parent = _gui
	_overlay = wrapper

	local clickCatcher = Instance.new("TextButton")
	clickCatcher.Name = "ClickCatcher"
	clickCatcher.Size = UDim2.fromScale(1, 1)
	clickCatcher.BackgroundTransparency = 1
	clickCatcher.BorderSizePixel = 0
	clickCatcher.Text = ""
	clickCatcher.AutoButtonColor = false
	clickCatcher.Active = true
	clickCatcher.ZIndex = 40
	clickCatcher.Parent = wrapper
	clickCatcher.MouseButton1Click:Connect(function()
		print("[MatchResultsPanel] close clicked source=overlay")
		MatchResultsPanel.Hide()
	end)

	-- ESC to close
	_escConn = UserInputService.InputBegan:Connect(function(input, processed)
		if processed then return end
		if input.KeyCode == Enum.KeyCode.Escape then
			print("[MatchResultsPanel] close clicked source=escape")
			MatchResultsPanel.Hide()
		end
	end)

	if _matchStateVal then
		_stateConn = _matchStateVal.Changed:Connect(function(newVal)
			if _active and newVal ~= "Ending" then
				print("[MatchResultsPanel] MatchStatus.State →", newVal, "— auto-closing")
				MatchResultsPanel.Hide()
			end
		end)
	end

	local CARD_W, CARD_H = 420, 480
	local card = Instance.new("TextButton")
	card.Name = "ResultsCard"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.fromOffset(CARD_W, CARD_H)
	card.BackgroundColor3 = Color3.fromRGB(20, 22, 35)
	card.BackgroundTransparency = 0.03
	card.BorderSizePixel = 0
	card.Text = ""
	card.AutoButtonColor = false
	card.ZIndex = 41
	card.Parent = wrapper

	card.MouseButton1Click:Connect(function()
		print("[MatchResultsPanel] close clicked source=card")
		MatchResultsPanel.Hide()
	end)

	Instance.new("UICorner", card).CornerRadius = UDim.new(0, 18)
	local cardStroke = Instance.new("UIStroke")
	cardStroke.Color = Color3.fromRGB(80, 100, 180)
	cardStroke.Thickness = 2
	cardStroke.Transparency = 0.2
	cardStroke.Parent = card

	-- ── Close "X" button (top-right, high ZIndex) ──
	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "CloseBtn"
	closeBtn.AnchorPoint = Vector2.new(1, 0)
	closeBtn.Position = UDim2.new(1, -6, 0, 6)
	closeBtn.Size = UDim2.fromOffset(36, 36)
	closeBtn.BackgroundColor3 = Color3.fromRGB(200, 50, 60)
	closeBtn.BackgroundTransparency = 0.15
	closeBtn.Font = Enum.Font.GothamBold
	closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	closeBtn.TextSize = 18
	closeBtn.Text = "X"
	closeBtn.BorderSizePixel = 0
	closeBtn.AutoButtonColor = true
	closeBtn.ZIndex = 55
	closeBtn.Parent = card
	Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(1, 0)
	closeBtn.MouseButton1Click:Connect(function()
		print("[MatchResultsPanel] close clicked source=button")
		MatchResultsPanel.Hide()
	end)

	local yOffset = 12

	-- ── Header: MATCH RESULTS ──
	local header = Instance.new("TextLabel")
	header.Name = "Header"
	header.AnchorPoint = Vector2.new(0.5, 0)
	header.Position = UDim2.new(0.5, 0, 0, yOffset)
	header.Size = UDim2.new(1, -20, 0, 28)
	header.BackgroundTransparency = 1
	header.Font = Enum.Font.GothamBold
	header.TextColor3 = Color3.fromRGB(255, 255, 255)
	header.TextSize = 22
	header.Text = "MATCH RESULTS"
	header.ZIndex = 42
	header.Parent = card
	local hs = Instance.new("UIStroke")
	hs.Color = Color3.fromRGB(0, 0, 0)
	hs.Thickness = 2
	hs.Parent = header
	yOffset += 34

	-- ── Your placement + rewards ──
	local placementColor = PLACEMENT_COLORS[data.yourPlacement] or Color3.fromRGB(180, 180, 200)
	local placementText = ordinal(data.yourPlacement)

	local placeLbl = Instance.new("TextLabel")
	placeLbl.AnchorPoint = Vector2.new(0.5, 0)
	placeLbl.Position = UDim2.new(0.5, 0, 0, yOffset)
	placeLbl.Size = UDim2.new(1, -20, 0, 32)
	placeLbl.BackgroundTransparency = 1
	placeLbl.Font = Enum.Font.GothamBold
	placeLbl.TextColor3 = placementColor
	placeLbl.TextSize = 28
	placeLbl.Text = placementText .. " Place"
	placeLbl.ZIndex = 42
	placeLbl.Parent = card
	local ps = Instance.new("UIStroke")
	ps.Color = Color3.fromRGB(0, 0, 0)
	ps.Thickness = 2
	ps.Parent = placeLbl
	yOffset += 36

	local rewardLabelText = if data.yourPlacement == 1 then "Win Bonus" else "Placement Bonus"
	local coinLbl = Instance.new("TextLabel")
	coinLbl.AnchorPoint = Vector2.new(0.5, 0)
	coinLbl.Position = UDim2.new(0.5, 0, 0, yOffset)
	coinLbl.Size = UDim2.new(1, -20, 0, 20)
	coinLbl.BackgroundTransparency = 1
	coinLbl.Font = Enum.Font.GothamSemibold
	coinLbl.TextColor3 = Color3.fromRGB(255, 220, 60)
	coinLbl.TextSize = 16
	coinLbl.Text = string.format("+%d %s", data.yourCoins or 0, rewardLabelText)
	coinLbl.ZIndex = 42
	coinLbl.Parent = card
	if DEBUG_LOGS then
		print(string.format(
			"[MatchResultsPanel] placement=%s rewardLabel=%s amount=%s",
			tostring(data.yourPlacement),
			rewardLabelText,
			tostring(data.yourCoins or 0)
		))
	end
	yOffset += 22

	local matchCoins = data.matchCoinsCollected or 0
	if matchCoins > 0 then
		local matchCoinLbl = Instance.new("TextLabel")
		matchCoinLbl.AnchorPoint = Vector2.new(0.5, 0)
		matchCoinLbl.Position = UDim2.new(0.5, 0, 0, yOffset)
		matchCoinLbl.Size = UDim2.new(1, -20, 0, 18)
		matchCoinLbl.BackgroundTransparency = 1
		matchCoinLbl.Font = Enum.Font.GothamSemibold
		matchCoinLbl.TextColor3 = Color3.fromRGB(100, 220, 255)
		matchCoinLbl.TextSize = 14
		matchCoinLbl.Text = string.format("Coins Collected: %d", matchCoins)
		matchCoinLbl.ZIndex = 42
		matchCoinLbl.Parent = card
		yOffset += 20

		local totalEarned = (data.yourCoins or 0) + matchCoins
		local totalLbl = Instance.new("TextLabel")
		totalLbl.AnchorPoint = Vector2.new(0.5, 0)
		totalLbl.Position = UDim2.new(0.5, 0, 0, yOffset)
		totalLbl.Size = UDim2.new(1, -20, 0, 18)
		totalLbl.BackgroundTransparency = 1
		totalLbl.Font = Enum.Font.GothamBold
		totalLbl.TextColor3 = Color3.fromRGB(255, 255, 255)
		totalLbl.TextSize = 14
		totalLbl.Text = string.format("Total Earned: %d", totalEarned)
		totalLbl.ZIndex = 42
		totalLbl.Parent = card
		local ts = Instance.new("UIStroke")
		ts.Color = Color3.fromRGB(0, 0, 0)
		ts.Thickness = 1
		ts.Parent = totalLbl
		yOffset += 20
	end
	yOffset += 4

	-- Separator
	local sep1 = Instance.new("Frame")
	sep1.Size = UDim2.new(1, -30, 0, 1)
	sep1.Position = UDim2.new(0, 15, 0, yOffset)
	sep1.BackgroundColor3 = Color3.fromRGB(60, 70, 110)
	sep1.BackgroundTransparency = 0.3
	sep1.BorderSizePixel = 0
	sep1.ZIndex = 42
	sep1.Parent = card
	yOffset += 8

	-- ── Player rankings list ──
	local rankingsData = data.rankings or {}
	local listHeight = math.min(#rankingsData * 24, 120)

	local listFrame = Instance.new("ScrollingFrame")
	listFrame.Name = "RankingsList"
	listFrame.AnchorPoint = Vector2.new(0.5, 0)
	listFrame.Position = UDim2.new(0.5, 0, 0, yOffset)
	listFrame.Size = UDim2.new(1, -24, 0, listHeight)
	listFrame.BackgroundTransparency = 1
	listFrame.BorderSizePixel = 0
	listFrame.ScrollBarThickness = 3
	listFrame.ScrollBarImageColor3 = Color3.fromRGB(100, 110, 150)
	listFrame.CanvasSize = UDim2.fromOffset(0, #rankingsData * 24)
	listFrame.ZIndex = 42
	listFrame.Parent = card

	local listLayout = Instance.new("UIListLayout")
	listLayout.FillDirection = Enum.FillDirection.Vertical
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Padding = UDim.new(0, 2)
	listLayout.Parent = listFrame

	for i, r in ipairs(rankingsData) do
		local row = Instance.new("Frame")
		row.Name = "Row" .. i
		row.Size = UDim2.new(1, 0, 0, 22)
		row.BackgroundTransparency = 1
		row.LayoutOrder = i
		row.ZIndex = 43
		row.Parent = listFrame

		local isYou = r.playerName == LocalPlayer.Name
		local rowColor = isYou and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(160, 170, 200)
		local rowFont = isYou and Enum.Font.GothamBold or Enum.Font.Gotham

		local placeCol = PLACEMENT_COLORS[r.placement] or Color3.fromRGB(140, 140, 160)

		local placeTxt = Instance.new("TextLabel")
		placeTxt.Size = UDim2.new(0, 30, 1, 0)
		placeTxt.Position = UDim2.fromOffset(4, 0)
		placeTxt.BackgroundTransparency = 1
		placeTxt.Font = Enum.Font.GothamBold
		placeTxt.TextColor3 = placeCol
		placeTxt.TextSize = 13
		placeTxt.Text = "#" .. tostring(r.placement)
		placeTxt.TextXAlignment = Enum.TextXAlignment.Left
		placeTxt.ZIndex = 43
		placeTxt.Parent = row

		local nameTxt = Instance.new("TextLabel")
		nameTxt.Size = UDim2.new(1, -90, 1, 0)
		nameTxt.Position = UDim2.fromOffset(36, 0)
		nameTxt.BackgroundTransparency = 1
		nameTxt.Font = rowFont
		nameTxt.TextColor3 = rowColor
		nameTxt.TextSize = 13
		nameTxt.Text = r.playerName .. (isYou and " (You)" or "")
		nameTxt.TextXAlignment = Enum.TextXAlignment.Left
		nameTxt.TextTruncate = Enum.TextTruncate.AtEnd
		nameTxt.ZIndex = 43
		nameTxt.Parent = row

		local rMatchCoins = r.matchCoinsCollected or 0
		if rMatchCoins > 0 then
			local collectedTxt = Instance.new("TextLabel")
			collectedTxt.Size = UDim2.new(0, 46, 1, 0)
			collectedTxt.AnchorPoint = Vector2.new(1, 0)
			collectedTxt.Position = UDim2.new(1, -56, 0, 0)
			collectedTxt.BackgroundTransparency = 1
			collectedTxt.Font = Enum.Font.Gotham
			collectedTxt.TextColor3 = Color3.fromRGB(100, 220, 255)
			collectedTxt.TextSize = 11
			collectedTxt.Text = string.format("[%d]", rMatchCoins)
			collectedTxt.TextXAlignment = Enum.TextXAlignment.Right
			collectedTxt.ZIndex = 43
			collectedTxt.Parent = row
		end

		local coinsTxt = Instance.new("TextLabel")
		coinsTxt.Size = UDim2.new(0, 50, 1, 0)
		coinsTxt.AnchorPoint = Vector2.new(1, 0)
		coinsTxt.Position = UDim2.new(1, -4, 0, 0)
		coinsTxt.BackgroundTransparency = 1
		coinsTxt.Font = Enum.Font.GothamSemibold
		coinsTxt.TextColor3 = Color3.fromRGB(255, 220, 60)
		coinsTxt.TextSize = 12
		coinsTxt.Text = "+" .. tostring(r.coins)
		coinsTxt.TextXAlignment = Enum.TextXAlignment.Right
		coinsTxt.ZIndex = 43
		coinsTxt.Parent = row
	end
	yOffset += listHeight + 10

	-- Separator
	local sep2 = Instance.new("Frame")
	sep2.Size = UDim2.new(1, -30, 0, 1)
	sep2.Position = UDim2.new(0, 15, 0, yOffset)
	sep2.BackgroundColor3 = Color3.fromRGB(60, 70, 110)
	sep2.BackgroundTransparency = 0.3
	sep2.BorderSizePixel = 0
	sep2.ZIndex = 42
	sep2.Parent = card
	yOffset += 10

	-- ══════════════════════════════════════════════
	-- CROWN PROGRESSION BAR
	-- ══════════════════════════════════════════════
	local prevM = data.prevMilestone or { wins = 0, crownId = "" }
	local nextM = data.nextMilestone
	local lifetimeWins = data.lifetimeWins or 0
	local crownGranted = data.crownGranted

	local BAR_H = 22
	local BAR_W = CARD_W - 50

	-- Section label
	local crownLabel = Instance.new("TextLabel")
	crownLabel.AnchorPoint = Vector2.new(0.5, 0)
	crownLabel.Position = UDim2.new(0.5, 0, 0, yOffset)
	crownLabel.Size = UDim2.new(1, -30, 0, 18)
	crownLabel.BackgroundTransparency = 1
	crownLabel.Font = Enum.Font.GothamBold
	crownLabel.TextColor3 = Color3.fromRGB(255, 215, 0)
	crownLabel.TextSize = 13
	crownLabel.Text = "CROWN PROGRESS"
	crownLabel.ZIndex = 42
	crownLabel.Parent = card
	yOffset += 22

	-- Progress bar background
	local barBg = Instance.new("Frame")
	barBg.Name = "BarBg"
	barBg.AnchorPoint = Vector2.new(0.5, 0)
	barBg.Position = UDim2.new(0.5, 0, 0, yOffset)
	barBg.Size = UDim2.fromOffset(BAR_W, BAR_H)
	barBg.BackgroundColor3 = Color3.fromRGB(35, 38, 55)
	barBg.BorderSizePixel = 0
	barBg.ZIndex = 42
	barBg.Parent = card
	Instance.new("UICorner", barBg).CornerRadius = UDim.new(0, 8)

	-- Progress bar fill
	local fillFraction = 0
	if nextM and nextM.wins > prevM.wins then
		fillFraction = math.clamp((lifetimeWins - prevM.wins) / (nextM.wins - prevM.wins), 0, 1)
	elseif not nextM then
		fillFraction = 1
	end

	local barFill = Instance.new("Frame")
	barFill.Name = "BarFill"
	barFill.Size = UDim2.new(0, 0, 1, 0)
	barFill.BackgroundColor3 = Color3.fromRGB(80, 200, 120)
	barFill.BorderSizePixel = 0
	barFill.ZIndex = 43
	barFill.Parent = barBg
	Instance.new("UICorner", barFill).CornerRadius = UDim.new(0, 8)

	local targetFillW = math.floor(BAR_W * fillFraction)
	task.delay(0.3, function()
		if barFill and barFill.Parent then
			TweenService:Create(barFill, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Size = UDim2.new(0, targetFillW, 1, 0)
			}):Play()
		end
	end)

	-- Wins text overlay
	local winsText = Instance.new("TextLabel")
	winsText.AnchorPoint = Vector2.new(0.5, 0.5)
	winsText.Position = UDim2.fromScale(0.5, 0.5)
	winsText.Size = UDim2.fromScale(1, 1)
	winsText.BackgroundTransparency = 1
	winsText.Font = Enum.Font.GothamBold
	winsText.TextColor3 = Color3.fromRGB(255, 255, 255)
	winsText.TextSize = 12
	winsText.ZIndex = 44
	winsText.Parent = barBg
	local ws = Instance.new("UIStroke")
	ws.Color = Color3.fromRGB(0, 0, 0)
	ws.Thickness = 1.5
	ws.Parent = winsText

	if nextM then
		winsText.Text = string.format("%d / %d Wins", lifetimeWins, nextM.wins)
	else
		winsText.Text = string.format("%d Wins (All Crowns!)", lifetimeWins)
	end

	-- Crown icon at the right end of the bar
	if nextM and nextM.crownId then
		local IC = getItemCatalog()
		local crownImage = ""
		if IC and IC.Crowns and IC.Crowns[nextM.crownId] then
			crownImage = IC.Crowns[nextM.crownId].image or ""
		end
		if crownImage ~= "" then
			local crownIcon = Instance.new("ImageLabel")
			crownIcon.Name = "CrownIcon"
			crownIcon.AnchorPoint = Vector2.new(0.5, 0.5)
			crownIcon.Position = UDim2.new(1, 16, 0.5, 0)
			crownIcon.Size = UDim2.fromOffset(28, 28)
			crownIcon.BackgroundTransparency = 1
			crownIcon.Image = crownImage
			crownIcon.ScaleType = Enum.ScaleType.Fit
			crownIcon.ZIndex = 44
			crownIcon.Parent = barBg
		end
	end
	yOffset += BAR_H + 8

	-- Crown granted animation
	if crownGranted then
		local grantLbl = Instance.new("TextLabel")
		grantLbl.AnchorPoint = Vector2.new(0.5, 0)
		grantLbl.Position = UDim2.new(0.5, 0, 0, yOffset)
		grantLbl.Size = UDim2.new(1, -30, 0, 24)
		grantLbl.BackgroundTransparency = 1
		grantLbl.Font = Enum.Font.GothamBold
		grantLbl.TextColor3 = Color3.fromRGB(255, 215, 0)
		grantLbl.TextSize = 16
		grantLbl.Text = "NEW CROWN UNLOCKED!"
		grantLbl.ZIndex = 42
		grantLbl.Parent = card

		local gs = Instance.new("UIStroke")
		gs.Color = Color3.fromRGB(0, 0, 0)
		gs.Thickness = 2
		gs.Parent = grantLbl

		local grantScale = Instance.new("UIScale")
		grantScale.Scale = 0.5
		grantScale.Parent = grantLbl
	task.delay(0.6, function()
		if grantScale and grantScale.Parent then
			TweenService:Create(grantScale, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 1 }):Play()
			end
		end)
		yOffset += 28
	end

	-- Finalize card size THEN start the scale-in animation
	card.Size = UDim2.fromOffset(CARD_W, yOffset + 14)
	AnimUtil.PopupOpen(card)

	task.defer(function()
		if card and card.Parent then
			print(string.format("[Modal] Show MatchResults parent=%s anchor=(%.1f,%.1f) pos=(%.2f,%.2f) absPos=(%.0f,%.0f) absSize=(%.0f,%.0f)",
				_gui.Name,
				card.AnchorPoint.X, card.AnchorPoint.Y,
				card.Position.X.Scale, card.Position.Y.Scale,
				card.AbsolutePosition.X, card.AbsolutePosition.Y,
				card.AbsoluteSize.X, card.AbsoluteSize.Y))
		end
	end)

	-- ── Auto-dismiss timer (hard failsafe) ──
	_hideTimer = task.delay(DISPLAY_SECONDS + 0.2, function()
		if _active then
			MatchResultsPanel.Hide()
		end
	end)
end

-- ═══════════════════════════════════════════
-- INIT
-- ═══════════════════════════════════════════
function MatchResultsPanel.Init(screenGui: ScreenGui)
	-- Create a dedicated high-priority ScreenGui so results always render
	-- above other panels (PanelGui DisplayOrder 10). This ensures the
	-- close button is never blocked by Pets/Crowns/Shop overlays.
	local pg = LocalPlayer:WaitForChild("PlayerGui")
	local resultsGui = Instance.new("ScreenGui")
	resultsGui.Name = "MatchResultsGui"
	resultsGui.DisplayOrder = 100
	resultsGui.IgnoreGuiInset = true
	resultsGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	resultsGui.ResetOnSpawn = false
	resultsGui.Parent = pg
	print("[Modal] MatchResultsGui ready (DisplayOrder=100, Global ZIndex)")
	_gui = resultsGui

	-- Cache MatchStatus.State (replicated StringValue) for auto-close
	task.spawn(function()
		local matchStatus = ReplicatedStorage:WaitForChild("MatchStatus", 15)
		if matchStatus then
			_matchStateVal = matchStatus:WaitForChild("State", 10)
			if _matchStateVal then
				print("[MatchResultsPanel] MatchStatus.State cached for auto-close")
				if _globalStateConn then
					_globalStateConn:Disconnect()
				end
				_globalStateConn = _matchStateVal.Changed:Connect(function(newVal)
					if newVal ~= "Ending" then
						local cleaned = cleanupStaleWrappers("RoundTransition:" .. tostring(newVal))
						if _active or cleaned > 0 then
							print(string.format("[MatchResultsPanel] round transition cleanup state=%s cleaned=%d",
								tostring(newVal), cleaned))
						end
						MatchResultsPanel.Hide()
					end
				end)
			end
		end
	end)

	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
		if not remotes then
			warn("[MatchResultsPanel] Remotes folder not found")
			return
		end
		local event = remotes:WaitForChild("MatchResultsEvent", 15)
		if not event then
			warn("[MatchResultsPanel] MatchResultsEvent not found")
			return
		end
		event.OnClientEvent:Connect(function(payload)
			print("[MatchResultsPanel] Received match results")
			MatchResultsPanel.Show(payload)
		end)
		print("[MatchResultsPanel] Listening for MatchResultsEvent")
	end)
end

return MatchResultsPanel
