--[[
	DailyRewardConfig
	Shared configuration for the daily rewards system.

	Used by: DailyRewardService (server), DailyRewardsPanel (client)
]]

local DailyRewardConfig = {}

-- !! TESTING: set to 0 to allow instant re-claim for testing. Revert to 86400 for production.
DailyRewardConfig.CooldownSeconds = 0 -- TESTING (normally 86400 = 24 hours)
DailyRewardConfig.StreakResetSeconds = 999999 -- TESTING (normally 172800 = 48 hours)
DailyRewardConfig.MaxStreak = 7

-- iconText is the emoji/text fallback when icon asset is empty
DailyRewardConfig.Rewards = {
	[1] = { type = "Coins",  amount = 250,  label = "250 Coins",        icon = "rbxassetid://130002796842909", iconText = "F",  iconColor = {255, 220, 60} },
	[2] = { type = "Coins",  amount = 450,  label = "450 Coins",        icon = "rbxassetid://130002796842909", iconText = "F",  iconColor = {255, 220, 60} },
	[3] = { type = "Coins",  amount = 500,  label = "500 Coins",        icon = "rbxassetid://130002796842909", iconText = "F",  iconColor = {255, 220, 60} },
	[4] = { type = "Spins",  amount = 4,    label = "4 Free Spins",     icon = "",                            iconText = "\xF0\x9F\x8E\xB0", iconColor = {255, 200, 60} },
	[5] = { type = "Crate",  crateId = "crate_crown", amount = 3, label = "3 Crown Crates", icon = "",       iconText = "\xF0\x9F\x93\xA6", iconColor = {200, 150, 255} },
	[6] = { type = "Coins",  amount = 1000, label = "1000 Coins",       icon = "rbxassetid://130002796842909", iconText = "F",  iconColor = {255, 220, 60} },
	[7] = { type = "Crown",  crownId = "crown_hollow_purple", label = "Hollow Purple Crown", icon = "rbxassetid://71121412594159", iconText = "\xF0\x9F\x91\x91", iconColor = {148, 48, 255} },
}

return DailyRewardConfig
