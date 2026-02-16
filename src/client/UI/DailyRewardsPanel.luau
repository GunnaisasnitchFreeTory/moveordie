--[[
	DailyRewardsPanel
	Standard-size panel (matches Crate Shop) with 7-day reward grid.
	Uses Components.CreatePanel for consistent sizing/styling.

	Layout:
	  - Standard panel header ("DAILY REWARDS") — light blue theme
	  - Progress bar: "Day X / 7"
	  - Left: 3×2 grid of Day 1–6 cards
	  - Right: Large featured Day 7 card
	  - Bottom: Timer + Claim button

	API:
	  Init(screenGui, onClose)
	  Show() / Hide() / IsVisible() / Toggle()
	  TryAutoShow()
]]

local FORCE_OPEN_DAILY_ON_JOIN = true -- set false for production

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared", 60)
if not Shared then
	warn("[DailyRewardsPanel] Shared not found")
	return { Init = function() end, Show = function() end, Hide = function() end,
		IsVisible = function() return false end, Toggle = function() end, TryAutoShow = function() end }
end

local CDPModule = Shared:WaitForChild("ClientDepsProvider", 60)
if not CDPModule then
	warn("[DailyRewardsPanel] ClientDepsProvider MISSING")
	return { Init = function() end, Show = function() end, Hide = function() end,
		IsVisible = function() return false end, Toggle = function() end, TryAutoShow = function() end }
end

local ok, Deps = pcall(require, CDPModule)
if not ok or not Deps then
	warn("[DailyRewardsPanel] require(ClientDepsProvider) FAILED:", Deps)
	return { Init = function() end, Show = function() end, Hide = function() end,
		IsVisible = function() return false end, Toggle = function() end, TryAutoShow = function() end }
end

local UIConfig = Deps.UIConfig

local okConfig, DailyRewardConfig = pcall(require, Shared:WaitForChild("DailyRewardConfig", 10))
if not okConfig or not DailyRewardConfig then
	warn("[DailyRewardsPanel] DailyRewardConfig not found")
	return { Init = function() end, Show = function() end, Hide = function() end,
		IsVisible = function() return false end, Toggle = function() end, TryAutoShow = function() end }
end

local Client = script.Parent
local AnimUtil = require(Client:WaitForChild("AnimUtil"))
local SoundUtil = require(Client:WaitForChild("SoundUtil"))
local Components = require(Client:WaitForChild("Components"))

local C = UIConfig.Colors
local S = UIConfig.Sizes

local DailyRewardsPanel = {}

-- STATE
local canvas = nil
local uiScale = nil
local overlay = nil
local visible = false
local closeCallback = nil
local _hasAutoShown = false

-- UI refs
local _claimButton = nil
local _timerLabel = nil
local _dayCards = {}
local _streakLabel = nil
local _progressFill = nil

-- State
local _status = nil
local _timerConn = nil

-- Remotes
local _getStatusFunc = nil
local _claimFunc = nil

-- Lazy RewardPopup
local _RewardPopup = nil
local function getRewardPopup()
	if _RewardPopup then return _RewardPopup end
	pcall(function()
		local ps = game:GetService("Players").LocalPlayer:FindFirstChild("PlayerScripts")
		local client = ps and ps:FindFirstChild("Client")
		local ui = client and client:FindFirstChild("UI")
		local rp = ui and ui:FindFirstChild("RewardPopup")
		if rp then _RewardPopup = require(rp) end
	end)
	return _RewardPopup
end

local function log(...) print("[DailyRewardsPanel]", ...) end

-- ═══════════════════════════════════════════════════════════════════
-- THEME — light blue palette (no orange / pet-ui)
-- ═══════════════════════════════════════════════════════════════════

local HEADER_COLOR      = Color3.fromRGB(60, 140, 255)       -- panel header bar
local INNER_BG_COLOR    = Color3.fromRGB(22, 35, 62)         -- inner content tint (dark blue)
local INNER_TINT_COLOR  = Color3.fromRGB(40, 80, 140)        -- subtle blue fill behind cards
local CARD_BG           = Color3.fromRGB(16, 22, 42)         -- card background (dark navy)
local CARD_BORDER       = Color3.fromRGB(50, 80, 140)        -- default card border
local PROGRESS_BG       = Color3.fromRGB(24, 30, 55)         -- progress bar bg
local PROGRESS_FILL     = Color3.fromRGB(60, 160, 255)       -- progress bar fill
local STREAK_TEXT       = Color3.fromRGB(130, 200, 255)       -- streak label
local TIMER_READY       = Color3.fromRGB(80, 255, 160)       -- "available now"
local TIMER_WAIT        = Color3.fromRGB(160, 180, 220)      -- countdown text
local CLAIM_GREEN       = Color3.fromRGB(50, 200, 80)        -- claim button
local CLAIM_DISABLED    = Color3.fromRGB(40, 45, 60)         -- disabled button

-- Per-day accent colours (blue-tinted spectrum)
local DAY_COLORS = {
	[1] = Color3.fromRGB(80, 200, 140),
	[2] = Color3.fromRGB(60, 160, 255),
	[3] = Color3.fromRGB(160, 110, 255),
	[4] = Color3.fromRGB(90, 200, 255),
	[5] = Color3.fromRGB(255, 120, 140),
	[6] = Color3.fromRGB(80, 220, 200),
	[7] = Color3.fromRGB(160, 100, 255),
}

-- ═══════════════════════════════════════════════════════════════════
-- HELPERS
-- ═══════════════════════════════════════════════════════════════════

local function formatTimer(seconds)
	local h = math.floor(seconds / 3600)
	local m = math.floor((seconds % 3600) / 60)
	local s = math.floor(seconds % 60)
	return string.format("%02d:%02d:%02d", h, m, s)
end

local function fetchStatus()
	if not _getStatusFunc then
		pcall(function()
			local remotes = ReplicatedStorage:WaitForChild("Remotes", 5)
			if remotes then
				_getStatusFunc = remotes:WaitForChild("DailyReward_GetStatus", 5)
				_claimFunc = remotes:WaitForChild("DailyReward_Claim", 5)
			end
		end)
	end
	if _getStatusFunc then
		local statusOk, status = pcall(_getStatusFunc.InvokeServer, _getStatusFunc)
		if statusOk and status then return status end
	end
	return nil
end

-- ═══════════════════════════════════════════════════════════════════
-- UI UPDATES
-- ═══════════════════════════════════════════════════════════════════

local function updateDayCards(status)
	if not status then return end
	local streak = status.streak or 0
	local canClaim = status.canClaim

	for i, card in ipairs(_dayCards) do
		local check = card:FindFirstChild("Check")
		local glow = card:FindFirstChild("GlowStroke")
		local dimOverlay = card:FindFirstChild("DimOverlay")
		local claimTag = card:FindFirstChild("ClaimTag")
		local lockedTag = card:FindFirstChild("LockedTag")

		if i <= streak then
			if check then check.Visible = true end
			if glow then glow.Enabled = false end
			if dimOverlay then dimOverlay.Visible = false end
			if claimTag then claimTag.Visible = false end
			if lockedTag then lockedTag.Visible = false end
		elseif i == streak + 1 and canClaim then
			if check then check.Visible = false end
			if glow then glow.Enabled = true end
			if dimOverlay then dimOverlay.Visible = false end
			if claimTag then claimTag.Visible = true end
			if lockedTag then lockedTag.Visible = false end
		else
			if check then check.Visible = false end
			if glow then glow.Enabled = false end
			if dimOverlay then dimOverlay.Visible = true end
			if claimTag then claimTag.Visible = false end
			if lockedTag then lockedTag.Visible = true end
		end
	end

	if _streakLabel then
		_streakLabel.Text = string.format("Day %d / %d", streak, DailyRewardConfig.MaxStreak)
	end

	if _progressFill then
		local frac = math.clamp(streak / DailyRewardConfig.MaxStreak, 0, 1)
		TweenService:Create(_progressFill, TweenInfo.new(0.4, Enum.EasingStyle.Quad), {
			Size = UDim2.new(frac, 0, 1, 0)
		}):Play()
	end

	if _claimButton then
		if canClaim then
			_claimButton.Text = "CLAIM REWARD"
			_claimButton.BackgroundColor3 = CLAIM_GREEN
			_claimButton.TextColor3 = Color3.fromRGB(255, 255, 255)
			_claimButton.Active = true
			_claimButton.AutoButtonColor = true
		else
			_claimButton.Text = "COME BACK LATER"
			_claimButton.BackgroundColor3 = CLAIM_DISABLED
			_claimButton.TextColor3 = Color3.fromRGB(100, 100, 120)
			_claimButton.Active = false
			_claimButton.AutoButtonColor = false
		end
	end

	if _timerLabel then
		if canClaim then
			_timerLabel.Text = "Reward available now!"
			_timerLabel.TextColor3 = TIMER_READY
		else
			local secs = status.secondsUntilNext or 0
			_timerLabel.Text = "Next reward in: " .. formatTimer(secs)
			_timerLabel.TextColor3 = TIMER_WAIT
		end
	end
end

local function startTimerLoop()
	if _timerConn then _timerConn:Disconnect() end
	local lastFetch = os.time()
	local serverSecs = _status and _status.secondsUntilNext or 0
	_timerConn = RunService.Heartbeat:Connect(function()
		if not visible or not _status then return end
		if _status.canClaim then return end
		local elapsed = os.time() - lastFetch
		local remaining = math.max(0, serverSecs - elapsed)
		if _timerLabel then
			if remaining <= 0 then
				_timerLabel.Text = "Reward available now!"
				_timerLabel.TextColor3 = TIMER_READY
				_status = fetchStatus()
				if _status then
					updateDayCards(_status)
					serverSecs = _status.secondsUntilNext or 0
					lastFetch = os.time()
				end
			else
				_timerLabel.Text = "Next reward in: " .. formatTimer(remaining)
			end
		end
	end)
end

local function stopTimerLoop()
	if _timerConn then _timerConn:Disconnect(); _timerConn = nil end
end

-- ═══════════════════════════════════════════════════════════════════
-- CLAIM
-- ═══════════════════════════════════════════════════════════════════

local _claiming = false
local function onClaim()
	if _claiming then return end
	if not _status or not _status.canClaim then return end
	_claiming = true
	if _claimButton then _claimButton.Text = "..."; _claimButton.Active = false end

	local result = nil
	if _claimFunc then
		local claimOk, claimResult = pcall(_claimFunc.InvokeServer, _claimFunc)
		if claimOk then result = claimResult end
	end

	if result and result.success then
		log("Claimed:", result.newStreak, result.reward and result.reward.label or "?")
		local popup = getRewardPopup()
		local reward = result.reward or {}

		-- Check if this was a crate reward with roll results
		if reward.crateResults and #reward.crateResults > 0 and popup and popup.ShowBatch then
			log(string.format("Day%d claimed -> resultsCount=%d crate rolls", result.newStreak, #reward.crateResults))
			local batchItems = {}
			for i, roll in ipairs(reward.crateResults) do
				log(string.format("  roll#%d: %s %s (dup=%s, coins=%s)",
					i, roll.category or "?", roll.itemId or "?",
					tostring(roll.isDuplicate), tostring(roll.coinsInstead)))
				table.insert(batchItems, {
					title = "DAILY REWARD!",
					name = roll.displayName or roll.itemId or "???",
					itemId = roll.itemId or "",
					itemType = roll.category == "Crowns" and "Crown" or (roll.category == "Pets" and "Pet" or ""),
					category = roll.category or "",
					rarityText = roll.rarity or "Common",
					icon = "",  -- let RewardPopup resolve from catalog
					isDuplicate = roll.isDuplicate,
				})
			end
			popup.ShowBatch(batchItems)
		elseif popup and popup.Show then
			local iconColor = nil
			if reward.iconColor and type(reward.iconColor) == "table" then
				iconColor = Color3.fromRGB(reward.iconColor[1] or 200, reward.iconColor[2] or 200, reward.iconColor[3] or 200)
			end
			popup.Show({
				title = "DAILY REWARD!",
				name = reward.label or "Reward",
				icon = reward.icon or "",
				iconText = reward.iconText or "",
				iconColor = iconColor,
				rarityText = "Day " .. tostring(result.newStreak),
				itemId = reward.crownId or reward.crateId or "",
				itemType = reward.type or "",
			})
		end
		_status = fetchStatus()
		if _status then
			updateDayCards(_status)
			startTimerLoop()
		end
	else
		warn("[DailyRewardsPanel] Claim failed:", result and result.reason or "unknown")
	end
	_claiming = false
end

-- ═══════════════════════════════════════════════════════════════════
-- BUILD DAY CARD  (scale-based, no fixed pixel sizes)
-- ═══════════════════════════════════════════════════════════════════

local function buildDayCard(parent, dayNum)
	local reward = DailyRewardConfig.Rewards[dayNum]
	local dayColor = DAY_COLORS[dayNum] or Color3.fromRGB(100, 160, 255)

	local card = Instance.new("Frame")
	card.Name = "Day" .. dayNum
	card.BackgroundColor3 = CARD_BG
	card.BorderSizePixel = 0
	card.ZIndex = 6
	card.Parent = parent
	Instance.new("UICorner", card).CornerRadius = UDim.new(0, 10)

	-- Border
	local stroke = Instance.new("UIStroke")
	stroke.Color = CARD_BORDER
	stroke.Thickness = 1.5
	stroke.Transparency = 0.3
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = card

	-- Glow stroke (claimable)
	local glowStroke = Instance.new("UIStroke")
	glowStroke.Name = "GlowStroke"
	glowStroke.Color = dayColor
	glowStroke.Thickness = 2.5
	glowStroke.Enabled = false
	glowStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	glowStroke.Parent = card

	-- Day header
	local dayLbl = Instance.new("TextLabel")
	dayLbl.AnchorPoint = Vector2.new(0.5, 0)
	dayLbl.Position = UDim2.new(0.5, 0, 0, 4)
	dayLbl.Size = UDim2.new(1, 0, 0, 16)
	dayLbl.BackgroundTransparency = 1
	dayLbl.Font = Enum.Font.GothamBold
	dayLbl.TextColor3 = dayColor
	dayLbl.TextSize = 12
	dayLbl.Text = "DAY " .. dayNum
	dayLbl.ZIndex = 7
	dayLbl.Parent = card

	-- Icon
	if reward then
		local iconLbl
		if reward.icon and reward.icon ~= "" then
			iconLbl = Instance.new("ImageLabel")
			iconLbl.Image = reward.icon
			iconLbl.ScaleType = Enum.ScaleType.Fit
			iconLbl.BackgroundTransparency = 1
		else
			iconLbl = Instance.new("TextLabel")
			iconLbl.BackgroundTransparency = 1
			iconLbl.Font = Enum.Font.GothamBold
			iconLbl.TextScaled = true
			iconLbl.Text = reward.iconText or "?"
			local ic = reward.iconColor
			if ic and type(ic) == "table" then
				iconLbl.TextColor3 = Color3.fromRGB(ic[1] or 200, ic[2] or 200, ic[3] or 200)
			else
				iconLbl.TextColor3 = Color3.fromRGB(130, 200, 255)
			end
		end
		iconLbl.Name = "RewardIcon"
		iconLbl.AnchorPoint = Vector2.new(0.5, 0.5)
		iconLbl.Position = UDim2.new(0.5, 0, 0.48, 0)
		iconLbl.Size = UDim2.new(0.6, 0, 0.45, 0)
		iconLbl.ZIndex = 7
		iconLbl.Parent = card

		-- Label
		local rewLbl = Instance.new("TextLabel")
		rewLbl.AnchorPoint = Vector2.new(0.5, 1)
		rewLbl.Position = UDim2.new(0.5, 0, 1, -4)
		rewLbl.Size = UDim2.new(1, -8, 0, 14)
		rewLbl.BackgroundTransparency = 1
		rewLbl.Font = Enum.Font.GothamSemibold
		rewLbl.TextColor3 = Color3.fromRGB(190, 205, 240)
		rewLbl.TextSize = 10
		rewLbl.TextTruncate = Enum.TextTruncate.AtEnd
		rewLbl.Text = reward.label or ""
		rewLbl.ZIndex = 7
		rewLbl.Parent = card
	end

	-- Claim tag
	local claimTag = Instance.new("TextLabel")
	claimTag.Name = "ClaimTag"
	claimTag.AnchorPoint = Vector2.new(0.5, 0)
	claimTag.Position = UDim2.new(0.5, 0, 0, 20)
	claimTag.Size = UDim2.new(0.85, 0, 0, 16)
	claimTag.BackgroundColor3 = CLAIM_GREEN
	claimTag.Font = Enum.Font.GothamBold
	claimTag.TextColor3 = Color3.fromRGB(255, 255, 255)
	claimTag.TextSize = 9
	claimTag.Text = "CLAIM"
	claimTag.BorderSizePixel = 0
	claimTag.ZIndex = 8
	claimTag.Visible = false
	claimTag.Parent = card
	Instance.new("UICorner", claimTag).CornerRadius = UDim.new(0, 5)

	-- Locked tag
	local lockedTag = Instance.new("TextLabel")
	lockedTag.Name = "LockedTag"
	lockedTag.AnchorPoint = Vector2.new(0.5, 0)
	lockedTag.Position = UDim2.new(0.5, 0, 0, 20)
	lockedTag.Size = UDim2.new(0.85, 0, 0, 16)
	lockedTag.BackgroundColor3 = Color3.fromRGB(120, 40, 40)
	lockedTag.Font = Enum.Font.GothamBold
	lockedTag.TextColor3 = Color3.fromRGB(255, 255, 255)
	lockedTag.TextSize = 9
	lockedTag.Text = "LOCKED"
	lockedTag.BorderSizePixel = 0
	lockedTag.ZIndex = 8
	lockedTag.Visible = false
	lockedTag.Parent = card
	Instance.new("UICorner", lockedTag).CornerRadius = UDim.new(0, 5)

	-- Checkmark
	local check = Instance.new("TextLabel")
	check.Name = "Check"
	check.AnchorPoint = Vector2.new(0.5, 0.5)
	check.Position = UDim2.fromScale(0.5, 0.45)
	check.Size = UDim2.fromOffset(30, 30)
	check.BackgroundTransparency = 1
	check.Font = Enum.Font.GothamBold
	check.TextColor3 = Color3.fromRGB(80, 255, 160)
	check.TextSize = 24
	check.Text = "\xE2\x9C\x93"
	check.ZIndex = 9
	check.Visible = false
	check.Parent = card

	-- Dim overlay (locked)
	local dimOv = Instance.new("Frame")
	dimOv.Name = "DimOverlay"
	dimOv.Size = UDim2.fromScale(1, 1)
	dimOv.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	dimOv.BackgroundTransparency = 0.55
	dimOv.BorderSizePixel = 0
	dimOv.ZIndex = 8
	dimOv.Visible = false
	dimOv.Parent = card
	Instance.new("UICorner", dimOv).CornerRadius = UDim.new(0, 10)

	table.insert(_dayCards, card)
	return card
end

-- ═══════════════════════════════════════════════════════════════════
-- PANEL LIFECYCLE
-- ═══════════════════════════════════════════════════════════════════

function DailyRewardsPanel.Init(screenGui, onClose)
	closeCallback = onClose

	overlay = Components.CreateDimOverlay(screenGui, function()
		DailyRewardsPanel.Hide()
	end)

	local content, closeBtn
	canvas, uiScale, content, closeBtn = Components.CreatePanel(screenGui, "DAILY REWARDS", HEADER_COLOR, "Daily")

	closeBtn.MouseButton1Click:Connect(function()
		SoundUtil.Close()
		DailyRewardsPanel.Hide()
	end)

	-- Disable the scroll from CreatePanel — we do our own layout
	if content then
		content.ScrollingEnabled = false
		content.AutomaticCanvasSize = Enum.AutomaticSize.None
		content.CanvasSize = UDim2.fromScale(0, 0)
		content.ScrollBarThickness = 0
	end

	-- ── LIGHT BLUE INNER BACKGROUND ──────────────────────────────
	local innerBg = Instance.new("Frame")
	innerBg.Name = "InnerBg"
	innerBg.Size = UDim2.fromScale(1, 1)
	innerBg.BackgroundColor3 = INNER_TINT_COLOR
	innerBg.BackgroundTransparency = 0.82
	innerBg.BorderSizePixel = 0
	innerBg.ZIndex = 5
	innerBg.Parent = content
	Instance.new("UICorner", innerBg).CornerRadius = UDim.new(0, 8)

	-- ── TOP: STREAK + PROGRESS BAR (fixed 40px strip) ───────────
	_streakLabel = Instance.new("TextLabel")
	_streakLabel.AnchorPoint = Vector2.new(0.5, 0)
	_streakLabel.Position = UDim2.new(0.5, 0, 0, 4)
	_streakLabel.Size = UDim2.new(1, -20, 0, 18)
	_streakLabel.BackgroundTransparency = 1
	_streakLabel.Font = Enum.Font.GothamBold
	_streakLabel.TextColor3 = STREAK_TEXT
	_streakLabel.TextSize = 14
	_streakLabel.Text = "Day 0 / 7"
	_streakLabel.ZIndex = 7
	_streakLabel.Parent = content

	local barBg = Instance.new("Frame")
	barBg.AnchorPoint = Vector2.new(0.5, 0)
	barBg.Position = UDim2.new(0.5, 0, 0, 26)
	barBg.Size = UDim2.new(0.7, 0, 0, 8)
	barBg.BackgroundColor3 = PROGRESS_BG
	barBg.BorderSizePixel = 0
	barBg.ZIndex = 7
	barBg.Parent = content
	Instance.new("UICorner", barBg).CornerRadius = UDim.new(1, 0)

	_progressFill = Instance.new("Frame")
	_progressFill.Size = UDim2.new(0, 0, 1, 0)
	_progressFill.BackgroundColor3 = PROGRESS_FILL
	_progressFill.BorderSizePixel = 0
	_progressFill.ZIndex = 8
	_progressFill.Parent = barBg
	Instance.new("UICorner", _progressFill).CornerRadius = UDim.new(1, 0)

	-- ── MIDDLE: CARDS AREA (fills available space) ──────────────
	-- Layout: 3-col × 2-row grid (days 1-6) on the left (~72%)
	--         tall Day 7 card on the right (~26%), 2% gap

	local TOP_OFFSET = 40     -- space for streak + progress bar
	local BOTTOM_OFFSET = 66  -- space for timer + claim button

	local cardsFrame = Instance.new("Frame")
	cardsFrame.Name = "CardsArea"
	cardsFrame.AnchorPoint = Vector2.new(0.5, 0)
	cardsFrame.Position = UDim2.new(0.5, 0, 0, TOP_OFFSET)
	cardsFrame.Size = UDim2.new(1, -16, 1, -(TOP_OFFSET + BOTTOM_OFFSET))
	cardsFrame.BackgroundTransparency = 1
	cardsFrame.ClipsDescendants = false
	cardsFrame.ZIndex = 6
	cardsFrame.Parent = content

	_dayCards = {}

	-- ── LEFT: 3×2 Grid container ────────────────────────────────
	local GRID_W_SCALE = 0.72
	local GAP_SCALE    = 0.02
	local DAY7_W_SCALE = 1 - GRID_W_SCALE - GAP_SCALE

	local gridFrame = Instance.new("Frame")
	gridFrame.Name = "GridDays"
	gridFrame.Size = UDim2.new(GRID_W_SCALE, 0, 1, 0)
	gridFrame.Position = UDim2.fromScale(0, 0)
	gridFrame.BackgroundTransparency = 1
	gridFrame.ZIndex = 6
	gridFrame.Parent = cardsFrame

	-- UIGridLayout for days 1-6
	local COLS, ROWS = 3, 2
	local CELL_PAD = 6
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.new(1 / COLS, -CELL_PAD, 1 / ROWS, -CELL_PAD)
	grid.CellPadding = UDim2.fromOffset(CELL_PAD, CELL_PAD)
	grid.FillDirection = Enum.FillDirection.Horizontal
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.HorizontalAlignment = Enum.HorizontalAlignment.Center
	grid.VerticalAlignment = Enum.VerticalAlignment.Center
	grid.Parent = gridFrame

	for i = 1, 6 do
		local c = buildDayCard(gridFrame, i)
		c.LayoutOrder = i
	end

	-- ── RIGHT: Day 7 featured card ──────────────────────────────
	local day7Frame = Instance.new("Frame")
	day7Frame.Name = "Day7Frame"
	day7Frame.AnchorPoint = Vector2.new(1, 0)
	day7Frame.Size = UDim2.new(DAY7_W_SCALE, 0, 1, 0)
	day7Frame.Position = UDim2.fromScale(1, 0)
	day7Frame.BackgroundTransparency = 1
	day7Frame.ZIndex = 6
	day7Frame.Parent = cardsFrame

	local c7 = buildDayCard(day7Frame, 7)
	c7.Size = UDim2.fromScale(1, 1)

	-- ── BOTTOM: Timer + Claim ───────────────────────────────────
	_timerLabel = Instance.new("TextLabel")
	_timerLabel.AnchorPoint = Vector2.new(0.5, 1)
	_timerLabel.Position = UDim2.new(0.5, 0, 1, -48)
	_timerLabel.Size = UDim2.new(1, -20, 0, 18)
	_timerLabel.BackgroundTransparency = 1
	_timerLabel.Font = Enum.Font.GothamSemibold
	_timerLabel.TextColor3 = TIMER_WAIT
	_timerLabel.TextSize = 13
	_timerLabel.Text = "Loading..."
	_timerLabel.ZIndex = 7
	_timerLabel.Parent = content

	_claimButton = Instance.new("TextButton")
	_claimButton.Name = "ClaimButton"
	_claimButton.AnchorPoint = Vector2.new(0.5, 1)
	_claimButton.Position = UDim2.new(0.5, 0, 1, -8)
	_claimButton.Size = UDim2.new(0.45, 0, 0, 36)
	_claimButton.BackgroundColor3 = CLAIM_GREEN
	_claimButton.BorderSizePixel = 0
	_claimButton.Font = Enum.Font.GothamBold
	_claimButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	_claimButton.TextSize = 16
	_claimButton.Text = "CLAIM REWARD"
	_claimButton.AutoButtonColor = true
	_claimButton.ZIndex = 7
	_claimButton.Parent = content
	Instance.new("UICorner", _claimButton).CornerRadius = UDim.new(0, 10)
	local btnStroke = Instance.new("UIStroke")
	btnStroke.Color = Color3.fromRGB(255, 255, 255)
	btnStroke.Thickness = 1.5
	btnStroke.Transparency = 0.5
	btnStroke.Parent = _claimButton

	_claimButton.MouseButton1Click:Connect(onClaim)

	log("Initialized")
end

-- ═══════════════════════════════════════════════════════════════════
-- SHOW / HIDE / TOGGLE
-- ═══════════════════════════════════════════════════════════════════

function DailyRewardsPanel.Show()
	if visible then return end
	visible = true
	overlay.Visible = true
	SoundUtil.Open()
	AnimUtil.OpenPanel(canvas, uiScale)

	task.spawn(function()
		_status = fetchStatus()
		if _status then
			updateDayCards(_status)
			startTimerLoop()
		end
	end)
end

function DailyRewardsPanel.Hide()
	if not visible then return end
	visible = false
	stopTimerLoop()
	overlay.Visible = false
	local t = AnimUtil.ClosePanel(canvas, uiScale)
	task.spawn(function()
		t.Completed:Wait()
		canvas.Visible = false
	end)
	if closeCallback then closeCallback() end
end

function DailyRewardsPanel.IsVisible()
	return visible
end

function DailyRewardsPanel.Toggle()
	if visible then DailyRewardsPanel.Hide() else DailyRewardsPanel.Show() end
end

function DailyRewardsPanel.TryAutoShow(openerFn)
	if _hasAutoShown then return end
	_hasAutoShown = true
	local doOpen = openerFn or function() DailyRewardsPanel.Show() end
	task.spawn(function()
		task.wait(3)
		if FORCE_OPEN_DAILY_ON_JOIN then
			log("FORCE_OPEN: auto-opening Daily Rewards")
			doOpen()
		else
			local status = fetchStatus()
			if status and status.canClaim then
				log("Auto-opening: reward available")
				doOpen()
			end
		end
	end)
end

return DailyRewardsPanel
