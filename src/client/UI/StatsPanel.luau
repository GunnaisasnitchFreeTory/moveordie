--[[
	StatsPanel
	Player profile stats panel — shows lifetime stats in a clean vertical list.

	Stats displayed:
	  - Time Played (hh:mm:ss)
	  - Wins
	  - Crowns Obtained
	  - Coins Earned (lifetime)
	  - Pets Obtained
	  - Deaths

	All data comes from server-replicated player attributes.
	Refreshes every 0.5s while open (for live time-played ticking).

	API:
	  Init(screenGui, onClose)
	  Show() / Hide() / IsVisible() / Toggle()

	Used by: UIController (sidebar "Stats" button)
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UIConfig = require(Shared:WaitForChild("UIConfig"))

local Client = script.Parent
local AnimUtil   = require(Client:WaitForChild("AnimUtil"))
local SoundUtil  = require(Client:WaitForChild("SoundUtil"))
local Components = require(Client:WaitForChild("Components"))

local C = UIConfig.Colors
local S = UIConfig.Sizes

local LocalPlayer = Players.LocalPlayer

local canvas: CanvasGroup = nil
local uiScale: UIScale = nil
local overlay: Frame = nil
local visible = false
local closeCallback: (() -> ())? = nil

local _refreshConn = nil
local _valueLabels: { [string]: TextLabel } = {}

local StatsPanel = {}

-- ═══════════════════════════════════════════════════════════════════
-- THEME
-- ═══════════════════════════════════════════════════════════════════

local HEADER_COLOR  = C.HeaderStats or Color3.fromRGB(48, 210, 190)
local ROW_BG_DARK   = Color3.fromRGB(18, 24, 46)
local ROW_BG_LIGHT  = Color3.fromRGB(24, 32, 56)
local LABEL_COLOR   = Color3.fromRGB(160, 180, 220)
local VALUE_COLOR   = Color3.fromRGB(255, 255, 255)
local ACCENT_COLORS = {
	Color3.fromRGB(80, 255, 200),   -- Time Played
	Color3.fromRGB(255, 220, 60),   -- Wins
	Color3.fromRGB(188, 62, 255),   -- Crowns
	Color3.fromRGB(255, 200, 60),   -- Coins
	Color3.fromRGB(252, 158, 35),   -- Pets
	Color3.fromRGB(255, 80, 100),   -- Deaths
}

-- ═══════════════════════════════════════════════════════════════════
-- HELPERS
-- ═══════════════════════════════════════════════════════════════════

local function formatTime(totalSeconds: number): string
	totalSeconds = math.floor(totalSeconds)
	local h = math.floor(totalSeconds / 3600)
	local m = math.floor((totalSeconds % 3600) / 60)
	local s = totalSeconds % 60
	return string.format("%02d:%02d:%02d", h, m, s)
end

local function formatNumber(n: number): string
	if n >= 1000000 then return string.format("%.1fM", n / 1000000) end
	if n >= 10000 then return string.format("%.1fK", n / 1000) end
	return tostring(n)
end

local function countJsonArray(jsonStr: string?): number
	if not jsonStr or jsonStr == "" or jsonStr == "[]" then return 0 end
	local ok, arr = pcall(HttpService.JSONDecode, HttpService, jsonStr)
	if ok and type(arr) == "table" then return #arr end
	return 0
end

local function getStats(): { [string]: string }
	return {
		TimePlayed = formatTime(LocalPlayer:GetAttribute("TimePlayedSeconds") or 0),
		Wins       = formatNumber(LocalPlayer:GetAttribute("LifetimeWins") or 0),
		Crowns     = tostring(countJsonArray(LocalPlayer:GetAttribute("OwnedCrowns"))),
		Coins      = formatNumber(LocalPlayer:GetAttribute("LifetimeCoinsAchieved") or 0),
		Pets       = tostring(countJsonArray(LocalPlayer:GetAttribute("OwnedPets"))),
		Deaths     = formatNumber(LocalPlayer:GetAttribute("LifetimeDeaths") or 0),
	}
end

local function refreshValues()
	local stats = getStats()
	if _valueLabels.TimePlayed then _valueLabels.TimePlayed.Text = stats.TimePlayed end
	if _valueLabels.Wins       then _valueLabels.Wins.Text       = stats.Wins end
	if _valueLabels.Crowns     then _valueLabels.Crowns.Text     = stats.Crowns end
	if _valueLabels.Coins      then _valueLabels.Coins.Text      = stats.Coins end
	if _valueLabels.Pets       then _valueLabels.Pets.Text       = stats.Pets end
	if _valueLabels.Deaths     then _valueLabels.Deaths.Text     = stats.Deaths end
end

-- ═══════════════════════════════════════════════════════════════════
-- BUILD ROW
-- ═══════════════════════════════════════════════════════════════════

local function buildStatRow(parent: Frame, index: number, icon: string, label: string, key: string, value: string)
	local bgColor = (index % 2 == 0) and ROW_BG_LIGHT or ROW_BG_DARK
	local accentColor = ACCENT_COLORS[index] or LABEL_COLOR

	local row = Instance.new("Frame")
	row.Name = "Row_" .. key
	row.Size = UDim2.new(1, 0, 0, 52)
	row.BackgroundColor3 = bgColor
	row.BackgroundTransparency = 0.15
	row.BorderSizePixel = 0
	row.LayoutOrder = index
	row.ZIndex = 6
	row.Parent = parent
	Instance.new("UICorner", row).CornerRadius = UDim.new(0, 8)

	-- Icon
	local iconLbl = Instance.new("TextLabel")
	iconLbl.Size = UDim2.fromOffset(40, 40)
	iconLbl.Position = UDim2.fromOffset(10, 6)
	iconLbl.BackgroundTransparency = 1
	iconLbl.Font = Enum.Font.GothamBold
	iconLbl.TextSize = 22
	iconLbl.Text = icon
	iconLbl.TextColor3 = accentColor
	iconLbl.ZIndex = 7
	iconLbl.Parent = row

	-- Label
	local labelLbl = Instance.new("TextLabel")
	labelLbl.AnchorPoint = Vector2.new(0, 0.5)
	labelLbl.Position = UDim2.new(0, 56, 0.5, 0)
	labelLbl.Size = UDim2.new(0.5, -60, 0, 20)
	labelLbl.BackgroundTransparency = 1
	labelLbl.Font = Enum.Font.GothamSemibold
	labelLbl.TextColor3 = LABEL_COLOR
	labelLbl.TextSize = 15
	labelLbl.TextXAlignment = Enum.TextXAlignment.Left
	labelLbl.Text = label
	labelLbl.ZIndex = 7
	labelLbl.Parent = row

	-- Value
	local valueLbl = Instance.new("TextLabel")
	valueLbl.Name = "Value"
	valueLbl.AnchorPoint = Vector2.new(1, 0.5)
	valueLbl.Position = UDim2.new(1, -16, 0.5, 0)
	valueLbl.Size = UDim2.new(0.4, 0, 0, 24)
	valueLbl.BackgroundTransparency = 1
	valueLbl.Font = Enum.Font.GothamBold
	valueLbl.TextColor3 = VALUE_COLOR
	valueLbl.TextSize = 18
	valueLbl.TextXAlignment = Enum.TextXAlignment.Right
	valueLbl.Text = value
	valueLbl.ZIndex = 7
	valueLbl.Parent = row

	local valueStroke = Instance.new("UIStroke")
	valueStroke.Color = Color3.fromRGB(0, 0, 0)
	valueStroke.Thickness = 1.2
	valueStroke.Transparency = 0.3
	valueStroke.Parent = valueLbl

	_valueLabels[key] = valueLbl
	return row
end

-- ═══════════════════════════════════════════════════════════════════
-- PANEL LIFECYCLE
-- ═══════════════════════════════════════════════════════════════════

function StatsPanel.Init(screenGui: ScreenGui, onClose: () -> ())
	closeCallback = onClose

	overlay = Components.CreateDimOverlay(screenGui, function()
		StatsPanel.Hide()
	end)

	local content, closeBtn
	canvas, uiScale, content, closeBtn = Components.CreatePanel(screenGui, "PLAYER STATS", HEADER_COLOR, "Stats")

	AnimUtil.WireButton(closeBtn, function()
		SoundUtil.Close()
		StatsPanel.Hide()
	end)

	-- Override stud texture to Fate Beams asset (only this panel)
	do
		local stud = canvas:FindFirstChild("StudTexture")
		if stud then
			stud.Image = "rbxassetid://70851348312450"
			stud.TileSize = UDim2.fromOffset(96, 96)
			stud.ImageTransparency = 0.88
			stud.ImageColor3 = Color3.fromRGB(255, 255, 255)
		end
	end

	-- Disable scroll — we have a fixed list
	if content then
		content.ScrollingEnabled = false
		content.AutomaticCanvasSize = Enum.AutomaticSize.None
		content.CanvasSize = UDim2.fromScale(0, 0)
		content.ScrollBarThickness = 0
	end

	-- Inner content padding
	local listLayout = Instance.new("UIListLayout")
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Padding = UDim.new(0, 6)
	listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	listLayout.Parent = content

	local listPad = Instance.new("UIPadding")
	listPad.PaddingLeft = UDim.new(0, 10)
	listPad.PaddingRight = UDim.new(0, 10)
	listPad.PaddingTop = UDim.new(0, 12)
	listPad.Parent = content

	-- Build stat rows
	local stats = getStats()
	buildStatRow(content, 1, "",  "Time Played",      "TimePlayed", stats.TimePlayed)
	buildStatRow(content, 2, "", "Wins",           "Wins",       stats.Wins)
	buildStatRow(content, 3, "", "Crowns Obtained","Crowns",     stats.Crowns)
	buildStatRow(content, 4, "", "Coins Earned",   "Coins",      stats.Coins)
	buildStatRow(content, 5, "", "Pets Obtained",  "Pets",       stats.Pets)
	buildStatRow(content, 6, "", "Deaths",         "Deaths",     stats.Deaths)

	print("[StatsPanel] Initialized")
end

-- ═══════════════════════════════════════════════════════════════════
-- SHOW / HIDE / TOGGLE
-- ═══════════════════════════════════════════════════════════════════

function StatsPanel.Show()
	if visible then return end
	visible = true
	overlay.Visible = true
	SoundUtil.Open()
	AnimUtil.OpenPanel(canvas, uiScale)

	-- Immediate refresh
	refreshValues()

	-- Live refresh every 0.5s (for time played ticking)
	if _refreshConn then _refreshConn:Disconnect() end
	local elapsed = 0
	_refreshConn = RunService.Heartbeat:Connect(function(dt)
		if not visible then return end
		elapsed += dt
		if elapsed >= 0.5 then
			elapsed = 0
			refreshValues()
		end
	end)
end

function StatsPanel.Hide()
	if not visible then return end
	visible = false
	if _refreshConn then _refreshConn:Disconnect(); _refreshConn = nil end
	overlay.Visible = false
	local t = AnimUtil.ClosePanel(canvas, uiScale)
	task.spawn(function()
		t.Completed:Wait()
		canvas.Visible = false
	end)
	if closeCallback then closeCallback() end
end

function StatsPanel.IsVisible(): boolean
	return visible
end

function StatsPanel.Toggle()
	if visible then StatsPanel.Hide() else StatsPanel.Show() end
end

return StatsPanel
