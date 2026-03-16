local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared", 60)
if not Shared then
	warn("[EmoteShopPanel] Shared not found")
	return {
		Init = function() end,
		Show = function() end,
		Hide = function() end,
		IsVisible = function() return false end,
		Toggle = function() end,
	}
end

local UIConfig = require(Shared:WaitForChild("UIConfig"))

local Client = script.Parent
local AnimUtil = require(Client:WaitForChild("AnimUtil"))
local SoundUtil = require(Client:WaitForChild("SoundUtil"))
local Components = require(Client:WaitForChild("Components"))

local C = UIConfig.Colors
local LocalPlayer = Players.LocalPlayer

local EmoteShopPanel = {}

local HEADER_COLOR = Color3.fromRGB(58, 58, 58)
local PANEL_BG = Color3.fromRGB(28, 28, 28)
local PANEL_HEADER_BG = Color3.fromRGB(36, 36, 36)
local PANEL_STROKE = Color3.fromRGB(55, 55, 55)
local PANEL_STUD = Color3.fromRGB(112, 112, 112)
local CARD_BG = Color3.fromRGB(32, 32, 32)
local CARD_BG_ALT = Color3.fromRGB(45, 45, 45)
local CARD_STROKE = Color3.fromRGB(68, 68, 68)
local MESSAGE_TEXT = Color3.fromRGB(244, 244, 244)
local MUTED_TEXT = Color3.fromRGB(182, 182, 182)
local BADGE_BG = Color3.fromRGB(52, 52, 52)

local canvas: CanvasGroup? = nil
local uiScale: UIScale? = nil
local overlay: TextButton? = nil
local visible = false
local closeCallback: (() -> ())? = nil
local activeEmoteTrack: AnimationTrack? = nil
local activeEmoteAnimationId: string? = nil
local emoteButtons: { [string]: TextButton } = {}
local emoteOwnedLocal: { [string]: boolean } = {}
local emoteDataById: { [string]: { [string]: any } } = {}
local emoteIdByAssetId: { [number]: string } = {}
local ownershipCheckInFlight: { [string]: boolean } = {}
local pendingPurchaseByAssetId: { [number]: { emoteId: string, emoteName: string, startedAt: number } } = {}

local function showEmoteShopToast(message: string)
	if not canvas or not canvas.Parent then
		return
	end

	local old = canvas:FindFirstChild("EmoteShopToast")
	if old then
		old:Destroy()
	end

	local toast = Instance.new("TextLabel")
	toast.Name = "EmoteShopToast"
	toast.AnchorPoint = Vector2.new(0.5, 1)
	toast.Position = UDim2.new(0.5, 0, 1, -14)
	toast.Size = UDim2.new(0, 360, 0, 38)
	toast.BackgroundColor3 = Color3.fromRGB(20, 24, 42)
	toast.BackgroundTransparency = 0.08
	toast.TextColor3 = Color3.fromRGB(255, 255, 255)
	toast.Font = Enum.Font.LuckiestGuy
	toast.TextSize = 15
	toast.Text = tostring(message or "")
	toast.BorderSizePixel = 0
	toast.ZIndex = 120
	toast.Parent = canvas
	Instance.new("UICorner", toast).CornerRadius = UDim.new(0, 10)

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(0, 0, 0)
	stroke.Thickness = 1.2
	stroke.Transparency = 0.25
	stroke.Parent = toast

	task.delay(2.2, function()
		if toast and toast.Parent then
			toast:Destroy()
		end
	end)
end

type EmotePurchaseInfo = {
	promptType: "asset" | "none",
	id: number,
}

local function getEmotePurchaseInfo(emoteData): EmotePurchaseInfo
	if type(emoteData) ~= "table" then
		return { promptType = "none", id = 0 }
	end

	local explicitType = string.lower(tostring(emoteData.purchaseType or emoteData.productType or ""))
	local assetId = tonumber(emoteData.assetId or emoteData.emoteAssetId) or 0

	if explicitType == "asset" and assetId > 0 then
		return { promptType = "asset", id = assetId }
	end

	-- Emote shop uses third-party asset purchase prompts.
	if assetId > 0 then
		return { promptType = "asset", id = assetId }
	end

	return { promptType = "none", id = 0 }
end

local function isEmoteOwned(emoteId: string): boolean
	return emoteOwnedLocal[emoteId] == true
end

local function applyActionButtonColor(button: TextButton, color: Color3)
	button.BackgroundColor3 = color

	local gradient = button:FindFirstChildWhichIsA("UIGradient")
	if gradient then
		local abr, abg, abb = color.R, color.G, color.B
		local lighter = Color3.new(
			math.min(abr + 0.20, 1),
			math.min(abg + 0.20, 1),
			math.min(abb + 0.20, 1)
		)
		local darker = Color3.new(
			math.max(abr - 0.10, 0),
			math.max(abg - 0.10, 0),
			math.max(abb - 0.10, 0)
		)
		gradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, lighter),
			ColorSequenceKeypoint.new(0.5, color),
			ColorSequenceKeypoint.new(1, darker),
		})
	end
end

local function refreshEmoteCard(emoteId: string)
	local button = emoteButtons[emoteId]
	local emoteData = emoteDataById[emoteId]
	if not button or not emoteData then
		return
	end

	if isEmoteOwned(emoteId) then
		local buyGroup = button:FindFirstChild("RobuxBuyGroup")
		if buyGroup then
			buyGroup:Destroy()
		end
		button.Text = "Use"
		applyActionButtonColor(button, C.EquipButton)
	else
		local robuxAmount = tostring(tonumber(emoteData.robux) or 99)
		button.Text = string.format("%s ROBUX", robuxAmount)
		applyActionButtonColor(button, C.RobuxButton)
		Components.ApplyRobuxBuyStyle(button, robuxAmount)
	end
end

local function refreshEmoteOwnership(emoteId: string, optimisticOwned: boolean?): boolean
	local emoteData = emoteDataById[emoteId]
	if not emoteData then
		return false
	end

	local owned = optimisticOwned == true
	local purchase = getEmotePurchaseInfo(emoteData)
	if not owned and not ownershipCheckInFlight[emoteId] then
		ownershipCheckInFlight[emoteId] = true
		if purchase.promptType == "asset" and purchase.id > 0 then
			local ok, owns = pcall(function()
				return MarketplaceService:PlayerOwnsAsset(LocalPlayer, purchase.id)
			end)
			if ok then
				owned = owns == true
			else
				warn(string.format("[EmoteShopPanel] Asset ownership check failed for %s (%d): %s",
					tostring(emoteData.name), purchase.id, tostring(owns)))
			end
		end
		ownershipCheckInFlight[emoteId] = nil
	end

	emoteOwnedLocal[emoteId] = owned
	refreshEmoteCard(emoteId)
	return owned
end

local function refreshAllEmoteOwnership()
	for emoteId in pairs(emoteDataById) do
		refreshEmoteOwnership(emoteId)
	end
end

local function stopActiveEmote(fadeTime: number?)
	if activeEmoteTrack then
		pcall(function()
			activeEmoteTrack:Stop(fadeTime or 0.15)
		end)
		activeEmoteTrack = nil
		activeEmoteAnimationId = nil
	end
end

local function getLocalAnimator(): Animator?
	local player = Players.LocalPlayer
	local character = player and player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator then
		return animator
	end

	animator = Instance.new("Animator")
	animator.Parent = humanoid
	return animator
end

local function playLocalEmote(emoteData)
	if type(emoteData) ~= "table" or type(emoteData.animationId) ~= "string" or emoteData.animationId == "" then
		return
	end

	if activeEmoteTrack and activeEmoteTrack.IsPlaying and activeEmoteAnimationId == emoteData.animationId then
		stopActiveEmote(0.12)
		return
	end

	local animator = getLocalAnimator()
	if not animator then
		warn(string.format("[EmoteShopPanel] Could not play emote '%s' - animator unavailable", tostring(emoteData.name)))
		return
	end

	stopActiveEmote(0.08)

	local animation = Instance.new("Animation")
	animation.AnimationId = emoteData.animationId

	local ok, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	animation:Destroy()

	if not ok or not track then
		warn(string.format("[EmoteShopPanel] Failed to load emote '%s': %s", tostring(emoteData.name), tostring(track)))
		return
	end

	track.Priority = Enum.AnimationPriority.Action4
	track.Looped = true

	local playOk, playErr = pcall(function()
		track:Play(0.15, 1, 1)
	end)
	if not playOk then
		warn(string.format("[EmoteShopPanel] Failed to play emote '%s': %s", tostring(emoteData.name), tostring(playErr)))
		return
	end

	activeEmoteTrack = track
	activeEmoteAnimationId = emoteData.animationId

	track.Stopped:Connect(function()
		if activeEmoteTrack == track then
			activeEmoteTrack = nil
			activeEmoteAnimationId = nil
		end
	end)
end

local function handleEmoteAction(emoteData)
	if type(emoteData) ~= "table" or type(emoteData.id) ~= "string" then
		return
	end

	if isEmoteOwned(emoteData.id) then
		playLocalEmote(emoteData)
		return
	end

	local purchase = getEmotePurchaseInfo(emoteData)
	print(string.format(
		"[EmoteShopPanel] Buy clicked emote=%s id=%s promptType=%s assetId=%d",
		tostring(emoteData.name),
		tostring(emoteData.id),
		purchase.promptType,
		purchase.id
	))

	if purchase.promptType == "none" or purchase.id <= 0 then
		warn(string.format("[EmoteShopPanel] Purchase blocked emote=%s id=%s reason=missing_product_config",
			tostring(emoteData.name), tostring(emoteData.id)))
		return
	end

	if purchase.promptType == "asset" then
		pendingPurchaseByAssetId[purchase.id] = {
			emoteId = emoteData.id,
			emoteName = tostring(emoteData.name or emoteData.id),
			startedAt = os.clock(),
		}
		print(string.format(
			"[EmoteShopPanel] PromptPurchase request emote=%s id=%s assetId=%d studio=%s",
			tostring(emoteData.name),
			tostring(emoteData.id),
			purchase.id,
			tostring(RunService:IsStudio())
		))
		local okPrompt, promptErr = pcall(function()
			MarketplaceService:PromptPurchase(LocalPlayer, purchase.id)
		end)
		if not okPrompt then
			pendingPurchaseByAssetId[purchase.id] = nil
			warn(string.format(
				"[EmoteShopPanel] PromptPurchase failed emote=%s id=%s assetId=%d error=%s studio=%s",
				tostring(emoteData.name),
				tostring(emoteData.id),
				purchase.id,
				tostring(promptErr),
				tostring(RunService:IsStudio())
			))
			if RunService:IsStudio() then
				showEmoteShopToast("Purchase prompt unavailable in this Studio test mode.")
			else
				showEmoteShopToast("Couldn't open purchase prompt. Please try again.")
			end
		end
	end
end

function EmoteShopPanel.Init(screenGui: ScreenGui, onClose: () -> ())
	closeCallback = onClose
	print("[EmoteShopPanel] Init complete (client asset purchase flow)")

	overlay = Components.CreateDimOverlay(screenGui, function()
		EmoteShopPanel.Hide()
	end)

	local content: ScrollingFrame
	local closeBtn: TextButton
	canvas, uiScale, content, closeBtn = Components.CreatePanel(screenGui, "EMOTE SHOP", HEADER_COLOR, "Icons")
	canvas.Size = UDim2.fromScale(0.52, 0.46)
	canvas.BackgroundColor3 = PANEL_BG
	content.AutomaticCanvasSize = Enum.AutomaticSize.Y
	content.ScrollingEnabled = true
	content.CanvasSize = UDim2.fromScale(0, 1)
	content.ScrollBarThickness = 0
	content.ScrollBarImageColor3 = PANEL_STROKE

	local panelStroke = canvas:FindFirstChildWhichIsA("UIStroke")
	if panelStroke then
		panelStroke.Color = PANEL_STROKE
		panelStroke.Transparency = 0.08
	end

	local centerGlow = canvas:FindFirstChild("CenterGlow")
	if centerGlow then
		centerGlow:Destroy()
	end

	local sunburst = canvas:FindFirstChild("Sunburst")
	if sunburst then
		sunburst:Destroy()
	end

	for _, child in ipairs(canvas:GetChildren()) do
		if string.match(child.Name, "^Sparkle") then
			child:Destroy()
		end
	end

	local studTexture = canvas:FindFirstChild("StudTexture")
	if studTexture and studTexture:IsA("ImageLabel") then
		studTexture.ImageColor3 = PANEL_STUD
		studTexture.ImageTransparency = 0.9
		studTexture.TileSize = UDim2.fromOffset(72, 72)
	end

	local header = canvas:FindFirstChild("Header")
	if header and header:IsA("Frame") then
		header.BackgroundColor3 = PANEL_HEADER_BG

		local bottomMask = header:FindFirstChild("BottomMask")
		if bottomMask and bottomMask:IsA("Frame") then
			bottomMask.BackgroundColor3 = PANEL_HEADER_BG
		end

		local highlightLine = header:FindFirstChild("HighlightLine")
		if highlightLine and highlightLine:IsA("Frame") then
			highlightLine.BackgroundColor3 = Color3.fromRGB(148, 148, 148)
			highlightLine.BackgroundTransparency = 0.82
		end

		local titleLabel = header:FindFirstChild("Title")
		if titleLabel and titleLabel:IsA("TextLabel") then
			titleLabel.TextColor3 = MESSAGE_TEXT
		end
	end

	closeBtn.BackgroundColor3 = C.CloseBtn
	closeBtn.TextColor3 = C.TextWhite
	local closeStroke = closeBtn:FindFirstChildWhichIsA("UIStroke")
	if closeStroke then
		closeStroke.Color = Color3.fromRGB(255, 255, 255)
		closeStroke.Transparency = 0.35
	end

	AnimUtil.WireButton(closeBtn, function()
		EmoteShopPanel.Hide()
	end)

	local wrapper = Instance.new("Frame")
	wrapper.Name = "Wrapper"
	wrapper.AnchorPoint = Vector2.new(0.5, 0)
	wrapper.Position = UDim2.new(0.5, 0, 0, 12)
	wrapper.Size = UDim2.new(1, -12, 0, 0)
	wrapper.AutomaticSize = Enum.AutomaticSize.Y
	wrapper.BackgroundTransparency = 1
	wrapper.BorderSizePixel = 0
	wrapper.Parent = content

	local bodyLayout = Instance.new("UIListLayout")
	bodyLayout.FillDirection = Enum.FillDirection.Vertical
	bodyLayout.Padding = UDim.new(0, 14)
	bodyLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	bodyLayout.VerticalAlignment = Enum.VerticalAlignment.Top
	bodyLayout.Parent = wrapper

	local gridHolder = Instance.new("Frame")
	gridHolder.Name = "EmoteGrid"
	gridHolder.Size = UDim2.new(1, -8, 0, 0)
	gridHolder.AutomaticSize = Enum.AutomaticSize.Y
	gridHolder.BackgroundTransparency = 1
	gridHolder.BorderSizePixel = 0
	gridHolder.LayoutOrder = 1
	gridHolder.Parent = wrapper

	local grid = Components.AddGridLayout(gridHolder)
	grid:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
		gridHolder.Size = UDim2.new(1, -8, 0, grid.AbsoluteContentSize.Y + 16)
	end)

	for _, emoteData in ipairs(UIConfig.MockEmotes or {}) do
		emoteDataById[emoteData.id] = emoteData
		local purchase = getEmotePurchaseInfo(emoteData)
		if purchase.promptType == "asset" and purchase.id > 0 then
			emoteIdByAssetId[purchase.id] = emoteData.id
		else
			warn(string.format("[EmoteShopPanel] Missing purchase config emote=%s id=%s",
				tostring(emoteData.name), tostring(emoteData.id)))
		end

		local card = Components.CreateItemCard(gridHolder, {
			name = tostring(emoteData.name or "Emote"),
			rarity = "Common",
			iconColor = Color3.fromRGB(72, 72, 72),
			iconText = string.sub(tostring(emoteData.name or "E"), 1, 1),
			image = tostring(emoteData.icon or ""),
			actionText = string.format("%d ROBUX", tonumber(emoteData.robux) or 99),
			actionColor = C.RobuxButton,
			tag = tostring(emoteData.tag or ""),
			subLabel = "Emote",
			onAction = function()
				handleEmoteAction(emoteData)
			end,
		})

		local rarityLabel = card:FindFirstChild("Rarity")
		if rarityLabel and rarityLabel:IsA("TextLabel") then
			rarityLabel:Destroy()
		end

		local subLabel = card:FindFirstChild("SubLabel")
		if subLabel and subLabel:IsA("TextLabel") then
			subLabel.Position = UDim2.new(0, 5, 0, 121)
		end

		local actionBtn = card:FindFirstChild("ActionBtn")
		if actionBtn and actionBtn:IsA("TextButton") then
			emoteButtons[emoteData.id] = actionBtn
		end

		refreshEmoteCard(emoteData.id)
	end

	refreshAllEmoteOwnership()

	Players.LocalPlayer.CharacterAdded:Connect(function()
		stopActiveEmote(0.08)
	end)

	MarketplaceService.PromptPurchaseFinished:Connect(function(player, assetId, wasPurchased)
		if player ~= LocalPlayer then
			return
		end
		local resolvedAssetId = tonumber(assetId)
		if not resolvedAssetId or resolvedAssetId <= 0 then
			return
		end
		local pending = pendingPurchaseByAssetId[resolvedAssetId]
		local elapsedMs = 0
		if pending and type(pending.startedAt) == "number" then
			elapsedMs = math.floor((os.clock() - pending.startedAt) * 1000)
		end
		print(string.format(
			"[EmoteShopPanel] PromptPurchaseFinished assetId=%d purchased=%s emote=%s emoteId=%s elapsedMs=%d studio=%s",
			resolvedAssetId,
			tostring(wasPurchased == true),
			tostring(pending and pending.emoteName or "unknown"),
			tostring(pending and pending.emoteId or "unknown"),
			elapsedMs,
			tostring(RunService:IsStudio())
		))
		pendingPurchaseByAssetId[resolvedAssetId] = nil

		if wasPurchased ~= true then
			if RunService:IsStudio() then
				showEmoteShopToast("Purchase not completed. Studio Start Server/Player may block third-party prompts.")
			end
			return
		end
		local emoteId = emoteIdByAssetId[resolvedAssetId]
		if not emoteId then
			return
		end
		emoteOwnedLocal[emoteId] = true
		refreshEmoteCard(emoteId)
		task.delay(0.5, function()
			refreshEmoteOwnership(emoteId, true)
		end)
	end)
end

function EmoteShopPanel.Show()
	if not canvas or not uiScale or not overlay or visible then
		return
	end

	visible = true
	overlay.Visible = true
	print("[EmoteShopPanel] Opened")
	refreshAllEmoteOwnership()
	SoundUtil.Open()
	AnimUtil.OpenPanel(canvas, uiScale)
end

function EmoteShopPanel.Hide()
	if not canvas or not uiScale or not overlay or not visible then
		return
	end

	visible = false
	overlay.Visible = false
	stopActiveEmote(0.12)
	local tween = AnimUtil.ClosePanel(canvas, uiScale)
	task.spawn(function()
		tween.Completed:Wait()
		if canvas then
			canvas.Visible = false
		end
	end)

	if closeCallback then
		closeCallback()
	end
end

function EmoteShopPanel.IsVisible(): boolean
	return visible
end

function EmoteShopPanel.Toggle()
	if visible then
		EmoteShopPanel.Hide()
	else
		EmoteShopPanel.Show()
	end
end

return EmoteShopPanel
