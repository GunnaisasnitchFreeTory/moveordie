--[[
	MatchState
	Shared constants for match lifecycle states.
	
	Used by: MatchManager, UI (future)
]]

export type State = "Intermission" | "Playing" | "Ending"

local MatchState = {}

-- All valid match states
MatchState.States = {
	Intermission = "Intermission",  -- Waiting for next match, collecting players
	Playing = "Playing",            -- Match is active
	Ending = "Ending",              -- Match ended, showing results
}

-- Validate if a string is a valid state
function MatchState.IsValid(state: string): boolean
	return MatchState.States[state] ~= nil
end

-- Get all state names as array
function MatchState.GetAll(): { State }
	return { "Intermission", "Playing", "Ending" }
end

return MatchState

