--[[
	RewardPopup
	Shared reward popup used by both Spin Wheel and Crate Shop.
	Lives in StarterPlayerScripts (safe from SharedSanity cleanup).

	Style: Dark rounded card, "YOU WON!" header, medium icon,
	       reward name, rarity line, green OK button.
	       Confetti burst + win sound on reveal.

	API:
	  RewardPopup.Show({...})       -- single reward
	  RewardPopup.ShowBatch({...})  -- multiple rewards (grid layout)
	  RewardPopup.IsActive() → boolean
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local WIN_SFX_ID = "rbxassetid://111217342629113"
local WIN_SFX_VOLUME = 0.5

local AnimUtil = require(script.Parent:WaitForChild("AnimUtil"))

local RewardPopup = {}

local player = Players.LocalPlayer
local _active = false
local _overlay: Frame? = nil
local _onDismissCallback: (() -> ())? = nil

-- ═══════════════════════════════════════════
-- LAZY-LOAD ITEMCATALOG + THUMBNAILRENDERER
-- ═══════════════════════════════════════════
local _ItemCatalog = nil
local function getItemCatalog()
	if _ItemCatalog then return _ItemCatalog end
	pcall(function()
		local Shared = ReplicatedStorage:FindFirstChild("Shared")
		if Shared then
			local cdp = Shared:FindFirstChild("ClientDepsProvider")
			if cdp then
				local Deps = require(cdp)
				_ItemCatalog = Deps and Deps.ItemCatalog
			end
		end
	end)
	return _ItemCatalog
end

local _ThumbnailRenderer = nil
local function getThumbnailRenderer()
	if _ThumbnailRenderer then return _ThumbnailRenderer end
	pcall(function()
		local playerScripts = player:FindFirstChild("PlayerScripts")
		local clientUI = playerScripts and playerScripts:FindFirstChild("Client")
		clientUI = clientUI and clientUI:FindFirstChild("UI")
		local mod = clientUI and clientUI:FindFirstChild("ThumbnailRenderer")
		if mod then _ThumbnailRenderer = require(mod) end
	end)
	return _ThumbnailRenderer
end

local _QuestRewardIconResolver = nil
local function getQuestRewardIconResolver()
	if _QuestRewardIconResolver then return _QuestRewardIconResolver end
	pcall(function()
		local Shared = ReplicatedStorage:FindFirstChild("Shared")
		if Shared then
			local mod = Shared:FindFirstChild("QuestRewardIconResolver")
			if mod then _QuestRewardIconResolver = require(mod) end
		end
	end)
	return _QuestRewardIconResolver
end

-- ═══════════════════════════════════════════
-- LOOKUP CATALOG ENTRY (shared helper)
-- ═══════════════════════════════════════════
local function lookupCatalogEntry(data)
	local IC = getItemCatalog()
	if not IC then return nil end
	if not data.itemId or data.itemId == "" then return nil end
	local t = string.lower(data.itemType or "")

	local entry = nil
	if data.category and data.category ~= "" then
		if IC.Get then entry = IC.Get(data.category, data.itemId) end
	end
	if not entry then
		if t == "pet" and IC.Pets then
			entry = IC.Pets[data.itemId]
		elseif t == "crown" and IC.Crowns then
			entry = IC.Crowns[data.itemId]
		elseif (t == "crate" or t == "crates") and IC.Crates then
			entry = IC.Crates[data.itemId]
		end
	end
	if not entry then
		if IC.Pets and IC.Pets[data.itemId] then entry = IC.Pets[data.itemId]
		elseif IC.Crowns and IC.Crowns[data.itemId] then entry = IC.Crowns[data.itemId]
		elseif IC.Crates and IC.Crates[data.itemId] then entry = IC.Crates[data.itemId] end
	end
	return entry
end

-- ═══════════════════════════════════════════
-- RESOLVE RARITY (authoritative from ItemCatalog)
-- For Pets/Crowns: ALWAYS use catalog rarity, never trust caller.
-- For Coins: use fixed rule based on amount, or caller's value.
-- ═══════════════════════════════════════════
local function resolveRarity(data)
	local callerRarity = data.rarityText or "Common"
	local itemType = data.itemType or ""

	-- Coins: no catalog rarity, use caller's value (which should be set intentionally)
	if itemType == "Coins" or itemType == "FateCoins" then
		print(string.format("[RewardPopup] type=Coins rarity=%s (coins use caller value)", callerRarity))
		return callerRarity
	end

	-- For Pets and Crowns: look up canonical rarity from ItemCatalog
	local entry = lookupCatalogEntry(data)
	if entry and entry.rarity then
		local catalogRarity = entry.rarity
		if catalogRarity ~= callerRarity then
			warn(string.format("[RewardPopup] RARITY MISMATCH! type=%s id=%s catalogRarity=%s callerRarity=%s → using catalog",
				itemType, data.itemId or "?", catalogRarity, callerRarity))
		else
			print(string.format("[RewardPopup] type=%s id=%s catalogRarity=%s popupRarity=%s",
				itemType, data.itemId or "?", catalogRarity, catalogRarity))
		end
		return catalogRarity
	end

	-- Catalog entry not found — use caller's value but warn
	if data.itemId and data.itemId ~= "" then
		warn(string.format("[RewardPopup] No catalog entry for type=%s id=%s — using caller rarity: %s",
			itemType, data.itemId or "?", callerRarity))
	end
	return callerRarity
end

-- ═══════════════════════════════════════════
-- BRAINROT PLACEHOLDER (used when no image asset set for brainrot items)
-- ═══════════════════════════════════════════
local BRAINROT_PLACEHOLDER_IMAGE = "rbxassetid://85473787445447"
local CRATE_FALLBACK_IMAGE = "rbxassetid://108812530080296"

-- ═══════════════════════════════════════════
-- RESOLVE ICON (multi-level fallback + ThumbnailRenderer)
-- Rule: If catalog has a non-empty image → use it (static).
--       No static image but has modelPath → return entry for ThumbnailRenderer.
--       Else → emoji fallback / placeholder.
-- Returns: resolvedImage, fallbackEmoji, fallbackColor, catalogEntry (for ThumbnailRenderer)
-- ═══════════════════════════════════════════
local function resolveIcon(data)
	-- Quest-specific mapping takes precedence when a quest reward descriptor exists.
	local questIconResolver = getQuestRewardIconResolver()
	if questIconResolver and questIconResolver.GetQuestRewardIcon then
		local questIcon = questIconResolver.GetQuestRewardIcon(data.questReward)
		if questIcon and questIcon ~= "" then
			return questIcon, nil, nil, nil
		end
	end

	-- Explicit icon from caller (e.g. wheel-specific asset IDs) always wins
	if data.icon and data.icon ~= "" then
		return data.icon, nil, nil, nil
	end

	local t = string.lower(data.itemType or "")
	local entry = lookupCatalogEntry(data)
	if entry then
		-- If catalog has a non-empty static image, use it
		if entry.image and entry.image ~= "" then
			return entry.image, nil, nil, entry
		end
		-- Crates should never render blank icon in popup.
		if t == "crate" or t == "crates" then
			return CRATE_FALLBACK_IMAGE, nil, nil, entry
		end
		-- No static image but has modelPath → allow ThumbnailRenderer (works for all items)
		if entry.modelPath and entry.modelPath ~= "" then
			return nil, entry.iconText or data.iconText, entry.iconColor or data.iconColor, entry
		end
		-- No image and no modelPath: use placeholder for brainrots, emoji for others
		if entry.source == "brainrot_mode" then
			print("[RewardPopup] Brainrot item with no image or modelPath — using placeholder for:", entry.name or "?")
			return BRAINROT_PLACEHOLDER_IMAGE, nil, nil, entry
		end
		return nil, entry.iconText or data.iconText, entry.iconColor or data.iconColor, entry
	end

	if data.iconText and data.iconText ~= "" then
		return nil, data.iconText, data.iconColor, nil
	end
	warn("[RewardPopup] Missing icon for", data.itemType or "?", data.itemId or "?", data.name or "?")
	return CRATE_FALLBACK_IMAGE, nil, nil, nil
end

-- ═══════════════════════════════════════════
-- RARITY COLORS
-- ═══════════════════════════════════════════
local RARITY_COLORS = {
	Common    = Color3.fromRGB(180, 200, 180),
	Uncommon  = Color3.fromRGB(80, 200, 80),
	Rare      = Color3.fromRGB(60, 140, 255),
	Epic      = Color3.fromRGB(178, 60, 255),
	Legendary = Color3.fromRGB(255, 180, 40),
	Exclusive = Color3.fromRGB(255, 58, 58),
}

-- ═══════════════════════════════════════════
-- WIN SOUND
-- ═══════════════════════════════════════════
local _winSound: Sound? = nil

local function playWinSound()
	if _winSound and _winSound.IsPlaying then
		_winSound:Stop()
	end
	if not _winSound or not _winSound.Parent then
		_winSound = Instance.new("Sound")
		_winSound.Name = "CrateWinSFX"
		_winSound.SoundId = WIN_SFX_ID
		_winSound.Looped = false
		_winSound.Volume = WIN_SFX_VOLUME
		_winSound.Parent = SoundService
	end
	_winSound:Play()
end

-- ═══════════════════════════════════════════
-- CONFETTI BURST (self-contained, same style as Spin Wheel)
-- ═══════════════════════════════════════════
local CONFETTI_COLORS = {
	Color3.fromRGB(255, 0, 0),
	Color3.fromRGB(0, 255, 0),
	Color3.fromRGB(0, 0, 255),
	Color3.fromRGB(255, 255, 0),
	Color3.fromRGB(255, 0, 255),
	Color3.fromRGB(0, 255, 255),
	Color3.fromRGB(255, 128, 0),
	Color3.fromRGB(255, 255, 255),
}

local function spawnConfettiBurst(parent: GuiObject)
	local screenW = parent.AbsoluteSize.X
	local screenH = parent.AbsoluteSize.Y
	if screenW < 10 or screenH < 10 then return end

	local centerX = screenW * 0.5
	local centerY = screenH * 0.5
	local velScale = math.min(screenW, screenH) / 1000

	for _ = 1, 60 do
		local piece = Instance.new("Frame")
		piece.AnchorPoint = Vector2.new(0.5, 0.5)
		piece.BorderSizePixel = 0
		local s = math.random(4, 10)
		piece.Size = UDim2.fromOffset(s, s * math.random(10, 30) / 10)
		piece.Position = UDim2.fromOffset(centerX, centerY)
		piece.BackgroundColor3 = CONFETTI_COLORS[math.random(1, #CONFETTI_COLORS)]
		piece.Rotation = math.random(0, 360)
		piece.ZIndex = 200
		piece.Parent = parent

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 2)
		corner.Parent = piece

		local angle = math.random() * math.pi * 2
		local speed = math.random(800, 1600) * velScale
		local vx = math.cos(angle) * speed
		local vy = math.sin(angle) * speed - math.random(600, 1000) * velScale
		local gravity = 1800 * velScale
		local drag = 0.98
		local rotSpeed = math.random(200, 600) * (math.random(0, 1) == 0 and 1 or -1)
		local t0 = tick()
		local px, py = 0, 0

		local conn
		conn = RunService.Heartbeat:Connect(function(dt)
			if not piece.Parent then
				conn:Disconnect()
				return
			end
			local elapsed = tick() - t0
			if elapsed > 3.5 or py > screenH + 80 then
				piece:Destroy()
				conn:Disconnect()
				return
			end
			vy = vy + gravity * dt
			vx = vx * drag
			px = px + vx * dt
			py = py + vy * dt
			piece.Position = UDim2.fromOffset(centerX + px, centerY + py)
			piece.Rotation = piece.Rotation + rotSpeed * dt
			if elapsed > 2.5 then
				piece.BackgroundTransparency = (elapsed - 2.5) / 1.0
			end
		end)
	end
end

-- ═══════════════════════════════════════════
-- SCREEN GUI
-- ═══════════════════════════════════════════
local _gui: ScreenGui? = nil

local function getGui(): ScreenGui?
	if _gui and _gui.Parent then return _gui end
	local pg = player:FindFirstChild("PlayerGui")
	if not pg then return nil end
	local existing = pg:FindFirstChild("RewardPopupGui")
	if existing then _gui = existing; return existing end
	local sg = Instance.new("ScreenGui")
	sg.Name = "RewardPopupGui"
	sg.DisplayOrder = 120
	sg.IgnoreGuiInset = true
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Parent = pg
	print("[Modal] RewardPopupGui ready (DisplayOrder=120)")
	_gui = sg
	return sg
end

-- ═══════════════════════════════════════════
-- DISMISS
-- ═══════════════════════════════════════════
local function dismiss()
	if not _active then return end
	_active = false
	local ov = _overlay
	if ov and ov.Parent then
		local panel = ov:FindFirstChild("Card") or ov:FindFirstChild("BatchPanel")
		local modalName = panel and panel.Name or "RewardPopup"
		print(string.format("[Modal] Hide %s -> tween out -> hidden", modalName))
		if panel then
			AnimUtil.PopupClose(panel, ov)
		else
			task.delay(0.25, function()
				if ov and ov.Parent then ov:Destroy() end
			end)
		end
	end
	_overlay = nil
	if _onDismissCallback then
		task.spawn(_onDismissCallback)
		_onDismissCallback = nil
	end
end

-- ═══════════════════════════════════════════
-- HELPER: build icon inside a parent frame
-- Supports: static image, ThumbnailRenderer (ViewportFrame for pets), emoji fallback
-- ═══════════════════════════════════════════
local function buildIcon(parent, resolvedImage, fallbackEmoji, fallbackColor, posY, iconSize, zIdx, catalogEntry)
	if resolvedImage and resolvedImage ~= "" then
		local icon = Instance.new("ImageLabel")
		icon.Name = "RewardIcon"
		icon.AnchorPoint = Vector2.new(0.5, 0)
		icon.Position = UDim2.new(0.5, 0, 0, posY)
		icon.Size = UDim2.fromOffset(iconSize, iconSize)
		icon.BackgroundTransparency = 1
		icon.Image = resolvedImage
		icon.ImageTransparency = 0
		icon.ScaleType = Enum.ScaleType.Fit
		icon.Visible = true
		icon.ZIndex = zIdx
		icon.Parent = parent
		local asp = Instance.new("UIAspectRatioConstraint")
		asp.AspectRatio = 1
		asp.Parent = icon
		return
	end

	-- ThumbnailRenderer fallback: for pets/crowns with a modelPath but no static image
	if catalogEntry and catalogEntry.modelPath and catalogEntry.modelPath ~= "" then
		local TR = getThumbnailRenderer()
		if TR then
			local vpFrame = Instance.new("ViewportFrame")
			vpFrame.Name = "RewardIcon"
			vpFrame.AnchorPoint = Vector2.new(0.5, 0)
			vpFrame.Position = UDim2.new(0.5, 0, 0, posY)
			vpFrame.Size = UDim2.fromOffset(iconSize, iconSize)
			vpFrame.BackgroundTransparency = 1
			vpFrame.BorderSizePixel = 0
			vpFrame.Visible = true
			vpFrame.ZIndex = zIdx
			vpFrame.Parent = parent
			Instance.new("UIAspectRatioConstraint", vpFrame).AspectRatio = 1

			local renderOk = TR.RenderItemToViewport(vpFrame, {
				modelPath = catalogEntry.modelPath,
				id = catalogEntry.id or catalogEntry.name,
				name = catalogEntry.name or catalogEntry.modelName,
				type = catalogEntry.type,
				rarity = catalogEntry.rarity,
			})
			if renderOk then
				print("[RewardPopup] ThumbnailRenderer used for:", catalogEntry.modelPath)
				return
			else
				warn("[RewardPopup] ThumbnailRenderer failed for:", catalogEntry.modelPath, "— falling back to emoji")
				vpFrame:Destroy()
			end
		end
	end

	-- Emoji fallback
	if fallbackEmoji and fallbackEmoji ~= "" then
		local emojiHolder = Instance.new("Frame")
		emojiHolder.Name = "RewardIcon"
		emojiHolder.AnchorPoint = Vector2.new(0.5, 0)
		emojiHolder.Position = UDim2.new(0.5, 0, 0, posY)
		emojiHolder.Size = UDim2.fromOffset(iconSize, iconSize)
		emojiHolder.BackgroundColor3 = fallbackColor or Color3.fromRGB(60, 65, 85)
		emojiHolder.BackgroundTransparency = 0.15
		emojiHolder.BorderSizePixel = 0
		emojiHolder.Visible = true
		emojiHolder.ZIndex = zIdx
		emojiHolder.Parent = parent
		Instance.new("UICorner", emojiHolder).CornerRadius = UDim.new(0.5, 0)
		Instance.new("UIAspectRatioConstraint", emojiHolder).AspectRatio = 1
		local ehs = Instance.new("UIStroke")
		ehs.Color = Color3.fromRGB(255, 255, 255)
		ehs.Thickness = 2
		ehs.Transparency = 0.5
		ehs.Parent = emojiHolder
		local emojiLbl = Instance.new("TextLabel")
		emojiLbl.Size = UDim2.fromScale(1, 1)
		emojiLbl.BackgroundTransparency = 1
		emojiLbl.Font = Enum.Font.GothamBold
		emojiLbl.Text = fallbackEmoji
		emojiLbl.TextScaled = true
		emojiLbl.TextColor3 = Color3.fromRGB(255, 255, 255)
		emojiLbl.ZIndex = zIdx + 1
		emojiLbl.Parent = emojiHolder
	end
end

-- ═══════════════════════════════════════════
-- SHOW (single reward)
-- ═══════════════════════════════════════════
function RewardPopup.Show(data)
	if not data then return end

	if _active and _overlay and _overlay.Parent then
		_overlay:Destroy()
		_overlay = nil
		_active = false
	end
	local gui = getGui()
	if not gui then return end

	_active = true
	_onDismissCallback = data.onDismiss

	local titleText = data.title or "YOU WON!"
	local nameText = data.name or "MISSING ITEM"
	local rarityStr = resolveRarity(data)
	local okText = data.okText or "OK"
	local rarityColor = RARITY_COLORS[rarityStr] or RARITY_COLORS.Common
	local resolvedImage, fallbackEmoji, fallbackColor, catalogEntry = resolveIcon(data)

	local wrapper = Instance.new("Frame")
	wrapper.Name = "ModalWrapper"
	wrapper.Size = UDim2.fromScale(1, 1)
	wrapper.BackgroundTransparency = 1
	wrapper.BorderSizePixel = 0
	wrapper.ZIndex = 50
	wrapper.Parent = gui
	_overlay = wrapper

	local clickCatcher = Instance.new("TextButton")
	clickCatcher.Name = "ClickCatcher"
	clickCatcher.Size = UDim2.fromScale(1, 1)
	clickCatcher.BackgroundTransparency = 1
	clickCatcher.BorderSizePixel = 0
	clickCatcher.Text = ""
	clickCatcher.AutoButtonColor = false
	clickCatcher.Active = true
	clickCatcher.ZIndex = 50
	clickCatcher.Parent = wrapper
	clickCatcher.MouseButton1Click:Connect(dismiss)

	local card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.fromOffset(260, 310)
	card.BackgroundColor3 = Color3.fromRGB(25, 28, 42)
	card.BackgroundTransparency = 0.02
	card.BorderSizePixel = 0
	card.ZIndex = 51
	card.Parent = wrapper

	Instance.new("UICorner", card).CornerRadius = UDim.new(0, 16)
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(60, 65, 85)
	stroke.Thickness = 2
	stroke.Transparency = 0.3
	stroke.Parent = card

	AnimUtil.PopupOpen(card)

	task.defer(function()
		if card and card.Parent then
			print(string.format("[Modal] Show %s parent=%s anchor=(%.1f,%.1f) pos=(%.2f,%.2f) absPos=(%.0f,%.0f) absSize=(%.0f,%.0f)",
				titleText, gui.Name,
				card.AnchorPoint.X, card.AnchorPoint.Y,
				card.Position.X.Scale, card.Position.Y.Scale,
				card.AbsolutePosition.X, card.AbsolutePosition.Y,
				card.AbsoluteSize.X, card.AbsoluteSize.Y))
		end
	end)

	playWinSound()
	task.delay(0.15, function()
		if overlay and overlay.Parent then
			spawnConfettiBurst(overlay)
		end
	end)

	local header = Instance.new("TextLabel")
	header.Name = "Header"
	header.AnchorPoint = Vector2.new(0.5, 0)
	header.Position = UDim2.new(0.5, 0, 0, 14)
	header.Size = UDim2.new(1, -20, 0, 30)
	header.BackgroundTransparency = 1
	header.Font = Enum.Font.GothamBold
	header.TextColor3 = Color3.fromRGB(255, 215, 0)
	header.TextSize = 22
	header.Text = titleText
	header.ZIndex = 52
	header.Parent = card
	local hs = Instance.new("UIStroke")
	hs.Color = Color3.fromRGB(0, 0, 0)
	hs.Thickness = 2
	hs.Parent = header

	buildIcon(card, resolvedImage, fallbackEmoji, fallbackColor, 55, 90, 52, catalogEntry)

	local nameLbl = Instance.new("TextLabel")
	nameLbl.Name = "Name"
	nameLbl.AnchorPoint = Vector2.new(0.5, 0)
	nameLbl.Position = UDim2.new(0.5, 0, 0, 190)
	nameLbl.Size = UDim2.new(1, -24, 0, 28)
	nameLbl.BackgroundTransparency = 1
	nameLbl.Font = Enum.Font.GothamBold
	nameLbl.TextColor3 = Color3.fromRGB(255, 255, 255)
	nameLbl.TextSize = 20
	nameLbl.Text = nameText
	nameLbl.ZIndex = 52
	nameLbl.Parent = card
	local ns = Instance.new("UIStroke")
	ns.Color = Color3.fromRGB(0, 0, 0)
	ns.Thickness = 1.5
	ns.Parent = nameLbl

	local rarLbl = Instance.new("TextLabel")
	rarLbl.Name = "Rarity"
	rarLbl.AnchorPoint = Vector2.new(0.5, 0)
	rarLbl.Position = UDim2.new(0.5, 0, 0, 220)
	rarLbl.Size = UDim2.new(1, -24, 0, 20)
	rarLbl.BackgroundTransparency = 1
	rarLbl.Font = Enum.Font.GothamSemibold
	rarLbl.TextColor3 = rarityColor
	rarLbl.TextSize = 14
	rarLbl.Text = rarityStr
	rarLbl.ZIndex = 52
	rarLbl.Parent = card

	local okBtn = Instance.new("TextButton")
	okBtn.Name = "OkBtn"
	okBtn.AnchorPoint = Vector2.new(0.5, 1)
	okBtn.Position = UDim2.new(0.5, 0, 1, -18)
	okBtn.Size = UDim2.new(1, -50, 0, 40)
	okBtn.BackgroundColor3 = Color3.fromRGB(50, 180, 80)
	okBtn.Font = Enum.Font.GothamBold
	okBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	okBtn.TextSize = 18
	okBtn.Text = okText
	okBtn.BorderSizePixel = 0
	okBtn.AutoButtonColor = true
	okBtn.ZIndex = 52
	okBtn.Parent = card
	Instance.new("UICorner", okBtn).CornerRadius = UDim.new(0, 10)

	okBtn.MouseButton1Click:Connect(dismiss)

	local thisOverlay = overlay
	task.delay(8, function()
		if _overlay == thisOverlay and _active then dismiss() end
	end)
end

-- ═══════════════════════════════════════════
-- SHOWBATCH (multiple rewards — grid layout)
-- Used by crate opening (3 or 6 crates)
-- ═══════════════════════════════════════════
function RewardPopup.ShowBatch(items)
	if not items or #items == 0 then return end
	if #items == 1 then
		RewardPopup.Show(items[1])
		return
	end

	if _active and _overlay and _overlay.Parent then
		_overlay:Destroy()
		_overlay = nil
		_active = false
	end

	local gui = getGui()
	if not gui then return end

	_active = true
	_onDismissCallback = nil

	local count = #items
	local CARD_W, CARD_H = 150, 200
	local COLS = math.min(count, 3)
	local ROWS = math.ceil(count / COLS)
	local GAP = 14
	local containerW = COLS * CARD_W + (COLS - 1) * GAP
	local containerH = ROWS * CARD_H + (ROWS - 1) * GAP

	local wrapper = Instance.new("Frame")
	wrapper.Name = "ModalWrapper"
	wrapper.Size = UDim2.fromScale(1, 1)
	wrapper.BackgroundTransparency = 1
	wrapper.BorderSizePixel = 0
	wrapper.ZIndex = 50
	wrapper.Parent = gui
	_overlay = wrapper

	local clickCatcher = Instance.new("TextButton")
	clickCatcher.Name = "ClickCatcher"
	clickCatcher.Size = UDim2.fromScale(1, 1)
	clickCatcher.BackgroundTransparency = 1
	clickCatcher.BorderSizePixel = 0
	clickCatcher.Text = ""
	clickCatcher.AutoButtonColor = false
	clickCatcher.Active = true
	clickCatcher.ZIndex = 50
	clickCatcher.Parent = wrapper
	clickCatcher.MouseButton1Click:Connect(dismiss)

	-- Main panel
	local panelW = containerW + 40
	local panelH = containerH + 100
	local panel = Instance.new("Frame")
	panel.Name = "BatchPanel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(panelW, panelH)
	panel.BackgroundColor3 = Color3.fromRGB(20, 22, 35)
	panel.BackgroundTransparency = 0.05
	panel.BorderSizePixel = 0
	panel.ZIndex = 51
	panel.Parent = wrapper

	Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 16)
	local panelStroke = Instance.new("UIStroke")
	panelStroke.Color = Color3.fromRGB(60, 65, 85)
	panelStroke.Thickness = 2
	panelStroke.Transparency = 0.3
	panelStroke.Parent = panel

	AnimUtil.PopupOpen(panel)

	task.defer(function()
		if panel and panel.Parent then
			print(string.format("[Modal] ShowBatch parent=%s anchor=(%.1f,%.1f) pos=(%.2f,%.2f) absPos=(%.0f,%.0f) absSize=(%.0f,%.0f)",
				gui.Name,
				panel.AnchorPoint.X, panel.AnchorPoint.Y,
				panel.Position.X.Scale, panel.Position.Y.Scale,
				panel.AbsolutePosition.X, panel.AbsolutePosition.Y,
				panel.AbsoluteSize.X, panel.AbsoluteSize.Y))
		end
	end)

	playWinSound()
	task.delay(0.15, function()
		if overlay and overlay.Parent then
			spawnConfettiBurst(overlay)
		end
	end)

	-- Header
	local header = Instance.new("TextLabel")
	header.AnchorPoint = Vector2.new(0.5, 0)
	header.Position = UDim2.new(0.5, 0, 0, 10)
	header.Size = UDim2.new(1, 0, 0, 28)
	header.BackgroundTransparency = 1
	header.Font = Enum.Font.GothamBold
	header.TextColor3 = Color3.fromRGB(255, 215, 0)
	header.TextSize = 20
	header.Text = "YOU WON!"
	header.ZIndex = 52
	header.Parent = panel
	local hs = Instance.new("UIStroke")
	hs.Color = Color3.fromRGB(0, 0, 0)
	hs.Thickness = 2
	hs.Parent = header

	-- Card grid container
	local grid = Instance.new("Frame")
	grid.Name = "CardGrid"
	grid.AnchorPoint = Vector2.new(0.5, 0)
	grid.Position = UDim2.new(0.5, 0, 0, 44)
	grid.Size = UDim2.fromOffset(containerW, containerH)
	grid.BackgroundTransparency = 1
	grid.ZIndex = 52
	grid.Parent = panel

	local gridLayout = Instance.new("UIGridLayout")
	gridLayout.CellSize = UDim2.fromOffset(CARD_W, CARD_H)
	gridLayout.CellPadding = UDim2.fromOffset(GAP, GAP)
	gridLayout.FillDirection = Enum.FillDirection.Horizontal
	gridLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	gridLayout.Parent = grid

	-- Build mini-cards
	for idx, item in ipairs(items) do
		local resolvedImage, fallbackEmoji, fallbackColor, catalogEntry = resolveIcon(item)
		local rarityStr = resolveRarity(item)
		local rarityColor = RARITY_COLORS[rarityStr] or RARITY_COLORS.Common

		local card = Instance.new("Frame")
		card.Name = "Card" .. idx
		card.BackgroundColor3 = Color3.fromRGB(30, 33, 50)
		card.BorderSizePixel = 0
		card.LayoutOrder = idx
		card.ZIndex = 53
		card.Parent = grid

		Instance.new("UICorner", card).CornerRadius = UDim.new(0, 12)
		local cardStroke = Instance.new("UIStroke")
		cardStroke.Color = rarityColor
		cardStroke.Thickness = 1.5
		cardStroke.Transparency = 0.4
		cardStroke.Parent = card

		-- Icon
		buildIcon(card, resolvedImage, fallbackEmoji, fallbackColor, 12, 60, 54, catalogEntry)

		-- Name
		local nameLbl = Instance.new("TextLabel")
		nameLbl.AnchorPoint = Vector2.new(0.5, 0)
		nameLbl.Position = UDim2.new(0.5, 0, 0, 78)
		nameLbl.Size = UDim2.new(1, -12, 0, 36)
		nameLbl.BackgroundTransparency = 1
		nameLbl.Font = Enum.Font.GothamBold
		nameLbl.TextColor3 = Color3.fromRGB(255, 255, 255)
		nameLbl.TextSize = 13
		nameLbl.Text = item.name or "MISSING ITEM"
		nameLbl.TextWrapped = true
		nameLbl.ZIndex = 54
		nameLbl.Parent = card

		-- Rarity
		local rarLbl = Instance.new("TextLabel")
		rarLbl.AnchorPoint = Vector2.new(0.5, 0)
		rarLbl.Position = UDim2.new(0.5, 0, 0, 116)
		rarLbl.Size = UDim2.new(1, -12, 0, 16)
		rarLbl.BackgroundTransparency = 1
		rarLbl.Font = Enum.Font.GothamSemibold
		rarLbl.TextColor3 = rarityColor
		rarLbl.TextSize = 11
		rarLbl.Text = rarityStr
		rarLbl.ZIndex = 54
		rarLbl.Parent = card

		-- Duplicate tag
		if item.isDuplicate then
			local dupLbl = Instance.new("TextLabel")
			dupLbl.AnchorPoint = Vector2.new(0.5, 1)
			dupLbl.Position = UDim2.new(0.5, 0, 1, -8)
			dupLbl.Size = UDim2.new(1, -12, 0, 16)
			dupLbl.BackgroundTransparency = 1
			dupLbl.Font = Enum.Font.GothamBold
			dupLbl.TextColor3 = Color3.fromRGB(255, 180, 40)
			dupLbl.TextSize = 10
			dupLbl.Text = "ALREADY OWNED"
			dupLbl.ZIndex = 54
			dupLbl.Parent = card
		end
	end

	-- CLAIM ALL button
	local claimBtn = Instance.new("TextButton")
	claimBtn.AnchorPoint = Vector2.new(0.5, 1)
	claimBtn.Position = UDim2.new(0.5, 0, 1, -12)
	claimBtn.Size = UDim2.new(0, math.min(containerW, 200), 0, 38)
	claimBtn.BackgroundColor3 = Color3.fromRGB(50, 180, 80)
	claimBtn.Font = Enum.Font.GothamBold
	claimBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	claimBtn.TextSize = 16
	claimBtn.Text = "CLAIM ALL"
	claimBtn.BorderSizePixel = 0
	claimBtn.AutoButtonColor = true
	claimBtn.ZIndex = 52
	claimBtn.Parent = panel
	Instance.new("UICorner", claimBtn).CornerRadius = UDim.new(0, 10)
	claimBtn.MouseButton1Click:Connect(dismiss)

	local thisWrapper = wrapper
	task.delay(12, function()
		if _overlay == thisWrapper and _active then dismiss() end
	end)
end

function RewardPopup.IsActive(): boolean
	return _active
end

function RewardPopup.Dismiss()
	dismiss()
end

return RewardPopup