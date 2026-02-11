--[[
	HUDPanel
	Always-visible heads-up display:
	  * Coin counter (top-left) -- glossy capsule, gold "F" icon
	  * Round badge (top-center) -- shows "Lobby" / "Round X" / "Results"
	  * Timer label (below round badge) -- shows seconds left
	  * 2x4 sidebar grid (left) -- Shop, Crowns, Pets, Index,
	    Spectate, Settings, AFK toggle, Icon Images
	  * Intermission bar (top-center) -- single bright horizontal pill
	    REPLACES the round badge during intermission (no duplicate!)

	KEY FIX: During intermission, the round badge + state label HIDE,
	and a single horizontal bar shows "Game starting in X".
	When playing, the bar hides and round badge returns.

	FIX: SetBannerOverrideHidden hides ALL top-center banners
	(intermission bar + round badge + timer) when a panel is open.

	Used by: UIController
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
local UIConfig = require(Shared:WaitForChild("UIConfig", 10))

local Client = script.Parent
local AnimUtil   = require(Client:WaitForChild("AnimUtil"))
local SoundUtil  = require(Client:WaitForChild("SoundUtil"))
local Components = require(Client:WaitForChild("Components"))

local C = UIConfig.Colors
local S = UIConfig.Sizes
local LocalPlayer = Players.LocalPlayer

local coinLabel: TextLabel = nil
local coinScale: UIScale = nil
local roundFrame: Frame = nil
local roundLabel: TextLabel = nil
local stateLabel: TextLabel = nil

-- Intermission bar elements
local intermissionBar: Frame = nil
local intermissionLabel: TextLabel = nil
local intermissionVisible = false
local bannerOverrideHidden = false

local HUDPanel = {}

local function formatCoins(n: number): string
	if n >= 1000000 then return string.format("%.1fM", n / 1000000) end
	if n >= 10000 then return string.format("%.1fK", n / 1000) end
	return tostring(n)
end

function HUDPanel.Init(screenGui: ScreenGui, callbacks: {
	onShop: () -> (),
	onCrowns: () -> (),
	onPets: () -> (),
	onIndex: () -> (),
	onSpectate: () -> (),
	onSettings: () -> (),
	onAFK: () -> (),
	onIcons: () -> (),
})
	-- COIN COUNTER (glossy capsule)
	local coinFrame = Instance.new("Frame")
	coinFrame.Name = "CoinFrame"
	coinFrame.AnchorPoint = Vector2.new(0, 0)
	coinFrame.Position = UDim2.fromOffset(16, 16)
	coinFrame.Size = UDim2.fromOffset(S.HudCoinW, S.HudCoinH)
	coinFrame.BackgroundColor3 = C.HudCoinBg
	coinFrame.BackgroundTransparency = 0
	coinFrame.BorderSizePixel = 0
	coinFrame.Parent = screenGui

	local coinCorner = Instance.new("UICorner")
	coinCorner.CornerRadius = UDim.new(0, S.HudCoinH / 2)
	coinCorner.Parent = coinFrame

	local coinStroke = Instance.new("UIStroke")
	coinStroke.Color = C.Gold
	coinStroke.Thickness = 2.5
	coinStroke.Transparency = 0.18
	coinStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	coinStroke.Parent = coinFrame

	local coinGrad = Instance.new("UIGradient")
	coinGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(58, 65, 100)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(36, 40, 70)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(22, 25, 50)),
	})
	coinGrad.Rotation = 90
	coinGrad.Parent = coinFrame

	Components.AddStudTexture(coinFrame, S.HudCoinH / 2)

	local coinShadow = Instance.new("Frame")
	coinShadow.Name = "Shadow"
	coinShadow.AnchorPoint = Vector2.new(0.5, 0.5)
	coinShadow.Position = UDim2.new(0.5, 2, 0.5, 3)
	coinShadow.Size = UDim2.new(1, 12, 1, 12)
	coinShadow.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	coinShadow.BackgroundTransparency = 0.5
	coinShadow.BorderSizePixel = 0
	coinShadow.ZIndex = 0
	coinShadow.Parent = coinFrame
	local csc = Instance.new("UICorner")
	csc.CornerRadius = UDim.new(0, S.HudCoinH / 2 + 6)
	csc.Parent = coinShadow

	coinScale = Instance.new("UIScale")
	coinScale.Parent = coinFrame

	local coinIcon = Instance.new("TextLabel")
	coinIcon.Name = "CoinIcon"
	coinIcon.Size = UDim2.fromOffset(36, 36)
	coinIcon.Position = UDim2.fromOffset(7, (S.HudCoinH - 36) / 2)
	coinIcon.BackgroundColor3 = C.Gold
	coinIcon.Font = Enum.Font.GothamBold
	coinIcon.Text = "F"
	coinIcon.TextColor3 = Color3.fromRGB(105, 70, 0)
	coinIcon.TextSize = 22
	coinIcon.BorderSizePixel = 0
	coinIcon.ZIndex = 2
	coinIcon.Parent = coinFrame
	local icCorner = Instance.new("UICorner")
	icCorner.CornerRadius = UDim.new(1, 0)
	icCorner.Parent = coinIcon
	local icStroke = Instance.new("UIStroke")
	icStroke.Color = Color3.fromRGB(190, 155, 22)
	icStroke.Thickness = 2
	icStroke.Transparency = 0.15
	icStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	icStroke.Parent = coinIcon

	coinLabel = Instance.new("TextLabel")
	coinLabel.Name = "CoinAmount"
	coinLabel.Size = UDim2.new(1, -56, 1, 0)
	coinLabel.Position = UDim2.fromOffset(52, 0)
	coinLabel.BackgroundTransparency = 1
	coinLabel.Font = Enum.Font.GothamBold
	coinLabel.TextColor3 = C.TextWhite
	coinLabel.TextSize = 24
	coinLabel.TextXAlignment = Enum.TextXAlignment.Left
	coinLabel.Text = "0"
	coinLabel.ZIndex = 2
	coinLabel.Parent = coinFrame
	local clStroke = Instance.new("UIStroke")
	clStroke.Color = Color3.fromRGB(0, 0, 0)
	clStroke.Thickness = 1.8
	clStroke.Transparency = 0.15
	clStroke.Parent = coinLabel

	-- ROUND BADGE (top-center, glossy pill)
	roundFrame = Instance.new("Frame")
	roundFrame.Name = "RoundFrame"
	roundFrame.AnchorPoint = Vector2.new(0.5, 0)
	roundFrame.Position = UDim2.new(0.5, 0, 0, 16)
	roundFrame.Size = UDim2.fromOffset(S.HudRoundW, S.HudRoundH)
	roundFrame.BackgroundColor3 = C.HudRoundBg
	roundFrame.BorderSizePixel = 0
	roundFrame.Parent = screenGui

	local rCorner = Instance.new("UICorner")
	rCorner.CornerRadius = UDim.new(0, S.HudRoundH / 2)
	rCorner.Parent = roundFrame
	local rStroke = Instance.new("UIStroke")
	rStroke.Color = Color3.fromRGB(255, 218, 115)
	rStroke.Thickness = 2.5
	rStroke.Transparency = 0.12
	rStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	rStroke.Parent = roundFrame

	local rGrad = Instance.new("UIGradient")
	rGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 208, 98)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(248, 162, 42)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(195, 108, 15)),
	})
	rGrad.Rotation = 90
	rGrad.Parent = roundFrame

	Components.AddStudTexture(roundFrame, S.HudRoundH / 2)

	local rShadow = Instance.new("Frame")
	rShadow.Name = "Shadow"
	rShadow.AnchorPoint = Vector2.new(0.5, 0.5)
	rShadow.Position = UDim2.new(0.5, 2, 0.5, 3)
	rShadow.Size = UDim2.new(1, 12, 1, 12)
	rShadow.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	rShadow.BackgroundTransparency = 0.48
	rShadow.BorderSizePixel = 0
	rShadow.ZIndex = 0
	rShadow.Parent = roundFrame
	local rsc = Instance.new("UICorner")
	rsc.CornerRadius = UDim.new(0, S.HudRoundH / 2 + 6)
	rsc.Parent = rShadow

	roundLabel = Instance.new("TextLabel")
	roundLabel.Name = "RoundText"
	roundLabel.Size = UDim2.fromScale(1, 1)
	roundLabel.BackgroundTransparency = 1
	roundLabel.Font = Enum.Font.GothamBold
	roundLabel.TextColor3 = C.TextWhite
	roundLabel.TextSize = 22
	roundLabel.Text = ""
	roundLabel.ZIndex = 2
	roundLabel.Parent = roundFrame
	local rlStroke = Instance.new("UIStroke")
	rlStroke.Color = Color3.fromRGB(0, 0, 0)
	rlStroke.Thickness = 1.8
	rlStroke.Transparency = 0.15
	rlStroke.Parent = roundLabel

	-- STATE LABEL (timer, below round badge)
	stateLabel = Instance.new("TextLabel")
	stateLabel.Name = "StateLabel"
	stateLabel.AnchorPoint = Vector2.new(0.5, 0)
	stateLabel.Position = UDim2.new(0.5, 0, 0, 16 + S.HudRoundH + 6)
	stateLabel.Size = UDim2.fromOffset(250, 24)
	stateLabel.BackgroundTransparency = 1
	stateLabel.Font = Enum.Font.GothamBold
	stateLabel.TextColor3 = C.TextLight
	stateLabel.TextSize = 18
	stateLabel.Text = ""
	stateLabel.Parent = screenGui
	local slStroke = Instance.new("UIStroke")
	slStroke.Color = Color3.fromRGB(0, 0, 0)
	slStroke.Thickness = 1.5
	slStroke.Transparency = 0.22
	slStroke.Parent = stateLabel

	-- INTERMISSION BAR (single bright horizontal pill)
	intermissionBar = Instance.new("Frame")
	intermissionBar.Name = "IntermissionBar"
	intermissionBar.AnchorPoint = Vector2.new(0.5, 0)
	intermissionBar.Position = UDim2.new(0.5, 0, 0, 16)
	intermissionBar.Size = UDim2.fromOffset(S.IntermissionW, S.IntermissionH)
	intermissionBar.BackgroundColor3 = C.IntermissionBg
	intermissionBar.BackgroundTransparency = 0
	intermissionBar.BorderSizePixel = 0
	intermissionBar.Visible = false
	intermissionBar.ZIndex = 10
	intermissionBar.Parent = screenGui

	local ibCorner = Instance.new("UICorner")
	ibCorner.CornerRadius = UDim.new(0, S.IntermissionCorner)
	ibCorner.Parent = intermissionBar

	local ibGrad = Instance.new("UIGradient")
	ibGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, C.IntermissionBg2),
		ColorSequenceKeypoint.new(0.5, C.IntermissionBg),
		ColorSequenceKeypoint.new(1, C.IntermissionStroke),
	})
	ibGrad.Rotation = 90
	ibGrad.Parent = intermissionBar

	Components.AddStudTexture(intermissionBar, S.IntermissionCorner)
	local ibStud = intermissionBar:FindFirstChild("StudTexture")
	if ibStud then
		ibStud.ImageColor3 = Color3.fromRGB(200, 225, 255)
		ibStud.ImageTransparency = 0.72
		ibStud.ZIndex = 10
	end

	local ibStroke = Instance.new("UIStroke")
	ibStroke.Color = Color3.fromRGB(255, 218, 115)
	ibStroke.Thickness = 2.5
	ibStroke.Transparency = 0.12
	ibStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	ibStroke.Parent = intermissionBar

	local ibShadow = Instance.new("Frame")
	ibShadow.Name = "Shadow"
	ibShadow.AnchorPoint = Vector2.new(0.5, 0.5)
	ibShadow.Position = UDim2.new(0.5, 2, 0.5, 3)
	ibShadow.Size = UDim2.new(1, 14, 1, 14)
	ibShadow.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	ibShadow.BackgroundTransparency = 0.48
	ibShadow.BorderSizePixel = 0
	ibShadow.ZIndex = 9
	ibShadow.Parent = intermissionBar
	local ibsc = Instance.new("UICorner")
	ibsc.CornerRadius = UDim.new(0, S.IntermissionCorner + 5)
	ibsc.Parent = ibShadow

	local ibScale = Instance.new("UIScale")
	ibScale.Parent = intermissionBar

	-- Intermission text (initial "--" until server countdown arrives)
	intermissionLabel = Instance.new("TextLabel")
	intermissionLabel.Name = "IntermissionText"
	intermissionLabel.Size = UDim2.fromScale(1, 1)
	intermissionLabel.BackgroundTransparency = 1
	intermissionLabel.Font = Enum.Font.GothamBold
	intermissionLabel.TextColor3 = C.IntermissionText
	intermissionLabel.TextSize = 24
	intermissionLabel.Text = "--"
	intermissionLabel.ZIndex = 11
	intermissionLabel.Parent = intermissionBar
	local ibls = Instance.new("UIStroke")
	ibls.Color = Color3.fromRGB(0, 0, 0)
	ibls.Thickness = 1.8
	ibls.Transparency = 0.2
	ibls.Parent = intermissionLabel

	-- 2x4 SIDEBAR GRID (glossy, vibrant)
	local SIDEBAR_ROWS = 4
	local sidebarBg = Instance.new("Frame")
	sidebarBg.Name = "SidebarBg"
	sidebarBg.AnchorPoint = Vector2.new(0, 0)
	sidebarBg.Position = UDim2.fromOffset(10, 72)
	sidebarBg.Size = UDim2.fromOffset(
		S.SideBtnW * 2 + S.SideBtnGap + 16,
		S.SideBtnH * SIDEBAR_ROWS + S.SideBtnGap * (SIDEBAR_ROWS - 1) + 16
	)
	sidebarBg.BackgroundColor3 = C.SidebarBg
	sidebarBg.BackgroundTransparency = C.SidebarBgAlpha
	sidebarBg.BorderSizePixel = 0
	sidebarBg.ZIndex = 0
	sidebarBg.Parent = screenGui
	local sbgCorner = Instance.new("UICorner")
	sbgCorner.CornerRadius = UDim.new(0, 18)
	sbgCorner.Parent = sidebarBg
	local sbgStroke = Instance.new("UIStroke")
	sbgStroke.Color = Color3.fromRGB(255, 255, 255)
	sbgStroke.Thickness = 2
	sbgStroke.Transparency = 0.65
	sbgStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	sbgStroke.Parent = sidebarBg

	Components.AddStudTexture(sidebarBg, 18)

	local sidebar = Instance.new("Frame")
	sidebar.Name = "Sidebar"
	sidebar.AnchorPoint = Vector2.new(0, 0)
	sidebar.Position = UDim2.fromOffset(18, 80)
	sidebar.Size = UDim2.fromOffset(
		S.SideBtnW * 2 + S.SideBtnGap,
		S.SideBtnH * SIDEBAR_ROWS + S.SideBtnGap * (SIDEBAR_ROWS - 1)
	)
	sidebar.BackgroundTransparency = 1
	sidebar.BorderSizePixel = 0
	sidebar.Parent = screenGui

	local sGrid = Instance.new("UIGridLayout")
	sGrid.CellSize = UDim2.fromOffset(S.SideBtnW, S.SideBtnH)
	sGrid.CellPadding = UDim2.fromOffset(S.SideBtnGap, S.SideBtnGap)
	sGrid.FillDirection = Enum.FillDirection.Horizontal
	sGrid.SortOrder = Enum.SortOrder.LayoutOrder
	sGrid.Parent = sidebar

	Components.CreateSideButton(sidebar, "Shop",     "\xF0\x9F\x92\x8E", C.SideShop,     1, function() if callbacks.onShop then callbacks.onShop() end end)
	Components.CreateSideButton(sidebar, "Crowns",   "\xF0\x9F\x91\x91", C.SideCrowns,   2, function() if callbacks.onCrowns then callbacks.onCrowns() end end)
	Components.CreateSideButton(sidebar, "Pets",     "\xF0\x9F\x90\xBE", C.SidePets,     3, function() if callbacks.onPets then callbacks.onPets() end end)
	Components.CreateSideButton(sidebar, "Index",    "\xF0\x9F\x93\x96", C.SideIndex,    4, function() if callbacks.onIndex then callbacks.onIndex() end end)
	Components.CreateSideButton(sidebar, "Spectate", "\xF0\x9F\x91\x81", C.SideSpectate, 5, function() if callbacks.onSpectate then callbacks.onSpectate() end end)
	Components.CreateSideButton(sidebar, "Settings", "\xE2\x9A\x99",  C.SideSettings, 6, function() if callbacks.onSettings then callbacks.onSettings() end end)

	local afkBtn = Components.CreateSideButton(sidebar, "Go AFK", "\xF0\x9F\x92\xA4", C.SideAFK, 7, function()
		if callbacks.onAFK then callbacks.onAFK() end
	end)

	local afkLabel = afkBtn:FindFirstChild("Label")
	local afkIcon = afkBtn:FindFirstChild("Icon")
	local isAFK = false

	local function setSideButtonColor(btn: GuiObject, baseColor: Color3)
		btn.BackgroundColor3 = baseColor
		local grad = btn:FindFirstChildOfClass("UIGradient")
		if grad then
			local r, g, b = baseColor.R, baseColor.G, baseColor.B
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
			grad.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, lighterColor),
				ColorSequenceKeypoint.new(0.5, baseColor),
				ColorSequenceKeypoint.new(1, darkerColor),
			})
		end
	end

	local function updateAFKVisual()
		local state = LocalPlayer:GetAttribute("PlayerState")
		isAFK = (state == "AFK")
		if afkLabel then
			afkLabel.Text = isAFK and "Return" or "Go AFK"
		end
		if afkIcon then
			afkIcon.Text = isAFK and "\xF0\x9F\x8F\x83" or "\xF0\x9F\x92\xA4"
		end
		setSideButtonColor(afkBtn, isAFK and C.Green or C.SideAFK)
	end
	updateAFKVisual()
	LocalPlayer:GetAttributeChangedSignal("PlayerState"):Connect(updateAFKVisual)

	Components.CreateSideButton(sidebar, "Icons", "\xF0\x9F\x96\xBC", C.SideIcons, 8, function() if callbacks.onIcons then callbacks.onIcons() end end)

	-- INTERMISSION SHOW/HIDE HELPERS
	local function showIntermission()
		if intermissionVisible then return end
		intermissionVisible = true

		roundFrame.Visible = false
		stateLabel.Visible = false

		if not bannerOverrideHidden then
			intermissionBar.Visible = true
			ibScale.Scale = 0.88
			local t = TweenService:Create(ibScale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
			t:Play()
		end
	end

	local function hideIntermission()
		if not intermissionVisible then return end
		intermissionVisible = false

		local t = TweenService:Create(ibScale, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Scale = 0.88 })
		t:Play()
		task.spawn(function()
			t.Completed:Wait()
			if not intermissionVisible then
				intermissionBar.Visible = false
			end
		end)

		if not bannerOverrideHidden then
			roundFrame.Visible = true
			stateLabel.Visible = true
		end
	end

	-- REACTIVITY
	local function updateCoins()
		local coins = LocalPlayer:GetAttribute("Coins") or 0
		local newText = formatCoins(coins)
		if coinLabel.Text ~= newText then
			coinLabel.Text = newText
			AnimUtil.Bump(coinScale)
			SoundUtil.CoinCollect()
		end
	end

	coinLabel.Text = formatCoins(LocalPlayer:GetAttribute("Coins") or 0)
	LocalPlayer:GetAttributeChangedSignal("Coins"):Connect(updateCoins)

	-- MatchStatus is created by MatchManager.Init on server
	local matchStatus = ReplicatedStorage:WaitForChild("MatchStatus", 15)
	if matchStatus then
		local stateVal = matchStatus:FindFirstChild("State")
		local roundVal = matchStatus:FindFirstChild("Round")
		local phaseEndVal = matchStatus:FindFirstChild("PhaseEndTime")

		if stateVal then
			local function onStateChange()
				local st = stateVal.Value
				if st == "Playing" then
					local r = roundVal and roundVal.Value or 0
					roundLabel.Text = r > 0 and ("Round " .. tostring(r)) or "Match"
					stateLabel.Text = ""
					if not bannerOverrideHidden then
						roundFrame.Visible = true
						stateLabel.Visible = true
					end
					hideIntermission()
				elseif st == "Intermission" then
					showIntermission()
				elseif st == "Ending" then
					roundLabel.Text = "Results"
					stateLabel.Text = "Match ended!"
					if not bannerOverrideHidden then
						roundFrame.Visible = true
						stateLabel.Visible = true
					end
					hideIntermission()
				else
					roundLabel.Text = "Lobby"
					stateLabel.Text = ""
					if not bannerOverrideHidden then
						roundFrame.Visible = true
						stateLabel.Visible = true
					end
					hideIntermission()
				end
			end
			stateVal.Changed:Connect(onStateChange)
			onStateChange()
		end

		if roundVal then
			roundVal.Changed:Connect(function()
				local r = roundVal.Value
				if r > 0 then
					roundLabel.Text = "Round " .. tostring(r)
					AnimUtil.SlideIn(roundFrame, roundFrame.Position, -20)
				end
			end)
		end

		if phaseEndVal then
			RunService.Heartbeat:Connect(function()
				local endTime = phaseEndVal.Value
				if endTime > 0 then
					local remaining = math.max(0, endTime - workspace:GetServerTimeNow())
					if remaining > 0.5 then
						local secs = math.ceil(remaining)
						if intermissionVisible and intermissionLabel then
							intermissionLabel.Text = "Game starting in " .. tostring(secs)
						end
						if not intermissionVisible then
							stateLabel.Text = string.format("%.0fs", secs)
						end
					end
				end
			end)
		end
	end
end

-- BANNER OVERRIDE (for panels -- SpinWheel, Shop, etc.)
-- Hides ALL top-center banners when a panel is open.
-- Countdown text keeps updating in the background so when
-- the banner becomes visible again, it shows the correct time.

function HUDPanel.SetBannerOverrideHidden(hidden: boolean)
	bannerOverrideHidden = hidden
	if hidden then
		-- Hide ALL top-center banners
		if intermissionBar then intermissionBar.Visible = false end
		if roundFrame then roundFrame.Visible = false end
		if stateLabel then stateLabel.Visible = false end
	else
		-- Restore based on current match state
		if intermissionVisible then
			if intermissionBar then intermissionBar.Visible = true end
			if roundFrame then roundFrame.Visible = false end
			if stateLabel then stateLabel.Visible = false end
		else
			if intermissionBar then intermissionBar.Visible = false end
			if roundFrame then roundFrame.Visible = true end
			if stateLabel then stateLabel.Visible = true end
		end
	end
end

function HUDPanel.SetVisible(vis: boolean)
	-- HUD is always visible; no-op
end

return HUDPanel
