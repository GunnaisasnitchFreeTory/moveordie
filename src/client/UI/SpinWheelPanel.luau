--[[
	SpinWheelPanel
	"Spin The Wheel" UI — prize wheel with daily free spin + purchasable spins.

	Features:
	  • 8-segment colored wheel (true pie slices via quadrant clipping)
	  • Smooth spin animation with tick sounds
	  • Spin result popup
	  • Free spin timer countdown
	  • Purchase panel for buying extra spins
	  • Matches premium UI theme (stud texture, sunburst, gloss)

	Used by: UIController (walk-up near SpinTheWheel + Press E)
]]

local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UIConfig = require(Shared:WaitForChild("UIConfig"))
local SpinWheelConfig = require(Shared:WaitForChild("SpinWheelConfig"))

local Client = script.Parent
local AnimUtil   = require(Client:WaitForChild("AnimUtil"))
local SoundUtil  = require(Client:WaitForChild("SoundUtil"))
local Components = require(Client:WaitForChild("Components"))

local C = UIConfig.Colors
local S = UIConfig.Sizes
local SEGS = SpinWheelConfig.Segments
local NUM = SpinWheelConfig.NUM_SEGMENTS
local SEG_ANGLE = SpinWheelConfig.SEGMENT_ANGLE

-- ═══════════════════════════════════════════
-- STATE
-- ═══════════════════════════════════════════

local canvas: CanvasGroup = nil
local uiScale: UIScale = nil
local overlay: Frame = nil
local visible = false
local spinning = false
local closeCallback: (() -> ())? = nil

local wheelDisc: CanvasGroup = nil      -- the rotating disc
local spinBtn: TextButton = nil          -- the SPIN button
local spinBtnLabel: TextLabel = nil      -- text on the spin button
local timerLabel: TextLabel = nil        -- "Next Free Spin in HH:MM:SS"
local resultFrame: CanvasGroup = nil     -- reward popup

-- Remote functions (lazy loaded)
local getDataRF: RemoteFunction? = nil
local requestSpinRF: RemoteFunction? = nil
local buySpinsRF: RemoteFunction? = nil

-- Player spin state (refreshed from server)
local freeSpinAvailable = false
local nextFreeSpinTime = 0
local purchasedSpins = 0
local lastTimerUpdate = 0

local SpinWheelPanel = {}

local function log(...)
	print("[SpinWheelPanel]", ...)
end

-- ═══════════════════════════════════════════
-- REMOTES
-- ═══════════════════════════════════════════

local function getRemotes()
	if getDataRF then return end
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
	end
	if not remotes then
		log("Remotes folder not found!")
		return
	end
	getDataRF = remotes:FindFirstChild("SpinWheel_GetData")
	requestSpinRF = remotes:FindFirstChild("SpinWheel_RequestSpin")
	buySpinsRF = remotes:FindFirstChild("SpinWheel_BuySpins")
	log("Remotes loaded — GetData:", getDataRF ~= nil, "RequestSpin:", requestSpinRF ~= nil, "BuySpins:", buySpinsRF ~= nil)
end

local function refreshSpinData()
	getRemotes()
	if not getDataRF then
		log("Cannot refresh — GetData remote not available")
		return
	end
	log("Refreshing spin data from server...")
	local ok, data = pcall(function()
		return getDataRF:InvokeServer()
	end)
	if ok and data then
		freeSpinAvailable = data.freeSpinAvailable
		nextFreeSpinTime = data.nextFreeSpinTime or 0
		purchasedSpins = data.purchasedSpins or 0
		log(string.format("Data refreshed — freeSpin: %s, nextFree: %ds, purchased: %d",
			tostring(freeSpinAvailable), nextFreeSpinTime, purchasedSpins))
	else
		log("Failed to refresh data:", tostring(data))
	end
end

-- ═══════════════════════════════════════════
-- HELPERS
-- ═══════════════════════════════════════════

local function formatTime(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local h = math.floor(seconds / 3600)
	local m = math.floor((seconds % 3600) / 60)
	local s = seconds % 60
	return string.format("%02d:%02d:%02d", h, m, s)
end

local function updateSpinButton()
	if not spinBtn then return end
	if spinning then
		spinBtn.BackgroundColor3 = C.DisabledBtn
		if spinBtnLabel then spinBtnLabel.Text = "SPINNING..." end
		return
	end
	local totalSpins = (freeSpinAvailable and 1 or 0) + purchasedSpins
	if totalSpins > 0 then
		spinBtn.BackgroundColor3 = Color3.fromRGB(85, 230, 85)
		if spinBtnLabel then spinBtnLabel.Text = "SPIN (" .. tostring(totalSpins) .. ")" end
	else
		spinBtn.BackgroundColor3 = C.DisabledBtn
		if spinBtnLabel then spinBtnLabel.Text = "NO SPINS" end
	end
end

local function updateTimerLabel()
	if not timerLabel then return end
	if freeSpinAvailable then
		timerLabel.Text = "Free Spin Available!"
		timerLabel.TextColor3 = Color3.fromRGB(85, 255, 85)
	else
		timerLabel.Text = "Next Free Spin in " .. formatTime(nextFreeSpinTime)
		timerLabel.TextColor3 = Color3.fromRGB(200, 210, 230)
	end
end

-- ═══════════════════════════════════════════
-- WHEEL CONSTRUCTION
-- ═══════════════════════════════════════════

local WHEEL_SIZE = 340

--[[
	Build the 8-segment wheel using quadrant clipping + diagonal UIGradient.
	Each quadrant clip frame holds 2 colored triangles = 2 segments.
	The CanvasGroup with UICorner clips everything to a circle.
]]
local function buildWheel(parent: GuiObject): (CanvasGroup, Frame)
	-- Container for wheel + pointer + spin button + timer
	local container = Instance.new("Frame")
	container.Name = "WheelArea"
	container.Size = UDim2.fromOffset(WHEEL_SIZE + 20, WHEEL_SIZE + 140)
	container.AnchorPoint = Vector2.new(0.5, 0)
	container.Position = UDim2.new(0.38, 0, 0, S.PanelHeaderHeight + 16)
	container.BackgroundTransparency = 1
	container.BorderSizePixel = 0
	container.ZIndex = 5
	container.Parent = parent

	-- ─── POINTER (fixed at top) ───
	local pointer = Instance.new("TextLabel")
	pointer.Name = "Pointer"
	pointer.Size = UDim2.fromOffset(44, 36)
	pointer.AnchorPoint = Vector2.new(0.5, 0)
	pointer.Position = UDim2.new(0.5, 0, 0, -2)
	pointer.BackgroundTransparency = 1
	pointer.Font = Enum.Font.GothamBold
	pointer.TextColor3 = Color3.fromRGB(255, 255, 255)
	pointer.TextSize = 36
	pointer.Text = "▼"
	pointer.ZIndex = 20
	pointer.Parent = container
	local ps = Instance.new("UIStroke")
	ps.Color = Color3.fromRGB(0, 0, 0)
	ps.Thickness = 3
	ps.Transparency = 0.1
	ps.Parent = pointer

	-- ─── WHEEL DISC (rotates) ───
	local disc = Instance.new("CanvasGroup")
	disc.Name = "WheelDisc"
	disc.Size = UDim2.fromOffset(WHEEL_SIZE, WHEEL_SIZE)
	disc.AnchorPoint = Vector2.new(0.5, 0)
	disc.Position = UDim2.new(0.5, 0, 0, 32)
	disc.BackgroundColor3 = Color3.fromRGB(35, 40, 65)
	disc.BackgroundTransparency = 0
	disc.BorderSizePixel = 0
	disc.Rotation = -SEG_ANGLE / 2  -- offset so segment 1 is centered at pointer
	disc.ZIndex = 5
	disc.Parent = container

	local discCorner = Instance.new("UICorner")
	discCorner.CornerRadius = UDim.new(1, 0)
	discCorner.Parent = disc

	-- Get segment colors
	local segColors = {}
	for i = 1, NUM do
		segColors[i] = SEGS[i].color
	end

	-- Quadrant config: each quadrant clips 2 triangular segments
	local quadrants = {
		{ pos = UDim2.fromScale(0.5, 0),   gradRot = 315, seg0 = 2, seg1 = 1 },  -- top-right
		{ pos = UDim2.fromScale(0.5, 0.5), gradRot = 45,  seg0 = 3, seg1 = 4 },  -- bottom-right
		{ pos = UDim2.fromScale(0, 0.5),   gradRot = 135, seg0 = 5, seg1 = 6 },  -- bottom-left
		{ pos = UDim2.fromScale(0, 0),     gradRot = 225, seg0 = 7, seg1 = 8 },  -- top-left
	}

	for _, q in ipairs(quadrants) do
		local clip = Instance.new("Frame")
		clip.Name = "QClip"
		clip.Size = UDim2.fromScale(0.501, 0.501)  -- tiny overlap prevents seams
		clip.Position = q.pos
		clip.BackgroundTransparency = 1
		clip.ClipsDescendants = true
		clip.BorderSizePixel = 0
		clip.ZIndex = 3
		clip.Parent = disc

		-- Bottom triangle (offset-0 side segment)
		local bot = Instance.new("Frame")
		bot.Size = UDim2.fromScale(1, 1)
		bot.BackgroundColor3 = segColors[q.seg0]
		bot.BorderSizePixel = 0
		bot.ZIndex = 3
		bot.Parent = clip
		local botGrad = Instance.new("UIGradient")
		botGrad.Rotation = q.gradRot
		botGrad.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.499, 0),
			NumberSequenceKeypoint.new(0.501, 1),
			NumberSequenceKeypoint.new(1, 1),
		})
		botGrad.Parent = bot

		-- Top triangle (offset-1 side segment)
		local top = Instance.new("Frame")
		top.Size = UDim2.fromScale(1, 1)
		top.BackgroundColor3 = segColors[q.seg1]
		top.BorderSizePixel = 0
		top.ZIndex = 4
		top.Parent = clip
		local topGrad = Instance.new("UIGradient")
		topGrad.Rotation = q.gradRot
		topGrad.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.499, 1),
			NumberSequenceKeypoint.new(0.501, 0),
			NumberSequenceKeypoint.new(1, 0),
		})
		topGrad.Parent = top
	end

	-- ─── DIVIDER LINES (from center to edge) ───
	for i = 1, NUM do
		local angle = (i - 1) * SEG_ANGLE
		local line = Instance.new("Frame")
		line.Name = "Div" .. i
		line.Size = UDim2.new(0, 2, 0.5, 0)
		line.AnchorPoint = Vector2.new(0.5, 1)
		line.Position = UDim2.fromScale(0.5, 0.5)
		line.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		line.BackgroundTransparency = 0.3
		line.Rotation = angle
		line.BorderSizePixel = 0
		line.ZIndex = 8
		line.Parent = disc
	end

	-- ─── REWARD LABELS (positioned at each segment center) ───
	for i = 1, NUM do
		local angle = (i - 1) * SEG_ANGLE + SEG_ANGLE / 2
		local rad = math.rad(angle)
		local labelR = 0.31
		local lx = 0.5 + labelR * math.sin(rad)
		local ly = 0.5 - labelR * math.cos(rad)

		local segData = SEGS[i]

		-- Colored backing behind the label text
		local labelBg = Instance.new("Frame")
		labelBg.Name = "LabelBg" .. i
		labelBg.Size = UDim2.fromOffset(72, 48)
		labelBg.AnchorPoint = Vector2.new(0.5, 0.5)
		labelBg.Position = UDim2.fromScale(lx, ly)
		labelBg.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		labelBg.BackgroundTransparency = 0.55
		labelBg.Rotation = angle
		labelBg.BorderSizePixel = 0
		labelBg.ZIndex = 9
		labelBg.Parent = disc
		local lbCorner = Instance.new("UICorner")
		lbCorner.CornerRadius = UDim.new(0, 6)
		lbCorner.Parent = labelBg

		-- Icon emoji
		local icon = Instance.new("TextLabel")
		icon.Size = UDim2.new(1, 0, 0, 22)
		icon.BackgroundTransparency = 1
		icon.Font = Enum.Font.GothamBold
		icon.TextColor3 = Color3.fromRGB(255, 255, 255)
		icon.TextSize = 16
		icon.Text = segData.icon
		icon.ZIndex = 10
		icon.Parent = labelBg

		-- Name + chance
		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, 0, 0, 22)
		label.Position = UDim2.fromOffset(0, 20)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.GothamBold
		label.TextColor3 = Color3.fromRGB(255, 255, 255)
		label.TextSize = 10
		label.Text = segData.name .. "\n" .. segData.chance .. "%"
		label.TextWrapped = true
		label.ZIndex = 10
		label.Parent = labelBg
		local ls = Instance.new("UIStroke")
		ls.Color = Color3.fromRGB(0, 0, 0)
		ls.Thickness = 1.2
		ls.Transparency = 0.15
		ls.Parent = label
	end

	-- ─── CENTER HUB ───
	local hub = Instance.new("Frame")
	hub.Name = "Hub"
	hub.Size = UDim2.fromScale(0.14, 0.14)
	hub.AnchorPoint = Vector2.new(0.5, 0.5)
	hub.Position = UDim2.fromScale(0.5, 0.5)
	hub.BackgroundColor3 = Color3.fromRGB(80, 200, 255)
	hub.BorderSizePixel = 0
	hub.ZIndex = 12
	hub.Parent = disc
	local hubCorner = Instance.new("UICorner")
	hubCorner.CornerRadius = UDim.new(1, 0)
	hubCorner.Parent = hub
	local hubStroke = Instance.new("UIStroke")
	hubStroke.Color = Color3.fromRGB(255, 255, 255)
	hubStroke.Thickness = 4
	hubStroke.Transparency = 0.1
	hubStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	hubStroke.Parent = hub
	-- Inner glow
	local hubInner = Instance.new("Frame")
	hubInner.Size = UDim2.fromScale(0.6, 0.6)
	hubInner.AnchorPoint = Vector2.new(0.5, 0.5)
	hubInner.Position = UDim2.fromScale(0.5, 0.5)
	hubInner.BackgroundColor3 = Color3.fromRGB(200, 240, 255)
	hubInner.BorderSizePixel = 0
	hubInner.ZIndex = 13
	hubInner.Parent = hub
	local hiCorner = Instance.new("UICorner")
	hiCorner.CornerRadius = UDim.new(1, 0)
	hiCorner.Parent = hubInner

	-- ─── CIRCULAR BORDER (over wheel) ───
	local border = Instance.new("Frame")
	border.Name = "WheelBorder"
	border.Size = UDim2.fromOffset(WHEEL_SIZE, WHEEL_SIZE)
	border.AnchorPoint = Vector2.new(0.5, 0)
	border.Position = UDim2.new(0.5, 0, 0, 32)
	border.BackgroundTransparency = 1
	border.BorderSizePixel = 0
	border.ZIndex = 15
	border.Parent = container
	local borderCorner = Instance.new("UICorner")
	borderCorner.CornerRadius = UDim.new(1, 0)
	borderCorner.Parent = border
	local borderStroke = Instance.new("UIStroke")
	borderStroke.Color = Color3.fromRGB(80, 210, 255)
	borderStroke.Thickness = 6
	borderStroke.Transparency = 0
	borderStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	borderStroke.Parent = border

	-- ─── SPIN BUTTON ───
	local sBtnY = 32 + WHEEL_SIZE + 12
	spinBtn = Instance.new("TextButton")
	spinBtn.Name = "SpinBtn"
	spinBtn.Size = UDim2.fromOffset(220, 56)
	spinBtn.AnchorPoint = Vector2.new(0.5, 0)
	spinBtn.Position = UDim2.new(0.5, 0, 0, sBtnY)
	spinBtn.BackgroundColor3 = Color3.fromRGB(85, 230, 85)
	spinBtn.BorderSizePixel = 0
	spinBtn.AutoButtonColor = false
	spinBtn.Text = ""
	spinBtn.ZIndex = 15
	spinBtn.Parent = container
	local sbCorner = Instance.new("UICorner")
	sbCorner.CornerRadius = UDim.new(0, 14)
	sbCorner.Parent = spinBtn
	local sbStroke = Instance.new("UIStroke")
	sbStroke.Color = Color3.fromRGB(255, 255, 255)
	sbStroke.Thickness = 4
	sbStroke.Transparency = 0.15
	sbStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	sbStroke.Parent = spinBtn

	-- Gradient on spin button
	local sbGrad = Instance.new("UIGradient")
	sbGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(130, 255, 130)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(85, 230, 85)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(45, 180, 45)),
	})
	sbGrad.Rotation = 90
	sbGrad.Parent = spinBtn

	spinBtnLabel = Instance.new("TextLabel")
	spinBtnLabel.Name = "Label"
	spinBtnLabel.Size = UDim2.fromScale(1, 1)
	spinBtnLabel.BackgroundTransparency = 1
	spinBtnLabel.Font = Enum.Font.GothamBold
	spinBtnLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	spinBtnLabel.TextSize = 28
	spinBtnLabel.Text = "SPIN (1)"
	spinBtnLabel.ZIndex = 16
	spinBtnLabel.Parent = spinBtn
	local sbls = Instance.new("UIStroke")
	sbls.Color = Color3.fromRGB(0, 0, 0)
	sbls.Thickness = 2.5
	sbls.Transparency = 0.1
	sbls.Parent = spinBtnLabel

	-- ─── TIMER LABEL ───
	timerLabel = Instance.new("TextLabel")
	timerLabel.Name = "Timer"
	timerLabel.Size = UDim2.fromOffset(280, 24)
	timerLabel.AnchorPoint = Vector2.new(0.5, 0)
	timerLabel.Position = UDim2.new(0.5, 0, 0, sBtnY + 62)
	timerLabel.BackgroundTransparency = 1
	timerLabel.Font = Enum.Font.GothamBold
	timerLabel.TextColor3 = Color3.fromRGB(200, 210, 230)
	timerLabel.TextSize = 16
	timerLabel.Text = "Next Free Spin in 00:00:00"
	timerLabel.ZIndex = 15
	timerLabel.Parent = container
	local tls = Instance.new("UIStroke")
	tls.Color = Color3.fromRGB(0, 0, 0)
	tls.Thickness = 1.5
	tls.Transparency = 0.2
	tls.Parent = timerLabel

	wheelDisc = disc
	return disc, container
end

-- ═══════════════════════════════════════════
-- PURCHASE PANEL (right side)
-- ═══════════════════════════════════════════

local function buildPurchasePanel(parent: GuiObject)
	local panel = Instance.new("Frame")
	panel.Name = "PurchasePanel"
	panel.Size = UDim2.fromOffset(260, WHEEL_SIZE + 20)
	panel.AnchorPoint = Vector2.new(1, 0)
	panel.Position = UDim2.new(1, -20, 0, S.PanelHeaderHeight + 40)
	panel.BackgroundColor3 = Color3.fromRGB(35, 42, 72)
	panel.BackgroundTransparency = 0.1
	panel.BorderSizePixel = 0
	panel.ZIndex = 5
	panel.Parent = parent
	local pCorner = Instance.new("UICorner")
	pCorner.CornerRadius = UDim.new(0, 16)
	pCorner.Parent = panel
	local pStroke = Instance.new("UIStroke")
	pStroke.Color = Color3.fromRGB(80, 210, 255)
	pStroke.Thickness = 3
	pStroke.Transparency = 0.15
	pStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	pStroke.Parent = panel

	-- Title
	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 36)
	title.Position = UDim2.fromOffset(0, 8)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextColor3 = C.TextWhite
	title.TextSize = 20
	title.Text = "Buy Spins"
	title.ZIndex = 6
	title.Parent = panel
	local tts = Instance.new("UIStroke")
	tts.Color = Color3.fromRGB(0, 0, 0)
	tts.Thickness = 2
	tts.Transparency = 0.15
	tts.Parent = title

	-- Purchase buttons
	for i, pkg in ipairs(SpinWheelConfig.SpinPrices) do
		local card = Instance.new("Frame")
		card.Name = "Pkg" .. i
		card.Size = UDim2.new(1, -24, 0, 78)
		card.Position = UDim2.fromOffset(12, 48 + (i - 1) * 90)
		card.BackgroundColor3 = Color3.fromRGB(42, 52, 85)
		card.BorderSizePixel = 0
		card.ZIndex = 6
		card.Parent = panel
		local cc = Instance.new("UICorner")
		cc.CornerRadius = UDim.new(0, 12)
		cc.Parent = card
		local cs = Instance.new("UIStroke")
		cs.Color = Color3.fromRGB(60, 180, 80)
		cs.Thickness = 2
		cs.Transparency = 0.25
		cs.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		cs.Parent = card

		-- Robux icon + price
		local robuxLabel = Instance.new("TextLabel")
		robuxLabel.Size = UDim2.new(1, 0, 0, 32)
		robuxLabel.Position = UDim2.fromOffset(0, 8)
		robuxLabel.BackgroundTransparency = 1
		robuxLabel.Font = Enum.Font.GothamBold
		robuxLabel.TextColor3 = Color3.fromRGB(85, 255, 130)
		robuxLabel.TextSize = 24
		robuxLabel.Text = "◎ " .. tostring(pkg.robux)
		robuxLabel.ZIndex = 7
		robuxLabel.Parent = card
		local rls = Instance.new("UIStroke")
		rls.Color = Color3.fromRGB(0, 0, 0)
		rls.Thickness = 2
		rls.Transparency = 0.15
		rls.Parent = robuxLabel

		-- Spin count label
		local countLabel = Instance.new("TextLabel")
		countLabel.Size = UDim2.new(1, 0, 0, 22)
		countLabel.Position = UDim2.fromOffset(0, 40)
		countLabel.BackgroundTransparency = 1
		countLabel.Font = Enum.Font.GothamBold
		countLabel.TextColor3 = Color3.fromRGB(180, 190, 220)
		countLabel.TextSize = 16
		countLabel.Text = pkg.label
		countLabel.ZIndex = 7
		countLabel.Parent = card
		local cls = Instance.new("UIStroke")
		cls.Color = Color3.fromRGB(0, 0, 0)
		cls.Thickness = 1.2
		cls.Transparency = 0.2
		cls.Parent = countLabel

		-- Alt: Fate Coins price (smaller text)
		local coinLabel = Instance.new("TextLabel")
		coinLabel.Size = UDim2.new(1, 0, 0, 16)
		coinLabel.Position = UDim2.fromOffset(0, 60)
		coinLabel.BackgroundTransparency = 1
		coinLabel.Font = Enum.Font.Gotham
		coinLabel.TextColor3 = Color3.fromRGB(140, 150, 175)
		coinLabel.TextSize = 12
		coinLabel.Text = "or F " .. tostring(pkg.coins) .. " Coins"
		coinLabel.ZIndex = 7
		coinLabel.Parent = card

		-- Make card clickable
		local btn = Instance.new("TextButton")
		btn.Size = UDim2.fromScale(1, 1)
		btn.BackgroundTransparency = 1
		btn.Text = ""
		btn.ZIndex = 8
		btn.Parent = card

		AnimUtil.WireButton(btn, function()
			SoundUtil.Click()
			if spinning then return end
			-- Try to buy spins
			getRemotes()
			if buySpinsRF then
				local ok, result = pcall(function()
					return buySpinsRF:InvokeServer(i)
				end)
				if ok and result and result.success then
					purchasedSpins = result.newSpinCount or purchasedSpins
					updateSpinButton()
				else
					local reason = (result and result.reason) or "Purchase failed"
					warn("[SpinWheel] Buy failed:", reason)
				end
			end
		end)
	end

	return panel
end

-- ═══════════════════════════════════════════
-- RESULT POPUP
-- ═══════════════════════════════════════════

local function buildResultPopup(parent: GuiObject)
	local frame = Instance.new("CanvasGroup")
	frame.Name = "ResultPopup"
	frame.Size = UDim2.fromOffset(320, 160)
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.BackgroundColor3 = Color3.fromRGB(28, 35, 62)
	frame.BackgroundTransparency = 0
	frame.GroupTransparency = 1
	frame.Visible = false
	frame.BorderSizePixel = 0
	frame.ZIndex = 30
	frame.Parent = parent

	local rc = Instance.new("UICorner")
	rc.CornerRadius = UDim.new(0, 20)
	rc.Parent = frame

	local rs = Instance.new("UIStroke")
	rs.Color = Color3.fromRGB(255, 215, 65)
	rs.Thickness = 4
	rs.Transparency = 0
	rs.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	rs.Parent = frame

	-- "You Won!" title
	local wonLabel = Instance.new("TextLabel")
	wonLabel.Name = "WonTitle"
	wonLabel.Size = UDim2.new(1, 0, 0, 40)
	wonLabel.Position = UDim2.fromOffset(0, 12)
	wonLabel.BackgroundTransparency = 1
	wonLabel.Font = Enum.Font.GothamBold
	wonLabel.TextColor3 = Color3.fromRGB(255, 215, 65)
	wonLabel.TextSize = 28
	wonLabel.Text = "🎉 You Won!"
	wonLabel.ZIndex = 31
	wonLabel.Parent = frame
	local ws = Instance.new("UIStroke")
	ws.Color = Color3.fromRGB(0, 0, 0)
	ws.Thickness = 2.5
	ws.Transparency = 0.1
	ws.Parent = wonLabel

	-- Reward name
	local rewardLabel = Instance.new("TextLabel")
	rewardLabel.Name = "RewardName"
	rewardLabel.Size = UDim2.new(1, -20, 0, 36)
	rewardLabel.Position = UDim2.fromOffset(10, 55)
	rewardLabel.BackgroundTransparency = 1
	rewardLabel.Font = Enum.Font.GothamBold
	rewardLabel.TextColor3 = C.TextWhite
	rewardLabel.TextSize = 24
	rewardLabel.Text = ""
	rewardLabel.ZIndex = 31
	rewardLabel.Parent = frame
	local rls = Instance.new("UIStroke")
	rls.Color = Color3.fromRGB(0, 0, 0)
	rls.Thickness = 2
	rls.Transparency = 0.12
	rls.Parent = rewardLabel

	-- Coins awarded
	local coinsLabel = Instance.new("TextLabel")
	coinsLabel.Name = "CoinsAwarded"
	coinsLabel.Size = UDim2.new(1, -20, 0, 30)
	coinsLabel.Position = UDim2.fromOffset(10, 95)
	coinsLabel.BackgroundTransparency = 1
	coinsLabel.Font = Enum.Font.GothamBold
	coinsLabel.TextColor3 = Color3.fromRGB(255, 230, 100)
	coinsLabel.TextSize = 20
	coinsLabel.Text = ""
	coinsLabel.ZIndex = 31
	coinsLabel.Parent = frame

	-- OK button
	local okBtn = Instance.new("TextButton")
	okBtn.Name = "OKBtn"
	okBtn.Size = UDim2.fromOffset(120, 36)
	okBtn.AnchorPoint = Vector2.new(0.5, 1)
	okBtn.Position = UDim2.new(0.5, 0, 1, -12)
	okBtn.BackgroundColor3 = Color3.fromRGB(55, 210, 55)
	okBtn.Font = Enum.Font.GothamBold
	okBtn.TextColor3 = C.TextWhite
	okBtn.TextSize = 18
	okBtn.Text = "CLAIM"
	okBtn.BorderSizePixel = 0
	okBtn.AutoButtonColor = false
	okBtn.ZIndex = 32
	okBtn.Parent = frame
	local obc = Instance.new("UICorner")
	obc.CornerRadius = UDim.new(0, 10)
	obc.Parent = okBtn
	local obs = Instance.new("UIStroke")
	obs.Color = Color3.fromRGB(255, 255, 255)
	obs.Thickness = 2
	obs.Transparency = 0.3
	obs.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	obs.Parent = okBtn

	resultFrame = frame
	return frame
end

local function showResult(rewardName: string, coinsAwarded: number)
	if not resultFrame then return end
	local rl: TextLabel = resultFrame:FindFirstChild("RewardName")
	local cl: TextLabel = resultFrame:FindFirstChild("CoinsAwarded")
	if rl then rl.Text = rewardName end
	if cl then cl.Text = "+ " .. tostring(coinsAwarded) .. " Fate Coins" end

	resultFrame.Visible = true
	resultFrame.GroupTransparency = 1
	local rScale = resultFrame:FindFirstChildOfClass("UIScale")
	if not rScale then
		rScale = Instance.new("UIScale")
		rScale.Parent = resultFrame
	end
	rScale.Scale = 0.5

	AnimUtil.Tween(resultFrame, { GroupTransparency = 0 }, 0.35, Enum.EasingStyle.Quad)
	AnimUtil.Tween(rScale, { Scale = 1 }, 0.4, Enum.EasingStyle.Back)

	SoundUtil.CoinCollect()

	-- Wire OK button to dismiss
	local okBtn: TextButton? = resultFrame:FindFirstChild("OKBtn")
	if okBtn then
		local conn
		conn = okBtn.MouseButton1Click:Connect(function()
			if conn then conn:Disconnect() end
			local t = AnimUtil.Tween(resultFrame, { GroupTransparency = 1 }, 0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			t.Completed:Wait()
			resultFrame.Visible = false
		end)
		-- Auto-dismiss after 5 seconds
		task.delay(5, function()
			if conn then conn:Disconnect() end
			if resultFrame.Visible then
				local t = AnimUtil.Tween(resultFrame, { GroupTransparency = 1 }, 0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
				t.Completed:Wait()
				resultFrame.Visible = false
			end
		end)
	end
end

-- ═══════════════════════════════════════════
-- SPIN LOGIC
-- ═══════════════════════════════════════════

local function doSpin()
	if spinning then
		log("doSpin called but already spinning — ignoring")
		return
	end

	-- Check spin availability
	local totalSpins = (freeSpinAvailable and 1 or 0) + purchasedSpins
	log("Spin button clicked! Available spins:", totalSpins, "(free:", tostring(freeSpinAvailable), "purchased:", purchasedSpins, ")")

	if totalSpins <= 0 then
		log("No spins available — cannot spin")
		return
	end

	spinning = true
	updateSpinButton()

	-- Request from server
	getRemotes()
	if not requestSpinRF then
		spinning = false
		updateSpinButton()
		log("RequestSpin remote not available — cannot spin")
		return
	end

	log("Requesting spin from server...")
	local ok, result = pcall(function()
		return requestSpinRF:InvokeServer()
	end)

	if not ok or not result or not result.success then
		spinning = false
		updateSpinButton()
		local reason = "Unknown error"
		if not ok then
			reason = "pcall failed: " .. tostring(result)
		elseif result and result.reason then
			reason = result.reason
		end
		warn("[SpinWheelPanel] Spin failed:", reason)
		return
	end

	local winIndex = result.segmentIndex
	local rewardName = result.rewardName or "Unknown"
	local coinsAwarded = result.coinsAwarded or 0
	log(string.format("Server returned reward: segment %d = '%s' (+%d coins)", winIndex, rewardName, coinsAwarded))

	-- Calculate target rotation
	local numSpins = math.random(SpinWheelConfig.MIN_FULL_SPINS, SpinWheelConfig.MAX_FULL_SPINS)
	local randomOffset = math.random(-12, 12)
	local landingAngle = 360 - (winIndex - 1) * SEG_ANGLE + randomOffset
	local totalSpin = numSpins * 360 + landingAngle

	local startRotation = wheelDisc.Rotation
	local targetRotation = startRotation + totalSpin

	-- Tick sound tracking
	local lastTickZone = math.floor(startRotation / SEG_ANGLE) % NUM
	local tickConn: RBXScriptConnection? = nil

	tickConn = RunService.Heartbeat:Connect(function()
		if not wheelDisc or not wheelDisc.Parent then
			if tickConn then tickConn:Disconnect() end
			return
		end
		local zone = math.floor(wheelDisc.Rotation / SEG_ANGLE) % NUM
		if zone ~= lastTickZone then
			SoundUtil.Hover()
			lastTickZone = zone
		end
	end)

	-- Spin tween
	local tweenInfo = TweenInfo.new(
		SpinWheelConfig.SPIN_DURATION,
		Enum.EasingStyle.Exponential,
		Enum.EasingDirection.Out
	)
	local tween = TweenService:Create(wheelDisc, tweenInfo, {
		Rotation = targetRotation,
	})
	tween:Play()

	log("Wheel spin animation started (duration:", SpinWheelConfig.SPIN_DURATION, "s, target rotation:", targetRotation, ")")

	-- Wait for completion
	task.spawn(function()
		tween.Completed:Wait()
		if tickConn then tickConn:Disconnect() end

		-- Normalize rotation to prevent floating precision issues
		wheelDisc.Rotation = targetRotation
		log("Wheel spin animation complete — showing reward popup")

		-- Show result
		task.wait(0.3)
		showResult(rewardName, coinsAwarded)

		-- Refresh data
		task.wait(0.5)
		refreshSpinData()
		spinning = false
		updateSpinButton()
		updateTimerLabel()
		log("Spin cycle complete — ready for next spin")
	end)
end

-- ═══════════════════════════════════════════
-- TIMER UPDATE LOOP
-- ═══════════════════════════════════════════

local timerConn: RBXScriptConnection? = nil

local function startTimerLoop()
	if timerConn then timerConn:Disconnect() end
	timerConn = RunService.Heartbeat:Connect(function()
		if not visible then return end
		local now = tick()
		if now - lastTimerUpdate < 1 then return end
		lastTimerUpdate = now

		if not freeSpinAvailable and nextFreeSpinTime > 0 then
			nextFreeSpinTime = nextFreeSpinTime - 1
			if nextFreeSpinTime <= 0 then
				freeSpinAvailable = true
				nextFreeSpinTime = 0
				updateSpinButton()
			end
		end
		updateTimerLabel()
	end)
end

-- ═══════════════════════════════════════════
-- PUBLIC API
-- ═══════════════════════════════════════════

function SpinWheelPanel.Init(screenGui: ScreenGui, onClose: () -> ())
	log("Initializing SpinWheelPanel...")
	closeCallback = onClose

	overlay = Components.CreateDimOverlay(screenGui, function()
		SpinWheelPanel.Hide()
	end)

	local content, closeBtn
	canvas, uiScale, content, closeBtn = Components.CreatePanel(
		screenGui,
		"🎡 SPIN THE WHEEL",
		Color3.fromRGB(72, 180, 255) -- wheel accent
	)

	-- Make panel wider for wheel + purchase layout
	canvas.Size = UDim2.fromScale(0.78, 0.82)

	-- Hide default scroll content (we use custom layout)
	content.Visible = false

	AnimUtil.WireButton(closeBtn, function()
		SoundUtil.Close()
		SpinWheelPanel.Hide()
	end)

	-- Build sub-elements
	buildWheel(canvas)
	buildPurchasePanel(canvas)
	buildResultPopup(canvas)

	-- Wire spin button
	AnimUtil.WireButton(spinBtn, function()
		log("SPIN button clicked!")
		SoundUtil.Click()
		doSpin()
	end)

	-- Start timer loop
	startTimerLoop()
	log("SpinWheelPanel initialized ✓")
end

function SpinWheelPanel.Show()
	if visible then return end
	log("Opening SpinWheel panel")
	visible = true
	overlay.Visible = true
	SoundUtil.Open()

	-- Refresh spin data from server
	task.spawn(function()
		refreshSpinData()
		updateSpinButton()
		updateTimerLabel()
	end)

	AnimUtil.OpenPanel(canvas, uiScale)
	log("SpinWheel panel visible")
end

function SpinWheelPanel.Hide()
	if not visible then return end
	log("Closing SpinWheel panel")
	visible = false
	overlay.Visible = false

	-- Hide result popup
	if resultFrame then resultFrame.Visible = false end

	local t = AnimUtil.ClosePanel(canvas, uiScale)
	task.spawn(function()
		t.Completed:Wait()
		canvas.Visible = false
	end)
	if closeCallback then closeCallback() end
end

function SpinWheelPanel.IsVisible(): boolean
	return visible
end

function SpinWheelPanel.Toggle()
	if visible then SpinWheelPanel.Hide() else SpinWheelPanel.Show() end
end

return SpinWheelPanel

