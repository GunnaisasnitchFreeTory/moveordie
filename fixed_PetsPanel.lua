--[[
	PetsPanel
	Pet collection / equip grid — shows ALL pets (owned + locked).

	DARK + VIBRANT theme — front-page quality:
	  * Dark card backgrounds with rarity-glow borders
	  * Pet icons using ItemCatalog images
	  * Equip / Equipped buttons
	  * Locked pets shown as "???" with dim styling

	Data source: ItemCatalog (single source of truth)
	Ownership:   Player "OwnedPets" attribute (JSON array of catalog IDs)

	Used by: UIController (sidebar "Pets" button)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
if not Shared then
	warn("[PetsPanel] ReplicatedStorage.Shared not found — panel disabled")
	return { Init = function() end, Show = function() end, Hide = function() end,
		IsVisible = function() return false end, Toggle = function() end }
end
local CDPModule = Shared:WaitForChild("ClientDepsProvider", 10)
if not CDPModule then
	warn("[PetsPanel] ClientDepsProvider not found — panel disabled")
	return { Init = function() end, Show = function() end, Hide = function() end,
		IsVisible = function() return false end, Toggle = function() end }
end
local Deps = require(CDPModule)
local UIConfig = Deps.UIConfig
local ItemCatalog = Deps.ItemCatalog

if not UIConfig then
	warn("[PetsPanel] UIConfig not available — panel disabled")
	return { Init = function() end, Show = function() end, Hide = function() end,
		IsVisible = function() return false end, Toggle = function() end }
end

local Client = script.Parent
local AnimUtil   = require(Client:WaitForChild("AnimUtil"))
local SoundUtil  = require(Client:WaitForChild("SoundUtil"))
local Components = require(Client:WaitForChild("Components"))

local C = UIConfig.Colors

local player = Players.LocalPlayer

local canvas: CanvasGroup = nil
local uiScale: UIScale = nil
local overlay: Frame = nil
local contentFrame: ScrollingFrame = nil
local visible = false
local closeCallback: (() -> ())? = nil

local equippedId: string? = nil

local PetsPanel = {}

-- Helper: read OwnedPets attribute → set of catalog IDs
local function getOwnedPetSet(): { [string]: boolean }
	local json = player:GetAttribute("OwnedPets") or "[]"
	local ok, list = pcall(HttpService.JSONDecode, HttpService, json)
	if not ok or type(list) ~= "table" then return {} end
	local set = {}
	for _, id in ipairs(list) do
		set[id] = true
	end
	return set
end

local function clearContent()
	for _, child in ipairs(contentFrame:GetChildren()) do
		if child:IsA("Frame") then child:Destroy() end
	end
end

local function refresh()
	clearContent()

	local ownedSet = getOwnedPetSet()
	local allPets = ItemCatalog.GetAllPetsSorted()

	for i, pet in ipairs(allPets) do
		local isOwned = ownedSet[pet.id] == true
		local isEquipped = isOwned and (pet.id == equippedId)
		local actionText = nil
		local actionColor = nil

		if isOwned then
			actionText = isEquipped and "Equipped" or "Equip"
			actionColor = isEquipped and C.Green or C.EquipButton
		end

		Components.CreateItemCard(contentFrame, {
			name = pet.name,
			rarity = pet.rarity,
			iconColor = pet.iconColor,
			iconText = pet.iconText or "🐾",
			image = ItemCatalog.GetImage(pet),
			locked = not isOwned,
			equipped = isEquipped,
			owned = isOwned,
			actionText = actionText,
			actionColor = actionColor,
			onAction = function()
				if isOwned and not isEquipped then
					equippedId = pet.id
					SoundUtil.Equip()
					if UIConfig.DebugLog then
						print(string.format("[PetsPanel] Equipped: %s", pet.name))
					end
					refresh()
				end
			end,
		}).LayoutOrder = i
	end
end

function PetsPanel.Init(screenGui: ScreenGui, onClose: () -> ())
	closeCallback = onClose

	overlay = Components.CreateDimOverlay(screenGui, function()
		PetsPanel.Hide()
	end)

	local content, closeBtn
	canvas, uiScale, content, closeBtn = Components.CreatePanel(screenGui, "🐾 PETS", C.HeaderPets, "Pets")
	contentFrame = content

	Components.AddGridLayout(content)

	-- Wire close button click (visual feedback handled by UIStyle.WireCloseButton in Components)
	closeBtn.MouseButton1Click:Connect(function()
		SoundUtil.Close()
		PetsPanel.Hide()
	end)

	-- Listen for OwnedPets attribute changes to auto-refresh
	player:GetAttributeChangedSignal("OwnedPets"):Connect(function()
		if visible then refresh() end
	end)

	refresh()
end

function PetsPanel.Show()
	if visible then return end
	visible = true
	overlay.Visible = true
	refresh()
	SoundUtil.Open()
	AnimUtil.OpenPanel(canvas, uiScale)
end

function PetsPanel.Hide()
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

function PetsPanel.IsVisible(): boolean
	return visible
end

function PetsPanel.Toggle()
	if visible then PetsPanel.Hide() else PetsPanel.Show() end
end

return PetsPanel
