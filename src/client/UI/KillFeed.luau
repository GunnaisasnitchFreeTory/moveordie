--[[
	KillFeed
	Right-side kill feed — shows elimination messages with slide-in + fade-out.

	* Listens for KillFeedEvent RemoteEvent (fired by server on elimination)
	* Also listens for player Humanoid.Died as a local fallback
	* Each message disappears after ~3 seconds
	* Stacks nicely (max 5 visible at once)
	* Vibrant, readable text with dark stroke

	Position: right side, vertically centered at ~45% from top.
	This avoids overlap with top-right HUD buttons (Stats, Daily, Vote).

	Used by: UIController (initialized once)
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UIConfig = require(Shared:WaitForChild("UIConfig"))

local C = UIConfig.Colors

local KillFeed = {}

local feedGui = nil
local feedContainer = nil
local MAX_MESSAGES = 5
local MESSAGE_LIFETIME = 3.0
local SLIDE_DURATION = 0.3
local FADE_DURATION = 0.5

local REASON_MAP = {
	Beam       = "a Beam",
	OOB        = "the Barrier",
	Disconnect = "Disconnecting",
}

local function getReasonText(reason)
	return REASON_MAP[reason] or reason
end

local function createFeedEntry(text, color)
	color = color or C.TextWhite

	local children = {}
	for _, child in ipairs(feedContainer:GetChildren()) do
		if child:IsA("Frame") then table.insert(children, child) end
	end
	while #children >= MAX_MESSAGES do
		local oldest = children[1]
		oldest:Destroy()
		table.remove(children, 1)
	end

	local entry = Instance.new("Frame")
	entry.Name = "FeedEntry"
	entry.Size = UDim2.new(1, 0, 0, 32)
	entry.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	entry.BackgroundTransparency = 0.45
	entry.BorderSizePixel = 0
	entry.Parent = feedContainer

	Instance.new("UICorner", entry).CornerRadius = UDim.new(0, 8)

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.Size = UDim2.new(1, -16, 1, 0)
	label.Position = UDim2.fromOffset(8, 0)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = color
	label.TextSize = 15
	label.Text = text
	label.TextXAlignment = Enum.TextXAlignment.Right
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.Parent = entry

	local ls = Instance.new("UIStroke")
	ls.Color = Color3.fromRGB(0, 0, 0)
	ls.Thickness = 1.5
	ls.Transparency = 0.15
	ls.Parent = label

	local startPos = entry.Position
	entry.Position = UDim2.new(0, 40, startPos.Y.Scale, startPos.Y.Offset)
	entry.BackgroundTransparency = 1
	label.TextTransparency = 1

	TweenService:Create(entry, TweenInfo.new(SLIDE_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Position = startPos,
		BackgroundTransparency = 0.45,
	}):Play()
	TweenService:Create(label, TweenInfo.new(SLIDE_DURATION, Enum.EasingStyle.Quad), {
		TextTransparency = 0,
	}):Play()

	task.delay(MESSAGE_LIFETIME, function()
		if not entry or not entry.Parent then return end
		TweenService:Create(entry, TweenInfo.new(FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			BackgroundTransparency = 1,
		}):Play()
		TweenService:Create(label, TweenInfo.new(FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			TextTransparency = 1,
		}):Play()
		task.delay(FADE_DURATION + 0.1, function()
			if entry and entry.Parent then
				entry:Destroy()
			end
		end)
	end)
end

function KillFeed.Init(screenGui)
	feedGui = screenGui

	feedContainer = Instance.new("Frame")
	feedContainer.Name = "KillFeedContainer"
	feedContainer.AnchorPoint = Vector2.new(1, 0.5)
	feedContainer.Position = UDim2.new(1, -16, 0.45, 0)
	feedContainer.Size = UDim2.new(0, 320, 0, (32 + 6) * MAX_MESSAGES)
	feedContainer.BackgroundTransparency = 1
	feedContainer.BorderSizePixel = 0
	feedContainer.Parent = screenGui

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.VerticalAlignment = Enum.VerticalAlignment.Top
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	layout.Parent = feedContainer

	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
		if not remotes then return end
		local killFeedEvent = remotes:WaitForChild("KillFeedEvent", 10)
		if killFeedEvent then
			killFeedEvent.OnClientEvent:Connect(function(playerName, reason)
				local reasonText = getReasonText(reason)
				local text = playerName .. " was eliminated by " .. reasonText
				local color = C.TextWhite
				if reason == "Beam" then
					color = C.Orange
				elseif reason == "OOB" then
					color = C.Red
				end
				createFeedEntry(text, color)
			end)
		end
	end)
end

function KillFeed.Push(text, color)
	createFeedEntry(text, color)
end

return KillFeed
