--[[
	UIController
	Central client-side UI orchestrator.

	Responsibilities:
	  * Creates ScreenGuis (HUD + Panels)
	  * Initialises sub-modules (HUD, Shop, FateCrowns, Pets, CrateShop, Index)
	  * Enforces "one panel at a time" rule
	  * ESC key closes the currently open panel
	  * Walk-up CrownPetShop: ProximityPrompt-based (reliable)
	    -> Also falls back to distance polling if prompt fails
	  * Also listens for OpenCrateShop RemoteEvent as fallback

	FIX: CrownPetShop position detection is now much more robust:
	  1. Tries PrimaryPart
	  2. Tries GetPivot()
	  3. Tries any descendant BasePart
	  4. Tries GetBoundingBox()
	  5. Retries multiple times with delays

	FIX (SpinWheel):
	  * Auto-close now uses the PROMPT's parent Part position (not the model root)
	  * Grace period after opening before auto-close kicks in
	  * CLOSE_DISTANCE increased to 50 studs (player must clearly walk away)
	  * "Game starting in X" banner is hidden while SpinWheel is open

	FIX (CrateShop):
	  * Now uses ProximityPrompt for reliable walk-up detection
	  * Distance polling kept as secondary check for auto-close

	Called from Client init.client.luau via UIController.Init().
]]

local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
if not Shared then
	warn("[UIController] Shared not found after 10s -- FAILED")
	return { Init = function() warn("[UIController] FAILED") end }
end

local okCfg, UIConfig = pcall(require, Shared:WaitForChild("UIConfig", 10))
if not okCfg or not UIConfig then
	local _children = {}
	for _, c in ipairs(Shared:GetChildren()) do table.insert(_children, c.Name.."("..c.ClassName..")") end
	warn("[UIController] require(UIConfig) FAILED:", UIConfig, "| Shared children:", table.concat(_children, ", "))
	return { Init = function() warn("[UIController] FAILED") end }
end

local Client = script.Parent
local UI = Client:WaitForChild("UI")

local SoundUtil         = require(UI:WaitForChild("SoundUtil"))
local Components        = require(UI:WaitForChild("Components"))
local HUDPanel          = require(UI:WaitForChild("HUDPanel"))

local PANEL_STUB = {
	Init = function() end, Show = function() end, Hide = function() end,
	IsVisible = function() return false end, Toggle = function() end,
}

local _failedPanels = {}

local SAFE_REQUIRE_RETRIES = { 0.25, 1.0 }

local function safeRequire(name)
	local moduleInstance = UI:WaitForChild(name, 10)
	if not moduleInstance then
		warn(string.format("[UIController] Module '%s' not found in UI folder after 10s", name))
		table.insert(_failedPanels, name)
		return PANEL_STUB
	end

	local ok, mod = pcall(require, moduleInstance)
	if ok and mod then return mod end

	warn(string.format("[UIController] Failed to load %s (path: %s): %s",
		name, moduleInstance:GetFullName(), tostring(mod)))

	for i, delay in ipairs(SAFE_REQUIRE_RETRIES) do
		task.wait(delay)
		warn(string.format("[UIController] Retry #%d for %s after %.2fs...", i, name, delay))
		ok, mod = pcall(require, moduleInstance)
		if ok and mod then
			print(string.format("[UIController] %s loaded OK on retry #%d", name, i))
			return mod
		end
		warn(string.format("[UIController] Retry #%d for %s FAILED: %s", i, name, tostring(mod)))
	end

	warn(string.format("[UIController] GIVING UP on %s after %d retries", name, #SAFE_REQUIRE_RETRIES))
	table.insert(_failedPanels, name)
	return PANEL_STUB
end

local ShopPanel         = safeRequire("ShopPanel")
local FateCrownsPanel   = safeRequire("FateCrownsPanel")
local PetsPanel         = safeRequire("PetsPanel")
local CrateShopPanel    = safeRequire("CrateShopPanel")
local IndexPanel        = safeRequire("IndexPanel")
local SpectatePanel     = safeRequire("SpectatePanel")
local SettingsPanel     = safeRequire("SettingsPanel")
local IconImagesPanel   = safeRequire("IconImagesPanel")
local SpinWheelPanel    = safeRequire("SpinWheelPanel")
local KillFeed          = safeRequire("KillFeed")
local MatchResultsPanel = safeRequire("MatchResultsPanel")
local DailyRewardsPanel = safeRequire("DailyRewardsPanel")
local StatsPanel        = safeRequire("StatsPanel")
local ModeVotePanel     = safeRequire("ModeVotePanel")

local LocalPlayer = Players.LocalPlayer

local initialized = false
local currentPanel: string? = nil
local matchLocked = false

local MATCH_LOCKED_PANELS = { Crowns = true, Pets = true, Daily = true, Stats = true }

local UIController = {}

local function log(...)
	if UIConfig.DebugLog then
		print("[UIController]", ...)
	end
end

local function closeCurrentPanel()
	if currentPanel == "Shop" and ShopPanel.IsVisible() then
		ShopPanel.Hide()
	elseif currentPanel == "Crowns" and FateCrownsPanel.IsVisible() then
		FateCrownsPanel.Hide()
	elseif currentPanel == "Pets" and PetsPanel.IsVisible() then
		PetsPanel.Hide()
	elseif currentPanel == "Index" and IndexPanel.IsVisible() then
		IndexPanel.Hide()
	elseif currentPanel == "CrateShop" and CrateShopPanel.IsVisible() then
		CrateShopPanel.Hide()
	elseif currentPanel == "Spectate" and SpectatePanel.IsVisible() then
		SpectatePanel.Hide()
	elseif currentPanel == "Settings" and SettingsPanel.IsVisible() then
		SettingsPanel.Hide()
	elseif currentPanel == "Icons" and IconImagesPanel.IsVisible() then
		IconImagesPanel.Hide()
	elseif currentPanel == "SpinWheel" and SpinWheelPanel.IsVisible() then
		SpinWheelPanel.Hide()
	elseif currentPanel == "Daily" and DailyRewardsPanel.IsVisible() then
		DailyRewardsPanel.Hide()
	elseif currentPanel == "Stats" and StatsPanel.IsVisible() then
		StatsPanel.Hide()
	end
	currentPanel = nil

	HUDPanel.SetBannerOverrideHidden(false)
end

local function openPanel(name: string)
	if matchLocked and MATCH_LOCKED_PANELS[name] then
		log("Blocked opening " .. name .. " -- player is InMatch")
		return
	end

	if currentPanel == name then
		closeCurrentPanel()
		return
	end
	closeCurrentPanel()
	currentPanel = name

	if name == "Shop" then
		ShopPanel.Show()
	elseif name == "Crowns" then
		FateCrownsPanel.Show()
	elseif name == "Pets" then
		PetsPanel.Show()
	elseif name == "Index" then
		IndexPanel.Show()
	elseif name == "CrateShop" then
		CrateShopPanel.Show()
	elseif name == "Spectate" then
		SpectatePanel.Show()
	elseif name == "Settings" then
		SettingsPanel.Show()
	elseif name == "Icons" then
		IconImagesPanel.Show()
	elseif name == "SpinWheel" then
		SpinWheelPanel.Show()
	elseif name == "Daily" then
		DailyRewardsPanel.Show()
	elseif name == "Stats" then
		StatsPanel.Show()
	end

	HUDPanel.SetBannerOverrideHidden(true)

	log("Opened:", name)
end

local function getInstancePosition(instance: Instance): Vector3?
	if instance:IsA("BasePart") then
		return instance.Position
	end

	if instance:IsA("Model") then
		local primary = instance.PrimaryPart
		if primary then
			return primary.Position
		end

		local ok, pivot = pcall(function()
			return instance:GetPivot()
		end)
		if ok and pivot then
			return pivot.Position
		end

		local ok2, cf = pcall(function()
			local cframe, _ = instance:GetBoundingBox()
			return cframe
		end)
		if ok2 and cf then
			return cf.Position
		end
	end

	local part = instance:FindFirstChildWhichIsA("BasePart", true)
	if part then
		return part.Position
	end

	for _, child in ipairs(instance:GetChildren()) do
		if child:IsA("BasePart") then
			return child.Position
		end
		if child:IsA("Model") then
			local pos = getInstancePosition(child)
			if pos then return pos end
		end
	end

	return nil
end

function UIController.Init()
	if initialized then return end
	initialized = true

	SoundUtil.Init()

	local hudOk, hudGui = pcall(Components.CreateScreenGui, "HUDGui", 1)
	if not hudOk or not hudGui then
		warn("[UIController] FAILED: Could not create HUD ScreenGui: " .. tostring(hudGui))
		return
	end
	local panelGui = Components.CreateScreenGui("PanelGui", 10)

	local function onPanelClosed()
		currentPanel = nil
		HUDPanel.SetBannerOverrideHidden(false)
	end

	local function safeInit(name, fn, ...)
		local args = {...}
		local ok, err = pcall(function()
			fn(table.unpack(args))
		end)
		if not ok then
			warn("[UIController] " .. name .. " Init FAILED: " .. tostring(err))
			if not table.find(_failedPanels, name) then
				table.insert(_failedPanels, name)
			end
		end
	end

	safeInit("ShopPanel", ShopPanel.Init, panelGui, onPanelClosed)
	safeInit("FateCrownsPanel", FateCrownsPanel.Init, panelGui, onPanelClosed)
	safeInit("PetsPanel", PetsPanel.Init, panelGui, onPanelClosed)
	safeInit("CrateShopPanel", CrateShopPanel.Init, panelGui, onPanelClosed)
	safeInit("IndexPanel", IndexPanel.Init, panelGui, onPanelClosed)
	safeInit("SpectatePanel", SpectatePanel.Init, panelGui, onPanelClosed)
	safeInit("SettingsPanel", SettingsPanel.Init, panelGui, onPanelClosed)
	safeInit("IconImagesPanel", IconImagesPanel.Init, panelGui, onPanelClosed)
	safeInit("SpinWheelPanel", SpinWheelPanel.Init, panelGui, onPanelClosed)
	safeInit("DailyRewardsPanel", DailyRewardsPanel.Init, panelGui, onPanelClosed)
	safeInit("StatsPanel", StatsPanel.Init, panelGui, onPanelClosed)

	safeInit("ModeVotePanel", ModeVotePanel.Init)

	safeInit("KillFeed", KillFeed.Init, hudGui)

	safeInit("MatchResultsPanel", MatchResultsPanel.Init, hudGui)

	local hudInitOk, hudInitErr = pcall(function()
		HUDPanel.Init(hudGui, {
			onShop     = function() openPanel("Shop") end,
			onCrowns   = function() openPanel("Crowns") end,
			onPets     = function() openPanel("Pets") end,
			onIndex    = function() openPanel("Index") end,
			onSpectate = function() openPanel("Spectate") end,
			onSettings = function() openPanel("Settings") end,
			onIcons    = function() openPanel("Icons") end,
			onDaily    = function() openPanel("Daily") end,
			onStats    = function() openPanel("Stats") end,
			onAFK      = function()
				task.spawn(function()
					local remotes = ReplicatedStorage:FindFirstChild("Remotes")
					if not remotes then return end
					local toggleAFK = remotes:FindFirstChild("ToggleAFK")
					if toggleAFK then
						toggleAFK:FireServer()
					end
				end)
			end,
		})
	end)

	if not hudInitOk then
		warn("[UIController] FAILED: HUD Init error: " .. tostring(hudInitErr))
		return
	end

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if input.KeyCode == Enum.KeyCode.Escape and currentPanel then
			closeCurrentPanel()
		end
	end)

	local function onPlayerStateChanged()
		local state = LocalPlayer:GetAttribute("PlayerState")
		local wasLocked = matchLocked
		matchLocked = (state == "InMatch")

		if matchLocked and not wasLocked then
			log("Match started -- locking Pets/Crowns UI")
			if currentPanel and MATCH_LOCKED_PANELS[currentPanel] then
				log("Force-closing " .. currentPanel .. " (match started)")
				closeCurrentPanel()
			end
		elseif not matchLocked and wasLocked then
			log("Match ended -- unlocking Pets/Crowns UI")
		end
	end
	onPlayerStateChanged()
	LocalPlayer:GetAttributeChangedSignal("PlayerState"):Connect(onPlayerStateChanged)

	task.spawn(function()
		local crateShopModel = nil
		local MAX_RETRIES = 15
		local RETRY_DELAY = 2

		for attempt = 1, MAX_RETRIES do
			crateShopModel = workspace:FindFirstChild("CrownPetShop", true)
			if not crateShopModel then
				crateShopModel = workspace:FindFirstChild("CrownPetShop")
			end
			if crateShopModel then
				print(string.format("[UIController] CrownPetShop found on attempt %d: %s (class: %s)",
					attempt, crateShopModel:GetFullName(), crateShopModel.ClassName))
				break
			end
			if attempt < MAX_RETRIES then
				if attempt == 1 then
					print("[UIController] Searching for CrownPetShop...")
				end
				task.wait(RETRY_DELAY)
			end
		end

		if not crateShopModel then
			warn("[UIController] CrownPetShop NOT FOUND after " .. MAX_RETRIES .. " attempts -- walk-up shop disabled")
			return
		end

		local refPart = nil
		if crateShopModel:IsA("Model") and crateShopModel.PrimaryPart then
			refPart = crateShopModel.PrimaryPart
		end
		if not refPart then
			refPart = crateShopModel:FindFirstChildWhichIsA("BasePart", true)
		end
		if not refPart then
			print("[UIController] CrownPetShop: waiting for BasePart to stream in...")
			local waitConn
			local found = false
			waitConn = crateShopModel.DescendantAdded:Connect(function(desc)
				if desc:IsA("BasePart") and not found then
					found = true
					refPart = desc
					if waitConn then waitConn:Disconnect() end
				end
			end)
			task.wait(8)
			if waitConn then pcall(function() waitConn:Disconnect() end) end
			if not refPart then
				refPart = crateShopModel:FindFirstChildWhichIsA("BasePart", true)
			end
		end

		if not refPart then
			warn("[UIController] CrownPetShop has NO BasePart -- walk-up disabled")
			return
		end

		print(string.format("[UIController] CrownPetShop refPart: %s at (%.1f, %.1f, %.1f)",
			refPart:GetFullName(), refPart.Position.X, refPart.Position.Y, refPart.Position.Z))

		local prompt: ProximityPrompt? = nil
		for _, desc in ipairs(crateShopModel:GetDescendants()) do
			if desc:IsA("ProximityPrompt") then
				prompt = desc
				break
			end
		end

		local OPEN_DISTANCE = 15
		local CLOSE_DISTANCE = 22
		local crateOpenTime = 0

		if not prompt then
			local anchor = Instance.new("Part")
			anchor.Name = "CrateShopPromptAnchor"
			anchor.Size = Vector3.new(2, 2, 2)
			anchor.Position = Vector3.new(refPart.Position.X, refPart.Position.Y + 3, refPart.Position.Z)
			anchor.Anchored = true
			anchor.CanCollide = false
			anchor.CanQuery = false
			anchor.CanTouch = false
			anchor.Transparency = 1
			anchor.Parent = crateShopModel

			prompt = Instance.new("ProximityPrompt")
			prompt.Name = "CrateShopPrompt"
			prompt.ActionText = "Open Shop"
			prompt.ObjectText = "Crate Shop"
			prompt.KeyboardKeyCode = Enum.KeyCode.E
			prompt.HoldDuration = 0
			prompt.MaxActivationDistance = OPEN_DISTANCE
			prompt.RequiresLineOfSight = false
			prompt.Parent = anchor

			print("[UIController] Created CrateShopPrompt on anchor at", anchor.Position)
		else
			print("[UIController] Found existing ProximityPrompt in CrownPetShop:", prompt:GetFullName())
		end

		local promptPart = prompt.Parent

		prompt.Triggered:Connect(function(playerWhoTriggered)
			if playerWhoTriggered ~= LocalPlayer then return end
			print("[UIController] CrateShop prompt triggered")
			crateOpenTime = tick()
			openPanel("CrateShop")
		end)

		local GRACE_PERIOD = 3
		RunService.Heartbeat:Connect(function()
			if currentPanel ~= "CrateShop" then return end
			if (tick() - crateOpenTime) < GRACE_PERIOD then return end

			local char = LocalPlayer.Character
			if not char then return end
			local root = char:FindFirstChild("HumanoidRootPart")
			if not root then return end

			local shopPos = nil
			if promptPart and promptPart:IsA("BasePart") then
				shopPos = promptPart.Position
			else
				shopPos = getInstancePosition(crateShopModel)
			end
			if not shopPos then return end

			local dist = (root.Position - shopPos).Magnitude
			if dist > CLOSE_DISTANCE then
				closeCurrentPanel()
			end
		end)
	end)

	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
		if not remotes then return end

		local openCrateShopEvent = remotes:WaitForChild("OpenCrateShop", 15)
		if openCrateShopEvent then
			openCrateShopEvent.OnClientEvent:Connect(function()
				openPanel("CrateShop")
			end)
		end
	end)

	task.spawn(function()
		local okSWC, SpinWheelCfg = pcall(require, Shared:WaitForChild("SpinWheelConfig", 10))
		if not okSWC or not SpinWheelCfg then
			warn("[UIController] SpinWheelConfig not available -- spin wheel walk-up disabled")
			return
		end

		local spinModel = nil
		local MAX_RETRIES = 10
		local RETRY_DELAY = 2

		for attempt = 1, MAX_RETRIES do
			spinModel = workspace:FindFirstChild("SpinTheWheel", true)
			if not spinModel then
				spinModel = workspace:FindFirstChild("SpinTheWheel")
			end
			if spinModel then
				log("[SpinWheel] Model found on attempt " .. attempt)
				break
			end
			if attempt < MAX_RETRIES then
				task.wait(RETRY_DELAY)
			end
		end

		if not spinModel then
			log("[SpinWheel] NOT FOUND -- spin wheel disabled")
			return
		end

		local prompt: ProximityPrompt? = nil
		for _, desc in ipairs(spinModel:GetDescendants()) do
			if desc:IsA("ProximityPrompt") then
				prompt = desc
				break
			end
		end

		if not prompt then
			local waitStart = tick()
			local MAX_WAIT = 20
			local foundEvent = Instance.new("BindableEvent")
			local conn = spinModel.DescendantAdded:Connect(function(desc)
				if desc:IsA("ProximityPrompt") then
					prompt = desc
					foundEvent:Fire()
				end
			end)
			task.spawn(function()
				while not prompt and (tick() - waitStart) < MAX_WAIT do
					task.wait(1)
					for _, desc in ipairs(spinModel:GetDescendants()) do
						if desc:IsA("ProximityPrompt") then
							prompt = desc
							foundEvent:Fire()
							return
						end
					end
				end
				foundEvent:Fire()
			end)
			if not prompt then
				foundEvent.Event:Wait()
			end
			conn:Disconnect()
			foundEvent:Destroy()
		end

		if not prompt then
			local refPart = spinModel:FindFirstChildWhichIsA("BasePart", true)
			if not refPart then return end

			local anchor = Instance.new("Part")
			anchor.Name = "SpinWheelPromptAnchor"
			anchor.Size = Vector3.new(2, 2, 2)
			anchor.Position = Vector3.new(refPart.Position.X, 5, refPart.Position.Z)
			anchor.Anchored = true
			anchor.CanCollide = false
			anchor.CanQuery = false
			anchor.CanTouch = false
			anchor.Transparency = 1
			anchor.Parent = spinModel

			prompt = Instance.new("ProximityPrompt")
			prompt.Name = "SpinWheelPrompt"
			prompt.ActionText = "Spin"
			prompt.ObjectText = "Spin The Wheel"
			prompt.KeyboardKeyCode = Enum.KeyCode.E
			prompt.HoldDuration = 0
			prompt.MaxActivationDistance = SpinWheelCfg.OPEN_DISTANCE
			prompt.RequiresLineOfSight = false
			prompt.Parent = anchor
		end

		local promptPart = prompt.Parent
		local spinOpenTime = 0

		prompt.Triggered:Connect(function(playerWhoTriggered)
			if playerWhoTriggered ~= LocalPlayer then return end
			spinOpenTime = tick()
			openPanel("SpinWheel")
		end)

		local CLOSE_DIST = SpinWheelCfg.CLOSE_DISTANCE
		local GRACE_PERIOD = SpinWheelCfg.OPEN_GRACE_PERIOD or 3

		RunService.Heartbeat:Connect(function()
			if currentPanel ~= "SpinWheel" then return end
			if (tick() - spinOpenTime) < GRACE_PERIOD then return end

			local char = LocalPlayer.Character
			if not char then return end
			local root = char:FindFirstChild("HumanoidRootPart")
			if not root then return end

			local promptPos = nil
			if promptPart and promptPart:IsA("BasePart") then
				promptPos = promptPart.Position
			else
				promptPos = getInstancePosition(spinModel)
			end
			if not promptPos then return end

			local dist = (root.Position - promptPos).Magnitude
			if dist > CLOSE_DIST then
				closeCurrentPanel()
			end
		end)
	end)

	if #_failedPanels > 0 then
		warn("[UIController] DEGRADED: panels failed: " .. table.concat(_failedPanels, ", "))
	else
		print("[UIController] READY")
	end

	if DailyRewardsPanel and DailyRewardsPanel.TryAutoShow then
		DailyRewardsPanel.TryAutoShow(function()
			openPanel("Daily")
		end)
	end

	task.spawn(function()
		local ContentProvider = game:GetService("ContentProvider")
		local PRELOAD_ASSETS = {
			"rbxassetid://71121412594159",
			"rbxassetid://125632977173073",
			"rbxassetid://74957106349993",
			"rbxassetid://96348372111632",
			"rbxassetid://140333135289717",
			"rbxassetid://130563974863986",
			"rbxassetid://70371140256856",
		}
		local preloadInstances = {}
		for _, assetId in ipairs(PRELOAD_ASSETS) do
			local img = Instance.new("ImageLabel")
			img.Image = assetId
			table.insert(preloadInstances, img)
		end
		local preloadOk, preloadErr = pcall(function()
			ContentProvider:PreloadAsync(preloadInstances)
		end)
		if preloadOk then
			print("[UIController] Asset preload complete --", #PRELOAD_ASSETS, "assets loaded successfully")
		else
			warn("[UIController] Asset preload FAILED:", preloadErr)
		end
		for _, inst in ipairs(preloadInstances) do
			inst:Destroy()
		end
	end)
end

return UIController
