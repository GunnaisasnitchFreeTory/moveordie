--[[
	RoundConfig
	Shared configuration for round timing and behavior.
	
	Round cycle: FreeMove → Telegraph → BeamWarning → Strike → Recovery
	
	Used by: RoundManager
]]

local RoundConfig = {}

-- Phase durations (seconds)
RoundConfig.FreeMoveSeconds = 7.1     -- Players can reposition freely (~5% faster)
RoundConfig.TelegraphGraceSeconds = 0.55 -- Grace: telegraph visible but players can still move (~8% faster)
RoundConfig.TelegraphSeconds = 1.9    -- Tile warning pulse (BEFORE beams appear) (~5% faster)
RoundConfig.FreezeSeconds = 5.7       -- Total freeze time (telegraph + beam warning) (~5% faster)
RoundConfig.StrikeSeconds = 0.25      -- Beam fires
RoundConfig.RecoverySeconds = 0.55    -- Brief pause before next round (~8% faster)

-- Match limits (caps to prevent infinite matches)
RoundConfig.MaxRoundsPerMatch = 20    -- 0 = unlimited
RoundConfig.MaxMatchSeconds = 180     -- 3 minutes max, 0 = unlimited

-- Winner detection
RoundConfig.MinPlayersForWinner = 2   -- Need at least 2 players to declare a winner
                                       -- Solo player matches run until cap or death

-- Debug
RoundConfig.DebugLog = true

return RoundConfig
