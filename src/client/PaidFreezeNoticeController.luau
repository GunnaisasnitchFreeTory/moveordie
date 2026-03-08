--[[
	PaidFreezeNoticeController
	Dedicated UI path for developer-product targeted freeze notice.
	Separated from FreezeIndicatorController so gameplay freeze UI cannot interrupt it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local PaidFreezeNoticeController = {}

local screenGui: ScreenGui? = nil
local noticeLabel: TextLabel? = nil
local countdownLabel: TextLabel? = nil
local noticeStroke: UIStroke? = nil
local noticeThread: thread? = nil

local function cancelNoticeThread()
	if noticeThread then
		pcall(task.cancel, noticeThread)
		noticeThread = nil
	end
end

local function ensureGui()
	if screenGui and screenGui.Parent and noticeLabel then
		return
	end
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui", 10)
	if not playerGui then
		return
	end

	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "PaidFreezeNoticeGui"
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 81
	screenGui.IgnoreGuiInset = true
	screenGui.Enabled = false
	screenGui.Parent = playerGui

	noticeLabel = Instance.new("TextLabel")
	noticeLabel.Name = "PaidFreezeNotice"
	noticeLabel.AnchorPoint = Vector2.new(0.5, 0)
	noticeLabel.Position = UDim2.new(0.5, 0, 0.44, 0)
	noticeLabel.Size = UDim2.new(0.9, 0, 0, 42)
	noticeLabel.BackgroundTransparency = 1
	noticeLabel.Font = Enum.Font.GothamBold
	noticeLabel.Text = ""
	noticeLabel.TextSize = 30
	noticeLabel.TextColor3 = Color3.fromRGB(175, 220, 255)
	noticeLabel.TextTransparency = 1
	noticeLabel.TextScaled = false
	noticeLabel.ZIndex = 2
	noticeLabel.Parent = screenGui

	countdownLabel = Instance.new("TextLabel")
	countdownLabel.Name = "PaidFreezeCountdown"
	countdownLabel.AnchorPoint = Vector2.new(0.5, 0)
	countdownLabel.Position = UDim2.new(0.5, 0, 0.50, 0)
	countdownLabel.Size = UDim2.new(0.5, 0, 0, 32)
	countdownLabel.BackgroundTransparency = 1
	countdownLabel.Font = Enum.Font.GothamBlack
	countdownLabel.Text = ""
	countdownLabel.TextSize = 26
	countdownLabel.TextColor3 = Color3.fromRGB(235, 245, 255)
	countdownLabel.TextTransparency = 1
	countdownLabel.TextScaled = false
	countdownLabel.ZIndex = 2
	countdownLabel.Parent = screenGui

	noticeStroke = Instance.new("UIStroke")
	noticeStroke.Color = Color3.fromRGB(25, 55, 85)
	noticeStroke.Thickness = 2
	noticeStroke.Transparency = 1
	noticeStroke.Parent = noticeLabel
end

local function showNotice(freezerName: string?, durationSeconds: number?)
	if not screenGui or not noticeLabel then
		return
	end
	cancelNoticeThread()

	local freezer = tostring(freezerName or "Someone")
	local duration = math.max(0.5, tonumber(durationSeconds) or 13.6)

	noticeLabel.Text = string.format("%s has frozen you!", freezer)
	if countdownLabel then
		countdownLabel.Text = string.format("Unfreezes in %ds", math.ceil(duration))
	end
	noticeLabel.TextTransparency = 1
	if countdownLabel then
		countdownLabel.TextTransparency = 1
	end
	if noticeStroke then
		noticeStroke.Transparency = 1
	end
	screenGui.Enabled = true

	local fadeIn = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(noticeLabel, fadeIn, { TextTransparency = 0 }):Play()
	if countdownLabel then
		TweenService:Create(countdownLabel, fadeIn, { TextTransparency = 0 }):Play()
	end
	if noticeStroke then
		TweenService:Create(noticeStroke, fadeIn, { Transparency = 0.1 }):Play()
	end
	print(string.format("[PaidFreezeUI] shown freezer=%s duration=%.2fs", freezer, duration))

	noticeThread = task.spawn(function()
		local startAt = tick()
		local endAt = startAt + duration
		while tick() < endAt do
			local remaining = math.max(0, endAt - tick())
			if countdownLabel then
				countdownLabel.Text = string.format("Unfreezes in %ds", math.ceil(remaining))
			end
			task.wait(0.1)
		end
		local fadeOut = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		TweenService:Create(noticeLabel, fadeOut, { TextTransparency = 1 }):Play()
		if countdownLabel then
			TweenService:Create(countdownLabel, fadeOut, { TextTransparency = 1 }):Play()
		end
		if noticeStroke then
			TweenService:Create(noticeStroke, fadeOut, { Transparency = 1 }):Play()
		end
		task.wait(0.3)
		if screenGui then
			screenGui.Enabled = false
		end
		noticeThread = nil
		print("[PaidFreezeUI] hidden reason=duration_elapsed")
	end)
end

local function hideNotice(reason: string?)
	if not screenGui or not noticeLabel then
		return
	end
	cancelNoticeThread()
	local hideReason = tostring(reason or "server")
	local fadeOut = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	TweenService:Create(noticeLabel, fadeOut, { TextTransparency = 1 }):Play()
	if countdownLabel then
		TweenService:Create(countdownLabel, fadeOut, { TextTransparency = 1 }):Play()
	end
	if noticeStroke then
		TweenService:Create(noticeStroke, fadeOut, { Transparency = 1 }):Play()
	end
	task.spawn(function()
		task.wait(0.25)
		if screenGui then
			screenGui.Enabled = false
		end
	end)
	print(string.format("[PaidFreezeUI] hidden reason=%s", hideReason))
end

function PaidFreezeNoticeController.Init()
	ensureGui()
	local remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
	if not remotes then
		warn("[PaidFreezeUI] Remotes folder not found")
		return
	end
	local remote = remotes:WaitForChild("PaidFreezeNotice", 10)
	if not remote or not remote:IsA("RemoteEvent") then
		warn("[PaidFreezeUI] PaidFreezeNotice remote missing")
		return
	end

	remote.OnClientEvent:Connect(function(action: string, arg1: any, arg2: any)
		if action == "Show" then
			showNotice(arg1, arg2)
		elseif action == "Hide" then
			hideNotice(arg1)
		end
	end)

	print("[PaidFreezeUI] Initialized")
end

return PaidFreezeNoticeController
