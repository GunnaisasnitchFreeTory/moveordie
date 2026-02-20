--[[
	PlayerData
	Shared data schema for persistent player progression.

	Used by: PlayerDataService (server), client UI (via attributes)

	VERSION HISTORY:
	  1 -- Initial: Coins, Owned/Equipped pets/crowns/icons, LifetimeWins
	  2 -- Added: LifetimeCoinsAchieved, WeeklyWins, WeeklyCoinsAchieved, WeeklyResetId
	  3 -- Added: LifetimeDeaths, TimePlayedSeconds
]]

local PlayerData = {}

PlayerData.VERSION = 3

-- DataStore key — Studio uses a separate namespace to prevent leaking test data into production
local RunService = game:GetService("RunService")
PlayerData.STORE_NAME = RunService:IsStudio() and "PlayerData_v1_STUDIO" or "PlayerData_v1"
PlayerData.KEY_PREFIX = "Player_"

-- Attribute names (replicated to client via player attributes)
PlayerData.Attributes = {
	Coins                 = "Coins",
	OwnedPets             = "OwnedPets",
	EquippedPet           = "EquippedPet",
	OwnedCrowns           = "OwnedCrowns",
	EquippedCrown         = "EquippedCrown",
	OwnedIcons            = "OwnedIcons",
	EquippedIcon          = "EquippedIcon",
	OwnedIconImages       = "OwnedIconImages",
	EquippedIconImage     = "EquippedIconImage",
	LifetimeWins          = "LifetimeWins",
	CoinMultiplier        = "CoinMultiplier",
	LifetimeCoinsAchieved = "LifetimeCoinsAchieved",
	WeeklyWins            = "WeeklyWins",
	WeeklyCoinsAchieved   = "WeeklyCoinsAchieved",
	LastDailyRewardTime   = "LastDailyRewardTime",
	DailyStreak           = "DailyStreak",
	LifetimeDeaths        = "LifetimeDeaths",
	TimePlayedSeconds     = "TimePlayedSeconds",
}

--- Compute current UTC week identifier.
function PlayerData.GetCurrentWeekId(): string
	return os.date("!%Y_W%W")
end

--- Default data for new players.
function PlayerData.GetDefaults(): { [string]: any }
	return {
		Version               = PlayerData.VERSION,
		Coins                 = 0,
		OwnedPets             = {},
		EquippedPet           = nil,
		OwnedCrowns           = {},
		EquippedCrown         = nil,
		OwnedIcons            = {},
		EquippedIcon          = nil,
		OwnedIconImages       = {},
		EquippedIconImage     = nil,
		LifetimeWins          = 0,
		LifetimeCoinsAchieved = 0,
		WeeklyWins            = 0,
		WeeklyCoinsAchieved   = 0,
		WeeklyResetId         = "",
		LastDailyRewardTime   = 0,
		DailyStreak           = 0,
		LifetimeDeaths        = 0,
		TimePlayedSeconds     = 0,
	}
end

--- Validate and migrate loaded data. Fills missing fields with defaults.
function PlayerData.Validate(data: { [string]: any }): { [string]: any }
	local defaults = PlayerData.GetDefaults()

	for key, defaultValue in pairs(defaults) do
		if data[key] == nil then
			data[key] = defaultValue
		end
	end

	if type(data.Coins) ~= "number" then data.Coins = 0 end
	if data.Coins < 0 then data.Coins = 0 end
	if type(data.OwnedPets) ~= "table" then data.OwnedPets = defaults.OwnedPets end
	if type(data.OwnedCrowns) ~= "table" then data.OwnedCrowns = defaults.OwnedCrowns end
	if type(data.OwnedIcons) ~= "table" then data.OwnedIcons = defaults.OwnedIcons end
	if type(data.OwnedIconImages) ~= "table" then data.OwnedIconImages = defaults.OwnedIconImages end
	if type(data.LifetimeWins) ~= "number" then data.LifetimeWins = 0 end
	if type(data.LifetimeCoinsAchieved) ~= "number" then data.LifetimeCoinsAchieved = 0 end
	if type(data.WeeklyWins) ~= "number" then data.WeeklyWins = 0 end
	if type(data.WeeklyCoinsAchieved) ~= "number" then data.WeeklyCoinsAchieved = 0 end
	if type(data.WeeklyResetId) ~= "string" then data.WeeklyResetId = "" end
	if type(data.LastDailyRewardTime) ~= "number" then data.LastDailyRewardTime = 0 end
	if type(data.DailyStreak) ~= "number" then data.DailyStreak = 0 end
	if type(data.LifetimeDeaths) ~= "number" then data.LifetimeDeaths = 0 end
	if type(data.TimePlayedSeconds) ~= "number" then data.TimePlayedSeconds = 0 end

	if data.EquippedPet ~= nil and type(data.EquippedPet) ~= "string" then
		data.EquippedPet = nil
	end
	if data.EquippedCrown ~= nil and type(data.EquippedCrown) ~= "string" then
		data.EquippedCrown = nil
	end
	if data.EquippedIcon ~= nil and type(data.EquippedIcon) ~= "string" then
		data.EquippedIcon = nil
	end
	if data.EquippedIconImage ~= nil and type(data.EquippedIconImage) ~= "string" then
		data.EquippedIconImage = nil
	end

	-- Weekly reset: if stored week doesn't match current week, zero weekly stats
	local currentWeek = PlayerData.GetCurrentWeekId()
	if data.WeeklyResetId ~= currentWeek then
		data.WeeklyWins            = 0
		data.WeeklyCoinsAchieved   = 0
		data.WeeklyResetId         = currentWeek
	end

	data.Version = PlayerData.VERSION
	return data
end

return PlayerData