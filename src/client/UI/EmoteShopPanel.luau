local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")

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
local emoteIdByGamepassId: { [number]: string } = {}

local function getEmoteGamepassId(emoteData): number
	if type(emoteData) ~= "table" then
		return 0
	end

	return tonumber(emoteData.gamepassId) or 0
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
		button.Text = "Use"
		applyActionButtonColor(button, C.EquipButton)
	else
		button.Text = string.format("%d ROBUX", tonumber(emoteData.robux) or 99)
		applyActionButtonColor(button, C.RobuxButton)
	end
end

local function refreshEmoteOwnership(emoteId: string, optimisticOwned: boolean?): boolean
	local emoteData = emoteDataById[emoteId]
	if not emoteData then
		return false
	end

	local owned = optimisticOwned == true
	local gamepassId = getEmoteGamepassId(emoteData)
	if not owned and gamepassId > 0 then
		local ok, owns = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(LocalPlayer.UserId, gamepassId)
		end)
		if ok then
			owned = owns == true
		else
			warn(string.format("[EmoteShopPanel] Ownership check failed for %s: %s", tostring(emoteData.name), tostring(owns)))
		end
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

	local gamepassId = getEmoteGamepassId(emoteData)
	if gamepassId <= 0 then
		warn(string.format(
			"[EmoteShopPanel] Purchase blocked for %s - gamepassId is not configured",
			tostring(emoteData.name)
		))
		return
	end

	MarketplaceService:PromptGamePassPurchase(LocalPlayer, gamepassId)
end

function EmoteShopPanel.Init(screenGui: ScreenGui, onClose: () -> ())
	closeCallback = onClose

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
		local gamepassId = getEmoteGamepassId(emoteData)
		if gamepassId > 0 then
			emoteIdByGamepassId[gamepassId] = emoteData.id
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

		if not wasPurchased or not gamepassId or gamepassId <= 0 then
			return
		end

		local emoteId = emoteIdByGamepassId[gamepassId]
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
