--[[
	PlayerStateBootstrap
	Wires PlayerStateService to player join/leave events.
	
	This is the entry point for player state tracking.
	Runs once on server start.
]]

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local Server = ServerScriptService:WaitForChild("Server")
local PlayerStateService = require(Server:WaitForChild("PlayerStateService"))

-- Initialize the service
PlayerStateService.Init()

-- Handle players already in game (for Studio testing with "Run" instead of "Play")
for _, player in ipairs(Players:GetPlayers()) do
	PlayerStateService.RegisterPlayer(player)
end

-- Wire up join/leave
Players.PlayerAdded:Connect(function(player)
	PlayerStateService.RegisterPlayer(player)
end)

Players.PlayerRemoving:Connect(function(player)
	PlayerStateService.RemovePlayer(player)
end)

