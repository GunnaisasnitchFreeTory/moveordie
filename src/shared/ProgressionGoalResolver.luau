--[[
	ProgressionGoalResolver
	Resolves the cheapest unowned direct Fate Coin goal from the live catalog.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemCatalog = require(Shared:WaitForChild("ItemCatalog"))

local ProgressionGoalResolver = {}
local OWNERSHIP_TYPE_MAP = {
	Crown = "OwnedCrowns",
	ExclusiveCrown = "OwnedCrowns",
	Pet = "OwnedPets",
	ExclusivePet = "OwnedPets",
}
local SCANNED_CATALOGS = {
	"Pets",
	"Crowns",
	"Premium",
}

local function normalizeOwnedSet(value: any): { [string]: boolean }
	local ownedSet = {}
	if type(value) ~= "table" then
		return ownedSet
	end

	local hasArrayItems = #value > 0
	if hasArrayItems then
		for _, itemId in ipairs(value) do
			if type(itemId) == "string" and itemId ~= "" then
				ownedSet[itemId] = true
			end
		end
		return ownedSet
	end

	for itemId, isOwned in pairs(value) do
		if type(itemId) == "string" and itemId ~= "" and isOwned == true then
			ownedSet[itemId] = true
		end
	end

	return ownedSet
end

function ProgressionGoalResolver.ResolveNextGoal(state: {
	coins: number?,
	ownedCrowns: any,
	ownedPets: any,
}): { id: string, name: string, type: string, price: number, currentCoins: number, remainingCoins: number }?
	local currentCoins = math.max(0, math.floor(tonumber((state and state.coins) or 0) or 0))
	local ownedCrowns = normalizeOwnedSet(state and state.ownedCrowns)
	local ownedPets = normalizeOwnedSet(state and state.ownedPets)
	local ownedByCategory = {
		OwnedCrowns = ownedCrowns,
		OwnedPets = ownedPets,
	}

	local cheapestGoal = nil
	local seenItemIds = {}

	for _, catalogName in ipairs(SCANNED_CATALOGS) do
		local catalog = ItemCatalog[catalogName]
		if type(catalog) == "table" then
			for itemId, entry in pairs(catalog) do
				if type(itemId) == "string" and type(entry) == "table" and not seenItemIds[itemId] then
					seenItemIds[itemId] = true

					local itemType = tostring(entry.type or "")
					local ownershipKey = OWNERSHIP_TYPE_MAP[itemType]
					local price = tonumber(entry.fateCoins)
					local ownedSet = ownershipKey and ownedByCategory[ownershipKey]
					if ownershipKey and ownedSet and price and price > 0 and not ownedSet[itemId] then
						local flooredPrice = math.max(0, math.floor(price))
						local itemName = tostring(entry.name or itemId)
						if not cheapestGoal
							or flooredPrice < cheapestGoal.price
							or (flooredPrice == cheapestGoal.price and itemName < cheapestGoal.name)
						then
							cheapestGoal = {
								id = itemId,
								name = itemName,
								type = itemType,
								price = flooredPrice,
								currentCoins = currentCoins,
								remainingCoins = math.max(0, flooredPrice - currentCoins),
							}
						end
					end
				end
			end
		end
	end

	return cheapestGoal
end

function ProgressionGoalResolver.Resolve(state)
	return ProgressionGoalResolver.ResolveNextGoal(state)
end

return ProgressionGoalResolver
