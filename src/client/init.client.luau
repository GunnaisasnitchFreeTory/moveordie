--[[
	Client entry point — Fate Beams
	Initializes all client-side controllers.
	Each require is wrapped in pcall so one failing controller
	does not break the others.

	Boot order:
	  0. game.Loaded
	  1. ClientDepsProvider.WaitUntilReady(5) — one signal for all deps
	  2. SpectateController
	  3. StormFXController
	  4. UIController (panels use cached deps — instant)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Client = script

local _bootTime = tick()
local function ts() return string.format("%.3f", tick() - _bootTime) end

print(string.format("[UIBoot] t=%s Client init starting", ts()))

-- 0. Wait for game to load (assets replicated)
if not game:IsLoaded() then
	game.Loaded:Wait()
end
print(string.format("[UIBoot] t=%s Loaded", ts()))

-- 0b. Pre-load ClientDepsProvider (populates shared deps once for all panels)
local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
if Shared then
	local cdpMod = Shared:FindFirstChild("ClientDepsProvider")
	if cdpMod then
		local cdpOk, CDP = pcall(require, cdpMod)
		if cdpOk and CDP and CDP.WaitUntilReady then
			local depsOk = CDP.WaitUntilReady(5)
			print(string.format("[UIBoot] t=%s DepsReady=%s", ts(), tostring(depsOk)))
		else
			warn(string.format("[UIBoot] t=%s ClientDepsProvider require failed: %s", ts(), tostring(CDP)))
		end
	else
		warn(string.format("[UIBoot] t=%s ClientDepsProvider not in Shared", ts()))
	end
else
	warn(string.format("[UIBoot] t=%s Shared folder not found", ts()))
end

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

-- 3. UIController (has Init method — panels use cached deps)
local uiOk, uiErr = pcall(function()
	local UIController = require(Client:WaitForChild("UIController"))
	UIController.Init()
end)
if uiOk then
	print(string.format("[UIBoot] t=%s UIController READY", ts()))
else
	warn(string.format("[UIBoot] t=%s UIController FAILED: %s", ts(), tostring(uiErr)))
end

-- 4. PetFollowerController (spawns + animates equipped pet models)
local petOk, petErr = pcall(function()
	local PetFollowerController = require(Client:WaitForChild("PetFollowerController"))
	PetFollowerController.Init()
end)
if petOk then
	print("[Client] PetFollowerController loaded OK")
else
	warn("[Client] PetFollowerController FAILED:", petErr)
end

-- 5. IconFollowerController (spawns + animates equipped icon image models)
local iconFollowerOk, iconFollowerErr = pcall(function()
	local IconFollowerController = require(Client:WaitForChild("IconFollowerController"))
	IconFollowerController.Init()
end)
if iconFollowerOk then
	print("[Client] IconFollowerController loaded OK")
else
	warn("[Client] IconFollowerController FAILED:", iconFollowerErr)
end

-- 6. MusicController (lobby + map music with transitions)
local musicOk, musicErr = pcall(function()
	local MusicController = require(Client:WaitForChild("MusicController"))
	MusicController.Init()
end)
if musicOk then
	print("[Client] MusicController loaded OK")
else
	warn("[Client] MusicController FAILED:", musicErr)
end

-- 6. WorldIndicators (floating labels above SpinWheel + CrateShop)
local indicatorsOk, indicatorsErr = pcall(function()
	local WorldIndicators = require(Client:WaitForChild("WorldIndicators"))
	WorldIndicators.Init()
end)
if indicatorsOk then
	print("[Client] WorldIndicators loaded OK")
else
	warn("[Client] WorldIndicators FAILED:", indicatorsErr)
end

-- 7. BrainrotPickupController (floating animation + pickup popup)
local brainrotOk, brainrotErr = pcall(function()
	local BrainrotPickupController = require(Client:WaitForChild("BrainrotPickupController"))
	BrainrotPickupController.Init()
end)
if brainrotOk then
	print("[Client] BrainrotPickupController loaded OK")
else
	warn("[Client] BrainrotPickupController FAILED:", brainrotErr)
end

-- 8. CoinPickupController (hover + rotation for round coins)
local coinOk, coinErr = pcall(function()
	local CoinPickupController = require(Client:WaitForChild("CoinPickupController"))
	CoinPickupController.Init()
end)
if coinOk then
	print("[Client] CoinPickupController loaded OK")
else
	warn("[Client] CoinPickupController FAILED:", coinErr)
end

print(string.format("[Client] Init complete (t=%s)", ts()))
