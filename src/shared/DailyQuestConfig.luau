--[[
	DailyQuestConfig
	Shared configuration for the daily quest system.

	Quests reset every UTC day (midnight).
	Progress is tracked server-side and persisted in DailyQuestData.

	Quest types:
	  TimePlayed         -- seconds of total session time (reads TimePlayedSeconds)
	  WinsToday          -- match wins in current day
	  SwordKillsToday    -- sword kills in current day
	  TTSSurvivalsToday  -- TungTungSahur 30s survive events today
]]

local DailyQuestConfig = {}

DailyQuestConfig.Quests = {
	quest_play_15min = {
		id          = "quest_play_15min",
		label       = "Time Traveler",
		description = "Play for 15 minutes",
		type        = "TimePlayed",
		target      = 900,      -- 15 min in seconds
		order       = 1,
		reward      = { type = "Coins", amount = 700 },
		icon        = "\xF0\x9F\x95\x90",
		iconColor   = { 255, 220, 60 },
	},
	quest_win_3games = {
		id          = "quest_win_3games",
		label       = "Champion",
		description = "Win 3 rounds in one day",
		type        = "WinsToday",
		target      = 3,
		order       = 2,
		reward      = { type = "Crown", itemId = "crown_sparkle" },
		icon        = "\xF0\x9F\x8F\x86",
		iconColor   = { 255, 200, 50 },
	},
	quest_sword_kills = {
		id          = "quest_sword_kills",
		label       = "Sword Master",
		description = "Eliminate 4 players with a sword",
		type        = "SwordKillsToday",
		target      = 4,
		order       = 3,
		reward      = { type = "Pet", itemId = "pet_eagle" },
		icon        = "\xE2\x9A\x94",
		iconColor   = { 220, 80, 80 },
	},
	quest_survive_tts = {
		id          = "quest_survive_tts",
		label       = "TungTung Survivor",
		description = "Survive TungTungSahur 7 times",
		type        = "TTSSurvivalsToday",
		target      = 7,
		order       = 4,
		reward      = { type = "Pet", itemId = "pet_tungtungsahur" },
		icon        = "\xF0\x9F\x91\xBE",
		iconColor   = { 255, 60, 60 },
	},
}

return DailyQuestConfig
