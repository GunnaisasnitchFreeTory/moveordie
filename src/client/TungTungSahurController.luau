--[[
	TungTungSahurController
	Client-side UI for TungTungSahur hazard.

	Styled to match sword announcement exactly:
	  - IgnoreGuiInset = true (absolute screen coordinates)
	  - No box/pill backgrounds — plain text only
	  - Font GothamBold, TextSize 22, red #FF5050 + dark stroke

	Layout (absolute Y from screen top, IgnoreGuiInset=true):
	  Y=8:   TTS countdown text  (ABOVE round badge ~Y52)
	  Y=150: Sword announcement  (unchanged, this script does NOT touch it)
	  Y=195: TTS spawn text      (BELOW sword, no overlap)

	Survival text: center-screen, text-only, green — no box.

	Remote events received from TungTungSahurEvent:
	  "Spawn",   durationSeconds        -> show banner + start countdown
	  "Despawn", showSurvival:boolean   -> hide UI; if true + player alive -> popup
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")

local ANNOUNCEMENT_HOLD      = 3.0    -- seconds banner stays solid
local FADE_TIME              = 0.35
local STACK_DISPLAY_ORDER    = 85
local SURVIVAL_DISPLAY_ORDER = 90

-- Absolute Y positions (IgnoreGuiInset = true)
local TIMER_Y    = 8    -- above round badge (~Y52 absolute)
local ANNOUNCE_Y = 195  -- below sword (sword: Y150, height 40 → bottom at Y190)

-- Sword-matching text style
local TEXT_COLOR   = Color3.fromRGB(255, 80, 80)
local STROKE_COLOR = Color3.fromRGB(50, 0, 0)
local TEXT_FONT    = Enum.Font.GothamBold
local TEXT_SIZE    = 22

-- --- STATE -------------------------------------------------------------------
local localPlayer              = Players.LocalPlayer
local stackGui: ScreenGui?     = nil
local countdownLabel: TextLabel? = nil
local announceLabel: TextLabel?  = nil
local survivalGui: ScreenGui?  = nil
local survivalLabel: TextLabel?  = nil

local countdownThread: thread? = nil
local announceThread: thread?  = nil

local TungTungSahurController = {}

-- --- HELPERS -----------------------------------------------------------------

local function cancelThread(t: thread?)
	if t then pcall(task.cancel, t) end
end

local function checkDisableGui()
	if countdownLabel and countdownLabel.Visible then return end
	if announceLabel  and announceLabel.Visible  then return end
	if stackGui then stackGui.Enabled = false end
end

local function makeSwordLabel(parent: Instance, text: string, yPos: number): TextLabel
	local lbl = Instance.new("TextLabel")
	lbl.Name                   = "TTSLabel"
	lbl.Size                   = UDim2.new(1, 0, 0, 28)
	lbl.Position               = UDim2.new(0.5, 0, 0, yPos)
	lbl.AnchorPoint            = Vector2.new(0.5, 0)
	lbl.BackgroundTransparency = 1
	lbl.Font                   = TEXT_FONT
	lbl.Text                   = text
	lbl.TextColor3             = TEXT_COLOR
	lbl.TextSize               = TEXT_SIZE
	lbl.TextScaled             = false
	lbl.TextXAlignment         = Enum.TextXAlignment.Center
	lbl.TextTransparency       = 1  -- hidden until shown
	lbl.Visible                = false
	lbl.Parent                 = parent

	local stroke = Instance.new("UIStroke")
	stroke.Color          = STROKE_COLOR
	stroke.Thickness      = 2
	stroke.Transparency   = 1  -- synced with TextTransparency
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.Parent         = lbl

	return lbl
end

local function showLabel(lbl: TextLabel?)
	if not lbl then return end
	lbl.Visible = true
	lbl.TextTransparency = 0
	local s = lbl:FindFirstChildOfClass("UIStroke")
	if s then s.Transparency = 0.3 end
end

local function hideLabel(lbl: TextLabel?)
	if not lbl then return end
	lbl.Visible = false
end

local function fadeOutLabel(lbl: TextLabel?, onDone: (() -> ())?)
	if not lbl then if onDone then onDone() end return end
	local info = TweenInfo.new(FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(lbl, info, { TextTransparency = 1 }):Play()
	local s = lbl:FindFirstChildOfClass("UIStroke")
	if s then TweenService:Create(s, info, { Transparency = 1 }):Play() end
	task.delay(FADE_TIME + 0.05, function()
		lbl.Visible = false
		if onDone then onDone() end
	end)
end

-- --- GUI BUILD ---------------------------------------------------------------

local function buildStackGui()
	local playerGui = localPlayer:WaitForChild("PlayerGui", 10)
	if not playerGui then return end

	local old = playerGui:FindFirstChild("TungTungStatusStack")
	if old then old:Destroy() end

	stackGui = Instance.new("ScreenGui")
	stackGui.Name           = "TungTungStatusStack"
	stackGui.ResetOnSpawn   = false
	stackGui.DisplayOrder   = STACK_DISPLAY_ORDER
	stackGui.IgnoreGuiInset = true   -- absolute coords, same as sword announcement
	stackGui.Enabled        = false
	stackGui.Parent         = playerGui

	countdownLabel = makeSwordLabel(stackGui, "TUNGTUNGSAHUR: 30", TIMER_Y)
	countdownLabel.Name = "CountdownText"

	announceLabel = makeSwordLabel(stackGui, "TUNGTUNGSAHUR HAS SPAWNED", ANNOUNCE_Y)
	announceLabel.Name = "AnnounceText"

	print("[TTS UI] TopCenterStack mounted -- TimerY=" .. TIMER_Y
		.. " AnnounceY=" .. ANNOUNCE_Y .. " IgnoreGuiInset=true (no boxes)")
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

	-- Text-only survival message, no background box
	survivalLabel = Instance.new("TextLabel")
	survivalLabel.Name                   = "SurvivalText"
	survivalLabel.AnchorPoint            = Vector2.new(0.5, 0.5)
	survivalLabel.Position               = UDim2.new(0.5, 0, 0.45, 0)
	survivalLabel.Size                   = UDim2.new(0.9, 0, 0, 34)
	survivalLabel.BackgroundTransparency = 1
	survivalLabel.Font                   = Enum.Font.GothamBold
	survivalLabel.Text                   = "YOU HAVE SURVIVED TUNGTUNGSAHUR!"
	survivalLabel.TextColor3             = Color3.fromRGB(80, 255, 80)
	survivalLabel.TextSize               = 22
	survivalLabel.TextScaled             = false
	survivalLabel.TextWrapped            = true
	survivalLabel.TextXAlignment         = Enum.TextXAlignment.Center
	survivalLabel.TextTransparency       = 1
	survivalLabel.Parent                 = survivalGui

	local stroke = Instance.new("UIStroke")
	stroke.Color          = Color3.fromRGB(0, 50, 0)
	stroke.Thickness      = 2
	stroke.Transparency   = 1
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.Parent         = survivalLabel
end

-- --- SHOW / HIDE -------------------------------------------------------------

local function showCountdown()
	if stackGui then stackGui.Enabled = true end
	showLabel(countdownLabel)
end

local function hideCountdown()
	hideLabel(countdownLabel)
	checkDisableGui()
end

local function showAnnounce()
	if stackGui then stackGui.Enabled = true end
	showLabel(announceLabel)
end

local function hideAnnounce()
	hideLabel(announceLabel)
	checkDisableGui()
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
	if not announceLabel then return end

	showAnnounce()

	announceThread = task.spawn(function()
		task.wait(ANNOUNCEMENT_HOLD)
		fadeOutLabel(announceLabel, function()
			hideAnnounce()
			announceThread = nil
		end)
	end)
end

local function showSurvivalPopup()
	if not survivalGui or not survivalLabel then return end

	local char = localPlayer.Character
	if char then
		local hum = char:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 then return end
	end

	survivalGui.Enabled = true
	survivalLabel.TextTransparency = 1
	local stroke = survivalLabel:FindFirstChildOfClass("UIStroke")
	if stroke then stroke.Transparency = 1 end

	local inInfo = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(survivalLabel, inInfo, { TextTransparency = 0 }):Play()
	if stroke then TweenService:Create(stroke, inInfo, { Transparency = 0.3 }):Play() end

	task.delay(3.5, function()
		if not survivalGui or not survivalGui.Parent then return end
		local outInfo = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		TweenService:Create(survivalLabel, outInfo, { TextTransparency = 1 }):Play()
		if stroke then TweenService:Create(stroke, outInfo, { Transparency = 1 }):Play() end
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

-- --- INIT --------------------------------------------------------------------

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
end

return TungTungSahurController
