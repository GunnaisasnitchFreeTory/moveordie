--[[
	MatchBootstrap
	Initializes MatchManager, GlobalLeaderboardService, and starts the match loop.
	
	Runs once on server start.
	Depends on: PlayerStateService (must be initialized first)
]]

local ServerScriptService = game:GetService("ServerScriptService")

local Server = ServerScriptService:WaitForChild("Server")
local MatchManager = require(Server:WaitForChild("MatchManager"))
local GlobalLeaderboardService = require(Server:WaitForChild("GlobalLeaderboardService"))
local DailyQuestService = require(Server:WaitForChild("DailyQuestService"))

-- Small delay to ensure PlayerStateBootstrap + PlayerDataBootstrap run first
-- (Roblox doesn't guarantee script execution order)
task.wait(0.5)

-- Initialize GlobalLeaderboardService FIRST so board parts are found
-- and rendering works when players seed stats on join.
GlobalLeaderboardService.Init()
DailyQuestService.Init()

-- Initialize MatchManager (creates MatchStatus, inits MapManager, RoundManager, EconomyService)
MatchManager.Init()

-- Start match loop (waits for first eligible player before beginning intermission)
MatchManager.StartLoop()
