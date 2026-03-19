--[[
	PlayerStateBootstrap
	Wires PlayerStateService to player join/leave events.
	
	This is the entry point for player state tracking.
	Runs once on server start.
]]

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = ServerScriptService:WaitForChild("Server")
local PlayerStateService = require(Server:WaitForChild("PlayerStateService"))
local TutorialService = require(Server:WaitForChild("TutorialService"))
local PlayerState = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlayerState"))

-- Initialize the service
PlayerStateService.Init()
TutorialService.Init()

local function registerAndPrime(player: Player)
	PlayerStateService.RegisterPlayer(player)
	PlayerStateService.SetState(player, PlayerState.States.TutorialLocked)
	TutorialService.PrimePlayer(player)
end

-- Handle players already in game (for Studio testing with "Run" instead of "Play")
for _, player in ipairs(Players:GetPlayers()) do
	registerAndPrime(player)
end

-- Wire up join/leave
Players.PlayerAdded:Connect(function(player)
	registerAndPrime(player)
end)

Players.PlayerRemoving:Connect(function(player)
	PlayerStateService.RemovePlayer(player)
end)

