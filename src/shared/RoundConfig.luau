--[[
	RoundConfig
	Shared configuration for round timing and behavior.
	
	Round cycle: FreeMove → Freeze/Telegraph → Strike → Recovery
	
	Used by: RoundManager
]]

local RoundConfig = {}

-- Phase durations (seconds)
RoundConfig.FreeMoveSeconds = 7.5     -- Players can reposition freely
RoundConfig.FreezeSeconds = 6.0       -- Players frozen + telegraph warning
RoundConfig.StrikeSeconds = 0.25      -- Beam fires
RoundConfig.RecoverySeconds = 0.75    -- Brief pause before next round

-- Match limits (caps to prevent infinite matches)
RoundConfig.MaxRoundsPerMatch = 20    -- 0 = unlimited
RoundConfig.MaxMatchSeconds = 180     -- 3 minutes max, 0 = unlimited

-- Winner detection
RoundConfig.MinPlayersForWinner = 2   -- Need at least 2 players to declare a winner
                                       -- Solo player matches run until cap or death

-- Debug
RoundConfig.DebugLog = true

return RoundConfig
