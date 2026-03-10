--[[
	DailyQuestConfig
	Template pool for the automated daily quest generator.

	PERMANENT quests always appear (reward specific items like crowns / pets).
	ROTATING quests (RotatingCount per day) are picked from the Templates pool
	using the UTC date as a deterministic seed -- same quests for all players on
	the same day, automatically different every day.

	Quest types (used as progress counter keys):
	  TimePlayed          -- seconds of session time (read from TimePlayedSeconds)
	  WinsToday           -- match wins today
	  SwordKillsToday     -- sword kills today
	  EliminationsToday   -- any player kill today (same source as SwordKillsToday)
	  SurviveRoundsToday  -- rounds survived today
	  TTSSurvivalsToday   -- TungTungSahur 30s-timer survival events today
	  BrainrotIShowSpeedPickupsToday -- pick up IShowSpeed in Save the Brainrot mode

	Reward types:
	  { type="Coins",  amount=N }
	  { type="Crown",  itemId="..." }
	  { type="Pet",    itemId="..." }
	  { type="IconImage", itemId="..." }
	  { type="Crate",  crateId="crate_pet"|"crate_crown", count=1 }
	  { type="Spin",   count=1 }
]]

local DailyQuestConfig = {}

-- Permanent quests (always shown, specific item rewards)
DailyQuestConfig.Permanent = {
	{
		id          = "quest_play_15min",
		label       = "Time Traveler",
		description = "Get 700 Fate Coins for playing for 15 minutes straight!",
		oneTime     = true,
		type        = "TimePlayed",
		target      = 900,
		order       = 1,
		reward      = { type = "Coins", amount = 700 },
		icon        = "",
		iconColor   = { 255, 220, 60 },
	},
	{
		id          = "quest_win_3games",
		label       = "3x Champion",
		description = "Get the Disco Party Crown for winning 3 straight games!",
		oneTime     = true,
		type        = "WinsToday",
		target      = 3,
		order       = 2,
		reward      = { type = "Crown", itemId = "crown_disco_party" },
		icon        = "",
		iconColor   = { 255, 200, 50 },
	},
	{
		id          = "quest_sword_kills",
		label       = "Sword Master",
		description = "Get the Chill Face Pet for killing 4 players with a sword!",
		oneTime     = true,
		type        = "SwordKillsToday",
		target      = 4,
		order       = 3,
		reward      = { type = "Pet", itemId = "pet_chill_face" },
		icon        = "",
		iconColor   = { 220, 80, 80 },
	},
	{
		id          = "quest_survive_tts",
		label       = "TungTung Survivor",
		description = "Get the TungTungSahur pet for surviving TungTung 7 times!",
		oneTime     = true,
		type        = "TTSSurvivalsToday",
		target      = 7,
		order       = 4,
		reward      = { type = "Pet", itemId = "pet_tungtungsahur" },
		icon        = "",
		iconColor   = { 255, 60, 60 },
	},
	{
		id          = "quest_brainrot_pickup_ishowspeed",
		label       = "ImWatchingYourStream",
		description = "Pick up IShowSpeed 5 times in Save the Brainrot mode to unlock ImWatchingYourStream!",
		oneTime     = true,
		type        = "BrainrotIShowSpeedPickupsToday",
		target      = 5,
		order       = 5,
		reward      = { type = "IconImage", itemId = "icon_imwatchingyourstream" },
		icon        = "",
		iconColor   = { 255, 58, 58 },
	},
	{
		id          = "quest_survive_12_single_match",
		label       = "The Battle Of The Strongest",
		description = "Survive 12 full rounds in a single match to unlock TheStrongest!",
		oneTime     = true,
		repeatable  = false,
		type        = "SurviveRoundsSingleMatch12",
		target      = 12,
		order       = 6,
		reward      = { type = "IconImage", itemId = "icon_thestrongest" },
		icon        = "",
		iconColor   = { 255, 48, 48 },
	},
	{
		id          = "quest_survive_15_single_match",
		label       = "Round 15 Champion",
		description = "Survive 15 full rounds in a single match to unlock THESTRONGEST!",
		oneTime     = true,
		repeatable  = false,
		type        = "SurviveRoundsSingleMatch15",
		target      = 15,
		order       = 7,
		reward      = { type = "Crown", itemId = "crown_thestrongest" },
		icon        = "",
		iconColor   = { 255, 48, 48 },
	},
}

-- Rotating template pool -- 3 are picked each day.
-- Rotating quest types are unique among rotating entries, but may overlap
-- with Permanent quests so daily sets still feel fresh.
DailyQuestConfig.Templates = {
	{
		type = "TimePlayed",
		icon = "", iconColor = { 255, 220, 60 },
		tiers = {
			{ target = 300,  label = "Early Bird",   desc = "Play for 5 minutes",   reward = { type = "Coins", amount = 200 } },
			{ target = 600,  label = "Regular",      desc = "Play for 10 minutes",  reward = { type = "Coins", amount = 350 } },
			{ target = 1200, label = "Dedicated",    desc = "Play for 20 minutes",  reward = { type = "Crate", crateId = "crate_pet", count = 1 } },
		},
	},
	{
		type = "WinsToday",
		icon = "", iconColor = { 255, 200, 50 },
		tiers = {
			{ target = 1, label = "First Win",   desc = "Win 1 match",   reward = { type = "Coins", amount = 300 } },
			{ target = 5, label = "Win Streak",  desc = "Win 5 matches", reward = { type = "Crate", crateId = "crate_crown", count = 1 } },
		},
	},
	{
		type = "EliminationsToday",
		icon = "", iconColor = { 255, 120, 40 },
		tiers = {
			{ target = 2, label = "Lethal",     desc = "Eliminate 2 players",  reward = { type = "Coins", amount = 250 } },
			{ target = 5, label = "Slayer",     desc = "Eliminate 5 players",  reward = { type = "Spin",  count = 1 } },
			{ target = 8, label = "Destroyer",  desc = "Eliminate 8 players",  reward = { type = "Crate", crateId = "crate_pet", count = 1 } },
		},
	},
	{
		type = "SurviveRoundsToday",
		icon = "", iconColor = { 80, 200, 255 },
		tiers = {
			{ target = 3, label = "Survivor",    desc = "Survive 3 rounds", reward = { type = "Coins", amount = 250 } },
			{ target = 5, label = "Endurance",   desc = "Survive 5 rounds", reward = { type = "Spin",  count = 1 } },
			{ target = 8, label = "Unstoppable", desc = "Survive 8 rounds", reward = { type = "Crate", crateId = "crate_crown", count = 1 } },
		},
	},
	{
		type = "SwordKillsToday",
		icon = "", iconColor = { 220, 80, 80 },
		tiers = {
			{ target = 1, label = "First Blood",   desc = "Get 1 sword kill",  reward = { type = "Coins", amount = 200 } },
			{ target = 3, label = "Blade Dancer",  desc = "Get 3 sword kills", reward = { type = "Crate", crateId = "crate_pet", count = 1 } },
		},
	},
	{
		type = "TTSSurvivalsToday",
		icon = "", iconColor = { 255, 60, 60 },
		tiers = {
			{ target = 2, label = "TTS Dodger", desc = "Survive TungTungSahur 2 times", reward = { type = "Coins", amount = 300 } },
			{ target = 5, label = "TTS Hunter", desc = "Survive TungTungSahur 5 times", reward = { type = "Spin",  count = 1 } },
		},
	},
}

-- How many rotating quests to add per day (on top of Permanent)
DailyQuestConfig.RotatingCount = 3

-- Returns a human-readable reward label for descriptions and popups
function DailyQuestConfig.GetRewardLabel(reward): string
	if not reward then return "a reward" end
	if reward.type == "Coins" then
		return tostring(reward.amount) .. " Fate Coins"
	elseif reward.type == "Crate" then
		return "1 " .. (reward.crateId == "crate_crown" and "Crown Crate" or "Pet Crate")
	elseif reward.type == "Spin" then
		local n = reward.count or 1
		return tostring(n) .. " Free Spin" .. (n == 1 and "" or "s")
	elseif reward.type == "Crown" then
		return "a Crown"
	elseif reward.type == "Pet" then
		return "a Pet"
	elseif reward.type == "IconImage" then
		return "an Icon Image"
	end
	return "a reward"
end

-- Seeded daily generator.
-- dayString: UTC date "2026_02_25"
-- Returns ordered array: Permanent quests first, then RotatingCount rotating quests.
-- Deterministic: same day -> same quests for all players on all servers.
function DailyQuestConfig.GenerateDailyQuests(dayString: string): { { [string]: any } }
	local seed = 0
	for c in string.gmatch(dayString, ".") do
		seed = (seed * 31 + string.byte(c)) % 2147483647
	end
	local rng = Random.new(seed)

	-- Shuffle a copy of Templates (Knuth shuffle)
	local pool: { any } = {}
	for _, tmpl in ipairs(DailyQuestConfig.Templates) do
		table.insert(pool, tmpl)
	end
	for i = #pool, 2, -1 do
		local j = rng:NextInteger(1, i)
		pool[i], pool[j] = pool[j], pool[i]
	end

	-- Track rotating types already selected (do not duplicate within rotating set)
	local usedTypes: { [string]: boolean } = {}

	-- Pick rotating quests (avoid duplicate rotating types)
	local rotating: { { [string]: any } } = {}
	for _, tmpl in ipairs(pool) do
		if #rotating >= DailyQuestConfig.RotatingCount then break end
		if not usedTypes[tmpl.type] then
			usedTypes[tmpl.type] = true
			local tierIdx = rng:NextInteger(1, #tmpl.tiers)
			local tier = tmpl.tiers[tierIdx]
			local rewardLabel = DailyQuestConfig.GetRewardLabel(tier.reward)
			local desc = (tier.desc or "") .. ". Reward: " .. rewardLabel .. "!"
			local dateDigits = dayString:gsub("[^%d]", "")
			local typeSlug   = tmpl.type:lower():gsub("[^%a%d]", "")
			table.insert(rotating, {
				id          = "daily_" .. typeSlug .. "_" .. dateDigits,
				label       = tier.label,
				description = desc,
				type        = tmpl.type,
				target      = tier.target,
				order       = #DailyQuestConfig.Permanent + #rotating + 1,
				reward      = tier.reward,
				icon        = tmpl.icon,
				iconColor   = tmpl.iconColor,
			})
		end
	end

	-- Assemble: permanent first (copy so callers can mutate safely), then rotating
	local all: { { [string]: any } } = {}
	for i, q in ipairs(DailyQuestConfig.Permanent) do
		local copy: { [string]: any } = {}
		for k, v in pairs(q) do copy[k] = v end
		copy.order = i
		table.insert(all, copy)
	end
	for _, q in ipairs(rotating) do
		table.insert(all, q)
	end

	return all
end

return DailyQuestConfig
