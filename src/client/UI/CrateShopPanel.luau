--[[
	CrateShopPanel
	Lobby crate shop UI — redesigned with 4 crate sections:
	  • Crown Crate (purple) — all Findable crowns
	  • Common Crate (green) — Common pets
	  • Rare Crate (blue) — Rare pets
	  • Epic Crate (purple) — Epic pets

	Each section shows:
	  • Left: Big ViewportFrame showing a representative model
	  • Right-top: All preview thumbnails with item names + drop % (horizontal scroll)
	  • Right-bottom: 3 buy buttons

	Reward popups are shown only from server-confirmed RewardGranted events.

	Used by: UIController (walk-up proximity or OpenCrateShop RemoteEvent)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")

local Shared = ReplicatedStorage:WaitForChild("Shared", 60)
if not Shared then
	warn("[CrateShopPanel] Shared not found after 60s -- disabled")
	return { Init = function() end, Show = function() end, Hide = function() end,
		IsVisible = function() return false end, Toggle = function() end }
end

local CDPModule = Shared:WaitForChild("ClientDepsProvider", 60)
if not CDPModule then
	warn("[CrateShopPanel] ClientDepsProvider MISSING")
	return { Init = function() end, Show = function() end, Hide = function() end,
		IsVisible = function() return false end, Toggle = function() end }
end

local ok, Deps = pcall(require, CDPModule)
if not ok or not Deps then
	warn("[CrateShopPanel] require(ClientDepsProvider) FAILED:", Deps)
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

-- Lazy-load CrateRevealUI (created in same folder)
local _CrateRevealUI = nil
local function getRevealUI()
	if _CrateRevealUI then return _CrateRevealUI end
	local mod = Client:FindFirstChild("CrateRevealUI")
	if mod then
		local okReq, result = pcall(require, mod)
		if okReq then _CrateRevealUI = result end
	end
	return _CrateRevealUI
end

local C = UIConfig.Colors
local S = UIConfig.Sizes

local canvas: CanvasGroup = nil
local uiScale: UIScale = nil
local overlay: Frame = nil
local visible = false
local closeCallback: (() -> ())? = nil
local _inventoryUpdatedConn: RBXScriptConnection? = nil
local _crateCountLabels: { [string]: TextLabel } = {}
local _crateCounts: { [string]: number } = {}
local _pendingRobuxCrateBuys: { [string]: number } = {}
local _pendingRobuxCrateBuyExpiresAt: { [string]: number } = {}
local _buyOpenBusyByCrate: { [string]: boolean } = {}

local CrateShopPanel = {}

-- ═══════════════════════════════════════════════════════════════════
-- HELPERS
-- ═══════════════════════════════════════════════════════════════════

local function getOpenCrateFunc(): RemoteFunction?
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then return nil end
	return remotes:FindFirstChild("OpenCrate")
end

local function getBuyCrateFunc(): RemoteFunction?
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then return nil end
	return remotes:FindFirstChild("BuyCrate")
end

local function getOwnedCratesFunc(): RemoteFunction?
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then return nil end
	return remotes:FindFirstChild("GetOwnedCrates")
end

local function getOpenOwnedCratesFunc(): RemoteFunction?
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then return nil end
	return remotes:FindFirstChild("OpenOwnedCrates")
end

local function showToast(msg: string, okStyle: boolean?)
	if not canvas then return end
	local toast = Instance.new("TextLabel")
	toast.Name = "CrateToast"
	toast.AnchorPoint = Vector2.new(0.5, 0)
	toast.Position = UDim2.new(0.5, 0, 0, 10)
	toast.Size = UDim2.new(0.75, 0, 0, 30)
	toast.BackgroundColor3 = okStyle and Color3.fromRGB(40, 145, 75) or Color3.fromRGB(145, 45, 45)
	toast.BackgroundTransparency = 0.1
	toast.BorderSizePixel = 0
	toast.Font = Enum.Font.GothamBold
	toast.Text = msg
	toast.TextColor3 = Color3.fromRGB(255, 255, 255)
	toast.TextSize = 14
	toast.ZIndex = 200
	toast.Parent = canvas
	Instance.new("UICorner", toast).CornerRadius = UDim.new(0, 8)
	task.delay(2.2, function()
		if toast and toast.Parent then
			toast:Destroy()
		end
	end)
end

local function updateCrateCountLabel(crateId: string, count: number)
	_crateCounts[crateId] = count
	local lbl = _crateCountLabels[crateId]
	if lbl and lbl.Parent then
		lbl.Text = string.format("Owned: %d", math.max(0, math.floor(count)))
	end
end

local function getCrateDisplayName(crateId: string): string
	for _, crate in ipairs(UIConfig.MockCrates or {}) do
		if crate.id == crateId then
			return tostring(crate.name or crateId)
		end
	end
	local stripped = string.gsub(tostring(crateId or "Crate"), "^crate_", "")
	stripped = string.gsub(stripped, "_", " ")
	local titled = string.gsub(stripped, "(%a)([%w_]*)", function(first, rest)
		return string.upper(first) .. string.lower(rest)
	end)
	return titled .. " Crate"
end

local function pluralizeCrateName(displayName: string, qty: number): string
	if qty == 1 then
		return displayName
	end
	if string.sub(displayName, -5) == "Crate" then
		return string.sub(displayName, 1, -2) .. "s"
	end
	return displayName .. "s"
end

local function formatCratePurchaseToast(crateId: string, qty: number, ownedCount: number?): string
	local n = math.max(1, math.floor(tonumber(qty) or 1))
	local name = pluralizeCrateName(getCrateDisplayName(crateId), n)
	local msg = string.format("Purchased %d %s", n, name)
	if ownedCount ~= nil then
		msg = string.format("%s (Owned: %d)", msg, math.max(0, math.floor(ownedCount)))
	end
	return msg
end

--- Get random preview items for a crate from its drop table
local function getPreviewItems(crateId: string, count: number): { any }
	-- Find the MockCrates entry for this crateId
	for _, crate in ipairs(UIConfig.MockCrates) do
		if crate.id == crateId and crate.drops then
			local drops = {}
			for _, d in ipairs(crate.drops) do
				table.insert(drops, d)
			end
			-- Shuffle
			for i = #drops, 2, -1 do
				local j = math.random(1, i)
				drops[i], drops[j] = drops[j], drops[i]
			end
			local result = {}
			for i = 1, math.min(count, #drops) do
				table.insert(result, drops[i])
			end
			return result
		end
	end
	return {}
end

local function showCrateRewards(results)
	local revealUI = getRevealUI()
	if not revealUI then
		return false
	end
	local revealItems = {}
	for _, r in ipairs(results or {}) do
		local shouldShow = (r.grantSuccess == true) or (r.isDuplicate == true)
		if not shouldShow then
			continue
		end
		local entry = ItemCatalog.Get(r.category, r.itemId)
		table.insert(revealItems, {
			name = entry and entry.name or r.itemId,
			rarity = entry and entry.rarity or "Common",
			modelPath = entry and entry.modelPath,
			iconColor = entry and entry.iconColor,
			isDuplicate = r.isDuplicate or false,
			itemId = r.itemId,
			category = r.category,
			itemType = entry and entry.type or "",
			iconText = entry and entry.iconText or "",
			image = entry and entry.image or "",
		})
	end
	if #revealItems > 1 and revealUI.ShowRewards then
		revealUI.ShowRewards(revealItems)
		return true
	elseif #revealItems == 1 and revealUI.ShowReward then
		revealUI.ShowReward(revealItems[1])
		return true
	end
	return false
end

local function openPurchasedCrates(crateId: string, qty: number): boolean
	local openOwned = getOpenOwnedCratesFunc()
	if not openOwned then
		warn("[CrateShop] OpenOwnedCrates RemoteFunction not found")
		return false
	end
	local ok, result = pcall(openOwned.InvokeServer, openOwned, crateId, qty)
	if not ok or not result or not result.success then
		warn("[CrateShop] OpenOwnedCrates failed:", ok and (result.error or result.reason) or result)
		return false
	end
	if type(result.newCount) == "number" then
		updateCrateCountLabel(crateId, result.newCount)
	end
	print(string.format("[CrateUI] ShowingRewardModal crateType=%s qty=%d", crateId, qty))
	return showCrateRewards(result.results)
end

-- ═══════════════════════════════════════════════════════════════════
-- CRATE SECTION BUILDER
-- ═══════════════════════════════════════════════════════════════════

local function createCrateSection(parent: ScrollingFrame, crateData: { [string]: any }, layoutOrder: number)
	local accent = crateData.accentColor or crateData.iconColor

	local section = Instance.new("Frame")
	section.Name = "Crate_" .. crateData.id
	section.Size = UDim2.new(1, -20, 0, 230)
	section.BackgroundColor3 = C.CardBg
	section.BorderSizePixel = 0
	section.LayoutOrder = layoutOrder
	section.Parent = parent

	local sc = Instance.new("UICorner")
	sc.CornerRadius = UDim.new(0, S.CardCorner)
	sc.Parent = section

	local ss = Instance.new("UIStroke")
	ss.Color = accent
	ss.Thickness = 2.5
	ss.Transparency = 0.12
	ss.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	ss.Parent = section

	-- Colored left bar accent
	local leftBar = Instance.new("Frame")
	leftBar.Name = "AccentBar"
	leftBar.Size = UDim2.new(0, 4, 1, -8)
	leftBar.Position = UDim2.fromOffset(2, 4)
	leftBar.BackgroundColor3 = accent
	leftBar.BorderSizePixel = 0
	leftBar.Parent = section
	local lbc = Instance.new("UICorner")
	lbc.CornerRadius = UDim.new(0, 2)
	lbc.Parent = leftBar

	-- ── Left: Big model preview ──
	local bigPreview = Instance.new("Frame")
	bigPreview.Name = "BigPreview"
	bigPreview.Size = UDim2.new(0, 120, 1, -14)
	bigPreview.Position = UDim2.fromOffset(12, 7)
	bigPreview.BackgroundColor3 = crateData.iconColor
	bigPreview.BorderSizePixel = 0
	bigPreview.Parent = section

	local bpc = Instance.new("UICorner")
	bpc.CornerRadius = UDim.new(0, 14)
	bpc.Parent = bigPreview

	local bps = Instance.new("UIStroke")
	bps.Color = Color3.fromRGB(255, 255, 255)
	bps.Thickness = 1.5
	bps.Transparency = 0.5
	bps.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	bps.Parent = bigPreview

	-- All drops for this crate (show every item, no limit)
	local allDrops = crateData.drops or {}
	print(string.format("[CrateShop] %s: %d items to display", crateData.name, #allDrops))

	-- Big preview: show crate box representation (not a random drop item)
	do
		local crateModelPath = crateData.modelPath
		local rendered = false
		if crateModelPath and crateModelPath ~= "" then
			local vp = Components.CreateViewportThumbnail(
				bigPreview,
				crateModelPath,
				UDim2.new(1, -8, 0, 120),
				crateData.iconColor, "")
			vp.Position = UDim2.fromOffset(4, 10)
			vp.BackgroundTransparency = 1
			rendered = ThumbnailRenderer.RenderItemToViewport(vp, { modelPath = crateModelPath })
		end
		if not rendered then
			local crateImg = Instance.new("ImageLabel")
			crateImg.Name = "CrateImage"
			crateImg.AnchorPoint = Vector2.new(0.5, 0)
			crateImg.Size = UDim2.new(0.78, 0, 0, 84)
			crateImg.Position = UDim2.new(0.5, 0, 0, 14)
			crateImg.BackgroundTransparency = 1
			crateImg.Image = "rbxassetid://108812530080296"
			crateImg.ScaleType = Enum.ScaleType.Fit
			crateImg.ImageTransparency = 0
			crateImg.ZIndex = 2
			crateImg.Parent = bigPreview
		end
	end

	-- Crate name under big preview
	local crateName = Instance.new("TextLabel")
	crateName.Name = "Name"
	crateName.AnchorPoint = Vector2.new(0.5, 1)
	crateName.Position = UDim2.new(0.5, 0, 1, -8)
	crateName.Size = UDim2.new(1, -8, 0, 34)
	crateName.BackgroundTransparency = 1
	crateName.Font = Enum.Font.GothamBold
	crateName.TextColor3 = C.TextWhite
	crateName.TextSize = 14
	crateName.Text = crateData.name
	crateName.TextWrapped = true
	crateName.Parent = bigPreview
	local cns = Instance.new("UIStroke")
	cns.Color = Color3.fromRGB(0, 0, 0)
	cns.Thickness = 1.5
	cns.Transparency = 0.22
	cns.Parent = crateName

	-- ── Right side: Title ──
	local titleR = Instance.new("TextLabel")
	titleR.Name = "Title"
	titleR.Size = UDim2.new(1, -155, 0, 24)
	titleR.Position = UDim2.fromOffset(143, 8)
	titleR.BackgroundTransparency = 1
	titleR.Font = Enum.Font.GothamBold
	titleR.TextColor3 = C.TextWhite
	titleR.TextSize = 18
	titleR.TextXAlignment = Enum.TextXAlignment.Left
	titleR.Text = crateData.name
	titleR.Parent = section
	local trs = Instance.new("UIStroke")
	trs.Color = Color3.fromRGB(0, 0, 0)
	trs.Thickness = 1.5
	trs.Transparency = 0.22
	trs.Parent = titleR

	-- ── Right: Preview thumbnails row (horizontal scroll) ──
	local thumbRow = Instance.new("ScrollingFrame")
	thumbRow.Name = "Thumbnails"
	thumbRow.Size = UDim2.new(1, -155, 0, 104)
	thumbRow.Position = UDim2.fromOffset(143, 32)
	thumbRow.BackgroundTransparency = 1
	thumbRow.BorderSizePixel = 0
	thumbRow.ScrollingDirection = Enum.ScrollingDirection.X
	thumbRow.ScrollBarThickness = 4
	thumbRow.ScrollBarImageColor3 = Color3.fromRGB(180, 180, 180)
	thumbRow.ScrollBarImageTransparency = 0.3
	thumbRow.AutomaticCanvasSize = Enum.AutomaticSize.X
	thumbRow.CanvasSize = UDim2.fromScale(0, 0)
	thumbRow.Parent = section

	local thumbLayout = Instance.new("UIListLayout")
	thumbLayout.FillDirection = Enum.FillDirection.Horizontal
	thumbLayout.Padding = UDim.new(0, 6)
	thumbLayout.SortOrder = Enum.SortOrder.LayoutOrder
	thumbLayout.VerticalAlignment = Enum.VerticalAlignment.Top
	thumbLayout.Parent = thumbRow

	-- Compute total chances for percentage display
	local totalChance = 0
	for _, drop in ipairs(allDrops) do
		totalChance = totalChance + (drop.chance or 0)
	end

	local cardsCreated = 0
	for i, item in ipairs(allDrops) do
		local thumbContainer = Instance.new("Frame")
		thumbContainer.Name = "Thumb" .. i
		thumbContainer.Size = UDim2.fromOffset(68, 96)
		thumbContainer.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		thumbContainer.BackgroundTransparency = 0
		thumbContainer.BorderSizePixel = 0
		thumbContainer.LayoutOrder = i
		thumbContainer.Parent = thumbRow
		Instance.new("UICorner", thumbContainer).CornerRadius = UDim.new(0, 6)

		-- THUMBNAIL_RENDERER_RULES:
		-- 1) explicit image -> STATIC
		-- 2) no explicit image -> ThumbnailRenderer
		local staticImage = ""
		local rendererKey = item.modelPath
		local itemType = if crateData.id == "crate_crown" then "CROWN" else "PET"
		if item.itemId and type(item.itemId) == "string" and string.match(item.itemId, "^crown_") then
			itemType = "CROWN"
		end
		if ItemCatalog.ResolveCrownOrPetImage and item.itemId then
			local resolved = ItemCatalog.ResolveCrownOrPetImage(item.itemId, itemType)
			if resolved and resolved.mode == "STATIC" then
				staticImage = resolved.image or ""
			elseif resolved and resolved.mode == "RENDERER" then
				rendererKey = resolved.rendererKey or rendererKey
			end
		end
		if staticImage == "" and type(item.image) == "string" and item.image ~= "" then
			staticImage = item.image
		end

		if staticImage ~= "" then
			local imgLbl = Instance.new("ImageLabel")
			imgLbl.Name = "ThumbImage"
			imgLbl.Position = UDim2.fromOffset(4, 0)
			imgLbl.Size = UDim2.fromOffset(60, 52)
			imgLbl.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
			imgLbl.BackgroundTransparency = 0
			imgLbl.BorderSizePixel = 0
			imgLbl.Image = staticImage
			imgLbl.ScaleType = Enum.ScaleType.Fit
			imgLbl.ZIndex = 3
			imgLbl.Parent = thumbContainer
			Instance.new("UICorner", imgLbl).CornerRadius = UDim.new(0, 6)
		elseif rendererKey and rendererKey ~= "" then
			local vp = Components.CreateViewportThumbnail(
				thumbContainer,
				rendererKey,
				UDim2.fromOffset(60, 52),
				Color3.fromRGB(0, 0, 0),
				item.name and string.sub(item.name, 1, 2) or "?"
			)
			vp.Position = UDim2.fromOffset(4, 0)
			ThumbnailRenderer.RenderItemToViewport(vp, {
				id = item.itemId,
				name = item.name,
				type = itemType,
				modelPath = rendererKey,
				rarity = item.rarity,
			})
		end

		-- Item name label (truncated)
		local nameLbl = Instance.new("TextLabel")
		nameLbl.Size = UDim2.new(1, 0, 0, 14)
		nameLbl.Position = UDim2.fromOffset(0, 54)
		nameLbl.BackgroundTransparency = 1
		nameLbl.Font = Enum.Font.GothamBold
		nameLbl.TextColor3 = C.TextWhite
		nameLbl.TextSize = 9
		nameLbl.Text = item.name or "MISSING ITEM"
		nameLbl.TextTruncate = Enum.TextTruncate.AtEnd
		nameLbl.TextXAlignment = Enum.TextXAlignment.Center
		nameLbl.Parent = thumbContainer

		-- Drop chance label
		local chancePercent = 0
		if totalChance > 0 and item.chance then
			chancePercent = item.chance
		end

		local rarColor = ItemCatalog.GetRarityColor(item.rarity)
		local chanceLbl = Instance.new("TextLabel")
		chanceLbl.Size = UDim2.new(1, 0, 0, 14)
		chanceLbl.Position = UDim2.fromOffset(0, 68)
		chanceLbl.BackgroundTransparency = 1
		chanceLbl.Font = Enum.Font.GothamBold
		chanceLbl.TextColor3 = rarColor or C.TextMuted
		chanceLbl.TextSize = 11
		chanceLbl.Text = string.format("%d%%", chancePercent)
		chanceLbl.TextXAlignment = Enum.TextXAlignment.Center
		chanceLbl.Parent = thumbContainer

		-- Rarity label
		local rarLbl = Instance.new("TextLabel")
		rarLbl.Size = UDim2.new(1, 0, 0, 12)
		rarLbl.Position = UDim2.fromOffset(0, 82)
		rarLbl.BackgroundTransparency = 1
		rarLbl.Font = Enum.Font.Gotham
		rarLbl.TextColor3 = rarColor or C.TextMuted
		rarLbl.TextSize = 9
		rarLbl.Text = item.rarity or ""
		rarLbl.TextXAlignment = Enum.TextXAlignment.Center
		rarLbl.Parent = thumbContainer
		cardsCreated += 1
	end
	print(string.format("[CrateShop] %s: %d cards created", crateData.name, cardsCreated))

	-- ── Buy buttons row ──
	local btnRow = Instance.new("Frame")
	btnRow.Name = "BuyButtons"
	btnRow.AnchorPoint = Vector2.new(0, 1)
	btnRow.Position = UDim2.new(0, 143, 1, -10)
	btnRow.Size = UDim2.new(1, -155, 0, 54)
	btnRow.BackgroundTransparency = 1
	btnRow.BorderSizePixel = 0
	btnRow.Parent = section

	local bLayout = Instance.new("UIListLayout")
	bLayout.FillDirection = Enum.FillDirection.Horizontal
	bLayout.Padding = UDim.new(0, 8)
	bLayout.SortOrder = Enum.SortOrder.LayoutOrder
	bLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	bLayout.Parent = btnRow

	for pi, price in ipairs(crateData.prices) do
		local isRobux = price.currency == "Robux"
		local priceText = isRobux and string.format("%d ROBUX", price.cost) or string.format("F %d", price.cost)
		local btnColor = isRobux and C.RobuxButton or C.BuyButton

		local pBtn = Instance.new("TextButton")
		pBtn.Name = "Price" .. pi
		pBtn.Size = UDim2.fromOffset(105, 50)
		pBtn.BackgroundColor3 = btnColor
		pBtn.Font = Enum.Font.GothamBlack
		pBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
		pBtn.TextSize = 14
		pBtn.Text = priceText .. "\n" .. price.label
		pBtn.TextYAlignment = Enum.TextYAlignment.Center
		pBtn.BorderSizePixel = 0
		pBtn.AutoButtonColor = false
		pBtn.LayoutOrder = pi
		pBtn.Parent = btnRow

		local pbc = Instance.new("UICorner")
		pbc.CornerRadius = UDim.new(0, S.SmBtnCorner)
		pbc.Parent = pBtn

		-- Gradient
		local br, bg, bb = btnColor.R, btnColor.G, btnColor.B
		local pbGrad = Instance.new("UIGradient")
		pbGrad.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.new(math.min(br+0.2,1), math.min(bg+0.2,1), math.min(bb+0.2,1))),
			ColorSequenceKeypoint.new(0.5, btnColor),
			ColorSequenceKeypoint.new(1, Color3.new(math.max(br-0.12,0), math.max(bg-0.12,0), math.max(bb-0.12,0))),
		})
		pbGrad.Rotation = 90
		pbGrad.Parent = pBtn

		local pbs = Instance.new("UIStroke")
		pbs.Color = Color3.fromRGB(0, 0, 0)
		pbs.Thickness = 1.75
		pbs.Transparency = 0.05
		pbs.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		pbs.Parent = pBtn

		-- Determine quantity from label
		local qty = tonumber(string.match(price.label, "(%d+)")) or 1

		AnimUtil.WireButton(pBtn, function()
			SoundUtil.Click()
			print(string.format("[CrateShopUI] Click buy crateType=%s qty=%d currency=%s",
				tostring(crateData.id), qty, isRobux and "Robux" or "F"))

			if isRobux then
				if price.productId and price.productId > 0 then
					_pendingRobuxCrateBuys[crateData.id] = (_pendingRobuxCrateBuys[crateData.id] or 0) + qty
					_pendingRobuxCrateBuyExpiresAt[crateData.id] = os.clock() + 45
					MarketplaceService:PromptProductPurchase(Players.LocalPlayer, price.productId)
				else
					print(string.format("[CrateShop] Robux purchase: %s — %s (no productId)", crateData.name, price.label))
				end
				return
			end

			-- Validate crate ID exists in catalog before firing remote
			if not ItemCatalog.Crates or not ItemCatalog.Crates[crateData.id] then
				warn("[CrateShop] Crate not configured:", crateData.id)
				return
			end

			local buyCrate = getBuyCrateFunc()
			if not buyCrate then
				warn("[CrateShop] BuyCrate RemoteFunction not found")
				return
			end

			local result = buyCrate:InvokeServer(crateData.id, qty, "Coins")
			if result and result.success then
				local newCount = tonumber(result.newCount) or (_crateCounts[crateData.id] or 0)
				if _buyOpenBusyByCrate[crateData.id] then
					return
				end
				_buyOpenBusyByCrate[crateData.id] = true
				local opened = openPurchasedCrates(crateData.id, qty)
				_buyOpenBusyByCrate[crateData.id] = nil
				if not opened then
					-- Keep the crate balance accurate if auto-open fails after purchase.
					updateCrateCountLabel(crateData.id, newCount)
					showToast(formatCratePurchaseToast(crateData.id, qty, newCount), true)
				end
			elseif result then
				if tostring(result.reason) == "INSUFFICIENT_FUNDS" then
					showToast("Not enough Fate Coins", false)
				else
					showToast("Purchase failed", false)
				end
				warn("[CrateShop] Failed:", result.error or result.reason or "unknown")
			end
		end)
	end

	return section
end

-- ═══════════════════════════════════════════════════════════════════
-- PANEL LIFECYCLE
-- ═══════════════════════════════════════════════════════════════════

function CrateShopPanel.Init(screenGui: ScreenGui, onClose: () -> ())
	closeCallback = onClose
	_crateCountLabels = {}
	_crateCounts = {}
	_pendingRobuxCrateBuys = {}
	_pendingRobuxCrateBuyExpiresAt = {}
	_buyOpenBusyByCrate = {}

	overlay = Components.CreateDimOverlay(screenGui, function()
		CrateShopPanel.Hide()
	end)

	local content, closeBtn
	canvas, uiScale, content, closeBtn = Components.CreatePanel(screenGui, "CRATE SHOP", C.HeaderCrate, "Crate")

	closeBtn.MouseButton1Click:Connect(function()
		SoundUtil.Close()
		CrateShopPanel.Hide()
	end)

	-- Override stud texture to Fate Beams asset (only this panel)
	do
		local stud = canvas:FindFirstChild("StudTexture")
		if stud then
			stud.Image = "rbxassetid://70851348312450"
			stud.TileSize = UDim2.fromOffset(96, 96)
			stud.ImageTransparency = 0.88
			stud.ImageColor3 = Color3.fromRGB(255, 255, 255)
		end
	end

	Components.AddListLayout(content, 16)

	do
		local getOwned = getOwnedCratesFunc()
		if getOwned then
			local ok, counts = pcall(getOwned.InvokeServer, getOwned)
			if ok and type(counts) == "table" then
				for crateId, n in pairs(counts) do
					_crateCounts[crateId] = tonumber(n) or 0
				end
			end
		end
	end

	-- Build crate sections from UIConfig.MockCrates (now has 4 entries)
	for i, crate in ipairs(UIConfig.MockCrates) do
		createCrateSection(content, crate, i)
	end

	if not _inventoryUpdatedConn then
		task.spawn(function()
			local remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
			local invUpdate = remotes and remotes:FindFirstChild("InventoryUpdated")
			if invUpdate and invUpdate:IsA("RemoteEvent") then
				_inventoryUpdatedConn = invUpdate.OnClientEvent:Connect(function(reason, data)
					if reason == "CrateBalance" and type(data) == "table" then
						if type(data.counts) == "table" then
							for crateId, n in pairs(data.counts) do
								updateCrateCountLabel(crateId, tonumber(n) or 0)
							end
						elseif type(data.crateId) == "string" then
							updateCrateCountLabel(data.crateId, tonumber(data.newCount) or 0)
						end
						if visible and tonumber(data.qty) and tonumber(data.qty) > 0 and type(data.crateId) == "string" then
							local pending = tonumber(_pendingRobuxCrateBuys[data.crateId]) or 0
							local expiresAt = tonumber(_pendingRobuxCrateBuyExpiresAt[data.crateId]) or 0
							if pending > 0 and os.clock() <= expiresAt then
								local qty = tonumber(data.qty) or 1
								_pendingRobuxCrateBuys[data.crateId] = math.max(0, pending - qty)
								if _pendingRobuxCrateBuys[data.crateId] <= 0 then
									_pendingRobuxCrateBuyExpiresAt[data.crateId] = nil
								end
								if not _buyOpenBusyByCrate[data.crateId] then
									_buyOpenBusyByCrate[data.crateId] = true
									local opened = openPurchasedCrates(data.crateId, qty)
									_buyOpenBusyByCrate[data.crateId] = nil
									if not opened then
										showToast(formatCratePurchaseToast(data.crateId, qty, tonumber(data.newCount)), true)
									end
								end
							end
						end
					end
				end)
			end
		end)
	end
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
