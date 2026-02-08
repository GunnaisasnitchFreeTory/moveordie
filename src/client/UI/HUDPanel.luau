--[[
	HUDPanel
	Always-visible heads-up display:
	  • Coin counter (top-left) — glossy capsule, gold "F" icon
	  • Round badge (top-center) — shows "Lobby" / "Round X" / "Results"
	  • Timer label (below round badge) — shows seconds left
	  • 2×4 sidebar grid (left) — Shop, Crowns, Pets, Index,
	    Spectate, Settings, AFK toggle, Icon Images
	  • Intermission bar (top-center) — single bright horizontal pill
	    REPLACES the round badge during intermission (no duplicate!)

	KEY FIX: During intermission, the round badge + state label HIDE,
	and a single horizontal bar shows "Game starting in X".
	When playing, the bar hides and round badge returns.

	Used by: UIController
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UIConfig = require(Shared:WaitForChild("UIConfig"))

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
	-- ────────── COIN COUNTER (glossy capsule) ──────────
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
	coinStroke.Thickness = 3
	coinStroke.Transparency = 0.15
	coinStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	coinStroke.Parent = coinFrame

	-- Color-based gradient (same approach as intermission bar — lighter → base → darker)
	local coinGrad = Instance.new("UIGradient")
	coinGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(62, 68, 105)),     -- lighter navy
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(38, 42, 72)),    -- base navy
		ColorSequenceKeypoint.new(1, Color3.fromRGB(22, 25, 52)),      -- slightly darker
	})
	coinGrad.Rotation = 90
	coinGrad.Parent = coinFrame

	-- Drop shadow
	local coinShadow = Instance.new("Frame")
	coinShadow.Name = "Shadow"
	coinShadow.AnchorPoint = Vector2.new(0.5, 0.5)
	coinShadow.Position = UDim2.new(0.5, 2, 0.5, 4)
	coinShadow.Size = UDim2.new(1, 14, 1, 14)
	coinShadow.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	coinShadow.BackgroundTransparency = 0.45
	coinShadow.BorderSizePixel = 0
	coinShadow.ZIndex = 0
	coinShadow.Parent = coinFrame
	local csc = Instance.new("UICorner")
	csc.CornerRadius = UDim.new(0, S.HudCoinH / 2 + 7)
	csc.Parent = coinShadow

	coinScale = Instance.new("UIScale")
	coinScale.Parent = coinFrame

	-- Gold circle with bold "F" for Fate Coins
	local coinIcon = Instance.new("TextLabel")
	coinIcon.Name = "CoinIcon"
	coinIcon.Size = UDim2.fromOffset(38, 38)
	coinIcon.Position = UDim2.fromOffset(6, (S.HudCoinH - 38) / 2)
	coinIcon.BackgroundColor3 = C.Gold
	coinIcon.Font = Enum.Font.GothamBold
	coinIcon.Text = "F"
	coinIcon.TextColor3 = Color3.fromRGB(110, 72, 0)
	coinIcon.TextSize = 24
	coinIcon.BorderSizePixel = 0
	coinIcon.ZIndex = 2
	coinIcon.Parent = coinFrame
	local icCorner = Instance.new("UICorner")
	icCorner.CornerRadius = UDim.new(1, 0)
	icCorner.Parent = coinIcon
	local icStroke = Instance.new("UIStroke")
	icStroke.Color = Color3.fromRGB(195, 158, 22)
	icStroke.Thickness = 2.5
	icStroke.Transparency = 0.12
	icStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	icStroke.Parent = coinIcon

	coinLabel = Instance.new("TextLabel")
	coinLabel.Name = "CoinAmount"
	coinLabel.Size = UDim2.new(1, -56, 1, 0)
	coinLabel.Position = UDim2.fromOffset(52, 0)
	coinLabel.BackgroundTransparency = 1
	coinLabel.Font = Enum.Font.GothamBold
	coinLabel.TextColor3 = C.TextWhite
	coinLabel.TextSize = 26
	coinLabel.TextXAlignment = Enum.TextXAlignment.Left
	coinLabel.Text = "0"
	coinLabel.ZIndex = 2
	coinLabel.Parent = coinFrame
	local clStroke = Instance.new("UIStroke")
	clStroke.Color = Color3.fromRGB(0, 0, 0)
	clStroke.Thickness = 2
	clStroke.Transparency = 0.15
	clStroke.Parent = coinLabel

	-- ────────── ROUND BADGE (top-center, glossy pill) ──────────
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
	rStroke.Color = Color3.fromRGB(255, 220, 120) -- warm gold border
	rStroke.Thickness = 3.5
	rStroke.Transparency = 0.1
	rStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	rStroke.Parent = roundFrame

	-- Color-based gradient (same approach as intermission bar — lighter → base → darker)
	local rGrad = Instance.new("UIGradient")
	rGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 210, 100)),   -- lighter orange
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 165, 42)),  -- base orange
		ColorSequenceKeypoint.new(1, Color3.fromRGB(200, 110, 15)),    -- slightly darker orange
	})
	rGrad.Rotation = 90
	rGrad.Parent = roundFrame

	local rShadow = Instance.new("Frame")
	rShadow.Name = "Shadow"
	rShadow.AnchorPoint = Vector2.new(0.5, 0.5)
	rShadow.Position = UDim2.new(0.5, 2, 0.5, 4)
	rShadow.Size = UDim2.new(1, 14, 1, 14)
	rShadow.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	rShadow.BackgroundTransparency = 0.42
	rShadow.BorderSizePixel = 0
	rShadow.ZIndex = 0
	rShadow.Parent = roundFrame
	local rsc = Instance.new("UICorner")
	rsc.CornerRadius = UDim.new(0, S.HudRoundH / 2 + 7)
	rsc.Parent = rShadow

	roundLabel = Instance.new("TextLabel")
	roundLabel.Name = "RoundText"
	roundLabel.Size = UDim2.fromScale(1, 1)
	roundLabel.BackgroundTransparency = 1
	roundLabel.Font = Enum.Font.GothamBold
	roundLabel.TextColor3 = C.TextWhite
	roundLabel.TextSize = 24
	roundLabel.Text = ""
	roundLabel.ZIndex = 2
	roundLabel.Parent = roundFrame
	local rlStroke = Instance.new("UIStroke")
	rlStroke.Color = Color3.fromRGB(0, 0, 0)
	rlStroke.Thickness = 2
	rlStroke.Transparency = 0.15
	rlStroke.Parent = roundLabel

	-- ────────── STATE LABEL (timer, below round badge) ──────────
	stateLabel = Instance.new("TextLabel")
	stateLabel.Name = "StateLabel"
	stateLabel.AnchorPoint = Vector2.new(0.5, 0)
	stateLabel.Position = UDim2.new(0.5, 0, 0, 16 + S.HudRoundH + 6)
	stateLabel.Size = UDim2.fromOffset(250, 24)
	stateLabel.BackgroundTransparency = 1
	stateLabel.Font = Enum.Font.GothamBold
	stateLabel.TextColor3 = C.TextLight
	stateLabel.TextSize = 19
	stateLabel.Text = ""
	stateLabel.Parent = screenGui
	local slStroke = Instance.new("UIStroke")
	slStroke.Color = Color3.fromRGB(0, 0, 0)
	slStroke.Thickness = 1.5
	slStroke.Transparency = 0.2
	slStroke.Parent = stateLabel

	-- ────────── INTERMISSION BAR (single bright horizontal pill) ──────────
	-- This is the ONLY intermission UI. It REPLACES the round badge.
	-- During intermission: bar shows, round badge hides.
	-- During playing: bar hides, round badge shows.
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

	-- Bright glossy gradient (light blue → darker blue)
	local ibGrad = Instance.new("UIGradient")
	ibGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, C.IntermissionBg2),
		ColorSequenceKeypoint.new(0.5, C.IntermissionBg),
		ColorSequenceKeypoint.new(1, C.IntermissionStroke),
	})
	ibGrad.Rotation = 90
	ibGrad.Parent = intermissionBar

	-- White border with subtle transparency
	local ibStroke = Instance.new("UIStroke")
	ibStroke.Color = Color3.fromRGB(255, 220, 120) -- warm gold border (matches round badge)
	ibStroke.Thickness = 3.5
	ibStroke.Transparency = 0.1
	ibStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	ibStroke.Parent = intermissionBar

	-- Drop shadow
	local ibShadow = Instance.new("Frame")
	ibShadow.Name = "Shadow"
	ibShadow.AnchorPoint = Vector2.new(0.5, 0.5)
	ibShadow.Position = UDim2.new(0.5, 2, 0.5, 4)
	ibShadow.Size = UDim2.new(1, 16, 1, 16)
	ibShadow.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	ibShadow.BackgroundTransparency = 0.42
	ibShadow.BorderSizePixel = 0
	ibShadow.ZIndex = 9
	ibShadow.Parent = intermissionBar
	local ibsc = Instance.new("UICorner")
	ibsc.CornerRadius = UDim.new(0, S.IntermissionCorner + 6)
	ibsc.Parent = ibShadow

	local ibScale = Instance.new("UIScale")
	ibScale.Parent = intermissionBar

	-- Single line: "Game starting in X" — all in one label
	intermissionLabel = Instance.new("TextLabel")
	intermissionLabel.Name = "IntermissionText"
	intermissionLabel.Size = UDim2.fromScale(1, 1)
	intermissionLabel.BackgroundTransparency = 1
	intermissionLabel.Font = Enum.Font.GothamBold
	intermissionLabel.TextColor3 = C.IntermissionText
	intermissionLabel.TextSize = 26
	intermissionLabel.Text = "Game starting in 10"
	intermissionLabel.ZIndex = 11
	intermissionLabel.Parent = intermissionBar
	local ibls = Instance.new("UIStroke")
	ibls.Color = Color3.fromRGB(0, 0, 0)
	ibls.Thickness = 2
	ibls.Transparency = 0.2
	ibls.Parent = intermissionLabel

	-- ────────── 2×4 SIDEBAR GRID (glossy, vibrant) ──────────
	-- Subtle backdrop panel behind buttons for better visibility
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
	sbgCorner.CornerRadius = UDim.new(0, 20)
	sbgCorner.Parent = sidebarBg
	local sbgStroke = Instance.new("UIStroke")
	sbgStroke.Color = Color3.fromRGB(255, 255, 255)
	sbgStroke.Thickness = 2.5
	sbgStroke.Transparency = 0.55
	sbgStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	sbgStroke.Parent = sidebarBg

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

	-- 8 buttons in 2×4 grid
	Components.CreateSideButton(sidebar, "Shop",     "💎", C.SideShop,     1, function() if callbacks.onShop then callbacks.onShop() end end)
	Components.CreateSideButton(sidebar, "Crowns",   "👑", C.SideCrowns,   2, function() if callbacks.onCrowns then callbacks.onCrowns() end end)
	Components.CreateSideButton(sidebar, "Pets",     "🐾", C.SidePets,     3, function() if callbacks.onPets then callbacks.onPets() end end)
	Components.CreateSideButton(sidebar, "Index",    "📖", C.SideIndex,    4, function() if callbacks.onIndex then callbacks.onIndex() end end)
	Components.CreateSideButton(sidebar, "Spectate", "👁", C.SideSpectate, 5, function() if callbacks.onSpectate then callbacks.onSpectate() end end)
	Components.CreateSideButton(sidebar, "Settings", "⚙",  C.SideSettings, 6, function() if callbacks.onSettings then callbacks.onSettings() end end)

	-- AFK button (toggle — changes label when active)
	local afkBtn = Components.CreateSideButton(sidebar, "Go AFK", "💤", C.SideAFK, 7, function()
		if callbacks.onAFK then callbacks.onAFK() end
	end)

	-- Store AFK button reference for toggling label
	local afkLabel = afkBtn:FindFirstChild("Label")
	local afkIcon = afkBtn:FindFirstChild("Icon")
	local isAFK = false

	-- React to PlayerState attribute changes (set by server)
	local function updateAFKVisual()
		local state = LocalPlayer:GetAttribute("PlayerState")
		isAFK = (state == "AFK")
		if afkLabel then
			afkLabel.Text = isAFK and "Return" or "Go AFK"
		end
		if afkIcon then
			afkIcon.Text = isAFK and "🏃" or "💤"
		end
		afkBtn.BackgroundColor3 = isAFK and C.Green or C.SideAFK
	end
	updateAFKVisual()
	LocalPlayer:GetAttributeChangedSignal("PlayerState"):Connect(updateAFKVisual)

	Components.CreateSideButton(sidebar, "Icons",    "🖼", C.SideIcons,    8, function() if callbacks.onIcons then callbacks.onIcons() end end)

	-- ────────── INTERMISSION SHOW/HIDE HELPERS ──────────
	local function showIntermission()
		if intermissionVisible then return end
		intermissionVisible = true

		-- HIDE round badge + state label (replaced by intermission bar)
		roundFrame.Visible = false
		stateLabel.Visible = false

		-- SHOW intermission bar with animation
		intermissionBar.Visible = true
		ibScale.Scale = 0.85
		local t = TweenService:Create(ibScale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
		t:Play()
	end

	local function hideIntermission()
		if not intermissionVisible then return end
		intermissionVisible = false

		-- Animate out
		local t = TweenService:Create(ibScale, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Scale = 0.85 })
		t:Play()
		task.spawn(function()
			t.Completed:Wait()
			if not intermissionVisible then
				intermissionBar.Visible = false
			end
		end)

		-- SHOW round badge + state label again
		roundFrame.Visible = true
		stateLabel.Visible = true
	end

	-- ────────── REACTIVITY ──────────
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

	local matchStatus = ReplicatedStorage:WaitForChild("MatchStatus", 10)
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
					roundFrame.Visible = true
					stateLabel.Visible = true
					hideIntermission()
				elseif st == "Intermission" then
					showIntermission()
				elseif st == "Ending" then
					roundLabel.Text = "Results"
					stateLabel.Text = "Match ended!"
					roundFrame.Visible = true
					stateLabel.Visible = true
					hideIntermission()
				else
					-- Lobby / unknown state
					roundLabel.Text = "Lobby"
					stateLabel.Text = ""
					roundFrame.Visible = true
					stateLabel.Visible = true
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
						-- Update intermission bar text if visible
						if intermissionVisible and intermissionLabel then
							intermissionLabel.Text = "Game starting in " .. tostring(secs)
						end
						-- Also update state label for non-intermission phases
						if not intermissionVisible then
							stateLabel.Text = string.format("%.0fs", secs)
						end
					end
				end
			end)
		end
	end
end

function HUDPanel.SetVisible(vis: boolean)
	-- HUD is always visible; no-op
end

return HUDPanel
