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
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UIConfig = require(Shared:WaitForChild("UIConfig"))

local C = UIConfig.Colors
local DEBUG_LOGS = RunService:IsStudio() and UIConfig.DebugLogs == true

local KillFeed = {}

local feedGui = nil
local feedContainer = nil
local safeAreaFrame: GuiObject? = nil
local MAX_MESSAGES = 5
local MESSAGE_LIFETIME = 2.6
local SLIDE_DURATION = 0.25
local FADE_DURATION = 0.4
local FEED_MIN_WIDTH = 340
local FEED_MAX_WIDTH = 440
local FEED_WIDTH_RATIO = 0.52
local FEED_ENTRY_HEIGHT = 36
local FEED_ENTRY_GAP = 6
local FEED_RIGHT_MARGIN = 16
local FEED_FALLBACK_TOP_OFFSET = 240
local RIGHT_SAFE_AREA_NAME = "HUDRightSafeArea"
local FEED_TEXT_PADDING = 12
local FEED_MAX_TEXT_SIZE = 15
local FEED_MIN_TEXT_SIZE = 10

local REASON_MAP = {
	Beam           = "Beam",
	OOB            = "Barrier",
	Barrier        = "Barrier",
	Disconnect     = "Disconnect",
	InactiveNoMove = "Inactivity",
	Sword          = "Sword",
	TungTungSahur  = "TungTungSahur",
	Unknown        = "Unknown",
}

-- Color override per reason key (nil = default white)
local REASON_COLOR = {
	Beam          = Color3.fromRGB(255, 165, 0),  -- orange
	OOB           = Color3.fromRGB(220, 50, 50),  -- red
	Barrier       = Color3.fromRGB(220, 50, 50),  -- red
	TungTungSahur = Color3.fromRGB(255, 60, 180), -- hot pink
}

local function trim(s: string): string
	return (string.gsub(string.gsub(s, "^%s+", ""), "%s+$", ""))
end

local function normalizeReasonKey(rawReason: any): string
	if typeof(rawReason) ~= "string" then
		return tostring(rawReason or "")
	end

	local reason = trim(rawReason)
	local lowered = string.lower(reason)
	local compact = string.gsub(lowered, "[^%a%d]", "")

	if compact == "beam" then
		return "Beam"
	end
	if compact == "oob" or compact == "barrier" or compact == "outofbounds" then
		return "OOB"
	end
	if compact == "disconnect" or compact == "disconnected" then
		return "Disconnect"
	end
	if compact == "inactivenomove" or compact == "inactive" then
		return "InactiveNoMove"
	end
	if compact == "sword" then
		return "Sword"
	end
	if compact == "tungtungsahur" or compact == "tungtung" or compact == "sahur" or compact == "tts" then
		return "TungTungSahur"
	end
	if compact == "unknown" then
		return "Unknown"
	end

	return reason
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

local function getViewportWidth(): number
	local camera = Workspace.CurrentCamera
	if camera then
		return camera.ViewportSize.X
	end
	return FEED_MIN_WIDTH
end

local function getResolvedFeedWidth(): number
	return math.clamp(math.floor(getViewportWidth() * FEED_WIDTH_RATIO), FEED_MIN_WIDTH, FEED_MAX_WIDTH)
end

local function debugLogKillFeed(sourceLabel: string, text: string)
	if not DEBUG_LOGS then
		return
	end
	print(string.format("[KillFeed] source=%s text=%s", sourceLabel, text))
end

local function formatKillFeedMessage(playerName: any, rawReason: any): (string, string, string)
	local victimName = tostring(playerName or "Unknown")
	local reason = normalizeReasonKey(rawReason)
	local killerName = resolvePlayerKillerName(rawReason)
	if killerName then
		return string.format("%s eliminated %s", tostring(killerName), victimName), reason, "Player"
	end

	local sourceName = REASON_MAP[reason]
	if sourceName == nil or sourceName == "" then
		sourceName = "Unknown"
	end

	return string.format("%s eliminated %s", sourceName, victimName), reason, sourceName
end

local function resizeFeedContainer()
	if not feedContainer then
		return
	end

	feedContainer.Size = UDim2.new(
		0,
		getResolvedFeedWidth(),
		0,
		(FEED_ENTRY_HEIGHT * MAX_MESSAGES) + (FEED_ENTRY_GAP * math.max(MAX_MESSAGES - 1, 0))
	)
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

local function bindViewportResize()
	local cameraConn: RBXScriptConnection? = nil

	local function attachCamera(camera: Camera?)
		if cameraConn then
			cameraConn:Disconnect()
			cameraConn = nil
		end

		if camera then
			cameraConn = camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
				resizeFeedContainer()
				repositionFeedContainer()
			end)
		end

		resizeFeedContainer()
		repositionFeedContainer()
	end

	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		attachCamera(Workspace.CurrentCamera)
	end)

	attachCamera(Workspace.CurrentCamera)
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
	entry.ClipsDescendants = false
	entry.ZIndex = 2
	entry.Parent = feedContainer

	Instance.new("UICorner", entry).CornerRadius = UDim.new(0, 8)

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.Size = UDim2.new(1, -(FEED_TEXT_PADDING * 2), 1, 0)
	label.Position = UDim2.fromOffset(FEED_TEXT_PADDING, 0)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = color
	label.TextSize = FEED_MAX_TEXT_SIZE
	label.TextScaled = true
	label.Text = text
	label.TextWrapped = false
	label.TextXAlignment = Enum.TextXAlignment.Right
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.TextTruncate = Enum.TextTruncate.None
	label.ZIndex = 3
	label.Parent = entry

	local textSizeConstraint = Instance.new("UITextSizeConstraint")
	textSizeConstraint.MaxTextSize = FEED_MAX_TEXT_SIZE
	textSizeConstraint.MinTextSize = FEED_MIN_TEXT_SIZE
	textSizeConstraint.Parent = label

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
	feedContainer.Size = UDim2.new(0, 0, 0, 0)
	feedContainer.BackgroundTransparency = 1
	feedContainer.BorderSizePixel = 0
	feedContainer.ClipsDescendants = false
	feedContainer.ZIndex = 2
	feedContainer.Parent = screenGui

	bindViewportResize()
	resizeFeedContainer()
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
				local text, reason, sourceLabel = formatKillFeedMessage(playerName, rawReason)
				debugLogKillFeed(sourceLabel, text)
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
