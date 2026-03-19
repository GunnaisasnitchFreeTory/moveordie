--[[
	Client entry point — Fate Beams
	Initializes all client-side controllers.
	Each require is wrapped in pcall so one failing controller
	does not break the others.

	Boot order:
	  0. game.Loaded
	  1. ClientDepsProvider.WaitUntilReady(5) — one signal for all deps
	  2. SpectateController
	  3. StormFXController
	  4. UIController (panels use cached deps — instant)
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui        = game:GetService("StarterGui")
local TweenService      = game:GetService("TweenService")
local Client = script

local _bootTime = tick()
local function ts() return string.format("%.3f", tick() - _bootTime) end

print(string.format("[UIBoot] t=%s Client init starting", ts()))

-- ── LOADING SCREEN ────────────────────────────────────────────────────────────
-- Must be created BEFORE any yields so it covers the frame-1 flash caused by
-- StarterGui elements (SpinWheelGuiScripts buttons etc.) that appear before
-- UIController finishes building the HUD.
local _loadGui = Instance.new("ScreenGui")
_loadGui.Name            = "LoadingScreen"
_loadGui.ResetOnSpawn    = false
_loadGui.IgnoreGuiInset  = true
_loadGui.DisplayOrder    = 10000
_loadGui.ZIndexBehavior  = Enum.ZIndexBehavior.Sibling
_loadGui.Parent          = Players.LocalPlayer:WaitForChild("PlayerGui")

local _loadBg = Instance.new("Frame")
_loadBg.Size                  = UDim2.fromScale(1, 1)
_loadBg.BackgroundColor3      = Color3.new(0, 0, 0)
_loadBg.BackgroundTransparency = 0
_loadBg.BorderSizePixel       = 0
_loadBg.ZIndex                = 1
_loadBg.Parent                = _loadGui

local function logBlackScreenDiagnostics(context: string)
	local Lighting = game:GetService("Lighting")
	local playerGui = Players.LocalPlayer and Players.LocalPlayer:FindFirstChild("PlayerGui")
	if not playerGui then
		warn(string.format("[BlackScreenDebug] context=%s playerGui=missing", context))
		return
	end

	local foundBlackFullscreen = false
	for _, gui in ipairs(playerGui:GetChildren()) do
		if gui:IsA("ScreenGui") and gui.Enabled ~= false then
			for _, desc in ipairs(gui:GetDescendants()) do
				if desc:IsA("Frame") and desc.Visible ~= false then
					local full = desc.Size.X.Scale >= 1 and desc.Size.Y.Scale >= 1
					local black = desc.BackgroundTransparency <= 0.05 and desc.BackgroundColor3 == Color3.new(0, 0, 0)
					if full and black then
						foundBlackFullscreen = true
						warn(string.format(
							"[BlackScreenDebug] context=%s fullscreenBlack=true gui=%s frame=%s zIndex=%d script=Client/init.client.luau(LoadingScreen)",
							context,
							gui.Name,
							desc.Name,
							desc.ZIndex
						))
					end
				end
			end
		end
	end
	if not foundBlackFullscreen then
		print(string.format("[BlackScreenDebug] context=%s fullscreenBlack=false", context))
	end

	local cc = Lighting:FindFirstChild("StormFX_CC")
	local bloom = Lighting:FindFirstChild("StormFX_Bloom")
	print(string.format(
		"[BlackScreenDebug] context=%s stormCCEnabled=%s stormBloomEnabled=%s stormProfile=%s presentation=%s",
		context,
		tostring(cc and cc:IsA("ColorCorrectionEffect") and cc.Enabled or false),
		tostring(bloom and bloom:IsA("BloomEffect") and bloom.Enabled or false),
		tostring(Lighting:GetAttribute("StormVfxProfile")),
		tostring(Lighting:GetAttribute("BarrierPresentationProfile"))
	))
end

local function dismissLoadingScreen()
	print(string.format("[BlackScreenDebug] context=DismissLoadingScreen action=fade_out source=Client/init.client.luau"))
	TweenService:Create(_loadBg, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		BackgroundTransparency = 1,
	}):Play()
	task.delay(0.4, function()
		if _loadGui and _loadGui.Parent then
			_loadGui:Destroy()
		end
		logBlackScreenDiagnostics("PostDismiss")
	end)
end

local function logFinalRemoteContents()
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		warn("[RemoteBootstrapClient] final remotes folder missing")
		return
	end

	local remoteNames = {}
	for _, child in ipairs(remotes:GetChildren()) do
		table.insert(remoteNames, string.format("%s:%s", child.Name, child.ClassName))
	end
	table.sort(remoteNames)

	local matchStatus = ReplicatedStorage:FindFirstChild("MatchStatus")
	local matchStatusNames = {}
	if matchStatus then
		for _, child in ipairs(matchStatus:GetChildren()) do
			table.insert(matchStatusNames, string.format("%s:%s", child.Name, child.ClassName))
		end
		table.sort(matchStatusNames)
	end

	print(string.format(
		"[RemoteBootstrapClient] final remotes count=%d contents=%s matchStatusExists=%s matchStatusChildren=%s",
		#remoteNames,
		table.concat(remoteNames, ", "),
		tostring(matchStatus ~= nil),
		(#matchStatusNames > 0 and table.concat(matchStatusNames, ", ")) or "(none)"
	))
end
-- ─────────────────────────────────────────────────────────────────────────────

-- 0. Wait for game to load (assets replicated)
if not game:IsLoaded() then
	game.Loaded:Wait()
end
print(string.format("[UIBoot] t=%s Loaded", ts()))

local function disableRespawnButton()
	for _ = 1, 20 do
		local ok = pcall(function()
			StarterGui:SetCore("ResetButtonCallback", false)
		end)
		if ok then
			print("[Client] Reset/Respawn button disabled")
			return
		end
		task.wait(0.25)
	end
	warn("[Client] Failed to disable Reset/Respawn button after retries")
end

disableRespawnButton()
Players.LocalPlayer.CharacterAdded:Connect(function()
	task.defer(disableRespawnButton)
end)

-- 0b. Pre-load ClientDepsProvider (populates shared deps once for all panels)
local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
if Shared then
	local cdpMod = Shared:FindFirstChild("ClientDepsProvider")
	if cdpMod then
		local cdpOk, CDP = pcall(require, cdpMod)
		if cdpOk and CDP and CDP.WaitUntilReady then
			local depsOk = CDP.WaitUntilReady(5)
			print(string.format("[UIBoot] t=%s DepsReady=%s", ts(), tostring(depsOk)))
		else
			warn(string.format("[UIBoot] t=%s ClientDepsProvider require failed: %s", ts(), tostring(CDP)))
		end
	else
		warn(string.format("[UIBoot] t=%s ClientDepsProvider not in Shared", ts()))
	end
else
	warn(string.format("[UIBoot] t=%s Shared folder not found", ts()))
end

-- 1. SpectateController (self-executing on require)
local spectateOk, spectateErr = pcall(function()
	require(Client:WaitForChild("SpectateController"))
end)
if spectateOk then
	print("[Client] SpectateController loaded OK")
else
	warn("[Client] SpectateController FAILED:", spectateErr)
end

-- 2. StormFXController (has Init method)
local stormOk, stormErr = pcall(function()
	local StormFXController = require(Client:WaitForChild("StormFXController"))
	StormFXController.Init()
end)
if stormOk then
	print("[Client] StormFXController loaded OK")
else
	warn("[Client] StormFXController FAILED:", stormErr)
end

-- 3. UIController (has Init method — panels use cached deps)
-- CloudLayerController
local cloudOk, cloudErr = pcall(function()
	local CloudLayerController = require(Client:WaitForChild("CloudLayerController"))
	CloudLayerController.Init()
end)
if cloudOk then
	print("[Client] CloudLayerController loaded OK")
else
	warn("[Client] CloudLayerController FAILED:", cloudErr)
end

-- UIController
local uiOk, uiErr = pcall(function()
	local UIController = require(Client:WaitForChild("UIController"))
	UIController.Init()
end)
if uiOk then
	print(string.format("[UIBoot] t=%s UIController READY", ts()))
else
	warn(string.format("[UIBoot] t=%s UIController FAILED: %s", ts(), tostring(uiErr)))
end

local announcementOk, announcementErr = pcall(function()
	local AnnouncementController = require(Client:WaitForChild("AnnouncementController"))
	AnnouncementController.Init()
end)
if announcementOk then
	print("[Client] AnnouncementController loaded OK")
else
	warn("[Client] AnnouncementController FAILED:", announcementErr)
end

local nextGoalOk, nextGoalErr = pcall(function()
	local NextGoalPopupController = require(Client:WaitForChild("NextGoalPopupController"))
	NextGoalPopupController.Init()
end)
if nextGoalOk then
	print("[Client] NextGoalPopupController loaded OK")
else
	warn("[Client] NextGoalPopupController FAILED:", nextGoalErr)
end

-- Dismiss loading screen now that the HUD and all panels are built.
-- The 0.35s fade reveals the fully-styled UI instead of the grey-box flash.
dismissLoadingScreen()

local questFeedbackOk, questFeedbackErr = pcall(function()
	local QuestFeedbackController = require(Client:WaitForChild("QuestFeedbackController"))
	QuestFeedbackController.Init()
end)
if questFeedbackOk then
	print("[Client] QuestFeedbackController loaded OK")
else
	warn("[Client] QuestFeedbackController FAILED:", questFeedbackErr)
end

-- Safety net: if bootstrap is interrupted before normal cleanup, never leave screen black.
task.delay(8, function()
	if _loadGui and _loadGui.Parent then
		warn("[BlackScreenDebug] FAILSAFE fired: stale LoadingScreen detected; destroying to restore visibility")
		logBlackScreenDiagnostics("FailsafeBeforeDestroy")
		_loadGui:Destroy()
		task.defer(function()
			logBlackScreenDiagnostics("FailsafeAfterDestroy")
		end)
	end
end)

-- 3b. UIScalingController (device-class responsive scaling)
local scalingOk, scalingErr = pcall(function()
	local UIScalingController = require(Client:WaitForChild("UIScalingController"))
	UIScalingController.Init()
end)
if scalingOk then
	print("[Client] UIScalingController loaded OK")
else
	warn("[Client] UIScalingController FAILED:", scalingErr)
end

-- 4. PetFollowerController (spawns + animates equipped pet models)
local petOk, petErr = pcall(function()
	local PetFollowerController = require(Client:WaitForChild("PetFollowerController"))
	PetFollowerController.Init()
end)
if petOk then
	print("[Client] PetFollowerController loaded OK")
else
	warn("[Client] PetFollowerController FAILED:", petErr)
end

-- 5. IconFollowerController (spawns + animates equipped icon image models)
local iconFollowerOk, iconFollowerErr = pcall(function()
	local IconFollowerController = require(Client:WaitForChild("IconFollowerController"))
	IconFollowerController.Init()
end)
if iconFollowerOk then
	print("[Client] IconFollowerController loaded OK")
else
	warn("[Client] IconFollowerController FAILED:", iconFollowerErr)
end

-- 6. MusicController (lobby + map music with transitions)
local musicOk, musicErr = pcall(function()
	local MusicController = require(Client:WaitForChild("MusicController"))
	MusicController.Init()
end)
if musicOk then
	print("[Client] MusicController loaded OK")
else
	warn("[Client] MusicController FAILED:", musicErr)
end

-- 6a. MatchAudioController (round feedback cues)
local matchAudioOk, matchAudioErr = pcall(function()
	local MatchAudioController = require(Client:WaitForChild("MatchAudioController"))
	MatchAudioController.Init()
end)
if matchAudioOk then
	print("[Client] MatchAudioController loaded OK")
else
	warn("[Client] MatchAudioController FAILED:", matchAudioErr)
end

-- 6b. EffectsController (camera shake, flash, elimination bursts, round text)
local effectsOk, effectsErr = pcall(function()
	local EffectsController = require(Client:WaitForChild("EffectsController"))
	EffectsController.Init()
end)
if effectsOk then
	print("[Client] EffectsController loaded OK")
else
	warn("[Client] EffectsController FAILED:", effectsErr)
end

-- 6. WorldIndicators (floating labels above SpinWheel + CrateShop)
local indicatorsOk, indicatorsErr = pcall(function()
	local WorldIndicators = require(Client:WaitForChild("WorldIndicators"))
	WorldIndicators.Init()
end)
if indicatorsOk then
	print("[Client] WorldIndicators loaded OK")
else
	warn("[Client] WorldIndicators FAILED:", indicatorsErr)
end

-- 7. BrainrotPickupController (floating animation + pickup popup)
local brainrotOk, brainrotErr = pcall(function()
	local BrainrotPickupController = require(Client:WaitForChild("BrainrotPickupController"))
	BrainrotPickupController.Init()
end)
if brainrotOk then
	print("[Client] BrainrotPickupController loaded OK")
else
	warn("[Client] BrainrotPickupController FAILED:", brainrotErr)
end

-- 8. CoinPickupController (hover + rotation for round coins)
local coinOk, coinErr = pcall(function()
	local CoinPickupController = require(Client:WaitForChild("CoinPickupController"))
	CoinPickupController.Init()
end)
if coinOk then
	print("[Client] CoinPickupController loaded OK")
else
	warn("[Client] CoinPickupController FAILED:", coinErr)
end

-- 8b. SwordPickupController (hover animation + announcement for sword spawns)
local swordOk, swordErr = pcall(function()
	local SwordPickupController = require(Client:WaitForChild("SwordPickupController"))
	SwordPickupController.Init()
end)
if swordOk then
	print("[Client] SwordPickupController loaded OK")
else
	warn("[Client] SwordPickupController FAILED:", swordErr)
end

-- 9. FireworksController (auto-play fireworks on match win + button click)
local fwOk, fwErr = pcall(function()
	local FireworksController = require(Client:WaitForChild("FireworksController"))
	FireworksController.Init()
end)
if fwOk then
	print("[Client] FireworksController loaded OK")
else
	warn("[Client] FireworksController FAILED:", fwErr)
end

-- 10. FreezeIndicatorController (shows FREEZE text when player is frozen)
local freezeOk, freezeErr = pcall(function()
	local FreezeIndicatorController = require(Client:WaitForChild("FreezeIndicatorController"))
	FreezeIndicatorController.Init()
end)
if freezeOk then
	print("[Client] FreezeIndicatorController loaded OK")
else
	warn("[Client] FreezeIndicatorController FAILED:", freezeErr)
end

-- 10b. PaidFreezeNoticeController (dedicated UI for paid targeted freeze)
local paidFreezeUiOk, paidFreezeUiErr = pcall(function()
	local PaidFreezeNoticeController = require(Client:WaitForChild("PaidFreezeNoticeController"))
	PaidFreezeNoticeController.Init()
end)
if paidFreezeUiOk then
	print("[Client] PaidFreezeNoticeController loaded OK")
else
	warn("[Client] PaidFreezeNoticeController FAILED:", paidFreezeUiErr)
end

-- 10c. PaidFreezeOverheadController (overhead icon on paid-frozen players)
local paidFreezeOverheadOk, paidFreezeOverheadErr = pcall(function()
	local PaidFreezeOverheadController = require(Client:WaitForChild("PaidFreezeOverheadController"))
	PaidFreezeOverheadController.Init()
end)
if paidFreezeOverheadOk then
	print("[Client] PaidFreezeOverheadController loaded OK")
else
	warn("[Client] PaidFreezeOverheadController FAILED:", paidFreezeOverheadErr)
end

-- 10d. TungTungSahurController (countdown + announcement UI for Brainrot hazard)
local ttsOk, ttsErr = pcall(function()
	local TungTungSahurController = require(Client:WaitForChild("TungTungSahurController"))
	TungTungSahurController.Init()
end)
if ttsOk then
	print("[Client] TungTungSahurController loaded OK")
else
	warn("[Client] TungTungSahurController FAILED:", ttsErr)
end

-- 11. GroupSignController (walk-up group join prompt)
local gsOk, gsErr = pcall(function()
	local GroupSignController = require(Client:WaitForChild("GroupSignController"))
	GroupSignController.Init()
end)
if gsOk then
	print("[Client] GroupSignController loaded OK")
else
	warn("[Client] GroupSignController FAILED:", gsErr)
end

-- 12. FreezePlayerPromptController (targeted freeze dev product prompt)
local freezePromptOk, freezePromptErr = pcall(function()
	local FreezePlayerPromptController = require(Client:WaitForChild("FreezePlayerPromptController"))
	FreezePlayerPromptController.Init()
end)
if freezePromptOk then
	print("[Client] FreezePlayerPromptController loaded OK")
else
	warn("[Client] FreezePlayerPromptController FAILED:", freezePromptErr)
end

-- 13. RewardGrantListener (server-confirmed reward popup only)
local rewardGrantOk, rewardGrantErr = pcall(function()
	local RewardGrantListener = require(Client:WaitForChild("RewardGrantListener"))
	RewardGrantListener.Init()
end)
if rewardGrantOk then
	print("[Client] RewardGrantListener loaded OK")
else
	warn("[Client] RewardGrantListener FAILED:", rewardGrantErr)
end

-- 14. VIPChestPromptController (walk-up VIP chest purchase prompt)
local vipChestOk, vipChestErr = pcall(function()
	local VIPChestPromptController = require(Client:WaitForChild("VIPChestPromptController"))
	VIPChestPromptController.Init()
end)
if vipChestOk then
	print("[Client] VIPChestPromptController loaded OK")
else
	warn("[Client] VIPChestPromptController FAILED:", vipChestErr)
end

-- 15. AbilityActivationWarningController (queued ability warning)
local abilityWarningOk, abilityWarningErr = pcall(function()
	local AbilityActivationWarningController = require(Client:WaitForChild("AbilityActivationWarningController"))
	AbilityActivationWarningController.Init()
end)
if abilityWarningOk then
	print("[Client] AbilityActivationWarningController loaded OK")
else
	warn("[Client] AbilityActivationWarningController FAILED:", abilityWarningErr)
end

-- 15c. CrownUnlockReminderController (nudge if crown unlocked but UI not checked)
local crownReminderOk, crownReminderErr = pcall(function()
	local CrownUnlockReminderController = require(Client:WaitForChild("CrownUnlockReminderController"))
	CrownUnlockReminderController.Init()
end)
if crownReminderOk then
	print("[Client] CrownUnlockReminderController loaded OK")
else
	warn("[Client] CrownUnlockReminderController FAILED:", crownReminderErr)
end

-- 15b. AbilitySellerLabelController (rainbow billboard text)
local abilityLabelOk, abilityLabelErr = pcall(function()
	local AbilitySellerLabelController = require(Client:WaitForChild("AbilitySellerLabelController"))
	AbilitySellerLabelController.Init()
end)
if abilityLabelOk then
	print("[Client] AbilitySellerLabelController loaded OK")
else
	warn("[Client] AbilitySellerLabelController FAILED:", abilityLabelErr)
end

-- BUILD_ID label (bottom-left corner, subtle version stamp)
pcall(function()
	local buildVal = ReplicatedStorage:WaitForChild("BUILD_ID", 10)
	if not buildVal then return end

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "BuildLabel"
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 999
	screenGui.IgnoreGuiInset = true
	screenGui.Parent = playerGui

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(0, 300, 0, 20)
	label.Position = UDim2.new(0, 6, 1, -22)
	label.AnchorPoint = Vector2.new(0, 1)
	label.BackgroundTransparency = 1
	label.Text = buildVal.Value
	label.TextColor3 = Color3.fromRGB(180, 180, 180)
	label.TextTransparency = 0.5
	label.TextSize = 11
	label.Font = Enum.Font.RobotoMono
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = screenGui

	buildVal.Changed:Connect(function(newVal)
		label.Text = newVal
	end)
end)

print(string.format("[Client] Init complete (t=%s)", ts()))
task.delay(2, logFinalRemoteContents)
