--[[
	QuestsPanel
	Daily quest UI — scrollable list of quests with progress bars.

	Theme: Glossy red, matching the rest of the UI aesthetic.
	Each row: left reward-card box (icon) + right progress rectangle.

	API:
	  Init(screenGui, onClose)
	  Show() / Hide() / IsVisible() / Toggle()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")
local RunService        = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared", 60)
if not Shared then
	warn("[QuestsPanel] Shared not found")
	return { Init=function()end, Show=function()end, Hide=function()end,
		IsVisible=function() return false end, Toggle=function()end }
end

local ok, Deps = pcall(require, Shared:WaitForChild("ClientDepsProvider", 60))
if not ok or not Deps then
	warn("[QuestsPanel] ClientDepsProvider failed:", Deps)
	return { Init=function()end, Show=function()end, Hide=function()end,
		IsVisible=function() return false end, Toggle=function()end }
end

local UIConfig = Deps.UIConfig

local okCfg, DailyQuestConfig = pcall(require, Shared:WaitForChild("DailyQuestConfig", 10))
if not okCfg or not DailyQuestConfig then
	warn("[QuestsPanel] DailyQuestConfig not found")
	return { Init=function()end, Show=function()end, Hide=function()end,
		IsVisible=function() return false end, Toggle=function()end }
end

local Client     = script.Parent
local AnimUtil   = require(Client:WaitForChild("AnimUtil"))
local SoundUtil  = require(Client:WaitForChild("SoundUtil"))
local Components = require(Client:WaitForChild("Components"))

-- ── THEME ────────────────────────────────────────────────────────────────────

local HEADER_COLOR   = Color3.fromRGB(200, 30,  30)
local HEADER_TOP     = Color3.fromRGB(255, 70,  70)
local HEADER_BOT     = Color3.fromRGB(140, 15,  15)
local INNER_BG       = Color3.fromRGB(30,  8,   8)
local CARD_BG        = Color3.fromRGB(20,  5,   5)
local CARD_BORDER    = Color3.fromRGB(200, 50,  50)
local BAR_BG         = Color3.fromRGB(50,  12,  12)
local BAR_FILL       = Color3.fromRGB(255, 60,  60)
local BAR_COMPLETE   = Color3.fromRGB(80,  255, 120)
local TEXT_WHITE     = Color3.fromRGB(255, 255, 255)
local TEXT_MUTED     = Color3.fromRGB(200, 150, 150)
local CLAIM_GREEN    = Color3.fromRGB(50,  200, 80)
local CLAIM_DISABLED = Color3.fromRGB(60,  20,  20)
local CLAIMED_COLOR  = Color3.fromRGB(80,  80,  80)

-- ── STATE ────────────────────────────────────────────────────────────────────

local QuestsPanel = {}
local canvas       = nil
local uiScale      = nil
local overlay      = nil
local visible      = false
local closeCallback = nil

local _questRows   = {}    -- { row, progressFill, progressLabel, claimBtn, barBg }
local _status      = nil
local _getStatusFunc: RemoteFunction? = nil
local _claimFunc: RemoteFunction?     = nil
local _updateRemote: RemoteEvent?     = nil

-- ── REMOTE HELPERS ───────────────────────────────────────────────────────────

local function ensureRemotes()
	if _getStatusFunc and _claimFunc then return end
	pcall(function()
		local remotes = ReplicatedStorage:WaitForChild("Remotes", 5)
		if not remotes then return end
		_getStatusFunc = remotes:WaitForChild("DailyQuest_GetStatus", 5)
		_claimFunc     = remotes:WaitForChild("DailyQuest_Claim", 5)
		_updateRemote  = remotes:FindFirstChild("DailyQuest_Update")
	end)
end

local function fetchStatus()
	ensureRemotes()
	if _getStatusFunc then
		local s_ok, status = pcall(_getStatusFunc.InvokeServer, _getStatusFunc)
		if s_ok and status then return status end
	end
	return nil
end

local function claimQuest(questId: string)
	ensureRemotes()
	if _claimFunc then
		local c_ok, result = pcall(_claimFunc.InvokeServer, _claimFunc, questId)
		if c_ok and result then return result end
	end
	return { success = false, reason = "Remote unavailable" }
end

-- ── UI UPDATE ────────────────────────────────────────────────────────────────

local function updateRow(rowData: {}, quest: {})
	if not rowData then return end

	local progress  = math.min(quest.progress or 0, quest.target or 1)
	local target    = quest.target or 1
	local completed = progress >= target
	local claimed   = quest.claimed

	-- Progress fill bar
	local frac = math.clamp(progress / target, 0, 1)
	if rowData.progressFill then
		TweenService:Create(rowData.progressFill,
			TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = UDim2.new(frac, 0, 1, 0) }
		):Play()
		rowData.progressFill.BackgroundColor3 = (completed or claimed) and BAR_COMPLETE or BAR_FILL
	end

	-- Progress label
	if rowData.progressLabel then
		rowData.progressLabel.Text = string.format("%d / %d", progress, target)
	end

	-- Claim button
	if rowData.claimBtn then
		if claimed then
			rowData.claimBtn.Text = "CLAIMED"
			rowData.claimBtn.BackgroundColor3 = CLAIMED_COLOR
			rowData.claimBtn.TextColor3 = Color3.fromRGB(120, 120, 120)
			rowData.claimBtn.Active = false
			rowData.claimBtn.AutoButtonColor = false
		elseif completed then
			rowData.claimBtn.Text = "CLAIM"
			rowData.claimBtn.BackgroundColor3 = CLAIM_GREEN
			rowData.claimBtn.TextColor3 = TEXT_WHITE
			rowData.claimBtn.Active = true
			rowData.claimBtn.AutoButtonColor = true
		else
			rowData.claimBtn.Text = "LOCKED"
			rowData.claimBtn.BackgroundColor3 = CLAIM_DISABLED
			rowData.claimBtn.TextColor3 = TEXT_MUTED
			rowData.claimBtn.Active = false
			rowData.claimBtn.AutoButtonColor = false
		end
	end

	-- Card border glow when complete
	if rowData.card then
		local stroke = rowData.card:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = completed and BAR_COMPLETE or CARD_BORDER
			stroke.Transparency = completed and 0.0 or 0.35
		end
	end
end

local function refreshUI()
	_status = fetchStatus()
	if not _status or not _status.quests then return end
	for _, quest in ipairs(_status.quests) do
		local rowData = _questRows[quest.id]
		if rowData then updateRow(rowData, quest) end
	end
end

-- ── PANEL BUILD ──────────────────────────────────────────────────────────────

local function buildPanel(parent: Instance)
	-- Root canvas
	canvas = Instance.new("CanvasGroup")
	canvas.Name            = "QuestsPanel"
	canvas.AnchorPoint     = Vector2.new(0.5, 0.5)
	canvas.Position        = UDim2.fromScale(0.5, 0.5)
	canvas.Size            = UDim2.fromScale(0.72, 0.80)
	canvas.BackgroundColor3 = INNER_BG
	canvas.BackgroundTransparency = 0
	canvas.BorderSizePixel = 0
	canvas.GroupTransparency = 1
	canvas.Visible         = false
	canvas.ZIndex          = 5
	canvas.ClipsDescendants = true
	canvas.Parent          = parent

	Instance.new("UICorner", canvas).CornerRadius = UDim.new(0, 14)

	local stroke = Instance.new("UIStroke")
	stroke.Color       = HEADER_COLOR
	stroke.Thickness   = 3
	stroke.Transparency = 0.08
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent      = canvas

	-- Drop shadow
	local shadow = Instance.new("Frame")
	shadow.AnchorPoint        = Vector2.new(0.5, 0.5)
	shadow.Position           = UDim2.new(0.5, 5, 0.5, 8)
	shadow.Size               = UDim2.new(1, 20, 1, 20)
	shadow.BackgroundColor3   = Color3.new(0, 0, 0)
	shadow.BackgroundTransparency = 0.45
	shadow.BorderSizePixel    = 0
	shadow.ZIndex             = 4
	shadow.Parent             = canvas
	Instance.new("UICorner", shadow).CornerRadius = UDim.new(0, 20)

	uiScale = Instance.new("UIScale")
	uiScale.Scale  = 0.9
	uiScale.Parent = canvas

	-- Overlay dim
	overlay = Instance.new("Frame")
	overlay.Name              = "Overlay"
	overlay.AnchorPoint       = Vector2.new(0.5, 0.5)
	overlay.Position          = UDim2.fromScale(0.5, 0.5)
	overlay.Size              = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3  = Color3.new(0, 0, 0)
	overlay.BackgroundTransparency = 1
	overlay.BorderSizePixel   = 0
	overlay.ZIndex            = 1
	overlay.Visible           = false
	overlay.Parent            = parent

	-- Subtle stud texture overlay
	local studTex = Instance.new("ImageLabel")
	studTex.Name              = "StudTexture"
	studTex.AnchorPoint       = Vector2.new(0, 0)
	studTex.Position          = UDim2.fromScale(0, 0)
	studTex.Size              = UDim2.fromScale(1, 1)
	studTex.BackgroundTransparency = 1
	studTex.Image             = "rbxassetid://70851348312450"
	studTex.ImageTransparency = 0.93
	studTex.ScaleType         = Enum.ScaleType.Tile
	studTex.TileSize          = UDim2.fromOffset(64, 64)
	studTex.ImageColor3       = Color3.fromRGB(255, 100, 100)
	studTex.ZIndex            = 6
	studTex.Parent            = canvas

	-- Radial center glow
	local glow = Instance.new("ImageLabel")
	glow.AnchorPoint          = Vector2.new(0.5, 0.5)
	glow.Position             = UDim2.fromScale(0.5, 0.5)
	glow.Size                 = UDim2.fromScale(1.3, 1.3)
	glow.BackgroundTransparency = 1
	glow.Image                = "rbxassetid://5607835947"
	glow.ImageColor3          = HEADER_COLOR
	glow.ImageTransparency    = 0.82
	glow.ZIndex               = 2
	glow.Parent               = canvas

	-- ── HEADER ──────────────────────────────────────────────────
	local header = Instance.new("Frame")
	header.Name             = "Header"
	header.AnchorPoint      = Vector2.new(0, 0)
	header.Position         = UDim2.fromOffset(0, 0)
	header.Size             = UDim2.new(1, 0, 0, 54)
	header.BackgroundColor3 = HEADER_COLOR
	header.BorderSizePixel  = 0
	header.ZIndex           = 8
	header.Parent           = canvas

	local hCorner = Instance.new("UICorner")
	hCorner.CornerRadius = UDim.new(0, 14)
	hCorner.Parent       = header

	-- Mask bottom corners of header
	local hMask = Instance.new("Frame")
	hMask.Position          = UDim2.new(0, 0, 0.5, 0)
	hMask.Size              = UDim2.new(1, 0, 0.5, 0)
	hMask.BackgroundColor3  = HEADER_COLOR
	hMask.BorderSizePixel   = 0
	hMask.ZIndex            = 8
	hMask.Parent            = header

	local hGrad = Instance.new("UIGradient")
	hGrad.Color    = ColorSequence.new({
		ColorSequenceKeypoint.new(0,   HEADER_TOP),
		ColorSequenceKeypoint.new(0.5, HEADER_COLOR),
		ColorSequenceKeypoint.new(1,   HEADER_BOT),
	})
	hGrad.Rotation = 90
	hGrad.Parent   = header

	local titleLabel = Instance.new("TextLabel")
	titleLabel.AnchorPoint      = Vector2.new(0, 0.5)
	titleLabel.Position         = UDim2.new(0, 18, 0.5, 0)
	titleLabel.Size             = UDim2.new(1, -56, 1, 0)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Font             = Enum.Font.GothamBold
	titleLabel.Text             = "\xE2\x9A\x94\xEF\xB8\x8F  DAILY QUESTS"
	titleLabel.TextColor3       = TEXT_WHITE
	titleLabel.TextSize         = 22
	titleLabel.TextXAlignment   = Enum.TextXAlignment.Left
	titleLabel.ZIndex           = 9
	titleLabel.Parent           = header
	local tlStroke = Instance.new("UIStroke")
	tlStroke.Color       = Color3.new(0, 0, 0)
	tlStroke.Thickness   = 1.8
	tlStroke.Transparency = 0.15
	tlStroke.Parent      = titleLabel

	-- Close button
	local closeBtn = Instance.new("TextButton")
	closeBtn.AnchorPoint      = Vector2.new(1, 0.5)
	closeBtn.Position         = UDim2.new(1, -12, 0.5, 0)
	closeBtn.Size             = UDim2.fromOffset(36, 36)
	closeBtn.BackgroundColor3 = Color3.fromRGB(180, 30, 30)
	closeBtn.BorderSizePixel  = 0
	closeBtn.Font             = Enum.Font.GothamBold
	closeBtn.Text             = "\xC3\x97"
	closeBtn.TextColor3       = TEXT_WHITE
	closeBtn.TextSize         = 22
	closeBtn.ZIndex           = 9
	closeBtn.Parent           = header
	Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(1, 0)
	AnimUtil.WireButton(closeBtn, function()
		if closeCallback then closeCallback() end
		QuestsPanel.Hide()
	end)

	-- Reset label (top right of body)
	local resetLabel = Instance.new("TextLabel")
	resetLabel.AnchorPoint    = Vector2.new(1, 0)
	resetLabel.Position       = UDim2.new(1, -14, 0, 60)
	resetLabel.Size           = UDim2.fromOffset(240, 20)
	resetLabel.BackgroundTransparency = 1
	resetLabel.Font           = Enum.Font.Gotham
	resetLabel.Text           = "Resets daily at midnight UTC"
	resetLabel.TextColor3     = TEXT_MUTED
	resetLabel.TextSize       = 12
	resetLabel.TextXAlignment = Enum.TextXAlignment.Right
	resetLabel.ZIndex         = 7
	resetLabel.Parent         = canvas

	-- ── SCROLL FRAME ────────────────────────────────────────────
	local scrollFrame = Instance.new("ScrollingFrame")
	scrollFrame.Name                = "QuestList"
	scrollFrame.AnchorPoint         = Vector2.new(0, 0)
	scrollFrame.Position            = UDim2.new(0, 12, 0, 62)
	scrollFrame.Size                = UDim2.new(1, -24, 1, -74)
	scrollFrame.BackgroundTransparency = 1
	scrollFrame.BorderSizePixel     = 0
	scrollFrame.ScrollBarThickness  = 6
	scrollFrame.ScrollBarImageColor3 = Color3.fromRGB(220, 60, 60)
	scrollFrame.CanvasSize          = UDim2.fromOffset(0, 0)
	scrollFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scrollFrame.ScrollingDirection  = Enum.ScrollingDirection.Y
	scrollFrame.ZIndex              = 7
	scrollFrame.Parent              = canvas

	local listLayout = Instance.new("UIListLayout")
	listLayout.Padding      = UDim.new(0, 10)
	listLayout.SortOrder    = Enum.SortOrder.LayoutOrder
	listLayout.FillDirection = Enum.FillDirection.Vertical
	listLayout.Parent        = scrollFrame

	local listPad = Instance.new("UIPadding")
	listPad.PaddingTop    = UDim.new(0, 6)
	listPad.PaddingBottom = UDim.new(0, 6)
	listPad.PaddingLeft   = UDim.new(0, 2)
	listPad.PaddingRight  = UDim.new(0, 6)
	listPad.Parent        = scrollFrame

	-- ── QUEST ROWS ──────────────────────────────────────────────
	-- Sort quests by order
	local sorted = {}
	for questId, questDef in pairs(DailyQuestConfig.Quests) do
		table.insert(sorted, { id = questId, def = questDef })
	end
	table.sort(sorted, function(a, b) return (a.def.order or 99) < (b.def.order or 99) end)

	for rowIndex, entry in ipairs(sorted) do
		local questId  = entry.id
		local questDef = entry.def

		-- Row container
		local row = Instance.new("Frame")
		row.Name               = "QuestRow_" .. questId
		row.Size               = UDim2.new(1, 0, 0, 90)
		row.BackgroundColor3   = CARD_BG
		row.BackgroundTransparency = 0
		row.BorderSizePixel    = 0
		row.LayoutOrder        = rowIndex
		row.ZIndex             = 7
		row.Parent             = scrollFrame

		Instance.new("UICorner", row).CornerRadius = UDim.new(0, 10)

		local rowStroke = Instance.new("UIStroke")
		rowStroke.Color       = CARD_BORDER
		rowStroke.Thickness   = 1.5
		rowStroke.Transparency = 0.35
		rowStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		rowStroke.Parent      = row

		-- Subtle row gradient
		local rowGrad = Instance.new("UIGradient")
		rowGrad.Color    = ColorSequence.new({
			ColorSequenceKeypoint.new(0,   Color3.fromRGB(45, 10, 10)),
			ColorSequenceKeypoint.new(0.5, CARD_BG),
			ColorSequenceKeypoint.new(1,   Color3.fromRGB(30, 6, 6)),
		})
		rowGrad.Rotation = 90
		rowGrad.Parent   = row

		-- ── LEFT CARD (reward icon) ──────────────────────────────
		local card = Instance.new("Frame")
		card.Name              = "RewardCard"
		card.AnchorPoint       = Vector2.new(0, 0.5)
		card.Position          = UDim2.new(0, 10, 0.5, 0)
		card.Size              = UDim2.fromOffset(70, 70)
		card.BackgroundColor3  = Color3.fromRGB(15, 4, 4)
		card.BorderSizePixel   = 0
		card.ZIndex            = 8
		card.Parent            = row

		Instance.new("UICorner", card).CornerRadius = UDim.new(0, 8)

		local cardStroke = Instance.new("UIStroke")
		cardStroke.Color       = CARD_BORDER
		cardStroke.Thickness   = 2
		cardStroke.Transparency = 0.35
		cardStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		cardStroke.Parent      = card

		local cardGrad = Instance.new("UIGradient")
		cardGrad.Color    = ColorSequence.new({
			ColorSequenceKeypoint.new(0,   Color3.fromRGB(60, 15, 15)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(30, 8, 8)),
			ColorSequenceKeypoint.new(1,   Color3.fromRGB(15, 3, 3)),
		})
		cardGrad.Rotation = 120
		cardGrad.Parent   = card

		-- Quest icon
		local iconLabel = Instance.new("TextLabel")
		iconLabel.AnchorPoint      = Vector2.new(0.5, 0.5)
		iconLabel.Position         = UDim2.fromScale(0.5, 0.5)
		iconLabel.Size             = UDim2.fromScale(0.85, 0.85)
		iconLabel.BackgroundTransparency = 1
		iconLabel.Font             = Enum.Font.GothamBold
		iconLabel.Text             = questDef.icon or "\xE2\x9C\x94"
		iconLabel.TextColor3       = questDef.iconColor and Color3.fromRGB(
			questDef.iconColor[1], questDef.iconColor[2], questDef.iconColor[3]) or HEADER_COLOR
		iconLabel.TextSize         = 32
		iconLabel.TextScaled       = false
		iconLabel.ZIndex           = 9
		iconLabel.Parent           = card

		-- ── RIGHT CONTENT AREA ───────────────────────────────────
		local content = Instance.new("Frame")
		content.AnchorPoint       = Vector2.new(0, 0)
		content.Position          = UDim2.new(0, 90, 0, 8)
		content.Size              = UDim2.new(1, -200, 1, -16)
		content.BackgroundTransparency = 1
		content.BorderSizePixel   = 0
		content.ZIndex            = 8
		content.Parent            = row

		-- Quest label
		local questLabel = Instance.new("TextLabel")
		questLabel.AnchorPoint    = Vector2.new(0, 0)
		questLabel.Position       = UDim2.fromOffset(0, 0)
		questLabel.Size           = UDim2.new(1, 0, 0, 22)
		questLabel.BackgroundTransparency = 1
		questLabel.Font           = Enum.Font.GothamBold
		questLabel.Text           = questDef.label or questId
		questLabel.TextColor3     = TEXT_WHITE
		questLabel.TextSize       = 16
		questLabel.TextXAlignment = Enum.TextXAlignment.Left
		questLabel.ZIndex         = 8
		questLabel.Parent         = content
		local qlStroke = Instance.new("UIStroke")
		qlStroke.Color       = Color3.new(0, 0, 0)
		qlStroke.Thickness   = 1.5
		qlStroke.Transparency = 0.2
		qlStroke.Parent      = questLabel

		-- Description
		local descLabel = Instance.new("TextLabel")
		descLabel.AnchorPoint    = Vector2.new(0, 0)
		descLabel.Position       = UDim2.fromOffset(0, 24)
		descLabel.Size           = UDim2.new(1, 0, 0, 16)
		descLabel.BackgroundTransparency = 1
		descLabel.Font           = Enum.Font.Gotham
		descLabel.Text           = questDef.description or ""
		descLabel.TextColor3     = TEXT_MUTED
		descLabel.TextSize       = 12
		descLabel.TextXAlignment = Enum.TextXAlignment.Left
		descLabel.ZIndex         = 8
		descLabel.Parent         = content

		-- Progress bar background
		local barBg = Instance.new("Frame")
		barBg.AnchorPoint       = Vector2.new(0, 1)
		barBg.Position          = UDim2.new(0, 0, 1, 0)
		barBg.Size              = UDim2.new(1, 0, 0, 14)
		barBg.BackgroundColor3  = BAR_BG
		barBg.BorderSizePixel   = 0
		barBg.ZIndex            = 8
		barBg.Parent            = content
		Instance.new("UICorner", barBg).CornerRadius = UDim.new(1, 0)

		-- Progress bar fill
		local progressFill = Instance.new("Frame")
		progressFill.AnchorPoint       = Vector2.new(0, 0)
		progressFill.Position          = UDim2.fromOffset(0, 0)
		progressFill.Size              = UDim2.new(0, 0, 1, 0)
		progressFill.BackgroundColor3  = BAR_FILL
		progressFill.BorderSizePixel   = 0
		progressFill.ZIndex            = 9
		progressFill.Parent            = barBg
		Instance.new("UICorner", progressFill).CornerRadius = UDim.new(1, 0)

		-- Progress label
		local progressLabel = Instance.new("TextLabel")
		progressLabel.AnchorPoint    = Vector2.new(1, 0.5)
		progressLabel.Position       = UDim2.new(1, 0, 0.5, 0)
		progressLabel.Size           = UDim2.fromOffset(60, 14)
		progressLabel.BackgroundTransparency = 1
		progressLabel.Font           = Enum.Font.GothamBold
		progressLabel.Text           = "0 / " .. tostring(questDef.target)
		progressLabel.TextColor3     = TEXT_WHITE
		progressLabel.TextSize       = 11
		progressLabel.TextXAlignment = Enum.TextXAlignment.Right
		progressLabel.ZIndex         = 10
		progressLabel.Parent         = barBg

		-- ── CLAIM BUTTON ─────────────────────────────────────────
		local claimBtn = Instance.new("TextButton")
		claimBtn.AnchorPoint       = Vector2.new(1, 0.5)
		claimBtn.Position          = UDim2.new(1, -12, 0.5, 0)
		claimBtn.Size              = UDim2.fromOffset(80, 40)
		claimBtn.BackgroundColor3  = CLAIM_DISABLED
		claimBtn.BorderSizePixel   = 0
		claimBtn.Font              = Enum.Font.GothamBold
		claimBtn.Text              = "LOCKED"
		claimBtn.TextColor3        = TEXT_MUTED
		claimBtn.TextSize          = 13
		claimBtn.Active            = false
		claimBtn.AutoButtonColor   = false
		claimBtn.ZIndex            = 9
		claimBtn.Parent            = row
		Instance.new("UICorner", claimBtn).CornerRadius = UDim.new(0, 10)

		local claimStroke = Instance.new("UIStroke")
		claimStroke.Color       = Color3.fromRGB(255, 255, 255)
		claimStroke.Thickness   = 1.5
		claimStroke.Transparency = 0.6
		claimStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		claimStroke.Parent      = claimBtn

		-- Wire claim button
		local capturedQuestId = questId
		AnimUtil.WireButton(claimBtn, function()
			if not claimBtn.Active then return end
			claimBtn.Active = false
			task.spawn(function()
				local result = claimQuest(capturedQuestId)
				if result and result.success then
					SoundUtil.Open()
				else
					claimBtn.Active = true
				end
			end)
		end)

		-- Store row data
		_questRows[questId] = {
			row           = row,
			card          = card,
			progressFill  = progressFill,
			progressLabel = progressLabel,
			claimBtn      = claimBtn,
			barBg         = barBg,
		}
	end
end

-- ── SHOW / HIDE ───────────────────────────────────────────────────────────────

function QuestsPanel.Show()
	if not canvas then return end
	visible = true
	canvas.Visible = true

	if overlay then
		overlay.Visible = true
		TweenService:Create(overlay, TweenInfo.new(0.18), { BackgroundTransparency = 0.55 }):Play()
	end

	uiScale.Scale = 0.88
	TweenService:Create(canvas,   TweenInfo.new(0.18), { GroupTransparency = 0 }):Play()
	TweenService:Create(uiScale,  TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()

	SoundUtil.Open()

	-- Fetch live data
	task.spawn(function()
		refreshUI()
	end)
end

function QuestsPanel.Hide()
	if not canvas then return end
	visible = false

	TweenService:Create(canvas,  TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { GroupTransparency = 1 }):Play()
	TweenService:Create(uiScale, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Scale = 0.92 }):Play()

	if overlay then
		TweenService:Create(overlay, TweenInfo.new(0.18), { BackgroundTransparency = 1 }):Play()
	end

	task.delay(0.2, function()
		if not visible and canvas then
			canvas.Visible = false
			if overlay then overlay.Visible = false end
		end
	end)

	SoundUtil.Close()
end

function QuestsPanel.IsVisible(): boolean
	return visible
end

function QuestsPanel.Toggle()
	if visible then QuestsPanel.Hide() else QuestsPanel.Show() end
end

-- ── INIT ─────────────────────────────────────────────────────────────────────

function QuestsPanel.Init(screenGui: ScreenGui, onClose: (() -> ())?)
	closeCallback = onClose

	buildPanel(screenGui)

	-- Listen for server push updates
	task.spawn(function()
		ensureRemotes()
		if not _updateRemote then
			pcall(function()
				local remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
				if remotes then
					_updateRemote = remotes:WaitForChild("DailyQuest_Update", 10)
				end
			end)
		end
		if _updateRemote then
			_updateRemote.OnClientEvent:Connect(function(status)
				_status = status
				if visible and status and status.quests then
					for _, quest in ipairs(status.quests) do
						local rowData = _questRows[quest.id]
						if rowData then updateRow(rowData, quest) end
					end
				end
			end)
		end
	end)
end

return QuestsPanel
