--[[
	PlayerState
	Shared constants for player state tracking.
	
	Used by: PlayerStateService, MatchManager (future), UI (future)
]]

export type State = "Lobby" | "Waiting" | "InMatch" | "Spectating" | "AFK" | "TutorialLocked"

local PlayerState = {}

-- All valid player states
PlayerState.States = {
	Lobby = "Lobby",         -- In lobby, available for next match
	Waiting = "Waiting",     -- Match is active, waiting to join next one
	InMatch = "InMatch",     -- Currently playing in a match
	Spectating = "Spectating", -- Eliminated or observing
	AFK = "AFK",             -- Away from keyboard, skip for matchmaking
	TutorialLocked = "TutorialLocked", -- Must finish tutorial before movement/match participation
}

-- Default state for new players
PlayerState.DEFAULT = PlayerState.States.Lobby

-- Validate if a string is a valid state
function PlayerState.IsValid(state: string): boolean
	return PlayerState.States[state] ~= nil
end

-- Get all state names as array
function PlayerState.GetAll(): { State }
	return { "Lobby", "Waiting", "InMatch", "Spectating", "AFK", "TutorialLocked" }
end

return PlayerState
