--[[
	RoundConfig
	Shared configuration for round timing and behavior.
	
	Used by: RoundManager
]]

local RoundConfig = {}

-- Phase durations (seconds)
RoundConfig.FreezeSeconds = 1.0       -- Players frozen, can't move
RoundConfig.TelegraphSeconds = 1.0    -- Warning phase, tiles flash
RoundConfig.StrikeSeconds = 0.25      -- Beam fires
RoundConfig.RecoverySeconds = 0.75    -- Brief pause before next round

-- Match limits
RoundConfig.MaxRoundsPerMatch = 10    -- 0 = unlimited (run until match ends)

-- Debug
RoundConfig.DebugLog = true

return RoundConfig

