--[[
	PlayerStateService
	Server-authoritative player state tracking.
	
	API:
		Init()                        → Initialize the service
		GetState(player)              → State
		SetState(player, state)       → boolean (success)
		IsAFK(player)                 → boolean
		SetAFK(player, isAFK)         → boolean (success)
		GetPlayersInState(state)      → { Player }
		RemovePlayer(player)          → void (cleanup)
	
	States: Lobby, Waiting, InMatch, Spectating, AFK
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlayerState = require(Shared:WaitForChild("PlayerState"))

-- Config
local DEBUG_LOG = true -- Set false to disable state change logging

-- Internal state
local playerStates: { [Player]: string } = {}
local previousStates: { [Player]: string } = {} -- For AFK toggle to restore previous state
local initialized = false

-- Removal callbacks: fired BEFORE state is cleared in RemovePlayer
-- Signature: fn(player: Player, oldState: string?)
local removalCallbacks: { (Player, string?) -> () } = {}
local stateChangedCallbacks: { (Player, string?, string) -> () } = {}

local PlayerStateService = {}

--[[ 
	Initialize the service.
	Call once from bootstrap.
]]
function PlayerStateService.Init()
	if initialized then
		warn("[PlayerStateService] Already initialized")
		return
	end
	initialized = true
	
	if DEBUG_LOG then
		print("[PlayerStateService] Initialized")
	end
end

--[[
	Get current state for a player.
	Returns nil if player is not tracked.
]]
function PlayerStateService.GetState(player: Player): string?
	return playerStates[player]
end

--[[
	Set state for a player.
	Returns false if state is invalid.
]]
function PlayerStateService.SetState(player: Player, state: string): boolean
	if not PlayerState.IsValid(state) then
		warn("[PlayerStateService] Invalid state:", state)
		return false
	end
	
	local oldState = playerStates[player]
	
	-- Don't log if state hasn't changed
	if oldState == state then
		return true
	end
	
	playerStates[player] = state
	
	-- Replicate to client via attribute (used by StormFXController, etc.)
	player:SetAttribute("PlayerState", state)
	
	if DEBUG_LOG then
		print(string.format("[PlayerStateService] %s: %s → %s", 
			player.Name, 
			oldState or "nil", 
			state
		))
	end

	for _, fn in ipairs(stateChangedCallbacks) do
		local ok, err = pcall(fn, player, oldState, state)
		if not ok then
			warn(string.format("[PlayerStateService] State callback error: %s", tostring(err)))
		end
	end
	
	return true
end

--[[
	Check if player is AFK.
]]
function PlayerStateService.IsAFK(player: Player): boolean
	return playerStates[player] == PlayerState.States.AFK
end

--[[
	Toggle AFK state.
	When going AFK: stores previous state
	When leaving AFK: restores previous state (defaults to Lobby)
]]
function PlayerStateService.SetAFK(player: Player, isAFK: boolean): boolean
	local currentState = playerStates[player]
	
	if isAFK then
		-- Going AFK
		if currentState == PlayerState.States.AFK then
			return true -- Already AFK
		end
		
		-- Can't go AFK while in match
		if currentState == PlayerState.States.InMatch then
			if DEBUG_LOG then
				print(string.format("[PlayerStateService] %s cannot go AFK while InMatch", player.Name))
			end
			return false
		end
		
		-- Store previous state and set AFK
		previousStates[player] = currentState
		return PlayerStateService.SetState(player, PlayerState.States.AFK)
	else
		-- Leaving AFK
		if currentState ~= PlayerState.States.AFK then
			return true -- Not AFK, nothing to do
		end
		
		-- Restore previous state or default to Lobby
		local restoreTo = previousStates[player] or PlayerState.DEFAULT
		previousStates[player] = nil
		return PlayerStateService.SetState(player, restoreTo)
	end
end

--[[
	Get all players currently in a specific state.
]]
function PlayerStateService.GetPlayersInState(state: string): { Player }
	if not PlayerState.IsValid(state) then
		warn("[PlayerStateService] Invalid state for query:", state)
		return {}
	end
	
	local result = {}
	for player, playerState in pairs(playerStates) do
		if playerState == state then
			table.insert(result, player)
		end
	end
	return result
end

--[[
	Register a new player (call on PlayerAdded).
	Sets default state to Lobby.
]]
function PlayerStateService.RegisterPlayer(player: Player)
	if playerStates[player] then
		warn("[PlayerStateService] Player already registered:", player.Name)
		return
	end
	
	playerStates[player] = PlayerState.DEFAULT
	
	-- Replicate to client via attribute (used by StormFXController, etc.)
	player:SetAttribute("PlayerState", PlayerState.DEFAULT)
	
	if DEBUG_LOG then
		print(string.format("[PlayerStateService] %s joined → %s", player.Name, PlayerState.DEFAULT))
	end
end

--[[
	Register a callback that fires BEFORE a player's state is cleared on removal.
	Use this to react to player disconnects (e.g., elimination tracking).
	Callback signature: fn(player: Player, oldState: string?)
]]
function PlayerStateService.OnPlayerRemoval(fn: (Player, string?) -> ())
	table.insert(removalCallbacks, fn)
end

function PlayerStateService.OnStateChanged(fn: (Player, string?, string) -> ())
	table.insert(stateChangedCallbacks, fn)
end

--[[
	Remove a player (call on PlayerRemoving).
	Fires removal callbacks BEFORE clearing state, then cleans up.
]]
function PlayerStateService.RemovePlayer(player: Player)
	local state = playerStates[player]
	
	-- Fire removal callbacks BEFORE clearing state (so listeners can read old state)
	for _, fn in ipairs(removalCallbacks) do
		local ok, err = pcall(fn, player, state)
		if not ok then
			warn(string.format("[PlayerStateService] Removal callback error: %s", tostring(err)))
		end
	end
	
	playerStates[player] = nil
	previousStates[player] = nil
	
	if DEBUG_LOG and state then
		print(string.format("[PlayerStateService] %s left (was %s)", player.Name, state))
	end
end

--[[
	Get count of players in each state (debug utility).
]]
function PlayerStateService.GetStateCounts(): { [string]: number }
	local counts = {}
	for _, state in pairs(PlayerState.GetAll()) do
		counts[state] = 0
	end
	
	for _, state in pairs(playerStates) do
		counts[state] = (counts[state] or 0) + 1
	end
	
	return counts
end

return PlayerStateService

