-- Shared quest reward icon mapping.
-- This is the single source of truth for Daily Quest reward icons.

local QuestRewardIconResolver = {}
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:FindFirstChild("Shared") or ReplicatedStorage:WaitForChild("Shared", 5)
local ItemCatalog = if Shared then require(Shared:WaitForChild("ItemCatalog")) else nil

local COIN_ICON = "rbxassetid://81959864063463"
local CRATE_ICON = "rbxassetid://102125624504903"
local SPIN_ICON = "rbxassetid://134540256061817"

function QuestRewardIconResolver.GetQuestRewardIcon(reward): string?
	if type(reward) ~= "table" then
		return nil
	end

	local rewardType = string.upper(tostring(reward.type or ""))

	if rewardType == "COINS" or rewardType == "FATECOINS" or rewardType == "FATE_COINS" then
		return COIN_ICON
	end

	if rewardType == "CRATE" or rewardType == "CRATES" or reward.crateId ~= nil then
		return CRATE_ICON
	end

	if rewardType == "SPIN"
		or rewardType == "SPINS"
		or rewardType == "FREE_SPIN"
		or rewardType == "FREESPIN"
		or reward.spinCount ~= nil
	then
		return SPIN_ICON
	end

	if rewardType == "ICONIMAGE" or rewardType == "ICON_IMAGE" then
		local iconId = tostring(reward.itemId or "")
		if iconId ~= "" and ItemCatalog and ItemCatalog.IconImages then
			local entry = ItemCatalog.IconImages[iconId]
			if entry and type(entry.image) == "string" and entry.image ~= "" then
				print(string.format("[QuestRewardIconResolver] static icon image reward id=%s image=%s", iconId, entry.image))
				return entry.image
			end
		end
	end

	return nil
end

return QuestRewardIconResolver
