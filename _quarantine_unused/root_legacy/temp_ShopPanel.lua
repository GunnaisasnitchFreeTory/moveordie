--[[
	ShopPanel  (Premium / Robux Shop)
	Sells Fate Coins, exclusive Crowns, exclusive Pets, VIP bundles.
	All prices are in Robux.

	Features:
	  * Category tabs (Coins, Crowns, Pets, Bundles)
	  * Dark vibrant card grid with rarity borders
	  * Stud texture + sunburst background (via Components.CreatePanel)
	  * Item images from ItemCatalog (single source of truth)

	Used by: UIController (sidebar "Shop" button)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared", 5)
local Deps = require(Shared.ClientDepsProvider)
local UIConfig = Deps.UIConfig
local ItemCatalog = Deps.ItemCatalog

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

-- Track warned IDs so we only warn once per missing catalog entry
local _warnedMissing = {}

local function clearCards()
	for _, child in ipairs(contentFrame:GetChildren()) do
		if child:IsA("Frame") then child:Destroy() end
	end
end

-- Resolve the Fate Coin image once at module load.
-- Uses the canonical Currency.FATE_COINS entry as the single source of truth.
local _fateCoinImage: string = ""
do
	local entry = ItemCatalog.Get and ItemCatalog.Get("Currency", "FATE_COINS") or nil
	if entry and type(entry.image) == "string" and entry.image ~= "" then
		_fateCoinImage = entry.image
	end

	if _fateCoinImage ~= "" then
		print(string.format("[PremiumShop] Coins icon -> type=Currency id=FATE_COINS image=%s", _fateCoinImage))
	else
		warn("[PremiumShop] Coins icon -> type=Currency id=FATE_COINS image=<EMPTY>")
		if ItemCatalog.Currency and ItemCatalog.Currency.FATE_COINS then
			local directImg = ItemCatalog.Currency.FATE_COINS.image
			if directImg and type(directImg) == "string" and directImg ~= "" then
				_fateCoinImage = directImg
				print(string.format("[PremiumShop] Coins icon (direct fallback) -> image=%s", _fateCoinImage))
			end
		end
		if _fateCoinImage == "" then
			warn("[PremiumShop] FATE_COINS image is EMPTY — coin cards will show text fallback")
		end
	end
end

--[[
	fixCoinCardLayout: post-process a Currency card's ItemImage so the
	Fate Coin image visually fills the Icon frame at the correct scale.

	Icon frame is left UNCHANGED — only the ItemImage (ImageLabel) inside
	it is configured.  No UIAspectRatioConstraint or UIScale added.
]]
local _coinLayoutLogged = false

local function fixCoinCardLayout(card: Frame, imageId: string)
	local iconFrame = card:FindFirstChild("Icon")
	if not iconFrame then return end

	-- ── ItemImage: configure to fill Icon at the correct visual scale ──
	local imgLabel = iconFrame:FindFirstChild("ItemImage")
	if not imgLabel or not imgLabel:IsA("ImageLabel") then
		-- Safety net: inject if Components didn't create one
		local letterLabel = iconFrame:FindFirstChild("Letter")
		if letterLabel then letterLabel.Visible = false end

		imgLabel = Instance.new("ImageLabel")
		imgLabel.Name = "ItemImage"
		imgLabel.ZIndex = 2
		imgLabel.Parent = iconFrame
	end

	-- Exact properties from the playtest-verified reference
	imgLabel.BackgroundTransparency = 1
	imgLabel.ImageTransparency      = 0
	imgLabel.AnchorPoint            = Vector2.new(0.25, 0.25)
	imgLabel.Position               = UDim2.fromScale(0, 0)
	imgLabel.Size                   = UDim2.fromScale(2.1, 2.1)
	imgLabel.SizeConstraint         = Enum.SizeConstraint.RelativeXY
	imgLabel.Visible                = true

	if imgLabel.Image ~= imageId then
		imgLabel.Image = imageId
	end

	-- Remove any UIAspectRatioConstraint or UIScale on the ImageLabel
	-- (must not be present per spec)
	for _, child in ipairs(imgLabel:GetChildren()) do
		if child:IsA("UIAspectRatioConstraint") or child:IsA("UIScale") then
			child:Destroy()
		end
	end

	-- Hide fallback Letter text (do not delete)
	local letterLabel = iconFrame:FindFirstChild("Letter")
	if letterLabel then
		letterLabel.Visible = false
	end

	-- One-time debug log
	if not _coinLayoutLogged then
		_coinLayoutLogged = true
		print(string.format(
			"[PremiumShop] Coins ItemImage applied: AnchorPoint=0.25,0.25 Size=2.1x2.1 Image=%s",
			imageId
		))
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

			-- Look up ItemCatalog.Premium for metadata + iconText
			local catEntry = ItemCatalog.Get("Premium", item.id)
			if not catEntry and not _warnedMissing[item.id] then
				_warnedMissing[item.id] = true
				warn(string.format("[ShopPanel] No ItemCatalog.Premium entry for '%s' — using placeholder", item.id))
			end

			-- Resolve the card image.
			-- Currency items: always use the canonical FATE_COINS image.
			-- Other types: use the per-item Premium entry image.
			local catalogImage: string
			if filterType == "Currency" then
				catalogImage = _fateCoinImage
			else
				catalogImage = catEntry and ItemCatalog.GetImage(catEntry) or ""
			end

			local catalogIconText = catEntry and catEntry.iconText or nil

			local card = Components.CreateItemCard(contentFrame, {
				name = item.name,
				rarity = item.rarity or "Rare",
				iconColor = item.iconColor,
				iconText = catalogIconText,
				image = catalogImage,
				tag = item.tag,
				actionText = actionText,
				actionColor = C.RobuxButton,
				onAction = function()
					if UIConfig.DebugLog then
						print(string.format("[ShopPanel] Premium purchase: %s (R$%d)", item.name, item.robux))
					end
				end,
			})
			card.LayoutOrder = order

			-- Post-process: fix ItemImage for Currency cards only
			if filterType == "Currency" and catalogImage ~= "" then
				fixCoinCardLayout(card, catalogImage)
			end
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

	closeBtn.MouseButton1Click:Connect(function()
		SoundUtil.Close()
		ShopPanel.Hide()
	end)

	local tabTitles = {}
	for _, cat in ipairs(CATEGORIES) do
		table.insert(tabTitles, { label = cat.label })
	end

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

	content.Position = UDim2.new(0, 12, 0, S.PanelHeaderHeight + S.TabHeight + 18)
	content.Size = UDim2.new(1, -24, 1, -(S.PanelHeaderHeight + S.TabHeight + 28))

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
