local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

if not RunService:IsStudio() then
	return
end

-- Safety: keep this OFF by default. Enable manually only when you explicitly
-- want to wipe Ultra Crown ownership for local Studio testing.
local ENABLE_STUDIO_ULTRA_CROWN_RESET = false
if not ENABLE_STUDIO_ULTRA_CROWN_RESET then
	return
end

local TARGET_CROWN_ID = "crown_ultra"

local Server = ServerScriptService:WaitForChild("Server")
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))

local function waitForData(player: Player): boolean
	local started = os.clock()
	while os.clock() - started < 20 do
		if PlayerDataService.IsLoaded(player) then
			return true
		end
		task.wait(0.1)
	end
	return false
end

local function resetUltraCrown(player: Player)
	if not waitForData(player) then
		return
	end

	local data = PlayerDataService.GetData(player)
	if not data then
		return
	end

	local ownedCrowns = data.OwnedCrowns or {}
	local filtered = table.create(#ownedCrowns)
	local removed = 0
	for _, crownId in ipairs(ownedCrowns) do
		if crownId == TARGET_CROWN_ID then
			removed += 1
		else
			table.insert(filtered, crownId)
		end
	end
	PlayerDataService.SetField(player, "OwnedCrowns", filtered)

	if data.EquippedCrown == TARGET_CROWN_ID then
		PlayerDataService.SetField(player, "EquippedCrown", nil)
	end

	local processed = data.ProcessedGrants
	local clearedGrantKeys = 0
	if type(processed) == "table" then
		local nextProcessed = {}
		for key, value in pairs(processed) do
			local keep = true
			if type(key) == "string" then
				local lower = string.lower(key)
				if string.find(lower, "gamepass", 1, true)
					and string.find(lower, TARGET_CROWN_ID, 1, true)
				then
					keep = false
				elseif string.find(lower, TARGET_CROWN_ID, 1, true) then
					keep = false
				end
			end
			if keep then
				nextProcessed[key] = value
			else
				clearedGrantKeys += 1
			end
		end
		PlayerDataService.SetField(player, "ProcessedGrants", nextProcessed)
	end

	warn(string.format(
		"[StudioResetUltraCrown] Reset %s: removedUltra=%d clearedGrantKeys=%d",
		player.Name,
		removed,
		clearedGrantKeys
	))
end

local function wirePlayer(player: Player)
	task.spawn(resetUltraCrown, player)
	player.CharacterAdded:Connect(function()
		task.delay(0.2, function()
			resetUltraCrown(player)
		end)
	end)
end

Players.PlayerAdded:Connect(wirePlayer)
for _, player in ipairs(Players:GetPlayers()) do
	wirePlayer(player)
end
