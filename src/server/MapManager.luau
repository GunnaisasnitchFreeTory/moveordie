--[[
	MapManager
	Server-side arena registration and lifecycle hooks.
	
	The arena (SquarePlatformMap) is ALWAYS visible in the world.
	This manager only tracks state and provides hooks for future systems.
	
	API:
		Init()            → Initialize and locate arena
		GetArena()        → BasePart reference
		IsActive()        → boolean (match in progress on arena)
		OnMatchStart()    → Called when Playing phase begins
		OnMatchEnd()      → Called when match ends
]]

local Workspace = game:GetService("Workspace")

--[[ CONFIGURATION ]]
local Config = {
	ArenaName = "SquarePlatformMap",
	DebugLog = true,
}

--[[ INTERNAL STATE ]]
local arena: BasePart? = nil
local isActive: boolean = false
local initialized: boolean = false

local MapManager = {}

--[[ HELPERS ]]

local function log(...)
	if Config.DebugLog then
		print("[MapManager]", ...)
	end
end

--[[ PUBLIC API ]]

--[[
	Initialize the MapManager.
	Locates and validates the existing arena in Workspace.
]]
function MapManager.Init()
	if initialized then
		warn("[MapManager] Already initialized")
		return
	end
	
	-- Locate the arena
	local found = Workspace:FindFirstChild(Config.ArenaName)
	
	if not found then
		error(string.format("[MapManager] Arena '%s' not found in Workspace! Create it before running.", Config.ArenaName))
	end
	
	if not found:IsA("BasePart") and not found:IsA("Model") then
		warn(string.format("[MapManager] Arena '%s' is a %s (expected BasePart or Model)", Config.ArenaName, found.ClassName))
	end
	
	arena = found
	initialized = true
	isActive = false
	
	log(string.format("Initialized — Arena '%s' registered (%s)", Config.ArenaName, found.ClassName))
end

--[[
	Get the arena reference.
	Returns nil if not initialized.
]]
function MapManager.GetArena(): Instance?
	return arena
end

--[[
	Check if a match is currently active on the arena.
]]
function MapManager.IsActive(): boolean
	return isActive
end

--[[
	Called when a match starts (Playing phase begins).
	Sets internal state to Active.
]]
function MapManager.OnMatchStart()
	if not initialized then
		warn("[MapManager] Not initialized, cannot start match")
		return
	end
	
	isActive = true
	log("Match started — Arena active")
	
	-- Future: Enable hazards, reset tiles, etc.
end

--[[
	Called when a match ends.
	Sets internal state to Idle.
]]
function MapManager.OnMatchEnd()
	if not initialized then
		warn("[MapManager] Not initialized, cannot end match")
		return
	end
	
	isActive = false
	log("Match ended — Arena idle")
	
	-- Future: Disable hazards, reset platform, etc.
end

return MapManager

