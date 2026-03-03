-- Shared quest reward icon mapping.
-- This is the single source of truth for Daily Quest reward icons.

local QuestRewardIconResolver = {}

local COIN_ICON = "rbxassetid://72345557707985"
local CRATE_ICON = "rbxassetid://108812530080296"
local SPIN_ICON = "rbxassetid://112640795485396"

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

	return nil
end

return QuestRewardIconResolver
