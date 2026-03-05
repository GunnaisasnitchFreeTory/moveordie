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
local ContentProvider    = game:GetService("ContentProvider")
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
local _inventoryUpdatedConn: RBXScriptConnection? = nil
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
local _petsBgImages: {string} = {
	"rbxassetid://125284831618843",
	"rbxassetid://134436052421277",
	"rbxassetid://104828243058275",
	"rbxassetid://91529728615582",
	"rbxassetid://99697942325285",
	"rbxassetid://110624123106515",
	"rbxassetid://96775279467975",
}
local _petsBgSlidesRoot: Frame? = nil
local _petsBgSlots: {ImageLabel} = {}
local _petsBgThread: thread? = nil
local _petsBgRunning = false

local function clearCards()
	for _, child in ipairs(contentFrame:GetChildren()) do
		local keep = child:IsA("UIGridLayout") or child:IsA("UIPadding") or child:IsA("UIListLayout")
		if not keep then child:Destroy() end
	end
end

local function showShopToast(message: string)
	if not canvas or not canvas.Parent then return end

	local old = canvas:FindFirstChild("ShopToast")
	if old then old:Destroy() end

	local toast = Instance.new("TextLabel")
	toast.Name = "ShopToast"
	toast.AnchorPoint = Vector2.new(0.5, 1)
	toast.Position = UDim2.new(0.5, 0, 1, -18)
	toast.Size = UDim2.new(0, 320, 0, 36)
	toast.BackgroundColor3 = Color3.fromRGB(20, 24, 42)
	toast.BackgroundTransparency = 0.08
	toast.TextColor3 = Color3.fromRGB(255, 255, 255)
	toast.Font = Enum.Font.GothamBold
	toast.TextSize = 14
	toast.Text = tostring(message or "")
	toast.TextTransparency = 1
	toast.BorderSizePixel = 0
	toast.ZIndex = 80
	toast.Parent = canvas
	Instance.new("UICorner", toast).CornerRadius = UDim.new(0, 10)

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(0, 0, 0)
	stroke.Thickness = 1.3
	stroke.Transparency = 0.25
	stroke.Parent = toast

	TweenService:Create(toast, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		TextTransparency = 0
	}):Play()

	task.delay(1.8, function()
		if not toast or not toast.Parent then return end
		local fade = TweenService:Create(toast, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			TextTransparency = 1,
			BackgroundTransparency = 1
		})
		fade:Play()
		fade.Completed:Connect(function()
			if toast then toast:Destroy() end
		end)
	end)
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
	if petsBgFrame then petsBgFrame.Visible = visible_ end
	if visible_ then
		if not petsBgFrame or not petsBgFrame.Parent then return end
		if #_petsBgSlots == 0 or #_petsBgImages == 0 then return end
		-- Preload once; safe to call repeatedly.
		pcall(function()
			ContentProvider:PreloadAsync(_petsBgImages)
		end)

		-- Idempotent restart.
		_petsBgRunning = false
		if _petsBgThread then
			pcall(task.cancel, _petsBgThread)
			_petsBgThread = nil
		end
		for _, slot in ipairs(_petsBgSlots) do
			TweenService:Create(slot, TweenInfo.new(0), { ImageTransparency = 1 }):Play()
		end

		_petsBgRunning = true
		local function shuffled(t: {string}): {string}
			local copy = table.clone(t)
			for i = #copy, 2, -1 do
				local j = math.random(1, i)
				copy[i], copy[j] = copy[j], copy[i]
			end
			return copy
		end

		_petsBgThread = task.spawn(function()
			local slotIdx = 0
			local imgQueue = shuffled(_petsBgImages)
			local imgIdx = 0
			while _petsBgRunning and petsBgFrame and petsBgFrame.Visible do
				slotIdx = (slotIdx % #_petsBgSlots) + 1
				imgIdx += 1
				if imgIdx > #imgQueue then
					imgQueue = shuffled(_petsBgImages)
					imgIdx = 1
				end

				local slot = _petsBgSlots[slotIdx]
				if slot then
					slot.Image = imgQueue[imgIdx]
					slot.ImageTransparency = 1
					slot.Position = UDim2.fromScale(0.5, 0.5)
					slot.Size = UDim2.fromScale(1, 1)
					slot.Rotation = math.random(-2, 2)

					local targetTrans = math.random(76, 86) / 100 -- visible but subtle
					local fadeInDur = math.random(25, 45) / 10
					local holdDur = math.random(30, 70) / 10
					local fadeOutDur = math.random(25, 45) / 10

					local tIn = TweenService:Create(
						slot,
						TweenInfo.new(fadeInDur, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
						{ ImageTransparency = targetTrans }
					)
					tIn:Play()
					tIn.Completed:Wait()
					if not _petsBgRunning then break end

					task.wait(holdDur)
					if not _petsBgRunning then break end

					TweenService:Create(
						slot,
						TweenInfo.new(fadeOutDur, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
						{ ImageTransparency = 1 }
					):Play()

					-- Stagger starts so layers are unsynchronized.
					task.wait(math.random(10, 30) / 10)
				end
			end
			for _, s in ipairs(_petsBgSlots) do
				TweenService:Create(s, TweenInfo.new(0.3), { ImageTransparency = 1 }):Play()
			end
		end)
	else
		_petsBgRunning = false
		if _petsBgThread then
			pcall(task.cancel, _petsBgThread)
			_petsBgThread = nil
		end
		for _, s in ipairs(_petsBgSlots) do
			TweenService:Create(s, TweenInfo.new(0.2), { ImageTransparency = 1 }):Play()
		end
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

local FNAF_BANNER_IMAGE = "rbxassetid://72168519670720"
local FNAF_SINGLE_PRICE = 70000
local function formatCoinText(n: number): string
	local s = tostring(math.max(0, math.floor(n)))
	local k
	repeat
		s, k = string.gsub(s, "^(-?%d+)(%d%d%d)", "%1,%2")
	until k == 0
	return s
end

local function getFnafBundleQuote()
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local quoteRF = remotes and remotes:FindFirstChild("Shop_GetBundleQuote")
	if not quoteRF then
		return nil
	end
	local ok, result = pcall(quoteRF.InvokeServer, quoteRF, "fnaf_all")
	if not ok or type(result) ~= "table" then
		return nil
	end
	return result
end

local function populatePetsTab()
	clearCards()
	setCoinsBgVisible(false)
	setCrownBgVisible(false)
	setPetsBgVisible(true)

	-- Rebuild pets content with ONE vertical UIListLayout:
	--   1) TopRow      (4 cards)
	--   2) FNAFSection (banner + controls)
	-- No spacer frames.
	for _, child in ipairs(contentFrame:GetChildren()) do
		child:Destroy()
	end

	contentFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	contentFrame.CanvasSize = UDim2.fromScale(0, 0)
	contentFrame.ScrollBarThickness = 6
	contentFrame.ScrollingDirection = Enum.ScrollingDirection.Y

	local list = Instance.new("UIListLayout")
	list.Name = "PetsListLayout"
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.FillDirection = Enum.FillDirection.Vertical
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.Padding = UDim.new(0, 12)
	list.Parent = contentFrame

	local FNAF_H = 280

	-- ── Build item data ─────────────────────────────────────────────
	local allPets = ItemCatalog.GetAllPetsSorted and ItemCatalog.GetAllPetsSorted() or {}
	local fnafSet: {[string]: boolean} = {}
	local fnafPetIds = {}
	for _, pet in ipairs(allPets) do
		if pet.collection == "FNAF" then
			fnafSet[pet.id] = true
			table.insert(fnafPetIds, pet.id)
		end
	end

	local topPets = {}
	for _, item in ipairs(UIConfig.MockPremiumItems) do
		if item.type == "ExclusivePet" and not fnafSet[item.id] and #topPets < 4 then
			table.insert(topPets, item)
		end
	end

	local ownedPets = getOwnedSet("OwnedPets")

	local function createPetCard(parent: Instance, item, layoutOrder: number, forceFateCoins: boolean, enablePreview: boolean)
		local petEntry = ItemCatalog.GetPet and ItemCatalog.GetPet(item.id) or nil
		local displayName = (petEntry and petEntry.name) or item.name
		local isFNAFPet = petEntry and petEntry.collection == "FNAF"
		local isGamepass = item.gamepassId and item.gamepassId > 0
		if forceFateCoins then
			isGamepass = false
		end
		local isFateCoins = forceFateCoins or (item.fateCoins and item.fateCoins > 0)
		local isOwned = _locallyOwned[item.id] == true or ownedPets[item.id] == true
		if isGamepass then
			-- Gamepass ownership checks can lag after purchase; inventory ownership is authoritative.
			isOwned = isOwned or checkGamepassOwned(item.gamepassId)
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
		-- Enforce shared image resolver rules directly from authoritative pet entry.
		if ItemCatalog.ResolveCrownOrPetImage then
			local resolvedPet = ItemCatalog.ResolveCrownOrPetImage(item.id, "PET")
			if resolvedPet and resolvedPet.mode == "STATIC" then
				catalogImage = resolvedPet.image or ""
				modelPath = nil
			elseif resolvedPet and resolvedPet.mode == "RENDERER" then
				catalogImage = ""
				modelPath = resolvedPet.rendererKey
			end
		end
		local card = Components.CreateItemCard(parent, {
			name       = displayName,
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

		if modelPath and catalogImage == "" and not isFNAFPet then
			local vpFrame = ensureViewportInCard(card, item.iconColor)
			if vpFrame then
				ThumbnailRenderer.RenderItemToViewport(vpFrame, {
					modelPath = modelPath, id = item.id,
					name = item.name, type = "ExclusivePet",
				})
			end
		end

		if enablePreview and _BundlePanel and _BundlePanel.ShowItemPreviewIn then
			local iconFrame = card:FindFirstChild("Icon")
			if iconFrame and iconFrame:IsA("Frame") then
				local click = Instance.new("TextButton")
				click.Name = "PreviewClick"
				click.Size = UDim2.fromScale(1, 1)
				click.BackgroundTransparency = 1
				click.Text = ""
				click.ZIndex = 10
				click.Parent = iconFrame
				click.MouseButton1Click:Connect(function()
					SoundUtil.Click()
					_BundlePanel.ShowItemPreviewIn(canvas, {
						name = displayName,
						image = catalogImage,
						modelPath = modelPath,
					})
				end)
			end
		end
	end

	-- Top row section
	-- IMPORTANT: do not hardcode 2 rows; on wider panels these 4 cards render as 1 row.
	-- If we reserve 2-row height unconditionally, it creates a giant blank gap below cards.
	local topH = S.CardHeight
	local topSection = Instance.new("Frame")
	topSection.Name             = "TopRow"
	topSection.Size             = UDim2.new(1, 0, 0, topH)
	topSection.AutomaticSize    = Enum.AutomaticSize.None
	topSection.BackgroundTransparency = 1
	topSection.LayoutOrder      = 1
	topSection.Parent           = contentFrame

	local grid = Instance.new("UIGridLayout")
	grid.CellSize              = UDim2.fromOffset(S.CardWidth, S.CardHeight)
	grid.CellPadding           = UDim2.fromOffset(S.CardPad, S.CardPad)
	grid.SortOrder             = Enum.SortOrder.LayoutOrder
	grid.FillDirection         = Enum.FillDirection.Horizontal
	grid.HorizontalAlignment   = Enum.HorizontalAlignment.Center
	grid.Parent                = topSection

	for i, item in ipairs(topPets) do
		createPetCard(topSection, item, i, false, false)
	end

	-- Tighten TopRow height to the ACTUAL rendered grid content size.
	task.defer(function()
		if topSection.Parent and grid.Parent then
			local contentY = grid.AbsoluteContentSize.Y
			if contentY and contentY > 0 then
				-- Add a small safety buffer so card strokes/shadows never overlap next section.
				topSection.Size = UDim2.new(1, 0, 0, contentY + 8)
			end
		end
	end)

	local fnafHeader = Instance.new("Frame")
	fnafHeader.Name = "FNAFHeader"
	fnafHeader.Size = UDim2.new(1, -16, 0, 26)
	fnafHeader.BackgroundColor3 = Color3.fromRGB(10, 12, 24)
	fnafHeader.BackgroundTransparency = 0.25
	fnafHeader.BorderSizePixel = 0
	fnafHeader.LayoutOrder = 2
	fnafHeader.Parent = contentFrame
	Instance.new("UICorner", fnafHeader).CornerRadius = UDim.new(0, 8)
	local headerStroke = Instance.new("UIStroke")
	headerStroke.Color = Color3.fromRGB(255, 208, 40)
	headerStroke.Thickness = 1.5
	headerStroke.Transparency = 0.35
	headerStroke.Parent = fnafHeader

	local headerLabel = Instance.new("TextLabel")
	headerLabel.Name = "Label"
	headerLabel.BackgroundTransparency = 1
	headerLabel.Position = UDim2.fromOffset(10, 0)
	headerLabel.Size = UDim2.new(1, -20, 1, 0)
	headerLabel.Font = Enum.Font.GothamBold
	headerLabel.Text = "Limited FNAF Pets"
	headerLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	headerLabel.TextSize = 16
	headerLabel.TextXAlignment = Enum.TextXAlignment.Left
	headerLabel.Parent = fnafHeader
	local headerTextStroke = Instance.new("UIStroke")
	headerTextStroke.Color = Color3.fromRGB(0, 0, 0)
	headerTextStroke.Thickness = 1.6
	headerTextStroke.Transparency = 0.25
	headerTextStroke.Parent = headerLabel

	-- FNAF section: full-width banner, pet grid below, and buy-all button.
	local fnafPets = {}
	for _, pet in ipairs(allPets) do
		if pet.collection == "FNAF" then
			table.insert(fnafPets, pet)
		end
	end

	-- Slightly taller banner to reduce top-edge crop while keeping Crop fill.
	local BANNER_H = 196
	local GRID_COLS = 4
	local TILE_W = 156
	local TILE_H = 130
	local TILE_PAD = 10
	local GRID_ROWS = math.max(1, math.ceil(#fnafPets / GRID_COLS))
	local GRID_H = GRID_ROWS * TILE_H + math.max(0, GRID_ROWS - 1) * TILE_PAD
	local BUY_ALL_H = 42
	local INNER_PAD = 8
	local SECTION_GAP = 12
	local fnafSectionH = BANNER_H + SECTION_GAP + GRID_H + SECTION_GAP + BUY_ALL_H + INNER_PAD

	local fnafSection = Instance.new("Frame")
	fnafSection.Name = "FNAFSection"
	fnafSection.Size = UDim2.new(1, 0, 0, fnafSectionH)
	fnafSection.BackgroundTransparency = 1
	fnafSection.LayoutOrder = 3
	fnafSection.Parent = contentFrame

	local bannerContainer = Instance.new("Frame")
	bannerContainer.Name = "FNAFBanner"
	bannerContainer.Size = UDim2.new(1, -16, 0, BANNER_H)
	bannerContainer.Position = UDim2.fromOffset(8, 0)
	bannerContainer.BackgroundColor3 = Color3.fromRGB(10, 12, 24)
	bannerContainer.BorderSizePixel = 0
	bannerContainer.ClipsDescendants = true
	bannerContainer.Parent = fnafSection
	Instance.new("UICorner", bannerContainer).CornerRadius = UDim.new(0, 10)
	local bannerStroke = Instance.new("UIStroke")
	bannerStroke.Color = Color3.fromRGB(255, 208, 40)
	bannerStroke.Thickness = 2
	bannerStroke.Transparency = 0.15
	bannerStroke.Parent = bannerContainer

	local bannerImage = Instance.new("ImageLabel")
	bannerImage.Name = "CoverImage"
	bannerImage.Size = UDim2.fromScale(1, 1)
	bannerImage.Position = UDim2.fromScale(0, 0)
	bannerImage.AnchorPoint = Vector2.new(0, 0)
	bannerImage.BackgroundTransparency = 1
	bannerImage.Image = FNAF_BANNER_IMAGE
	bannerImage.ScaleType = Enum.ScaleType.Crop
	bannerImage.Parent = bannerContainer

	local bannerTitle = Instance.new("TextLabel")
	bannerTitle.Name = "Title"
	bannerTitle.BackgroundTransparency = 1
	bannerTitle.Position = UDim2.fromOffset(12, 8)
	bannerTitle.Size = UDim2.new(1, -24, 0, 28)
	bannerTitle.Font = Enum.Font.GothamBold
	bannerTitle.Text = "FNAF Pets"
	bannerTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
	bannerTitle.TextSize = 32
	bannerTitle.TextXAlignment = Enum.TextXAlignment.Left
	bannerTitle.ZIndex = 2
	bannerTitle.Parent = bannerContainer
	local titleStroke = Instance.new("UIStroke")
	titleStroke.Color = Color3.fromRGB(0, 0, 0)
	titleStroke.Thickness = 2
	titleStroke.Transparency = 0.2
	titleStroke.Parent = bannerTitle

	local gridHost = Instance.new("Frame")
	gridHost.Name = "FNAFPetGrid"
	gridHost.BackgroundTransparency = 1
	gridHost.Position = UDim2.fromOffset(8, BANNER_H + SECTION_GAP)
	gridHost.Size = UDim2.new(1, -16, 0, GRID_H)
	gridHost.Parent = fnafSection

	local fnafGrid = Instance.new("UIGridLayout")
	fnafGrid.CellSize = UDim2.fromOffset(TILE_W, TILE_H)
	fnafGrid.CellPadding = UDim2.fromOffset(TILE_PAD, TILE_PAD)
	fnafGrid.FillDirection = Enum.FillDirection.Horizontal
	fnafGrid.SortOrder = Enum.SortOrder.LayoutOrder
	fnafGrid.HorizontalAlignment = Enum.HorizontalAlignment.Center
	fnafGrid.Parent = gridHost

	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local buyRF = remotes and remotes:FindFirstChild("Shop_BuyWithCoins")
	for i, pet in ipairs(fnafPets) do
		local resolved = ItemCatalog.ResolveCrownOrPetImage and ItemCatalog.ResolveCrownOrPetImage(pet.id, "PET") or nil
		local imageId = (resolved and resolved.image) or ItemCatalog.GetImage(pet)
		local isOwned = _locallyOwned[pet.id] == true or ownedPets[pet.id] == true

		local tile = Instance.new("Frame")
		tile.Name = "FNAFTile_" .. pet.id
		tile.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		tile.BorderSizePixel = 0
		tile.LayoutOrder = i
		tile.Parent = gridHost
		Instance.new("UICorner", tile).CornerRadius = UDim.new(0, 8)
		local tileStroke = Instance.new("UIStroke")
		tileStroke.Color = Color3.fromRGB(255, 208, 40)
		tileStroke.Thickness = 1.5
		tileStroke.Transparency = 0.28
		tileStroke.Parent = tile

		local icon = Instance.new("ImageLabel")
		icon.Name = "Icon"
		icon.BackgroundTransparency = 1
		icon.Position = UDim2.fromOffset(8, 6)
		icon.Size = UDim2.new(1, -16, 0, 70)
		icon.Image = imageId
		icon.ScaleType = Enum.ScaleType.Fit
		icon.Parent = tile
		if _BundlePanel and _BundlePanel.ShowItemPreviewIn then
			local previewClick = Instance.new("TextButton")
			previewClick.Name = "PreviewClick"
			previewClick.Size = UDim2.fromScale(1, 1)
			previewClick.Position = UDim2.fromScale(0, 0)
			previewClick.BackgroundTransparency = 1
			previewClick.Text = ""
			previewClick.ZIndex = 3
			previewClick.Parent = icon
			previewClick.MouseButton1Click:Connect(function()
				SoundUtil.Click()
				_BundlePanel.ShowItemPreviewIn(canvas, {
					name = pet.name,
					image = imageId,
					modelPath = pet.modelPath,
				})
			end)
		end

		local nameLbl = Instance.new("TextLabel")
		nameLbl.Name = "Name"
		nameLbl.BackgroundTransparency = 1
		nameLbl.Position = UDim2.fromOffset(6, 77)
		nameLbl.Size = UDim2.new(1, -12, 0, 18)
		nameLbl.Font = Enum.Font.GothamBold
		nameLbl.TextColor3 = C.TextWhite
		nameLbl.TextSize = 12
		nameLbl.Text = pet.name
		nameLbl.TextTruncate = Enum.TextTruncate.AtEnd
		nameLbl.Parent = tile

		local buyBtn = Instance.new("TextButton")
		buyBtn.Name = "BuyBtn"
		buyBtn.AnchorPoint = Vector2.new(0.5, 1)
		buyBtn.Position = UDim2.new(0.5, 0, 1, -6)
		buyBtn.Size = UDim2.new(1, -12, 0, 26)
		buyBtn.BackgroundColor3 = isOwned and C.DisabledBtn or Color3.fromRGB(255, 200, 30)
		buyBtn.BorderSizePixel = 0
		buyBtn.AutoButtonColor = not isOwned
		buyBtn.Text = isOwned and "OWNED" or "70K F"
		buyBtn.TextColor3 = isOwned and Color3.fromRGB(210, 215, 230) or Color3.fromRGB(35, 25, 0)
		buyBtn.Font = Enum.Font.GothamBold
		buyBtn.TextSize = 12
		buyBtn.Parent = tile
		Instance.new("UICorner", buyBtn).CornerRadius = UDim.new(0, 8)

		buyBtn.MouseButton1Click:Connect(function()
			if isOwned or not buyRF then
				return
			end
			local okBuy, result = pcall(buyRF.InvokeServer, buyRF, pet.id, "ExclusivePet")
			if okBuy and result and result.success then
				_locallyOwned[pet.id] = true
				isOwned = true
				buyBtn.Text = "OWNED"
				buyBtn.BackgroundColor3 = C.DisabledBtn
				buyBtn.TextColor3 = Color3.fromRGB(210, 215, 230)
				buyBtn.AutoButtonColor = false
			elseif okBuy and result and result.reason == "INSUFFICIENT_COINS" then
				local productId = tonumber(result.productId)
				if productId and productId > 0 then
					MarketplaceService:PromptProductPurchase(LocalPlayer, productId)
				else
					warn("[ShopPanel] Missing top-up productId for insufficient FNAF item coins")
				end
			end
		end)
	end

	local buyAllBtn = Instance.new("TextButton")
	buyAllBtn.Name = "BuyAllFNAFBtn"
	buyAllBtn.BackgroundColor3 = Color3.fromRGB(255, 200, 30)
	buyAllBtn.BorderSizePixel = 0
	buyAllBtn.Position = UDim2.fromOffset(8, BANNER_H + SECTION_GAP + GRID_H + SECTION_GAP)
	buyAllBtn.Size = UDim2.new(1, -16, 0, BUY_ALL_H)
	buyAllBtn.Text = "Buy All FNAF Pets — 150,000 Fate Coins"
	buyAllBtn.TextColor3 = Color3.fromRGB(20, 14, 0)
	buyAllBtn.Font = Enum.Font.GothamBold
	buyAllBtn.TextSize = 18
	buyAllBtn.Parent = fnafSection
	Instance.new("UICorner", buyAllBtn).CornerRadius = UDim.new(0, 10)
	local buyAllStroke = Instance.new("UIStroke")
	buyAllStroke.Color = Color3.fromRGB(0, 0, 0)
	buyAllStroke.Thickness = 1.4
	buyAllStroke.Transparency = 0.35
	buyAllStroke.Parent = buyAllBtn
	local function applyBuyAllStateFromQuote(quote)
		if quote and quote.ok == false and quote.reason == "ALREADY_OWNED" then
			buyAllBtn.Text = "OWNED"
			buyAllBtn.BackgroundColor3 = C.DisabledBtn
			buyAllBtn.TextColor3 = Color3.fromRGB(210, 215, 230)
			buyAllBtn.AutoButtonColor = false
			buyAllBtn.Active = false
			return
		end
		local price = quote and tonumber(quote.price) or 150000
		buyAllBtn.Text = string.format("Buy All FNAF Pets — %s Fate Coins", formatCoinText(price))
		buyAllBtn.BackgroundColor3 = Color3.fromRGB(255, 200, 30)
		buyAllBtn.TextColor3 = Color3.fromRGB(20, 14, 0)
		buyAllBtn.AutoButtonColor = true
		buyAllBtn.Active = true
	end
	applyBuyAllStateFromQuote(getFnafBundleQuote())

	local buyAllBusy = false
	buyAllBtn.MouseButton1Click:Connect(function()
		if buyAllBusy then return end
		local preQuote = getFnafBundleQuote()
		applyBuyAllStateFromQuote(preQuote)
		if preQuote and preQuote.ok == false and preQuote.reason == "ALREADY_OWNED" then
			showShopToast("You already own all FNAF pets.")
			return
		end
		local remotes = ReplicatedStorage:FindFirstChild("Remotes")
		local buyRF = remotes and remotes:FindFirstChild("Shop_BuyWithCoins")
		if not buyRF then
			warn("[ShopPanel] Shop_BuyWithCoins remote not found for FNAF bundle")
			return
		end

		buyAllBusy = true
		buyAllBtn.AutoButtonColor = false

		local okBuy, result = pcall(buyRF.InvokeServer, buyRF, "fnaf_all", "Bundle")
		if okBuy and result and result.success then
			for _, petId in ipairs(fnafPetIds) do
				_locallyOwned[petId] = true
			end
			populatePetsTab()
		else
			local reason = (okBuy and result and result.reason) or "Purchase failed"
			if reason == "ALREADY_OWNED" then
				showShopToast("You already own all FNAF pets.")
				for _, petId in ipairs(fnafPetIds) do
					_locallyOwned[petId] = true
				end
				populatePetsTab()
			elseif reason == "INSUFFICIENT_COINS" then
				local productId = okBuy and result and tonumber(result.productId) or nil
				if productId and productId > 0 then
					showShopToast("Not enough Fate Coins. Opening top-up...")
					MarketplaceService:PromptProductPurchase(LocalPlayer, productId)
				else
					RewardPopup.Show({
						title = "PURCHASE FAILED",
						name = "Not enough Fate Coins",
						itemType = "Currency",
						icon = "rbxassetid://72345557707985",
						okText = "OK",
					})
				end
			else
				RewardPopup.Show({
					title = "PURCHASE FAILED",
					name = tostring(reason),
					itemType = "Currency",
					icon = "rbxassetid://72345557707985",
					okText = "OK",
				})
			end
		end

		buyAllBusy = false
		buyAllBtn.AutoButtonColor = true
		applyBuyAllStateFromQuote(getFnafBundleQuote())
	end)
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

	local bestValueCurrencyId: string? = nil
	if filterType == "Currency" then
		local bestRatio = -math.huge
		for _, entry in ipairs(UIConfig.MockPremiumItems) do
			if entry.type == "Currency" and (entry.robux or 0) > 0 then
				local coinsAmount = tonumber(entry.coinsAmount) or 0
				local ratio = coinsAmount / entry.robux
				if ratio > bestRatio then
					bestRatio = ratio
					bestValueCurrencyId = entry.id
				end
			end
		end
	end

	local order = 0
	for _, item in ipairs(UIConfig.MockPremiumItems) do
		if item.type == filterType then
			order += 1

			local isGamepass  = item.gamepassId and item.gamepassId > 0
			local isProduct   = item.productId and item.productId > 0
			local isFateCoins = item.fateCoins and item.fateCoins > 0

			-- Ownership check (server-confirmed inventory state + local optimistic cache).
			local isOwned = false
			if isGamepass or isFateCoins then
				local attrKey = (filterType == "ExclusiveCrown") and "OwnedCrowns" or "OwnedPets"
				local ownedSet = getOwnedSet(attrKey)
				isOwned = (_locallyOwned[item.id] == true) or (ownedSet[item.id] == true)
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
			local petEntry = (filterType == "ExclusivePet" and ItemCatalog.GetPet and ItemCatalog.GetPet(item.id)) or nil
			local isFNAFPet = petEntry and petEntry.collection == "FNAF"
			local wantsThumbnail = (not hasExplicitImage) and modelPath
				and (filterType == "ExclusivePet" or filterType == "ExclusiveCrown")
				and not isFNAFPet

			local cardData = {
				name = item.name,
				rarity = item.rarity or "Rare",
				iconColor = item.iconColor,
				thumbnailBgColor = catEntry and catEntry.thumbnailBgColor or nil,
				iconText = catalogIconText,
				image = catalogImage,
				modelPath = modelPath,
				tag = (filterType == "Currency" and (
					(item.id == "coins_500" and "POPULAR")
					or (item.id == bestValueCurrencyId and "BEST VALUE")
					or ""
				)) or item.tag,
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

local function ensureTabBarPinned()
	if not _tabBarRef or not _tabBarRef.Parent then return end
	if not _tabBarHostRef or not _tabBarHostRef.Parent then return end
	if not contentFrame or not contentFrame.Parent then return end

	if _tabBarRef:IsDescendantOf(contentFrame) then
		_tabBarRef.Parent = _tabBarHostRef
		_tabBarRef.AnchorPoint = Vector2.new(0.5, 0)
		_tabBarRef.Position = UDim2.new(0.5, 0, 0, 0)
		_tabBarRef.Size = UDim2.new(1, 0, 0, S.TabHeight + 8)
		warn("[TabBarDebug] TabBar was inside scrolling content; reparented to fixed host")
	end
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

	if not _inventoryUpdatedConn then
		task.spawn(function()
			local remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
			local invUpdate = remotes and remotes:FindFirstChild("InventoryUpdated")
			if invUpdate and invUpdate:IsA("RemoteEvent") then
				_inventoryUpdatedConn = invUpdate.OnClientEvent:Connect(function()
					if not visible then return end
					local tab = CATEGORIES[activeTab]
					if tab and tab.filter ~= "Bundle" then
						populateCards(tab.filter)
					end
				end)
			end
		end)
	end

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

		-- Pets tab slideshow root (behind content, non-interactive)
		local slideRoot = Instance.new("Frame")
		slideRoot.Name = "PetsBackgroundSlideshow"
		slideRoot.Size = UDim2.fromScale(1, 1)
		slideRoot.Position = UDim2.fromScale(0, 0)
		slideRoot.BackgroundTransparency = 1
		slideRoot.BorderSizePixel = 0
		slideRoot.ZIndex = 4
		slideRoot.Active = false
		slideRoot.Selectable = false
		slideRoot.ClipsDescendants = true
		slideRoot.Parent = pbf
		_petsBgSlidesRoot = slideRoot
		_petsBgSlots = {}

		for i = 1, 3 do
			local lbl = Instance.new("ImageLabel")
			lbl.Name = "PetsBgSlot" .. i
			lbl.AnchorPoint = Vector2.new(0.5, 0.5)
			lbl.Position = UDim2.fromScale(0.5, 0.5)
			lbl.Size = UDim2.fromScale(1, 1)
			lbl.BackgroundTransparency = 1
			lbl.Image = ""
			lbl.ScaleType = Enum.ScaleType.Crop
			lbl.ImageTransparency = 1
			lbl.ZIndex = 4
			lbl.Active = false
			lbl.Selectable = false
			lbl.Parent = slideRoot
			table.insert(_petsBgSlots, lbl)
		end

		local shade = Instance.new("Frame")
		shade.Name = "PetsBackgroundShade"
		shade.Size = UDim2.fromScale(1, 1)
		shade.Position = UDim2.fromScale(0, 0)
		shade.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		shade.BackgroundTransparency = 0.72
		shade.BorderSizePixel = 0
		shade.ZIndex = 4
		shade.Active = false
		shade.Selectable = false
		shade.Parent = slideRoot
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
	setPetsBgVisible(false)
	local t = AnimUtil.ClosePanel(canvas, uiScale)
	task.spawn(function()
		t.Completed:Wait()
		canvas.Visible = false
	end)
	if closeCallback then closeCallback() end
end

-- Refresh cards after a gamepass purchase completes
MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(a, b, c)
	local gamepassId: number? = nil
	local wasPurchased: boolean? = nil
	if typeof(a) == "Instance" and a:IsA("Player") then
		gamepassId = tonumber(b)
		wasPurchased = (c == true)
	else
		gamepassId = tonumber(a)
		wasPurchased = (b == true)
	end
	print(string.format("[GamePassClient] finished gamepassId=%s purchased=%s",
		tostring(gamepassId), tostring(wasPurchased)))
	if wasPurchased then
		task.wait(0.5)
		local verifyRF = ReplicatedStorage:FindFirstChild("Remotes")
			and ReplicatedStorage.Remotes:FindFirstChild("VerifyGamepassPurchase")
		if verifyRF and gamepassId and gamepassId > 0 then
			pcall(function() verifyRF:InvokeServer(gamepassId) end)
		end
		if visible and activeTab and CATEGORIES[activeTab] and CATEGORIES[activeTab].filter ~= "Bundle" then
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