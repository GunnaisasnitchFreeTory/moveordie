local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

if not RunService:IsStudio() then
	return
end

local Server = ServerScriptService:WaitForChild("Server")
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local BundleCatalog = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BundleCatalog"))

local ALLOWED_USER_IDS = {
	[game.CreatorId] = true,
}
local ALLOWED_USERNAMES = {
	ihavehopsxd = true,
}

local fnafPetIds = {}
do
	local bundle = BundleCatalog.Get("fnaf_pets_bundle")
	if bundle and bundle.includes then
		for _, inc in ipairs(bundle.includes) do
			if inc.category == "Pets" and type(inc.itemId) == "string" then
				fnafPetIds[inc.itemId] = true
			end
		end
	end
end

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

local function resetPlayer(player: Player)
	if not ALLOWED_USER_IDS[player.UserId] and not ALLOWED_USERNAMES[string.lower(player.Name)] then
		return
	end
	if not waitForData(player) then
		return
	end

	local data = PlayerDataService.GetData(player)
	if not data then
		return
	end

	local ownedPets = data.OwnedPets or {}
	local filtered = table.create(#ownedPets)
	local removed = 0
	for _, petId in ipairs(ownedPets) do
		if fnafPetIds[petId] then
			removed += 1
		else
			table.insert(filtered, petId)
		end
	end

	PlayerDataService.SetField(player, "OwnedPets", filtered)

	local equippedPet = data.EquippedPet
	if type(equippedPet) == "string" and fnafPetIds[equippedPet] then
		PlayerDataService.SetField(player, "EquippedPet", "")
	end

	PlayerDataService.SetField(player, "Coins", 0)

	warn(string.format(
		"[StudioResetFNAF] Reset %s: removedFnafPets=%d coins=0",
		player.Name,
		removed
	))
end

Players.PlayerAdded:Connect(resetPlayer)

for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(resetPlayer, player)
end

