--[[
	NextGoalPopupController
	Lightweight lobby/intermission popup for the live next Fate Coin goal.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
local MatchState = require(Shared:WaitForChild("MatchState", 10))
local PlayerData = require(Shared:WaitForChild("PlayerData", 10))
local PlayerState = require(Shared:WaitForChild("PlayerState", 10))
local ProgressionGoalResolver = require(Shared:WaitForChild("ProgressionGoalResolver", 10))
local UIConfig = require(Shared:WaitForChild("UIConfig", 10))

local NextGoalPopupController = {}

local POPUP_NAME = "NextGoalPopupGui"
local POPUP_COOLDOWN_SECONDS = 60
local LARGE_COIN_GAIN_THRESHOLD = 100
local OPEN_Y_OFFSET = UserInputService.TouchEnabled and 84 or 92
local POPUP_WIDTH = UserInputService.TouchEnabled and 316 or 360
local POPUP_HEIGHT = UserInputService.TouchEnabled and 84 or 92
local CLOSED_Y_OFFSET = -(POPUP_HEIGHT + 20)

local initialized = false
local screenGui: ScreenGui? = nil
local popupFrame: Frame? = nil
local titleLabel: TextLabel? = nil
local detailLabel: TextLabel? = nil
local activeTween: Tween? = nil
local matchStateValue: StringValue? = nil
local connectedRemoteNames: { [string]: boolean } = {}
local nextAllowedOpenAt = 0
local reopenToken = 0
local lastLoggedResolutionKey: string? = nil
local lastShownGoalKey: string? = nil
local lastShownAt = 0
local lastObservedCoins = math.max(0, math.floor(tonumber(LocalPlayer:GetAttribute(PlayerData.Attributes.Coins)) or 0))
local lastMatchState: string = ""
local scheduleRefresh: (reason: string) -> ()

local function log(message: string)
	print("[NextGoalPopup] " .. message)
end

local function formatCoinCount(value: number): string
	local rounded = math.max(0, math.floor(tonumber(value) or 0))
	local reversed = string.reverse(tostring(rounded))
	local withCommas = string.reverse(reversed:gsub("(%d%d%d)", "%1,"))
	return withCommas:gsub("^,", "")
end

local function formatGoalName(name: string): string
	local formatted = tostring(name or "")
	formatted = formatted:gsub("(%l)(%u)", "%1 %2")
	formatted = formatted:gsub("(%u)(%u%l)", "%1 %2")
	formatted = formatted:gsub("(%d)(%u%l)", "%1 %2")
	formatted = formatted:gsub("%s+", " ")
	formatted = formatted:gsub("^%s+", ""):gsub("%s+$", "")
	return string.upper(formatted)
end

local function getGoalLocationSuffix(goal): string
	local goalType = tostring(goal and goal.type or "")
	if goalType == "Crown" or goalType == "ExclusiveCrown" then
		return " - FOUND IN SHOP"
	end
	return ""
end

local function decodeOwnedList(attributeName: string): any
	local rawValue = LocalPlayer:GetAttribute(attributeName)
	if type(rawValue) ~= "string" or rawValue == "" then
		return {}
	end

	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, rawValue)
	if ok and type(decoded) == "table" then
		return decoded
	end

	return {}
end

local function resolveNextGoal()
	local attributes = PlayerData.Attributes
	local goal = ProgressionGoalResolver.ResolveNextGoal({
		coins = LocalPlayer:GetAttribute(attributes.Coins) or 0,
		ownedCrowns = decodeOwnedList(attributes.OwnedCrowns),
		ownedPets = decodeOwnedList(attributes.OwnedPets),
	})

	local coins = goal and goal.currentCoins or math.max(0, math.floor(tonumber(LocalPlayer:GetAttribute(attributes.Coins) or 0) or 0))
	local resolutionKey = goal and string.format("%s:%d:%d", goal.id, goal.price, coins) or ("none:" .. tostring(coins))
	if resolutionKey ~= lastLoggedResolutionKey then
		lastLoggedResolutionKey = resolutionKey
		if goal then
			log(string.format("resolved item=%s price=%d coins=%d", goal.id, goal.price, coins))
		else
			log(string.format("resolved item=none coins=%d", coins))
		end
	end

	return goal
end

local function getPopupOpenPosition(): UDim2
	return UDim2.new(0.5, 0, 0, OPEN_Y_OFFSET)
end

local function getPopupClosedPosition(): UDim2
	return UDim2.new(0.5, 0, 0, CLOSED_Y_OFFSET)
end

local function isPopupEligible(): boolean
	local playerState = tostring(LocalPlayer:GetAttribute("PlayerState") or "")
	local matchState = matchStateValue and matchStateValue.Value or ""

	if playerState == PlayerState.States.InMatch then
		return false
	end

	if matchState == MatchState.States.Playing or matchState == MatchState.States.Ending then
		return false
	end

	if matchState == MatchState.States.Intermission then
		return true
	end

	return playerState == PlayerState.States.Lobby
end

local function destroyPopup()
	if activeTween then
		activeTween:Cancel()
		activeTween = nil
	end

	if popupFrame then
		popupFrame:Destroy()
		popupFrame = nil
	end

	titleLabel = nil
	detailLabel = nil
end

local function ensureScreenGui()
	if screenGui and screenGui.Parent then
		return
	end

	screenGui = PlayerGui:FindFirstChild(POPUP_NAME) :: ScreenGui?
	if screenGui then
		screenGui:ClearAllChildren()
	else
		screenGui = Instance.new("ScreenGui")
		screenGui.Name = POPUP_NAME
		screenGui.ResetOnSpawn = false
		screenGui.IgnoreGuiInset = true
		screenGui.DisplayOrder = 55
		screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		screenGui.Parent = PlayerGui
	end
end

local function updatePopupContent(goal)
	if not titleLabel or not detailLabel then
		return
	end

	titleLabel.Text = "NEXT GOAL: " .. formatGoalName(goal.name)
	detailLabel.Text = string.format(
		"%sF - YOU HAVE %s%s",
		formatCoinCount(goal.price),
		formatCoinCount(goal.currentCoins),
		getGoalLocationSuffix(goal)
	)
	detailLabel.TextColor3 = if goal.remainingCoins > 0
		then Color3.fromRGB(255, 224, 122)
		else Color3.fromRGB(146, 244, 176)
end

local function getGoalKey(goal): string
	return string.format("%s:%d", tostring(goal.id or ""), math.max(0, math.floor(tonumber(goal.price) or 0)))
end

local function closePopup(manualClose: boolean, reason: string)
	if manualClose then
		nextAllowedOpenAt = math.max(nextAllowedOpenAt, os.clock() + POPUP_COOLDOWN_SECONDS)
		reopenToken += 1
		local token = reopenToken
		task.delay(POPUP_COOLDOWN_SECONDS, function()
			if reopenToken ~= token or popupFrame then
				return
			end
			scheduleRefresh("manual_close_cooldown")
		end)
	end

	if not popupFrame then
		if manualClose then
			log(string.format("popup_closed reason=%s cooldown=%.1fs", reason, POPUP_COOLDOWN_SECONDS))
		end
		return
	end

	if activeTween then
		activeTween:Cancel()
		activeTween = nil
	end

	local frameToClose = popupFrame
	activeTween = TweenService:Create(
		frameToClose,
		TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Position = getPopupClosedPosition() }
	)
	activeTween:Play()
	activeTween.Completed:Connect(function()
		if popupFrame == frameToClose then
			destroyPopup()
		end
	end)

	log(string.format("popup_closed reason=%s cooldown=%.1fs", reason, manualClose and POPUP_COOLDOWN_SECONDS or 0))
end

local function buildPopup()
	ensureScreenGui()
	destroyPopup()

	local frame = Instance.new("Frame")
	frame.Name = "NextGoalPopup"
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.Position = getPopupClosedPosition()
	frame.Size = UDim2.fromOffset(POPUP_WIDTH, POPUP_HEIGHT)
	frame.BackgroundColor3 = Color3.fromRGB(24, 30, 58)
	frame.BackgroundTransparency = 0.06
	frame.BorderSizePixel = 0
	frame.ZIndex = 40
	frame.Parent = screenGui
	popupFrame = frame

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 18)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(255, 210, 88)
	stroke.Thickness = 1.8
	stroke.Transparency = 0.18
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = frame

	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(48, 60, 104)),
		ColorSequenceKeypoint.new(0.55, Color3.fromRGB(24, 30, 58)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(14, 18, 34)),
	})
	gradient.Rotation = 90
	gradient.Parent = frame

	local shadow = Instance.new("ImageLabel")
	shadow.Name = "Shadow"
	shadow.AnchorPoint = Vector2.new(0.5, 0.5)
	shadow.Position = UDim2.fromScale(0.5, 0.5)
	shadow.Size = UDim2.new(1, 36, 1, 36)
	shadow.BackgroundTransparency = 1
	shadow.Image = "rbxassetid://1316045217"
	shadow.ImageColor3 = Color3.new(0, 0, 0)
	shadow.ImageTransparency = 0.42
	shadow.ScaleType = Enum.ScaleType.Slice
	shadow.SliceCenter = Rect.new(10, 10, 118, 118)
	shadow.ZIndex = 39
	shadow.Parent = frame

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(16, 14)
	title.Size = UDim2.new(1, -64, 0, 24)
	title.Font = Enum.Font.GothamBlack
	title.TextColor3 = UIConfig.Colors.TextWhite
	title.TextSize = UserInputService.TouchEnabled and 18 or 20
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextTruncate = Enum.TextTruncate.AtEnd
	title.ZIndex = 41
	title.Parent = frame
	titleLabel = title

	local titleStroke = Instance.new("UIStroke")
	titleStroke.Color = Color3.new(0, 0, 0)
	titleStroke.Thickness = 1.5
	titleStroke.Transparency = 0.25
	titleStroke.Parent = title

	local detail = Instance.new("TextLabel")
	detail.Name = "Detail"
	detail.BackgroundTransparency = 1
	detail.Position = UDim2.fromOffset(16, 44)
	detail.Size = UDim2.new(1, -32, 0, 22)
	detail.Font = Enum.Font.GothamBold
	detail.TextColor3 = Color3.fromRGB(255, 224, 122)
	detail.TextSize = UserInputService.TouchEnabled and 13 or 15
	detail.TextXAlignment = Enum.TextXAlignment.Left
	detail.TextTruncate = Enum.TextTruncate.AtEnd
	detail.ZIndex = 41
	detail.Parent = frame
	detailLabel = detail

	local detailStroke = Instance.new("UIStroke")
	detailStroke.Color = Color3.new(0, 0, 0)
	detailStroke.Thickness = 1.2
	detailStroke.Transparency = 0.28
	detailStroke.Parent = detail

	local closeButton = Instance.new("TextButton")
	closeButton.Name = "CloseButton"
	closeButton.AnchorPoint = Vector2.new(1, 0)
	closeButton.Position = UDim2.new(1, -10, 0, 10)
	closeButton.Size = UDim2.fromOffset(28, 28)
	closeButton.BackgroundColor3 = Color3.fromRGB(48, 56, 96)
	closeButton.AutoButtonColor = true
	closeButton.BorderSizePixel = 0
	closeButton.Font = Enum.Font.GothamBlack
	closeButton.Text = "X"
	closeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	closeButton.TextSize = 14
	closeButton.ZIndex = 42
	closeButton.Parent = frame

	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(1, 0)
	closeCorner.Parent = closeButton

	local closeStroke = Instance.new("UIStroke")
	closeStroke.Color = Color3.fromRGB(255, 218, 124)
	closeStroke.Thickness = 1.2
	closeStroke.Transparency = 0.28
	closeStroke.Parent = closeButton

	closeButton.MouseButton1Click:Connect(function()
		closePopup(true, "manual_close")
	end)
end

local function openPopup(goal, reason: string)
	buildPopup()
	updatePopupContent(goal)

	if not popupFrame then
		return
	end

	if activeTween then
		activeTween:Cancel()
		activeTween = nil
	end

	activeTween = TweenService:Create(
		popupFrame,
		TweenInfo.new(0.24, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Position = getPopupOpenPosition() }
	)
	activeTween:Play()
	lastShownGoalKey = getGoalKey(goal)
	lastShownAt = os.clock()
	log(string.format(
		"popup_opened item=%s cost=%d coins=%d reason=%s",
		goal.id,
		goal.price,
		goal.currentCoins,
		reason
	))
end

function scheduleRefresh(reason: string)
	local delaySeconds = math.max(0, nextAllowedOpenAt - os.clock())
	if delaySeconds <= 0 then
		task.defer(function()
			local goal = resolveNextGoal()
			if popupFrame and goal then
				updatePopupContent(goal)
			end

			if not goal or not isPopupEligible() then
				closePopup(false, goal and ("blocked_" .. reason) or ("no_goal_" .. reason))
				return
			end

			if popupFrame then
				return
			end

			local now = os.clock()
			local goalKey = getGoalKey(goal)
			if now < nextAllowedOpenAt then
				return
			end
			if lastShownGoalKey == goalKey and (now - lastShownAt) < POPUP_COOLDOWN_SECONDS then
				return
			end

			openPopup(goal, reason)
		end)
		return
	end

	reopenToken += 1
	local token = reopenToken
	task.delay(delaySeconds, function()
		if reopenToken ~= token or popupFrame then
			return
		end
		scheduleRefresh("cooldown_complete")
	end)
end

function NextGoalPopupController.Init()
	if initialized then
		return
	end
	initialized = true

	ensureScreenGui()

	LocalPlayer:GetAttributeChangedSignal(PlayerData.Attributes.Coins):Connect(function()
		local latestCoins = math.max(0, math.floor(tonumber(LocalPlayer:GetAttribute(PlayerData.Attributes.Coins)) or 0))
		local delta = latestCoins - lastObservedCoins
		lastObservedCoins = latestCoins
		if delta >= LARGE_COIN_GAIN_THRESHOLD then
			scheduleRefresh("large_coin_gain")
		end
	end)

	task.spawn(function()
		local matchStatus = ReplicatedStorage:WaitForChild("MatchStatus", 15)
		if not matchStatus then
			warn("[NextGoalPopup] MatchStatus not found")
			return
		end

		matchStateValue = matchStatus:WaitForChild("State", 10) :: StringValue?
		if matchStateValue then
			lastMatchState = matchStateValue.Value
			matchStateValue.Changed:Connect(function()
				local nextState = matchStateValue and matchStateValue.Value or ""
				local wasInMatch = (lastMatchState == MatchState.States.Playing) or (lastMatchState == MatchState.States.Ending)
				local isNowIntermission = nextState == MatchState.States.Intermission
				lastMatchState = nextState
				if wasInMatch and isNowIntermission then
					scheduleRefresh("match_end")
				end
			end)
		end

		scheduleRefresh("join")
	end)
end

return NextGoalPopupController
