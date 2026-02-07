--[[
	CoinConfig
	Shared configuration for match coin rewards.
	
	Used by: EliminationTracker, EconomyService, MatchManager
]]

local CoinConfig = {}

-- Reward amounts per placement
CoinConfig.FirstPlace = 100
CoinConfig.SecondPlace = 60
CoinConfig.ThirdPlace = 35
CoinConfig.Participation = 15
CoinConfig.LastPlace = 0

-- Time window (seconds) for grouping simultaneous eliminations into same placement
-- Players eliminated within this window of each other share the same rank
CoinConfig.SimultaneousWindow = 0.1

-- Debug logging
CoinConfig.DebugLog = true

return CoinConfig

