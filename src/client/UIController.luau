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
local MarketplaceService = game:GetService("MarketplaceService")

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

local okLobbyNpcConfig, LobbyNpcConfig = pcall(require, Shared:WaitForChild("LobbyNpcConfig", 10))
if not okLobbyNpcConfig or not LobbyNpcConfig then
	warn("[UIController] require(LobbyNpcConfig) FAILED:", LobbyNpcConfig)
	LobbyNpcConfig = {}
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
local QuestsPanel       = safeRequire("QuestsPanel")
local ForceNextModePanel = safeRequire("ForceNextModePanel")
local CustomSwordComingSoonPanel = safeRequire("CustomSwordComingSoonPanel")
local NpcDialoguePanel = safeRequire("NpcDialoguePanel")
local ToolboxDialoguePanel = safeRequire("ToolboxDialoguePanel")
local EmoteShopPanel = safeRequire("EmoteShopPanel")
local AbilityShopPanel = safeRequire("PerkShopPanel")

local LocalPlayer = Players.LocalPlayer

local initialized = false
local currentPanel: string? = nil
local matchLocked = false

local MATCH_LOCKED_PANELS = {
	Shop = true,
	Crowns = true,
	Pets = true,
	Icons = true,
	Daily = true,
	Stats = true,
	Spectate = true,
	CustomSwordComingSoon = true,
	NpcDialogue = true,
	ToolboxDialogue = true,
	EmoteShop = true,
	PerkShop = true, -- legacy alias
	AbilityShop = true,
}

local UIController = {}

UIController.CloseAllPanels = nil -- set after closeCurrentPanel is defined

local LUCKIEST_GUY_FONT = Enum.Font.LuckiestGuy

local function log(...)
	if UIConfig.DebugLog then
		print("[UIController]", ...)
	end
end

local function applyLuckiestGuyFontToInstance(instance: Instance)
	if instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox") then
		instance.Font = LUCKIEST_GUY_FONT
	end
end

local function applyLuckiestGuyFontRecursively(root: Instance)
	applyLuckiestGuyFontToInstance(root)
	for _, desc in ipairs(root:GetDescendants()) do
		applyLuckiestGuyFontToInstance(desc)
	end
end

local function isInsideBillboard(instance: Instance): boolean
	local current = instance
	while current do
		if current:IsA("BillboardGui") then
			return true
		end
		current = current.Parent
	end
	return false
end

local function applyLuckiestGuyToBillboardText(root: Instance)
	local function maybeApply(instance: Instance)
		if (instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox"))
			and isInsideBillboard(instance) then
			instance.Font = LUCKIEST_GUY_FONT
		end
	end

	maybeApply(root)
	for _, desc in ipairs(root:GetDescendants()) do
		maybeApply(desc)
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
	elseif currentPanel == "Quests" and QuestsPanel.IsVisible() then
		QuestsPanel.Hide()
	elseif currentPanel == "ForceNextMode" and ForceNextModePanel.IsVisible() then
		ForceNextModePanel.Hide()
	elseif currentPanel == "CustomSwordComingSoon" and CustomSwordComingSoonPanel.IsVisible() then
		CustomSwordComingSoonPanel.Hide()
	elseif currentPanel == "NpcDialogue" and NpcDialoguePanel.IsVisible() then
		NpcDialoguePanel.Hide()
	elseif currentPanel == "ToolboxDialogue" and ToolboxDialoguePanel.IsVisible() then
		ToolboxDialoguePanel.Hide()
	elseif currentPanel == "EmoteShop" and EmoteShopPanel.IsVisible() then
		EmoteShopPanel.Hide()
	elseif (currentPanel == "PerkShop" or currentPanel == "AbilityShop") and AbilityShopPanel.IsVisible() then
		AbilityShopPanel.Hide()
	end
	currentPanel = nil

	HUDPanel.SetBannerOverrideHidden(false)
end

UIController.CloseAllPanels = closeCurrentPanel

local function openPanel(name: string, payload: any?)
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
	elseif name == "Quests" then
		QuestsPanel.Show()
	elseif name == "ForceNextMode" then
		ForceNextModePanel.Show()
	elseif name == "CustomSwordComingSoon" then
		CustomSwordComingSoonPanel.Show()
	elseif name == "NpcDialogue" then
		NpcDialoguePanel.Show(payload)
	elseif name == "ToolboxDialogue" then
		ToolboxDialoguePanel.Show(payload)
	elseif name == "EmoteShop" then
		EmoteShopPanel.Show()
	elseif name == "PerkShop" or name == "AbilityShop" then
		AbilityShopPanel.Show()
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

	pcall(function()
		local StarterGui = game:GetService("StarterGui")
		StarterGui.ScreenOrientation = Enum.ScreenOrientation.LandscapeSensor
	end)

	SoundUtil.Init()

	local hudOk, hudGui = pcall(Components.CreateScreenGui, "HUDGui", 1)
	if not hudOk or not hudGui then
		warn("[UIController] FAILED: Could not create HUD ScreenGui: " .. tostring(hudGui))
		return
	end
	local panelGui = Components.CreateScreenGui("PanelGui", 10)

	Components.SetupResponsiveScale(hudGui)
	Components.SetupResponsiveScale(panelGui)

	-- Global UI typography override: force Luckiest Guy for every text object.
	applyLuckiestGuyFontRecursively(hudGui)
	applyLuckiestGuyFontRecursively(panelGui)

	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if playerGui then
		applyLuckiestGuyFontRecursively(playerGui)
		playerGui.DescendantAdded:Connect(function(desc)
			applyLuckiestGuyFontToInstance(desc)
		end)
	end

	-- World-space typography override: every BillboardGui text uses Luckiest Guy.
	applyLuckiestGuyToBillboardText(workspace)
	workspace.DescendantAdded:Connect(function(desc)
		if desc:IsA("BillboardGui") then
			applyLuckiestGuyToBillboardText(desc)
			return
		end
		if desc:IsA("TextLabel") or desc:IsA("TextButton") or desc:IsA("TextBox") then
			if isInsideBillboard(desc) then
				desc.Font = LUCKIEST_GUY_FONT
			end
		end
	end)

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
	safeInit("QuestsPanel", QuestsPanel.Init, panelGui, onPanelClosed)
	safeInit("CustomSwordComingSoonPanel", CustomSwordComingSoonPanel.Init, panelGui, onPanelClosed)
	safeInit("NpcDialoguePanel", NpcDialoguePanel.Init, panelGui, onPanelClosed)
	safeInit("ToolboxDialoguePanel", ToolboxDialoguePanel.Init, panelGui, onPanelClosed)
	safeInit("EmoteShopPanel", EmoteShopPanel.Init, panelGui, onPanelClosed)
	safeInit("PerkShopPanel", AbilityShopPanel.Init, panelGui, onPanelClosed)
	safeInit("ForceNextModePanel", ForceNextModePanel.Init, onPanelClosed)

	if NpcDialoguePanel.SetResponseHandlers then
		NpcDialoguePanel.SetResponseHandlers({
			onYes = function(dialogueData)
				local nextPanel = dialogueData and dialogueData.nextPanel
				if type(nextPanel) == "string" and nextPanel ~= "" then
					openPanel(nextPanel)
				else
					closeCurrentPanel()
				end
			end,
			onNo = function()
				closeCurrentPanel()
			end,
		})
	end

	if ToolboxDialoguePanel.SetResponseHandlers then
		ToolboxDialoguePanel.SetResponseHandlers({
			onYes = function(dialogueData)
				local nextPanel = dialogueData and dialogueData.nextPanel
				if type(nextPanel) == "string" and nextPanel ~= "" then
					openPanel(nextPanel)
				else
					closeCurrentPanel()
				end
			end,
			onNo = function()
				closeCurrentPanel()
			end,
		})
	end

	safeInit("ModeVotePanel", ModeVotePanel.Init)

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
			onQuests   = function() openPanel("Quests") end,
			onForceNextMode = function() openPanel("ForceNextMode") end,
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

	safeInit("KillFeed", KillFeed.Init, hudGui)

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
		local remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
		if not remotes then
			warn("[UIController] Remotes folder missing -- NPC dialogue disabled")
			return
		end

		local remote = remotes:WaitForChild("NpcDialogueRequest", 10)
		if not remote or not remote:IsA("RemoteEvent") then
			warn("[UIController] NpcDialogueRequest remote missing")
			return
		end

		remote.OnClientEvent:Connect(function(npcId: string, dialoguePayload)
			if currentPanel == "EmoteShop" or EmoteShopPanel.IsVisible()
				or currentPanel == "PerkShop" or currentPanel == "AbilityShop" or AbilityShopPanel.IsVisible() then
				return
			end

			local npcConfig = LobbyNpcConfig and LobbyNpcConfig[npcId]
			local dialogueData = dialoguePayload or (npcConfig and npcConfig.dialogue)
			if not dialogueData then
				warn("[UIController] Missing dialogue data for NPC:", tostring(npcId))
				return
			end

			local panelName = "NpcDialogue"
			if npcConfig and type(npcConfig.dialoguePanel) == "string" and npcConfig.dialoguePanel ~= "" then
				panelName = npcConfig.dialoguePanel
			end

			if panelName == "ToolboxDialogue" then
				if currentPanel == "ToolboxDialogue" or ToolboxDialoguePanel.IsVisible() then
					return
				end
				if ToolboxDialoguePanel.SetDialogue then
					ToolboxDialoguePanel.SetDialogue(dialogueData)
				end
				openPanel("ToolboxDialogue", dialogueData)
				return
			end

			if currentPanel == "NpcDialogue" or NpcDialoguePanel.IsVisible() then
				return
			end

			if NpcDialoguePanel.SetDialogue then
				NpcDialoguePanel.SetDialogue(dialogueData)
			end
			openPanel("NpcDialogue", dialogueData)
		end)
	end)

	task.spawn(function()
		local customSwordsModel = workspace:FindFirstChild("CustomSwords")
		if not customSwordsModel then
			customSwordsModel = workspace:FindFirstChild("CustomSwords", true)
		end

		if not customSwordsModel then
			warn("[UIController] CustomSwords NOT FOUND -- custom sword prompt disabled")
			return
		end

		local promptPart = customSwordsModel:FindFirstChild("Part")
		if not (promptPart and promptPart:IsA("BasePart")) then
			promptPart = customSwordsModel:FindFirstChildWhichIsA("BasePart", true)
		end

		if not promptPart then
			warn("[UIController] CustomSwords has NO BasePart -- custom sword prompt disabled")
			return
		end

		local prompt = customSwordsModel:FindFirstChild("CustomSwordPrompt", true)
		if prompt and not prompt:IsA("ProximityPrompt") then
			prompt = nil
		end

		if not prompt then
			for _, desc in ipairs(customSwordsModel:GetDescendants()) do
				if desc:IsA("ProximityPrompt") then
					prompt = desc
					break
				end
			end
		end

		if not prompt then
			prompt = Instance.new("ProximityPrompt")
			prompt.Parent = promptPart
		elseif prompt.Parent ~= promptPart then
			prompt.Parent = promptPart
		end

		prompt.Name = "CustomSwordPrompt"
		prompt.ActionText = "Customize"
		prompt.ObjectText = "Sword"
		prompt.KeyboardKeyCode = Enum.KeyCode.E
		prompt.HoldDuration = 0
		prompt.MaxActivationDistance = 15
		prompt.RequiresLineOfSight = false
		prompt.Enabled = true

		prompt.Triggered:Connect(function(playerWhoTriggered)
			if playerWhoTriggered ~= LocalPlayer then
				return
			end
			if currentPanel == "CustomSwordComingSoon" or CustomSwordComingSoonPanel.IsVisible() then
				return
			end
			openPanel("CustomSwordComingSoon")
		end)
	end)

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

	-- ═══════════════════════════════════════════════════════════════════
	-- WALK-UP: Brainrot Bundle Display
	-- ═══════════════════════════════════════════════════════════════════
	local function findNamedDisplayModel(root: Instance, candidateNames: { string }): Model?
		for _, name in ipairs(candidateNames) do
			local direct = root:FindFirstChild(name)
			if direct and direct:IsA("Model") then
				return direct
			end
		end
		for _, desc in ipairs(root:GetDescendants()) do
			if desc:IsA("Model") then
				local lowerName = string.lower(desc.Name)
				for _, name in ipairs(candidateNames) do
					if lowerName == string.lower(name) then
						return desc
					end
				end
			end
		end
		return nil
	end

	local function getBundleAnchorPosition(displayModel: Model): Vector3?
		local ok, boxCFrame, boxSize = pcall(function()
			return displayModel:GetBoundingBox()
		end)
		if ok and boxCFrame and boxSize then
			-- Keep the prompt just above the visual top of the displayed model.
			return boxCFrame.Position + Vector3.new(0, (boxSize.Y * 0.5) + 0.35, 0)
		end

		local bestPart = displayModel:FindFirstChildWhichIsA("BasePart", true)
		if bestPart then
			return bestPart.Position + Vector3.new(0, 2.4, 0)
		end

		return nil
	end

	local function getFixedTopCenterAnchorPosition(displayModel: Model, yOffset: number?): Vector3?
		local ok, boxCFrame, boxSize = pcall(function()
			return displayModel:GetBoundingBox()
		end)
		if ok and boxCFrame and boxSize then
			return boxCFrame.Position + Vector3.new(0, (boxSize.Y * 0.5) + (yOffset or 0.35), 0)
		end
		return nil
	end

	local function getOrCreateBundlePromptAnchor(displayModel: Model, anchorName: string): (BasePart?, boolean)
		local head = displayModel:FindFirstChild("Head", true)
		if head and head:IsA("BasePart") then
			return head, true
		end

		local humanoidRootPart = displayModel:FindFirstChild("HumanoidRootPart", true)
		if humanoidRootPart and humanoidRootPart:IsA("BasePart") then
			return humanoidRootPart, true
		end

		local primaryPart = displayModel.PrimaryPart
		if primaryPart and primaryPart:IsA("BasePart") and primaryPart.Transparency < 1 then
			return primaryPart, true
		end

		local promptAnchorName = "PromptAnchor"
		local anchorPart = displayModel:FindFirstChild(promptAnchorName)
		if not (anchorPart and anchorPart:IsA("BasePart")) then
			local legacyAnchor = displayModel:FindFirstChild(anchorName)
			if legacyAnchor and legacyAnchor:IsA("BasePart") then
				legacyAnchor.Name = promptAnchorName
				anchorPart = legacyAnchor
			end
		end

		if not (anchorPart and anchorPart:IsA("BasePart")) then
			anchorPart = Instance.new("Part")
			anchorPart.Name = promptAnchorName
			anchorPart.Size = Vector3.new(0.2, 0.2, 0.2)
			anchorPart.Anchored = true
			anchorPart.CanCollide = false
			anchorPart.CanQuery = true
			anchorPart.CanTouch = false
			anchorPart.Transparency = 1
			anchorPart.Parent = displayModel
		end

		local anchorPosition = getBundleAnchorPosition(displayModel)
		if anchorPosition then
			anchorPart.CFrame = CFrame.new(anchorPosition)
		end

		return anchorPart, false
	end

	local function findExistingBundlePrompt(bundleRoot: Instance, promptName: string): ProximityPrompt?
		local namedPrompt = bundleRoot:FindFirstChild(promptName, true)
		if namedPrompt and namedPrompt:IsA("ProximityPrompt") then
			return namedPrompt
		end
		for _, desc in ipairs(bundleRoot:GetDescendants()) do
			if desc:IsA("ProximityPrompt") then
				return desc
			end
		end
		return nil
	end

	local function removeDuplicateBundlePrompts(
		bundleRoot: Instance,
		keepPrompt: ProximityPrompt?,
		keepAnchor: BasePart?,
		legacyAnchorNames: { [string]: boolean }?
	): (number, number)
		local removedPrompts = 0
		for _, desc in ipairs(bundleRoot:GetDescendants()) do
			if desc:IsA("ProximityPrompt") and desc ~= keepPrompt then
				desc:Destroy()
				removedPrompts += 1
			end
		end

		local removedAnchors = 0
		if legacyAnchorNames then
			for _, desc in ipairs(bundleRoot:GetDescendants()) do
				if desc:IsA("BasePart")
					and desc ~= keepAnchor
					and legacyAnchorNames[desc.Name]
				then
					desc:Destroy()
					removedAnchors += 1
				end
			end
		end

		return removedPrompts, removedAnchors
	end

	local function configureBundlePrompt(
		prompt: ProximityPrompt,
		promptName: string,
		objectText: string,
		anchorPart: BasePart,
		usesBodyPartAnchor: boolean,
		maxDistance: number,
		actionText: string?
	)
		prompt.Name = promptName
		prompt.ActionText = actionText or "Buy"
		prompt.ObjectText = objectText
		prompt.KeyboardKeyCode = Enum.KeyCode.E
		prompt.HoldDuration = 0
		prompt.MaxActivationDistance = maxDistance
		prompt.RequiresLineOfSight = false
		prompt.UIOffset = usesBodyPartAnchor and Vector2.new(0, -48) or Vector2.new(0, 0)
		if prompt.Parent ~= anchorPart then
			prompt.Parent = anchorPart
		end
		prompt.Enabled = true
	end

	local function formatCoinAmount(value: number): string
		local s = tostring(math.max(0, math.floor(value)))
		local k
		repeat
			s, k = string.gsub(s, "^(-?%d+)(%d%d%d)", "%1,%2")
		until k == 0
		return s
	end

	local function getCoinTopUp150kProductId(): number?
		for _, entry in ipairs(UIConfig.MockPremiumItems or {}) do
			if entry.type == "Currency" and tonumber(entry.coinsAmount) == 150000 then
				local productId = tonumber(entry.productId)
				if productId and productId > 0 then
					return productId
				end
			end
		end
		return nil
	end

	local BUNDLE_PROMPT_BASE_COST: { [string]: number } = {
		brainrot_bundle = 150000,
		fnaf_pets_bundle = 150000,
	}

	local bundleQuoteRemote: RemoteFunction? = nil
	local function getBundleQuoteRemote(): RemoteFunction?
		if bundleQuoteRemote and bundleQuoteRemote.Parent then
			return bundleQuoteRemote
		end
		local remotes = ReplicatedStorage:FindFirstChild("Remotes")
		if not remotes then
			return nil
		end
		local rf = remotes:FindFirstChild("Shop_GetBundleQuote")
		if rf and rf:IsA("RemoteFunction") then
			bundleQuoteRemote = rf
			return rf
		end
		return nil
	end

	local function getBundlePromptState(bundleId: string)
		local coins = math.max(0, math.floor(tonumber(LocalPlayer:GetAttribute("Coins")) or 0))
		local basePrice = BUNDLE_PROMPT_BASE_COST[bundleId] or 150000
		local state = {
			ok = false,
			reason = "QUOTE_UNAVAILABLE",
			basePrice = basePrice,
			price = basePrice,
			deductionAmount = 0,
			ownedCount = 0,
			totalCount = 0,
			missingCount = 0,
			coins = coins,
			affordable = false,
		}
		local quoteRF = getBundleQuoteRemote()
		if quoteRF then
			local okQuote, result = pcall(quoteRF.InvokeServer, quoteRF, bundleId)
			if okQuote and type(result) == "table" then
				state.ok = result.ok == true
				state.reason = tostring(result.reason or "")
				state.price = math.max(0, math.floor(tonumber(result.price) or basePrice))
				state.ownedCount = math.max(0, math.floor(tonumber(result.ownedCount) or 0))
				state.totalCount = math.max(0, math.floor(tonumber(result.totalCount) or 0))
				state.missingCount = math.max(0, math.floor(tonumber(result.missingCount) or 0))
			end
		end
		state.deductionAmount = math.max(0, state.basePrice - state.price)
		state.affordable = state.coins >= state.price
		return state
	end

	local function isBundleOwnedPromptState(state): boolean
		if type(state) ~= "table" then
			return false
		end
		if tostring(state.reason) == "ALREADY_OWNED" then
			return true
		end
		if tonumber(state.price) and tonumber(state.price) <= 0 then
			return true
		end
		if tonumber(state.totalCount) and tonumber(state.totalCount) > 0 then
			return tonumber(state.missingCount) == 0
		end
		return false
	end

	local function applyBundlePromptPrice(prompt: ProximityPrompt, bundleId: string, objectText: string)
		local state = getBundlePromptState(bundleId)
		local owned = isBundleOwnedPromptState(state)
		local actionText = if owned
			then "OWNED"
			else string.format("BUY FOR %s FATE COINS", formatCoinAmount(state.price))
		prompt.ActionText = actionText
		prompt.ObjectText = objectText
		print(string.format(
			"[BundlePromptState] bundle=%s totalBundleCost=%d ownedItemDeductions=%d owned=%d missing=%d remainingCost=%d coins=%d affordable=%s isOwned=%s action=%s",
			bundleId,
			state.basePrice,
			state.deductionAmount,
			state.totalCount,
			state.ownedCount,
			state.missingCount,
			state.price,
			state.coins,
			tostring(state.affordable),
			tostring(owned),
			actionText
		))
		return state
	end

	local function handleBundlePromptTrigger(bundleId: string): boolean
		local state = getBundlePromptState(bundleId)
		local owned = isBundleOwnedPromptState(state)
		print(string.format(
			"[BundlePromptTrigger] bundle=%s totalBundleCost=%d ownedItemDeductions=%d owned=%d missing=%d remainingCost=%d coins=%d affordable=%s isOwned=%s reason=%s",
			bundleId,
			state.basePrice,
			state.deductionAmount,
			state.totalCount,
			state.ownedCount,
			state.missingCount,
			state.price,
			state.coins,
			tostring(state.affordable),
			tostring(owned),
			tostring(state.reason)
		))
		if owned then
			print(string.format("[BundlePromptRoute] bundle=%s branch=OWNED_NO_ACTION", bundleId))
			return false
		end
		if state.affordable then
			print(string.format("[BundlePromptRoute] bundle=%s branch=OPEN_BUNDLE_PANEL", bundleId))
			openPanel("Shop")
			if ShopPanel.ActivateBundleTab then
				ShopPanel.ActivateBundleTab(bundleId)
			end
			return true
		end

		local topUpProductId = getCoinTopUp150kProductId()
		if topUpProductId and topUpProductId > 0 then
			print(string.format("[BundlePromptRoute] bundle=%s branch=OPEN_150K_TOPUP productId=%d", bundleId, topUpProductId))
			MarketplaceService:PromptProductPurchase(LocalPlayer, topUpProductId)
		else
			warn(string.format("[BundlePromptRoute] bundle=%s topupProductMissing=true", bundleId))
			openPanel("Shop")
			if ShopPanel.ActivateBundleTab then
				ShopPanel.ActivateBundleTab(bundleId)
			end
		end
		return false
	end

	local function getOrCreateFixedBundleRootAnchor(
		bundleRoot: Instance,
		displayModel: Model,
		anchorName: string
	): BasePart?
		local anchorPart = bundleRoot:FindFirstChild(anchorName)
		if not (anchorPart and anchorPart:IsA("BasePart")) then
			anchorPart = Instance.new("Part")
			anchorPart.Name = anchorName
			anchorPart.Size = Vector3.new(0.2, 0.2, 0.2)
			anchorPart.Anchored = true
			anchorPart.CanCollide = false
			anchorPart.CanQuery = true
			anchorPart.CanTouch = false
			anchorPart.Transparency = 1
			anchorPart.Parent = bundleRoot
		end

		local anchorPosition = getFixedTopCenterAnchorPosition(displayModel, 0.35)
		if anchorPosition then
			anchorPart.CFrame = CFrame.new(anchorPosition)
		end

		return anchorPart
	end

	local function removeFnafPromptArtifacts(
		bundleRoot: Instance,
		keepPrompt: ProximityPrompt?,
		keepAnchor: BasePart?
	): (number, number)
		local removedPrompts = 0
		for _, desc in ipairs(workspace:GetDescendants()) do
			if desc:IsA("ProximityPrompt") and desc ~= keepPrompt then
				local parentPath = desc.Parent and desc.Parent:GetFullName() or ""
				local isFnafPrompt = desc.Name == "FNAFBundlePrompt"
				local isFnafObjectText = desc.ObjectText == "Animatronic Pets"
				if desc:IsDescendantOf(bundleRoot)
					or isFnafPrompt
					or (isFnafObjectText and (
						string.find(parentPath, "FNAFGameBun", 1, true)
						or string.find(parentPath, "FNAF Game Bun", 1, true)
					))
				then
					desc:Destroy()
					removedPrompts += 1
				end
			end
		end

		local removedAnchors = 0
		local legacyAnchorNames = {
			PromptAnchor = true,
			PromptPart = true,
			FNAFBundlePromptAnchor = true,
		}
		for _, desc in ipairs(bundleRoot:GetDescendants()) do
			if desc:IsA("BasePart")
				and desc ~= keepAnchor
				and legacyAnchorNames[desc.Name]
			then
				desc:Destroy()
				removedAnchors += 1
			end
		end

		return removedPrompts, removedAnchors
	end

	task.spawn(function()
		local BUNDLE_OPEN_DISTANCE = 15
		local BUNDLE_CLOSE_DISTANCE = 30
		local BRAINROT_PROMPT_ANCHOR_NAME = "PromptAnchor_BrainrotBuy"
		local bundleOpenTime = 0

		local brainrotFolder = nil
		for attempt = 1, 300 do
			brainrotFolder = workspace:FindFirstChild("Brainrot Game Bun")
			if brainrotFolder then break end
			task.wait(1)
		end

		if not brainrotFolder then
			log("[BrainrotBundle] Folder not found -- walk-up disabled")
			return
		end

		local function findBrainrotDisplayModel(folder: Instance): Model?
			return findNamedDisplayModel(folder, { "Dragon Cannelloni" })
		end

		local displayModel = nil
		local promptPart = nil
		local delayedForAnchor = false
		for attempt = 1, 300 do
			displayModel = findBrainrotDisplayModel(brainrotFolder)
			if displayModel then
				promptPart = getOrCreateFixedBundleRootAnchor(brainrotFolder, displayModel, BRAINROT_PROMPT_ANCHOR_NAME)
			end
			if promptPart then break end
			delayedForAnchor = true
			task.wait(1)
		end

		if not promptPart then
			log("[BrainrotBundle] No Dragon Cannelloni anchor -- walk-up disabled")
			return
		end
		log(string.format(
			"[BrainrotPrompt] anchorFound=%s initDelayedUntilAnchor=%s placementSource=FixedTopCenter finalY=%.2f",
			promptPart:GetFullName(),
			tostring(delayedForAnchor),
			promptPart.Position.Y
		))

		local prompt = findExistingBundlePrompt(brainrotFolder, "BrainrotBundlePrompt")

		if not prompt then
			prompt = Instance.new("ProximityPrompt")
			log("[BrainrotBundle] Prompt created for fixed Dragon Cannelloni display anchor")
		end
		configureBundlePrompt(prompt, "BrainrotBundlePrompt", "Brainrot Bundle", promptPart, false, BUNDLE_OPEN_DISTANCE)
		applyBundlePromptPrice(prompt, "brainrot_bundle", "Brainrot Bundle")
		local removedPromptCount, removedAnchorCount = removeDuplicateBundlePrompts(brainrotFolder, prompt, promptPart, {
			PromptAnchor = true,
			BrainrotBundlePromptAnchor = true,
			[BRAINROT_PROMPT_ANCHOR_NAME] = true,
		})
		if removedPromptCount > 0 or removedAnchorCount > 0 then
			log(string.format(
				"[BrainrotBundle] Reconciled anchor=%s anchorPos=%s removedPrompts=%d removedAnchors=%d",
				promptPart:GetFullName(),
				tostring(promptPart.Position),
				removedPromptCount,
				removedAnchorCount
			))
		end

		prompt.Triggered:Connect(function(playerWhoTriggered)
			if playerWhoTriggered ~= LocalPlayer then return end
			local openedBundle = handleBundlePromptTrigger("brainrot_bundle")
			if openedBundle then
				bundleOpenTime = tick()
			end
		end)

		-- Keep Brainrot prompt visible/enabled if assets stream or hierarchy refreshes.
		task.spawn(function()
			while true do
				if not brainrotFolder.Parent then
					break
				end
				if not displayModel or not displayModel.Parent then
					displayModel = findBrainrotDisplayModel(brainrotFolder)
				end
				if displayModel and displayModel.Parent then
					promptPart = getOrCreateFixedBundleRootAnchor(brainrotFolder, displayModel, BRAINROT_PROMPT_ANCHOR_NAME)
				end
				if promptPart and promptPart.Parent then
					if not prompt or not prompt.Parent then
						prompt = Instance.new("ProximityPrompt")
						configureBundlePrompt(prompt, "BrainrotBundlePrompt", "Brainrot Bundle", promptPart, false, BUNDLE_OPEN_DISTANCE)
						applyBundlePromptPrice(prompt, "brainrot_bundle", "Brainrot Bundle")
						prompt.Triggered:Connect(function(playerWhoTriggered)
							if playerWhoTriggered ~= LocalPlayer then return end
							local openedBundle = handleBundlePromptTrigger("brainrot_bundle")
							if openedBundle then
								bundleOpenTime = tick()
							end
						end)
						local removedPromptCountLoop, removedAnchorCountLoop = removeDuplicateBundlePrompts(brainrotFolder, prompt, promptPart, {
							PromptAnchor = true,
							BrainrotBundlePromptAnchor = true,
							[BRAINROT_PROMPT_ANCHOR_NAME] = true,
						})
						if removedPromptCountLoop > 0 or removedAnchorCountLoop > 0 then
							log(string.format(
								"[BrainrotBundle] Reconciled anchor=%s anchorPos=%s removedPrompts=%d removedAnchors=%d",
								promptPart:GetFullName(),
								tostring(promptPart.Position),
								removedPromptCountLoop,
								removedAnchorCountLoop
							))
						end
						log("[BrainrotBundle] Prompt recreated on fixed Dragon Cannelloni anchor")
					else
						configureBundlePrompt(prompt, "BrainrotBundlePrompt", "Brainrot Bundle", promptPart, false, BUNDLE_OPEN_DISTANCE)
						applyBundlePromptPrice(prompt, "brainrot_bundle", "Brainrot Bundle")
						local removedPromptCountLoop, removedAnchorCountLoop = removeDuplicateBundlePrompts(brainrotFolder, prompt, promptPart, {
							PromptAnchor = true,
							BrainrotBundlePromptAnchor = true,
							[BRAINROT_PROMPT_ANCHOR_NAME] = true,
						})
						if removedPromptCountLoop > 0 or removedAnchorCountLoop > 0 then
							log(string.format(
								"[BrainrotBundle] Reconciled anchor=%s anchorPos=%s removedPrompts=%d removedAnchors=%d",
								promptPart:GetFullName(),
								tostring(promptPart.Position),
								removedPromptCountLoop,
								removedAnchorCountLoop
							))
						end
					end
				end
				task.wait(6)
			end
		end)

		local GRACE_PERIOD = 3
		RunService.Heartbeat:Connect(function()
			if currentPanel ~= "Shop" then return end
			if (tick() - bundleOpenTime) < GRACE_PERIOD then return end
			if bundleOpenTime == 0 then return end

			local char = LocalPlayer.Character
			if not char then return end
			local root = char:FindFirstChild("HumanoidRootPart")
			if not root then return end

			local dist = (root.Position - promptPart.Position).Magnitude
			if dist > BUNDLE_CLOSE_DISTANCE then
				bundleOpenTime = 0
				closeCurrentPanel()
			end
		end)
	end)

	-- ═══════════════════════════════════════════════════════════════════
	-- WALK-UP: FNAF Bundle Display
	-- ═══════════════════════════════════════════════════════════════════
	task.spawn(function()
		local BUNDLE_OPEN_DISTANCE = 15
		local BUNDLE_CLOSE_DISTANCE = 30
		local FNAF_PROMPT_ANCHOR_NAME = "PromptAnchor_FNAFBuy"
		local bundleOpenTime = 0
		local lastPromptOpenAt = 0
		local promptOpenCooldown = 0.75
		local openedByFnafPrompt = false

		local function findFnafFolder(): Instance?
			local exact = workspace:FindFirstChild("FNAFGameBun") or workspace:FindFirstChild("FNAF Game Bun")
			if exact then return exact end
			for _, d in ipairs(workspace:GetDescendants()) do
				local n = string.lower(d.Name)
				if string.find(n, "fnaf", 1, true) and string.find(n, "bun", 1, true) then
					return d
				end
			end
			return nil
		end

		local fnafFolder = nil
		for attempt = 1, 300 do
			fnafFolder = findFnafFolder()
			if fnafFolder then break end
			task.wait(1)
		end

		if not fnafFolder then
			log("[FNAFBundle] Folder not found -- walk-up disabled")
			return
		end

		local function findFnafDisplayModel(folder: Instance): Model?
			return findNamedDisplayModel(folder, {
				"Freddy Fzber",
				"Freddy Fazber",
				"Freddy Fazbear",
			})
		end

		local displayModel = nil
		local promptPart = nil
		local prompt: ProximityPrompt? = nil
		local promptConn: RBXScriptConnection? = nil

		local function bindFnafPrompt(targetPrompt: ProximityPrompt)
			if promptConn then
				promptConn:Disconnect()
				promptConn = nil
			end
			promptConn = targetPrompt.Triggered:Connect(function(playerWhoTriggered)
				if playerWhoTriggered ~= LocalPlayer then return end
				local now = tick()
				if (now - lastPromptOpenAt) < promptOpenCooldown then
					return
				end
				lastPromptOpenAt = now
				local openedBundle = handleBundlePromptTrigger("fnaf_pets_bundle")
				if openedBundle then
					bundleOpenTime = tick()
					openedByFnafPrompt = true
					print("[ShopOpen] source=FNAFPrompt action=OPEN")
				end
			end)
		end

		for attempt = 1, 60 do
			displayModel = findFnafDisplayModel(fnafFolder)
			if displayModel then
				promptPart = getOrCreateFixedBundleRootAnchor(fnafFolder, displayModel, FNAF_PROMPT_ANCHOR_NAME)
			end
			if promptPart then break end
			task.wait(1)
		end

		if not promptPart then
			log("[FNAFBundle] No Freddy Fzber anchor -- walk-up disabled")
			return
		end

		prompt = findExistingBundlePrompt(fnafFolder, "FNAFBundlePrompt")

		if not prompt then
			prompt = Instance.new("ProximityPrompt")
			log("[FNAFBundle] Prompt created for Freddy Fzber display anchor")
		end
		configureBundlePrompt(prompt, "FNAFBundlePrompt", "Animatronic Pets", promptPart, false, BUNDLE_OPEN_DISTANCE)
		applyBundlePromptPrice(prompt, "fnaf_pets_bundle", "Animatronic Pets")
		local removedPromptCount, removedAnchorCount = removeFnafPromptArtifacts(fnafFolder, prompt, promptPart)
		log(string.format(
			"[FNAFBundle] displayModel=%s anchor=%s anchorPos=%s removedPrompts=%d removedAnchors=%d",
			displayModel:GetFullName(),
			promptPart:GetFullName(),
			tostring(promptPart.Position),
			removedPromptCount,
			removedAnchorCount
		))
		print(string.format("[BundleIndicator] bundle=fnaf visible=true part=%s", promptPart:GetFullName()))
		bindFnafPrompt(prompt)

		task.spawn(function()
			while true do
				if not fnafFolder.Parent then
					break
				end

				local nextDisplayModel = findFnafDisplayModel(fnafFolder)
				if nextDisplayModel then
					displayModel = nextDisplayModel
				end
				if displayModel and displayModel.Parent then
					promptPart = getOrCreateFixedBundleRootAnchor(fnafFolder, displayModel, FNAF_PROMPT_ANCHOR_NAME)
				end
				if promptPart and promptPart.Parent then
					if not prompt or not prompt.Parent then
						prompt = Instance.new("ProximityPrompt")
						configureBundlePrompt(prompt, "FNAFBundlePrompt", "Animatronic Pets", promptPart, false, BUNDLE_OPEN_DISTANCE)
						applyBundlePromptPrice(prompt, "fnaf_pets_bundle", "Animatronic Pets")
						bindFnafPrompt(prompt)
						log("[FNAFBundle] Prompt recreated on fixed Freddy anchor")
					else
						configureBundlePrompt(prompt, "FNAFBundlePrompt", "Animatronic Pets", promptPart, false, BUNDLE_OPEN_DISTANCE)
						applyBundlePromptPrice(prompt, "fnaf_pets_bundle", "Animatronic Pets")
					end

					local removedPromptCountLoop, removedAnchorCountLoop = removeFnafPromptArtifacts(fnafFolder, prompt, promptPart)
					if removedPromptCountLoop > 0 or removedAnchorCountLoop > 0 then
						log(string.format(
							"[FNAFBundle] Reconciled anchor=%s anchorPos=%s removedPrompts=%d removedAnchors=%d",
							promptPart:GetFullName(),
							tostring(promptPart.Position),
							removedPromptCountLoop,
							removedAnchorCountLoop
						))
					end
				end
				task.wait(6)
			end
		end)

		local GRACE_PERIOD = 3
		RunService.Heartbeat:Connect(function()
			if currentPanel ~= "Shop" then return end
			if (tick() - bundleOpenTime) < GRACE_PERIOD then return end
			if bundleOpenTime == 0 then return end

			local char = LocalPlayer.Character
			if not char then return end
			local root = char:FindFirstChild("HumanoidRootPart")
			if not root then return end

			local dist = (root.Position - promptPart.Position).Magnitude
			if dist > BUNDLE_CLOSE_DISTANCE then
				bundleOpenTime = 0
				if openedByFnafPrompt and currentPanel == "Shop" then
					print(string.format("[ShopOpen] source=FNAFPrompt action=CLOSE reason=DISTANCE_%.1f", dist))
					openedByFnafPrompt = false
				end
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
			UIConfig.StudTexture.AssetId,
			"rbxassetid://88626832961620",
			"rbxassetid://73347243859743",
			"rbxassetid://122828161526119",
			"rbxassetid://127688852831524",
			"rbxassetid://91925982333477",
			"rbxassetid://91048723795171",
			"rbxassetid://70943425376411",
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
