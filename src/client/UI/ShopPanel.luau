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
local MarketplaceService = game:GetService("MarketplaceService")
local TweenService       = game:GetService("TweenService")
local Players            = game:GetService("Players")
local HttpService        = game:GetService("HttpService")
local RunService         = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

local Shared = ReplicatedStorage:WaitForChild("Shared", 60)
if not Shared then
	warn("[ShopPanel] Shared not found after 60s -- disabled")
	return { Init = function() end, Show = function() end, Hide = function() end,
		IsVisible = function() return false end, Toggle = function() end }
end

local CDPModule = Shared:WaitForChild("ClientDepsProvider", 60)
if not CDPModule then
	local _children = {}
	for _, c in ipairs(Shared:GetChildren()) do table.insert(_children, c.Name.."("..c.ClassName..")") end
	warn("[ShopPanel] ClientDepsProvider MISSING. Shared path:", Shared:GetFullName(), "| Shared children:", table.concat(_children, ", "))
	return { Init = function() end, Show = function() end, Hide = function() end,
		IsVisible = function() return false end, Toggle = function() end }
end

local ok, Deps = pcall(require, CDPModule)
if not ok or not Deps then
	warn("[ShopPanel] require(ClientDepsProvider) FAILED:", Deps)
	return { Init = function() end, Show = function() end, Hide = function() end,
		IsVisible = function() return false end, Toggle = function() end }
end
local UIConfig = Deps.UIConfig
local ItemCatalog = Deps.ItemCatalog

local Client = script.Parent
local AnimUtil          = require(Client:WaitForChild("AnimUtil"))
local SoundUtil         = require(Client:WaitForChild("SoundUtil"))
local Components        = require(Client:WaitForChild("Components"))
local ThumbnailRenderer = require(Client:WaitForChild("ThumbnailRenderer"))
local RewardPopup       = require(Client:WaitForChild("RewardPopup"))

local C = UIConfig.Colors
local S = UIConfig.Sizes

local canvas: CanvasGroup = nil
local uiScale: UIScale = nil
local overlay: Frame = nil
local contentFrame: ScrollingFrame = nil
local coinsBgArt: ImageLabel? = nil
-- FadeOverlays: a Frame child of coinsBgArt used as container + duplicate guard.
-- Overlays are ImageLabels inside it, created once and reused across open/close cycles.
local _fadeContainer: Frame? = nil           -- "FadeOverlays" frame inside coinsBgArt
local _fadeOverlays: {ImageLabel} = {}       -- the 6 overlay ImageLabels
local _fadeThreads: {thread} = {}            -- per-overlay animation threads
local visible = false
local closeCallback: (() -> ())? = nil
local activeTab = 1
local _setActiveTab: ((number) -> ())? = nil

local CATEGORIES = {
	{ label = "Coins",   filter = "Currency" },
	{ label = "Crowns",  filter = "ExclusiveCrown" },
	{ label = "Pets",    filter = "ExclusivePet" },
	{ label = "Bundles", filter = "Bundle" },
}

local ShopPanel = {}

local _bundlePanelOk, _BundlePanel = false, nil
do
	local bpModule = Client:WaitForChild("BundlePanel", 10)
	if bpModule then
		_bundlePanelOk, _BundlePanel = pcall(require, bpModule)
		if not _bundlePanelOk then
			warn("[ShopPanel] BundlePanel failed to load:", _BundlePanel)
			_BundlePanel = nil
		end
	else
		warn("[ShopPanel] BundlePanel module not found -- bundle tab will be empty")
	end
end

local _warnedMissing = {}
-- Items purchased this session: avoids waiting for OwnedCrowns attribute to propagate
local _locallyOwned: {[string]: true} = {}
local _isPopulating = false  -- guard: prevents duplicate populate runs
-- ─── Crown background animation state ─────────────────────────────
-- Crown images collected once at module load from ItemCatalog.Crowns.
local _crownBgImages: {string} = {}
do
	if ItemCatalog and ItemCatalog.Crowns then
		for _, data in pairs(ItemCatalog.Crowns) do
			local img = (ItemCatalog.GetImage and ItemCatalog.GetImage(data)) or data.image or ""
			if img ~= "" then
				table.insert(_crownBgImages, img)
			end
		end
	end
	print(string.format("[CrownBG] Collected %d crown images", #_crownBgImages))
end

local crownBgFrame: Frame? = nil            -- container Frame, created in Init
local petsBgFrame: Frame? = nil             -- pets tab background matching crown panel color
local _crownSlots: {ImageLabel} = {}        -- 3 reusable ImageLabel slots
local _crownBgThread: thread? = nil         -- single animation coroutine
local _crownBgRunning = false               -- guard: prevents duplicate loops

local function clearCards()
	for _, child in ipairs(contentFrame:GetChildren()) do
		local keep = child:IsA("UIGridLayout") or child:IsA("UIPadding") or child:IsA("UIListLayout")
		if not keep then child:Destroy() end
	end
end

local NUM_OVERLAYS = 6

-- Stop animation threads and reset overlays to fully transparent.
-- Does NOT destroy overlays — they are reused on the next open.
local function stopCoinsBgAnim()
	for _, t in ipairs(_fadeThreads) do
		pcall(task.cancel, t)
	end
	_fadeThreads = {}
	for _, ovl in ipairs(_fadeOverlays) do
		TweenService:Create(ovl, TweenInfo.new(0), { ImageTransparency = 0.97 }):Play()
	end
	print("[PremiumShopBG] Fade stopped")
end

-- Build the FadeOverlays container + 6 overlay ImageLabels (only once).
-- Subsequent calls are no-ops if FadeOverlays already exists.
local function ensureFadeOverlays()
	if not coinsBgArt then return end
	if _fadeContainer and _fadeContainer.Parent then return end  -- already built

	-- Transparent full-size container parented to coinsBgArt
	local container = Instance.new("Frame")
	container.Name               = "FadeOverlays"
	container.AnchorPoint        = Vector2.new(0, 0)
	container.Position           = UDim2.fromScale(0, 0)
	container.Size               = UDim2.fromScale(1, 1)
	container.BackgroundTransparency = 1
	container.BorderSizePixel    = 0
	container.ZIndex             = coinsBgArt.ZIndex + 1
	container.Parent             = coinsBgArt
	_fadeContainer               = container
	_fadeOverlays                = {}

	for i = 1, NUM_OVERLAYS do
		local ovl = Instance.new("ImageLabel")
		ovl.Name                   = "Overlay" .. i
		ovl.AnchorPoint            = Vector2.new(0.5, 0.5)
		-- Slight random position offset: center ± 0.005–0.015 scale
		local ox = (math.random() * 0.02 - 0.01)
		local oy = (math.random() * 0.02 - 0.01)
		ovl.Position               = UDim2.fromScale(0.5 + ox, 0.5 + oy)
		ovl.Size                   = UDim2.fromScale(1.02, 1.02)  -- very slightly oversized to cover seams
		ovl.BackgroundTransparency = 1
		ovl.Image                  = coinsBgArt.Image
		ovl.ScaleType              = Enum.ScaleType.Crop
		ovl.ZIndex                 = container.ZIndex
		ovl.Rotation               = (math.random() * 4 - 2)     -- -2 to +2 degrees
		ovl.ImageTransparency      = 0.97
		ovl.Parent                 = container
		table.insert(_fadeOverlays, ovl)
	end
end

-- Start (or restart) per-overlay fade loops.
-- Overlays are created once by ensureFadeOverlays; this just drives the tweens.
local function startCoinsBgAnim()
	if not coinsBgArt or not coinsBgArt.Parent then return end
	ensureFadeOverlays()
	if #_fadeOverlays == 0 then return end
	-- Stop any existing threads before launching new ones (idempotent restart)
	for _, t in ipairs(_fadeThreads) do pcall(task.cancel, t) end
	_fadeThreads = {}

	for i, ovl in ipairs(_fadeOverlays) do
		local capturedOvl = ovl
		local t = task.spawn(function()
			-- Stagger start so overlays are not synchronized
			task.wait(math.random(0, 30) / 10)  -- 0–3s initial delay per overlay

			while capturedOvl.Parent do
				local fadeDur  = math.random(22, 55) / 10        -- 2.2–5.5s per half-cycle
				local holdDur  = math.random(0, 15) / 10         -- 0–1.5s hold
				local minTrans = math.random(75, 88) / 100       -- 0.75–0.88 (slightly visible)
				local maxTrans = math.random(92, 98) / 100       -- 0.92–0.98 (nearly invisible)

				local tIn = TweenService:Create(
					capturedOvl,
					TweenInfo.new(fadeDur, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
					{ ImageTransparency = minTrans }
				)
				tIn:Play()
				tIn.Completed:Wait()
				if not capturedOvl.Parent then break end

				if holdDur > 0 then
					task.wait(holdDur)
					if not capturedOvl.Parent then break end
				end

				local tOut = TweenService:Create(
					capturedOvl,
					TweenInfo.new(fadeDur, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
					{ ImageTransparency = maxTrans }
				)
				tOut:Play()
				tOut.Completed:Wait()
				if not capturedOvl.Parent then break end
			end
		end)
		table.insert(_fadeThreads, t)
	end

	print(string.format("[PremiumShopBG] Fade overlays ready count=%d", #_fadeOverlays))
end

local function setCoinsBgVisible(visible_: boolean)
	if coinsBgArt then coinsBgArt.Visible = visible_ end
	if visible_ then
		startCoinsBgAnim()
	else
		stopCoinsBgAnim()
	end
end

-- ─── Crown tab animated background ────────────────────────────────

local function stopCrownBgAnim()
	_crownBgRunning = false
	if _crownBgThread then
		pcall(task.cancel, _crownBgThread)
		_crownBgThread = nil
	end
	for _, slot in ipairs(_crownSlots) do
		TweenService:Create(slot, TweenInfo.new(0), { ImageTransparency = 1 }):Play()
	end
end

local function startCrownBgAnim()
	if not crownBgFrame or not crownBgFrame.Parent then return end
	if #_crownBgImages == 0 or #_crownSlots == 0 then return end
	-- Idempotent: kill any running loop before starting a new one
	stopCrownBgAnim()
	_crownBgRunning = true

	local function shuffled(t: {string}): {string}
		local copy = table.clone(t)
		for i = #copy, 2, -1 do
			local j = math.random(1, i)
			copy[i], copy[j] = copy[j], copy[i]
		end
		return copy
	end

	_crownBgThread = task.spawn(function()
		local slotIdx  = 0
		local imgQueue = shuffled(_crownBgImages)
		local imgIdx   = 0

		while _crownBgRunning do
			-- Advance slot (round-robin through 3 slots)
			slotIdx = (slotIdx % #_crownSlots) + 1
			imgIdx  = imgIdx + 1
			if imgIdx > #imgQueue then
				imgQueue = shuffled(_crownBgImages)
				imgIdx   = 1
			end

			local slot = _crownSlots[slotIdx]
			local img  = imgQueue[imgIdx]

			-- Assign new image and randomise placement before fade-in
			slot.Image            = img
			slot.ImageTransparency = 1
			slot.Position = UDim2.fromScale(
				math.random(20, 80) / 100,
				math.random(12, 88) / 100
			)
			slot.Rotation = math.random(-20, 20)

			-- Fade IN  (1.2 s)
			local targetTrans = math.random(94, 97) / 100   -- 0.94–0.97: very dark / barely visible
			local tIn = TweenService:Create(
				slot,
				TweenInfo.new(1.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
				{ ImageTransparency = targetTrans }
			)
			tIn:Play()
			tIn.Completed:Wait()
			if not _crownBgRunning then break end

			-- Hold (1.8–3.5 s)
			task.wait(math.random(18, 35) / 10)
			if not _crownBgRunning then break end

			-- Fire-and-forget fade OUT (1.2 s) — next iteration starts 0.5 s early
			-- creating a cross-fade overlap between two crown images.
			TweenService:Create(
				slot,
				TweenInfo.new(1.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
				{ ImageTransparency = 1 }
			):Play()

			-- Wait 0.7 s: the remaining 0.5 s of the fade-out overlaps the next fade-in
			task.wait(0.7)
			if not _crownBgRunning then break end
		end

		-- Final cleanup: hide all slots
		for _, s in ipairs(_crownSlots) do
			TweenService:Create(s, TweenInfo.new(0.3), { ImageTransparency = 1 }):Play()
		end
	end)
end

local function setCrownBgVisible(visible_: boolean)
	if crownBgFrame then crownBgFrame.Visible = visible_ end
	if visible_ then
		startCrownBgAnim()
	else
		stopCrownBgAnim()
	end
end

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
			warn("[PremiumShop] FATE_COINS image is EMPTY -- coin cards will show text fallback")
		end
	end
end

local _coinLayoutLogged = false

local function fixCoinCardLayout(card: Frame, imageId: string)
	local iconFrame = card:FindFirstChild("Icon")
	if not iconFrame then return end

	local imgLabel = iconFrame:FindFirstChild("ItemImage")
	if not imgLabel or not imgLabel:IsA("ImageLabel") then
		local letterLabel = iconFrame:FindFirstChild("Letter")
		if letterLabel then letterLabel.Visible = false end

		imgLabel = Instance.new("ImageLabel")
		imgLabel.Name = "ItemImage"
		imgLabel.ZIndex = 2
		imgLabel.Parent = iconFrame
	end

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

	for _, child in ipairs(imgLabel:GetChildren()) do
		if child:IsA("UIAspectRatioConstraint") or child:IsA("UIScale") then
			child:Destroy()
		end
	end

	local letterLabel = iconFrame:FindFirstChild("Letter")
	if letterLabel then
		letterLabel.Visible = false
	end

	if not _coinLayoutLogged then
		_coinLayoutLogged = true
		print(string.format(
			"[PremiumShop] Coins ItemImage applied: AnchorPoint=0.25,0.25 Size=2.1x2.1 Image=%s",
			imageId
		))
	end
end

local function ensureViewportInCard(card: Frame, bgColor: Color3?): ViewportFrame?
	local existing = card:FindFirstChild("ModelPreview", true)
	if existing and existing:IsA("ViewportFrame") then
		return existing
	end

	local iconFrame = card:FindFirstChild("Icon")
	if not iconFrame then
		warn("[PremiumShop] Card has no Icon frame -- cannot create ViewportFrame")
		return nil
	end

	for _, child in ipairs(iconFrame:GetChildren()) do
		if child:IsA("TextLabel") or child:IsA("ImageLabel") then
			child:Destroy()
		end
	end

	local vpFrame = Instance.new("ViewportFrame")
	vpFrame.Name = "ModelPreview"
	vpFrame.Size = UDim2.fromScale(1, 1)
	vpFrame.BackgroundColor3 = bgColor or Color3.fromRGB(30, 32, 50)
	vpFrame.BackgroundTransparency = 0.3
	vpFrame.BorderSizePixel = 0
	vpFrame.Parent = iconFrame

	local vpCorner = Instance.new("UICorner")
	vpCorner.CornerRadius = UDim.new(0, 10)
	vpCorner.Parent = vpFrame

	return vpFrame
end

local function checkGamepassOwned(gamepassId: number): boolean
	local ok, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(LocalPlayer.UserId, gamepassId)
	end)
	return ok and owns == true
end

local function getOwnedSet(attrKey: string): {[string]: boolean}
	local out = {}
	local raw = LocalPlayer:GetAttribute(attrKey)
	if type(raw) ~= "string" or raw == "" then
		return out
	end
	local okDec, list = pcall(HttpService.JSONDecode, HttpService, raw)
	if okDec and type(list) == "table" then
		for _, id in ipairs(list) do
			out[id] = true
		end
	end
	return out
end

local function ensureGridLayout()
	for _, child in ipairs(contentFrame:GetChildren()) do
		if child:IsA("UIListLayout") then
			child:Destroy()
		end
	end
	if not contentFrame:FindFirstChildOfClass("UIGridLayout") then
		Components.AddGridLayout(contentFrame)
	end
end

local function setPetsBgVisible(visible_: boolean)
	if petsBgFrame then
		petsBgFrame.Visible = visible_
	end
end

local function resolvePremiumVisual(item, filterType: string)
	local catEntry = ItemCatalog.Get("Premium", item.id)
	if not catEntry and not _warnedMissing[item.id] then
		_warnedMissing[item.id] = true
		warn(string.format("[ShopPanel] No ItemCatalog.Premium entry for '%s' -- using placeholder", item.id))
	end

	local catalogImage: string
	local modelPath: string? = catEntry and catEntry.modelPath or nil
	local catalogIconText = catEntry and catEntry.iconText or nil
	if filterType == "Currency" then
		catalogImage = _fateCoinImage
	else
		local resolved = nil
		if (filterType == "ExclusiveCrown" or filterType == "ExclusivePet")
			and ItemCatalog.ResolveCrownOrPetImage
		then
			local kind = if filterType == "ExclusiveCrown" then "CROWN" else "PET"
			resolved = ItemCatalog.ResolveCrownOrPetImage(item.id, kind)
		end
		if resolved and resolved.mode == "STATIC" then
			catalogImage = resolved.image or ""
			modelPath = nil
		else
			catalogImage = catEntry and ItemCatalog.GetImage(catEntry) or ""
			if resolved and resolved.mode == "RENDERER" then
				modelPath = resolved.rendererKey
			end
		end
	end
	return catEntry, catalogImage, modelPath, catalogIconText
end

local FNAF_BUNDLE_GAMEPASS_ID = 1885101090
local FNAF_BANNER_IMAGE = "rbxassetid://72168519670720"
local FNAF_SINGLE_PRICE = 75000

local function populatePetsTab()
	clearCards()
	setCoinsBgVisible(false)
	setCrownBgVisible(false)
	setPetsBgVisible(true)

	-- Wipe contentFrame completely — no UIListLayout, no UIPadding, nothing.
	-- We use absolute Position for each child so the gap is always exactly
	-- what we specify, with zero influence from layout objects.
	for _, child in ipairs(contentFrame:GetChildren()) do
		child:Destroy()
	end

	-- Absolute-position constants (all in pixels)
	local H_PAD        = 8    -- horizontal inset on each side
	local TOP_PAD      = 10   -- space above first section
	local SECTION_GAP  = 10   -- gap between top-4 section and FNAF section
	local BOTTOM_PAD   = 12   -- space below FNAF section
	local FNAF_H       = 280  -- tall enough for cover art + buttons

	-- ── Build item data ─────────────────────────────────────────────
	local allPets = ItemCatalog.GetAllPetsSorted and ItemCatalog.GetAllPetsSorted() or {}
	local fnafSet: {[string]: boolean} = {}
	for _, pet in ipairs(allPets) do
		if pet.collection == "FNAF" then fnafSet[pet.id] = true end
	end

	local topPets = {}
	for _, item in ipairs(UIConfig.MockPremiumItems) do
		if item.type == "ExclusivePet" and not fnafSet[item.id] and #topPets < 4 then
			table.insert(topPets, item)
		end
	end

	local ownedPets = getOwnedSet("OwnedPets")

	local function createPetCard(parent: Instance, item, layoutOrder: number)
		local isGamepass = item.gamepassId and item.gamepassId > 0
		local isFateCoins = item.fateCoins and item.fateCoins > 0
		local isOwned = false
		if isGamepass then
			isOwned = checkGamepassOwned(item.gamepassId)
		else
			isOwned = _locallyOwned[item.id] == true or ownedPets[item.id] == true
		end

		local actionText, actionColor
		if isOwned then
			actionText = "OWNED"
			actionColor = C.DisabledBtn
		elseif isFateCoins then
			actionText = string.format("%dK F", math.floor(FNAF_SINGLE_PRICE / 1000))
			actionColor = Color3.fromRGB(255, 200, 30)
		else
			actionText = string.format("%d ROBUX", item.robux or 0)
			actionColor = C.RobuxButton
		end

		local _, catalogImage, modelPath, catalogIconText = resolvePremiumVisual(item, "ExclusivePet")
		local card = Components.CreateItemCard(parent, {
			name       = item.name,
			rarity     = item.rarity or "Rare",
			iconColor  = item.iconColor,
			iconText   = catalogIconText,
			image      = catalogImage,
			modelPath  = modelPath,
			tag        = item.tag,
			actionText = actionText,
			actionColor= actionColor,
			onAction = function()
				if isOwned then return end
				if isGamepass then
					MarketplaceService:PromptGamePassPurchase(LocalPlayer, item.gamepassId)
					return
				end
				local remotes = ReplicatedStorage:FindFirstChild("Remotes")
				local buyRF   = remotes and remotes:FindFirstChild("Shop_BuyWithCoins")
				if not buyRF then return end
				local ok, result = pcall(buyRF.InvokeServer, buyRF, item.id, "ExclusivePet")
				if ok and result and result.success then
					_locallyOwned[item.id] = true
					local btn = card:FindFirstChild("ActionBtn")
					if btn and btn:IsA("TextButton") then
						btn.Text = "OWNED"
						btn.BackgroundColor3 = C.DisabledBtn
						btn.Active = false
					end
				end
			end,
		})
		card.Name = "ItemCard_" .. item.id
		card.LayoutOrder = layoutOrder

		if modelPath and catalogImage == "" then
			local vpFrame = ensureViewportInCard(card, item.iconColor)
			if vpFrame then
				ThumbnailRenderer.RenderItemToViewport(vpFrame, {
					modelPath = modelPath, id = item.id,
					name = item.name, type = "ExclusivePet",
				})
			end
		end
	end

	-- ── Top-4 section (UIGridLayout for 2-column card grid) ─────────
	-- Height = rows * CardHeight + (rows-1) * cellPad  (no UIPadding inside,
	-- we handle insets via Position/Size so the math is 100% predictable).
	local topRows    = math.max(1, math.ceil(#topPets / 2))
	local topH       = topRows * S.CardHeight + math.max(0, topRows - 1) * S.CardPad
	local topSection = Instance.new("Frame")
	topSection.Name             = "TopPetsSection"
	topSection.Size             = UDim2.new(1, -H_PAD * 2, 0, topH)
	topSection.Position         = UDim2.fromOffset(H_PAD, TOP_PAD)
	topSection.BackgroundTransparency = 1
	topSection.Parent           = contentFrame

	local grid = Instance.new("UIGridLayout")
	grid.CellSize              = UDim2.fromOffset(S.CardWidth, S.CardHeight)
	grid.CellPadding           = UDim2.fromOffset(S.CardPad, S.CardPad)
	grid.SortOrder             = Enum.SortOrder.LayoutOrder
	grid.HorizontalAlignment   = Enum.HorizontalAlignment.Center
	grid.Parent                = topSection

	for i, item in ipairs(topPets) do
		createPetCard(topSection, item, i)
	end

	-- ── FNAF bundle section (absolute, exactly SECTION_GAP below top) ─
	local fnafYPos   = TOP_PAD + topH + SECTION_GAP
	local fnafSection = Instance.new("Frame")
	fnafSection.Name             = "FNAFSection"
	fnafSection.Size             = UDim2.new(1, -H_PAD * 2, 0, FNAF_H)
	fnafSection.Position         = UDim2.fromOffset(H_PAD, fnafYPos)
	fnafSection.BackgroundTransparency = 1
	fnafSection.ClipsDescendants = false
	fnafSection.Parent           = contentFrame

	if _BundlePanel and _BundlePanel.PopulateInto then
		local fnafPanelHost = Instance.new("ScrollingFrame")
		fnafPanelHost.Name                 = "FNAFBundlePanelHost"
		fnafPanelHost.Size                 = UDim2.fromScale(1, 1)
		fnafPanelHost.BackgroundTransparency = 1
		fnafPanelHost.BorderSizePixel      = 0
		fnafPanelHost.ScrollBarThickness   = 0
		fnafPanelHost.CanvasSize           = UDim2.fromScale(0, 0)
		fnafPanelHost.AutomaticCanvasSize  = Enum.AutomaticSize.None
		fnafPanelHost.ScrollingDirection   = Enum.ScrollingDirection.XY
		fnafPanelHost.Parent               = fnafSection
		_BundlePanel.PopulateInto(fnafPanelHost, {
			bundleIds    = { "fnaf_pets_bundle" },
			itemType     = "ExclusivePet",
			itemCoinPrice= FNAF_SINGLE_PRICE,
		})
		if _BundlePanel.SelectBundle then
			_BundlePanel.SelectBundle("fnaf_pets_bundle")
		end
	end

	-- Set the canvas size explicitly — no AutomaticCanvasSize, no mystery extra height.
	local totalH = fnafYPos + FNAF_H + BOTTOM_PAD
	contentFrame.AutomaticCanvasSize = Enum.AutomaticSize.None
	contentFrame.CanvasSize          = UDim2.fromOffset(0, totalH)
	contentFrame.CanvasPosition      = Vector2.zero
	contentFrame.ScrollBarThickness  = 6
	contentFrame.ScrollingDirection  = Enum.ScrollingDirection.Y

	-- ── Layout diagnostics (Studio only) ──────────────────────────
	if RunService:IsStudio() then
		task.defer(function()
			local topS  = contentFrame:FindFirstChild("TopPetsSection")
			local fnafS = contentFrame:FindFirstChild("FNAFSection")
			if topS and fnafS then
				local topAbsY  = topS.AbsolutePosition.Y
				local topAbsH  = topS.AbsoluteSize.Y
				local fnafAbsY = fnafS.AbsolutePosition.Y
				local gap      = fnafAbsY - (topAbsY + topAbsH)
				print(string.format(
					"[PetsTabLayout] topY=%.0f topH=%.0f fnafY=%.0f gap=%.0f canvasH=%.0f",
					topAbsY, topAbsH, fnafAbsY, gap, totalH
				))
			end
		end)
	end
end

local function populateCards(filterType: string)
	if _isPopulating then return end
	_isPopulating = true
	clearCards()
	setCoinsBgVisible(filterType == "Currency")
	setCrownBgVisible(filterType == "ExclusiveCrown")
	setPetsBgVisible(filterType == "ExclusivePet")

	if filterType == "ExclusivePet" then
		populatePetsTab()
		_isPopulating = false
		return
	end

	ensureGridLayout()

	print(string.format("[PremiumShop] populateCards called -- filterType=%s", filterType))

	local order = 0
	for _, item in ipairs(UIConfig.MockPremiumItems) do
		if item.type == filterType then
			order += 1

			local isGamepass  = item.gamepassId and item.gamepassId > 0
			local isProduct   = item.productId and item.productId > 0
			local isFateCoins = item.fateCoins and item.fateCoins > 0

			-- Ownership check
			local isOwned = false
			if isGamepass then
				isOwned = checkGamepassOwned(item.gamepassId)
			elseif isFateCoins then
				-- Local cache: immediately true after a successful purchase this session
				if _locallyOwned[item.id] then
					isOwned = true
				else
					-- Fallback: check OwnedCrowns/OwnedPets attribute (may lag by a frame)
					local attrKey = (filterType == "ExclusiveCrown") and "OwnedCrowns" or "OwnedPets"
					local raw = LocalPlayer:GetAttribute(attrKey)
					if raw and type(raw) == "string" and raw ~= "" then
						for _, ownedId in ipairs(string.split(raw, ",")) do
							if ownedId == item.id then isOwned = true break end
						end
					end
				end
			end

			local actionText
			local actionColor
			if isOwned then
				actionText = "OWNED"
				actionColor = C.DisabledBtn
			elseif isFateCoins then
				local fmt = item.fateCoins >= 1000
					and string.format("%dK F", math.floor(item.fateCoins / 1000))
					or string.format("%d F", item.fateCoins)
				actionText  = fmt
				actionColor = Color3.fromRGB(255, 200, 30)
			else
				actionText = string.format("%d ROBUX", item.robux or 0)
				actionColor = C.RobuxButton
			end

			local catEntry, catalogImage, modelPath, catalogIconText = resolvePremiumVisual(item, filterType)

			local hasExplicitImage = (catalogImage ~= "")
			local wantsThumbnail = (not hasExplicitImage) and modelPath
				and (filterType == "ExclusivePet" or filterType == "ExclusiveCrown")

			local cardData = {
				name = item.name,
				rarity = item.rarity or "Rare",
				iconColor = item.iconColor,
				thumbnailBgColor = catEntry and catEntry.thumbnailBgColor or nil,
				iconText = catalogIconText,
				image = catalogImage,
				modelPath = modelPath,
				tag = item.tag,
				actionText = actionText,
				actionColor = actionColor,
			onAction = function()
				if isOwned then return end

				if isGamepass then
					MarketplaceService:PromptGamePassPurchase(LocalPlayer, item.gamepassId)
				elseif isProduct then
					MarketplaceService:PromptProductPurchase(LocalPlayer, item.productId)
				elseif isFateCoins then
					local remotes = ReplicatedStorage:FindFirstChild("Remotes")
					local buyRF = remotes and remotes:FindFirstChild("Shop_BuyWithCoins")
					if not buyRF then
						warn("[ShopPanel] Shop_BuyWithCoins remote not found")
						return
					end
					local ok, result = pcall(buyRF.InvokeServer, buyRF, item.id, item.type)
					if ok and result and result.success then
						-- Record locally so ownership check is immediate on next rebuild
						_locallyOwned[item.id] = true
						-- Surgically update ONLY this card's ActionBtn — no full rebuild,
						-- no card-clear flash, no layout shift.
						local cardFrame = contentFrame:FindFirstChild("ItemCard_" .. item.id)
						if cardFrame then
							local actionBtn = cardFrame:FindFirstChild("ActionBtn")
							if actionBtn then
								actionBtn.Text = "OWNED"
								actionBtn.BackgroundColor3 = C.DisabledBtn
								actionBtn.Active = false
								local grad = actionBtn:FindFirstChildOfClass("UIGradient")
								if grad then grad:Destroy() end
							end
						else
							-- Card not found by ID (e.g. first open): fall back to full rebuild
							populateCards(CATEGORIES[activeTab].filter)
						end
						local catEntry = ItemCatalog.Get("Premium", item.id)
						RewardPopup.Show({
							title      = "PURCHASED!",
							name       = item.name,
							itemId     = item.id,
							itemType   = item.type,
							rarityText = item.rarity or (catEntry and catEntry.rarity) or "Legendary",
							okText     = "NICE!",
						})
					elseif ok and result then
						warn(string.format("[ShopPanel] Purchase failed for %s: %s", item.name, tostring(result.reason)))
					else
						warn("[ShopPanel] Remote error:", tostring(result))
					end
				else
					print(string.format("[ShopPanel] No purchase ID for: %s", item.name))
				end
			end,
			}

			local card = Components.CreateItemCard(contentFrame, cardData)
			card.Name        = "ItemCard_" .. item.id   -- ID tag for surgical update
			card.LayoutOrder = order

			if wantsThumbnail then
				local vpFrame = ensureViewportInCard(card, item.iconColor)
				if vpFrame then
					ThumbnailRenderer.RenderItemToViewport(vpFrame, {
						modelPath = modelPath,
						id = item.id,
						name = item.name,
						type = filterType,
					})
				end
			end

			if filterType == "Currency" and catalogImage ~= "" then
				fixCoinCardLayout(card, catalogImage)
			end
		end
	end
	_isPopulating = false
end

function ShopPanel.Init(screenGui: ScreenGui, onClose: () -> ())
	closeCallback = onClose

	overlay = Components.CreateDimOverlay(screenGui, function()
		ShopPanel.Hide()
	end)

	local content, closeBtn
	canvas, uiScale, content, closeBtn = Components.CreatePanel(screenGui, "PREMIUM SHOP", C.HeaderShop, "Shop")
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
		if CATEGORIES[idx].filter == "Bundle" then
			clearCards()
			setCoinsBgVisible(false)
			setCrownBgVisible(false)
			setPetsBgVisible(false)
			if _BundlePanel and _BundlePanel.PopulateInto then
				_BundlePanel.PopulateInto(contentFrame)
			end
			return
		end
		if _BundlePanel and _BundlePanel.ClearContent then
			_BundlePanel.ClearContent()
		end
		populateCards(CATEGORIES[idx].filter)
	end)
	tabBar.AnchorPoint = Vector2.new(0.5, 0)
	tabBar.Position = UDim2.new(0.5, 0, 0, S.PanelHeaderHeight + 4)
	tabBar.Size = UDim2.new(1, -20, 0, S.TabHeight + 8)

	content.Position = UDim2.new(0, 12, 0, S.PanelHeaderHeight + S.TabHeight + 18)
	content.Size = UDim2.new(1, -24, 1, -(S.PanelHeaderHeight + S.TabHeight + 28))

	-- Coins tab decorative background -- sits behind card grid, fixed (not scrollable)
	coinsBgArt = Instance.new("ImageLabel")
	coinsBgArt.Name = "BackgroundArt"
	coinsBgArt.AnchorPoint = Vector2.new(0, 0)
	coinsBgArt.Position = content.Position
	coinsBgArt.Size = content.Size
	coinsBgArt.BackgroundTransparency = 1
	coinsBgArt.Image = "rbxassetid://92371827400252"
	coinsBgArt.ImageTransparency = 0.55     -- subtle, won't compete with cards
	coinsBgArt.ScaleType = Enum.ScaleType.Crop  -- cover-fill, no distortion
	coinsBgArt.ZIndex = 4                   -- below contentFrame (ZIndex 5)
	coinsBgArt.Visible = true               -- Coins is the default tab
	coinsBgArt.Parent = canvas

	-- Crowns tab animated background (cross-fading crown images)
	-- Created once here; startCrownBgAnim/stopCrownBgAnim drive the tweens.
	if #_crownBgImages > 0 then
		local cbf = Instance.new("Frame")
		cbf.Name                  = "CrownBackground"
		cbf.AnchorPoint           = Vector2.new(0, 0)
		cbf.Position              = UDim2.fromScale(0, 0)   -- full canvas
		cbf.Size                  = UDim2.fromScale(1, 1)   -- full canvas
		cbf.BackgroundColor3      = Color3.fromRGB(5, 3, 18)  -- very dark purple-black
		cbf.BackgroundTransparency = 0.35                   -- 65% opaque dark tint
		cbf.BorderSizePixel       = 0
		cbf.ClipsDescendants      = true
		cbf.ZIndex                = 4      -- behind contentFrame (ZIndex 5)
		cbf.Active                = false
		cbf.Selectable            = false
		cbf.Visible               = false
		cbf.Parent                = canvas
		crownBgFrame              = cbf
		_crownSlots               = {}

		for i = 1, 3 do
			local lbl              = Instance.new("ImageLabel")
			lbl.Name               = "CrownSlot" .. i
			lbl.AnchorPoint        = Vector2.new(0.5, 0.5)
			lbl.Position           = UDim2.fromScale(0.5, 0.5)
			lbl.Size               = UDim2.fromScale(0.55, 0.88)
			lbl.BackgroundTransparency = 1
			lbl.Image              = ""
			lbl.ScaleType          = Enum.ScaleType.Fit
			lbl.ImageTransparency  = 1
			lbl.ZIndex             = 4
			lbl.Active             = false
			lbl.Selectable         = false
			lbl.Parent             = cbf
			table.insert(_crownSlots, lbl)
		end
	end

	-- Pets tab background (matches Crowns panel styling)
	do
		local pbf = Instance.new("Frame")
		pbf.Name                  = "PetsBackground"
		pbf.AnchorPoint           = Vector2.new(0, 0)
		pbf.Position              = UDim2.fromScale(0, 0)
		pbf.Size                  = UDim2.fromScale(1, 1)
		pbf.BackgroundColor3      = Color3.fromRGB(5, 3, 18)
		pbf.BackgroundTransparency = 0.35
		pbf.BorderSizePixel       = 0
		pbf.ZIndex                = 4
		pbf.Active                = false
		pbf.Selectable            = false
		pbf.Visible               = false
		pbf.Parent                = canvas
		petsBgFrame               = pbf
	end

	_setActiveTab = setActiveTab

	Components.AddGridLayout(contentFrame)
	setActiveTab(1)
	startCoinsBgAnim()
	populateCards(CATEGORIES[1].filter)
end

function ShopPanel.ActivateBundleTab(bundleId: string?)
	local BUNDLE_TAB = 4
	activeTab = BUNDLE_TAB
	if _setActiveTab then _setActiveTab(BUNDLE_TAB) end
	clearCards()
	if _BundlePanel and _BundlePanel.PopulateInto then
		_BundlePanel.PopulateInto(contentFrame)
	end
	if bundleId and _BundlePanel and _BundlePanel.SelectBundle then
		_BundlePanel.SelectBundle(bundleId)
	end
end

function ShopPanel.Show()
	if visible then return end
	visible = true
	overlay.Visible = true
	SoundUtil.Open()
	AnimUtil.OpenPanel(canvas, uiScale)
	-- Restart crown bg animation if Crowns tab is currently active
	if CATEGORIES[activeTab] and CATEGORIES[activeTab].filter == "ExclusiveCrown" then
		setCrownBgVisible(true)
	end
end

function ShopPanel.Hide()
	if not visible then return end
	visible = false
	overlay.Visible = false
	stopCoinsBgAnim()
	stopCrownBgAnim()
	local t = AnimUtil.ClosePanel(canvas, uiScale)
	task.spawn(function()
		t.Completed:Wait()
		canvas.Visible = false
	end)
	if closeCallback then closeCallback() end
end

-- Refresh cards after a gamepass purchase completes
MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(_player, _gamepassId, wasPurchased)
	if wasPurchased and visible then
		task.wait(0.5)
		local verifyRF = ReplicatedStorage:FindFirstChild("Remotes")
			and ReplicatedStorage.Remotes:FindFirstChild("VerifyGamepassPurchase")
		if verifyRF then
			pcall(function() verifyRF:InvokeServer(_gamepassId) end)
		end
		if activeTab and CATEGORIES[activeTab] and CATEGORIES[activeTab].filter ~= "Bundle" then
			populateCards(CATEGORIES[activeTab].filter)
		end
	end
end)

MarketplaceService.PromptProductPurchaseFinished:Connect(function(_userId, _productId, wasPurchased)
	if wasPurchased and visible then
		task.wait(1)
		if activeTab and CATEGORIES[activeTab] and CATEGORIES[activeTab].filter == "Currency" then
			populateCards("Currency")
		end
	end
end)

function ShopPanel.IsVisible(): boolean
	return visible
end

function ShopPanel.Toggle()
	if visible then ShopPanel.Hide() else ShopPanel.Show() end
end

return ShopPanel