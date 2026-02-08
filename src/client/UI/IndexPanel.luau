--[[
	IndexPanel
	Discovery/collection grid — ALL crowns AND pets.
	  • Owned  → full icon + name + rarity (vibrant)
	  • Locked → dark card with "?" (dim)

	Features:
	  • Tab bar: Crowns / Pets
	  • Dark theme, stud texture, sunburst (via Components.CreatePanel)

	Used by: UIController (sidebar "Index" button)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UIConfig = require(Shared:WaitForChild("UIConfig"))

local Client = script.Parent
local AnimUtil   = require(Client:WaitForChild("AnimUtil"))
local SoundUtil  = require(Client:WaitForChild("SoundUtil"))
local Components = require(Client:WaitForChild("Components"))

local C = UIConfig.Colors
local S = UIConfig.Sizes

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

local function clearCards()
	for _, child in ipairs(contentFrame:GetChildren()) do
		if child:IsA("Frame") then child:Destroy() end
	end
end

local function populateCrowns()
	clearCards()
	if not contentFrame:FindFirstChildOfClass("UIGridLayout") then
		Components.AddGridLayout(contentFrame)
	end
	for i, item in ipairs(UIConfig.MockCrowns) do
		Components.CreateItemCard(contentFrame, {
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
	if not contentFrame:FindFirstChildOfClass("UIGridLayout") then
		Components.AddGridLayout(contentFrame)
	end
	for i, item in ipairs(UIConfig.MockPets) do
		Components.CreateItemCard(contentFrame, {
			name = item.name,
			rarity = item.rarity,
			iconColor = item.iconColor,
			iconText = "🐾",
			locked = not item.owned,
			owned = item.owned,
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

	overlay = Components.CreateDimOverlay(screenGui, function()
		IndexPanel.Hide()
	end)

	local content, closeBtn
	canvas, uiScale, content, closeBtn = Components.CreatePanel(screenGui, "📖 INDEX", C.HeaderIndex)
	contentFrame = content

	AnimUtil.WireButton(closeBtn, function()
		SoundUtil.Close()
		IndexPanel.Hide()
	end)

	-- Tab bar
	local tabBar, setActiveTab = Components.CreateTabBar(canvas, TABS, function(idx)
		activeTab = idx
		setActiveTab(idx)
		showTab(idx)
	end)
	tabBar.AnchorPoint = Vector2.new(0.5, 0)
	tabBar.Position = UDim2.new(0.5, 0, 0, S.PanelHeaderHeight + 4)
	tabBar.Size = UDim2.new(1, -20, 0, S.TabHeight + 8)

	-- Shift content below tabs
	content.Position = UDim2.new(0, 12, 0, S.PanelHeaderHeight + S.TabHeight + 18)
	content.Size = UDim2.new(1, -24, 1, -(S.PanelHeaderHeight + S.TabHeight + 28))

	Components.AddGridLayout(contentFrame)
	setActiveTab(1)
	showTab(1)
end

function IndexPanel.Show()
	if visible then return end
	visible = true
	overlay.Visible = true
	showTab(activeTab)
	SoundUtil.Open()
	AnimUtil.OpenPanel(canvas, uiScale)
end

function IndexPanel.Hide()
	if not visible then return end
	visible = false
	overlay.Visible = false
	local t = AnimUtil.ClosePanel(canvas, uiScale)
	task.spawn(function()
		t.Completed:Wait()
		canvas.Visible = false
	end)
	if closeCallback then closeCallback() end
end

function IndexPanel.IsVisible(): boolean
	return visible
end

function IndexPanel.Toggle()
	if visible then IndexPanel.Hide() else IndexPanel.Show() end
end

return IndexPanel
