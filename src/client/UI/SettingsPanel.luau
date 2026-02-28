--[[
	SettingsPanel
	Player settings — music toggle + volume slider.

	• Background Music ON/OFF toggle
	• Music volume slider (0–100)
	• Instantly affects currently playing background music
	• Same glossy/vibrant style as other panels

	Used by: UIController (sidebar "Settings" button)
]]

local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UIConfig = require(Shared:WaitForChild("UIConfig"))

local Client = script.Parent
local AnimUtil   = require(Client:WaitForChild("AnimUtil"))
local SoundUtil  = require(Client:WaitForChild("SoundUtil"))
local Components = require(Client:WaitForChild("Components"))

local C = UIConfig.Colors
local S = UIConfig.Sizes

local canvas: CanvasGroup = nil
local uiScale: UIScale = nil
local overlay: Frame = nil
local visible = false
local closeCallback: (() -> ())? = nil

-- Settings state
local musicEnabled = true
local musicVolume = 50 -- 0–100

local SettingsPanel = {}

-- ─── FIND BACKGROUND MUSIC ───

local function findBGMusic(): { Sound }
	local sounds = {}
	-- Check SoundService
	for _, child in ipairs(SoundService:GetChildren()) do
		if child:IsA("Sound") then
			table.insert(sounds, child)
		end
	end
	-- Check Workspace
	for _, child in ipairs(workspace:GetChildren()) do
		if child:IsA("Sound") then
			table.insert(sounds, child)
		end
	end
	-- Check SoundGroup named "Music" or "BGM"
	local sg = SoundService:FindFirstChild("Music") or SoundService:FindFirstChild("BGM")
	if sg then
		for _, child in ipairs(sg:GetChildren()) do
			if child:IsA("Sound") then
				table.insert(sounds, child)
			end
		end
	end
	return sounds
end

local function applyMusicSettings()
	local vol = musicEnabled and (musicVolume / 100) or 0

	-- Prefer setting SoundGroup volume (lets MusicController manage per-sound fades)
	local bgmGroup = SoundService:FindFirstChild("BGM") or SoundService:FindFirstChild("Music")
	if bgmGroup and bgmGroup:IsA("SoundGroup") then
		bgmGroup.Volume = vol
	end

	-- Also apply to any orphan sounds not managed by a group
	local sounds = findBGMusic()
	for _, sound in ipairs(sounds) do
		if not sound.SoundGroup or sound.SoundGroup == SoundService then
			sound.Volume = vol
		end
	end
end

-- ─── BUILD ───

local toggleBtn: TextButton = nil
local toggleLabel: TextLabel = nil
local volumeLabel: TextLabel = nil
local sliderFill: Frame = nil

local function updateToggleVisual()
	if not toggleBtn then return end
	if musicEnabled then
		toggleBtn.BackgroundColor3 = C.Green
		toggleLabel.Text = "ON"
	else
		toggleBtn.BackgroundColor3 = C.Red
		toggleLabel.Text = "OFF"
	end
end

local function updateVolumeVisual()
	if not volumeLabel then return end
	volumeLabel.Text = tostring(musicVolume) .. "%"
	if sliderFill then
		sliderFill.Size = UDim2.new(musicVolume / 100, 0, 1, 0)
	end
end

function SettingsPanel.Init(screenGui: ScreenGui, onClose: () -> ())
	closeCallback = onClose

	overlay = Components.CreateDimOverlay(screenGui, function()
		SettingsPanel.Hide()
	end)

	local content, closeBtn
	canvas, uiScale, content, closeBtn = Components.CreatePanel(screenGui, "SETTINGS", C.HeaderSettings, "Settings")

	-- Hide scrolling, use fixed layout
	content.ScrollBarThickness = 0
	content.ScrollingEnabled = false

	-- ─── MUSIC TOGGLE ROW ───
	local row1 = Instance.new("Frame")
	row1.Name = "MusicRow"
	row1.Size = UDim2.new(1, -40, 0, 56)
	row1.Position = UDim2.new(0, 20, 0, S.PanelHeaderHeight + 24)
	row1.BackgroundColor3 = C.CardBg
	row1.BorderSizePixel = 0
	row1.Parent = canvas

	local r1c = Instance.new("UICorner")
	r1c.CornerRadius = UDim.new(0, S.BtnCorner)
	r1c.Parent = row1

	local r1s = Instance.new("UIStroke")
	r1s.Color = C.CardStroke
	r1s.Thickness = S.PanelStroke
	r1s.Transparency = 0.35
	r1s.Parent = row1

	-- Stud texture on row
	Components.AddStudTexture(row1, S.BtnCorner)

	local r1pad = Instance.new("UIPadding")
	r1pad.PaddingLeft = UDim.new(0, 16)
	r1pad.PaddingRight = UDim.new(0, 14)
	r1pad.Parent = row1

	local musicText = Instance.new("TextLabel")
	musicText.Size = UDim2.new(0.6, 0, 1, 0)
	musicText.Position = UDim2.fromOffset(0, 0)
	musicText.BackgroundTransparency = 1
	musicText.Font = Enum.Font.GothamBold
	musicText.TextColor3 = C.TextWhite
	musicText.TextSize = 20
	musicText.Text = "Background Music"
	musicText.TextXAlignment = Enum.TextXAlignment.Left
	musicText.Parent = row1

	local mts = Instance.new("UIStroke")
	mts.Color = Color3.fromRGB(0, 0, 0)
	mts.Thickness = 1.5
	mts.Transparency = 0.22
	mts.Parent = musicText

	toggleBtn = Instance.new("TextButton")
	toggleBtn.Name = "ToggleBtn"
	toggleBtn.Size = UDim2.fromOffset(80, 36)
	toggleBtn.AnchorPoint = Vector2.new(1, 0.5)
	toggleBtn.Position = UDim2.new(1, 0, 0.5, 0)
	toggleBtn.BackgroundColor3 = C.Green
	toggleBtn.BorderSizePixel = 0
	toggleBtn.AutoButtonColor = false
	toggleBtn.Text = ""
	toggleBtn.Parent = row1

	local tbc = Instance.new("UICorner")
	tbc.CornerRadius = UDim.new(0, S.BtnCorner)
	tbc.Parent = toggleBtn

	local tbs = Instance.new("UIStroke")
	tbs.Color = Color3.fromRGB(255, 255, 255)
	tbs.Thickness = S.PanelStroke
	tbs.Transparency = 0.4
	tbs.Parent = toggleBtn

	toggleLabel = Instance.new("TextLabel")
	toggleLabel.Size = UDim2.fromScale(1, 1)
	toggleLabel.BackgroundTransparency = 1
	toggleLabel.Font = Enum.Font.GothamBold
	toggleLabel.TextColor3 = C.TextWhite
	toggleLabel.TextSize = 18
	toggleLabel.Text = "ON"
	toggleLabel.Parent = toggleBtn

	local tls = Instance.new("UIStroke")
	tls.Color = Color3.fromRGB(0, 0, 0)
	tls.Thickness = 1.5
	tls.Transparency = 0.2
	tls.Parent = toggleLabel

	AnimUtil.WireButton(toggleBtn, function()
		SoundUtil.Click()
		musicEnabled = not musicEnabled
		updateToggleVisual()
		applyMusicSettings()
	end)

	-- ─── VOLUME SLIDER ROW ───
	local row2 = Instance.new("Frame")
	row2.Name = "VolumeRow"
	row2.Size = UDim2.new(1, -40, 0, 56)
	row2.Position = UDim2.new(0, 20, 0, S.PanelHeaderHeight + 92)
	row2.BackgroundColor3 = C.CardBg
	row2.BorderSizePixel = 0
	row2.Parent = canvas

	local r2c = Instance.new("UICorner")
	r2c.CornerRadius = UDim.new(0, S.BtnCorner)
	r2c.Parent = row2

	local r2s = Instance.new("UIStroke")
	r2s.Color = C.CardStroke
	r2s.Thickness = S.PanelStroke
	r2s.Transparency = 0.35
	r2s.Parent = row2

	-- Stud texture on row
	Components.AddStudTexture(row2, S.BtnCorner)

	local r2pad = Instance.new("UIPadding")
	r2pad.PaddingLeft = UDim.new(0, 16)
	r2pad.PaddingRight = UDim.new(0, 14)
	r2pad.Parent = row2

	local volText = Instance.new("TextLabel")
	volText.Size = UDim2.new(0, 120, 1, 0)
	volText.Position = UDim2.fromOffset(0, 0)
	volText.BackgroundTransparency = 1
	volText.Font = Enum.Font.GothamBold
	volText.TextColor3 = C.TextWhite
	volText.TextSize = 20
	volText.Text = "Volume"
	volText.TextXAlignment = Enum.TextXAlignment.Left
	volText.Parent = row2

	local vts = Instance.new("UIStroke")
	vts.Color = Color3.fromRGB(0, 0, 0)
	vts.Thickness = 1.5
	vts.Transparency = 0.22
	vts.Parent = volText

	-- Volume percentage label
	volumeLabel = Instance.new("TextLabel")
	volumeLabel.Size = UDim2.fromOffset(50, 30)
	volumeLabel.AnchorPoint = Vector2.new(1, 0.5)
	volumeLabel.Position = UDim2.new(1, 0, 0.5, 0)
	volumeLabel.BackgroundTransparency = 1
	volumeLabel.Font = Enum.Font.GothamBold
	volumeLabel.TextColor3 = C.Gold
	volumeLabel.TextSize = 18
	volumeLabel.Text = "50%"
	volumeLabel.Parent = row2

	local vls = Instance.new("UIStroke")
	vls.Color = Color3.fromRGB(0, 0, 0)
	vls.Thickness = 1.5
	vls.Transparency = 0.22
	vls.Parent = volumeLabel

	-- Slider track
	local sliderTrack = Instance.new("TextButton")
	sliderTrack.Name = "SliderTrack"
	sliderTrack.Size = UDim2.new(1, -220, 0, 16)
	sliderTrack.AnchorPoint = Vector2.new(0, 0.5)
	sliderTrack.Position = UDim2.new(0, 134, 0.5, 0)
	sliderTrack.BackgroundColor3 = C.CardBgDark
	sliderTrack.BorderSizePixel = 0
	sliderTrack.AutoButtonColor = false
	sliderTrack.Text = ""
	sliderTrack.Parent = row2

	local stc = Instance.new("UICorner")
	stc.CornerRadius = UDim.new(0, 8)
	stc.Parent = sliderTrack

	-- Slider fill
	sliderFill = Instance.new("Frame")
	sliderFill.Name = "Fill"
	sliderFill.Size = UDim2.new(0.5, 0, 1, 0)
	sliderFill.BackgroundColor3 = C.Blue
	sliderFill.BorderSizePixel = 0
	sliderFill.Parent = sliderTrack

	local sfc = Instance.new("UICorner")
	sfc.CornerRadius = UDim.new(0, 8)
	sfc.Parent = sliderFill

	-- Slider interaction
	local dragging = false

	local function updateSliderFromInput(input)
		local trackAbsPos = sliderTrack.AbsolutePosition.X
		local trackAbsSize = sliderTrack.AbsoluteSize.X
		local relX = math.clamp((input.Position.X - trackAbsPos) / trackAbsSize, 0, 1)
		musicVolume = math.floor(relX * 100 + 0.5)
		updateVolumeVisual()
		applyMusicSettings()
	end

	sliderTrack.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			updateSliderFromInput(input)
		end
	end)

	sliderTrack.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)

	game:GetService("UserInputService").InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			updateSliderFromInput(input)
		end
	end)

	-- ─── CLOSE ───
	AnimUtil.WireButton(closeBtn, function()
		SoundUtil.Close()
		SettingsPanel.Hide()
	end)

	updateToggleVisual()
	updateVolumeVisual()
end

function SettingsPanel.Show()
	if visible then return end
	visible = true
	overlay.Visible = true
	SoundUtil.Open()
	AnimUtil.OpenPanel(canvas, uiScale)
end

function SettingsPanel.Hide()
	if not visible then return end
	visible = false
	overlay.Visible = false
	local t = AnimUtil.ClosePanel(canvas, uiScale)
	task.spawn(function()
		t.Completed:Wait()
		canvas.Visible = false
	end)
	if closeCallback then closeCallback() end
end

function SettingsPanel.IsVisible(): boolean
	return visible
end

function SettingsPanel.Toggle()
	if visible then SettingsPanel.Hide() else SettingsPanel.Show() end
end

return SettingsPanel
