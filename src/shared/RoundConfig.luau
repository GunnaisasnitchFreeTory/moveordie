--[[
	RoundConfig
	Shared configuration for round timing and behavior.
	
	Round cycle: FreeMove → Telegraph → BeamWarning → Strike → Recovery
	
	Used by: RoundManager
]]

local RoundConfig = {}

-- Phase durations (seconds)
RoundConfig.FreeMoveSeconds = 7.5     -- Players can reposition freely
RoundConfig.TelegraphGraceSeconds = 0.6  -- Grace: telegraph visible but players can still move
RoundConfig.TelegraphSeconds = 2.0    -- Tile warning pulse (BEFORE beams appear)
RoundConfig.FreezeSeconds = 6.0       -- Total freeze time (telegraph + beam warning)
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
