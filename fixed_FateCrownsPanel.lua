--[[
	FateCrownsPanel
	Crown collection / equip grid — shows ALL crowns (owned + locked).

	DARK + VIBRANT theme — front-page quality:
	  * Dark card backgrounds with rarity-glow borders
	  * Crown images from ItemCatalog (single source of truth)
	  * Equip / Equipped buttons
	  * Locked crowns shown as "???" with dim styling

	Used by: UIController (sidebar "Crowns" button)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
if not Shared then
	warn("[FateCrownsPanel] ReplicatedStorage.Shared not found — panel disabled")
	return { Init = function() end, Show = function() end, Hide = function() end,
		IsVisible = function() return false end, Toggle = function() end }
end
local CDPModule = Shared:WaitForChild("ClientDepsProvider", 10)
if not CDPModule then
	warn("[FateCrownsPanel] ClientDepsProvider not found — panel disabled")
	return { Init = function() end, Show = function() end, Hide = function() end,
		IsVisible = function() return false end, Toggle = function() end }
end
local Deps = require(CDPModule)
local UIConfig = Deps.UIConfig
local ItemCatalog = Deps.ItemCatalog

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

local equippedId: string = "crown_basic"

-- Track warned IDs so we only warn once per missing catalog entry
local _warnedMissing = {}

local FateCrownsPanel = {}

local function clearContent()
	for _, child in ipairs(contentFrame:GetChildren()) do
		if child:IsA("Frame") then child:Destroy() end
	end
end

local function refresh()
	clearContent()

	for i, item in ipairs(UIConfig.MockCrowns) do
		local isEquipped = item.owned and (item.id == equippedId)
		local actionText = nil
		local actionColor = nil

		if item.owned then
			actionText = isEquipped and "Equipped" or "Equip"
			actionColor = isEquipped and C.Green or C.EquipButton
		end

		-- Look up ItemCatalog.Crowns for image + iconText
		local catEntry = ItemCatalog.Get("Crowns", item.id)
		if not catEntry and not _warnedMissing[item.id] then
			_warnedMissing[item.id] = true
			warn(string.format("[FateCrownsPanel] No ItemCatalog.Crowns entry for '%s' — using placeholder", item.id))
		end

		local catalogImage = catEntry and ItemCatalog.GetImage(catEntry) or ""
		local catalogIconText = catEntry and catEntry.iconText or "👑"

		Components.CreateItemCard(contentFrame, {
			name = item.name,
			rarity = item.rarity,
			iconColor = item.iconColor,
			iconText = catalogIconText,
			image = catalogImage,
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
						print(string.format("[FateCrowns] Equipped: %s", item.name))
					end
					refresh()
				end
			end,
		}).LayoutOrder = i
	end
end

function FateCrownsPanel.Init(screenGui: ScreenGui, onClose: () -> ())
	closeCallback = onClose

	overlay = Components.CreateDimOverlay(screenGui, function()
		FateCrownsPanel.Hide()
	end)

	local content, closeBtn
	canvas, uiScale, content, closeBtn = Components.CreatePanel(screenGui, "👑 FATE CROWNS", C.HeaderCrowns, "Crowns")
	contentFrame = content

	Components.AddGridLayout(content)

	-- Wire close button click (visual feedback handled by UIStyle.WireCloseButton in Components)
	closeBtn.MouseButton1Click:Connect(function()
		SoundUtil.Close()
		FateCrownsPanel.Hide()
	end)

	refresh()
end

function FateCrownsPanel.Show()
	if visible then return end
	visible = true
	overlay.Visible = true
	refresh()
	SoundUtil.Open()
	AnimUtil.OpenPanel(canvas, uiScale)
end

function FateCrownsPanel.Hide()
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

function FateCrownsPanel.IsVisible(): boolean
	return visible
end

function FateCrownsPanel.Toggle()
	if visible then FateCrownsPanel.Hide() else FateCrownsPanel.Show() end
end

return FateCrownsPanel
