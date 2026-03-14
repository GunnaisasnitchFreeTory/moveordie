--[[
	DailyRewardConfig
	Shared configuration for the daily rewards system.

	Used by: DailyRewardService (server), DailyRewardsPanel (client)
]]

local DailyRewardConfig = {}

DailyRewardConfig.CooldownSeconds = 86400    -- 24 hours
DailyRewardConfig.StreakResetSeconds = 172800 -- 48 hours (miss a day = streak resets)
DailyRewardConfig.MaxStreak = 7

-- iconText is the emoji/text fallback when icon asset is empty
DailyRewardConfig.Rewards = {
	[1] = { type = "Coins",  amount = 250,  label = "250 Coins",        icon = "rbxassetid://81959864063463", iconText = "F",  iconColor = {255, 220, 60} },
	[2] = { type = "Coins",  amount = 450,  label = "450 Coins",        icon = "rbxassetid://81959864063463", iconText = "F",  iconColor = {255, 220, 60} },
	[3] = { type = "Coins",  amount = 500,  label = "500 Coins",        icon = "rbxassetid://81959864063463", iconText = "F",  iconColor = {255, 220, 60} },
	[4] = { type = "Spins",  amount = 4,    label = "4 Free Spins",     icon = "rbxassetid://134540256061817", iconText = "SPIN", iconColor = {255, 200, 60} },
	[5] = { type = "Crate",  crateId = "crate_crown", amount = 3, label = "3 Crown Crates", icon = "rbxassetid://102125624504903", iconText = "CRATE", iconColor = {200, 150, 255} },
	[6] = { type = "Coins",  amount = 1000, label = "1000 Coins",       icon = "rbxassetid://81959864063463", iconText = "F",  iconColor = {255, 220, 60} },
	[7] = { type = "Crown",  crownId = "crown_hollow_purple", label = "Hollow Purple Crown", icon = "rbxassetid://88626832961620", iconText = "CROWN", iconColor = {148, 48, 255} },
}

return DailyRewardConfig
