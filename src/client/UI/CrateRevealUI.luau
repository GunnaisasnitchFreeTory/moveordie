--[[
	CrateRevealUI
	Thin wrapper around RewardPopup (sibling in Client.UI folder).
	Preserves existing API so CrateShopPanel doesn't need changes.

	API:
	  CrateRevealUI.Init(screenGui)      -- no-op
	  CrateRevealUI.ShowReward(data)      -- single reward → RewardPopup.Show
	  CrateRevealUI.ShowRewards(items)    -- batch rewards → RewardPopup.ShowBatch

	Used by: CrateShopPanel
]]

local RewardPopup = nil
pcall(function()
	RewardPopup = require(script.Parent:WaitForChild("RewardPopup", 5))
end)

if not RewardPopup then
	warn("[CrateRevealUI] RewardPopup module not found in Client.UI — crate reveal disabled")
end

local CrateRevealUI = {}

function CrateRevealUI.Init(_screenGui)
	-- No-op: RewardPopup creates its own ScreenGui
end

function CrateRevealUI.ShowReward(data)
	if not data then return end
	if not RewardPopup then
		warn("[CrateRevealUI] RewardPopup not available")
		return
	end
	RewardPopup.Show({
		icon       = data.image or "",
		title      = "YOU WON!",
		name       = data.name or "MISSING ITEM",
		rarityText = data.rarity or "Common",
		okText     = "CLAIM",
		onDismiss  = nil,
		itemId     = data.itemId or "",
		itemType   = data.itemType or "",
		category   = data.category or "",
		iconText   = data.iconText or "",
		iconColor  = data.iconColor,
	})
end

-- Batch reveal for multi-crate purchases (3 or 6 crates)
function CrateRevealUI.ShowRewards(items)
	if not items or #items == 0 then return end
	if not RewardPopup then
		warn("[CrateRevealUI] RewardPopup not available")
		return
	end

	local mapped = {}
	for _, data in ipairs(items) do
		table.insert(mapped, {
			icon       = data.image or "",
			title      = "YOU WON!",
			name       = data.name or "MISSING ITEM",
			rarityText = data.rarity or "Common",
			itemId     = data.itemId or "",
			itemType   = data.itemType or "",
			category   = data.category or "",
			iconText   = data.iconText or "",
			iconColor  = data.iconColor,
			isDuplicate = data.isDuplicate or false,
		})
	end

	RewardPopup.ShowBatch(mapped)
end

return CrateRevealUI
