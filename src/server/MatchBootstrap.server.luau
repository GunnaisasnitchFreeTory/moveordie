--[[
	MatchBootstrap
	Initializes MatchManager and starts the match loop.
	
	Runs once on server start.
	Depends on: PlayerStateService (must be initialized first)
]]

local ServerScriptService = game:GetService("ServerScriptService")

local Server = ServerScriptService:WaitForChild("Server")
local MatchManager = require(Server:WaitForChild("MatchManager"))

-- Small delay to ensure PlayerStateBootstrap + PlayerDataBootstrap run first
-- (Roblox doesn't guarantee script execution order)
task.wait(0.5)

-- Initialize and start
MatchManager.Init()
MatchManager.StartLoop()

