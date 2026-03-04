local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

if not RunService:IsStudio() then
	return
end

-- Safety: keep this OFF by default. Enable manually only when you explicitly
-- want to wipe FNAF ownership for local Studio testing.
local ENABLE_STUDIO_FNAF_RESET = false
if not ENABLE_STUDIO_FNAF_RESET then
	return
end

local Server = ServerScriptService:WaitForChild("Server")
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local BundleCatalog = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BundleCatalog"))

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

	local processedGrants = data.ProcessedGrants
	local clearedGrantKeys = 0
	if type(processedGrants) == "table" then
		local nextProcessed = {}
		for key, value in pairs(processedGrants) do
			local keep = true
			if type(key) == "string" then
				local lower = string.lower(key)
				if string.find(lower, "fnaf", 1, true) or string.find(lower, "bundle", 1, true) then
					keep = false
				else
					for petId in pairs(fnafPetIds) do
						if string.find(lower, string.lower(petId), 1, true) then
							keep = false
							break
						end
					end
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
		"[StudioResetFNAF] Reset %s: removedFnafPets=%d clearedGrantKeys=%d",
		player.Name,
		removed,
		clearedGrantKeys
	))
end

local function wirePlayer(player: Player)
	task.spawn(resetPlayer, player)
	player.CharacterAdded:Connect(function()
		task.delay(0.2, function()
			resetPlayer(player)
		end)
	end)
end

Players.PlayerAdded:Connect(wirePlayer)

for _, player in ipairs(Players:GetPlayers()) do
	wirePlayer(player)
end

