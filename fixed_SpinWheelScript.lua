local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")

-- ═══════════════════════════════════════════
local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
if not Shared then
	warn("[SpinWheelScript] ReplicatedStorage.Shared not found — disabled")
	return
end
local CDPModule = Shared:WaitForChild("ClientDepsProvider", 10)
if not CDPModule then
	warn("[SpinWheelScript] ClientDepsProvider not found — disabled")
	return
end
local Deps = require(CDPModule)
local ItemCatalog = Deps.ItemCatalog
local SpinWheelConfig = Deps.SpinWheelConfig

if not SpinWheelConfig then
	warn("[SpinWheelScript] SpinWheelConfig not available — spin wheel disabled")
	return
end
local player = Players.LocalPlayer
local ui = player:WaitForChild("PlayerGui"):WaitForChild("SpinWheelGuiScripts")
local spinFrame = ui.Handler.Frames.SpinWheel
local spinWheelHandler = spinFrame.Handler
local spinHandler = spinWheelHandler.SpinHandler
local wheelCursor = spinWheelHandler.WheelCursor
local wheelRedMiddle = spinWheelHandler.WheelRedMiddle
local wheelFlash = spinFrame.Flash
local confetti = spinWheelHandler.Confetti
local lights = spinHandler.Lights
local spinButton = spinFrame.SpinButton

-- ═══════════════════════════════════════════
-- STYLE SPIN BUTTON (was invisible placeholder)
-- ═══════════════════════════════════════════
do
	spinButton.BackgroundColor3 = Color3.fromRGB(50, 180, 80)
	spinButton.BackgroundTransparency = 0

	-- Remove aspect ratio constraint (forces square shape, we want wider pill)
	local aspectRatio = spinButton:FindFirstChildOfClass("UIAspectRatioConstraint")
	if aspectRatio then aspectRatio:Destroy() end

	-- Wider pill shape below wheel
	spinButton.Size = UDim2.new(0.25, 0, 0.065, 0)
	spinButton.Position = UDim2.new(0.5, 0, 0.94, 0)

	local corner = spinButton:FindFirstChildOfClass("UICorner") or Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 14)
	corner.Parent = spinButton

	local grad = Instance.new("UIGradient")
	grad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(80, 220, 110)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(50, 180, 80)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(30, 140, 60)),
	})
	grad.Rotation = 90
	grad.Parent = spinButton

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(255, 255, 255)
	stroke.Thickness = 2
	stroke.Transparency = 0.35
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = spinButton

	-- Drop shadow
	local shadow = Instance.new("Frame")
	shadow.Name = "Shadow"
	shadow.AnchorPoint = Vector2.new(0.5, 0.5)
	shadow.Position = UDim2.new(0.5, 2, 0.5, 3)
	shadow.Size = UDim2.new(1, 10, 1, 10)
	shadow.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	shadow.BackgroundTransparency = 0.55
	shadow.BorderSizePixel = 0
	shadow.ZIndex = 0
	shadow.Parent = spinButton
	local sc = Instance.new("UICorner")
	sc.CornerRadius = UDim.new(0, 18)
	sc.Parent = shadow

	-- Style the TextButton child
	local tb = spinButton.TextButton
	tb.Text = "SPIN"
	tb.Font = Enum.Font.GothamBold
	tb.TextSize = 26
	tb.TextColor3 = Color3.fromRGB(255, 255, 255)
	tb.BackgroundTransparency = 1
	tb.ZIndex = 2

	-- Clean up existing strokes, add a fresh one
	for _, child in ipairs(tb:GetChildren()) do
		if child:IsA("UIStroke") then child:Destroy() end
	end
	local tbStroke = Instance.new("UIStroke")
	tbStroke.Color = Color3.fromRGB(0, 0, 0)
	tbStroke.Thickness = 2
	tbStroke.Transparency = 0.25
	tbStroke.Parent = tb

	-- Hide the placeholder ImageLabel
	local imgLabel = tb:FindFirstChildOfClass("ImageLabel")
	if imgLabel then imgLabel.Visible = false end
end

-- ═══════════════════════════════════════════
-- SPIN BUTTON STATE MANAGEMENT
-- ═══════════════════════════════════════════
local spinBtnGrad = spinButton:FindFirstChildOfClass("UIGradient")

local function updateSpinButtonState(enabled, statusText)
	local tb = spinButton.TextButton
	if enabled then
		spinButton.BackgroundTransparency = 0
		spinButton.BackgroundColor3 = Color3.fromRGB(50, 180, 80)
		if spinBtnGrad then spinBtnGrad.Enabled = true end
		tb.Text = statusText or "SPIN"
		tb.TextColor3 = Color3.fromRGB(255, 255, 255)
	else
		spinButton.BackgroundTransparency = 0
		spinButton.BackgroundColor3 = Color3.fromRGB(80, 80, 90)
		if spinBtnGrad then spinBtnGrad.Enabled = false end
		tb.Text = statusText or "NO SPINS"
		tb.TextColor3 = Color3.fromRGB(180, 180, 190)
	end
end

local circleEffect = spinWheelHandler.CircleEffect
local circleEffectBlur = spinWheelHandler.CircleEffectBlur
local lineEffect = spinWheelHandler.LineEffect
local star = spinWheelHandler.Star

local BgEffect = ui.Handler:FindFirstChild("BackgroundEffects")
local BgEffectRainbow = ui.Handler:FindFirstChild("RainbowBackgroundEffect")

local fov = game.Workspace.Camera

-- ═══════════════════════════════════════════
-- SERVER REMOTES
-- ═══════════════════════════════════════════
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
local RequestSpinRF = Remotes and Remotes:WaitForChild("SpinWheel_RequestSpin", 10) or nil
local GetDataRF     = Remotes and Remotes:WaitForChild("SpinWheel_GetData", 10) or nil
local BuySpinsRF    = Remotes and Remotes:WaitForChild("SpinWheel_BuySpins", 10) or nil

-- ═══════════════════════════════════════════
-- STOP ANGLES (server segment index → imported wheel visual angle)
-- Matches the 8 segments in SpinWheelConfig.Segments
-- ═══════════════════════════════════════════
local stopAngles = {
	-23,   -- Segment 1: 100 Coins
	-203,  -- Segment 2: Common Pet
	22,    -- Segment 3: 200 Coins
	-68,   -- Segment 4: Rare Pet
	113,   -- Segment 5: Crown
	-113,  -- Segment 6: 500 Coins
	-158,  -- Segment 7: Epic Pet
	67,    -- Segment 8: 4000 Coins (Jackpot)
}

local isSpinning = false
local debounce = false
local spinDuration = 11
local totalSpins = 10
local idleRotationSpeed = 35
local cursorMaxAngle = -25
local cursorMinAngle = -8
local segmentSize = 45

local lastMilestone = 0
local previousRotation = 0
local rotationVelocity = 0
local idleTween = nil
local isAnimating = false

-- ═══════════════════════════════════════════
-- SET SEGMENT VISUALS FROM ITEMCATALOG (ViewportFrame for models, Image for coins)
-- ═══════════════════════════════════════════

--- Resolve a dot-separated model path in ReplicatedStorage
local function resolveModelPath(modelPath)
	if not modelPath or modelPath == "" then return nil end
	local parts = string.split(modelPath, ".")
	local current = ReplicatedStorage
	for _, part in ipairs(parts) do
		current = current:FindFirstChild(part)
		if not current then return nil end
	end
	return current
end

--- Get bounding box of a model for camera framing
local function getModelBoundsForWheel(model)
	local minB = Vector3.new(math.huge, math.huge, math.huge)
	local maxB = Vector3.new(-math.huge, -math.huge, -math.huge)
	local baseParts = {}
	if model:IsA("BasePart") then table.insert(baseParts, model) end
	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("BasePart") then table.insert(baseParts, desc) end
	end
	for _, part in ipairs(baseParts) do
		local pos = part.Position
		local half = part.Size / 2
		minB = Vector3.new(math.min(minB.X, pos.X-half.X), math.min(minB.Y, pos.Y-half.Y), math.min(minB.Z, pos.Z-half.Z))
		maxB = Vector3.new(math.max(maxB.X, pos.X+half.X), math.max(maxB.Y, pos.Y+half.Y), math.max(maxB.Z, pos.Z+half.Z))
	end
	if minB.X == math.huge then return Vector3.zero, Vector3.new(2,2,2) end
	return minB, maxB
end

--- Create a ViewportFrame inside an ImageLabel to display a 3D model
local function createWheelViewport(parentLabel, modelPath)
	local modelInst = resolveModelPath(modelPath)
	if not modelInst then return false end

	-- Clear the ImageLabel's own image
	parentLabel.Image = ""
	parentLabel.BackgroundTransparency = 1

	local vpFrame = Instance.new("ViewportFrame")
	vpFrame.Name = "SegmentVP"
	vpFrame.Size = UDim2.fromScale(1, 1)
	vpFrame.Position = UDim2.fromScale(0, 0)
	vpFrame.BackgroundTransparency = 1
	vpFrame.Ambient = Color3.fromRGB(180, 180, 200)
	vpFrame.LightColor = Color3.fromRGB(255, 255, 255)
	vpFrame.LightDirection = Vector3.new(-1, -1, -1)
	vpFrame.Parent = parentLabel

	local clone = modelInst:Clone()
	-- Reset position to origin
	if clone:IsA("Model") and clone.PrimaryPart then
		clone:PivotTo(CFrame.new())
	elseif clone:IsA("BasePart") then
		clone.Position = Vector3.zero
	elseif clone:IsA("Model") then
		local fp = clone:FindFirstChildWhichIsA("BasePart", true)
		if fp then
			local offset = fp.Position
			for _, desc in ipairs(clone:GetDescendants()) do
				if desc:IsA("BasePart") then desc.Position = desc.Position - offset end
			end
		end
	end
	clone.Parent = vpFrame

	-- Setup camera
	local minB, maxB = getModelBoundsForWheel(clone)
	local center = (minB + maxB) / 2
	local sz = maxB - minB
	local maxDim = math.max(sz.X, sz.Y, sz.Z, 1)
	local dist = maxDim * 2.0
	local camPos = center + Vector3.new(dist * 0.5, dist * 0.35, dist * 0.8)

	local cam = Instance.new("Camera")
	cam.CameraType = Enum.CameraType.Scriptable
	cam.CFrame = CFrame.lookAt(camPos, center)
	cam.FieldOfView = 50
	cam.Parent = vpFrame
	vpFrame.CurrentCamera = cam

	return true
end

-- Wait for ItemModels to replicate
task.spawn(function()
	ReplicatedStorage:WaitForChild("ItemModels", 8)
end)

do
	local rewardsFrame = spinHandler:FindFirstChild("Rewards")
	if rewardsFrame then
		local labels = {}
		for _, child in ipairs(rewardsFrame:GetChildren()) do
			if child:IsA("ImageLabel") then
				table.insert(labels, child)
			end
		end
		table.sort(labels, function(a, b) return a.Rotation < b.Rotation end)
		local segments = SpinWheelConfig.Segments
		for i, seg in ipairs(segments) do
			local label = labels[i]
			if not label then continue end

			if seg.modelPath then
				-- Use ViewportFrame for 3D model preview
				local created = createWheelViewport(label, seg.modelPath)
				if not created then
					-- Fallback to coin image if model not found
					label.Image = ItemCatalog.CoinImage or ""
				end
			else
				-- Coin segments: use coin image
				label.Image = ItemCatalog.CoinImage or ""
			end
		end
		print("[SpinWheel] Segment visuals updated from ItemCatalog (ViewportFrame + Images)")
	end
end

-- ═══════════════════════════════════════════
-- BUY SPINS PANEL (right side of wheel)
-- Shows: spin count, free spin timer, coin buy buttons, Robux buy buttons
-- ═══════════════════════════════════════════

-- Status state (updated from server, countdown locally)
local freeSpinReady = false
local nextFreeSpinCountdown = 0
local purchasedSpinCount = 0

-- Forward-declare labels (set inside do...end)
local buyPanelSpinsLabel: TextLabel = nil
local buyPanelTimerLabel: TextLabel = nil
local buyPanelErrorLabel: TextLabel = nil

-- Show temporary error message at bottom of panel
local function showBuyError(msg: string)
	if not buyPanelErrorLabel then return end
	buyPanelErrorLabel.Text = msg
	buyPanelErrorLabel.Visible = true
	task.delay(3, function()
		if buyPanelErrorLabel and buyPanelErrorLabel.Text == msg then
			buyPanelErrorLabel.Visible = false
		end
	end)
end

-- Refresh status from server
local statusRefreshLock = false
local function refreshSpinStatus()
	if statusRefreshLock or not GetDataRF then return end
	statusRefreshLock = true
	local ok, data = pcall(function()
		return GetDataRF:InvokeServer()
	end)
	statusRefreshLock = false
	if not ok or not data then return end

	freeSpinReady = data.freeSpinAvailable == true
	nextFreeSpinCountdown = data.nextFreeSpinTime or 0
	purchasedSpinCount = data.purchasedSpins or 0

	-- Update spins label
	local totalAvail = purchasedSpinCount + (freeSpinReady and 1 or 0)
	if buyPanelSpinsLabel then
		buyPanelSpinsLabel.Text = "🎟️ Spins: " .. tostring(totalAvail)
	end

	-- Update timer label
	if buyPanelTimerLabel then
		if freeSpinReady then
			buyPanelTimerLabel.Text = "✅ Free spin ready!"
			buyPanelTimerLabel.TextColor3 = Color3.fromRGB(80, 255, 120)
		else
			local h = math.floor(nextFreeSpinCountdown / 3600)
			local m = math.floor((nextFreeSpinCountdown % 3600) / 60)
			local s = math.floor(nextFreeSpinCountdown % 60)
			buyPanelTimerLabel.Text = string.format("⏱️ Free in: %02d:%02d:%02d", h, m, s)
			buyPanelTimerLabel.TextColor3 = Color3.fromRGB(180, 200, 255)
		end
	end

	print(string.format("[SpinWheel] Status: freeReady=%s, countdown=%ds, purchased=%d, total=%d",
		tostring(freeSpinReady), nextFreeSpinCountdown, purchasedSpinCount, totalAvail))
end

-- ── BUILD THE PANEL UI ──
do
	local panel = Instance.new("Frame")
	panel.Name = "BuySpinsPanel"
	panel.AnchorPoint = Vector2.new(0, 0.5)
	panel.Position = UDim2.new(0.73, 0, 0.47, 0)
	panel.Size = UDim2.new(0.25, 0, 0.82, 0)
	panel.BackgroundColor3 = Color3.fromRGB(18, 20, 32)
	panel.BackgroundTransparency = 0.06
	panel.BorderSizePixel = 0
	panel.ZIndex = 20
	panel.ClipsDescendants = true
	panel.Parent = spinFrame

	local panelCorner = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0, 16)
	panelCorner.Parent = panel

	local panelStroke = Instance.new("UIStroke")
	panelStroke.Color = Color3.fromRGB(80, 100, 180)
	panelStroke.Thickness = 2
	panelStroke.Transparency = 0.25
	panelStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	panelStroke.Parent = panel

	-- Subtle gradient overlay
	local panelGrad = Instance.new("UIGradient")
	panelGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(200, 200, 220)),
	})
	panelGrad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.94),
		NumberSequenceKeypoint.new(0.3, 1),
		NumberSequenceKeypoint.new(1, 0.92),
	})
	panelGrad.Rotation = 90
	panelGrad.Parent = panel

	-- ── TITLE ──
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, 0, 0, 30)
	title.Position = UDim2.fromOffset(0, 10)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.Text = "🎰 BUY SPINS"
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.TextSize = 20
	title.ZIndex = 21
	title.Parent = panel
	local titleStroke = Instance.new("UIStroke")
	titleStroke.Color = Color3.fromRGB(0, 0, 0)
	titleStroke.Thickness = 1.5
	titleStroke.Transparency = 0.2
	titleStroke.Parent = title

	-- ── SPINS COUNT ──
	local spinsLbl = Instance.new("TextLabel")
	spinsLbl.Name = "SpinsCount"
	spinsLbl.Size = UDim2.new(1, -20, 0, 22)
	spinsLbl.Position = UDim2.new(0, 10, 0, 44)
	spinsLbl.BackgroundTransparency = 1
	spinsLbl.Font = Enum.Font.GothamBold
	spinsLbl.Text = "🎟️ Spins: ..."
	spinsLbl.TextColor3 = Color3.fromRGB(255, 220, 60)
	spinsLbl.TextSize = 16
	spinsLbl.TextXAlignment = Enum.TextXAlignment.Left
	spinsLbl.ZIndex = 21
	spinsLbl.Parent = panel
	buyPanelSpinsLabel = spinsLbl

	-- ── TIMER ──
	local timerLbl = Instance.new("TextLabel")
	timerLbl.Name = "Timer"
	timerLbl.Size = UDim2.new(1, -20, 0, 18)
	timerLbl.Position = UDim2.new(0, 10, 0, 68)
	timerLbl.BackgroundTransparency = 1
	timerLbl.Font = Enum.Font.GothamSemibold
	timerLbl.Text = "Loading..."
	timerLbl.TextColor3 = Color3.fromRGB(180, 200, 255)
	timerLbl.TextSize = 13
	timerLbl.TextXAlignment = Enum.TextXAlignment.Left
	timerLbl.ZIndex = 21
	timerLbl.Parent = panel
	buyPanelTimerLabel = timerLbl

	-- ── SEPARATOR 1 ──
	local sep1 = Instance.new("Frame")
	sep1.Name = "Sep1"
	sep1.Size = UDim2.new(1, -24, 0, 1)
	sep1.Position = UDim2.new(0, 12, 0, 92)
	sep1.BackgroundColor3 = Color3.fromRGB(60, 70, 110)
	sep1.BackgroundTransparency = 0.3
	sep1.BorderSizePixel = 0
	sep1.ZIndex = 21
	sep1.Parent = panel

	-- ── ERROR LABEL (bottom of panel) ──
	local errLbl = Instance.new("TextLabel")
	errLbl.Name = "ErrorLabel"
	errLbl.Size = UDim2.new(1, -20, 0, 16)
	errLbl.Position = UDim2.new(0, 10, 1, -24)
	errLbl.BackgroundTransparency = 1
	errLbl.Font = Enum.Font.GothamBold
	errLbl.Text = ""
	errLbl.TextColor3 = Color3.fromRGB(255, 80, 80)
	errLbl.TextSize = 12
	errLbl.TextXAlignment = Enum.TextXAlignment.Center
	errLbl.ZIndex = 22
	errLbl.Visible = false
	errLbl.Parent = panel
	buyPanelErrorLabel = errLbl

	-- ── HELPER: Create a styled buy button ──
	local function makeBuyBtn(yPos: number, text: string, bgColor: Color3, onClick: () -> ()): TextButton
		local btn = Instance.new("TextButton")
		btn.Size = UDim2.new(1, -20, 0, 34)
		btn.Position = UDim2.new(0, 10, 0, yPos)
		btn.BackgroundColor3 = bgColor
		btn.Font = Enum.Font.GothamBold
		btn.TextColor3 = Color3.fromRGB(255, 255, 255)
		btn.TextSize = 13
		btn.Text = text
		btn.BorderSizePixel = 0
		btn.AutoButtonColor = false
		btn.ZIndex = 22
		btn.Parent = panel

		local bc = Instance.new("UICorner")
		bc.CornerRadius = UDim.new(0, 10)
		bc.Parent = btn

		local bs = Instance.new("UIStroke")
		bs.Color = Color3.fromRGB(255, 255, 255)
		bs.Thickness = 1.5
		bs.Transparency = 0.5
		bs.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		bs.Parent = btn

		-- Gradient (lighter top → base → darker bottom)
		local r, g, b = bgColor.R, bgColor.G, bgColor.B
		local lighter = Color3.new(math.min(r + 0.18, 1), math.min(g + 0.18, 1), math.min(b + 0.18, 1))
		local darker = Color3.new(math.max(r - 0.08, 0), math.max(g - 0.08, 0), math.max(b - 0.08, 0))
		local btnGrad = Instance.new("UIGradient")
		btnGrad.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, lighter),
			ColorSequenceKeypoint.new(0.5, bgColor),
			ColorSequenceKeypoint.new(1, darker),
		})
		btnGrad.Rotation = 90
		btnGrad.Parent = btn

		-- Text stroke for readability
		local ts = Instance.new("UIStroke")
		ts.Color = Color3.fromRGB(0, 0, 0)
		ts.Thickness = 1.2
		ts.Transparency = 0.2
		ts.Parent = btn

		-- Hover/press color feedback
		btn.MouseEnter:Connect(function()
			TweenService:Create(btn, TweenInfo.new(0.12), { BackgroundColor3 = lighter }):Play()
		end)
		btn.MouseLeave:Connect(function()
			TweenService:Create(btn, TweenInfo.new(0.12), { BackgroundColor3 = bgColor }):Play()
		end)
		btn.MouseButton1Down:Connect(function()
			TweenService:Create(btn, TweenInfo.new(0.06), { BackgroundColor3 = darker }):Play()
		end)
		btn.MouseButton1Up:Connect(function()
			TweenService:Create(btn, TweenInfo.new(0.10), { BackgroundColor3 = lighter }):Play()
		end)

		btn.MouseButton1Click:Connect(onClick)
		return btn
	end

	-- ── FATE COINS SECTION ──
	local coinsHdr = Instance.new("TextLabel")
	coinsHdr.Name = "CoinsHeader"
	coinsHdr.Size = UDim2.new(1, -20, 0, 18)
	coinsHdr.Position = UDim2.new(0, 10, 0, 100)
	coinsHdr.BackgroundTransparency = 1
	coinsHdr.Font = Enum.Font.GothamBold
	coinsHdr.Text = "💰 FATE COINS"
	coinsHdr.TextColor3 = Color3.fromRGB(255, 200, 60)
	coinsHdr.TextSize = 12
	coinsHdr.TextXAlignment = Enum.TextXAlignment.Left
	coinsHdr.ZIndex = 21
	coinsHdr.Parent = panel

	local coinBtnY = 122
	for i, pkg in ipairs(SpinWheelConfig.SpinPrices) do
		local label = pkg.label .. "  —  " .. tostring(pkg.coins) .. " 🪙"
		makeBuyBtn(coinBtnY, label, Color3.fromRGB(40, 140, 60), function()
			if not BuySpinsRF then
				showBuyError("Not connected")
				return
			end
			local ok, result = pcall(function()
				return BuySpinsRF:InvokeServer(i)
			end)
			if ok and result and result.success then
				print("[SpinWheel] Bought spins with coins: " .. pkg.label)
				task.spawn(refreshSpinStatus)
			else
				local reason = (result and result.reason) or "Purchase failed"
				showBuyError(reason)
				print("[SpinWheel] Coin buy failed:", reason)
			end
		end)
		coinBtnY = coinBtnY + 40
	end

	-- ── SEPARATOR 2 ──
	local sep2Y = coinBtnY + 4
	local sep2 = Instance.new("Frame")
	sep2.Name = "Sep2"
	sep2.Size = UDim2.new(1, -24, 0, 1)
	sep2.Position = UDim2.new(0, 12, 0, sep2Y)
	sep2.BackgroundColor3 = Color3.fromRGB(60, 70, 110)
	sep2.BackgroundTransparency = 0.3
	sep2.BorderSizePixel = 0
	sep2.ZIndex = 21
	sep2.Parent = panel

	-- ── ROBUX SECTION ──
	local robuxHdr = Instance.new("TextLabel")
	robuxHdr.Name = "RobuxHeader"
	robuxHdr.Size = UDim2.new(1, -20, 0, 18)
	robuxHdr.Position = UDim2.new(0, 10, 0, sep2Y + 8)
	robuxHdr.BackgroundTransparency = 1
	robuxHdr.Font = Enum.Font.GothamBold
	robuxHdr.Text = "💎 ROBUX"
	robuxHdr.TextColor3 = Color3.fromRGB(120, 200, 255)
	robuxHdr.TextSize = 12
	robuxHdr.TextXAlignment = Enum.TextXAlignment.Left
	robuxHdr.ZIndex = 21
	robuxHdr.Parent = panel

	local robuxBtnY = sep2Y + 30
	for i, pkg in ipairs(SpinWheelConfig.SpinPrices) do
		local label = pkg.label .. "  —  R$ " .. tostring(pkg.robux)
		makeBuyBtn(robuxBtnY, label, Color3.fromRGB(30, 100, 180), function()
			local productId = pkg.productId
			if not productId or productId == 0 then
				showBuyError("Product not configured")
				print("[SpinWheel] Robux product not set up for package:", i)
				return
			end
			local ok, err = pcall(function()
				MarketplaceService:PromptProductPurchase(player, productId)
			end)
			if not ok then
				showBuyError("Purchase error")
				warn("[SpinWheel] Robux purchase prompt error:", err)
			end
		end)
		robuxBtnY = robuxBtnY + 40
	end
end

-- Timer countdown loop (client-side, ticks every second)
task.spawn(function()
	while true do
		task.wait(1)
		if not freeSpinReady and nextFreeSpinCountdown > 0 then
			nextFreeSpinCountdown = nextFreeSpinCountdown - 1
			if nextFreeSpinCountdown <= 0 then
				freeSpinReady = true
				task.spawn(refreshSpinStatus) -- confirm with server
			elseif buyPanelTimerLabel then
				local h = math.floor(nextFreeSpinCountdown / 3600)
				local m = math.floor((nextFreeSpinCountdown % 3600) / 60)
				local s = math.floor(nextFreeSpinCountdown % 60)
				buyPanelTimerLabel.Text = string.format("⏱️ Free in: %02d:%02d:%02d", h, m, s)
			end
		end
	end
end)

-- Refresh after Robux purchase completes (via MarketplaceService callback)
MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, wasPurchased)
	if wasPurchased then
		task.wait(1.5) -- let server ProcessReceipt finish
		refreshSpinStatus()
	end
end)

-- ═══════════════════════════════════════════
-- SOUND / ANIMATION HELPERS (unchanged)
-- ═══════════════════════════════════════════

local function playSoundCloned(sound)
	if sound and sound:IsA("Sound") then
		local clone = sound:Clone()
		clone.Parent = script.Parent
		clone:Play()
		clone.Ended:Connect(function()
			clone:Destroy()
		end)
	end
end

local function normalizeAngle(angle)
	angle = angle % 360
	if angle > 180 then
		angle = angle - 360
	elseif angle < -180 then
		angle = angle + 360
	end
	return angle
end

local onId = "rbxassetid://127797176399242"
local offId = "rbxassetid://71621719249233"

local sequences = {
	oneByOne = {
		{1},{2},{3},{4},{5},{6},{7},{8}
	},
	half = {
		{1,3,5,7},{2,4,6,8}
	},
	all = {
		{1,2,3,4,5,6,7,8},{},{1,2,3,4,5,6,7,8},{}
	}
}

local lightLoopRunning = false
local lightLoopSequence = {}
local lightLoopDelay = 0.1
local lightLoopStep = 1
local lightLoopLastTime = 0

local function resetLights()
	for i = 1, 8 do
		if lights[i] then
			lights[i].Image = offId
			lights[i].Size = UDim2.new(0.08,0,0.08,0)
		end
	end
end

local function animateLight(light)
	if not light then return end
	light.Size = UDim2.new(0.08,0,0.08,0)
	light:TweenSize(UDim2.new(0.11,0,0.11,0), Enum.EasingDirection.Out, Enum.EasingStyle.Back, 0.1, true)
	task.spawn(function()
		task.wait(0.08)
		light:TweenSize(UDim2.new(0.08,0,0.08,0), Enum.EasingDirection.Out, Enum.EasingStyle.Quad, 0.3, true)
	end)
end

local function updateLights()
	resetLights()
	local step = lightLoopSequence[lightLoopStep]
	if step then
		for _, index in ipairs(step) do
			local light = lights[index]
			if light then
				light.Image = onId
				animateLight(light)
			end
		end
	end
end

function startLightLoop(sequenceName, delay)
	local sequence = sequences[sequenceName]
	if not sequence then return end
	stopLightLoop()
	lightLoopSequence = sequence
	lightLoopDelay = delay or 0.15
	lightLoopStep = 1
	lightLoopLastTime = os.clock()
	lightLoopRunning = true
	task.spawn(function()
		while lightLoopRunning do
			local now = os.clock()
			if now - lightLoopLastTime >= lightLoopDelay then
				updateLights()
				lightLoopStep = lightLoopStep + 1
				if lightLoopStep > #lightLoopSequence then
					lightLoopStep = 1
				end
				lightLoopLastTime = now
			end
			task.wait()
		end
		resetLights()
	end)
end

function stopLightLoop()
	lightLoopRunning = false
	resetLights()
end

local function flashScreen()
	local flashClone = wheelFlash:Clone()
	flashClone.Parent = wheelFlash.Parent

	local tweenInfo = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(flashClone,tweenInfo,{BackgroundTransparency=-0}):Play()

	task.spawn(function()
		task.wait(0.05)
		local tweenInfo = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		TweenService:Create(flashClone,tweenInfo,{BackgroundTransparency=1}):Play()

	end)
	
	task.spawn(function()
		task.wait(1)
		flashClone:Destroy()
	end)
end

local function bezier(t, p0, p1, p2)
	return p0*(1-t)^2 + 2*p1*(1-t)*t + p2*t^2
end

local function spawnConfetti(parent, center)
	center = center or UDim2.new(0.5, 0, 0.5, 0)
	local template = spinWheelHandler.Confetti
	local screenHeight = parent.AbsoluteSize.Y
	local screenWidth = parent.AbsoluteSize.X
	local count = 80

	local colors = {
		Color3.fromRGB(255, 0, 0),
		Color3.fromRGB(0, 255, 0),
		Color3.fromRGB(0, 0, 255),
		Color3.fromRGB(255, 255, 0),
		Color3.fromRGB(255, 0, 255),
		Color3.fromRGB(0, 255, 255),
		Color3.fromRGB(255, 128, 0),
		Color3.fromRGB(255, 255, 255)
	}

	for i = 1, count do
		local confetti = template:Clone()
		confetti.Visible = true
		confetti.AnchorPoint = Vector2.new(0.5, 0.5)
		confetti.ZIndex = -5

		local scale = math.random(40, 100) / 100
		local baseSize = template.Size
		confetti.Size = UDim2.new(
			baseSize.X.Scale * scale, 
			baseSize.X.Offset * scale, 
			baseSize.Y.Scale * scale, 
			baseSize.Y.Offset * scale
		)

		confetti.Position = center
		confetti.BackgroundColor3 = colors[math.random(1, #colors)]
		confetti.Parent = parent

		local angle = math.random() * math.pi * 2
		local velocityScale = math.min(screenWidth, screenHeight) / 1000
		local initialVelocity = math.random(1000, 1800) * velocityScale
		local velocityX = math.cos(angle) * initialVelocity
		local velocityY = math.sin(angle) * initialVelocity - math.random(800, 1200) * velocityScale

		local gravity = 2000 * velocityScale
		local airResistance = 0.98

		local rotationSpeed = math.random(300, 800)
		local rotationDir = math.random(0, 1) == 0 and 1 or -1

		local startTime = tick()
		local maxDuration = 4

		local posX = center.X.Offset
		local posY = center.Y.Offset

		RunService.Heartbeat:Connect(function(dt)
			if not confetti.Parent then return end

			local elapsed = tick() - startTime
			if elapsed >= maxDuration or posY > screenHeight + 100 then
				confetti:Destroy()
				return
			end

			velocityY = velocityY + gravity * dt
			velocityX = velocityX * airResistance

			posX = posX + velocityX * dt
			posY = posY + velocityY * dt

			confetti.Position = UDim2.new(center.X.Scale, posX, center.Y.Scale, posY)
			confetti.Rotation = confetti.Rotation + rotationSpeed * rotationDir * dt

			local fadeStart = 3
			if elapsed > fadeStart then
				local fadeT = (elapsed - fadeStart) / (maxDuration - fadeStart)
				confetti.BackgroundTransparency = fadeT
			end
		end)
	end
end

local function animateCursor()
	
	local tweenInfo = TweenInfo.new(0.1, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	TweenService:Create(wheelCursor,tweenInfo,{Rotation=-20}):Play()
	
	spinHandler:TweenSize(UDim2.new(1.022, 0, 1.022, 0), Enum.EasingDirection.Out, Enum.EasingStyle.Back, 0.15, true)
	
	task.spawn(function()
		task.wait(0.05)
		local tweenInfo = TweenInfo.new(0.8, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		TweenService:Create(wheelCursor,tweenInfo,{Rotation=0}):Play()
		
		spinHandler:TweenSize(UDim2.new(1, 0,1, 0), Enum.EasingDirection.Out, Enum.EasingStyle.Quad, 0.82, true)
	end)
end

local function animateWheelStart()
	script.Roll2.Volume = 0.5
	
	spinWheelHandler:TweenSize(UDim2.new(0.95, 0, 0.95, 0), Enum.EasingDirection.Out, Enum.EasingStyle.Back, 0.2, true)
	wheelRedMiddle:TweenSize(UDim2.new(0.23, 0, 0.23, 0), Enum.EasingDirection.Out, Enum.EasingStyle.Back, 0.2, true)

	task.spawn(function()
		task.wait(0.12)

		spinWheelHandler:TweenSize(UDim2.new(0.912, 0,0.897, 0), Enum.EasingDirection.Out, Enum.EasingStyle.Elastic, 2.3, true)
		wheelRedMiddle:TweenSize(UDim2.new(0.2, 0, 0.2, 0), Enum.EasingDirection.Out, Enum.EasingStyle.Back, 1.8, true)
	end)
	
	local middlePulse = wheelRedMiddle.Pulse:Clone()
	middlePulse.Parent = wheelRedMiddle
	
	middlePulse.Visible = true
	middlePulse:TweenSize(UDim2.new(0.85, 0, 0.85, 0), Enum.EasingDirection.Out, Enum.EasingStyle.Quad, 0.2, true)
	
	local tweenInfo = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(middlePulse,tweenInfo,{BackgroundTransparency=1}):Play()
	
	task.spawn(function()
		task.wait(3)
		middlePulse:Destroy()
	end)
end

local function createParticleExplosion()
	local particleCount = math.random(10, 18)
	local centerX = 0.5
	local centerY = 0.5
	local screenSize = star.Parent.AbsoluteSize
	local velocityScale = math.min(screenSize.X, screenSize.Y) / 1000

	for i = 1, particleCount do
		task.spawn(function()
			local spawnDelay = math.random(0, 80) / 1000
			task.wait(spawnDelay)

			local particle = star:Clone()
			particle.Parent = star.Parent
			particle.BackgroundTransparency = 1
			particle.Visible = false

			local randomSize = math.random(60, 140) / 1000
			particle.Size = UDim2.new(randomSize, 0, randomSize, 0)
			particle.Position = UDim2.new(centerX, 0, centerY, 0)

			local angleStep = (math.pi * 2) / particleCount
			local angle = angleStep * i + math.random(-20, 20) / 100
			local speed = math.random(600, 900) * velocityScale
			local velocityX = math.cos(angle) * speed
			local velocityY = math.sin(angle) * speed

			local rotationSpeed = math.random(150, 500)
			local rotationDirection = math.random(0, 1) == 0 and -1 or 1

			local fadeInDuration = 0.1
			local maxDuration = 1.5
			local fadeOutStart = 0.8

			particle.ImageTransparency = 1
			particle.Visible = true

			local startTime = tick()
			local posX = centerX * screenSize.X
			local posY = centerY * screenSize.Y

			while true do
				local elapsed = tick() - startTime
				if elapsed >= maxDuration then break end

				posX = posX + velocityX * (1/60)
				posY = posY + velocityY * (1/60)

				particle.Position = UDim2.new(0, posX, 0, posY)
				particle.Rotation = particle.Rotation + rotationSpeed * rotationDirection * (1/60)

				if elapsed <= fadeInDuration then
					particle.ImageTransparency = 1 - (elapsed / fadeInDuration) * 0.7
				elseif elapsed >= fadeOutStart then
					local fadeProgress = (elapsed - fadeOutStart) / (maxDuration - fadeOutStart)
					particle.ImageTransparency = 0.3 + fadeProgress * 0.7
				else
					particle.ImageTransparency = 0.3
				end

				local shrinkStart = 0.6
				if elapsed >= shrinkStart then
					local shrinkProgress = (elapsed - shrinkStart) / (maxDuration - shrinkStart)
					local sizeScale = 1 - (shrinkProgress * 0.7)
					particle.Size = UDim2.new(randomSize * sizeScale, 0, randomSize * sizeScale, 0)
				end

				game:GetService("RunService").RenderStepped:Wait()
			end

			particle:Destroy()
		end)
	end
end

local function createSparkles(startPos)
	local sparkleCount = math.random(2, 5)
	local screenSize = star.Parent.AbsoluteSize
	local velocityScale = math.min(screenSize.X, screenSize.Y) / 1000

	for i = 1, sparkleCount do
		task.spawn(function()
			local spawnDelay = math.random(0, 80) / 1000
			task.wait(spawnDelay)

			local particle = Instance.new("Frame")
			particle.Parent = wheelCursor
			particle.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			particle.BackgroundTransparency = math.random(30, 60) / 100
			particle.BorderSizePixel = 0
			particle.AnchorPoint = Vector2.new(0.5, 0.5)

			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(1, 0)
			corner.Parent = particle

			local randomSize = math.random(30, 100) / 1000
			particle.Size = UDim2.new(randomSize, 0, randomSize, 0)

			local spawnRadius = math.random(0, 20)
			local spawnAngle = math.random() * math.pi * 2
			local spawnOffsetX = math.cos(spawnAngle) * spawnRadius
			local spawnOffsetY = math.sin(spawnAngle) * spawnRadius

			particle.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + spawnOffsetX, startPos.Y.Scale, startPos.Y.Offset + spawnOffsetY)
			particle.Visible = false

			local speed = math.random(150, 350) * velocityScale
			local angle = math.random(0, 40)
			local velocityX = math.cos(math.rad(angle)) * speed
			local velocityY = math.sin(math.rad(angle)) * speed

			local useCurve = math.random(0, 1) == 0
			local gravity = useCurve and math.random(600, 1200) * velocityScale or math.random(150, 400) * velocityScale

			local rotationSpeed = math.random(200, 600)
			local rotationDirection = math.random(0, 1) == 0 and -1 or 1

			local maxDuration = math.random(20, 45) / 100
			local shrinkStart = maxDuration * 0.5

			particle.Visible = true

			local startTime = tick()
			local posX = startPos.X.Offset + spawnOffsetX
			local posY = startPos.Y.Offset + spawnOffsetY

			while true do
				local elapsed = tick() - startTime
				if elapsed >= maxDuration then break end

				velocityY = velocityY + gravity * (1/60)

				posX = posX + velocityX * (1/60)
				posY = posY + velocityY * (1/60)

				particle.Position = UDim2.new(startPos.X.Scale, posX, startPos.Y.Scale, posY)
				particle.Rotation = particle.Rotation + rotationSpeed * rotationDirection * (1/60)

				if elapsed >= shrinkStart then
					local shrinkProgress = (elapsed - shrinkStart) / (maxDuration - shrinkStart)
					local sizeScale = 1 - shrinkProgress
					particle.Size = UDim2.new(randomSize * sizeScale, 0, randomSize * sizeScale, 0)
				end

				game:GetService("RunService").RenderStepped:Wait()
			end

			particle:Destroy()
		end)
	end
end

local function circleEffects()
	local circle1 = circleEffect:Clone()
	circle1.Parent = circleEffect.Parent
	
	local tweenInfo = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(circle1,tweenInfo,{ImageTransparency=0.6}):Play()
	
	circle1:TweenSize(UDim2.new(3, 0, 3, 0), Enum.EasingDirection.Out, Enum.EasingStyle.Quad, 0.8, true)
	
	task.spawn(function()
		task.wait(0.3)
		local tweenInfo = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		TweenService:Create(circle1,tweenInfo,{ImageTransparency=1}):Play()
	end)
	
	local circle2 = circleEffectBlur:Clone()
	circle2.Parent = circleEffectBlur.Parent

	local tweenInfo = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(circle2,tweenInfo,{ImageTransparency=0}):Play()

	circle2:TweenSize(UDim2.new(5, 0, 5, 0), Enum.EasingDirection.Out, Enum.EasingStyle.Quad, 2, true)
	
	task.spawn(function()
		task.wait(0.3)
		local tweenInfo = TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		TweenService:Create(circle1,tweenInfo,{ImageTransparency=1}):Play()
	end)
	
	task.spawn(function()
		task.wait(10)
		circle1:Destroy()
		circle2:Destroy()
	end)
end

local function animateWheelEnd()
	flashScreen()
	spinWheelHandler:TweenSize(UDim2.new(0.96, 0, 0.96, 0), Enum.EasingDirection.Out, Enum.EasingStyle.Back, 0.2, true)
	
	stopLightLoop()

	task.spawn(function()
		task.wait(0.1)
		startLightLoop("all", 0.3)
	end)

	task.spawn(function()
		task.wait(0.12)

		spinWheelHandler:TweenSize(UDim2.new(0.912, 0,0.897, 0), Enum.EasingDirection.Out, Enum.EasingStyle.Elastic, 2.3, true)
		
		spawnConfetti(ui.Handler, UDim2.new(0.5,0,0.5,0))
		playSoundCloned(script:FindFirstChild("FollowRare"))
		playSoundCloned(script:FindFirstChild("Reward audio 2"))
		playSoundCloned(script:FindFirstChild("rng roll"))
		
		createParticleExplosion()
		
		circleEffects()
		
		script.Roll2.Volume = 0
	end)
end

script.Roll2.Volume = 0

local function trackRotation(dt)
	if dt > 0.1 then return end

	local currentRotation = (spinHandler.Rotation % 360 + 360) % 360
	local deltaRotation = currentRotation - (previousRotation % 360)

	if deltaRotation < -180 then
		deltaRotation = deltaRotation + 360
	elseif deltaRotation > 180 then
		deltaRotation = deltaRotation - 360
	end

	rotationVelocity = math.abs(deltaRotation / dt)

	local currentMilestone = math.floor(currentRotation / segmentSize)

	if currentMilestone ~= lastMilestone then
		lastMilestone = currentMilestone
		animateCursor(rotationVelocity)
		createSparkles(UDim2.new(0.481, 0,0.659, 0))
		playSoundCloned(script:FindFirstChild("Roll2"))
	end

	previousRotation = spinHandler.Rotation
end

local spinHandlerBasePos = spinHandler.Position

local TweenService = game:GetService("TweenService")
local spinHandlerBasePos = spinHandler.Position

local function shake(object, duration, strength, speed)
	object = object or spinHandler
	local basePos = object.Position
	local startTime = tick()

	while object and object.Parent do
		local elapsed = tick() - startTime
		if elapsed >= duration then break end

		local t = elapsed / duration
		local decay = 1 - (t * t)

		local offset = Vector2.new(
			(math.random() - 0.5) * strength * decay,
			(math.random() - 0.5) * strength * decay
		)

		local s = speed * (1 + t * 1.5)

		local goal = {}
		goal.Position = UDim2.new(basePos.X.Scale, basePos.X.Offset + offset.X, basePos.Y.Scale, basePos.Y.Offset + offset.Y)

		local tween = TweenService:Create(object, TweenInfo.new(s, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goal)
		tween:Play()
		tween.Completed:Wait()
	end

	if object and object.Parent then
		local goal = {}
		goal.Position = basePos
		TweenService:Create(object, TweenInfo.new(speed * 2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goal):Play()
	end
end

local function spinToTarget(targetAngle)
	isSpinning = true

	if idleTween then
		idleTween:Cancel()
		idleTween = nil
	end

	task.wait(0.05)

	local currentRotation = spinHandler.Rotation
	previousRotation = currentRotation
	lastMilestone = math.floor((currentRotation + segmentSize/2) / segmentSize)

	local normalizedCurrent = currentRotation % 360
	local normalizedTarget = normalizeAngle(targetAngle)

	local shortestPath = normalizeAngle(normalizedTarget - normalizedCurrent)
	local totalRotation = (totalSpins * 360) + shortestPath
	local finalRotation = currentRotation + totalRotation

	local tween = TweenService:Create(
		spinHandler,
		TweenInfo.new(spinDuration, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
		{Rotation = finalRotation}
	)

	tween:Play()

	task.spawn(function()
		shake(spinWheelHandler, 8, 8, 0.07) --object, duration, strength, speed
	end)
	
	stopLightLoop()

	task.spawn(function()
		task.wait(0.1)
		startLightLoop("oneByOne", 0.12)
	end)

	return tween
end

-- ═══════════════════════════════════════════
-- SPIN (server-authoritative)
-- ═══════════════════════════════════════════
local function doSpin()
	if debounce then return end
	debounce = true
	updateSpinButtonState(false, "SPINNING...")

	if not RequestSpinRF then
		warn("[SpinWheel] RequestSpin remote not available")
		updateSpinButtonState(false, "ERROR")
		task.delay(2, function()
			debounce = false
			updateSpinButtonState(true)
		end)
		return
	end

	local ok, result = pcall(function()
		return RequestSpinRF:InvokeServer()
	end)

	if not ok or not result or not result.success then
		local reason = "Unknown"
		if not ok then
			reason = tostring(result)
		elseif result and result.reason then
			reason = result.reason
		end
		print("[SpinWheel] Spin denied:", reason)
		updateSpinButtonState(false, reason or "DENIED")
		task.delay(2, function()
			debounce = false
			updateSpinButtonState(true)
		end)
		return
	end

	local segIndex = result.segmentIndex or 1
	local targetAngle = stopAngles[segIndex] or stopAngles[1]
	local variance = math.random(-8, 8)
	targetAngle = targetAngle + variance

	print("[SpinWheel] Spinning to segment", segIndex, "->", result.rewardName, "angle:", targetAngle)

	local tween = spinToTarget(targetAngle)

	task.spawn(function()
		animateWheelStart()
	end)

	task.spawn(function()
		task.wait(spinDuration - 1.8)
		animateWheelEnd()
	end)

	tween.Completed:Wait()

	-- Show reward on button briefly
	if result.rewardType == "Pet" or result.rewardType == "Crown" then
		updateSpinButtonState(false, "Won: " .. (result.rewardName or "Item") .. "!")
		print("[SpinWheel] Won:", result.rewardType, result.rewardName)
	else
		updateSpinButtonState(false, "+" .. tostring(result.coinsAwarded or 0) .. " Fate Coins!")
		print("[SpinWheel] Won:", result.rewardName, "+" .. tostring(result.coinsAwarded or 0), "Fate Coins")
	end

	task.wait(2)

	isSpinning = false
	debounce = false
	updateSpinButtonState(true)

	startIdleSpin()

	-- Refresh buy panel status after spin completes
	task.spawn(refreshSpinStatus)
end


function startIdleSpin()
	if idleTween then
		idleTween:Cancel()
	end
	
	script.Roll2.Volume = 0

	local currentRotation = spinHandler.Rotation
	previousRotation = currentRotation
	lastMilestone = math.floor((currentRotation + segmentSize/2) / segmentSize)

	local duration = 360 / idleRotationSpeed

	idleTween = TweenService:Create(
		spinHandler,
		TweenInfo.new(duration, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1),
		{Rotation = spinHandler.Rotation + 360}
	)

	idleTween:Play()
	
	stopLightLoop()
	
	task.spawn(function()
		task.wait(0.1)
		startLightLoop("half", 0.4)
	end)
end

RunService.Heartbeat:Connect(function(dt)
	trackRotation(dt)
end)

-- E key handler removed: spin is triggered by ProximityPrompt -> UIController -> SpinWheelPanel

spinButton.TextButton.MouseButton1Click:Connect(function()
	doSpin()
end)

startIdleSpin()

-- Initial status refresh (fetch free spin timer + purchased spins)
task.spawn(refreshSpinStatus)