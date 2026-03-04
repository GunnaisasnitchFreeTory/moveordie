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

local function dismissLoadingScreen()
	TweenService:Create(_loadBg, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		BackgroundTransparency = 1,
	}):Play()
	task.delay(0.4, function()
		if _loadGui and _loadGui.Parent then _loadGui:Destroy() end
	end)
end
-- ─────────────────────────────────────────────────────────────────────────────

-- 0. Wait for game to load (assets replicated)
if not game:IsLoaded() then
	game.Loaded:Wait()
end
print(string.format("[UIBoot] t=%s Loaded", ts()))

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
local uiOk, uiErr = pcall(function()
	local UIController = require(Client:WaitForChild("UIController"))
	UIController.Init()
end)
if uiOk then
	print(string.format("[UIBoot] t=%s UIController READY", ts()))
else
	warn(string.format("[UIBoot] t=%s UIController FAILED: %s", ts(), tostring(uiErr)))
end

-- Dismiss loading screen now that the HUD and all panels are built.
-- The 0.35s fade reveals the fully-styled UI instead of the grey-box flash.
dismissLoadingScreen()

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

-- 6b. FNAF indicator wiring (clone working Brainrot indicator)
local fnafIndicatorOk, fnafIndicatorErr = pcall(function()
	local FnafIndicatorWiring = require(Client:WaitForChild("FnafIndicatorWiring"))
	FnafIndicatorWiring.Init()
end)
if fnafIndicatorOk then
	print("[Client] FnafIndicatorWiring loaded OK")
else
	warn("[Client] FnafIndicatorWiring FAILED:", fnafIndicatorErr)
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

-- 10b. TungTungSahurController (countdown + announcement UI for Brainrot hazard)
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

-- 12. RewardGrantListener (server-confirmed reward popup only)
local rewardGrantOk, rewardGrantErr = pcall(function()
	local RewardGrantListener = require(Client:WaitForChild("RewardGrantListener"))
	RewardGrantListener.Init()
end)
if rewardGrantOk then
	print("[Client] RewardGrantListener loaded OK")
else
	warn("[Client] RewardGrantListener FAILED:", rewardGrantErr)
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
