--[[
	IndexPanel
	Discovery/collection grid — ALL crowns AND pets.
	  • Owned  → full icon + name + rarity (vibrant)
	  • Locked → dark card with "?" (dim)

	Features:
	  • Tab bar: Crowns / Pets
	  • Pets tab: sourced from ItemCatalog (single source of truth)
	  • Crowns tab: still uses UIConfig.MockCrowns (unchanged)
	  • Dark theme, stud texture, sunburst (via Components.CreatePanel)

	Used by: UIController (sidebar "Index" button)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UIConfig = require(Shared:WaitForChild("UIConfig"))
local ItemCatalog = require(Shared:WaitForChild("ItemCatalog"))

local Client = script.Parent
local AnimUtil   = require(Client:WaitForChild("AnimUtil"))
local SoundUtil  = require(Client:WaitForChild("SoundUtil"))
local Components = require(Client:WaitForChild("Components"))

local C = UIConfig.Colors
local S = UIConfig.Sizes

local player = Players.LocalPlayer

local canvas: CanvasGroup = nil
local uiScale: UIScale = nil
local overlay: Frame = nil
local contentFrame: ScrollingFrame = nil
local visible = false
local closeCallback: (() -> ())? = nil
local activeTab = 1

local TABS = {
	{ label = "Crowns" },
	{ label = "Pets" },
}

local IndexPanel = {}

local function warnOnce(msg: string)
	warn("[IndexPanel] " .. msg)
end

local function safeCall(name: string, fn: any, ...)
	if type(fn) ~= "function" then
		warnOnce("Missing Components helper: " .. tostring(name))
		return nil
	end
	return fn(...)
end

local function clearCards()
	if not contentFrame then return end
	for _, child in ipairs(contentFrame:GetChildren()) do
		if child:IsA("Frame") then child:Destroy() end
	end
end

local function ensureGrid()
	if not contentFrame then return end
	if not contentFrame:FindFirstChildOfClass("UIGridLayout") then
		safeCall("AddGridLayout", Components.AddGridLayout, contentFrame)
	end
end

-- Helper: read OwnedPets attribute → set of catalog IDs
local function getOwnedPetSet(): { [string]: boolean }
	local json = player:GetAttribute("OwnedPets") or "[]"
	local ok, list = pcall(HttpService.JSONDecode, HttpService, json)
	if not ok or type(list) ~= "table" then return {} end
	local set = {}
	for _, id in ipairs(list) do
		set[id] = true
	end
	return set
end

local function populateCrowns()
	clearCards()
	ensureGrid()

	local crowns = UIConfig.MockCrowns
	if type(crowns) ~= "table" then
		warnOnce("MockCrowns missing or not a table")
		return
	end

	for i, item in ipairs(crowns) do
		safeCall("CreateItemCard", Components.CreateItemCard, contentFrame, {
			name = item.name,
			rarity = item.rarity,
			iconColor = item.iconColor,
			iconText = "👑",
			locked = not item.owned,
			owned = item.owned,
		}).LayoutOrder = i
	end
end

local function populatePets()
	clearCards()
	ensureGrid()

	local allPets = ItemCatalog.GetAllPetsSorted()

	if #allPets == 0 then
		-- Placeholder so the tab never looks "broken" even if data is empty.
		safeCall("CreateItemCard", Components.CreateItemCard, contentFrame, {
			name = "No pets yet",
			rarity = "Common",
			iconColor = C.Cyan,
			iconText = "🐾",
			locked = false,
			owned = false,
		}).LayoutOrder = 1
		return
	end

	local ownedSet = getOwnedPetSet()

	for i, pet in ipairs(allPets) do
		local isOwned = ownedSet[pet.id] == true
		safeCall("CreateItemCard", Components.CreateItemCard, contentFrame, {
			name = pet.name,
			rarity = pet.rarity,
			iconColor = pet.iconColor,
			iconText = pet.iconText or "🐾",
			image = ItemCatalog.GetImage(pet),
			locked = not isOwned,
			owned = isOwned,
		}).LayoutOrder = i
	end
end

local function showTab(idx: number)
	if idx == 1 then
		populateCrowns()
	else
		populatePets()
	end
end

function IndexPanel.Init(screenGui: ScreenGui, onClose: () -> ())
	closeCallback = onClose

	overlay = safeCall("CreateDimOverlay", Components.CreateDimOverlay, screenGui, function()
		IndexPanel.Hide()
	end)

	local content, closeBtn
	canvas, uiScale, content, closeBtn = safeCall("CreatePanel", Components.CreatePanel, screenGui, "📖 INDEX", C.HeaderIndex, "Index")
	contentFrame = content

	if closeBtn then
		AnimUtil.WireButton(closeBtn, function()
			SoundUtil.Close()
			IndexPanel.Hide()
		end)
	end

	-- Tab bar
	-- NOTE: Pre-declare `setActiveTab` so the callback captures the local (Luau scoping).
	local setActiveTab: ((number) -> ())? = nil
	local tabBar
	tabBar, setActiveTab = safeCall("CreateTabBar", Components.CreateTabBar, canvas, TABS, function(idx)
		activeTab = idx

		if type(setActiveTab) == "function" then
			setActiveTab(idx)
		else
			warnOnce("Tab visual updater missing (CreateTabBar did not return update function)")
		end

		showTab(idx)
	end)

	if tabBar then
		tabBar.AnchorPoint = Vector2.new(0.5, 0)
		tabBar.Position = UDim2.new(0.5, 0, 0, S.PanelHeaderHeight + 4)
		tabBar.Size = UDim2.new(1, -20, 0, S.TabHeight + 8)
	end

	-- Shift content below tabs
	if content then
		content.Position = UDim2.new(0, 12, 0, S.PanelHeaderHeight + S.TabHeight + 18)
		content.Size = UDim2.new(1, -24, 1, -(S.PanelHeaderHeight + S.TabHeight + 28))
	end

	safeCall("AddGridLayout", Components.AddGridLayout, contentFrame)
	if type(setActiveTab) == "function" then
		setActiveTab(1)
	end
	showTab(1)

	-- Listen for OwnedPets changes to auto-refresh if Pets tab is active
	player:GetAttributeChangedSignal("OwnedPets"):Connect(function()
		if visible and activeTab == 2 then showTab(2) end
	end)
end

function IndexPanel.Show()
	if visible then return end
	visible = true
	if overlay then overlay.Visible = true end
	showTab(activeTab)
	SoundUtil.Open()
	if canvas and uiScale then
		AnimUtil.OpenPanel(canvas, uiScale)
	end
end

function IndexPanel.Hide()
	if not visible then return end
	visible = false
	if overlay then overlay.Visible = false end
	if canvas and uiScale then
		local t = AnimUtil.ClosePanel(canvas, uiScale)
		task.spawn(function()
			t.Completed:Wait()
			canvas.Visible = false
		end)
	end
	if closeCallback then closeCallback() end
end

function IndexPanel.IsVisible(): boolean
	return visible
end

function IndexPanel.Toggle()
	if visible then IndexPanel.Hide() else IndexPanel.Show() end
end

return IndexPanel
