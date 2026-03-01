local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

if not RunService:IsStudio() then
	return
end

local Server = ServerScriptService:WaitForChild("Server")
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local InventoryService = require(Server:WaitForChild("InventoryService"))
local ItemCatalog = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ItemCatalog"))

local ALLOWED_USER_IDS = {
	[game.CreatorId] = true,
}

local function waitForData(player: Player): boolean
	local started = os.clock()
	while os.clock() - started < 15 do
		if PlayerDataService.IsLoaded(player) then
			return true
		end
		task.wait(0.1)
	end
	return false
end

local function grantAll(player: Player)
	if not ALLOWED_USER_IDS[player.UserId] then
		return
	end
	if not waitForData(player) then
		return
	end

	print(string.format("[DevGrant] Studio grant-all enabled for %s", player.Name))

	for petId in pairs(ItemCatalog.Pets or {}) do
		if not InventoryService.OwnsItem(player, "Pets", petId) then
			InventoryService.GrantItem(player, "Pets", petId)
		end
	end

	for crownId in pairs(ItemCatalog.Crowns or {}) do
		if not InventoryService.OwnsItem(player, "Crowns", crownId) then
			InventoryService.GrantItem(player, "Crowns", crownId)
		end
	end
end

Players.PlayerAdded:Connect(grantAll)

for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(grantAll, player)
end
