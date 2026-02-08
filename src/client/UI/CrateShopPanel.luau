--[[
	CrateShopPanel
	Walk-up lobby crate shop UI.
	Opens when the player walks near the CrownPetShop model.
	Sells crates with visible drop chances (matching egg-shop reference).

	DARK + VIBRANT theme — front-page quality:
	  • Big glossy crate icons with glow
	  • Drop chances colour-coded by rarity
	  • Bright buy buttons (green for Coins, Robux-green for R$)
	  • Stud texture + sunburst background (via Components.CreatePanel)

	Used by: UIController (walk-up proximity or OpenCrateShop RemoteEvent)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UIConfig = require(Shared:WaitForChild("UIConfig"))

local Client = script.Parent
local AnimUtil   = require(Client:WaitForChild("AnimUtil"))
local SoundUtil  = require(Client:WaitForChild("SoundUtil"))
local Components = require(Client:WaitForChild("Components"))

local C = UIConfig.Colors

local canvas: CanvasGroup = nil
local uiScale: UIScale = nil
local overlay: Frame = nil
local visible = false
local closeCallback: (() -> ())? = nil

local CrateShopPanel = {}

local function populateCrates(content: ScrollingFrame)
	Components.AddListLayout(content, 16)

	for i, crate in ipairs(UIConfig.MockCrates) do
		Components.CreateCrateSection(content, {
			name = crate.name,
			iconColor = crate.iconColor,
			accentColor = crate.accentColor,
			drops = crate.drops,
			prices = crate.prices,
			onBuy = function(priceIdx)
				local p = crate.prices[priceIdx]
				if UIConfig.DebugLog then
					print(string.format("[CrateShop] Buy: %s — %s (%d %s)", crate.name, p.label, p.cost, p.currency))
				end
			end,
		}).LayoutOrder = i
	end
end

function CrateShopPanel.Init(screenGui: ScreenGui, onClose: () -> ())
	closeCallback = onClose

	overlay = Components.CreateDimOverlay(screenGui, function()
		CrateShopPanel.Hide()
	end)

	local content, closeBtn
	canvas, uiScale, content, closeBtn = Components.CreatePanel(screenGui, "📦 CRATE SHOP", C.HeaderCrate)

	AnimUtil.WireButton(closeBtn, function()
		SoundUtil.Close()
		CrateShopPanel.Hide()
	end)

	populateCrates(content)
end

function CrateShopPanel.Show()
	if visible then return end
	visible = true
	overlay.Visible = true
	SoundUtil.Open()
	AnimUtil.OpenPanel(canvas, uiScale)
end

function CrateShopPanel.Hide()
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

function CrateShopPanel.IsVisible(): boolean
	return visible
end

function CrateShopPanel.Toggle()
	if visible then CrateShopPanel.Hide() else CrateShopPanel.Show() end
end

return CrateShopPanel
