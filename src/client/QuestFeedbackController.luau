--[[
	QuestFeedbackController
	Client-only presentation layer for quest intro prompts, quest notifications,
	and quest completion announcements.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
local DailyQuestConfig = require(Shared:WaitForChild("DailyQuestConfig", 10))
local MatchState = require(Shared:WaitForChild("MatchState", 10))
local PlayerState = require(Shared:WaitForChild("PlayerState", 10))

local QuestFeedbackController = {}

local GUI_NAME = "QuestFeedbackGui"
local HUD_GUI_NAME = "HUDGui"
local PANEL_GUI_NAME = "PanelGui"
local QUEST_BUTTON_NAME = "QuestsBtn"
local QUEST_PANEL_NAME = "QuestsPanel"
local STARTER_QUEST = DailyQuestConfig.StarterQuest
local STARTER_QUEST_ID = tostring(STARTER_QUEST and STARTER_QUEST.id or "starter_survive_1_round")

local MOBILE = UserInputService.TouchEnabled
local INTRO_WIDTH = MOBILE and 300 or 348
local INTRO_HEIGHT = MOBILE and 74 or 82
local INTRO_START_Y_SCALE = MOBILE and 0.78 or 0.74
local INTRO_HOLD_SECONDS = 1.15
local INTRO_MOVE_SECONDS = 0.45
local ANNOUNCEMENT_WIDTH = MOBILE and 340 or 420
local ANNOUNCEMENT_HEIGHT = MOBILE and 50 or 58
local ANNOUNCEMENT_HOLD_SECONDS = 1.75

local initialized = false
local screenGui: ScreenGui? = nil
local questButton: GuiButton? = nil
local questPanel: GuiObject? = nil
local questCountBadge: Frame? = nil
local questCountBadgeLabel: TextLabel? = nil
local bellUnread = false
local currentIntro: CanvasGroup? = nil
local currentAnnouncement: CanvasGroup? = nil
local currentFlash: Frame? = nil
local currentPresentationToken = 0
local queuePumpToken = 0
local matchStateValue: StringValue? = nil
local getStatusRemote: RemoteFunction? = nil
local updateRemote: RemoteEvent? = nil
local connectedQuestPanel: GuiObject? = nil
local activeQuestCount = 0
local lastLoggedBadgeCount: number? = nil
local lastLoggedAuthoritativeStatusSignature: string? = nil

local knownQuestStates: { [string]: { completed: boolean, progress: number, target: number } } = {}
local queuedIntroIds: { [string]: boolean } = {}
local shownIntroIds: { [string]: boolean } = {}
local announcedCompletionIds: { [string]: boolean } = {}
local introQueue: { [number]: { [string]: any } } = {}
local completionQueue: { [number]: { [string]: any } } = {}

local function log(message: string)
	print("[QuestFeedback] " .. message)
end

local function formatNumber(value: number): string
	local rounded = math.max(0, math.floor(tonumber(value) or 0))
	local reversed = string.reverse(tostring(rounded))
	local withCommas = string.reverse(reversed:gsub("(%d%d%d)", "%1,"))
	return withCommas:gsub("^,", "")
end

local function normalizeLabel(value: string): string
	local normalized = tostring(value or "")
	normalized = normalized:gsub("(%l)(%u)", "%1 %2")
	normalized = normalized:gsub("(%u)(%u%l)", "%1 %2")
	normalized = normalized:gsub("_", " ")
	normalized = normalized:gsub("%s+", " ")
	normalized = normalized:gsub("^%s+", ""):gsub("%s+$", "")
	return string.upper(normalized)
end

local function getQuestObjectiveText(quest): string
	local questType = tostring(quest.type or "")
	local target = math.max(1, math.floor(tonumber(quest.target) or 1))

	if tostring(quest.id or "") == STARTER_QUEST_ID or questType == "StarterSurviveRound" then
		return "SURVIVE 1 ROUND"
	elseif questType == "TimePlayed" then
		local minutes = math.max(1, math.floor(target / 60 + 0.5))
		return string.format("PLAY FOR %d MINUTE%s", minutes, minutes == 1 and "" or "S")
	elseif questType == "WinsToday" then
		return string.format("WIN %d MATCH%s", target, target == 1 and "" or "ES")
	elseif questType == "SwordKillsToday" then
		return string.format("GET %d SWORD KILL%s", target, target == 1 and "" or "S")
	elseif questType == "EliminationsToday" then
		return string.format("ELIMINATE %d PLAYER%s", target, target == 1 and "" or "S")
	elseif questType == "SurviveRoundsToday" then
		return string.format("SURVIVE %d ROUND%s", target, target == 1 and "" or "S")
	elseif questType == "TTSSurvivalsToday" then
		return string.format("SURVIVE TUNGTUNG %d TIME%s", target, target == 1 and "" or "S")
	elseif questType == "BrainrotIShowSpeedPickupsToday" then
		return string.format("PICK UP ISHOWSPEED %d TIME%s", target, target == 1 and "" or "S")
	elseif questType == "SurviveRoundsSingleMatch12" or questType == "SurviveRoundsSingleMatch15" then
		return string.format("SURVIVE %d ROUNDS IN ONE MATCH", target)
	end

	local desc = tostring(quest.description or quest.label or "")
	desc = desc:gsub("%.?%s*[Rr]eward:%s*.+$", "")
	if desc ~= "" then
		return normalizeLabel(desc)
	end

	return normalizeLabel(tostring(quest.label or "NEW QUEST"))
end

local function isQuestFeedbackEligible(): boolean
	local playerState = tostring(LocalPlayer:GetAttribute("PlayerState") or "")
	local matchState = matchStateValue and tostring(matchStateValue.Value or "") or ""

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
		or playerState == PlayerState.States.Waiting
		or playerState == PlayerState.States.TutorialLocked
end

local function isQuestPanelVisible(): boolean
	return questPanel ~= nil and questPanel.Visible == true
end

local function destroyInstanceSafely(instance: Instance?)
	if instance and instance.Parent then
		instance:Destroy()
	end
end

local function ensureScreenGui()
	if screenGui and screenGui.Parent then
		return
	end

	local existing = PlayerGui:FindFirstChild(GUI_NAME)
	if existing and existing:IsA("ScreenGui") then
		existing:ClearAllChildren()
		screenGui = existing
	else
		screenGui = Instance.new("ScreenGui")
		screenGui.Name = GUI_NAME
		screenGui.ResetOnSpawn = false
		screenGui.IgnoreGuiInset = false
		screenGui.DisplayOrder = 60
		screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		screenGui.Parent = PlayerGui
	end
end

local function ensureQuestButton()
	if questButton and questButton.Parent then
		return questButton
	end

	local hudGui = PlayerGui:FindFirstChild(HUD_GUI_NAME)
	if not hudGui then
		return nil
	end

	local button = hudGui:FindFirstChild(QUEST_BUTTON_NAME, true)
	if button and button:IsA("GuiButton") then
		questButton = button
	end

	return questButton
end

local function ensureQuestPanel()
	if questPanel and questPanel.Parent then
		return questPanel
	end

	local panelGui = PlayerGui:FindFirstChild(PANEL_GUI_NAME)
	if not panelGui then
		return nil
	end

	local panel = panelGui:FindFirstChild(QUEST_PANEL_NAME, true)
	if panel and panel:IsA("GuiObject") then
		questPanel = panel
	end

	return questPanel
end

local function clearTransientUi(reason: string)
	currentPresentationToken += 1
	local hadTransientUi = currentIntro ~= nil or currentAnnouncement ~= nil or currentFlash ~= nil
	destroyInstanceSafely(currentIntro)
	destroyInstanceSafely(currentAnnouncement)
	destroyInstanceSafely(currentFlash)
	currentIntro = nil
	currentAnnouncement = nil
	currentFlash = nil

	if hadTransientUi and reason ~= "" then
		log("presentation_cleared reason=" .. reason)
	end
end

local function ensureQuestCountBadge()
	local button = ensureQuestButton()
	if not button then
		return nil
	end

	if questCountBadge and questCountBadge.Parent == button then
		return questCountBadge
	end

	destroyInstanceSafely(questCountBadge)

	local badge = Instance.new("Frame")
	badge.Name = "QuestCountBadge"
	badge.AnchorPoint = Vector2.new(0.5, 0.5)
	badge.Position = UDim2.new(1, -8, 0, 8)
	badge.Size = UDim2.fromOffset(MOBILE and 22 or 24, MOBILE and 22 or 24)
	badge.BackgroundColor3 = Color3.fromRGB(255, 235, 92)
	badge.BackgroundTransparency = 0.02
	badge.BorderSizePixel = 0
	badge.Visible = false
	badge.ZIndex = button.ZIndex + 4
	badge.Parent = button
	questCountBadge = badge

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = badge

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(120, 18, 18)
	stroke.Thickness = 1.6
	stroke.Transparency = 0.1
	stroke.Parent = badge

	local shadow = Instance.new("ImageLabel")
	shadow.Name = "Shadow"
	shadow.AnchorPoint = Vector2.new(0.5, 0.5)
	shadow.Position = UDim2.fromScale(0.5, 0.5)
	shadow.Size = UDim2.new(1, 12, 1, 12)
	shadow.BackgroundTransparency = 1
	shadow.Image = "rbxassetid://1316045217"
	shadow.ImageColor3 = Color3.new(0, 0, 0)
	shadow.ImageTransparency = 0.58
	shadow.ScaleType = Enum.ScaleType.Slice
	shadow.SliceCenter = Rect.new(10, 10, 118, 118)
	shadow.ZIndex = badge.ZIndex - 1
	shadow.Parent = badge

	local label = Instance.new("TextLabel")
	label.Name = "Count"
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.Text = ""
	label.TextColor3 = Color3.fromRGB(110, 12, 12)
	label.TextSize = MOBILE and 12 or 13
	label.ZIndex = badge.ZIndex + 1
	label.Parent = badge
	questCountBadgeLabel = label

	log("quest_count_badge_attached button=" .. button.Name)
	return badge
end

local function refreshQuestCountBadge(reason: string)
	local badge = ensureQuestCountBadge()
	if not badge or not questCountBadgeLabel then
		return
	end

	local nextVisible = activeQuestCount > 0
	badge.Visible = nextVisible
	questCountBadgeLabel.Text = nextVisible and tostring(math.min(activeQuestCount, 99)) or ""

	if lastLoggedBadgeCount ~= activeQuestCount then
		lastLoggedBadgeCount = activeQuestCount
		log(string.format("quest_count_badge_updated count=%d reason=%s", activeQuestCount, reason))
		if activeQuestCount == 0 then
			log("quest_count_badge_hidden reason=count_zero")
		end
	end
end

local function updateActiveQuestCount(status, reason: string)
	if type(status) ~= "table" or type(status.quests) ~= "table" then
		return
	end
	activeQuestCount = #status.quests
	refreshQuestCountBadge(reason)
end

local function setBellUnread(active: boolean, reason: string)
	if bellUnread == active then
		return
	end

	bellUnread = active
end

local function stopBellAnimation()
	return
end

local function startBellAnimation()
	return
end

local function ensureBell()
	return nil
end

local function refreshBell()
	return
end

local function playCompletionFlash()
	ensureScreenGui()
	if not screenGui then
		return
	end

	destroyInstanceSafely(currentFlash)

	local flash = Instance.new("Frame")
	flash.Name = "QuestCompletionFlash"
	flash.Size = UDim2.fromScale(1, 1)
	flash.BackgroundColor3 = Color3.fromRGB(255, 244, 176)
	flash.BackgroundTransparency = 1
	flash.BorderSizePixel = 0
	flash.ZIndex = 49
	flash.Parent = screenGui
	currentFlash = flash

	local fadeIn = TweenService:Create(
		flash,
		TweenInfo.new(0.07, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
		{ BackgroundTransparency = 0.84 }
	)
	local fadeOut = TweenService:Create(
		flash,
		TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ BackgroundTransparency = 1 }
	)

	fadeIn:Play()
	fadeIn.Completed:Connect(function()
		if flash.Parent then
			fadeOut:Play()
		end
	end)
	fadeOut.Completed:Connect(function()
		if currentFlash == flash then
			destroyInstanceSafely(flash)
			currentFlash = nil
		end
	end)
end

local function createBannerFrame(name: string, size: UDim2, position: UDim2): CanvasGroup
	ensureScreenGui()

	local frame = Instance.new("CanvasGroup")
	frame.Name = name
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = position
	frame.Size = size
	frame.BackgroundColor3 = Color3.fromRGB(118, 20, 20)
	frame.BackgroundTransparency = 0.05
	frame.BorderSizePixel = 0
	frame.GroupTransparency = 1
	frame.ZIndex = 50
	frame.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, MOBILE and 16 or 18)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(255, 219, 92)
	stroke.Thickness = 2
	stroke.Transparency = 0.1
	stroke.Parent = frame

	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(220, 46, 46)),
		ColorSequenceKeypoint.new(0.45, Color3.fromRGB(158, 24, 24)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(92, 12, 12)),
	})
	gradient.Rotation = 90
	gradient.Parent = frame

	local shadow = Instance.new("ImageLabel")
	shadow.Name = "Shadow"
	shadow.AnchorPoint = Vector2.new(0.5, 0.5)
	shadow.Position = UDim2.fromScale(0.5, 0.5)
	shadow.Size = UDim2.new(1, 28, 1, 28)
	shadow.BackgroundTransparency = 1
	shadow.Image = "rbxassetid://1316045217"
	shadow.ImageColor3 = Color3.new(0, 0, 0)
	shadow.ImageTransparency = 0.44
	shadow.ScaleType = Enum.ScaleType.Slice
	shadow.SliceCenter = Rect.new(10, 10, 118, 118)
	shadow.ZIndex = frame.ZIndex - 1
	shadow.Parent = frame

	return frame
end

local function addLabel(parent: Instance, name: string, text: string, position: UDim2, size: UDim2, textSize: number, color: Color3): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Position = position
	label.Size = size
	label.Font = Enum.Font.LuckiestGuy
	label.Text = text
	label.TextColor3 = color
	label.TextSize = textSize
	label.TextWrapped = true
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.ZIndex = 51
	label.Parent = parent

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.new(0, 0, 0)
	stroke.Thickness = 2
	stroke.Transparency = 0.18
	stroke.Parent = label

	return label
end

local function getQuestButtonTargetCenter(): Vector2?
	local button = ensureQuestButton()
	if not button then
		return nil
	end

	local absolutePosition = button.AbsolutePosition
	local absoluteSize = button.AbsoluteSize
	return absolutePosition + (absoluteSize * 0.5)
end

local function pumpQueues(reason: string)
	queuePumpToken += 1
	local token = queuePumpToken

	task.defer(function()
		if token ~= queuePumpToken then
			return
		end

		refreshBell()

		if currentIntro or currentAnnouncement then
			return
		end

		if not isQuestFeedbackEligible() or isQuestPanelVisible() then
			if #introQueue > 0 then
				log(string.format(
					"popup_shown=false reason=%s feedbackEligible=%s questPanelVisible=%s queued=%d",
					reason,
					tostring(isQuestFeedbackEligible()),
					tostring(isQuestPanelVisible()),
					#introQueue
				))
			end
			return
		end

		local nextIntro = table.remove(introQueue, 1)
		if not nextIntro then
			return
		end

		local targetCenter = getQuestButtonTargetCenter()
		if not targetCenter then
			table.insert(introQueue, 1, nextIntro)
			log(string.format("popup_shown=false reason=quest_button_missing quest=%s", tostring(nextIntro.id)))
			return
		end
		queuedIntroIds[nextIntro.id] = nil

		local presentationToken = currentPresentationToken + 1
		currentPresentationToken = presentationToken

		local intro = createBannerFrame(
			"QuestIntroPopup",
			UDim2.fromOffset(INTRO_WIDTH, INTRO_HEIGHT),
			UDim2.new(0.5, 0, INTRO_START_Y_SCALE, 0)
		)
		currentIntro = intro

		addLabel(
			intro,
			"QuestObjective",
			getQuestObjectiveText(nextIntro),
			UDim2.fromOffset(18, 8),
			UDim2.new(1, -36, 0, MOBILE and 30 or 34),
			MOBILE and 18 or 20,
			Color3.fromRGB(255, 255, 255)
		)

		addLabel(
			intro,
			"QuestReward",
			"REWARD: " .. string.upper(DailyQuestConfig.GetRewardLabel(nextIntro.reward)),
			UDim2.fromOffset(18, MOBILE and 42 or 48),
			UDim2.new(1, -36, 0, 24),
			MOBILE and 11 or 12,
			Color3.fromRGB(255, 234, 162)
		)

		local fadeIn = TweenService:Create(
			intro,
			TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ GroupTransparency = 0 }
		)
		fadeIn:Play()
		log(string.format(
			"popup_shown=true quest=%s reward=%s",
			tostring(nextIntro.id),
			DailyQuestConfig.GetRewardLabel(nextIntro.reward)
		))

		task.delay(INTRO_HOLD_SECONDS, function()
			if currentPresentationToken ~= presentationToken or currentIntro ~= intro then
				return
			end

			local moveTween = TweenService:Create(
				intro,
				TweenInfo.new(INTRO_MOVE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
				{
					Position = UDim2.fromOffset(targetCenter.X, targetCenter.Y),
					Size = UDim2.fromOffset(128, 34),
					GroupTransparency = 0.12,
				}
			)
			moveTween:Play()
			moveTween.Completed:Connect(function()
				if currentPresentationToken ~= presentationToken or currentIntro ~= intro then
					return
				end

				log(string.format(
					"quest_intro_docked quest=%s target=%s",
					tostring(nextIntro.id),
					QUEST_BUTTON_NAME
				))
				setBellUnread(true, "quest_intro_" .. tostring(nextIntro.id))
				refreshBell()
				destroyInstanceSafely(intro)
				currentIntro = nil
				pumpQueues("intro_finished")
			end)
		end)
	end)
end

local function queueIntro(quest, reason: string)
	if tostring(quest.id or "") ~= STARTER_QUEST_ID then
		return
	end
	if shownIntroIds[quest.id] or queuedIntroIds[quest.id] or quest.completed then
		return
	end

	shownIntroIds[quest.id] = true
	queuedIntroIds[quest.id] = true
	table.insert(introQueue, quest)
	log(string.format(
		"intro_queued quest=%s reward=%s reason=%s source=authoritative_status",
		tostring(quest.id),
		DailyQuestConfig.GetRewardLabel(quest.reward),
		reason
	))
	pumpQueues("intro_queued")
end

local function queueCompletion(quest)
	if announcedCompletionIds[quest.id] then
		return
	end

	announcedCompletionIds[quest.id] = true
	if tostring(quest.id or "") ~= STARTER_QUEST_ID then
		setBellUnread(true, "quest_complete_" .. tostring(quest.id))
	end
	refreshBell()
	log(string.format("completion_seen quest=%s routed=AnnouncementController", tostring(quest.id)))
end

local function logAuthoritativeStatus(status, reason: string)
	if type(status) ~= "table" or type(status.quests) ~= "table" then
		return
	end

	local entries = table.create(#status.quests)
	local starterPresent = false
	for _, quest in ipairs(status.quests) do
		local questId = tostring(quest.id or "")
		local questLabel = tostring(quest.label or questId)
		if questId == STARTER_QUEST_ID then
			starterPresent = true
		end
		table.insert(entries, questId .. ":" .. questLabel)
	end

	local payloadSignature = tostring(#status.quests) .. "::" .. table.concat(entries, "|")
	if lastLoggedAuthoritativeStatusSignature == payloadSignature then
		return
	end
	lastLoggedAuthoritativeStatusSignature = payloadSignature

	log(string.format(
		"authoritative_status_received reason=%s activeQuestCount=%d starterPresent=%s quests=%s",
		reason,
		#status.quests,
		tostring(starterPresent),
		table.concat(entries, ",")
	))
	log(string.format(
		"ui_received_quest quest=%s visibleInPayload=%s source=authoritative_status",
		STARTER_QUEST_ID,
		tostring(starterPresent)
	))
end

local function applyStatus(status, reason: string)
	if type(status) ~= "table" or status.dataLoaded ~= true or type(status.quests) ~= "table" then
		return
	end

	logAuthoritativeStatus(status, reason)
	updateActiveQuestCount(status, reason)

	local seenQuestIds = {}

	for _, quest in ipairs(status.quests) do
		if type(quest) == "table" and type(quest.id) == "string" then
			seenQuestIds[quest.id] = true

			local previous = knownQuestStates[quest.id]
			local completed = quest.completed == true
			local progress = math.floor(tonumber(quest.progress) or 0)
			local target = math.floor(tonumber(quest.target) or 0)
			knownQuestStates[quest.id] = {
				completed = completed,
				progress = progress,
				target = target,
			}

			if previous and previous.completed ~= true and completed then
				queueCompletion(quest)
			end

			if not previous then
				queueIntro(quest, reason .. "_new")
			end
		end
	end

	for questId in pairs(knownQuestStates) do
		if not seenQuestIds[questId] then
			knownQuestStates[questId] = nil
		end
	end

	refreshBell()
end

local function requestCurrentStatus(reason: string)
	if not getStatusRemote then
		return
	end

	local ok, status = pcall(getStatusRemote.InvokeServer, getStatusRemote)
	if ok and status then
		applyStatus(status, reason)
	end
end

local function connectQuestPanelVisibility()
	local panel = ensureQuestPanel()
	if not panel or connectedQuestPanel == panel then
		return
	end
	connectedQuestPanel = panel

	panel:GetPropertyChangedSignal("Visible"):Connect(function()
		if panel.Visible then
			setBellUnread(false, "quests_opened")
			refreshBell()
			clearTransientUi("quests_opened")
		else
			pumpQueues("quests_closed")
		end
	end)

	if panel.Visible then
		setBellUnread(false, "quests_opened")
		refreshBell()
	end
end

function QuestFeedbackController.Init()
	if initialized then
		return
	end
	initialized = true

	ensureScreenGui()
	ensureBell()

	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
		if not remotes then
			warn("[QuestFeedback] Remotes not found")
			return
		end

		local statusRemote = remotes:WaitForChild("DailyQuest_GetStatus", 15)
		if statusRemote and statusRemote:IsA("RemoteFunction") then
			getStatusRemote = statusRemote
		end

		local dailyUpdate = remotes:WaitForChild("DailyQuest_Update", 15)
		if dailyUpdate and dailyUpdate:IsA("RemoteEvent") then
			updateRemote = dailyUpdate
			updateRemote.OnClientEvent:Connect(function(status)
				applyStatus(status, "remote_update")
			end)
		end

		requestCurrentStatus("init")
	end)

	task.spawn(function()
		local matchStatus = ReplicatedStorage:WaitForChild("MatchStatus", 15)
		if not matchStatus then
			warn("[QuestFeedback] MatchStatus not found")
			return
		end

		matchStateValue = matchStatus:WaitForChild("State", 10) :: StringValue?
		if matchStateValue then
			matchStateValue.Changed:Connect(function()
				if not isQuestFeedbackEligible() then
					clearTransientUi("match_state_changed")
				end
				refreshBell()
				pumpQueues("match_state_changed")
			end)
		end
	end)

	LocalPlayer:GetAttributeChangedSignal("PlayerState"):Connect(function()
		if not isQuestFeedbackEligible() then
			clearTransientUi("player_state_changed")
		end
		refreshBell()
		pumpQueues("player_state_changed")
	end)

	task.spawn(function()
		local hudGui = PlayerGui:WaitForChild(HUD_GUI_NAME, 15)
		if hudGui then
			hudGui.DescendantAdded:Connect(function(descendant)
				if descendant.Name == QUEST_BUTTON_NAME and descendant:IsA("GuiButton") then
					questButton = descendant
					ensureBell()
					refreshBell()
					pumpQueues("quest_button_ready")
				end
			end)
		end
		ensureQuestButton()
		ensureBell()
		refreshQuestCountBadge("quest_button_ready")
		refreshBell()
		pumpQueues("quest_button_ready")
	end)

	task.spawn(function()
		local panelGui = PlayerGui:WaitForChild(PANEL_GUI_NAME, 15)
		if panelGui then
			panelGui.DescendantAdded:Connect(function(descendant)
				if descendant.Name == QUEST_PANEL_NAME and descendant:IsA("GuiObject") then
					questPanel = descendant
					connectQuestPanelVisibility()
					pumpQueues("quest_panel_ready")
				end
			end)
		end
		ensureQuestPanel()
		connectQuestPanelVisibility()
	end)

	refreshBell()
	pumpQueues("init")
end

return QuestFeedbackController
