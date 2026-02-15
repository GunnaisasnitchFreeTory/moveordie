--[[
	CoinConfig
	Shared configuration for match coin rewards.
	
	Used by: EliminationTracker, EconomyService, MatchManager
]]

local CoinConfig = {}

-- Reward amounts per placement (5–12 player matches)
CoinConfig.FirstPlace = 100
CoinConfig.SecondPlace = 60
CoinConfig.ThirdPlace = 35
CoinConfig.Participation = 15
CoinConfig.LastPlace = 0

-- Small match threshold: if playerCount <= this, use SmallMatchPayouts table
CoinConfig.SmallMatchMaxPlayers = 4

-- Per-placement payout tables for small lobbies (indexed by player count).
-- Every placement earns coins — last place is always > 0.
-- Values are coin amounts per placement rank (1st, 2nd, 3rd, 4th).
CoinConfig.SmallMatchPayouts = {
	[2] = { 100, 50 },            -- 1st=100, 2nd=50
	[3] = { 100, 60, 30 },        -- 1st=100, 2nd=60, 3rd=30
	[4] = { 100, 70, 40, 20 },    -- 1st=100, 2nd=70, 3rd=40, 4th=20
}

-- Time window (seconds) for grouping simultaneous eliminations into same placement
-- Players eliminated within this window of each other share the same rank
CoinConfig.SimultaneousWindow = 0.1

-- Debug logging
CoinConfig.DebugLog = true

return CoinConfig
