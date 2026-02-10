--[[
	ShopPanel  (Premium / Robux Shop)
	Sells Fate Coins, exclusive Crowns, exclusive Pets, VIP bundles.
	All prices are in Robux.

	Features:
	  • Category tabs (Coins, Crowns, Pets, Bundles)
	  • Dark vibrant card grid with rarity borders
	  • Stud texture + sunburst background (via Components.CreatePanel)

	Used by: UIController (sidebar "Shop" button)
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

local CATEGORIES = {
	{ label = "Coins",   filter = "Currency" },
	{ label = "Crowns",  filter = "ExclusiveCrown" },
	{ label = "Pets",    filter = "ExclusivePet" },
	{ label = "Bundles", filter = "Bundle" },
}

local ShopPanel = {}

local function clearCards()
	for _, child in ipairs(contentFrame:GetChildren()) do
		if child:IsA("Frame") then child:Destroy() end
	end
end

local function populateCards(filterType: string)
	clearCards()

	-- Ensure grid layout exists (or recreate)
	if not contentFrame:FindFirstChildOfClass("UIGridLayout") then
		Components.AddGridLayout(contentFrame)
	end

	local order = 0
	for _, item in ipairs(UIConfig.MockPremiumItems) do
		if item.type == filterType then
			order += 1
			local actionText = string.format("R$ %d", item.robux)
			Components.CreateItemCard(contentFrame, {
				name = item.name,
				rarity = item.rarity or "Rare",
				iconColor = item.iconColor,
				iconText = item.type == "Currency" and "F" or nil,
				tag = item.tag,
				actionText = actionText,
				actionColor = C.RobuxButton,
				onAction = function()
					if UIConfig.DebugLog then
						print(string.format("[ShopPanel] Premium purchase: %s (R$%d)", item.name, item.robux))
					end
				end,
			}).LayoutOrder = order
		end
	end
end

function ShopPanel.Init(screenGui: ScreenGui, onClose: () -> ())
	closeCallback = onClose

	overlay = Components.CreateDimOverlay(screenGui, function()
		ShopPanel.Hide()
	end)

	local content, closeBtn
	canvas, uiScale, content, closeBtn = Components.CreatePanel(screenGui, "💎 PREMIUM SHOP", C.HeaderShop, "Shop")
	contentFrame = content

	-- Wire close button click (visual feedback handled by UIStyle.WireCloseButton in Components)
	closeBtn.MouseButton1Click:Connect(function()
		SoundUtil.Close()
		ShopPanel.Hide()
	end)

	-- Create tab bar (between header and content)
	local tabTitles = {}
	for _, cat in ipairs(CATEGORIES) do
		table.insert(tabTitles, { label = cat.label })
	end

	-- Pre-declare so the closure can capture it (Luau scoping)
	local setActiveTab: ((number) -> ())?
	local tabBar
	tabBar, setActiveTab = Components.CreateTabBar(canvas, tabTitles, function(idx)
		activeTab = idx
		if setActiveTab then
			setActiveTab(idx)
		end
		populateCards(CATEGORIES[idx].filter)
	end)
	tabBar.AnchorPoint = Vector2.new(0.5, 0)
	tabBar.Position = UDim2.new(0.5, 0, 0, S.PanelHeaderHeight + 4)
	tabBar.Size = UDim2.new(1, -20, 0, S.TabHeight + 8)

	-- Shift content below tabs
	content.Position = UDim2.new(0, 12, 0, S.PanelHeaderHeight + S.TabHeight + 18)
	content.Size = UDim2.new(1, -24, 1, -(S.PanelHeaderHeight + S.TabHeight + 28))

	-- Set default tab
	Components.AddGridLayout(contentFrame)
	setActiveTab(1)
	populateCards(CATEGORIES[1].filter)
end

function ShopPanel.Show()
	if visible then return end
	visible = true
	overlay.Visible = true
	SoundUtil.Open()
	AnimUtil.OpenPanel(canvas, uiScale)
end

function ShopPanel.Hide()
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

function ShopPanel.IsVisible(): boolean
	return visible
end

function ShopPanel.Toggle()
	if visible then ShopPanel.Hide() else ShopPanel.Show() end
end

return ShopPanel
