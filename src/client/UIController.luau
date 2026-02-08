--[[
	UIController
	Central client-side UI orchestrator.

	Responsibilities:
	  • Creates ScreenGuis (HUD + Panels)
	  • Initialises sub-modules (HUD, Shop, FateCrowns, Pets, CrateShop, Index)
	  • Enforces "one panel at a time" rule
	  • ESC key closes the currently open panel
	  • Walk-up CrownPetShop: client-side proximity detection
	    → INSTANTLY opens Crate Shop when player walks near
	    → No ProximityPrompt, no button press, no delay
	  • Also listens for OpenCrateShop RemoteEvent as fallback

	FIX: CrownPetShop position detection is now much more robust:
	  1. Tries PrimaryPart
	  2. Tries GetPivot()
	  3. Tries any descendant BasePart
	  4. Tries GetBoundingBox()
	  5. Retries multiple times with delays

	Called from Client init.client.luau via UIController.Init().
]]

local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UIConfig = require(Shared:WaitForChild("UIConfig"))

local Client = script.Parent
local UI = Client:WaitForChild("UI")

local SoundUtil         = require(UI:WaitForChild("SoundUtil"))
local Components        = require(UI:WaitForChild("Components"))
local HUDPanel          = require(UI:WaitForChild("HUDPanel"))
local ShopPanel         = require(UI:WaitForChild("ShopPanel"))
local FateCrownsPanel   = require(UI:WaitForChild("FateCrownsPanel"))
local PetsPanel         = require(UI:WaitForChild("PetsPanel"))
local CrateShopPanel    = require(UI:WaitForChild("CrateShopPanel"))
local IndexPanel        = require(UI:WaitForChild("IndexPanel"))
local SpectatePanel     = require(UI:WaitForChild("SpectatePanel"))
local SettingsPanel     = require(UI:WaitForChild("SettingsPanel"))
local IconImagesPanel   = require(UI:WaitForChild("IconImagesPanel"))
local SpinWheelPanel    = require(UI:WaitForChild("SpinWheelPanel"))
local KillFeed          = require(UI:WaitForChild("KillFeed"))

local LocalPlayer = Players.LocalPlayer

local initialized = false
local currentPanel: string? = nil

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
	end
	currentPanel = nil
end

local function openPanel(name: string)
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
	end

	log("Opened:", name)
end

--[[
	ROBUST position finder for CrownPetShop.
	Tries every possible method to get a world position from the model.
]]
local function getInstancePosition(instance: Instance): Vector3?
	-- 1. If it IS a BasePart directly
	if instance:IsA("BasePart") then
		return instance.Position
	end

	-- 2. If it's a Model with PrimaryPart
	if instance:IsA("Model") then
		local primary = instance.PrimaryPart
		if primary then
			return primary.Position
		end

		-- 3. Try GetPivot (works even without PrimaryPart)
		local ok, pivot = pcall(function()
			return instance:GetPivot()
		end)
		if ok and pivot then
			return pivot.Position
		end

		-- 4. Try GetBoundingBox (works on any Model with parts)
		local ok2, cf = pcall(function()
			local cframe, _ = instance:GetBoundingBox()
			return cframe
		end)
		if ok2 and cf then
			return cf.Position
		end
	end

	-- 5. Find ANY descendant BasePart (deepest fallback)
	local part = instance:FindFirstChildWhichIsA("BasePart", true)
	if part then
		return part.Position
	end

	-- 6. Check if it's a Folder — look for child Models or Parts
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

	-- 1. Bootstrap sounds
	SoundUtil.Init()

	-- 2. Create ScreenGuis
	local hudGui   = Components.CreateScreenGui("HUDGui", 1)
	local panelGui = Components.CreateScreenGui("PanelGui", 10)

	-- 3. Panel close callback
	local function onPanelClosed()
		currentPanel = nil
	end

	-- 4. Init all panels
	ShopPanel.Init(panelGui, onPanelClosed)
	FateCrownsPanel.Init(panelGui, onPanelClosed)
	PetsPanel.Init(panelGui, onPanelClosed)
	CrateShopPanel.Init(panelGui, onPanelClosed)
	IndexPanel.Init(panelGui, onPanelClosed)
	SpectatePanel.Init(panelGui, onPanelClosed)
	SettingsPanel.Init(panelGui, onPanelClosed)
	IconImagesPanel.Init(panelGui, onPanelClosed)
	SpinWheelPanel.Init(panelGui, onPanelClosed)

	-- 4b. Init Kill Feed (always visible on HUD layer)
	KillFeed.Init(hudGui)

	-- 5. Init HUD (2×4 sidebar grid)
	HUDPanel.Init(hudGui, {
		onShop     = function() openPanel("Shop") end,
		onCrowns   = function() openPanel("Crowns") end,
		onPets     = function() openPanel("Pets") end,
		onIndex    = function() openPanel("Index") end,
		onSpectate = function() openPanel("Spectate") end,
		onSettings = function() openPanel("Settings") end,
		onIcons    = function() openPanel("Icons") end,
		onAFK      = function()
			-- Fire ToggleAFK remote to server
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

	-- 6. ESC key handler
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if input.KeyCode == Enum.KeyCode.Escape and currentPanel then
			closeCurrentPanel()
		end
	end)

	-- 7. Walk-up CrownPetShop — CLIENT-SIDE PROXIMITY DETECTION
	--    Opens INSTANTLY when player walks near, NO prompt/button needed.
	--    ROBUST: retries multiple times, uses every possible method to find position.
	task.spawn(function()
		local crateShopModel = nil
		local MAX_RETRIES = 10
		local RETRY_DELAY = 2

		for attempt = 1, MAX_RETRIES do
			-- Try multiple search patterns
			crateShopModel = workspace:FindFirstChild("CrownPetShop", true)

			if not crateShopModel then
				-- Also try as a direct child of workspace
				crateShopModel = workspace:FindFirstChild("CrownPetShop")
			end

			if crateShopModel then
				log(string.format("CrownPetShop found on attempt %d: %s (class: %s)",
					attempt, crateShopModel:GetFullName(), crateShopModel.ClassName))
				break
			end

			if attempt < MAX_RETRIES then
				log(string.format("CrownPetShop not found (attempt %d/%d), retrying in %ds...",
					attempt, MAX_RETRIES, RETRY_DELAY))
				task.wait(RETRY_DELAY)
			end
		end

		if not crateShopModel then
			log("CrownPetShop NOT FOUND after " .. MAX_RETRIES .. " attempts — walk-up shop disabled")
			log("Workspace children: " .. tostring(#workspace:GetChildren()))
			return
		end

		-- Test position detection immediately
		local initialPos = getInstancePosition(crateShopModel)
		if not initialPos then
			-- Wait for children to load (streaming might delay parts)
			log("Position not available yet, waiting for children to stream in...")
			task.wait(3)
			initialPos = getInstancePosition(crateShopModel)
		end

		if not initialPos then
			-- Last resort: listen for DescendantAdded and try again
			log("Still no position — waiting for any descendant BasePart...")
			local waitedPart = nil
			local conn
			conn = crateShopModel.DescendantAdded:Connect(function(desc)
				if desc:IsA("BasePart") then
					waitedPart = desc
					if conn then conn:Disconnect() end
				end
			end)
			task.wait(5)
			if conn then conn:Disconnect() end

			if waitedPart then
				initialPos = waitedPart.Position
				log("Got position from streamed-in part:", waitedPart:GetFullName())
			else
				log("FAILED: No BasePart found in CrownPetShop after waiting — walk-up disabled")
				log("Children of CrownPetShop:")
				for _, child in ipairs(crateShopModel:GetChildren()) do
					log("  ", child.ClassName, child.Name)
				end
				return
			end
		end

		log(string.format("Walk-up shop position: (%.1f, %.1f, %.1f)", initialPos.X, initialPos.Y, initialPos.Z))

		local OPEN_DISTANCE = 12   -- studs to auto-open
		local CLOSE_DISTANCE = 18  -- studs to auto-close
		local wasInRange = false

		log("Walk-up proximity detection ACTIVE (open at", OPEN_DISTANCE, "studs)")

		RunService.Heartbeat:Connect(function()
			local char = LocalPlayer.Character
			if not char then return end
			local root = char:FindFirstChild("HumanoidRootPart")
			if not root then return end

			-- Re-read position in case model moves
			local pos = getInstancePosition(crateShopModel)
			if not pos then return end

			local dist = (root.Position - pos).Magnitude
			local inRange = dist <= OPEN_DISTANCE

			if inRange and not wasInRange then
				-- Player just walked into range → INSTANTLY open
				wasInRange = true
				openPanel("CrateShop")
				log("Walk-up shop auto-opened (distance:", string.format("%.1f", dist), ")")
			elseif not inRange and wasInRange and dist > CLOSE_DISTANCE then
				-- Player walked away → auto-close if still on crate shop
				wasInRange = false
				if currentPanel == "CrateShop" then
					closeCurrentPanel()
					log("Walk-up shop auto-closed (distance:", string.format("%.1f", dist), ")")
				end
			end
		end)
	end)

	-- 8. Also listen for OpenCrateShop RemoteEvent (server fallback / debug)
	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
		if not remotes then
			log("Remotes folder not found — remote walk-up shop listener skipped")
			return
		end

		local openCrateShopEvent = remotes:WaitForChild("OpenCrateShop", 15)
		if openCrateShopEvent then
			openCrateShopEvent.OnClientEvent:Connect(function()
				log("Crate shop opened via server RemoteEvent")
				openPanel("CrateShop")
			end)
			log("Listening for OpenCrateShop RemoteEvent (backup)")
		end
	end)

	-- 9. Walk-up SpinTheWheel — ProximityPrompt-based (server creates prompt)
	--    Player walks near → Roblox shows "E to Spin" natively → opens panel.
	--    Auto-closes when player walks out of range.
	task.spawn(function()
		local SpinWheelCfg = require(Shared:WaitForChild("SpinWheelConfig"))
		local spinModel = nil
		local MAX_RETRIES = 10
		local RETRY_DELAY = 2

		for attempt = 1, MAX_RETRIES do
			spinModel = workspace:FindFirstChild("SpinTheWheel", true)
			if not spinModel then
				spinModel = workspace:FindFirstChild("SpinTheWheel")
			end
			if spinModel then
				log("[SpinWheel] Model found on attempt " .. attempt .. ": " .. spinModel:GetFullName() .. " (class: " .. spinModel.ClassName .. ")")
				break
			end
			if attempt < MAX_RETRIES then
				log("[SpinWheel] Not found (attempt " .. attempt .. "/" .. MAX_RETRIES .. "), retrying...")
				task.wait(RETRY_DELAY)
			end
		end

		if not spinModel then
			log("[SpinWheel] NOT FOUND after " .. MAX_RETRIES .. " attempts — spin wheel disabled")
			return
		end

		-- Wait for the ProximityPrompt created by SpinWheelBootstrap on server
		log("[SpinWheel] Searching for ProximityPrompt...")
		local prompt: ProximityPrompt? = nil

		-- Search existing descendants
		for _, desc in ipairs(spinModel:GetDescendants()) do
			if desc:IsA("ProximityPrompt") then
				prompt = desc
				break
			end
		end

		-- If not found yet, wait for it (server may still be creating it)
		if not prompt then
			log("[SpinWheel] ProximityPrompt not found yet — waiting for server to create it...")
			local waitStart = tick()
			local MAX_WAIT = 20

			-- Listen for new descendants
			local foundEvent = Instance.new("BindableEvent")
			local conn = spinModel.DescendantAdded:Connect(function(desc)
				if desc:IsA("ProximityPrompt") then
					prompt = desc
					foundEvent:Fire()
				end
			end)

			-- Also poll periodically
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
				foundEvent:Fire() -- unblock even if not found
			end)

			if not prompt then
				foundEvent.Event:Wait()
			end
			conn:Disconnect()
			foundEvent:Destroy()
		end

		-- Fallback: create client-side ProximityPrompt if server didn't
		if not prompt then
			log("[SpinWheel] Server ProximityPrompt not found — creating client-side fallback")
			local triggerPart = nil
			if spinModel:IsA("Model") and spinModel.PrimaryPart then
				triggerPart = spinModel.PrimaryPart
			end
			if not triggerPart then
				triggerPart = spinModel:FindFirstChildWhichIsA("BasePart", true)
			end
			if not triggerPart then
				log("[SpinWheel] No BasePart found in SpinTheWheel — spin wheel disabled")
				return
			end

			prompt = Instance.new("ProximityPrompt")
			prompt.Name = "SpinWheelPrompt"
			prompt.ActionText = "Spin"
			prompt.ObjectText = "Spin The Wheel"
			prompt.KeyboardKeyCode = Enum.KeyCode.E
			prompt.HoldDuration = 0
			prompt.MaxActivationDistance = SpinWheelCfg.OPEN_DISTANCE
			prompt.RequiresLineOfSight = false
			prompt.Parent = triggerPart
			log("[SpinWheel] Client-side ProximityPrompt created on: " .. triggerPart:GetFullName())
		else
			log("[SpinWheel] ProximityPrompt found on: " .. prompt.Parent:GetFullName())
		end

		-- Listen for ProximityPrompt activation → open the SpinWheel UI panel
		prompt.Triggered:Connect(function(playerWhoTriggered)
			if playerWhoTriggered ~= LocalPlayer then return end
			log("[SpinWheel] ProximityPrompt triggered (E pressed) — opening panel")
			openPanel("SpinWheel")
		end)

		-- Auto-close when player walks out of range
		local CLOSE_DIST = SpinWheelCfg.CLOSE_DISTANCE

		RunService.Heartbeat:Connect(function()
			if currentPanel ~= "SpinWheel" then return end

			local char = LocalPlayer.Character
			if not char then return end
			local root = char:FindFirstChild("HumanoidRootPart")
			if not root then return end

			local pos = getInstancePosition(spinModel)
			if not pos then return end

			local dist = (root.Position - pos).Magnitude
			if dist > CLOSE_DIST then
				closeCurrentPanel()
				log("[SpinWheel] Auto-closed (out of range, dist: " .. string.format("%.1f", dist) .. ")")
			end
		end)

		log("[SpinWheel] ProximityPrompt walk-up detection ACTIVE (E to open, auto-close at " .. CLOSE_DIST .. " studs)")
	end)

	log("Initialized — HUD + 9 panels + KillFeed ready (Shop, Crowns, Pets, CrateShop, Index, Spectate, Settings, Icons, SpinWheel)")
end

return UIController
