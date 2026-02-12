--[[
	Components
	Reusable UI element factory functions.

	DARK + VIBRANT theme — front-page Roblox quality:
	  • Dark opaque panel backgrounds
	  • Visible stud texture overlay (lighter pattern on dark)
	  • PER-PANEL unique background animations (via UIStyle themes)
	  • Centered radial glow (soft bright circle, color from theme)
	  • Refined coloured borders (subtle, consistent)
	  • Glossy gradient on headers & buttons
	  • High-contrast text with dark strokes
	  • Close button hover/press feedback (via UIStyle)

	Used by: every panel + HUDPanel + UIController
]]

local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:FindFirstChild("Shared") or ReplicatedStorage:WaitForChild("Shared", 5)
local UIConfig = require(Shared:WaitForChild("UIConfig"))

local Client = script.Parent
local AnimUtil  = require(Client:WaitForChild("AnimUtil"))
local SoundUtil = require(Client:WaitForChild("SoundUtil"))

-- UIStyle: instant load (NO blocking WaitForChild — never wait for UIStyle)
local _styleStart = tick()
local UIStyleModule = Client:FindFirstChild("UIStyle")
local UIStyle
if UIStyleModule then
	local ok, mod = pcall(require, UIStyleModule)
	if ok then
		UIStyle = mod
		print(string.format("[Components] UIStyle loaded instantly (%.0fms)", (tick() - _styleStart) * 1000))
	else
		warn("[Components] UIStyle failed to load:", mod, "— using built-in defaults")
	end
end
if not UIStyle then
	print(string.format("[Components] UIStyle not present — using built-in defaults (%.0fms, non-blocking)", (tick() - _styleStart) * 1000))
	UIStyle = {
		GetTheme = function(_themeName)
			return {
				accentColor   = Color3.fromRGB(72, 180, 255),
				glowColor     = Color3.fromRGB(75, 105, 195),
				glowAlpha     = 0.84,
				glowSize      = 1.4,
				bgAnimation   = "sunburst",
				sunburstSpeed = 8,
				sunburstAlpha = 0.85,
				sparkleCount  = 6,
				sparkleColor  = Color3.fromRGB(255, 255, 255),
			}
		end,
		ApplyBgAnimation = function() end,
		WireCloseButton = function() end,
	}
	-- Async: if UIStyle loads later, hot-swap it (non-blocking)
	task.spawn(function()
		local laterModule = Client:WaitForChild("UIStyle", 30)
		if laterModule then
			local ok2, mod2 = pcall(require, laterModule)
			if ok2 and mod2 then
				UIStyle = mod2
				print("[Components] UIStyle hot-swapped (loaded asynchronously)")
			end
		end
	end)
end

local C = UIConfig.Colors
local S = UIConfig.Sizes

local Components = {}

-- ═══════════════════════════════════════════════════════════════════
-- INTERNAL HELPERS
-- ═══════════════════════════════════════════════════════════════════

--[[
	Subtle glossy sheen — white highlight at top, NO black darkening.
	This preserves the actual background color so buttons stay vibrant.
	topAlpha = how visible the white sheen is (lower = more visible)
]]
local function addGloss(frame: GuiObject, topAlpha: number?, _bottomAlpha: number?)
	topAlpha = topAlpha or 0.72
	local grad = Instance.new("UIGradient")
	grad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 255, 255)),
	})
	grad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, topAlpha),
		NumberSequenceKeypoint.new(0.4, 1),
		NumberSequenceKeypoint.new(1, 1),
	})
	grad.Rotation = 90
	grad.Parent = frame
end

--[[
	Strong glossy sheen for HEADER bars (brighter highlight).
]]
local function addHeaderGloss(frame: GuiObject)
	local grad = Instance.new("UIGradient")
	grad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(220, 225, 240)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 0, 0)),
	})
	grad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.52),
		NumberSequenceKeypoint.new(0.35, 0.88),
		NumberSequenceKeypoint.new(0.65, 0.95),
		NumberSequenceKeypoint.new(1, 0.82),
	})
	grad.Rotation = 90
	grad.Parent = frame
end

--[[
	Offset drop-shadow behind a frame.
]]
local function addShadow(parent: GuiObject, radius: number?, ox: number?, oy: number?)
	radius = radius or S.PanelCorner + 8
	ox = ox or 3
	oy = oy or 6
	local shadow = Instance.new("Frame")
	shadow.Name = "DropShadow"
	shadow.AnchorPoint = Vector2.new(0.5, 0.5)
	shadow.Position = UDim2.new(0.5, ox, 0.5, oy)
	shadow.Size = UDim2.new(1, 20, 1, 20)
	shadow.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	shadow.BackgroundTransparency = 0.48
	shadow.BorderSizePixel = 0
	shadow.ZIndex = 0
	shadow.Parent = parent
	local sc = Instance.new("UICorner")
	sc.CornerRadius = UDim.new(0, radius)
	sc.Parent = shadow
end

--[[
	Tileable stud texture overlay (lighter than dark bg = clearly visible).
]]
local function addStudTexture(parent: GuiObject, radius: number?)
	local tex = UIConfig.StudTexture
	local stud = Instance.new("ImageLabel")
	stud.Name = "StudTexture"
	stud.Size = UDim2.fromScale(1, 1)
	stud.BackgroundTransparency = 1
	stud.Image = tex.AssetId
	stud.ScaleType = Enum.ScaleType.Tile
	stud.TileSize = tex.TileSize
	stud.ImageTransparency = tex.Transparency
	stud.ImageColor3 = tex.Color
	stud.ZIndex = 1
	stud.Parent = parent
	if radius then
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, radius)
		c.Parent = stud
	end
end

-- Expose addStudTexture so other modules can add stud texture to backgrounds
Components.AddStudTexture = addStudTexture

--[[
	Centered radial glow — a big soft bright circle behind content.
	Creates a warm "spotlight" effect on the dark panel.
	Now accepts optional alpha and size from theme.
]]
local function addCenterGlow(parent: GuiObject, color: Color3?, alpha: number?, glowSize: number?)
	color = color or Color3.fromRGB(75, 105, 195)
	alpha = alpha or 0.84
	glowSize = glowSize or 1.4
	local glow = Instance.new("Frame")
	glow.Name = "CenterGlow"
	glow.Size = UDim2.new(glowSize, 0, glowSize * 0.85, 0)
	glow.AnchorPoint = Vector2.new(0.5, 0.5)
	glow.Position = UDim2.fromScale(0.5, 0.5)
	glow.BackgroundColor3 = color
	glow.BackgroundTransparency = alpha
	glow.BorderSizePixel = 0
	glow.ZIndex = 1
	glow.Parent = parent
	local gc = Instance.new("UICorner")
	gc.CornerRadius = UDim.new(0.5, 0)
	gc.Parent = glow

	-- Pulse
	local expandSize = glowSize + 0.1
	local shrinkSize = glowSize - 0.1
	task.spawn(function()
		while glow and glow.Parent do
			local t1 = TweenService:Create(glow, TweenInfo.new(3, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
				BackgroundTransparency = alpha,
				Size = UDim2.new(expandSize, 0, expandSize * 0.85, 0),
			})
			t1:Play()
			t1.Completed:Wait()
			local t2 = TweenService:Create(glow, TweenInfo.new(3, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
				BackgroundTransparency = alpha + 0.04,
				Size = UDim2.new(shrinkSize, 0, shrinkSize * 0.85, 0),
			})
			t2:Play()
			t2.Completed:Wait()
		end
	end)
end

--[[
	Slow-rotating "sunburst" light rays behind content.
	Now accepts optional speed and alpha from theme.
]]
local function addSunburst(parent: GuiObject, speed: number?, alpha: number?)
	speed = speed or (UIConfig.Anim.SunburstSpeed or 10)
	alpha = alpha or 0.85

	local burst = Instance.new("Frame")
	burst.Name = "Sunburst"
	burst.Size = UDim2.new(2.5, 0, 2.5, 0)
	burst.AnchorPoint = Vector2.new(0.5, 0.5)
	burst.Position = UDim2.fromScale(0.5, 0.5)
	burst.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	burst.BackgroundTransparency = alpha
	burst.BorderSizePixel = 0
	burst.ZIndex = 2
	burst.Parent = parent

	local grad = Instance.new("UIGradient")
	grad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.58),
		NumberSequenceKeypoint.new(0.08, 0.96),
		NumberSequenceKeypoint.new(0.16, 0.62),
		NumberSequenceKeypoint.new(0.24, 0.96),
		NumberSequenceKeypoint.new(0.33, 0.58),
		NumberSequenceKeypoint.new(0.41, 0.96),
		NumberSequenceKeypoint.new(0.50, 0.62),
		NumberSequenceKeypoint.new(0.58, 0.96),
		NumberSequenceKeypoint.new(0.66, 0.58),
		NumberSequenceKeypoint.new(0.75, 0.96),
		NumberSequenceKeypoint.new(0.83, 0.62),
		NumberSequenceKeypoint.new(0.91, 0.96),
		NumberSequenceKeypoint.new(1, 0.58),
	})
	grad.Parent = burst

	local conn
	conn = RunService.Heartbeat:Connect(function(dt)
		if not burst.Parent then
			conn:Disconnect()
			return
		end
		grad.Rotation = (grad.Rotation + dt * speed) % 360
	end)
end

--[[
	Floating sparkle dots that fade in/out at random positions.
	Now accepts optional sparkle color from theme.
]]
local function addSparkles(parent: GuiObject, count: number?, sparkleColor: Color3?)
	count = count or 6
	sparkleColor = sparkleColor or Color3.fromRGB(255, 255, 255)
	for i = 1, count do
		local sparkle = Instance.new("Frame")
		sparkle.Name = "Sparkle" .. i
		sparkle.Size = UDim2.fromOffset(3, 3)
		sparkle.AnchorPoint = Vector2.new(0.5, 0.5)
		sparkle.Position = UDim2.fromScale(math.random() * 0.8 + 0.1, math.random() * 0.8 + 0.1)
		sparkle.BackgroundColor3 = sparkleColor
		sparkle.BackgroundTransparency = 1
		sparkle.BorderSizePixel = 0
		sparkle.ZIndex = 3
		sparkle.Parent = parent

		local sc = Instance.new("UICorner")
		sc.CornerRadius = UDim.new(1, 0)
		sc.Parent = sparkle

		task.spawn(function()
			task.wait(math.random() * 2)
			while sparkle and sparkle.Parent do
				sparkle.Position = UDim2.fromScale(math.random() * 0.8 + 0.1, math.random() * 0.8 + 0.1)
				local fadeIn = TweenService:Create(sparkle, TweenInfo.new(0.6, Enum.EasingStyle.Quad), {
					BackgroundTransparency = 0.20,
					Size = UDim2.fromOffset(6, 6),
				})
				fadeIn:Play()
				fadeIn.Completed:Wait()
				local fadeOut = TweenService:Create(sparkle, TweenInfo.new(0.6, Enum.EasingStyle.Quad), {
					BackgroundTransparency = 1,
					Size = UDim2.fromOffset(3, 3),
				})
				fadeOut:Play()
				fadeOut.Completed:Wait()
				task.wait(math.random() * 2 + 0.8)
			end
		end)
	end
end

-- ═══════════════════════════════════════════════════════════════════
-- SCREEN GUI
-- ═══════════════════════════════════════════════════════════════════

function Components.CreateScreenGui(name: string, displayOrder: number): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = displayOrder
	gui.IgnoreGuiInset = false
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	return gui
end

-- ═══════════════════════════════════════════════════════════════════
-- DIM OVERLAY
-- ═══════════════════════════════════════════════════════════════════

function Components.CreateDimOverlay(parent: Instance, onClose: () -> ()): Frame
	local overlay = Instance.new("TextButton")
	overlay.Name = "DimOverlay"
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.Position = UDim2.fromScale(0, 0)
	overlay.BackgroundColor3 = C.Overlay
	overlay.BackgroundTransparency = C.OverlayTransparency
	overlay.BorderSizePixel = 0
	overlay.Text = ""
	overlay.AutoButtonColor = false
	overlay.ZIndex = 1
	overlay.Visible = false
	overlay.Parent = parent
	overlay.MouseButton1Click:Connect(function()
		SoundUtil.Close()
		if onClose then onClose() end
	end)
	return overlay
end

-- ═══════════════════════════════════════════════════════════════════
-- PANEL  (dark opaque bg + stud texture + coloured border + theme-specific animation)
-- 4th param: themeName (optional) — e.g. "Shop", "Crate", "Spectate"
-- Uses UIStyle to select unique background animation per panel.
-- Returns: canvasGroup, uiScale, contentScroll, closeBtn
-- ═══════════════════════════════════════════════════════════════════

function Components.CreatePanel(parent: Instance, title: string, headerColor: Color3?, themeName: string?)
	-- Resolve theme from UIStyle (defaults to "Default" if not provided)
	local theme = UIStyle.GetTheme(themeName or "Default")

	-- Use theme accent if no explicit headerColor was passed
	headerColor = headerColor or theme.accentColor or C.HeaderShop

	-- Canvas root (dark, opaque)
	local canvas = Instance.new("CanvasGroup")
	canvas.Name = title:gsub("[^%w]", "") .. "Panel"
	canvas.AnchorPoint = Vector2.new(0.5, 0.5)
	canvas.Position = UDim2.fromScale(0.5, 0.5)
	canvas.Size = UDim2.fromScale(S.PanelWidth, S.PanelHeight)
	canvas.BackgroundColor3 = C.PanelBg
	canvas.BackgroundTransparency = 0
	canvas.BorderSizePixel = 0
	canvas.GroupTransparency = 1
	canvas.Visible = false
	canvas.ZIndex = 5
	canvas.ClipsDescendants = true
	canvas.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, S.PanelCorner)
	corner.Parent = canvas

	-- Refined coloured border (thinner, more transparent)
	local stroke = Instance.new("UIStroke")
	stroke.Color = headerColor
	stroke.Thickness = S.PanelStroke
	stroke.Transparency = 0.1
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = canvas

	-- Drop shadow
	addShadow(canvas, S.PanelCorner + 8, 4, 8)

	-- Stud texture (visible on dark)
	addStudTexture(canvas, S.PanelCorner)

	-- Center glow (color + alpha from theme)
	addCenterGlow(canvas, theme.glowColor, theme.glowAlpha, theme.glowSize)

	-- ─── THEME-SPECIFIC BACKGROUND ANIMATION ───
	-- Instead of always sunburst+sparkles, each panel gets its own animation.
	local bgAnim = theme.bgAnimation or "sunburst"

	if bgAnim == "sunburst" then
		-- Classic rotating light rays
		addSunburst(canvas, theme.sunburstSpeed, theme.sunburstAlpha)
		addSparkles(canvas, theme.sparkleCount, theme.sparkleColor)
	elseif bgAnim == "none" then
		-- Clean / minimal — no animated background (Settings)
	else
		-- Use UIStyle's animated variants (shimmer, waves, stars, bubbles)
		UIStyle.ApplyBgAnimation(canvas, theme)
		-- Still add themed sparkles for most panels (except "none")
		if theme.sparkleCount and theme.sparkleCount > 0 then
			addSparkles(canvas, theme.sparkleCount, theme.sparkleColor)
		end
	end

	-- UIScale for open/close animation
	local uiScale = Instance.new("UIScale")
	uiScale.Scale = UIConfig.Anim.OpenStartScale
	uiScale.Parent = canvas

	-- ─── GLOSSY HEADER ───
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, S.PanelHeaderHeight)
	header.Position = UDim2.fromScale(0, 0)
	header.BackgroundColor3 = headerColor
	header.BorderSizePixel = 0
	header.ZIndex = 6
	header.Parent = canvas

	local hCorner = Instance.new("UICorner")
	hCorner.CornerRadius = UDim.new(0, S.PanelCorner)
	hCorner.Parent = header

	-- Mask bottom corners of header (so top corners round, bottom stays flat)
	local hMask = Instance.new("Frame")
	hMask.Name = "BottomMask"
	hMask.Size = UDim2.new(1, 0, 0, S.PanelCorner)
	hMask.Position = UDim2.new(0, 0, 1, -S.PanelCorner)
	hMask.BackgroundColor3 = headerColor
	hMask.BorderSizePixel = 0
	hMask.ZIndex = 6
	hMask.Parent = header

	addHeaderGloss(header)

	-- Header bottom highlight line (softer)
	local hLine = Instance.new("Frame")
	hLine.Name = "HighlightLine"
	hLine.Size = UDim2.new(1, -28, 0, 1)
	hLine.Position = UDim2.new(0, 14, 1, -1)
	hLine.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	hLine.BackgroundTransparency = 0.6
	hLine.BorderSizePixel = 0
	hLine.ZIndex = 7
	hLine.Parent = header

	-- Title text
	local titleLabel = Instance.new("TextLabel")
	titleLabel.Name = "Title"
	titleLabel.Size = UDim2.new(1, -S.CloseBtnSize - 32, 1, 0)
	titleLabel.Position = UDim2.fromOffset(22, 0)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Font = Enum.Font.GothamBold
	titleLabel.TextColor3 = C.TextWhite
	titleLabel.TextSize = 30
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.Text = title
	titleLabel.ZIndex = 7
	titleLabel.Parent = header
	local ts = Instance.new("UIStroke")
	ts.Color = Color3.fromRGB(0, 0, 0)
	ts.Thickness = 1.8
	ts.Transparency = 0.18
	ts.Parent = titleLabel

	-- Close button (red circle with white X)
	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "CloseBtn"
	closeBtn.AnchorPoint = Vector2.new(1, 0.5)
	closeBtn.Position = UDim2.new(1, -10, 0.5, 0)
	closeBtn.Size = UDim2.fromOffset(S.CloseBtnSize, S.CloseBtnSize)
	closeBtn.BackgroundColor3 = C.CloseBtn
	closeBtn.Font = Enum.Font.GothamBold
	closeBtn.Text = "X"
	closeBtn.TextColor3 = C.TextWhite
	closeBtn.TextSize = 26
	closeBtn.BorderSizePixel = 0
	closeBtn.AutoButtonColor = false
	closeBtn.ZIndex = 8
	closeBtn.Parent = header
	local cbCorner = Instance.new("UICorner")
	cbCorner.CornerRadius = UDim.new(0, S.CloseBtnSize / 2)
	cbCorner.Parent = closeBtn
	local cbStroke = Instance.new("UIStroke")
	cbStroke.Color = Color3.fromRGB(255, 255, 255)
	cbStroke.Thickness = 2
	cbStroke.Transparency = 0.35
	cbStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	cbStroke.Parent = closeBtn

	-- Close button hover/press feedback (via UIStyle)
	UIStyle.WireCloseButton(closeBtn, theme)

	-- Content scrolling area
	local content = Instance.new("ScrollingFrame")
	content.Name = "Content"
	content.Size = UDim2.new(1, -24, 1, -(S.PanelHeaderHeight + 18))
	content.Position = UDim2.new(0, 12, 0, S.PanelHeaderHeight + 8)
	content.BackgroundTransparency = 1
	content.BorderSizePixel = 0
	content.ScrollBarThickness = 5
	content.ScrollBarImageColor3 = Color3.fromRGB(75, 82, 108)
	content.CanvasSize = UDim2.fromScale(0, 0)
	content.AutomaticCanvasSize = Enum.AutomaticSize.Y
	content.ScrollingDirection = Enum.ScrollingDirection.Y
	content.ZIndex = 5
	content.Parent = canvas

	return canvas, uiScale, content, closeBtn
end

-- ═══════════════════════════════════════════════════════════════════
-- TAB BAR  (for Premium Shop categories, Index tabs, etc.)
-- Returns: Frame, updateActive(index) function
-- ═══════════════════════════════════════════════════════════════════

function Components.CreateTabBar(parent: Instance, tabs: {{label: string}}, onSelect: (number) -> ()): (Frame, (number) -> ())
	local bar = Instance.new("Frame")
	bar.Name = "TabBar"
	bar.Size = UDim2.new(1, -20, 0, S.TabHeight + 8)
	bar.BackgroundTransparency = 1
	bar.BorderSizePixel = 0
	bar.ZIndex = 6
	bar.Parent = parent

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, 6)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = bar

	local tabButtons: {TextButton} = {}

	for i, tab in ipairs(tabs) do
		local btn = Instance.new("TextButton")
		btn.Name = "Tab_" .. tab.label
		btn.Size = UDim2.fromOffset(math.max(#tab.label * 9 + 26, 72), S.TabHeight)
		btn.BackgroundColor3 = C.TabInactive
		btn.Font = Enum.Font.GothamBold
		btn.TextColor3 = C.TabTextInactive
		btn.TextSize = 15
		btn.Text = tab.label
		btn.BorderSizePixel = 0
		btn.AutoButtonColor = false
		btn.LayoutOrder = i
		btn.ZIndex = 6
		btn.Parent = bar

		local btnCorner = Instance.new("UICorner")
		btnCorner.CornerRadius = UDim.new(0, S.TabCorner)
		btnCorner.Parent = btn

		local btnStroke = Instance.new("UIStroke")
		btnStroke.Color = Color3.fromRGB(255, 255, 255)
		btnStroke.Thickness = 1.5
		btnStroke.Transparency = 0.7
		btnStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		btnStroke.Parent = btn

		tabButtons[i] = btn

		AnimUtil.WireButton(btn, function()
			SoundUtil.Click()
			onSelect(i)
		end)
	end

	local function updateActive(activeIdx: number)
		for i, btn in ipairs(tabButtons) do
			if i == activeIdx then
				btn.BackgroundColor3 = C.TabActive
				btn.TextColor3 = C.TabTextActive
			else
				btn.BackgroundColor3 = C.TabInactive
				btn.TextColor3 = C.TabTextInactive
			end
		end
	end

	return bar, updateActive
end

-- ═══════════════════════════════════════════════════════════════════
-- ITEM CARD  (dark bg, vibrant rarity border, glossy icon, white text)
-- Now supports optional `image` field — shows ImageLabel when provided,
-- falls back to text icon otherwise.
-- ═══════════════════════════════════════════════════════════════════

export type CardConfig = {
	name: string,
	rarity: string,
	iconColor: Color3,
	iconText: string?,
	image: string?,
	locked: boolean?,
	owned: boolean?,
	equipped: boolean?,
	actionText: string?,
	actionColor: Color3?,
	tag: string?,
	onAction: (() -> ())?,
}

function Components.CreateItemCard(parent: Instance, data: CardConfig): Frame
	local rarityInfo = UIConfig.RarityInfo[data.rarity] or UIConfig.RarityInfo.Common
	local rarityColor = rarityInfo.color

	local card = Instance.new("Frame")
	card.Name = "Card_" .. data.name
	card.Size = UDim2.fromOffset(S.CardWidth, S.CardHeight)
	card.BackgroundColor3 = data.locked and C.CardBgDark or C.CardBg
	card.BorderSizePixel = 0
	card.Parent = parent

	local cc = Instance.new("UICorner")
	cc.CornerRadius = UDim.new(0, S.CardCorner)
	cc.Parent = card

	local cStroke = Instance.new("UIStroke")
	cStroke.Color = data.locked and Color3.fromRGB(42, 45, 62) or rarityColor
	cStroke.Thickness = data.locked and 1.5 or 2.5
	cStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	cStroke.Transparency = data.locked and 0.4 or 0.1
	cStroke.Parent = card

	if not data.locked then
		addGloss(card, 0.80, 0.92)
	end

	addStudTexture(card, S.CardCorner)

	local iconFrame = Instance.new("Frame")
	iconFrame.Name = "Icon"
	iconFrame.Size = UDim2.new(1, -16, 0, 90)
	iconFrame.Position = UDim2.fromOffset(8, 8)
	iconFrame.BorderSizePixel = 0
	iconFrame.Parent = card
	local iCorner = Instance.new("UICorner")
	iCorner.CornerRadius = UDim.new(0, 10)
	iCorner.Parent = iconFrame

	local displayText = data.iconText or string.sub(data.name, 1, 1)

	if data.locked then
		iconFrame.BackgroundColor3 = Color3.fromRGB(25, 28, 45)
		local q = Instance.new("TextLabel")
		q.Size = UDim2.fromScale(1, 1)
		q.BackgroundTransparency = 1
		q.Font = Enum.Font.GothamBold
		q.Text = "?"
		q.TextColor3 = Color3.fromRGB(55, 58, 80)
		q.TextSize = 42
		q.Parent = iconFrame
		local qs = Instance.new("UIStroke")
		qs.Color = Color3.fromRGB(0, 0, 0)
		qs.Thickness = 1.5
		qs.Transparency = 0.35
		qs.Parent = q
	else
		iconFrame.BackgroundColor3 = data.iconColor
		addGloss(iconFrame, 0.48, 0.78)

		if data.image and data.image ~= "" then
			local img = Instance.new("ImageLabel")
			img.Name = "ItemImage"
			img.Size = UDim2.new(1, -8, 1, -8)
			img.Position = UDim2.fromOffset(4, 4)
			img.BackgroundTransparency = 1
			img.Image = data.image
			img.ScaleType = Enum.ScaleType.Fit
			img.ZIndex = 2
			img.Parent = iconFrame
			local ic = Instance.new("UICorner")
			ic.CornerRadius = UDim.new(0, 8)
			ic.Parent = img
		else
			local letter = Instance.new("TextLabel")
			letter.Name = "Letter"
			letter.Size = UDim2.fromScale(1, 1)
			letter.BackgroundTransparency = 1
			letter.Font = Enum.Font.GothamBold
			letter.Text = displayText
			letter.TextColor3 = Color3.fromRGB(255, 255, 255)
			letter.TextSize = 34
			letter.TextTransparency = 0.02
			letter.Parent = iconFrame
			local ls = Instance.new("UIStroke")
			ls.Color = Color3.fromRGB(0, 0, 0)
			ls.Thickness = 1.8
			ls.Transparency = 0.2
			ls.Parent = letter
		end
	end

	if data.tag and data.tag ~= "" then
		local tagBadge = Instance.new("TextLabel")
		tagBadge.Name = "Tag"
		tagBadge.AnchorPoint = Vector2.new(0.5, 0)
		tagBadge.Position = UDim2.new(0.5, 0, 0, -8)
		tagBadge.Size = UDim2.fromOffset(math.max(#data.tag * 8 + 18, 48), 22)
		tagBadge.BackgroundColor3 = C.Gold
		tagBadge.Font = Enum.Font.GothamBold
		tagBadge.TextColor3 = Color3.fromRGB(62, 40, 0)
		tagBadge.TextSize = 12
		tagBadge.Text = data.tag
		tagBadge.BorderSizePixel = 0
		tagBadge.ZIndex = 10
		tagBadge.Parent = card
		local tc = Instance.new("UICorner")
		tc.CornerRadius = UDim.new(0, 7)
		tc.Parent = tagBadge
		local tcs = Instance.new("UIStroke")
		tcs.Color = Color3.fromRGB(175, 138, 0)
		tcs.Thickness = 1.5
		tcs.Transparency = 0.35
		tcs.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		tcs.Parent = tagBadge
	end

	if data.equipped then
		local check = Instance.new("TextLabel")
		check.Name = "Equipped"
		check.AnchorPoint = Vector2.new(1, 0)
		check.Position = UDim2.new(1, -4, 0, 4)
		check.Size = UDim2.fromOffset(26, 26)
		check.BackgroundColor3 = C.Green
		check.Font = Enum.Font.GothamBold
		check.Text = "\xe2\x9c\x93"
		check.TextColor3 = C.TextWhite
		check.TextSize = 15
		check.BorderSizePixel = 0
		check.ZIndex = 10
		check.Parent = card
		local chc = Instance.new("UICorner")
		chc.CornerRadius = UDim.new(1, 0)
		chc.Parent = check
		local chs = Instance.new("UIStroke")
		chs.Color = Color3.fromRGB(255, 255, 255)
		chs.Thickness = 1.5
		chs.Transparency = 0.3
		chs.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		chs.Parent = check
	end

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "ItemName"
	nameLabel.Size = UDim2.new(1, -10, 0, 20)
	nameLabel.Position = UDim2.new(0, 5, 0, 102)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextColor3 = data.locked and Color3.fromRGB(55, 58, 80) or C.TextWhite
	nameLabel.TextSize = 15
	nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
	nameLabel.TextXAlignment = Enum.TextXAlignment.Center
	nameLabel.Text = data.locked and "???" or data.name
	nameLabel.Parent = card
	if not data.locked then
		local ns = Instance.new("UIStroke")
		ns.Color = Color3.fromRGB(0, 0, 0)
		ns.Thickness = 1.5
		ns.Transparency = 0.15
		ns.Parent = nameLabel
	end

	local rarLabel = Instance.new("TextLabel")
	rarLabel.Name = "Rarity"
	rarLabel.Size = UDim2.new(1, -10, 0, 16)
	rarLabel.Position = UDim2.new(0, 5, 0, 120)
	rarLabel.BackgroundTransparency = 1
	rarLabel.Font = Enum.Font.GothamBold
	rarLabel.TextColor3 = data.locked and Color3.fromRGB(42, 45, 65) or rarityColor
	rarLabel.TextSize = 13
	rarLabel.TextXAlignment = Enum.TextXAlignment.Center
	rarLabel.Text = data.locked and "" or rarityInfo.label
	rarLabel.Parent = card

	if data.actionText and not data.locked then
		local btnColor = data.actionColor or C.BuyButton
		local btn = Instance.new("TextButton")
		btn.Name = "ActionBtn"
		btn.AnchorPoint = Vector2.new(0.5, 1)
		btn.Position = UDim2.new(0.5, 0, 1, -8)
		btn.Size = UDim2.new(1, -16, 0, 34)
		btn.BackgroundColor3 = btnColor
		btn.Font = Enum.Font.GothamBold
		btn.TextColor3 = C.TextWhite
		btn.TextSize = 15
		btn.Text = data.actionText
		btn.BorderSizePixel = 0
		btn.AutoButtonColor = false
		btn.Parent = card
		local bc = Instance.new("UICorner")
		bc.CornerRadius = UDim.new(0, S.SmBtnCorner)
		bc.Parent = btn

		local abr, abg, abb = btnColor.R, btnColor.G, btnColor.B
		local lighterAB = Color3.new(
			math.min(abr + 0.20, 1),
			math.min(abg + 0.20, 1),
			math.min(abb + 0.20, 1)
		)
		local darkerAB = Color3.new(
			math.max(abr - 0.10, 0),
			math.max(abg - 0.10, 0),
			math.max(abb - 0.10, 0)
		)
		local abGrad = Instance.new("UIGradient")
		abGrad.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, lighterAB),
			ColorSequenceKeypoint.new(0.5, btnColor),
			ColorSequenceKeypoint.new(1, darkerAB),
		})
		abGrad.Rotation = 90
		abGrad.Parent = btn

		local bs = Instance.new("UIStroke")
		bs.Color = Color3.fromRGB(255, 255, 255)
		bs.Thickness = 1.5
		bs.Transparency = 0.4
		bs.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		bs.Parent = btn

		local bts = Instance.new("UIStroke")
		bts.Color = Color3.fromRGB(0, 0, 0)
		bts.Thickness = 1.5
		bts.Transparency = 0.12
		bts.Parent = btn

		AnimUtil.WireButton(btn, function()
			SoundUtil.Click()
			if data.onAction then data.onAction() end
		end)
	end

	return card
end

-- ═══════════════════════════════════════════════════════════════════
-- CRATE SECTION  (for walk-up Crate Shop — big icon, drops, buy buttons)
-- ═══════════════════════════════════════════════════════════════════

export type CrateData = {
	name: string,
	iconColor: Color3,
	accentColor: Color3?,
	drops: {{ name: string, chance: number, rarity: string }},
	prices: {{ label: string, cost: number, currency: string }},
	onBuy: ((priceIndex: number) -> ())?,
}

function Components.CreateCrateSection(parent: Instance, data: CrateData): Frame
	local accent = data.accentColor or data.iconColor

	local section = Instance.new("Frame")
	section.Name = "Crate_" .. data.name
	section.Size = UDim2.new(1, -20, 0, S.CrateSectionHeight)
	section.BackgroundColor3 = C.CardBg
	section.BorderSizePixel = 0
	section.Parent = parent
	local sc = Instance.new("UICorner")
	sc.CornerRadius = UDim.new(0, S.CardCorner)
	sc.Parent = section
	local ss = Instance.new("UIStroke")
	ss.Color = accent
	ss.Thickness = 2.5
	ss.Transparency = 0.12
	ss.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	ss.Parent = section

	addGloss(section, 0.82, 0.94)

	addStudTexture(section, S.CardCorner)

	local iconArea = Instance.new("Frame")
	iconArea.Name = "IconArea"
	iconArea.Size = UDim2.new(0, 120, 1, -14)
	iconArea.Position = UDim2.fromOffset(7, 7)
	iconArea.BackgroundColor3 = data.iconColor
	iconArea.BorderSizePixel = 0
	iconArea.Parent = section
	local iac = Instance.new("UICorner")
	iac.CornerRadius = UDim.new(0, 14)
	iac.Parent = iconArea
	addGloss(iconArea, 0.38, 0.75)
	local ias = Instance.new("UIStroke")
	ias.Color = Color3.fromRGB(255, 255, 255)
	ias.Thickness = 1.5
	ias.Transparency = 0.5
	ias.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	ias.Parent = iconArea

	local crateEmoji = Instance.new("TextLabel")
	crateEmoji.Size = UDim2.new(1, 0, 0, 70)
	crateEmoji.Position = UDim2.fromOffset(0, 18)
	crateEmoji.BackgroundTransparency = 1
	crateEmoji.Font = Enum.Font.GothamBold
	crateEmoji.Text = "\xF0\x9F\x93\xA6"
	crateEmoji.TextSize = 46
	crateEmoji.TextColor3 = C.TextWhite
	crateEmoji.Parent = iconArea
	local ces = Instance.new("UIStroke")
	ces.Color = Color3.fromRGB(0, 0, 0)
	ces.Thickness = 1.8
	ces.Transparency = 0.22
	ces.Parent = crateEmoji

	local crateName = Instance.new("TextLabel")
	crateName.Name = "Name"
	crateName.AnchorPoint = Vector2.new(0.5, 1)
	crateName.Position = UDim2.new(0.5, 0, 1, -10)
	crateName.Size = UDim2.new(1, -8, 0, 34)
	crateName.BackgroundTransparency = 1
	crateName.Font = Enum.Font.GothamBold
	crateName.TextColor3 = C.TextWhite
	crateName.TextSize = 15
	crateName.Text = data.name
	crateName.TextWrapped = true
	crateName.Parent = iconArea
	local cns = Instance.new("UIStroke")
	cns.Color = Color3.fromRGB(0, 0, 0)
	cns.Thickness = 1.5
	cns.Transparency = 0.22
	cns.Parent = crateName

	local titleR = Instance.new("TextLabel")
	titleR.Name = "Title"
	titleR.Size = UDim2.new(1, -150, 0, 28)
	titleR.Position = UDim2.fromOffset(138, 10)
	titleR.BackgroundTransparency = 1
	titleR.Font = Enum.Font.GothamBold
	titleR.TextColor3 = C.TextWhite
	titleR.TextSize = 19
	titleR.TextXAlignment = Enum.TextXAlignment.Left
	titleR.Text = data.name
	titleR.Parent = section
	local trs = Instance.new("UIStroke")
	trs.Color = Color3.fromRGB(0, 0, 0)
	trs.Thickness = 1.5
	trs.Transparency = 0.22
	trs.Parent = titleR

	for i, drop in ipairs(data.drops) do
		local dRarity = UIConfig.RarityInfo[drop.rarity] or UIConfig.RarityInfo.Common
		local dLabel = Instance.new("TextLabel")
		dLabel.Name = "Drop" .. i
		dLabel.Size = UDim2.new(0, 220, 0, 20)
		dLabel.Position = UDim2.fromOffset(138, 36 + (i - 1) * 22)
		dLabel.BackgroundTransparency = 1
		dLabel.Font = Enum.Font.GothamBold
		dLabel.TextColor3 = dRarity.color
		dLabel.TextSize = 14
		dLabel.TextXAlignment = Enum.TextXAlignment.Left
		dLabel.Text = string.format("%d%%  %s", drop.chance, drop.name)
		dLabel.Parent = section
		local ds = Instance.new("UIStroke")
		ds.Color = Color3.fromRGB(0, 0, 0)
		ds.Thickness = 1.2
		ds.Transparency = 0.18
		ds.Parent = dLabel
	end

	local btnRow = Instance.new("Frame")
	btnRow.Name = "BuyButtons"
	btnRow.AnchorPoint = Vector2.new(0, 1)
	btnRow.Position = UDim2.new(0, 138, 1, -10)
	btnRow.Size = UDim2.new(1, -150, 0, 54)
	btnRow.BackgroundTransparency = 1
	btnRow.BorderSizePixel = 0
	btnRow.Parent = section

	local bLayout = Instance.new("UIListLayout")
	bLayout.FillDirection = Enum.FillDirection.Horizontal
	bLayout.Padding = UDim.new(0, 8)
	bLayout.SortOrder = Enum.SortOrder.LayoutOrder
	bLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	bLayout.Parent = btnRow

	for pi, price in ipairs(data.prices) do
		local isRobux = price.currency == "Robux"
		local priceText = isRobux and string.format("R$ %d", price.cost) or string.format("F %d", price.cost)
		local btnColor = isRobux and C.RobuxButton or C.BuyButton

		local pBtn = Instance.new("TextButton")
		pBtn.Name = "Price" .. pi
		pBtn.Size = UDim2.fromOffset(105, 50)
		pBtn.BackgroundColor3 = btnColor
		pBtn.Font = Enum.Font.GothamBold
		pBtn.TextColor3 = C.TextWhite
		pBtn.TextSize = 15
		pBtn.Text = priceText .. "\n" .. price.label
		pBtn.TextYAlignment = Enum.TextYAlignment.Center
		pBtn.BorderSizePixel = 0
		pBtn.AutoButtonColor = false
		pBtn.LayoutOrder = pi
		pBtn.Parent = btnRow
		local pbc = Instance.new("UICorner")
		pbc.CornerRadius = UDim.new(0, S.SmBtnCorner)
		pbc.Parent = pBtn

		local br, bg, bb = btnColor.R, btnColor.G, btnColor.B
		local lighterBtn = Color3.new(
			math.min(br + 0.20, 1),
			math.min(bg + 0.20, 1),
			math.min(bb + 0.20, 1)
		)
		local darkerBtn = Color3.new(
			math.max(br - 0.12, 0),
			math.max(bg - 0.12, 0),
			math.max(bb - 0.12, 0)
		)
		local pbGrad = Instance.new("UIGradient")
		pbGrad.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, lighterBtn),
			ColorSequenceKeypoint.new(0.5, btnColor),
			ColorSequenceKeypoint.new(1, darkerBtn),
		})
		pbGrad.Rotation = 90
		pbGrad.Parent = pBtn

		local pbs = Instance.new("UIStroke")
		pbs.Color = Color3.fromRGB(255, 255, 255)
		pbs.Thickness = 1.5
		pbs.Transparency = 0.4
		pbs.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		pbs.Parent = pBtn

		local pbts = Instance.new("UIStroke")
		pbts.Color = Color3.fromRGB(0, 0, 0)
		pbts.Thickness = 1.2
		pbts.Transparency = 0.18
		pbts.Parent = pBtn

		AnimUtil.WireButton(pBtn, function()
			SoundUtil.Click()
			if data.onBuy then data.onBuy(pi) end
		end)
	end

	return section
end

-- ═══════════════════════════════════════════════════════════════════
-- GRID LAYOUT  (for item cards)
-- ═══════════════════════════════════════════════════════════════════

function Components.AddGridLayout(parent: Instance, cellSize: Vector2?, padding: number?): UIGridLayout
	cellSize = cellSize or Vector2.new(S.CardWidth, S.CardHeight)
	padding = padding or S.CardPad
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.fromOffset(cellSize.X, cellSize.Y)
	grid.CellPadding = UDim2.fromOffset(padding, padding)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.FillDirection = Enum.FillDirection.Horizontal
	grid.HorizontalAlignment = Enum.HorizontalAlignment.Center
	grid.Parent = parent
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 10)
	pad.PaddingBottom = UDim.new(0, 10)
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 8)
	pad.Parent = parent
	return grid
end

-- ═══════════════════════════════════════════════════════════════════
-- LIST LAYOUT  (for crate sections, stacked vertically)
-- ═══════════════════════════════════════════════════════════════════

function Components.AddListLayout(parent: Instance, padding: number?)
	padding = padding or 14
	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, padding)
	list.FillDirection = Enum.FillDirection.Vertical
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.Parent = parent
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 10)
	pad.PaddingBottom = UDim.new(0, 10)
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 8)
	pad.Parent = parent
end

-- ═══════════════════════════════════════════════════════════════════
-- SIDEBAR BUTTON  (dark, chunky, glossy — refined strokes)
-- ═══════════════════════════════════════════════════════════════════

function Components.CreateSideButton(parent: Instance, label: string, iconText: string, bgColor: Color3, layoutOrder: number, onClick: () -> ()): TextButton
	local btn = Instance.new("TextButton")
	btn.Name = "Side_" .. label
	btn.Size = UDim2.fromOffset(S.SideBtnW, S.SideBtnH)
	btn.BackgroundColor3 = bgColor
	btn.BorderSizePixel = 0
	btn.AutoButtonColor = false
	btn.Text = ""
	btn.LayoutOrder = layoutOrder
	btn.Parent = parent

	local co = Instance.new("UICorner")
	co.CornerRadius = UDim.new(0, S.SideBtnCorner)
	co.Parent = btn

	local st = Instance.new("UIStroke")
	st.Color = Color3.fromRGB(255, 255, 255)
	st.Thickness = 2.5
	st.Transparency = 0.28
	st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	st.Parent = btn

	local r, g, b = bgColor.R, bgColor.G, bgColor.B
	local lighterColor = Color3.new(
		math.min(r + 0.22, 1),
		math.min(g + 0.22, 1),
		math.min(b + 0.22, 1)
	)
	local darkerColor = Color3.new(
		math.max(r - 0.10, 0),
		math.max(g - 0.10, 0),
		math.max(b - 0.10, 0)
	)
	local sideGrad = Instance.new("UIGradient")
	sideGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, lighterColor),
		ColorSequenceKeypoint.new(0.5, bgColor),
		ColorSequenceKeypoint.new(1, darkerColor),
	})
	sideGrad.Rotation = 90
	sideGrad.Parent = btn

	local shadow = Instance.new("Frame")
	shadow.Name = "Shadow"
	shadow.AnchorPoint = Vector2.new(0.5, 0.5)
	shadow.Position = UDim2.new(0.5, 2, 0.5, 4)
	shadow.Size = UDim2.new(1, 10, 1, 10)
	shadow.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	shadow.BackgroundTransparency = 0.5
	shadow.BorderSizePixel = 0
	shadow.ZIndex = 0
	shadow.Parent = btn
	local shc = Instance.new("UICorner")
	shc.CornerRadius = UDim.new(0, S.SideBtnCorner + 4)
	shc.Parent = shadow

	local icon = Instance.new("TextLabel")
	icon.Name = "Icon"
	icon.Size = UDim2.new(1, 0, 0, 40)
	icon.Position = UDim2.fromOffset(0, 6)
	icon.BackgroundTransparency = 1
	icon.Font = Enum.Font.GothamBold
	icon.TextColor3 = C.TextWhite
	icon.TextSize = 36
	icon.Text = iconText
	icon.ZIndex = 2
	icon.Parent = btn
	local is = Instance.new("UIStroke")
	is.Color = Color3.fromRGB(0, 0, 0)
	is.Thickness = 2
	is.Transparency = 0.15
	is.Parent = icon

	local lbl = Instance.new("TextLabel")
	lbl.Name = "Label"
	lbl.Size = UDim2.new(1, 0, 0, 20)
	lbl.Position = UDim2.new(0, 0, 1, -24)
	lbl.BackgroundTransparency = 1
	lbl.Font = Enum.Font.GothamBold
	lbl.TextColor3 = C.TextWhite
	lbl.TextSize = 14
	lbl.Text = label
	lbl.ZIndex = 2
	lbl.Parent = btn
	local ls = Instance.new("UIStroke")
	ls.Color = Color3.fromRGB(0, 0, 0)
	ls.Thickness = 1.5
	ls.Transparency = 0.2
	ls.Parent = lbl

	AnimUtil.WireButton(btn, function()
		SoundUtil.Click()
		onClick()
	end)

	return btn
end

return Components
