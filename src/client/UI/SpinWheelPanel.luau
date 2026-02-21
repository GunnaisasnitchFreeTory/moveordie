--[[
	SpinWheelPanel (Wrapper for imported SpinWheelGuiScripts)

	Controls the imported SpinWheel UI:
	  • Opens/closes the SpinWheel frame inside SpinWheelGuiScripts
	  • Handles blur, FOV, and background effects
	  • Wires close button (creates one if none exists)
	  • Hides orphaned navigation Buttons (from disabled AnimateFrames)
	  • Toggles ScreenGui.Enabled so nothing leaks when closed

	The actual spin logic is in SpinWheelGui/SpinWheelScript (client)
	and SpinWheelService (server).

	Used by: UIController (walk-up near SpinTheWheel + Press E)
]]

local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local UserInputService = game:GetService("UserInputService")

local SpinWheelPanel = {}

local visible = false
local closeCallback = nil

local spinFrame = nil
local bgEffect = nil
local bgEffectRainbow = nil
local spinGui = nil
local buttonsFrame = nil

local function log(...)
	print("[SpinWheelPanel]", ...)
end

----------------------------------------------------------------------------
-- CLOSE BUTTON FACTORY
-- Creates a small "✕" close button in the top-right of the spin frame
-- so the player has a clear way to exit besides ESC / walking away.
----------------------------------------------------------------------------
local function createCloseButton(parent)
	local btn = Instance.new("TextButton")
	btn.Name = "SpinWheelCloseBtn"
	btn.Text = "X"
	btn.Font = Enum.Font.GothamBold
	btn.TextSize = 26
	btn.TextColor3 = Color3.fromRGB(255, 255, 255)
	btn.TextStrokeTransparency = 0.2
	btn.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	btn.BackgroundColor3 = Color3.fromRGB(200, 50, 60)
	btn.BackgroundTransparency = 0.05
	btn.Size = UDim2.fromOffset(44, 44)
	btn.Position = UDim2.new(1, -56, 0, 16)
	btn.AnchorPoint = Vector2.new(0.5, 0.5)
	btn.ZIndex = 100
	btn.AutoButtonColor = false
	btn.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = btn

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(255, 255, 255)
	stroke.Thickness = 2
	stroke.Transparency = 0.35
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = btn

	local baseColor = btn.BackgroundColor3
	local hoverColor = Color3.fromRGB(240, 70, 80)
	local pressColor = Color3.fromRGB(160, 35, 45)

	btn.MouseEnter:Connect(function()
		TweenService:Create(btn, TweenInfo.new(0.15, Enum.EasingStyle.Quad), {
			BackgroundColor3 = hoverColor,
			Size = UDim2.fromOffset(48, 48),
		}):Play()
	end)
	btn.MouseLeave:Connect(function()
		TweenService:Create(btn, TweenInfo.new(0.15, Enum.EasingStyle.Quad), {
			BackgroundColor3 = baseColor,
			Size = UDim2.fromOffset(44, 44),
		}):Play()
	end)
	btn.MouseButton1Down:Connect(function()
		TweenService:Create(btn, TweenInfo.new(0.08, Enum.EasingStyle.Quad), {
			BackgroundColor3 = pressColor,
			Size = UDim2.fromOffset(40, 40),
		}):Play()
	end)
	btn.MouseButton1Up:Connect(function()
		TweenService:Create(btn, TweenInfo.new(0.12, Enum.EasingStyle.Quad), {
			BackgroundColor3 = hoverColor,
			Size = UDim2.fromOffset(48, 48),
		}):Play()
	end)

	return btn
end

----------------------------------------------------------------------------
-- HIDE/SHOW OVERLAPPING HUD ELEMENTS (Stats, Daily, Vote)
----------------------------------------------------------------------------
local function setOverlayUIVisible(show: boolean)
	local playerGui = Players.LocalPlayer:FindFirstChild("PlayerGui")
	if not playerGui then return end

	local hudGui = playerGui:FindFirstChild("HUDGui")
	if hudGui then
		local statsBtn = hudGui:FindFirstChild("StatsBtn")
		if statsBtn then statsBtn.Visible = show end
		local dailyBtn = hudGui:FindFirstChild("DailyBtn")
		if dailyBtn then dailyBtn.Visible = show end
	end

	local modeVoteGui = playerGui:FindFirstChild("ModeVoteGui")
	if modeVoteGui then
		modeVoteGui.Enabled = show
	end
end

----------------------------------------------------------------------------
-- MOBILE: Wrap BuySpinsPanel content in a ScrollingFrame
----------------------------------------------------------------------------
local function applyMobileBuyScroll()
	if not UserInputService.TouchEnabled then return end
	local vp = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize
	if not vp or math.min(vp.X, vp.Y) >= 600 then return end
	if not spinFrame then return end

	local buyPanel = spinFrame:FindFirstChild("BuySpinsPanel", true)
	if not buyPanel then return end
	if buyPanel:FindFirstChild("MobileScroll") then return end

	local SCROLL_TOP = 96

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "MobileScroll"
	scroll.Position = UDim2.new(0, 0, 0, SCROLL_TOP)
	scroll.Size = UDim2.new(1, 0, 1, -SCROLL_TOP - 28)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 4
	scroll.ScrollBarImageColor3 = Color3.fromRGB(100, 110, 150)
	scroll.ZIndex = 21
	scroll.CanvasSize = UDim2.fromOffset(0, 0)
	scroll.Parent = buyPanel

	local toMove = {}
	for _, child in ipairs(buyPanel:GetChildren()) do
		if child:IsA("GuiObject") and child ~= scroll and child.Name ~= "ErrorLabel" then
			if child.Position.Y.Offset >= SCROLL_TOP then
				table.insert(toMove, child)
			end
		end
	end

	local maxBottom = 0
	for _, child in ipairs(toMove) do
		local newY = child.Position.Y.Offset - SCROLL_TOP
		child.Position = UDim2.new(child.Position.X.Scale, child.Position.X.Offset, 0, newY)
		child.Parent = scroll
		local bottom = newY + child.Size.Y.Offset
		if bottom > maxBottom then maxBottom = bottom end
	end

	scroll.CanvasSize = UDim2.fromOffset(0, maxBottom + 12)
	log("Mobile BuySpinsPanel scroll applied (canvas=" .. tostring(maxBottom + 12) .. ")")
end

----------------------------------------------------------------------------
-- INIT
----------------------------------------------------------------------------
function SpinWheelPanel.Init(screenGui, onClose)
	log("Initializing SpinWheelPanel (imported wheel wrapper)...")
	closeCallback = onClose

	-- Find the imported SpinWheel frame inside SpinWheelGuiScripts
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	spinGui = playerGui:WaitForChild("SpinWheelGuiScripts", 15)
	if not spinGui then
		warn("[SpinWheelPanel] SpinWheelGuiScripts not found in PlayerGui!")
		return
	end

	local handler = spinGui:WaitForChild("Handler", 10)
	if not handler then
		warn("[SpinWheelPanel] Handler not found in SpinWheelGuiScripts!")
		return
	end

	local framesFolder = handler:WaitForChild("Frames", 10)
	if not framesFolder then
		warn("[SpinWheelPanel] Frames not found in Handler!")
		return
	end

	spinFrame = framesFolder:WaitForChild("SpinWheel", 10)
	if not spinFrame then
		warn("[SpinWheelPanel] SpinWheel frame not found!")
		return
	end

	-- Get background effects
	bgEffect = handler:FindFirstChild("BackgroundEffects")
	bgEffectRainbow = handler:FindFirstChild("RainbowBackgroundEffect")

	-- ── MAKE ORPHANED BUTTONS INVISIBLE (preserve layout) ────────────
	-- The original AnimateFrames (disabled) used these for navigation.
	-- Their TextButtons have ZIndex=999999999 and Active=true, which
	-- intercepts mouse clicks on the left side of the screen.
	-- Instead of Visible=false (which removes from layout and causes
	-- UI shifting during animations), make all visual elements transparent
	-- and disable input while keeping the frames present for layout math.
	buttonsFrame = handler:FindFirstChild("Buttons", true)
	if buttonsFrame then
		-- Make the Buttons frame itself a passive layout placeholder
		buttonsFrame.BackgroundTransparency = 1
		buttonsFrame.Active = false

		for _, desc in ipairs(buttonsFrame:GetDescendants()) do
			if desc:IsA("TextButton") or desc:IsA("ImageButton") then
				desc.BackgroundTransparency = 1
				desc.Active = false
				desc.Selectable = false
				if desc:IsA("TextButton") then
					desc.TextTransparency = 1
				end
			elseif desc:IsA("ImageLabel") then
				desc.ImageTransparency = 1
				desc.BackgroundTransparency = 1
			elseif desc:IsA("TextLabel") then
				desc.TextTransparency = 1
				desc.BackgroundTransparency = 1
			elseif desc:IsA("Frame") then
				desc.BackgroundTransparency = 1
				desc.Active = false
				desc.Selectable = false
			end
			-- Make any UIStroke fully transparent
			if desc:IsA("UIStroke") then
				desc.Transparency = 1
			end
			for _, child in ipairs(desc:GetChildren()) do
				if child:IsA("UIStroke") then
					child.Transparency = 1
				end
			end
		end
		log("Made orphaned Buttons invisible (layout preserved, no click interception)")
	end

	-- Ensure spin frame starts hidden
	spinFrame.Visible = false

	-- ── DISABLE SCREENGUI WHEN NOT IN USE ──────────────────────────────
	-- Prevents any of the imported UI from rendering or intercepting input
	spinGui.Enabled = false
	log("Disabled ScreenGui (will enable on Show)")

	-- ── WIRE / CREATE CLOSE BUTTON ─────────────────────────────────────
	local foundClose = false
	for _, desc in ipairs(spinFrame:GetDescendants()) do
		if (desc:IsA("TextButton") or desc:IsA("ImageButton")) and desc.Name:match("[Cc]lose") then
			desc.MouseButton1Click:Connect(function()
				SpinWheelPanel.Hide()
			end)
			foundClose = true
			log("Wired existing close button:", desc:GetFullName())
		end
	end

	if not foundClose then
		-- No close button found → create one
		local closeBtn = createCloseButton(spinFrame)
		closeBtn.MouseButton1Click:Connect(function()
			SpinWheelPanel.Hide()
		end)
		log("Created close button (none found in imported UI)")
	end

	log("Initialized ✓ (imported wheel at: " .. spinFrame:GetFullName() .. ")")
end

----------------------------------------------------------------------------
-- SHOW
----------------------------------------------------------------------------
function SpinWheelPanel.Show()
	if visible or not spinFrame then return end
	visible = true

	-- Enable ScreenGui so it renders
	if spinGui then
		spinGui.Enabled = true
	end

	-- Make frame visible with open animation (matches imported AnimateFrames style)
	spinFrame.Visible = true
	spinFrame.Size = UDim2.new(0.8, 0, 0.8, 0)
	spinFrame.Position = UDim2.new(0.5, 0, 0.7, 0)

	spinFrame:TweenSize(UDim2.new(1, 0, 1, 0), Enum.EasingDirection.Out, Enum.EasingStyle.Quad, 0.4, true)
	spinFrame:TweenPosition(UDim2.new(0.5, 0, 0.5, 0), Enum.EasingDirection.Out, Enum.EasingStyle.Back, 0.5, true)

	-- ── Force full ancestor chain visible (fixes DailyTimerLabel hidden by parent) ──
	-- Walk up from spinFrame ensuring every GuiObject ancestor is Visible=true.
	task.defer(function()
		local current: Instance? = spinFrame
		while current do
			if current:IsA("GuiObject") then
				if not current.Visible then
					log("Force-showing hidden ancestor:", current.Name, current.ClassName)
					current.Visible = true
				end
			end
			current = current.Parent
		end

		-- Also ensure BuySpinsPanel (common timer host) is visible
		local buyPanel = spinFrame:FindFirstChild("BuySpinsPanel", true)
		if buyPanel and buyPanel:IsA("GuiObject") and not buyPanel.Visible then
			buyPanel.Visible = true
			log("Force-showed BuySpinsPanel")
		end

		-- Debug: log DailyTimerLabel state if it exists
		local timerLbl = spinFrame:FindFirstChild("DailyTimerLabel", true)
			or spinFrame:FindFirstChild("Timer", true)
		if timerLbl then
			log(string.format("Timer label found: %s Visible=%s Text='%s' AbsPos=(%.0f,%.0f) AbsSize=(%.0f,%.0f)",
				timerLbl:GetFullName(),
				tostring(timerLbl.Visible),
				tostring((timerLbl :: any).Text or "?"),
				timerLbl.AbsolutePosition.X, timerLbl.AbsolutePosition.Y,
				timerLbl.AbsoluteSize.X, timerLbl.AbsoluteSize.Y))

			-- Walk parent chain and log visibility
			local p: Instance? = timerLbl.Parent
			while p and p ~= spinGui do
				if p:IsA("GuiObject") then
					if not p.Visible then
						log("  HIDDEN ancestor:", p.Name, p.ClassName)
						p.Visible = true
						log("  -> forced Visible=true")
					end
				end
				p = p.Parent
			end
		end
	end)

	task.defer(applyMobileBuyScroll)

	-- Background effects
	if bgEffect and bgEffect:IsA("CanvasGroup") then
		bgEffect.GroupTransparency = 1
		TweenService:Create(bgEffect, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {GroupTransparency = 0.2}):Play()
	end

	-- Blur
	local blur = Lighting:FindFirstChild("Blur")
	if not blur then
		blur = Instance.new("BlurEffect")
		blur.Name = "Blur"
		blur.Size = 0
		blur.Parent = Lighting
	end
	TweenService:Create(blur, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Size = 16}):Play()

	-- FOV
	TweenService:Create(workspace.Camera, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {FieldOfView = 92}):Play()

	setOverlayUIVisible(false)
	log("Opened")
end

----------------------------------------------------------------------------
-- HIDE
----------------------------------------------------------------------------
function SpinWheelPanel.Hide()
	if not visible or not spinFrame then return end
	visible = false

	-- Hide frame immediately
	spinFrame.Visible = false

	-- Reverse background effects
	if bgEffect and bgEffect:IsA("CanvasGroup") then
		TweenService:Create(bgEffect, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {GroupTransparency = 1}):Play()
	end

	-- Reverse blur
	local blur = Lighting:FindFirstChild("Blur")
	if blur then
		TweenService:Create(blur, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Size = 0}):Play()
	end

	-- Reverse FOV
	TweenService:Create(workspace.Camera, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {FieldOfView = 70}):Play()

	-- Disable ScreenGui after a short delay (allow fade-out tweens to finish)
	task.delay(0.5, function()
		if not visible and spinGui then
			spinGui.Enabled = false
		end
	end)

	setOverlayUIVisible(true)
	log("Closed")
	if closeCallback then closeCallback() end
end

----------------------------------------------------------------------------
-- UTILITY
----------------------------------------------------------------------------
function SpinWheelPanel.IsVisible()
	return visible
end

function SpinWheelPanel.Toggle()
	if visible then SpinWheelPanel.Hide() else SpinWheelPanel.Show() end
end

return SpinWheelPanel
