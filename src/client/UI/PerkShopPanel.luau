local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared", 60)
if not Shared then
	warn("[AbilityShopPanel] Shared not found")
	return {
		Init = function() end,
		Show = function() end,
		Hide = function() end,
		IsVisible = function() return false end,
		Toggle = function() end,
	}
end

local UIConfig = require(Shared:WaitForChild("UIConfig"))
local PerkCatalog = require(Shared:WaitForChild("PerkCatalog"))

local Client = script.Parent
local AnimUtil = require(Client:WaitForChild("AnimUtil"))
local SoundUtil = require(Client:WaitForChild("SoundUtil"))
local Components = require(Client:WaitForChild("Components"))

local LocalPlayer = Players.LocalPlayer

local AbilityShopPanel = {}

local HEADER_COLOR = Color3.fromRGB(25, 118, 67)
local PANEL_BG = Color3.fromRGB(9, 14, 11)
local PANEL_HEADER_BG = Color3.fromRGB(16, 70, 43)
local PANEL_STROKE = Color3.fromRGB(62, 162, 108)
local PANEL_STUD = Color3.fromRGB(122, 194, 153)
local CARD_BG = Color3.fromRGB(14, 20, 16)
local CARD_BG_ALT = Color3.fromRGB(22, 34, 27)
local CARD_STROKE = Color3.fromRGB(72, 155, 110)
local CARD_ACCENT = Color3.fromRGB(98, 214, 143)
local BUTTON_BG = Color3.fromRGB(30, 122, 73)
local BUTTON_BG_DISABLED = Color3.fromRGB(43, 58, 49)
local TEXT_PRIMARY = Color3.fromRGB(244, 250, 246)
local TEXT_MUTED = Color3.fromRGB(166, 190, 175)
local BADGE_BG = Color3.fromRGB(16, 48, 31)

local STATUS_NONE = "None"
local STATUS_QUEUED = "Queued"
local STATUS_ACTIVE = "Active"

local canvas: CanvasGroup? = nil
local uiScale: UIScale? = nil
local overlay: TextButton? = nil
local visible = false
local closeCallback: (() -> ())? = nil
local requestRemote: RemoteEvent? = nil

local actionButtons: { [string]: TextButton } = {}
local priceLabels: { [string]: TextLabel } = {}
local statusLabels: { [string]: TextLabel } = {}
local cardsGridLayout: UIGridLayout? = nil

local function getRequestRemote(): RemoteEvent?
	if requestRemote and requestRemote.Parent then
		return requestRemote
	end

	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		return nil
	end

	local remote = remotes:FindFirstChild("PerkProductPromptRequest")
	if remote and remote:IsA("RemoteEvent") then
		requestRemote = remote
	end

	return requestRemote
end

local function getAbilityStatus(abilityId: string): string
	local ability = PerkCatalog.Get(abilityId)
	if not ability then
		return STATUS_NONE
	end

	local value = LocalPlayer:GetAttribute(ability.statusAttribute)
	if value == STATUS_QUEUED or value == STATUS_ACTIVE then
		return value
	end
	return STATUS_NONE
end

local function refreshAbilityCard(abilityId: string)
	local button = actionButtons[abilityId]
	local priceLabel = priceLabels[abilityId]
	local statusLabel = statusLabels[abilityId]
	local ability = PerkCatalog.Get(abilityId)
	if not button or not priceLabel or not statusLabel or not ability then
		return
	end

	local status = getAbilityStatus(abilityId)
	if status == STATUS_QUEUED then
		button.Text = "QUEUED"
		button.BackgroundColor3 = BUTTON_BG_DISABLED
		priceLabel.Text = "Queued for your next match"
		statusLabel.Text = "NEXT MATCH"
		statusLabel.TextColor3 = CARD_ACCENT
	elseif status == STATUS_ACTIVE then
		button.Text = "ACTIVE"
		button.BackgroundColor3 = BUTTON_BG_DISABLED
		priceLabel.Text = "Active for this match"
		statusLabel.Text = "LIVE NOW"
		statusLabel.TextColor3 = CARD_ACCENT
	else
		button.Text = "BUY ABILITY"
		button.BackgroundColor3 = BUTTON_BG
		priceLabel.Text = string.format("%d Robux", tonumber(ability.robux) or 5)
		statusLabel.Text = "ONE MATCH"
		statusLabel.TextColor3 = TEXT_MUTED
	end
end

local function refreshAllAbilityCards()
	for _, perk in ipairs(PerkCatalog.All) do
		refreshAbilityCard(perk.id)
	end
end

local function createAbilityCard(parent: Instance, ability, layoutOrder: number?)
	local card = Instance.new("Frame")
	card.Name = ability.id .. "_Card"
	card.Size = UDim2.fromOffset(246, 228)
	card.LayoutOrder = layoutOrder or 0
	card.BackgroundColor3 = CARD_BG
	card.BorderSizePixel = 0
	card.Parent = parent
	Instance.new("UICorner", card).CornerRadius = UDim.new(0, 18)
	Components.AddStudTexture(card, 18)

	local cardTexture = card:FindFirstChild("StudTexture")
	if cardTexture and cardTexture:IsA("ImageLabel") then
		cardTexture.ImageColor3 = PANEL_STUD
		cardTexture.ImageTransparency = 0.94
		cardTexture.TileSize = UDim2.fromOffset(60, 60)
		cardTexture.ZIndex = 3
	end

	local stroke = Instance.new("UIStroke")
	stroke.Color = CARD_STROKE
	stroke.Thickness = 2
	stroke.Transparency = 0.08
	stroke.Parent = card

	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, CARD_BG_ALT),
		ColorSequenceKeypoint.new(1, CARD_BG),
	})
	gradient.Rotation = 90
	gradient.Parent = card

	local badge = Instance.new("TextLabel")
	badge.Name = "Badge"
	badge.AnchorPoint = Vector2.new(0.5, 0)
	badge.Position = UDim2.new(0.5, 0, 0, 14)
	badge.Size = UDim2.fromOffset(116, 24)
	badge.BackgroundColor3 = BADGE_BG
	badge.BorderSizePixel = 0
	badge.Font = Enum.Font.GothamBold
	badge.Text = "ABILITY SHOP"
	badge.TextColor3 = TEXT_PRIMARY
	badge.TextSize = 12
	badge.ZIndex = 4
	badge.Parent = card
	Instance.new("UICorner", badge).CornerRadius = UDim.new(0, 12)

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.AnchorPoint = Vector2.new(0.5, 0)
	title.Position = UDim2.new(0.5, 0, 0, 48)
	title.Size = UDim2.new(1, -24, 0, 32)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBlack
	title.Text = ability.name
	title.TextColor3 = TEXT_PRIMARY
	title.TextSize = 24
	title.ZIndex = 4
	title.Parent = card

	local titleStroke = Instance.new("UIStroke")
	titleStroke.Color = Color3.new(0, 0, 0)
	titleStroke.Thickness = 1.4
	titleStroke.Transparency = 0.28
	titleStroke.Parent = title

	local statusLabel = Instance.new("TextLabel")
	statusLabel.Name = "Status"
	statusLabel.AnchorPoint = Vector2.new(0.5, 0)
	statusLabel.Position = UDim2.new(0.5, 0, 0, 82)
	statusLabel.Size = UDim2.new(1, -28, 0, 18)
	statusLabel.BackgroundTransparency = 1
	statusLabel.Font = Enum.Font.GothamBold
	statusLabel.Text = "ONE MATCH"
	statusLabel.TextColor3 = TEXT_MUTED
	statusLabel.TextSize = 12
	statusLabel.ZIndex = 4
	statusLabel.Parent = card
	statusLabels[ability.id] = statusLabel

	local description = Instance.new("TextLabel")
	description.Name = "Description"
	description.AnchorPoint = Vector2.new(0.5, 0)
	description.Position = UDim2.new(0.5, 0, 0, 108)
	description.Size = UDim2.new(1, -28, 0, 56)
	description.BackgroundTransparency = 1
	description.Font = Enum.Font.GothamMedium
	description.Text = ability.description
	description.TextColor3 = TEXT_MUTED
	description.TextSize = 14
	description.TextWrapped = true
	description.ZIndex = 4
	description.Parent = card

	local accentLine = Instance.new("Frame")
	accentLine.Name = "AccentLine"
	accentLine.AnchorPoint = Vector2.new(0.5, 0)
	accentLine.Position = UDim2.new(0.5, 0, 0, 168)
	accentLine.Size = UDim2.new(1, -34, 0, 2)
	accentLine.BackgroundColor3 = CARD_ACCENT
	accentLine.BorderSizePixel = 0
	accentLine.ZIndex = 4
	accentLine.Parent = card

	local priceLabel = Instance.new("TextLabel")
	priceLabel.Name = "Price"
	priceLabel.AnchorPoint = Vector2.new(0.5, 1)
	priceLabel.Position = UDim2.new(0.5, 0, 1, -48)
	priceLabel.Size = UDim2.new(1, -28, 0, 18)
	priceLabel.BackgroundTransparency = 1
	priceLabel.Font = Enum.Font.GothamBold
	priceLabel.Text = string.format("%d Robux", tonumber(ability.robux) or 5)
	priceLabel.TextColor3 = TEXT_PRIMARY
	priceLabel.TextSize = 15
	priceLabel.ZIndex = 4
	priceLabel.Parent = card
	priceLabels[ability.id] = priceLabel

	local button = Instance.new("TextButton")
	button.Name = "BuyButton"
	button.AnchorPoint = Vector2.new(0.5, 1)
	button.Position = UDim2.new(0.5, 0, 1, -14)
	button.Size = UDim2.new(1, -28, 0, 32)
	button.BackgroundColor3 = BUTTON_BG
	button.BorderSizePixel = 0
	button.AutoButtonColor = false
	button.Font = Enum.Font.GothamBold
	button.Text = "BUY ABILITY"
	button.TextColor3 = TEXT_PRIMARY
	button.TextSize = 15
	button.ZIndex = 4
	button.Parent = card
	Instance.new("UICorner", button).CornerRadius = UDim.new(0, 12)

	local buttonStroke = Instance.new("UIStroke")
	buttonStroke.Color = Color3.fromRGB(218, 255, 230)
	buttonStroke.Thickness = 1
	buttonStroke.Transparency = 0.36
	buttonStroke.Parent = button

	actionButtons[ability.id] = button

	AnimUtil.WireButton(button, function()
		if getAbilityStatus(ability.id) ~= STATUS_NONE then
			return
		end

		local remote = getRequestRemote()
		if not remote then
			warn("[AbilityShopPanel] PerkProductPromptRequest remote missing")
			return
		end

		SoundUtil.Click()
		remote:FireServer(ability.id)
	end)

	refreshAbilityCard(ability.id)
end

function AbilityShopPanel.Init(screenGui: ScreenGui, onClose: () -> ())
	closeCallback = onClose

	overlay = Components.CreateDimOverlay(screenGui, function()
		AbilityShopPanel.Hide()
	end)

	local content: ScrollingFrame
	local closeBtn: TextButton
	canvas, uiScale, content, closeBtn = Components.CreatePanel(screenGui, "ABILITY SHOP", HEADER_COLOR, "Shop")
	canvas.Size = UDim2.fromScale(0.58, 0.5)
	canvas.BackgroundColor3 = PANEL_BG
	content.ScrollingEnabled = true
	content.ScrollingDirection = Enum.ScrollingDirection.Y
	content.AutomaticCanvasSize = Enum.AutomaticSize.Y
	content.CanvasSize = UDim2.fromOffset(0, 0)
	content.ScrollBarThickness = 8
	content.ElasticBehavior = Enum.ElasticBehavior.Always

	local panelStroke = canvas:FindFirstChildWhichIsA("UIStroke")
	if panelStroke then
		panelStroke.Color = PANEL_STROKE
		panelStroke.Transparency = 0.06
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
		studTexture.ImageTransparency = 0.92
		studTexture.TileSize = UDim2.fromOffset(74, 74)
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
			highlightLine.BackgroundColor3 = Color3.fromRGB(177, 240, 200)
			highlightLine.BackgroundTransparency = 0.7
		end
	end

	closeBtn.BackgroundColor3 = UIConfig.Colors.CloseBtn
	closeBtn.TextColor3 = UIConfig.Colors.TextWhite
	AnimUtil.WireButton(closeBtn, function()
		AbilityShopPanel.Hide()
	end)

	local wrapper = Instance.new("Frame")
	wrapper.Name = "Wrapper"
	wrapper.Size = UDim2.new(1, -18, 0, 0)
	wrapper.AutomaticSize = Enum.AutomaticSize.Y
	wrapper.BackgroundTransparency = 1
	wrapper.BorderSizePixel = 0
	wrapper.Parent = content

	local wrapperLayout = Instance.new("UIListLayout")
	wrapperLayout.FillDirection = Enum.FillDirection.Vertical
	wrapperLayout.Padding = UDim.new(0, 10)
	wrapperLayout.SortOrder = Enum.SortOrder.LayoutOrder
	wrapperLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	wrapperLayout.Parent = wrapper

	local intro = Instance.new("TextLabel")
	intro.Name = "Intro"
	intro.Size = UDim2.new(1, -20, 0, 42)
	intro.BackgroundTransparency = 1
	intro.Font = Enum.Font.GothamSemibold
	intro.Text = "Single-match abilities from AbilitySeller. These expire after one match and never become permanent."
	intro.TextColor3 = TEXT_MUTED
	intro.TextSize = 15
	intro.TextWrapped = true
	intro.LayoutOrder = 1
	intro.Parent = wrapper

	local cardsHolder = Instance.new("Frame")
	cardsHolder.Name = "CardsHolder"
	cardsHolder.Size = UDim2.new(1, -20, 0, 0)
	cardsHolder.BackgroundTransparency = 1
	cardsHolder.BorderSizePixel = 0
	cardsHolder.LayoutOrder = 2
	cardsHolder.Parent = wrapper

	cardsGridLayout = Instance.new("UIGridLayout")
	cardsGridLayout.CellSize = UDim2.new(0.5, -8, 0, 228)
	cardsGridLayout.CellPadding = UDim2.fromOffset(10, 10)
	cardsGridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	cardsGridLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	cardsGridLayout.VerticalAlignment = Enum.VerticalAlignment.Top
	cardsGridLayout.Parent = cardsHolder

	local function updateCardsHolderHeight()
		if not cardsGridLayout then
			return
		end
		cardsHolder.Size = UDim2.new(1, -20, 0, cardsGridLayout.AbsoluteContentSize.Y)
	end

	cardsGridLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(updateCardsHolderHeight)

	for index, ability in ipairs(PerkCatalog.All) do
		createAbilityCard(cardsHolder, ability, index)
		LocalPlayer:GetAttributeChangedSignal(ability.statusAttribute):Connect(function()
			refreshAbilityCard(ability.id)
		end)
	end

	updateCardsHolderHeight()
end

function AbilityShopPanel.Show()
	if not canvas or not uiScale or not overlay or visible then
		return
	end

	visible = true
	overlay.Visible = true
	refreshAllAbilityCards()
	SoundUtil.Open()
	AnimUtil.OpenPanel(canvas, uiScale)
end

function AbilityShopPanel.Hide()
	if not canvas or not uiScale or not overlay or not visible then
		return
	end

	visible = false
	overlay.Visible = false
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

function AbilityShopPanel.IsVisible(): boolean
	return visible
end

function AbilityShopPanel.Toggle()
	if visible then
		AbilityShopPanel.Hide()
	else
		AbilityShopPanel.Show()
	end
end

return AbilityShopPanel
