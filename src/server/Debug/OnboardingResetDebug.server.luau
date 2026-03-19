--[[
	OnboardingResetDebug (Studio-only)
	One-click helper to simulate a fresh/new player onboarding flow.

	How to use:
	1) Set ENABLED = true
	2) Optional: set TARGET_USER_IDS (empty = all players in Studio)
	3) Start playtest
	4) Set ENABLED = false when done
]]

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local ENABLED = false
local TARGET_USER_IDS = {} -- e.g. { 12345678 }
local FORCE_FIRST_MATCH_TIPS_ATTRIBUTE = false

if not ENABLED then
	return
end

if not RunService:IsStudio() then
	warn("[OnboardingResetDebug] Refusing to run outside Studio")
	return
end

local Server = ServerScriptService:WaitForChild("Server")
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))

local function shouldReset(player: Player): boolean
	if #TARGET_USER_IDS == 0 then
		return true
	end
	for _, userId in ipairs(TARGET_USER_IDS) do
		if tonumber(userId) == player.UserId then
			return true
		end
	end
	return false
end

local function waitForDataLoaded(player: Player, timeoutSeconds: number): boolean
	local deadline = os.clock() + timeoutSeconds
	while os.clock() < deadline do
		if not player.Parent then
			return false
		end
		if PlayerDataService.IsLoaded(player) then
			return true
		end
		task.wait(0.2)
	end
	return PlayerDataService.IsLoaded(player)
end

local function resetPlayer(player: Player)
	if not shouldReset(player) then
		return
	end

	if not waitForDataLoaded(player, 15) then
		warn(string.format("[OnboardingResetDebug] skip player=%s reason=data_not_loaded", player.Name))
		return
	end

	PlayerDataService.SetField(player, "FirstMatchTipsShown", false)
	PlayerDataService.SetField(player, "FirstMatchTipMatchesServed", 0)
	PlayerDataService.SetField(player, "LifetimeMatchesCompleted", 0)
	PlayerDataService.SetField(player, "TutorialCompleted", false)

	if FORCE_FIRST_MATCH_TIPS_ATTRIBUTE then
		player:SetAttribute("DebugForceOnboardingTips", true)
	else
		player:SetAttribute("DebugForceOnboardingTips", false)
	end

	print(string.format(
		"[OnboardingResetDebug] reset player=%s userId=%d forcedTips=%s",
		player.Name,
		player.UserId,
		tostring(FORCE_FIRST_MATCH_TIPS_ATTRIBUTE)
	))
end

for _, player in ipairs(Players:GetPlayers()) do
	task.defer(resetPlayer, player)
end

Players.PlayerAdded:Connect(function(player)
	task.defer(resetPlayer, player)
end)

print("[OnboardingResetDebug] ACTIVE (Studio-only)")
