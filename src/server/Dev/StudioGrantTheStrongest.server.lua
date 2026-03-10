local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

if not RunService:IsStudio() then
	return
end

local Server = ServerScriptService:WaitForChild("Server")
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local InventoryService = require(Server:WaitForChild("InventoryService"))

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

local function grantStrongestItems(player: Player)
	if not waitForData(player) then
		warn(string.format("[StudioGrantTheStrongest] data not loaded for %s", player.Name))
		return
	end

	local iconOk = InventoryService.GrantItem(player, "IconImages", "icon_thestrongest")
	local crownOk = InventoryService.GrantItem(player, "Crowns", "crown_thestrongest")
	local equipOk = InventoryService.EquipItem(player, "IconImages", "icon_thestrongest")
	print(string.format(
		"[StudioGrantTheStrongest] player=%s iconGranted=%s crownGranted=%s iconEquipped=%s",
		player.Name,
		tostring(iconOk),
		tostring(crownOk),
		tostring(equipOk and equipOk.success == true)
	))
end

Players.PlayerAdded:Connect(function(player)
	task.spawn(grantStrongestItems, player)
end)

for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(grantStrongestItems, player)
end
