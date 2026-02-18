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

	After purchase, shows reward via CrateRevealUI.

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

local CrateShopPanel = {}

-- ═══════════════════════════════════════════════════════════════════
-- HELPERS
-- ═══════════════════════════════════════════════════════════════════

local function getOpenCrateFunc(): RemoteFunction?
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then return nil end
	return remotes:FindFirstChild("OpenCrate")
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
				crateData.iconColor,
				"\240\159\147\166"
			)
			vp.Position = UDim2.fromOffset(4, 10)
			vp.BackgroundTransparency = 1
			rendered = ThumbnailRenderer.RenderItemToViewport(vp, { modelPath = crateModelPath })
		end
		if not rendered then
			local emoji = Instance.new("TextLabel")
			emoji.Size = UDim2.new(1, 0, 0, 80)
			emoji.Position = UDim2.fromOffset(0, 20)
			emoji.BackgroundTransparency = 1
			emoji.Font = Enum.Font.GothamBold
			emoji.Text = "\240\159\147\166"
			emoji.TextSize = 52
			emoji.TextColor3 = C.TextWhite
			emoji.Parent = bigPreview
			local emojiStroke = Instance.new("UIStroke")
			emojiStroke.Color = Color3.fromRGB(0, 0, 0)
			emojiStroke.Thickness = 2
			emojiStroke.Transparency = 0.3
			emojiStroke.Parent = emoji
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
	thumbRow.Position = UDim2.fromOffset(143, 36)
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

		-- Thumbnail: prefer static image from ItemCatalog if available
		local staticImage = ""
		if item.itemId then
			local catEntry = ItemCatalog.Crowns and ItemCatalog.Crowns[item.itemId]
			if not catEntry then catEntry = ItemCatalog.Pets and ItemCatalog.Pets[item.itemId] end
			if catEntry then staticImage = ItemCatalog.GetImage(catEntry) end
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
		elseif item.modelPath and item.modelPath ~= "" then
			local vp = Components.CreateViewportThumbnail(
				thumbContainer,
				item.modelPath,
				UDim2.fromOffset(60, 52),
				Color3.fromRGB(0, 0, 0),
				item.name and string.sub(item.name, 1, 2) or "?"
			)
			vp.Position = UDim2.fromOffset(4, 0)
			ThumbnailRenderer.RenderItemToViewport(vp, item)
		end

		-- Item name label (truncated)
		local nameLbl = Instance.new("TextLabel")
		nameLbl.Size = UDim2.new(1, 0, 0, 14)
		nameLbl.Position = UDim2.fromOffset(0, 54)
		nameLbl.BackgroundTransparency = 1
		nameLbl.Font = Enum.Font.GothamBold
		nameLbl.TextColor3 = C.TextWhite
		nameLbl.TextSize = 9
		nameLbl.Text = item.name or "???"
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
		pBtn.Font = Enum.Font.GothamBold
		pBtn.TextColor3 = C.TextWhite
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
		pbs.Color = Color3.fromRGB(255, 255, 255)
		pbs.Thickness = 1.5
		pbs.Transparency = 0.4
		pbs.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		pbs.Parent = pBtn

		-- Determine quantity from label
		local qty = tonumber(string.match(price.label, "(%d+)")) or 1

		AnimUtil.WireButton(pBtn, function()
			SoundUtil.Click()

			if isRobux then
				if price.productId and price.productId > 0 then
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

			local openCrate = getOpenCrateFunc()
			if not openCrate then
				warn("[CrateShop] OpenCrate RemoteFunction not found")
				return
			end

			local result = openCrate:InvokeServer(crateData.id, qty)
			if result and result.success then
				local revealUI = getRevealUI()
				if revealUI then
					-- Collect all rewards into a batch for grid layout
					local revealItems = {}
					for _, r in ipairs(result.results or {}) do
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
					-- Use batch reveal (grid layout) for multi-crate, single reveal for 1
					if #revealItems > 1 and revealUI.ShowRewards then
						revealUI.ShowRewards(revealItems)
					elseif #revealItems == 1 then
						revealUI.ShowReward(revealItems[1])
					end
				else
					-- Fallback: log to console
					for _, r in ipairs(result.results or {}) do
						local entry = ItemCatalog.Get(r.category, r.itemId)
						if r.isDuplicate then
							print(string.format("[CrateShop] Already owned: %s",
								entry and entry.name or r.itemId))
						else
							print(string.format("[CrateShop] Got: %s!",
								entry and entry.name or r.itemId))
						end
					end
				end
			elseif result then
				warn("[CrateShop] Failed:", result.error or "unknown")
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

	overlay = Components.CreateDimOverlay(screenGui, function()
		CrateShopPanel.Hide()
	end)

	local content, closeBtn
	canvas, uiScale, content, closeBtn = Components.CreatePanel(screenGui, "\240\159\147\166 CRATE SHOP", C.HeaderCrate, "Crate")

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

	-- Build crate sections from UIConfig.MockCrates (now has 4 entries)
	for i, crate in ipairs(UIConfig.MockCrates) do
		createCrateSection(content, crate, i)
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
