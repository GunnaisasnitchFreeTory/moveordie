--[[
	SpawnConfig
	Shared configuration for player spawning and teleportation.
	
	Used by: MapManager, MatchManager
]]

local SpawnConfig = {}

-- Arena spawn settings
SpawnConfig.ArenaSpawnYOffset = 6           -- Studs above platform top surface
SpawnConfig.ArenaSpawnSpreadRadius = 30     -- Random spread radius from center
SpawnConfig.ArenaSpawnMinDistance = 5       -- Min distance between spawn points

-- Lobby spawn settings
SpawnConfig.LobbySpawnPosition = Vector3.new(0, 10, -80)  -- Fallback if no SpawnLocation
SpawnConfig.ReturnToLobbyOnEnd = true       -- Teleport players back when match ends

-- Teleport safety
SpawnConfig.TeleportRetryDelay = 0.5        -- Seconds to wait if character not ready
SpawnConfig.MaxTeleportRetries = 3          -- Max retries per player

-- Debug
SpawnConfig.DebugLog = true

return SpawnConfig

