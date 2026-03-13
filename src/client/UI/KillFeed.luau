--[[
	KillFeed
	Right-side kill feed — shows elimination messages with slide-in + fade-out.

	* Listens for KillFeedEvent RemoteEvent (fired by server on elimination)
	* Also listens for player Humanoid.Died as a local fallback
	* Each message disappears after ~3 seconds
	* Stacks nicely (max 5 visible at once)
	* Vibrant, readable text with dark stroke

	Position: top-right, anchored below the HUD's right-side safe area.
	This keeps the feed clear of the top-right button stack.

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
local safeAreaFrame: GuiObject? = nil
local MAX_MESSAGES = 5
local MESSAGE_LIFETIME = 2.6
local SLIDE_DURATION = 0.25
local FADE_DURATION = 0.4
local FEED_WIDTH = 320
local FEED_ENTRY_HEIGHT = 32
local FEED_ENTRY_GAP = 6
local FEED_RIGHT_MARGIN = 16
local FEED_FALLBACK_TOP_OFFSET = 240
local RIGHT_SAFE_AREA_NAME = "HUDRightSafeArea"

local REASON_MAP = {
	Beam           = "a Beam",
	OOB            = "the Barrier",
	Disconnect     = "Disconnecting",
	TungTungSahur  = "TungTungSahur",
}

-- Color override per reason key (nil = default white)
local REASON_COLOR = {
	Beam          = Color3.fromRGB(255, 165, 0),  -- orange
	OOB           = Color3.fromRGB(220, 50, 50),  -- red
	TungTungSahur = Color3.fromRGB(255, 60, 180), -- hot pink
}

local function getReasonText(reason)
	return REASON_MAP[reason] or reason
end

local function normalizeReasonKey(rawReason: any): string
	if typeof(rawReason) ~= "string" then
		return tostring(rawReason or "")
	end

	local reason = rawReason
	local lowered = string.lower(reason)
	local compact = string.gsub(lowered, "[^%a%d]", "")

	-- Normalize all Tung variants to one canonical key for mapping/color.
	if string.find(compact, "tungtungsahur", 1, true)
		or string.find(compact, "tungtung", 1, true)
		or compact == "sahur"
		or compact == "tts"
	then
		return "TungTungSahur"
	end

	return reason
end

local function trim(s: string): string
	return (string.gsub(string.gsub(s, "^%s+", ""), "%s+$", ""))
end

local function resolvePlayerKillerName(rawReason: any): string?
	local reasonType = typeof(rawReason)
	if reasonType == "Instance" then
		if rawReason:IsA("Player") then
			return rawReason.Name
		end
		return nil
	end
	if reasonType == "number" then
		local killerPlayer = Players:GetPlayerByUserId(rawReason)
		return killerPlayer and killerPlayer.Name or nil
	end
	if reasonType ~= "string" then
		return nil
	end

	local reason = trim(rawReason)
	if reason == "" or reason == "..." then
		return nil
	end

	local normalized = normalizeReasonKey(reason)
	if REASON_MAP[normalized] ~= nil then
		return nil
	end

	return reason
end

local function repositionFeedContainer()
	if not feedContainer then
		return
	end

	local topOffset = FEED_FALLBACK_TOP_OFFSET
	if safeAreaFrame and safeAreaFrame.Parent then
		local recommendedGap = safeAreaFrame:GetAttribute("RecommendedGap")
		if typeof(recommendedGap) ~= "number" then
			recommendedGap = 16
		end
		topOffset = safeAreaFrame.Position.Y.Offset + safeAreaFrame.Size.Y.Offset + recommendedGap
	end

	feedContainer.AnchorPoint = Vector2.new(1, 0)
	feedContainer.Position = UDim2.new(1, -FEED_RIGHT_MARGIN, 0, math.floor(topOffset))
end

local function bindSafeArea(frame: GuiObject)
	if safeAreaFrame == frame then
		repositionFeedContainer()
		return
	end

	safeAreaFrame = frame
	frame:GetPropertyChangedSignal("Position"):Connect(repositionFeedContainer)
	frame:GetPropertyChangedSignal("Size"):Connect(repositionFeedContainer)
	frame:GetAttributeChangedSignal("RecommendedGap"):Connect(repositionFeedContainer)
	repositionFeedContainer()
end

local function observeSafeArea(screenGui: ScreenGui)
	local existing = screenGui:FindFirstChild(RIGHT_SAFE_AREA_NAME)
	if existing and existing:IsA("GuiObject") then
		bindSafeArea(existing)
	end

	screenGui.ChildAdded:Connect(function(child)
		if child.Name == RIGHT_SAFE_AREA_NAME and child:IsA("GuiObject") then
			bindSafeArea(child)
		end
	end)
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
	entry.Size = UDim2.new(1, 0, 0, FEED_ENTRY_HEIGHT)
	entry.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	entry.BackgroundTransparency = 0.45
	entry.BorderSizePixel = 0
	entry.ZIndex = 2
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
	label.ZIndex = 3
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
	feedContainer.Size = UDim2.new(
		0,
		FEED_WIDTH,
		0,
		(FEED_ENTRY_HEIGHT * MAX_MESSAGES) + (FEED_ENTRY_GAP * math.max(MAX_MESSAGES - 1, 0))
	)
	feedContainer.BackgroundTransparency = 1
	feedContainer.BorderSizePixel = 0
	feedContainer.ZIndex = 2
	feedContainer.Parent = screenGui

	repositionFeedContainer()
	observeSafeArea(screenGui)

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, FEED_ENTRY_GAP)
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.VerticalAlignment = Enum.VerticalAlignment.Top
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	layout.Parent = feedContainer

	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
		if not remotes then return end
		local killFeedEvent = remotes:WaitForChild("KillFeedEvent", 10)
		if killFeedEvent then
			killFeedEvent.OnClientEvent:Connect(function(playerName, rawReason)
				local reason = normalizeReasonKey(rawReason)
				local reasonText = getReasonText(reason)
				local killerName = resolvePlayerKillerName(rawReason)
				local text
				if killerName then
					text = tostring(killerName) .. " eliminated " .. tostring(playerName)
					print(string.format("[KillfeedPlayer] victim=%s killerRefType=%s", tostring(playerName), typeof(rawReason)))
					print(string.format("[KillfeedPlayer] resolvedKillerName=%s", tostring(killerName)))
					print("[KillfeedPlayer] fallbackUsed=false")
				elseif reason == "TungTungSahur" then
					-- Keep cause visible on narrow/mobile layouts by placing it first.
					text = reasonText .. " eliminated " .. tostring(playerName)
					print(string.format("[KillfeedCause] rawCause=%s", tostring(rawReason)))
					print(string.format("[KillfeedCause] resolvedDisplayName=%s", reasonText))
				else
					if reasonText == nil or tostring(reasonText) == "" or tostring(reasonText) == "..." then
						reasonText = "Unknown"
					end
					text = tostring(playerName) .. " was eliminated by " .. tostring(reasonText)
				end
				local color = REASON_COLOR[reason] or C.TextWhite
				createFeedEntry(text, color)
			end)
		end
	end)
end

function KillFeed.Push(text, color)
	createFeedEntry(text, color)
end

return KillFeed
