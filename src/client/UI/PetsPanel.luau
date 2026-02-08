--[[
	PetsPanel
	Pet collection / equip grid — shows ALL pets (owned + locked).

	DARK + VIBRANT theme — front-page quality:
	  • Dark card backgrounds with rarity-glow borders
	  • Cute pet icons, glossy icon areas
	  • Equip / Equipped buttons
	  • Locked pets shown as "???" with dim styling

	Used by: UIController (sidebar "Pets" button)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UIConfig = require(Shared:WaitForChild("UIConfig"))

local Client = script.Parent
local AnimUtil   = require(Client:WaitForChild("AnimUtil"))
local SoundUtil  = require(Client:WaitForChild("SoundUtil"))
local Components = require(Client:WaitForChild("Components"))

local C = UIConfig.Colors

local canvas: CanvasGroup = nil
local uiScale: UIScale = nil
local overlay: Frame = nil
local contentFrame: ScrollingFrame = nil
local visible = false
local closeCallback: (() -> ())? = nil

local equippedId: string = "pet_chick"

local PetsPanel = {}

local function clearContent()
	for _, child in ipairs(contentFrame:GetChildren()) do
		if child:IsA("Frame") then child:Destroy() end
	end
end

local function refresh()
	clearContent()

	for i, item in ipairs(UIConfig.MockPets) do
		local isEquipped = item.owned and (item.id == equippedId)
		local actionText = nil
		local actionColor = nil

		if item.owned then
			actionText = isEquipped and "Equipped" or "Equip"
			actionColor = isEquipped and C.Green or C.EquipButton
		end

		Components.CreateItemCard(contentFrame, {
			name = item.name,
			rarity = item.rarity,
			iconColor = item.iconColor,
			iconText = "🐾",
			locked = not item.owned,
			equipped = isEquipped,
			owned = item.owned,
			actionText = actionText,
			actionColor = actionColor,
			onAction = function()
				if item.owned and not isEquipped then
					equippedId = item.id
					SoundUtil.Equip()
					if UIConfig.DebugLog then
						print(string.format("[PetsPanel] Equipped: %s", item.name))
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
	canvas, uiScale, content, closeBtn = Components.CreatePanel(screenGui, "🐾 PETS", C.HeaderPets)
	contentFrame = content

	Components.AddGridLayout(content)

	AnimUtil.WireButton(closeBtn, function()
		SoundUtil.Close()
		PetsPanel.Hide()
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
