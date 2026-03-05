local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

if not RunService:IsStudio() then
	return
end

-- Studio test helper for Brainrot bundle purchase re-testing.
-- This only runs in Studio and only strips Brainrot bundle ownership.
local ENABLE_STUDIO_BRAINROT_RESET = false
if not ENABLE_STUDIO_BRAINROT_RESET then
	return
end

local Server = ServerScriptService:WaitForChild("Server")
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local BundleCatalog = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BundleCatalog"))

local brainrotByCategory = {
	Pets = {},
	Crowns = {},
	IconImages = {},
}

do
	local bundle = BundleCatalog.Get("brainrot_bundle")
	if bundle and bundle.includes then
		for _, inc in ipairs(bundle.includes) do
			if type(inc) == "table" and type(inc.category) == "string" and type(inc.itemId) == "string" then
				local set = brainrotByCategory[inc.category]
				if set then
					set[inc.itemId] = true
				end
			end
		end
	end
end

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

local function filterOwned(list: {string}?, removeSet: {[string]: boolean})
	local out = table.create(list and #list or 0)
	local removed = 0
	for _, id in ipairs(list or {}) do
		if removeSet[id] then
			removed += 1
		else
			table.insert(out, id)
		end
	end
	return out, removed
end

local function resetPlayer(player: Player)
	if not waitForData(player) then
		return
	end

	local data = PlayerDataService.GetData(player)
	if not data then
		return
	end

	local nextPets, removedPets = filterOwned(data.OwnedPets, brainrotByCategory.Pets)
	local nextCrowns, removedCrowns = filterOwned(data.OwnedCrowns, brainrotByCategory.Crowns)
	local nextIcons, removedIcons = filterOwned(data.OwnedIconImages, brainrotByCategory.IconImages)

	PlayerDataService.SetField(player, "OwnedPets", nextPets)
	PlayerDataService.SetField(player, "OwnedCrowns", nextCrowns)
	PlayerDataService.SetField(player, "OwnedIconImages", nextIcons)

	if type(data.EquippedPet) == "string" and brainrotByCategory.Pets[data.EquippedPet] then
		PlayerDataService.SetField(player, "EquippedPet", nil)
	end
	if type(data.EquippedCrown) == "string" and brainrotByCategory.Crowns[data.EquippedCrown] then
		PlayerDataService.SetField(player, "EquippedCrown", nil)
	end
	if type(data.EquippedIconImage) == "string" and brainrotByCategory.IconImages[data.EquippedIconImage] then
		PlayerDataService.SetField(player, "EquippedIconImage", nil)
	end

	local processed = data.ProcessedGrants
	local clearedGrantKeys = 0
	if type(processed) == "table" then
		local nextProcessed = {}
		for key, value in pairs(processed) do
			local keep = true
			if type(key) == "string" then
				local lower = string.lower(key)
				if string.find(lower, "brainrot", 1, true) then
					keep = false
				else
					for itemId in pairs(brainrotByCategory.Pets) do
						if string.find(lower, string.lower(itemId), 1, true) then
							keep = false
							break
						end
					end
					if keep then
						for itemId in pairs(brainrotByCategory.Crowns) do
							if string.find(lower, string.lower(itemId), 1, true) then
								keep = false
								break
							end
						end
					end
					if keep then
						for itemId in pairs(brainrotByCategory.IconImages) do
							if string.find(lower, string.lower(itemId), 1, true) then
								keep = false
								break
							end
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
		"[StudioResetBrainrot] Reset %s: removedPets=%d removedCrowns=%d removedIcons=%d clearedGrantKeys=%d",
		player.Name,
		removedPets,
		removedCrowns,
		removedIcons,
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

