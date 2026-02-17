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

local Shared = ReplicatedStorage:WaitForChild("Shared", 60)
if not Shared then
	warn("[PetsPanel] Shared not found after 60s -- disabled")
	return { Init = function() end, Show = function() end, Hide = function() end,
		IsVisible = function() return false end, Toggle = function() end }
end

local CDPModule = Shared:WaitForChild("ClientDepsProvider", 60)
if not CDPModule then
	local _children = {}
	for _, c in ipairs(Shared:GetChildren()) do table.insert(_children, c.Name.."("..c.ClassName..")") end
	warn("[PetsPanel] ClientDepsProvider MISSING. Shared path:", Shared:GetFullName(), "| Shared children:", table.concat(_children, ", "))
	return { Init = function() end, Show = function() end, Hide = function() end,
		IsVisible = function() return false end, Toggle = function() end }
end

local ok, Deps = pcall(require, CDPModule)
if not ok or not Deps then
	warn("[PetsPanel] require(ClientDepsProvider) FAILED:", Deps)
	return { Init = function() end, Show = function() end, Hide = function() end,
		IsVisible = function() return false end, Toggle = function() end }
end
local UIConfig = Deps.UIConfig
local ItemCatalog = Deps.ItemCatalog

if not UIConfig then
	warn("[PetsPanel] UIConfig not available -- disabled")
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
local _equipDebounce = false  -- prevents double-fire + preserves optimistic equippedId

local PetsPanel = {}

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

local function refresh()
	clearContent()

	local ownedSet = getOwnedPetSet()
	-- During debounce, keep the optimistic equippedId so the UI updates instantly.
	-- Otherwise, sync with the authoritative server attribute.
	if not _equipDebounce then
		equippedId = player:GetAttribute("EquippedPet") or nil
	end
	local allPets = ItemCatalog.GetAllPetsSorted()

	for i, pet in ipairs(allPets) do
		local isOwned = ownedSet[pet.id] == true
		local isEquipped = isOwned and (pet.id == equippedId)
		local actionText = nil
		local actionColor = nil
		local subLabel = nil

		if isOwned then
			actionText = isEquipped and "Equipped" or "Equip"
			actionColor = isEquipped and C.Green or C.EquipButton
		else
			-- Show how to obtain
			if pet.shopOnly then
				subLabel = "Shop Only"
			else
				subLabel = "Pet Crate"
			end
		end

		Components.CreateViewportItemCard(contentFrame, {
			id = pet.id,
			name = pet.name,
			rarity = pet.rarity,
			iconColor = pet.iconColor,
			thumbnailBgColor = pet.thumbnailBgColor,
			iconText = pet.iconText or "\240\159\144\190",
			image = ItemCatalog.GetImage(pet),
			modelPath = pet.modelPath,
			locked = not isOwned,
			equipped = isEquipped,
			owned = isOwned,
			subLabel = subLabel,
			actionText = actionText,
			actionColor = actionColor,
			onAction = function()
				if not isOwned then return end
				if _equipDebounce then return end -- prevent double-fire
				_equipDebounce = true

				if isEquipped then
					-- Unequip
					local unequipRemote = getUnequipRemote()
					if unequipRemote then
						unequipRemote:FireServer("Pets")
					end
					equippedId = nil
				else
					-- Equip via server
					local equipRemote = getEquipRemote()
					if equipRemote then
						equipRemote:FireServer("Pets", pet.id)
					end
					equippedId = pet.id
				end

				SoundUtil.Equip()
				refresh() -- instant optimistic UI update

				-- Release debounce after attribute has time to replicate,
				-- then do a final sync refresh.
				task.delay(0.5, function()
					_equipDebounce = false
					if visible then refresh() end
				end)
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
	canvas, uiScale, content, closeBtn = Components.CreatePanel(screenGui, "\xF0\x9F\x90\xBE PETS", C.HeaderPets, "Pets")
	contentFrame = content

	Components.AddGridLayout(content)

	closeBtn.MouseButton1Click:Connect(function()
		SoundUtil.Close()
		PetsPanel.Hide()
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