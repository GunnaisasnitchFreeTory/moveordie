local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
local FeedbackConfig = require(Shared:WaitForChild("FeedbackConfig", 10))
local PlayerData = require(Shared:WaitForChild("PlayerData", 10))
local AnnouncementController = require(script.Parent:WaitForChild("AnnouncementController"))

local CrownUnlockReminderController = {}

local initialized = false
local knownOwnedCrowns: { [string]: boolean } = {}
local pendingByCrownId: { [string]: { unlockedAt: number } } = {}
local lastViewedAt = -math.huge

local CROWNS_PANEL_OPEN_ATTR = "CrownsPanelOpen"
local CROWNS_PANEL_VIEWED_TOKEN_ATTR = "CrownsPanelViewedToken"
local REMINDER_DELAY_SECONDS = 6

local function log(message: string)
	print("[CrownUnlockReminder] " .. message)
end

local function decodeOwnedCrowns(): { [string]: boolean }
	local raw = LocalPlayer:GetAttribute(PlayerData.Attributes.OwnedCrowns)
	if type(raw) ~= "string" or raw == "" then
		return {}
	end

	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
	if not ok or type(decoded) ~= "table" then
		return {}
	end

	local set = {}
	for _, id in ipairs(decoded) do
		if type(id) == "string" and id ~= "" then
			set[id] = true
		end
	end
	return set
end

local function isCrownsPanelOpen(): boolean
	return LocalPlayer:GetAttribute(CROWNS_PANEL_OPEN_ATTR) == true
end

local function markViewed(reason: string)
	lastViewedAt = os.clock()
	for crownId, entry in pairs(pendingByCrownId) do
		if entry.unlockedAt <= lastViewedAt then
			pendingByCrownId[crownId] = nil
		end
	end
	log("crowns_ui_checked reason=" .. reason)
end

local function queueReminderIfStillPending(crownId: string, unlockedAt: number)
	task.delay(REMINDER_DELAY_SECONDS, function()
		local pending = pendingByCrownId[crownId]
		if not pending then
			return
		end
		if pending.unlockedAt ~= unlockedAt then
			return
		end
		if lastViewedAt >= unlockedAt then
			pendingByCrownId[crownId] = nil
			return
		end
		if isCrownsPanelOpen() then
			pendingByCrownId[crownId] = nil
			return
		end

		AnnouncementController.QueueLocal({
			text = "You've unlocked a crown! Check the Crowns UI.",
			style = "Tip",
			priority = FeedbackConfig.Announcements.Priorities.Tip,
			durationSeconds = FeedbackConfig.Announcements.TipDisplayDurationSeconds,
			dedupeKey = "crown_unchecked_unlock:" .. crownId,
			cooldownSeconds = 5,
			requiresInMatch = false,
		})
		log("reminder_queued crownId=" .. crownId)
		pendingByCrownId[crownId] = nil
	end)
end

local function processOwnedCrownsChange(reason: string)
	local currentSet = decodeOwnedCrowns()
	local now = os.clock()

	for crownId in pairs(currentSet) do
		if not knownOwnedCrowns[crownId] then
			if isCrownsPanelOpen() then
				log("unlock_detected crownId=" .. crownId .. " checked_immediately=true reason=" .. reason)
			else
				pendingByCrownId[crownId] = { unlockedAt = now }
				log("unlock_detected crownId=" .. crownId .. " checked_immediately=false reason=" .. reason)
				queueReminderIfStillPending(crownId, now)
			end
		end
	end

	knownOwnedCrowns = currentSet
end

function CrownUnlockReminderController.Init()
	if initialized then
		return
	end
	initialized = true

	AnnouncementController.Init()
	knownOwnedCrowns = decodeOwnedCrowns()
	if isCrownsPanelOpen() then
		markViewed("init_open")
	end

	LocalPlayer:GetAttributeChangedSignal(PlayerData.Attributes.OwnedCrowns):Connect(function()
		processOwnedCrownsChange("owned_crowns_changed")
	end)
	LocalPlayer:GetAttributeChangedSignal(CROWNS_PANEL_VIEWED_TOKEN_ATTR):Connect(function()
		markViewed("viewed_token")
	end)
	LocalPlayer:GetAttributeChangedSignal(CROWNS_PANEL_OPEN_ATTR):Connect(function()
		if isCrownsPanelOpen() then
			markViewed("panel_opened")
		end
	end)

	log("initialized")
end

return CrownUnlockReminderController
