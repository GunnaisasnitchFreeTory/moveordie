--[[
	FateCrownsPanel
	Crown collection / equip grid — shows ALL 17 crowns organized by source.

	Display order:
	  • Level Crowns   (earned by wins milestones)
	  • Findable Crowns (from Crown Crate / Spin Wheel)
	  • Exclusive Crowns (Shop-only, Robux)

	Each card:
	  • ViewportFrame showing the 3D crown model
	  • Owned = full color + Equip button (server-wired)
	  • Unowned = greyed/locked + source label:
	      Level → "X Wins"
	      Findable → "Crown Crate"
	      Exclusive → "Shop Only"

	Data source: ItemCatalog.GetAllCrownsSorted()
	Ownership:   Player "OwnedCrowns" attribute (JSON array of catalog IDs)

	Used by: UIController (sidebar "Crowns" button)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local Shared = ReplicatedStorage:WaitForChild("Shared", 60)
if not Shared then
	warn("[FateCrownsPanel] Shared not found after 60s -- disabled")
	return { Init = function() end, Show = function() end, Hide = function() end,
		IsVisible = function() return false end, Toggle = function() end }
end

local CDPModule = Shared:WaitForChild("ClientDepsProvider", 60)
if not CDPModule then
	warn("[FateCrownsPanel] ClientDepsProvider MISSING")
	return { Init = function() end, Show = function() end, Hide = function() end,
		IsVisible = function() return false end, Toggle = function() end }
end

local ok, Deps = pcall(require, CDPModule)
if not ok or not Deps then
	warn("[FateCrownsPanel] require(ClientDepsProvider) FAILED:", Deps)
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

local player = Players.LocalPlayer

local canvas: CanvasGroup = nil
local uiScale: UIScale = nil
local overlay: Frame = nil
local contentFrame: ScrollingFrame = nil
local visible = false
local closeCallback: (() -> ())? = nil

local equippedId: string? = nil

local FateCrownsPanel = {}

local function getOwnedCrownSet(): { [string]: boolean }
	local json = player:GetAttribute("OwnedCrowns") or "[]"
	local okDec, list = pcall(HttpService.JSONDecode, HttpService, json)
	if not okDec or type(list) ~= "table" then return {} end
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

--- Build a sub-label for unowned crowns based on source (delegates to ItemCatalog)
local function getSubLabel(crown): string?
	return ItemCatalog.GetCrownAcquisitionLabel(crown.id)
end

local function refresh()
	clearContent()

	local ownedSet = getOwnedCrownSet()
	equippedId = player:GetAttribute("EquippedCrown") or nil
	local allCrowns = ItemCatalog.GetAllCrownsSorted()

	for i, crown in ipairs(allCrowns) do
		local isOwned = ownedSet[crown.id] == true
		local isEquipped = isOwned and (crown.id == equippedId)
		local actionText = nil
		local actionColor = nil
		local subLabel = nil

		if isOwned then
			actionText = isEquipped and "Equipped" or "Equip"
			actionColor = isEquipped and C.Green or C.EquipButton
		else
			subLabel = getSubLabel(crown)
		end

		Components.CreateViewportItemCard(contentFrame, {
			name = crown.name,
			rarity = crown.rarity,
			iconColor = crown.iconColor,
			thumbnailBgColor = crown.thumbnailBgColor,
			iconText = crown.iconText or "\240\159\145\145",
			image = ItemCatalog.GetImage(crown),
			modelPath = crown.modelPath,
			locked = not isOwned,
			equipped = isEquipped,
			owned = isOwned,
			subLabel = subLabel,
			actionText = actionText,
			actionColor = actionColor,
			onAction = function()
				if isOwned then
					if isEquipped then
						-- Unequip
						local unequipRemote = getUnequipRemote()
						if unequipRemote then
							unequipRemote:FireServer("Crowns")
						end
						equippedId = nil
					else
						-- Equip via server
						local equipRemote = getEquipRemote()
						if equipRemote then
							equipRemote:FireServer("Crowns", crown.id)
						end
						equippedId = crown.id
					end
					SoundUtil.Equip()
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
	canvas, uiScale, content, closeBtn = Components.CreatePanel(screenGui, "\240\159\145\145 FATE CROWNS", C.HeaderCrowns, "Crowns")
	contentFrame = content

	Components.AddGridLayout(content)

	closeBtn.MouseButton1Click:Connect(function()
		SoundUtil.Close()
		FateCrownsPanel.Hide()
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

	-- Refresh when ownership/equip changes
	player:GetAttributeChangedSignal("OwnedCrowns"):Connect(function()
		if visible then refresh() end
	end)
	player:GetAttributeChangedSignal("EquippedCrown"):Connect(function()
		if visible then refresh() end
	end)

	-- Also listen for InventoryUpdated remote
	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
		if remotes then
			local invUpdate = remotes:FindFirstChild("InventoryUpdated")
			if invUpdate and invUpdate:IsA("RemoteEvent") then
				invUpdate.OnClientEvent:Connect(function()
					if visible then refresh() end
				end)
			end
		end
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
