local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UIConfig = require(Shared:WaitForChild("UIConfig"))

local UIScalingController = {}

local SCALE_PRESETS = {
	Phone   = 0.78,
	Tablet  = 1.00,
	Desktop = 0.90,
}

local SCALED_GUI_NAMES = {
	HUDGui = true,
	PanelGui = true,
	ModeVoteGui = true,
	ForceNextModeGui = true,
	MatchResultsGui = true,
}

local DAILY_PANEL_NAME = "DAILYREWARDSPanel"

local PHONE_SIDEBAR_SCALE = 0.65
local PHONE_SIDEBAR_TOP_INSET = -16
local PHONE_CELL_H_MULT = 0.88
local PHONE_PAD_Y_MULT = 0.6
local ORIG_CELL_H = 86
local ORIG_PAD_Y = 8

local DESKTOP_SIDEBAR_Y_OFFSET = 75

local PHONE_SIDEBAR_X_SHIFT = 6
local PHONE_COIN_SCALE = 0.55
local PHONE_COIN_Y_SHIFT = -6
local COMPACT_TOP_CENTER_SHORT_SIDE_MAX = 800
local PHONE_ROUND_SCALE = 0.92
local PHONE_STATE_SCALE = 0.90
local PHONE_INTERMISSION_SCALE = 0.82
local DEBUG_LOGS = RunService:IsStudio() and UIConfig.DebugLogs == true

local SWORD_ANNOUNCEMENT_PROFILE = {
	TextSize = 19,
	Height = 34,
	YOffset = 132,
}

local TTS_COUNTDOWN_PROFILE = {
	TextSize = 19,
	Height = 24,
	YOffset = 6,
}

local TTS_ANNOUNCEMENT_PROFILE = {
	TextSize = 19,
	Height = 24,
	YOffset = 176,
}

local Camera = workspace.CurrentCamera
local deviceClass: string = "Desktop"
local trackedScales: { UIScale } = {}
local _sidebarPhoneTuned = false
local _sidebarDesktopOffset = false
local _coinPhoneTuned = false
local _compactTopCenterTuned = false
local _origSidebarBgAlpha: number? = nil
local _origSidebarBgStrokeAlpha: number? = nil
local _origSidebarStudAlpha: number? = nil
local _playerGui: Instance? = nil

local function classify(): string
	local keyboard = UserInputService.KeyboardEnabled
	local touch = UserInputService.TouchEnabled

	if keyboard and not touch then
		return "Desktop"
	end

	if touch then
		local vp = Camera.ViewportSize
		local shortSide = math.min(vp.X, vp.Y)
		if shortSide < 600 then
			return "Phone"
		else
			return "Tablet"
		end
	end

	return "Desktop"
end

local function debugLog(message: string, ...)
	if not DEBUG_LOGS then
		return
	end
	print(string.format(message, ...))
end

local function isCompactTopCenterViewport(): boolean
	if not UserInputService.TouchEnabled then
		return false
	end
	local vp = Camera.ViewportSize
	return math.min(vp.X, vp.Y) <= COMPACT_TOP_CENTER_SHORT_SIDE_MAX
end

local function ensureNamedScale(guiObject: Instance, scaleName: string, scaleValue: number)
	local existing = guiObject:FindFirstChild(scaleName)
	if existing and existing:IsA("UIScale") then
		existing.Scale = scaleValue
		return
	end

	local scale = Instance.new("UIScale")
	scale.Name = scaleName
	scale.Scale = scaleValue
	scale.Parent = guiObject
end

local function removeNamedScale(guiObject: Instance?, scaleName: string)
	if not guiObject then
		return
	end
	local existing = guiObject:FindFirstChild(scaleName)
	if existing and existing:IsA("UIScale") then
		existing:Destroy()
	end
end

local function rememberNumberAttribute(instance: Instance, attributeName: string, value: number)
	if instance:GetAttribute(attributeName) == nil then
		instance:SetAttribute(attributeName, value)
	end
end

local function applyLabelCompactProfile(label: TextLabel, profileKey: string, profile)
	local attrPrefix = "CompactTopCenter" .. profileKey
	rememberNumberAttribute(label, attrPrefix .. "TextSize", label.TextSize)
	rememberNumberAttribute(label, attrPrefix .. "SizeYScale", label.Size.Y.Scale)
	rememberNumberAttribute(label, attrPrefix .. "SizeYOffset", label.Size.Y.Offset)
	rememberNumberAttribute(label, attrPrefix .. "PosYScale", label.Position.Y.Scale)
	rememberNumberAttribute(label, attrPrefix .. "PosYOffset", label.Position.Y.Offset)

	label.TextSize = profile.TextSize
	label.Size = UDim2.new(label.Size.X.Scale, label.Size.X.Offset, label.Size.Y.Scale, profile.Height)
	label.Position = UDim2.new(label.Position.X.Scale, label.Position.X.Offset, label.Position.Y.Scale, profile.YOffset)
end

local function restoreLabelCompactProfile(label: TextLabel, profileKey: string)
	local attrPrefix = "CompactTopCenter" .. profileKey
	local textSize = label:GetAttribute(attrPrefix .. "TextSize")
	local sizeYScale = label:GetAttribute(attrPrefix .. "SizeYScale")
	local sizeYOffset = label:GetAttribute(attrPrefix .. "SizeYOffset")
	local posYScale = label:GetAttribute(attrPrefix .. "PosYScale")
	local posYOffset = label:GetAttribute(attrPrefix .. "PosYOffset")

	if typeof(textSize) == "number" then
		label.TextSize = textSize
	end
	if typeof(sizeYScale) == "number" and typeof(sizeYOffset) == "number" then
		label.Size = UDim2.new(label.Size.X.Scale, label.Size.X.Offset, sizeYScale, sizeYOffset)
	end
	if typeof(posYScale) == "number" and typeof(posYOffset) == "number" then
		label.Position = UDim2.new(label.Position.X.Scale, label.Position.X.Offset, posYScale, posYOffset)
	end
end

local function trackGui(screenGui: ScreenGui)
	local existing = screenGui:FindFirstChild("ResponsiveScale")
	if existing and existing:IsA("UIScale") then
		for _, s in ipairs(trackedScales) do
			if s == existing then return end
		end
		table.insert(trackedScales, existing)
		existing.Scale = SCALE_PRESETS[deviceClass] or 1
		print(string.format("[UIScaling] Tracked existing GUI: %s (scale=%.2f)", screenGui.Name, existing.Scale))
		return
	end

	local s = Instance.new("UIScale")
	s.Name = "ResponsiveScale"
	s.Scale = SCALE_PRESETS[deviceClass] or 1
	s.Parent = screenGui
	table.insert(trackedScales, s)
	print(string.format("[UIScaling] Tracked new GUI: %s (scale=%.2f)", screenGui.Name, s.Scale))
end

local function applyScale()
	local newClass = classify()
	local vp = Camera.ViewportSize
	local changed = newClass ~= deviceClass
	deviceClass = newClass

	local scale = SCALE_PRESETS[deviceClass] or 1
	for _, uiScale in ipairs(trackedScales) do
		if uiScale and uiScale.Parent then
			uiScale.Scale = scale
		end
	end

	if changed then
		print(string.format(
			"[UI] DeviceClass = %s (viewport %dx%d) scale=%.2f",
			deviceClass, math.floor(vp.X), math.floor(vp.Y), scale
		))
	end
end

local function applyPhonePopupClamp(panel: GuiObject, maxWFrac: number, maxHFrac: number)
	if panel:FindFirstChild("PhoneSizeConstraint") then return end
	local vp = Camera.ViewportSize
	local scale = SCALE_PRESETS.Phone or 0.78
	local maxW = math.floor(vp.X * maxWFrac / scale)
	local maxH = math.floor(vp.Y * maxHFrac / scale)
	local constraint = Instance.new("UISizeConstraint")
	constraint.Name = "PhoneSizeConstraint"
	constraint.MaxSize = Vector2.new(maxW, maxH)
	constraint.Parent = panel
end

local function removePhoneClamp(panel: GuiObject)
	local existing = panel and panel:FindFirstChild("PhoneSizeConstraint")
	if existing then existing:Destroy() end
end

local function applyDailyRewardsPhoneConstraint()
	if deviceClass ~= "Phone" then return end
	if not _playerGui then return end
	local panelGui = _playerGui:FindFirstChild("PanelGui")
	if not panelGui then return end
	local dailyPanel = panelGui:FindFirstChild(DAILY_PANEL_NAME)
	if not dailyPanel then return end

	applyPhonePopupClamp(dailyPanel, 0.85, 0.80)

	for _, desc in ipairs(dailyPanel:GetDescendants()) do
		if desc.Name == "CardsArea" and desc:IsA("Frame") then
			desc.ClipsDescendants = true
			break
		end
	end

	print("[UI] DailyRewards applied phone constraints")
end

local function removeDailyRewardsPhoneConstraint()
	if not _playerGui then return end
	local panelGui = _playerGui:FindFirstChild("PanelGui")
	if not panelGui then return end
	local dailyPanel = panelGui:FindFirstChild(DAILY_PANEL_NAME)
	if not dailyPanel then return end
	removePhoneClamp(dailyPanel)
end

local function applyModeVotePhoneClamp()
	if deviceClass ~= "Phone" then return end
	if not _playerGui then return end
	local mvGui = _playerGui:FindFirstChild("ModeVoteGui")
	if not mvGui then return end
	local votePanel = mvGui:FindFirstChild("VotePanel")
	if not votePanel then return end
	applyPhonePopupClamp(votePanel, 0.85, 0.80)
	print("[UI] ModeVotePanel applied phone constraints")
end

local function removeModeVotePhoneClamp()
	if not _playerGui then return end
	local mvGui = _playerGui:FindFirstChild("ModeVoteGui")
	if not mvGui then return end
	local votePanel = mvGui:FindFirstChild("VotePanel")
	if votePanel then removePhoneClamp(votePanel) end
end

local function applyForceNextModePhoneClamp()
	if deviceClass ~= "Phone" then return end
	if not _playerGui then return end
	local forceGui = _playerGui:FindFirstChild("ForceNextModeGui")
	if not forceGui then return end
	local forcePanel = forceGui:FindFirstChild("ForceNextModePanel")
	if not forcePanel then return end
	applyPhonePopupClamp(forcePanel, 0.88, 0.82)
	print("[UI] ForceNextModePanel applied phone constraints")
end

local function removeForceNextModePhoneClamp()
	if not _playerGui then return end
	local forceGui = _playerGui:FindFirstChild("ForceNextModeGui")
	if not forceGui then return end
	local forcePanel = forceGui:FindFirstChild("ForceNextModePanel")
	if forcePanel then removePhoneClamp(forcePanel) end
end

local function applyLeftStackPhoneTuning()
	if _sidebarPhoneTuned then return end

	local playerGui = Players.LocalPlayer and Players.LocalPlayer:FindFirstChild("PlayerGui")
	if not playerGui then return end
	local hudGui = playerGui:FindFirstChild("HUDGui")
	if not hudGui then return end

	local sidebarBg = hudGui:FindFirstChild("SidebarBg")
	local sidebar = hudGui:FindFirstChild("Sidebar")
	if not sidebarBg and not sidebar then return end

	if sidebarBg and not sidebarBg:FindFirstChild("PhoneSidebarScale") then
		local s = Instance.new("UIScale")
		s.Name = "PhoneSidebarScale"
		s.Scale = PHONE_SIDEBAR_SCALE
		s.Parent = sidebarBg

		local p = sidebarBg.Position
		sidebarBg.Position = UDim2.new(p.X.Scale, p.X.Offset + PHONE_SIDEBAR_X_SHIFT, p.Y.Scale, p.Y.Offset + PHONE_SIDEBAR_TOP_INSET)

		_origSidebarBgAlpha = sidebarBg.BackgroundTransparency
		sidebarBg.BackgroundTransparency = 1
		local bgStroke = sidebarBg:FindFirstChildWhichIsA("UIStroke")
		if bgStroke then
			_origSidebarBgStrokeAlpha = bgStroke.Transparency
			bgStroke.Transparency = 1
		end
		local bgStud = sidebarBg:FindFirstChild("StudTexture")
		if bgStud and bgStud:IsA("ImageLabel") then
			_origSidebarStudAlpha = bgStud.ImageTransparency
			bgStud.ImageTransparency = 1
		end
	end

	if sidebar and not sidebar:FindFirstChild("PhoneSidebarScale") then
		local s = Instance.new("UIScale")
		s.Name = "PhoneSidebarScale"
		s.Scale = PHONE_SIDEBAR_SCALE
		s.Parent = sidebar

		local p = sidebar.Position
		sidebar.Position = UDim2.new(p.X.Scale, p.X.Offset + PHONE_SIDEBAR_X_SHIFT, p.Y.Scale, p.Y.Offset + PHONE_SIDEBAR_TOP_INSET)

		local grid = sidebar:FindFirstChildWhichIsA("UIGridLayout")
		if grid then
			local cellX = grid.CellSize.X.Offset
			local padX = grid.CellPadding.X.Offset
			grid.CellSize = UDim2.fromOffset(cellX, math.floor(ORIG_CELL_H * PHONE_CELL_H_MULT))
			grid.CellPadding = UDim2.fromOffset(padX, math.max(3, math.floor(ORIG_PAD_Y * PHONE_PAD_Y_MULT)))
		end
	end

	_sidebarPhoneTuned = true

	local eff = (SCALE_PRESETS.Phone or 0.78) * PHONE_SIDEBAR_SCALE
	print(string.format(
		"[UI] DeviceClass=Phone -> applying LeftStack phone tuning (sidebarScale=%.2f, inset=%d, effective=%.2f)",
		PHONE_SIDEBAR_SCALE, PHONE_SIDEBAR_TOP_INSET, eff
	))
end

local function removeLeftStackPhoneTuning()
	if not _sidebarPhoneTuned then return end

	local playerGui = Players.LocalPlayer and Players.LocalPlayer:FindFirstChild("PlayerGui")
	if not playerGui then return end
	local hudGui = playerGui:FindFirstChild("HUDGui")
	if not hudGui then return end

	for _, name in ipairs({"SidebarBg", "Sidebar"}) do
		local frame = hudGui:FindFirstChild(name)
		if frame then
			local ps = frame:FindFirstChild("PhoneSidebarScale")
			if ps then ps:Destroy() end

			local p = frame.Position
			frame.Position = UDim2.new(p.X.Scale, p.X.Offset - PHONE_SIDEBAR_X_SHIFT, p.Y.Scale, p.Y.Offset - PHONE_SIDEBAR_TOP_INSET)
		end
	end

	local sidebarBg = hudGui:FindFirstChild("SidebarBg")
	if sidebarBg then
		if _origSidebarBgAlpha ~= nil then
			sidebarBg.BackgroundTransparency = _origSidebarBgAlpha
			_origSidebarBgAlpha = nil
		end
		local bgStroke = sidebarBg:FindFirstChildWhichIsA("UIStroke")
		if bgStroke and _origSidebarBgStrokeAlpha ~= nil then
			bgStroke.Transparency = _origSidebarBgStrokeAlpha
			_origSidebarBgStrokeAlpha = nil
		end
		local bgStud = sidebarBg:FindFirstChild("StudTexture")
		if bgStud and bgStud:IsA("ImageLabel") and _origSidebarStudAlpha ~= nil then
			bgStud.ImageTransparency = _origSidebarStudAlpha
			_origSidebarStudAlpha = nil
		end
	end

	local sidebar = hudGui:FindFirstChild("Sidebar")
	if sidebar then
		local grid = sidebar:FindFirstChildWhichIsA("UIGridLayout")
		if grid then
			grid.CellSize = UDim2.fromOffset(86, ORIG_CELL_H)
			grid.CellPadding = UDim2.fromOffset(8, ORIG_PAD_Y)
		end
	end

	_sidebarPhoneTuned = false
end

local function applyDesktopLeftStackOffset()
	if _sidebarDesktopOffset then return end
	if not _playerGui then return end
	local hudGui = _playerGui:FindFirstChild("HUDGui")
	if not hudGui then return end

	for _, name in ipairs({"SidebarBg", "Sidebar"}) do
		local frame = hudGui:FindFirstChild(name)
		if frame then
			local p = frame.Position
			frame.Position = UDim2.new(p.X.Scale, p.X.Offset, p.Y.Scale, p.Y.Offset + DESKTOP_SIDEBAR_Y_OFFSET)
		end
	end

	_sidebarDesktopOffset = true
	print(string.format("[UI] Desktop detected -> applying LeftStack Y offset (+%dpx)", DESKTOP_SIDEBAR_Y_OFFSET))
end

local function removeDesktopLeftStackOffset()
	if not _sidebarDesktopOffset then return end
	if not _playerGui then return end
	local hudGui = _playerGui:FindFirstChild("HUDGui")
	if not hudGui then return end

	for _, name in ipairs({"SidebarBg", "Sidebar"}) do
		local frame = hudGui:FindFirstChild(name)
		if frame then
			local p = frame.Position
			frame.Position = UDim2.new(p.X.Scale, p.X.Offset, p.Y.Scale, p.Y.Offset - DESKTOP_SIDEBAR_Y_OFFSET)
		end
	end

	_sidebarDesktopOffset = false
end

local function applyCompactTopCenterHudTuning()
	if not _playerGui then return end
	local hudGui = _playerGui:FindFirstChild("HUDGui")
	if not hudGui then return end

	local roundFrame = hudGui:FindFirstChild("RoundFrame")
	if roundFrame then
		ensureNamedScale(roundFrame, "PhoneRoundScale", PHONE_ROUND_SCALE)
	end

	local stateLabel = hudGui:FindFirstChild("StateLabel")
	if stateLabel then
		ensureNamedScale(stateLabel, "PhoneStateScale", PHONE_STATE_SCALE)
	end

	local bar = hudGui:FindFirstChild("IntermissionBar")
	if bar then
		ensureNamedScale(bar, "PhoneIntermissionScale", PHONE_INTERMISSION_SCALE)
	end
end

local function removeCompactTopCenterHudTuning()
	if not _playerGui then return end
	local hudGui = _playerGui:FindFirstChild("HUDGui")
	if not hudGui then return end

	removeNamedScale(hudGui:FindFirstChild("RoundFrame"), "PhoneRoundScale")
	removeNamedScale(hudGui:FindFirstChild("StateLabel"), "PhoneStateScale")
	removeNamedScale(hudGui:FindFirstChild("IntermissionBar"), "PhoneIntermissionScale")
end

local function applyRuntimeBannerTuning(screenGui: ScreenGui)
	if screenGui.Name == "SwordAnnouncement" then
		local label = screenGui:FindFirstChild("AnnouncementLabel")
		if label and label:IsA("TextLabel") then
			applyLabelCompactProfile(label, "SwordAnnouncement", SWORD_ANNOUNCEMENT_PROFILE)
		end
	elseif screenGui.Name == "TungTungStatusStack" then
		local countdown = screenGui:FindFirstChild("CountdownText")
		if countdown and countdown:IsA("TextLabel") then
			applyLabelCompactProfile(countdown, "TTSCountdown", TTS_COUNTDOWN_PROFILE)
		end

		local announce = screenGui:FindFirstChild("AnnounceText")
		if announce and announce:IsA("TextLabel") then
			applyLabelCompactProfile(announce, "TTSAnnouncement", TTS_ANNOUNCEMENT_PROFILE)
		end
	end
end

local function removeRuntimeBannerTuning(screenGui: ScreenGui)
	if screenGui.Name == "SwordAnnouncement" then
		local label = screenGui:FindFirstChild("AnnouncementLabel")
		if label and label:IsA("TextLabel") then
			restoreLabelCompactProfile(label, "SwordAnnouncement")
		end
	elseif screenGui.Name == "TungTungStatusStack" then
		local countdown = screenGui:FindFirstChild("CountdownText")
		if countdown and countdown:IsA("TextLabel") then
			restoreLabelCompactProfile(countdown, "TTSCountdown")
		end

		local announce = screenGui:FindFirstChild("AnnounceText")
		if announce and announce:IsA("TextLabel") then
			restoreLabelCompactProfile(announce, "TTSAnnouncement")
		end
	end
end

local function applyCompactTopCenterRuntimeTuning()
	if not _playerGui then return end
	for _, guiName in ipairs({"SwordAnnouncement", "TungTungStatusStack"}) do
		local screenGui = _playerGui:FindFirstChild(guiName)
		if screenGui and screenGui:IsA("ScreenGui") then
			applyRuntimeBannerTuning(screenGui)
		end
	end
end

local function removeCompactTopCenterRuntimeTuning()
	if not _playerGui then return end
	for _, guiName in ipairs({"SwordAnnouncement", "TungTungStatusStack"}) do
		local screenGui = _playerGui:FindFirstChild(guiName)
		if screenGui and screenGui:IsA("ScreenGui") then
			removeRuntimeBannerTuning(screenGui)
		end
	end
end

local function applyCompactTopCenterTuning()
	if not _playerGui then
		return
	end

	applyCompactTopCenterHudTuning()
	applyCompactTopCenterRuntimeTuning()

	if not _compactTopCenterTuned then
		_compactTopCenterTuned = true
		local vp = Camera.ViewportSize
		debugLog(
			"[UI] CompactTopCenterProfile applied viewport=%dx%d roundScale=%.2f stateScale=%.2f intermissionScale=%.2f",
			math.floor(vp.X),
			math.floor(vp.Y),
			PHONE_ROUND_SCALE,
			PHONE_STATE_SCALE,
			PHONE_INTERMISSION_SCALE
		)
	end
end

local function removeCompactTopCenterTuning()
	if not _playerGui then
		return
	end

	removeCompactTopCenterHudTuning()
	removeCompactTopCenterRuntimeTuning()
	_compactTopCenterTuned = false
end

local function refreshCompactTopCenterTuning()
	if isCompactTopCenterViewport() then
		applyCompactTopCenterTuning()
	else
		removeCompactTopCenterTuning()
	end
end

local function applyCoinFramePhoneTuning()
	if _coinPhoneTuned then return end
	if not _playerGui then return end
	local hudGui = _playerGui:FindFirstChild("HUDGui")
	if not hudGui then return end
	local coinFrame = hudGui:FindFirstChild("CoinFrame")
	if not coinFrame then return end

	if not coinFrame:FindFirstChild("PhoneCoinScale") then
		local s = Instance.new("UIScale")
		s.Name = "PhoneCoinScale"
		s.Scale = PHONE_COIN_SCALE
		s.Parent = coinFrame
	end

	local shadow = coinFrame:FindFirstChild("Shadow")
	if shadow then
		shadow.Size = UDim2.new(1, 4, 1, 4)
	end

	local p = coinFrame.Position
	coinFrame.Position = UDim2.new(p.X.Scale, p.X.Offset, p.Y.Scale, p.Y.Offset + PHONE_COIN_Y_SHIFT)

	_coinPhoneTuned = true
	print(string.format("[UI] Phone -> CoinFrame scaled to %.2f, Y shifted %d, shadow shrunk", PHONE_COIN_SCALE, PHONE_COIN_Y_SHIFT))
end

local function removeCoinFramePhoneTuning()
	if not _coinPhoneTuned then return end
	if not _playerGui then return end
	local hudGui = _playerGui:FindFirstChild("HUDGui")
	if not hudGui then return end
	local coinFrame = hudGui:FindFirstChild("CoinFrame")
	if coinFrame then
		local ps = coinFrame:FindFirstChild("PhoneCoinScale")
		if ps then ps:Destroy() end
		local shadow = coinFrame:FindFirstChild("Shadow")
		if shadow then
			shadow.Size = UDim2.new(1, 12, 1, 12)
		end
		local p = coinFrame.Position
		coinFrame.Position = UDim2.new(p.X.Scale, p.X.Offset, p.Y.Scale, p.Y.Offset - PHONE_COIN_Y_SHIFT)
	end
	_coinPhoneTuned = false
end

local function applyPhoneTuning()
	applyLeftStackPhoneTuning()
	applyDailyRewardsPhoneConstraint()
	applyModeVotePhoneClamp()
	applyForceNextModePhoneClamp()
	applyCoinFramePhoneTuning()
end

local function removePhoneTuning()
	removeLeftStackPhoneTuning()
	removeDailyRewardsPhoneConstraint()
	removeModeVotePhoneClamp()
	removeForceNextModePhoneClamp()
	removeCoinFramePhoneTuning()
end

local function onViewportChanged()
	applyScale()
	if deviceClass == "Desktop" then
		removePhoneTuning()
		applyDesktopLeftStackOffset()
	elseif deviceClass == "Phone" then
		removeDesktopLeftStackOffset()
		applyPhoneTuning()
	else
		removeDesktopLeftStackOffset()
		removePhoneTuning()
		print("[UI] Tablet -> no LeftStack offset applied")
	end
	refreshCompactTopCenterTuning()
end

local function runUIAudit()
	if not _playerGui then return end

	local auditTargets = {
		{ name = "DailyRewards",  guiName = "PanelGui",         frameName = DAILY_PANEL_NAME },
		{ name = "ModeVote",      guiName = "ModeVoteGui",      frameName = "VotePanel" },
		{ name = "ForceNextMode", guiName = "ForceNextModeGui", frameName = "ForceNextModePanel" },
		{ name = "PremiumShop",   guiName = "PanelGui",         frameName = "PREMIUMSHOPPanel" },
		{ name = "FateCrowns",    guiName = "PanelGui",         frameName = "FATECROWNSPanel" },
		{ name = "MatchResults",  guiName = "MatchResultsGui",  frameName = "ResultsPanel" },
		{ name = "RewardPopup",   guiName = "RewardPopupGui",   frameName = "RewardFrame" },
		{ name = "BrainrotPopup", guiName = "BrainrotPickupGui",frameName = "PopupFrame" },
	}

	for _, target in ipairs(auditTargets) do
		local gui = _playerGui:FindFirstChild(target.guiName)
		local frame = gui and gui:FindFirstChild(target.frameName)
		local scaleCount = 0
		local hasAspect = false

		if gui then
			for _, d in ipairs(gui:GetDescendants()) do
				if d:IsA("UIScale") then scaleCount += 1 end
				if d:IsA("UIAspectRatioConstraint") then hasAspect = true end
			end
		end

		local path = "NOT_FOUND"
		if frame then
			path = frame:GetFullName()
		elseif gui then
			path = gui:GetFullName() .. ".<" .. target.frameName .. " missing>"
		end

		print(string.format(
			"[UIAudit] %s path=%s | UIScales=%d | HasAspect=%s",
			target.name, path, scaleCount, tostring(hasAspect)
		))
	end
end

function UIScalingController.Init()
	local playerGui = Players.LocalPlayer and Players.LocalPlayer:WaitForChild("PlayerGui", 10)
	if not playerGui then
		warn("[UI] PlayerGui not found -- scaling disabled")
		return
	end
	_playerGui = playerGui

	for _, child in ipairs(playerGui:GetChildren()) do
		if child:IsA("ScreenGui") and SCALED_GUI_NAMES[child.Name] then
			trackGui(child)
		end
	end

	playerGui.ChildAdded:Connect(function(child)
		if not child:IsA("ScreenGui") then
			return
		end

		if SCALED_GUI_NAMES[child.Name] then
			trackGui(child)
			if deviceClass == "Phone" then
				task.defer(function()
					applyModeVotePhoneClamp()
					applyForceNextModePhoneClamp()
				end)
			end
		end

		task.defer(refreshCompactTopCenterTuning)
	end)

	if #trackedScales == 0 then
		warn("[UI] No ResponsiveScale instances found -- scaling disabled")
		return
	end

	applyScale()

	local vp = Camera.ViewportSize
	print(string.format(
		"[UI] DeviceClass = %s (viewport %dx%d) scale=%.2f  tracked=%d",
		deviceClass, math.floor(vp.X), math.floor(vp.Y),
		SCALE_PRESETS[deviceClass] or 1, #trackedScales
	))

	if deviceClass == "Desktop" then
		applyDesktopLeftStackOffset()
	elseif deviceClass == "Phone" then
		applyPhoneTuning()
	else
		print("[UI] Tablet -> no LeftStack offset applied")
	end
	refreshCompactTopCenterTuning()

	runUIAudit()

	Camera:GetPropertyChangedSignal("ViewportSize"):Connect(onViewportChanged)
end

function UIScalingController.GetDeviceClass(): string
	return deviceClass
end

return UIScalingController
