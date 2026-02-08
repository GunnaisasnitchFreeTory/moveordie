--[[
	Client entry point — Fate Beams
	Initializes all client-side controllers.
	Each require is wrapped in pcall so one failing controller
	does not break the others.
]]

local Client = script

print("[Client] Initializing...")

-- 1. SpectateController (self-executing on require)
local spectateOk, spectateErr = pcall(function()
	require(Client:WaitForChild("SpectateController"))
end)
if spectateOk then
	print("[Client] SpectateController loaded OK")
else
	warn("[Client] SpectateController FAILED:", spectateErr)
end

-- 2. StormFXController (has Init method)
local stormOk, stormErr = pcall(function()
	local StormFXController = require(Client:WaitForChild("StormFXController"))
	StormFXController.Init()
end)
if stormOk then
	print("[Client] StormFXController loaded OK")
else
	warn("[Client] StormFXController FAILED:", stormErr)
end

-- 3. UIController (has Init method)
local uiOk, uiErr = pcall(function()
	local UIController = require(Client:WaitForChild("UIController"))
	UIController.Init()
end)
if uiOk then
	print("[Client] UIController loaded OK")
else
	warn("[Client] UIController FAILED:", uiErr)
end

print("[Client] Init complete")
