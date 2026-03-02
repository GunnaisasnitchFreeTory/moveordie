--[[
	WalkerPetBootstrap
	Starts the server-side walker-pet NPC controller.
	Runs once on server start (after PlayerData/State are available).
]]

local ServerScriptService = game:GetService("ServerScriptService")
local Server = ServerScriptService:WaitForChild("Server")

task.wait(0.5) -- ensure data services are up

local WalkerPetServerController = require(Server:WaitForChild("WalkerPetServerController"))
WalkerPetServerController.Init()
