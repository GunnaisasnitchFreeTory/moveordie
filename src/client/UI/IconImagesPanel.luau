--[[
	IconImagesPanel
	Icon Image collection / equip grid — shows all icon images (owned + locked).

	Icon Images are 3D follower companions (like pets) that follow the player
	and can be equipped simultaneously with a pet (on the opposite side).

	Equip category: "IconImages"
	Attribute: "EquippedIconImage"
	Catalog: ItemCatalog.IconImages

	Used by: UIController (sidebar "Icons" button)
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared", 60)
if not Shared then
	warn("[IconImagesPanel] Shared not found after 60s -- disabled")
	return { Init = function() end, Show = function() end, Hide = function() end,
		IsVisible = function() return false end, Toggle = function() end }
end

local CDPModule = Shared:WaitForChild("ClientDepsProvider", 60)
if not CDPModule then
	local _children = {}
	for _, c in ipairs(Shared:GetChildren()) do table.insert(_children, c.Name.."("..c.ClassName..")") end
	warn("[IconImagesPanel] ClientDepsProvider MISSING. Shared path:", Shared:GetFullName(), "| Shared children:", table.concat(_children, ", "))
	return { Init = function() end, Show = function() end, Hide = function() end,
		IsVisible = function() return false end, Toggle = function() end }
end

local ok, Deps = pcall(require, CDPModule)
if not ok or not Deps then
	warn("[IconImagesPanel] require(ClientDepsProvider) FAILED:", Deps)
	return { Init = function() end, Show = function() end, Hide = function() end,
		IsVisible = function() return false end, Toggle = function() end }
end
local UIConfig = Deps.UIConfig
local ItemCatalog = Deps.ItemCatalog

local Client = script.Parent
local AnimUtil   = require(Client:WaitForChild("AnimUtil"))
local SoundUtil  = require(Client:WaitForChild("SoundUtil"))
local Components = require(Client:WaitForChild("Components"))

local C = UIConfig.Colors
local S = UIConfig.Sizes

local player = Players.LocalPlayer

local canvas: CanvasGroup = nil
local uiScale: UIScale = nil
local overlay: Frame = nil
local contentFrame: ScrollingFrame = nil
local visible = false
local closeCallback: (() -> ())? = nil

local equippedId: string? = nil
local _equipDebounce = false

local IconImagesPanel = {}

local RARITY_COLORS = {
	Common    = C.Common,
	Uncommon  = C.Uncommon,
	Rare      = C.Rare,
	Epic      = C.Epic,
	Legendary = C.Legendary,
}

local function getOwnedIconImageSet(): { [string]: boolean }
	local json = player:GetAttribute("OwnedIconImages") or "[]"
	local success, list = pcall(game.HttpService.JSONDecode, game.HttpService, json)
	if not success or type(list) ~= "table" then return {} end
	local set = {}
	for _, id in ipairs(list) do
		set[id] = true
	end
	return set
end

local function getEquipRemote(): RemoteEvent?
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then return nil end
	return remotes:FindFirstChild("EquipItem")
end

local function getUnequipRemote(): RemoteEvent?
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then return nil end
	return remotes:FindFirstChild("UnequipItem")
end

local function clearContent()
	for _, child in ipairs(contentFrame:GetChildren()) do
		if child:IsA("Frame") then child:Destroy() end
	end
end

local function refresh()
	clearContent()

	local ownedSet = getOwnedIconImageSet()
	if not _equipDebounce then
		equippedId = player:GetAttribute("EquippedIconImage") or nil
		if equippedId == "" then equippedId = nil end
	end

	local allIcons = {}
	if ItemCatalog.GetAllIconImagesSorted then
		allIcons = ItemCatalog.GetAllIconImagesSorted()
	end

	for i, item in ipairs(allIcons) do
		local isOwned = ownedSet[item.id] == true
		local isEquipped = isOwned and (item.id == equippedId)
		local actionText = nil
		local actionColor = nil
		local subLabel = nil

		if isOwned then
			if isEquipped then
				actionText = "EQUIPPED"
				actionColor = C.Equipped or Color3.fromRGB(80, 200, 80)
				subLabel = "Tap to unequip"
			else
				actionText = "EQUIP"
				actionColor = C.Equip or Color3.fromRGB(80, 160, 255)
			end
		else
			local acqLabel = ItemCatalog.GetIconImageAcquisitionLabel and ItemCatalog.GetIconImageAcquisitionLabel(item.id)
			subLabel = acqLabel or "Locked"
		end

		local rarityStr = item.rarity or "Legendary"
		local iconColor = RARITY_COLORS[rarityStr] or C.Legendary
		local catalogImage = ItemCatalog.GetImage(item)

		Components.CreateViewportItemCard(contentFrame, {
			name = item.name or "MISSING ITEM",
			rarity = rarityStr,
			iconColor = iconColor,
			iconText = item.iconText or "",
			image = catalogImage,
			modelPath = item.modelPath,
			locked = not isOwned,
			equipped = isEquipped,
			owned = isOwned,
			subLabel = subLabel,
			actionText = actionText,
			actionColor = actionColor,
			onAction = function()
				if not isOwned then return end
				if _equipDebounce then return end
				_equipDebounce = true

				if isEquipped then
					local unequipRemote = getUnequipRemote()
					if unequipRemote then
						unequipRemote:FireServer("IconImages")
					end
					equippedId = nil
				else
					local equipRemote = getEquipRemote()
					if equipRemote then
						equipRemote:FireServer("IconImages", item.id)
					end
					equippedId = item.id
				end

				SoundUtil.Equip()
				refresh()

				task.delay(0.5, function()
					_equipDebounce = false
					if visible then refresh() end
				end)
			end,
		}).LayoutOrder = i
	end
end

function IconImagesPanel.Init(screenGui: ScreenGui, onClose: () -> ())
	closeCallback = onClose

	overlay = Components.CreateDimOverlay(screenGui, function()
		IconImagesPanel.Hide()
	end)

	local content, closeBtn
	canvas, uiScale, content, closeBtn = Components.CreatePanel(screenGui, "ICON IMAGES", C.HeaderIcons, "Icons")
	contentFrame = content

	Components.AddGridLayout(content)

	closeBtn.MouseButton1Click:Connect(function()
		SoundUtil.Close()
		IconImagesPanel.Hide()
	end)

	refresh()

	player:GetAttributeChangedSignal("EquippedIconImage"):Connect(function()
		if visible and not _equipDebounce then refresh() end
	end)
	player:GetAttributeChangedSignal("OwnedIconImages"):Connect(function()
		if visible then refresh() end
	end)
end

function IconImagesPanel.Show()
	if visible then return end
	visible = true
	overlay.Visible = true
	refresh()
	SoundUtil.Open()
	AnimUtil.OpenPanel(canvas, uiScale)
end

function IconImagesPanel.Hide()
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

function IconImagesPanel.IsVisible(): boolean
	return visible
end

function IconImagesPanel.Toggle()
	if visible then IconImagesPanel.Hide() else IconImagesPanel.Show() end
end

return IconImagesPanel