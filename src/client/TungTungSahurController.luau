--[[
	TungTungSahurController
	Client-side UI for TungTungSahur hazard.

	Layout — single top-center StatusStack (UIListLayout, vertical):
	  • Round UI sits above this stack in its own system
	  • Slot 1: Countdown pill  ("TUNGTUNGSAHUR: XX")
	  • Slot 2: Spawn banner    ("⚠ TUNGTUNGSAHUR HAS SPAWNED ⚠")
	Both slots live in one ScreenGui positioned below the Round counter.

	Remote events received from TungTungSahurEvent:
	  "Spawn", durationSeconds          → show banner + start countdown
	  "Despawn", showSurvival:boolean   → hide UI; if showSurvival=true and player alive → popup

	Mobile-friendly: all sizes in UDim2 relative or capped-pixel.
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")

local ANNOUNCEMENT_HOLD  = 3.0     -- seconds banner stays solid
local FADE_TIME          = 0.35
local STACK_DISPLAY_ORDER = 85
local SURVIVAL_DISPLAY_ORDER = 90
local STACK_TOP_Y        = 0.11    -- below round counter (~8% from top)
local STACK_PADDING      = 6       -- pixels between timer and banner

-- ─── STATE ───────────────────────────────────────────────────────────────────
local localPlayer        = Players.LocalPlayer
local stackGui: ScreenGui?     = nil
local stackFrame: Frame?       = nil
local countdownPill: Frame?    = nil
local countdownLabel: TextLabel? = nil
local announcePill: Frame?     = nil
local announceLabel: TextLabel? = nil
local survivalGui: ScreenGui?  = nil

local countdownThread: thread? = nil
local announceThread: thread?  = nil

local TungTungSahurController = {}

-- ─── HELPERS ──────────────────────────────────────────────────────────────────

local function cancelThread(t: thread?)
	if t then pcall(task.cancel, t) end
end

local function makePill(parent: Instance, height: number, bgColor: Color3, strokeColor: Color3): Frame
	local pill = Instance.new("Frame")
	pill.AnchorPoint           = Vector2.new(0.5, 0)
	pill.Position              = UDim2.new(0.5, 0, 0, 0)
	pill.Size                  = UDim2.new(1, 0, 0, height)
	pill.BackgroundColor3      = bgColor
	pill.BackgroundTransparency = 0.12
	pill.BorderSizePixel        = 0
	pill.Parent                 = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = pill

	local stroke = Instance.new("UIStroke")
	stroke.Color       = strokeColor
	stroke.Thickness   = 2
	stroke.Transparency = 0.1
	stroke.Parent      = pill

	return pill
end

local function makeLabel(parent: Instance, text: string, size: number, color: Color3, strokeColor: Color3): TextLabel
	local lbl = Instance.new("TextLabel")
	lbl.AnchorPoint           = Vector2.new(0.5, 0.5)
	lbl.Position              = UDim2.new(0.5, 0, 0.5, 0)
	lbl.Size                  = UDim2.new(1, -12, 1, 0)
	lbl.BackgroundTransparency = 1
	lbl.Font                  = Enum.Font.GothamBlack
	lbl.Text                  = text
	lbl.TextColor3            = color
	lbl.TextSize              = size
	lbl.TextScaled            = false
	lbl.TextXAlignment        = Enum.TextXAlignment.Center
	lbl.Parent                = parent

	local stroke = Instance.new("UIStroke")
	stroke.Color       = strokeColor
	stroke.Thickness   = 2
	stroke.Transparency = 0
	stroke.Parent      = lbl

	return lbl
end

-- ─── GUI BUILD ─────────────────────────────────────────────────────────────────

local function buildStackGui()
	local playerGui = localPlayer:WaitForChild("PlayerGui", 10)
	if not playerGui then return end

	-- Destroy old if exists
	local old = playerGui:FindFirstChild("TungTungStatusStack")
	if old then old:Destroy() end

	stackGui = Instance.new("ScreenGui")
	stackGui.Name            = "TungTungStatusStack"
	stackGui.ResetOnSpawn    = false
	stackGui.DisplayOrder    = STACK_DISPLAY_ORDER
	stackGui.IgnoreGuiInset  = true
	stackGui.Enabled         = false
	stackGui.Parent          = playerGui

	-- Container centered top — sits just below round counter
	stackFrame = Instance.new("Frame")
	stackFrame.Name             = "StatusStack"
	stackFrame.AnchorPoint      = Vector2.new(0.5, 0)
	stackFrame.Position         = UDim2.new(0.5, 0, STACK_TOP_Y, 0)
	stackFrame.Size             = UDim2.new(0, 300, 0, 200)   -- height auto from layout
	stackFrame.BackgroundTransparency = 1
	stackFrame.BorderSizePixel  = 0
	stackFrame.Parent           = stackGui

	local layout = Instance.new("UIListLayout")
	layout.SortOrder         = Enum.SortOrder.LayoutOrder
	layout.FillDirection     = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment  = Enum.VerticalAlignment.Top
	layout.Padding           = UDim.new(0, STACK_PADDING)
	layout.Parent            = stackFrame

	-- Slot 1 — countdown pill (LayoutOrder 1 = top)
	countdownPill = makePill(stackFrame, 40, Color3.fromRGB(160, 15, 15), Color3.fromRGB(255, 60, 60))
	countdownPill.Name        = "CountdownPill"
	countdownPill.LayoutOrder = 1
	countdownPill.Visible     = false

	countdownLabel = makeLabel(
		countdownPill,
		"TUNGTUNGSAHUR: 30",
		17,
		Color3.fromRGB(255, 255, 255),
		Color3.fromRGB(70, 0, 0)
	)
	countdownLabel.Name = "CountdownText"

	-- Slot 2 — announcement banner (LayoutOrder 2 = below countdown)
	announcePill = makePill(stackFrame, 48, Color3.fromRGB(35, 0, 0), Color3.fromRGB(255, 50, 50))
	announcePill.Name        = "AnnouncePill"
	announcePill.LayoutOrder = 2
	announcePill.Visible     = false

	-- Larger stroke for announcement
	announcePill.BackgroundTransparency = 0.05
	for _, s in ipairs(announcePill:GetChildren()) do
		if s:IsA("UIStroke") then s.Thickness = 2.5 end
	end

	announceLabel = makeLabel(
		announcePill,
		"⚠ TUNGTUNGSAHUR HAS SPAWNED ⚠",
		17,
		Color3.fromRGB(255, 80, 80),
		Color3.fromRGB(50, 0, 0)
	)
	announceLabel.Name = "AnnounceText"

	-- UISizeConstraint keeps pills from going too wide on large screens
	local maxWidth = Instance.new("UISizeConstraint")
	maxWidth.MaxSize = Vector2.new(340, 999)
	maxWidth.Parent = stackFrame
end

local function buildSurvivalGui()
	local playerGui = localPlayer:WaitForChild("PlayerGui", 10)
	if not playerGui then return end

	local old = playerGui:FindFirstChild("TungTungSurvivalGui")
	if old then old:Destroy() end

	survivalGui = Instance.new("ScreenGui")
	survivalGui.Name           = "TungTungSurvivalGui"
	survivalGui.ResetOnSpawn   = false
	survivalGui.DisplayOrder   = SURVIVAL_DISPLAY_ORDER
	survivalGui.IgnoreGuiInset = true
	survivalGui.Enabled        = false
	survivalGui.Parent         = playerGui

	local panel = Instance.new("Frame")
	panel.Name                  = "SurvivalPanel"
	panel.AnchorPoint           = Vector2.new(0.5, 0.5)
	panel.Position              = UDim2.new(0.5, 0, 0.45, 0)
	panel.Size                  = UDim2.new(0, 360, 0, 80)
	panel.BackgroundColor3      = Color3.fromRGB(5, 40, 5)
	panel.BackgroundTransparency = 0.1
	panel.BorderSizePixel       = 0
	panel.Parent                = survivalGui

	Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 14)

	local stroke = Instance.new("UIStroke")
	stroke.Color       = Color3.fromRGB(60, 230, 60)
	stroke.Thickness   = 2.5
	stroke.Transparency = 0
	stroke.Parent      = panel

	local lbl = Instance.new("TextLabel")
	lbl.Name                  = "SurvivalText"
	lbl.AnchorPoint           = Vector2.new(0.5, 0.5)
	lbl.Position              = UDim2.new(0.5, 0, 0.5, 0)
	lbl.Size                  = UDim2.new(1, -16, 1, 0)
	lbl.BackgroundTransparency = 1
	lbl.Font                  = Enum.Font.GothamBlack
	lbl.Text                  = "YOU HAVE SURVIVED TUNGTUNGSAHUR!"
	lbl.TextColor3            = Color3.fromRGB(80, 255, 80)
	lbl.TextSize              = 18
	lbl.TextScaled            = false
	lbl.TextWrapped           = true
	lbl.TextXAlignment        = Enum.TextXAlignment.Center
	lbl.Parent                = panel

	local textStroke = Instance.new("UIStroke")
	textStroke.Color       = Color3.fromRGB(0, 60, 0)
	textStroke.Thickness   = 2
	textStroke.Transparency = 0
	textStroke.Parent      = lbl
end

-- ─── SHOW / HIDE ──────────────────────────────────────────────────────────────

local function showCountdown()
	if stackGui then stackGui.Enabled = true end
	if countdownPill then countdownPill.Visible = true end
end

local function hideCountdown()
	if countdownPill then countdownPill.Visible = false end
	-- Hide entire stackGui only if announce is also hidden
	if announcePill and not announcePill.Visible then
		if stackGui then stackGui.Enabled = false end
	end
end

local function showAnnounce()
	if stackGui then stackGui.Enabled = true end
	if announcePill then announcePill.Visible = true end
end

local function hideAnnounce()
	if announcePill then announcePill.Visible = false end
	if countdownPill and not countdownPill.Visible then
		if stackGui then stackGui.Enabled = false end
	end
end

local function startCountdown(duration: number)
	hideCountdown()
	cancelThread(countdownThread)
	if not countdownLabel then return end

	showCountdown()

	countdownThread = task.spawn(function()
		local startTime = tick()
		while true do
			local elapsed   = tick() - startTime
			local remaining = math.max(0, math.ceil(duration - elapsed))
			if countdownLabel then
				countdownLabel.Text = string.format("TUNGTUNGSAHUR: %d", remaining)
			end
			if remaining <= 0 then
				hideCountdown()
				countdownThread = nil
				return
			end
			task.wait(0.25)
		end
	end)
end

local function runShowAnnouncement()
	cancelThread(announceThread)
	if not announcePill then return end

	-- Reset visuals
	announcePill.BackgroundTransparency = 0.05
	if announceLabel then announceLabel.TextTransparency = 0 end
	showAnnounce()

	announceThread = task.spawn(function()
		task.wait(ANNOUNCEMENT_HOLD)
		-- Fade out pill and text
		local info = TweenInfo.new(FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		if announcePill then
			TweenService:Create(announcePill, info, { BackgroundTransparency = 1 }):Play()
		end
		if announceLabel then
			TweenService:Create(announceLabel, info, { TextTransparency = 1 }):Play()
		end
		task.wait(FADE_TIME + 0.05)
		hideAnnounce()
		-- Reset for next time
		if announceLabel then announceLabel.TextTransparency = 0 end
		announceThread = nil
	end)
end

local function showSurvivalPopup()
	if not survivalGui then return end

	-- Only show to a player who is still alive
	local char = localPlayer.Character
	if char then
		local hum = char:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 then return end
	end

	survivalGui.Enabled = true

	local panel = survivalGui:FindFirstChild("SurvivalPanel")
	if not panel then return end

	-- Fade in from transparent
	panel.BackgroundTransparency = 1
	local lbl = panel:FindFirstChild("SurvivalText")
	if lbl then lbl.TextTransparency = 1 end

	local inInfo = TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	TweenService:Create(panel, inInfo, { BackgroundTransparency = 0.1 }):Play()
	if lbl then TweenService:Create(lbl, inInfo, { TextTransparency = 0 }):Play() end

	-- Hold then fade out
	task.delay(3.5, function()
		if not survivalGui or not survivalGui.Parent then return end
		local outInfo = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		TweenService:Create(panel, outInfo, { BackgroundTransparency = 1 }):Play()
		if lbl then TweenService:Create(lbl, outInfo, { TextTransparency = 1 }):Play() end
		task.wait(0.6)
		survivalGui.Enabled = false
	end)
end

local function onDespawn(showSurvival: boolean)
	cancelThread(countdownThread)
	cancelThread(announceThread)
	countdownThread = nil
	announceThread  = nil
	hideCountdown()
	hideAnnounce()
	if stackGui then stackGui.Enabled = false end

	if showSurvival then
		showSurvivalPopup()
	end
end

-- ─── INIT ─────────────────────────────────────────────────────────────────────

function TungTungSahurController.Init()
	buildStackGui()
	buildSurvivalGui()

	local remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
	if not remotes then
		warn("[TungTungSahurController] Remotes folder not found")
		return
	end

	local remote = remotes:WaitForChild("TungTungSahurEvent", 10)
	if not remote then
		warn("[TungTungSahurController] TungTungSahurEvent remote not found")
		return
	end

	remote.OnClientEvent:Connect(function(action: string, extraArg)
		if action == "Spawn" then
			local dur = (type(extraArg) == "number") and extraArg or 30
			runShowAnnouncement()
			startCountdown(dur)
		elseif action == "Despawn" then
			local showSurvival = extraArg == true
			onDespawn(showSurvival)
		end
	end)

	print("[TungTungSahurController] Initialized — StatusStack UI ready")
end

return TungTungSahurController
