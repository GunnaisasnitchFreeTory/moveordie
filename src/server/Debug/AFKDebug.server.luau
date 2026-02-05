--[[
	AFKDebug
	Studio-only debug commands for testing AFK toggle.
	
	Commands:
		/afk   → Set yourself to AFK
		/back  → Return from AFK
	
	⚠️ This script does NOTHING outside of Studio.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

-- Guard: Only run in Studio
if not RunService:IsStudio() then
	return
end

local Server = ServerScriptService:WaitForChild("Server")
local PlayerStateService = require(Server:WaitForChild("PlayerStateService"))

local function log(...)
	print("[AFKDebug]", ...)
end

local function handleChat(player: Player, message: string)
	local command = string.lower(string.match(message, "^(%S+)") or "")
	
	if command == "/afk" then
		local success = PlayerStateService.SetAFK(player, true)
		if success then
			log(player.Name, "→ AFK")
		else
			log(player.Name, "could not go AFK (maybe InMatch?)")
		end
		
	elseif command == "/back" then
		local success = PlayerStateService.SetAFK(player, false)
		if success then
			log(player.Name, "→ back from AFK")
		else
			log(player.Name, "was not AFK")
		end
	end
end

local function setupPlayer(player: Player)
	player.Chatted:Connect(function(message)
		handleChat(player, message)
	end)
end

-- Wire up existing players
for _, player in ipairs(Players:GetPlayers()) do
	setupPlayer(player)
end

-- Wire up new players
Players.PlayerAdded:Connect(setupPlayer)

log("Loaded (Studio only) — /afk and /back available")

