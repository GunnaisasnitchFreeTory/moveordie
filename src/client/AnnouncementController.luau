local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")

local LocalPlayer = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
local FeedbackConfig = require(Shared:WaitForChild("FeedbackConfig", 10))
local PlayerState = require(Shared:WaitForChild("PlayerState", 10))

local AnnouncementController = {}

type AnnouncementPayload = {
	text: string,
	style: string?,
	priority: number?,
	durationSeconds: number?,
	dedupeKey: string?,
	cooldownSeconds: number?,
	requiresInMatch: boolean?,
	soundId: string?,
	yScale: number?,
	yOffset: number?,
	yPosition: number?,
	effect: string?,
}

type QueuedAnnouncement = AnnouncementPayload & {
	source: string,
	sequence: number,
}

local initialized = false
local announcementRemote: RemoteEvent? = nil
local playerGui: PlayerGui? = nil
local screenGui: ScreenGui? = nil
local announcementLabel: TextLabel? = nil
local announcementStroke: UIStroke? = nil
local queue: { QueuedAnnouncement } = {}
local activeAnnouncement: QueuedAnnouncement? = nil
local recentCooldownsByKey: { [string]: number } = {}
local sequenceCounter = 0
local activeToken = 0
local impactFlashFrame: Frame? = nil
local lastSwordImpactAt = 0

local GUI_NAME = "SwordAnnouncement"
local LABEL_NAME = "AnnouncementLabel"
local FLASH_NAME = "SwordImpactFlash"
local SWORD_IMPACT_DEBOUNCE_SECONDS = 0.25
local SWORD_IMPACT_SOUND_ID = "rbxassetid://12222225"

local function log(message: string)
	print("[AnnouncementController] " .. message)
end

local function isLocalPlayerInMatch(): boolean
	return LocalPlayer:GetAttribute("PlayerState") == PlayerState.States.InMatch
end

local function ensureGui()
	if screenGui and screenGui.Parent and announcementLabel and announcementStroke then
		return
	end

	playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui", 10)
	if not playerGui then
		return
	end

	local existingGui = playerGui:FindFirstChild(GUI_NAME)
	if existingGui and existingGui:IsA("ScreenGui") then
		screenGui = existingGui
	else
		screenGui = Instance.new("ScreenGui")
		screenGui.Name = GUI_NAME
		screenGui.ResetOnSpawn = false
		screenGui.IgnoreGuiInset = true
		screenGui.DisplayOrder = FeedbackConfig.Announcements.DisplayOrder
		screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		screenGui.Parent = playerGui
	end

	local existingLabel = screenGui:FindFirstChild(LABEL_NAME)
	if existingLabel and existingLabel:IsA("TextLabel") then
		announcementLabel = existingLabel
	else
		announcementLabel = Instance.new("TextLabel")
		announcementLabel.Name = LABEL_NAME
		announcementLabel.AnchorPoint = Vector2.new(0.5, 0)
		local yScale = tonumber(FeedbackConfig.Announcements.YScale)
		local yOffset = tonumber(FeedbackConfig.Announcements.YOffset) or 0
		if yScale then
			announcementLabel.Position = UDim2.new(0.5, 0, yScale, yOffset)
		else
			announcementLabel.Position = UDim2.new(0.5, 0, 0, FeedbackConfig.Announcements.YPosition)
		end
		announcementLabel.Size = UDim2.new(1, -40, 0, FeedbackConfig.Announcements.LineHeight)
		announcementLabel.BackgroundTransparency = 1
		announcementLabel.Font = Enum.Font.GothamBold
		announcementLabel.TextSize = FeedbackConfig.Announcements.TextSize
		announcementLabel.TextWrapped = true
		announcementLabel.TextXAlignment = Enum.TextXAlignment.Center
		announcementLabel.TextYAlignment = Enum.TextYAlignment.Center
		announcementLabel.TextTransparency = 1
		announcementLabel.Visible = false
		announcementLabel.Parent = screenGui
	end
	local yScale = tonumber(FeedbackConfig.Announcements.YScale)
	local yOffset = tonumber(FeedbackConfig.Announcements.YOffset) or 0
	if yScale then
		announcementLabel.Position = UDim2.new(0.5, 0, yScale, yOffset)
	else
		announcementLabel.Position = UDim2.new(0.5, 0, 0, FeedbackConfig.Announcements.YPosition)
	end

	local existingStroke = announcementLabel:FindFirstChildOfClass("UIStroke")
	if existingStroke then
		announcementStroke = existingStroke
	else
		announcementStroke = Instance.new("UIStroke")
		announcementStroke.Thickness = 2
		announcementStroke.Transparency = 1
		announcementStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		announcementStroke.Parent = announcementLabel
	end

	local existingFlash = screenGui:FindFirstChild(FLASH_NAME)
	if existingFlash and existingFlash:IsA("Frame") then
		impactFlashFrame = existingFlash
	else
		impactFlashFrame = Instance.new("Frame")
		impactFlashFrame.Name = FLASH_NAME
		impactFlashFrame.Size = UDim2.fromScale(1, 1)
		impactFlashFrame.Position = UDim2.fromScale(0, 0)
		impactFlashFrame.BackgroundColor3 = Color3.new(1, 1, 1)
		impactFlashFrame.BackgroundTransparency = 1
		impactFlashFrame.BorderSizePixel = 0
		impactFlashFrame.ZIndex = 999
		impactFlashFrame.Visible = false
		impactFlashFrame.Parent = screenGui
	end
end

local function playSound(soundId: string?)
	if type(soundId) ~= "string" or soundId == "" then
		return
	end
	if not playerGui then
		return
	end

	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Volume = 0.4
	sound.PlayOnRemove = false
	sound.Parent = playerGui
	sound:Play()
	task.delay(5, function()
		if sound and sound.Parent then
			sound:Destroy()
		end
	end)
end

local function playSwordKillImpact()
	local now = os.clock()
	if (now - lastSwordImpactAt) < SWORD_IMPACT_DEBOUNCE_SECONDS then
		return
	end
	lastSwordImpactAt = now

	if impactFlashFrame then
		impactFlashFrame.Visible = true
		impactFlashFrame.BackgroundTransparency = 0.92
		TweenService:Create(
			impactFlashFrame,
			TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ BackgroundTransparency = 1 }
		):Play()
		task.delay(0.1, function()
			if impactFlashFrame then
				impactFlashFrame.Visible = false
			end
		end)
	end

	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local bumpOut = TweenService:Create(
			humanoid,
			TweenInfo.new(0.05, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
			{ CameraOffset = Vector3.new(0, 0, -0.2) }
		)
		local bumpBack = TweenService:Create(
			humanoid,
			TweenInfo.new(0.1, Enum.EasingStyle.Sine, Enum.EasingDirection.In),
			{ CameraOffset = Vector3.new(0, 0, 0) }
		)
		bumpOut.Completed:Connect(function()
			bumpBack:Play()
		end)
		bumpOut:Play()
	end

	local impactSound = Instance.new("Sound")
	impactSound.SoundId = SWORD_IMPACT_SOUND_ID
	impactSound.Volume = 0.3
	impactSound.Parent = SoundService
	impactSound:Play()
	task.delay(2, function()
		if impactSound and impactSound.Parent then
			impactSound:Destroy()
		end
	end)
end

local function getStyle(styleName: string?): { TextColor: Color3, StrokeColor: Color3 }
	local styles = FeedbackConfig.Announcements.Styles
	local key = if type(styleName) == "string" and styles[styleName] then styleName else "Default"
	return styles[key]
end

local function isDuplicate(entry: QueuedAnnouncement): boolean
	local dedupeKey = type(entry.dedupeKey) == "string" and entry.dedupeKey or ""
	if dedupeKey == "" then
		return false
	end

	local now = os.clock()
	local cooldownExpiry = recentCooldownsByKey[dedupeKey]
	if cooldownExpiry and cooldownExpiry > now then
		log(string.format("announcement_skipped reason=cooldown dedupeKey=%s source=%s", dedupeKey, entry.source))
		return true
	end

	if activeAnnouncement and activeAnnouncement.dedupeKey == dedupeKey then
		log(string.format("announcement_skipped reason=active_duplicate dedupeKey=%s source=%s", dedupeKey, entry.source))
		return true
	end

	for _, queued in ipairs(queue) do
		if queued.dedupeKey == dedupeKey then
			log(string.format("announcement_skipped reason=queued_duplicate dedupeKey=%s source=%s", dedupeKey, entry.source))
			return true
		end
	end

	return false
end

local function sortQueue()
	table.sort(queue, function(a, b)
		local aPriority = tonumber(a.priority) or 0
		local bPriority = tonumber(b.priority) or 0
		if aPriority == bPriority then
			return a.sequence < b.sequence
		end
		return aPriority > bPriority
	end)
end

local function hideActiveAnnouncement(reason: string)
	activeToken += 1
	activeAnnouncement = nil
	if announcementLabel then
		announcementLabel.Visible = false
		announcementLabel.TextTransparency = 1
	end
	if announcementStroke then
		announcementStroke.Transparency = 1
	end
	if reason ~= "" then
		log("announcement_cleared reason=" .. reason)
	end
end

local pumpQueue

local function finishAnnouncement(entry: QueuedAnnouncement, reason: string)
	local dedupeKey = type(entry.dedupeKey) == "string" and entry.dedupeKey or ""
	if dedupeKey ~= "" then
		recentCooldownsByKey[dedupeKey] = os.clock() + math.max(0, tonumber(entry.cooldownSeconds) or FeedbackConfig.Announcements.DefaultCooldownSeconds)
	end
	hideActiveAnnouncement(reason)
	task.delay(FeedbackConfig.Announcements.QueueGapSeconds, function()
		pumpQueue()
	end)
end

local function playAnnouncement(entry: QueuedAnnouncement)
	ensureGui()
	if not announcementLabel or not announcementStroke then
		return
	end

	local fallbackYScale = tonumber(FeedbackConfig.Announcements.YScale)
	local fallbackYOffset = tonumber(FeedbackConfig.Announcements.YOffset) or 0
	local overrideYScale = tonumber(entry.yScale)
	local overrideYOffset = tonumber(entry.yOffset)
	local overrideYPosition = tonumber(entry.yPosition)
	if overrideYScale then
		announcementLabel.Position = UDim2.new(0.5, 0, overrideYScale, overrideYOffset or 0)
	elseif overrideYPosition then
		announcementLabel.Position = UDim2.new(0.5, 0, 0, overrideYPosition)
	elseif fallbackYScale then
		announcementLabel.Position = UDim2.new(0.5, 0, fallbackYScale, fallbackYOffset)
	else
		announcementLabel.Position = UDim2.new(0.5, 0, 0, FeedbackConfig.Announcements.YPosition)
	end

	local style = getStyle(entry.style)
	local displayDuration = math.max(0.5, tonumber(entry.durationSeconds) or FeedbackConfig.Announcements.DisplayDurationSeconds)
	local token = activeToken + 1
	activeToken = token
	activeAnnouncement = entry

	announcementLabel.Text = entry.text
	announcementLabel.TextColor3 = style.TextColor
	announcementStroke.Color = style.StrokeColor
	announcementLabel.TextTransparency = 1
	announcementStroke.Transparency = 1
	announcementLabel.Visible = true

	playSound(entry.soundId)
	if entry.effect == "SwordKillImpact" then
		playSwordKillImpact()
	end

	TweenService:Create(
		announcementLabel,
		TweenInfo.new(FeedbackConfig.Announcements.FadeInSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ TextTransparency = 0 }
	):Play()
	TweenService:Create(
		announcementStroke,
		TweenInfo.new(FeedbackConfig.Announcements.FadeInSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Transparency = 0.3 }
	):Play()

	log(string.format("announcement_shown source=%s style=%s text=%s", entry.source, tostring(entry.style or "Default"), entry.text))

	task.delay(displayDuration, function()
		if activeToken ~= token or activeAnnouncement ~= entry or not announcementLabel or not announcementStroke then
			return
		end

		local fadeOut = TweenService:Create(
			announcementLabel,
			TweenInfo.new(FeedbackConfig.Announcements.FadeOutSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ TextTransparency = 1 }
		)
		local strokeFade = TweenService:Create(
			announcementStroke,
			TweenInfo.new(FeedbackConfig.Announcements.FadeOutSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Transparency = 1 }
		)
		fadeOut:Play()
		strokeFade:Play()
		fadeOut.Completed:Connect(function()
			if activeToken ~= token or activeAnnouncement ~= entry then
				return
			end
			finishAnnouncement(entry, "completed")
		end)
	end)
end

function pumpQueue()
	if activeAnnouncement then
		return
	end

	while #queue > 0 do
		local nextEntry = table.remove(queue, 1)
		if nextEntry.requiresInMatch == true and not isLocalPlayerInMatch() then
			log(string.format("announcement_skipped reason=requires_in_match source=%s text=%s", nextEntry.source, nextEntry.text))
		else
			playAnnouncement(nextEntry)
			return
		end
	end
end

local function purgeMatchOnlyAnnouncements(reason: string)
	local filtered = {}
	for _, entry in ipairs(queue) do
		if entry.requiresInMatch == true then
			log(string.format("announcement_removed_from_queue reason=%s source=%s text=%s", reason, entry.source, entry.text))
		else
			table.insert(filtered, entry)
		end
	end
	queue = filtered
	if activeAnnouncement and activeAnnouncement.requiresInMatch == true then
		hideActiveAnnouncement(reason)
		task.delay(FeedbackConfig.Announcements.QueueGapSeconds, function()
			pumpQueue()
		end)
	end
end

local function normalizePayload(payload: AnnouncementPayload, source: string): QueuedAnnouncement?
	local text = tostring(payload.text or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if text == "" then
		return nil
	end

	sequenceCounter += 1

	return {
		text = text,
		style = payload.style,
		priority = tonumber(payload.priority) or FeedbackConfig.Announcements.Priorities.Quest,
		durationSeconds = tonumber(payload.durationSeconds) or FeedbackConfig.Announcements.DisplayDurationSeconds,
		dedupeKey = payload.dedupeKey,
		cooldownSeconds = tonumber(payload.cooldownSeconds) or FeedbackConfig.Announcements.DefaultCooldownSeconds,
		requiresInMatch = payload.requiresInMatch == true,
		soundId = payload.soundId,
		yScale = tonumber(payload.yScale),
		yOffset = tonumber(payload.yOffset),
		yPosition = tonumber(payload.yPosition),
		effect = type(payload.effect) == "string" and payload.effect or nil,
		source = source,
		sequence = sequenceCounter,
	}
end

local function enqueueAnnouncement(payload: AnnouncementPayload, source: string)
	local entry = normalizePayload(payload, source)
	if not entry then
		return
	end

	if isDuplicate(entry) then
		return
	end

	if #queue >= FeedbackConfig.Announcements.MaxQueued then
		log(string.format("announcement_skipped reason=queue_full source=%s text=%s", source, entry.text))
		return
	end

	table.insert(queue, entry)
	sortQueue()
	log(string.format("announcement_queued source=%s priority=%d text=%s", source, tonumber(entry.priority) or 0, entry.text))
	pumpQueue()
end

function AnnouncementController.QueueLocal(payload: AnnouncementPayload)
	enqueueAnnouncement(payload, "local")
end

function AnnouncementController.QueueImmediate(payload: AnnouncementPayload)
	local entry = normalizePayload(payload, "local_immediate")
	if not entry then
		return
	end
	if isDuplicate(entry) then
		return
	end
	hideActiveAnnouncement("immediate_override")
	table.insert(queue, entry)
	sortQueue()
	pumpQueue()
end

function AnnouncementController.Init()
	if initialized then
		return
	end
	initialized = true

	ensureGui()

	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
		if not remotes then
			warn("[AnnouncementController] Remotes folder not found")
			return
		end

		local remote = remotes:WaitForChild("PlayerAnnouncement", 15)
		if remote and remote:IsA("RemoteEvent") then
			announcementRemote = remote
			announcementRemote.OnClientEvent:Connect(function(payload)
				if type(payload) == "table" then
					enqueueAnnouncement(payload, "server")
				end
			end)
		else
			warn("[AnnouncementController] PlayerAnnouncement remote missing")
		end
	end)

	LocalPlayer:GetAttributeChangedSignal("PlayerState"):Connect(function()
		if not isLocalPlayerInMatch() then
			purgeMatchOnlyAnnouncements("left_match")
		end
	end)

	log("initialized")
end

return AnnouncementController
