--[[
	MonetizationConfig
	Single source of truth for all Roblox monetization IDs used by the game.

	Structure:
	  - DeveloperProducts: consumable purchases handled by ProcessReceipt
	  - GamePasses: permanent entitlements checked via UserOwnsGamePassAsync

	Each entry keeps the live ID plus a clear internal id/name so the rest of
	the codebase can reference these values without hardcoding numbers.
]]

local MonetizationConfig = {}

MonetizationConfig.DeveloperProducts = {
	Utility = {
		FreezePlayer = {
			id = "freeze_player",
			name = "Freeze Player",
			productId = 3558060610,
			robux = 15,
		},
		ForceNextMode = {
			id = "force_next_mode",
			name = "FORCE NEXT MODE!",
			productId = 3558060942,
			robux = 5,
		},
	},

	Abilities = {
		PerkSpeed = {
			id = "perk_speed",
			name = "Speed Ability",
			productId = 3558061524,
			robux = 5,
		},
		PerkJump = {
			id = "perk_jump",
			name = "Jump Ability",
			productId = 3558061875,
			robux = 5,
		},
	},

	CoinPacks = {
		Coins500 = {
			id = "coins_500",
			name = "500 Fate Coins",
			productId = 3558062485,
			robux = 100,
			coinsAmount = 500,
		},
		Coins2000 = {
			id = "coins_2000",
			name = "2,000 Fate Coins",
			productId = 3558062762,
			robux = 200,
			coinsAmount = 2000,
		},
		Coins5000 = {
			id = "coins_5000",
			name = "5,000 Fate Coins",
			productId = 3558062931,
			robux = 400,
			coinsAmount = 5000,
		},
		Coins10000 = {
			id = "coins_10000",
			name = "10,000 Fate Coins",
			productId = 3558063167,
			robux = 500,
			coinsAmount = 10000,
		},
		Coins20000 = {
			id = "coins_20000",
			name = "20,000 Fate Coins",
			productId = 3558063333,
			robux = 600,
			coinsAmount = 20000,
		},
		Coins80000 = {
			id = "coins_80000",
			name = "80,000 Fate Coins",
			productId = 3558063773,
			robux = 800,
			coinsAmount = 80000,
		},
		Coins100000 = {
			id = "coins_100000",
			name = "100,000 Fate Coins",
			productId = 3558063985,
			robux = 1000,
			coinsAmount = 100000,
		},
		Coins150000 = {
			id = "coins_150000",
			name = "150,000 Fate Coins",
			productId = 3558064229,
			robux = 1200,
			coinsAmount = 150000,
		},
		Coins200000 = {
			id = "coins_200000",
			name = "200,000 Fate Coins",
			productId = 3558064423,
			robux = 2000,
			coinsAmount = 200000,
		},
	},

	Spins = {
		Spin1 = {
			id = "spin_1",
			name = "1 SPIN",
			productId = 3558070641,
			robux = 10,
			spins = 1,
			coins = 250,
		},
		Spin3 = {
			id = "spin_3",
			name = "3 SPINS",
			productId = 3558070880,
			robux = 30,
			spins = 3,
			coins = 450,
		},
		Spin10 = {
			id = "spin_10",
			name = "10 SPINS",
			productId = 3558071478,
			robux = 90,
			spins = 10,
			coins = 850,
		},
	},

	Crates = {
		CrownCrates6 = {
			id = "crate_crown_6",
			name = "6 Crown Crates",
			productId = 3558072648,
			robux = 400,
			crateId = "crate_crown",
			quantity = 6,
		},
		CommonPetCrates6 = {
			id = "crate_pet_common_6",
			name = "6 Common Pet Crates",
			productId = 3558072874,
			robux = 400,
			crateId = "crate_pet_common",
			quantity = 6,
		},
		RarePetCrates6 = {
			id = "crate_pet_rare_6",
			name = "6 Rare Pet Crates",
			productId = 3558073054,
			robux = 400,
			crateId = "crate_pet_rare",
			quantity = 6,
		},
		EpicPetCrates6 = {
			id = "crate_pet_epic_6",
			name = "6 Epic Pet Crates",
			productId = 3558073268,
			robux = 400,
			crateId = "crate_pet_epic",
			quantity = 6,
		},
	},
}

MonetizationConfig.GamePasses = {
	Bundles = {
		BrainrotBundle = {
			id = "brainrot_bundle",
			name = "Brainrot Bundle",
			gamepassId = 1714491142,
			robux = 800,
		},
		FnafPetsBundle = {
			id = "fnaf_pets_bundle",
			name = "Animatronic Pets Bundle",
			gamepassId = 1732407562,
			robux = 500,
		},
		VIP = {
			id = "bundle_vip",
			name = "VIP Bundle",
			gamepassId = 1754012702,
			robux = 500,
		},
	},

	Pets = {
		DarkFalcon = {
			id = "pet_dark_falcon",
			name = "Dark Goblem",
			gamepassId = 1752726919,
			robux = 250,
		},
		DarkWingedDragon = {
			id = "pet_dark_winged_dragon",
			name = "Music Winged Dragon",
			gamepassId = 1753946705,
			robux = 300,
		},
		PinkButterfly = {
			id = "pet_pink_butterfly",
			name = "Pink Butterfly",
			gamepassId = 1749629635,
			robux = 200,
		},
		GlitchedDragon = {
			id = "pet_glitched_dragon",
			name = "Glitched Dragon",
			gamepassId = 1749601655,
			robux = 250,
		},
		FreddyFazbear = {
			id = "pet_freddy_fazbear",
			name = "AnimatronicBear",
			gamepassId = 1885101001,
			robux = 400,
		},
		Bonnie = {
			id = "pet_bonnie",
			name = "AnimatronicBunny",
			gamepassId = 1885101002,
			robux = 400,
		},
		Chica = {
			id = "pet_chica",
			name = "AnimatronicChicken",
			gamepassId = 1885101003,
			robux = 400,
		},
		Foxy = {
			id = "pet_foxy",
			name = "AnimatronicFox",
			gamepassId = 1885101004,
			robux = 400,
		},
		GoldenFreddy = {
			id = "pet_golden_freddy",
			name = "TheOneYouShouldntHaveKilled",
			gamepassId = 1885101005,
			robux = 400,
		},
		ThePuppet = {
			id = "pet_the_puppet",
			name = "AnimatronicPuppet",
			gamepassId = 1885101006,
			robux = 400,
		},
		Cupcake = {
			id = "pet_cupcake",
			name = "HauntedCupcake",
			gamepassId = 1885101007,
			robux = 400,
		},
	},

	Crowns = {
		FireCircle = {
			id = "crown_fire_circle",
			name = "Fire Circle Crown",
			gamepassId = 1753784703,
			robux = 450,
		},
		NenXKillua = {
			id = "crown_nen_x_killua",
			name = "Nen X Killua Crown",
			gamepassId = 1749687542,
			robux = 400,
		},
		Slashes = {
			id = "crown_slashes",
			name = "Slashes Crown",
			gamepassId = 1753068844,
			robux = 300,
		},
		InfiniteVoid = {
			id = "crown_infinite_void",
			name = "Infinite Void Crown",
			gamepassId = 1752214968,
			robux = 250,
		},
		Rengoku = {
			id = "crown_rengoku",
			name = "Rengoku Crown",
			gamepassId = 1752702925,
			robux = 200,
		},
		Ultra = {
			id = "crown_ultra",
			name = "Ultra Crown",
			gamepassId = 1749613715,
			robux = 300,
		},
	},
}

local function buildIndex(groupedEntries: { [string]: { [string]: any } }, idField: string)
	local byId = {}
	local byNumericId = {}

	for _, categoryEntries in pairs(groupedEntries) do
		if type(categoryEntries) == "table" then
			for _, entry in pairs(categoryEntries) do
				if type(entry) == "table" and type(entry.id) == "string" then
					byId[entry.id] = entry
					local numericId = tonumber(entry[idField])
					if numericId and numericId > 0 then
						byNumericId[numericId] = entry
					end
				end
			end
		end
	end

	return byId, byNumericId
end

local developerProductsById, developerProductsByProductId = buildIndex(MonetizationConfig.DeveloperProducts, "productId")
local gamePassesById, gamePassesByGamepassId = buildIndex(MonetizationConfig.GamePasses, "gamepassId")

MonetizationConfig.Lookup = {
	DeveloperProductsById = developerProductsById,
	DeveloperProductsByProductId = developerProductsByProductId,
	GamePassesById = gamePassesById,
	GamePassesByGamepassId = gamePassesByGamepassId,
}

function MonetizationConfig.GetDeveloperProduct(id: string)
	return developerProductsById[id]
end

function MonetizationConfig.GetDeveloperProductId(id: string): number?
	local entry = developerProductsById[id]
	return entry and tonumber(entry.productId) or nil
end

function MonetizationConfig.GetGamePass(id: string)
	return gamePassesById[id]
end

function MonetizationConfig.GetGamePassId(id: string): number?
	local entry = gamePassesById[id]
	return entry and tonumber(entry.gamepassId) or nil
end

return MonetizationConfig
