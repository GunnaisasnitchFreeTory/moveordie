--[[
	FreezeIndicatorController
	Clean 2D HUD overlay: shows "FREEZE" when the local player is frozen.
	Listens for FreezeIndicator RemoteEvent from server.

	The ScreenGui starts Enabled=false so nothing is visible on join.
	Only enabled when a "Freeze" event fires, disabled after fade-out.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local FreezeIndicatorController = {}

local FADE_IN_TIME = 0.2
local HOLD_TIME = 1.0
local FADE_OUT_TIME = 0.5

local screenGui: ScreenGui = nil
local freezeLabel: TextLabel = nil
local glowLabel: TextLabel = nil
local freezeScale: UIScale = nil
local glowScale: UIScale = nil
local textStroke: UIStroke = nil
local glowStroke: UIStroke = nil
local fadeThread: thread? = nil

local function cancelPending()
	if fadeThread then
		pcall(task.cancel, fadeThread)
		fadeThread = nil
	end
end

local function createGui()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui", 10)
	if not playerGui then return end

	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "FreezeGui"
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 80
	screenGui.IgnoreGuiInset = true
	screenGui.Enabled = false
	screenGui.Parent = playerGui

	glowLabel = Instance.new("TextLabel")
	glowLabel.Name = "FreezeGlow"
	glowLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	glowLabel.Position = UDim2.new(0.5, 0, 0.36, 0)
	glowLabel.Size = UDim2.new(0.9, 0, 0, 72)
	glowLabel.BackgroundTransparency = 1
	glowLabel.Font = Enum.Font.GothamBlack
	glowLabel.Text = "FREEZE"
	glowLabel.TextSize = 58
	glowLabel.TextColor3 = Color3.fromRGB(255, 160, 30)
	glowLabel.TextTransparency = 1
	glowLabel.TextScaled = false
	glowLabel.ZIndex = 2
	glowLabel.Parent = screenGui

	glowStroke = Instance.new("UIStroke")
	glowStroke.Color = Color3.fromRGB(200, 100, 0)
	glowStroke.Thickness = 5
	glowStroke.Transparency = 1
	glowStroke.Parent = glowLabel

	glowScale = Instance.new("UIScale")
	glowScale.Scale = 1
	glowScale.Parent = glowLabel

	freezeLabel = Instance.new("TextLabel")
	freezeLabel.Name = "FreezeText"
	freezeLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	freezeLabel.Position = UDim2.new(0.5, 0, 0.36, 0)
	freezeLabel.Size = UDim2.new(0.9, 0, 0, 72)
	freezeLabel.BackgroundTransparency = 1
	freezeLabel.Font = Enum.Font.GothamBlack
	freezeLabel.Text = "FREEZE"
	freezeLabel.TextSize = 58
	freezeLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	freezeLabel.TextTransparency = 1
	freezeLabel.TextScaled = false
	freezeLabel.ZIndex = 3
	freezeLabel.Parent = screenGui

	textStroke = Instance.new("UIStroke")
	textStroke.Color = Color3.fromRGB(255, 140, 0)
	textStroke.Thickness = 2.5
	textStroke.Transparency = 1
	textStroke.Parent = freezeLabel

	freezeScale = Instance.new("UIScale")
	freezeScale.Scale = 1
	freezeScale.Parent = freezeLabel
end

local function showFreeze(freezeDuration: number?)
	if not screenGui or not freezeLabel or not glowLabel then return end
	cancelPending()

	local totalDuration = freezeDuration or 5
	local holdTime = math.clamp(totalDuration - FADE_IN_TIME - FADE_OUT_TIME - 0.2, 0.3, HOLD_TIME)

	freezeLabel.TextTransparency = 1
	glowLabel.TextTransparency = 1
	if textStroke then textStroke.Transparency = 1 end
	if glowStroke then glowStroke.Transparency = 1 end
	if freezeScale then freezeScale.Scale = 1.2 end
	if glowScale then glowScale.Scale = 1.25 end

	screenGui.Enabled = true

	local fadeIn = TweenInfo.new(FADE_IN_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	TweenService:Create(freezeLabel, fadeIn, { TextTransparency = 0 }):Play()
	TweenService:Create(glowLabel, fadeIn, { TextTransparency = 0.5 }):Play()
	if textStroke then TweenService:Create(textStroke, fadeIn, { Transparency = 0.05 }):Play() end
	if glowStroke then TweenService:Create(glowStroke, fadeIn, { Transparency = 0.35 }):Play() end
	if freezeScale then TweenService:Create(freezeScale, fadeIn, { Scale = 1 }):Play() end
	if glowScale then TweenService:Create(glowScale, fadeIn, { Scale = 1.04 }):Play() end

	fadeThread = task.spawn(function()
		task.wait(FADE_IN_TIME + holdTime)

		local fadeOut = TweenInfo.new(FADE_OUT_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		TweenService:Create(freezeLabel, fadeOut, { TextTransparency = 1 }):Play()
		TweenService:Create(glowLabel, fadeOut, { TextTransparency = 1 }):Play()
		if textStroke then TweenService:Create(textStroke, fadeOut, { Transparency = 1 }):Play() end
		if glowStroke then TweenService:Create(glowStroke, fadeOut, { Transparency = 1 }):Play() end
		if freezeScale then TweenService:Create(freezeScale, fadeOut, { Scale = 0.9 }):Play() end
		if glowScale then TweenService:Create(glowScale, fadeOut, { Scale = 0.9 }):Play() end

		task.wait(FADE_OUT_TIME + 0.05)
		if screenGui then screenGui.Enabled = false end
		fadeThread = nil
	end)
end

local function hideFreeze()
	if not screenGui or not freezeLabel or not glowLabel then return end
	cancelPending()

	local fadeOut = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	TweenService:Create(freezeLabel, fadeOut, { TextTransparency = 1 }):Play()
	TweenService:Create(glowLabel, fadeOut, { TextTransparency = 1 }):Play()
	if textStroke then TweenService:Create(textStroke, fadeOut, { Transparency = 1 }):Play() end
	if glowStroke then TweenService:Create(glowStroke, fadeOut, { Transparency = 1 }):Play() end

	fadeThread = task.spawn(function()
		task.wait(0.3)
		if screenGui then screenGui.Enabled = false end
		fadeThread = nil
	end)
end

function FreezeIndicatorController.Init()
	createGui()

	local remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
	if not remotes then
		warn("[FreezeIndicator] Remotes folder not found")
		return
	end

	local remote = remotes:WaitForChild("FreezeIndicator", 10)
	if not remote then
		warn("[FreezeIndicator] FreezeIndicator remote not found")
		return
	end

	remote.OnClientEvent:Connect(function(action: string, freezeDuration: number?)
		if action == "Freeze" then
			showFreeze(freezeDuration)
		elseif action == "Unfreeze" then
			hideFreeze()
		end
	end)

	print("[FreezeIndicator] Initialized — GUI hidden until freeze event")
end

return FreezeIndicatorController
