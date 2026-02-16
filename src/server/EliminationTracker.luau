--[[
	EliminationTracker
	Records eliminations during a match and builds placement rankings at match end.
	
	Standalone module (no circular deps) — required by HazardManager,
	MapManager, and MatchManager.
	
	API:
		Reset(matchPlayers)                           → Clear data for new match
		RecordElimination(player, round, reason)      → Log an elimination
		BuildRankings(survivors)                       → { PlacementGroup }
		GetEliminations()                              → Raw elimination list
		GetMatchId()                                   → Current match counter
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CoinConfig = require(Shared:WaitForChild("CoinConfig"))

--[[ TYPES ]]
export type EliminationRecord = {
	player: Player?,       -- May be nil if player left after elimination
	playerName: string,
	playerId: number,
	eliminationTime: number,
	roundNumber: number,
	reason: string,        -- "Beam", "OOB", "Disconnect"
}

export type PlayerEntry = {
	player: Player?,
	playerName: string,
	playerId: number,
}

export type PlacementGroup = {
	placement: number,
	players: { PlayerEntry },
	coins: number,
	reason: string,        -- "Survived" or "Eliminated"
}

--[[ INTERNAL STATE ]]
local eliminations: { EliminationRecord } = {}
local matchPlayerIds: { [number]: boolean } = {}  -- userId set for validation
local matchId: number = 0
local awarded: boolean = false

local EliminationTracker = {}

--[[ HELPERS ]]

local function log(...)
	if CoinConfig.DebugLog then
		print("[EliminationTracker]", ...)
	end
end

-- Lazy-load PlayerDataService for death tracking (avoids tight coupling)
local _PlayerDataService = nil
local function getPDS()
	if _PlayerDataService then return _PlayerDataService end
	pcall(function()
		local Server = game:GetService("ServerScriptService"):FindFirstChild("Server")
		if Server then
			local pds = Server:FindFirstChild("PlayerDataService")
			if pds then _PlayerDataService = require(pds) end
		end
	end)
	return _PlayerDataService
end

--[[ PUBLIC API ]]

--[[
	Reset tracker for a new match.
	Call at the start of Playing phase with all InMatch players.
]]
function EliminationTracker.Reset(players: { Player })
	eliminations = {}
	matchPlayerIds = {}
	awarded = false
	matchId = matchId + 1
	
	for _, player in ipairs(players) do
		matchPlayerIds[player.UserId] = true
	end
	
	log(string.format("Reset for match #%d — %d players", matchId, #players))
end

--[[
	Record a player elimination.
	Idempotent: ignores duplicate calls for the same player.
]]
function EliminationTracker.RecordElimination(player: Player, roundNumber: number, reason: string)
	-- Ignore if player wasn't in this match
	if not matchPlayerIds[player.UserId] then
		return
	end
	
	-- Prevent duplicate recording for same player
	for _, record in ipairs(eliminations) do
		if record.playerId == player.UserId then
			return
		end
	end
	
	local record: EliminationRecord = {
		player = player,
		playerName = player.Name,
		playerId = player.UserId,
		eliminationTime = os.clock(),
		roundNumber = roundNumber,
		reason = reason,
	}
	
	table.insert(eliminations, record)
	log(string.format("Recorded: %s eliminated (round %d, %s) — #%d this match",
		player.Name, roundNumber, reason, #eliminations))

	-- Increment lifetime death counter (persistent)
	local PDS = getPDS()
	if PDS and PDS.IsLoaded(player) then
		local deaths = (PDS.GetField(player, "LifetimeDeaths") or 0) + 1
		PDS.SetField(player, "LifetimeDeaths", deaths)
	end

	-- Broadcast to all clients for Kill Feed UI
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if remotes then
		local killFeedEvent = remotes:FindFirstChild("KillFeedEvent")
		if killFeedEvent then
			killFeedEvent:FireAllClients(player.Name, reason)
		end
	end
end

--[[
	Build placement rankings from elimination data + surviving players.
	
	Algorithm:
	  1. Survivors (still InMatch at match end) form the top group
	  2. Eliminated players sorted by eliminationTime descending (latest = better)
	  3. Players within SimultaneousWindow of each other share a placement
	  4. Small match (2–4 players): use SmallMatchPayouts table (last > 0)
	     Normal match (5+ players): standard tiers, last = 0
	  5. If only 1 group total → everyone gets FirstPlace
	
	Returns an ordered list of PlacementGroups from best to worst.
	May only be called ONCE per match (enforced by awarded flag).
]]
function EliminationTracker.BuildRankings(survivors: { Player }): { PlacementGroup }
	if awarded then
		warn("[EliminationTracker] Rankings already built for this match — skipping")
		return {}
	end
	awarded = true
	
	local groups: { PlacementGroup } = {}
	
	-- Survivors form the top group (if any)
	if #survivors > 0 then
		local entries: { PlayerEntry } = {}
		for _, p in ipairs(survivors) do
			table.insert(entries, {
				player = p,
				playerName = p.Name,
				playerId = p.UserId,
			})
		end
		table.insert(groups, {
			placement = 0, -- assigned below
			players = entries,
			coins = 0,
			reason = "Survived",
		})
	end
	
	-- Sort eliminations by time DESCENDING (last eliminated = best)
	local sorted = table.clone(eliminations)
	table.sort(sorted, function(a, b)
		return a.eliminationTime > b.eliminationTime
	end)
	
	-- Group by time proximity
	local currentEntries: { PlayerEntry }? = nil
	local currentTime: number = 0
	
	for _, record in ipairs(sorted) do
		if currentEntries == nil or (currentTime - record.eliminationTime) > CoinConfig.SimultaneousWindow then
			-- Flush previous group
			if currentEntries and #currentEntries > 0 then
				table.insert(groups, {
					placement = 0,
					players = currentEntries,
					coins = 0,
					reason = "Eliminated",
				})
			end
			currentEntries = {}
			currentTime = record.eliminationTime
		end
		
		table.insert(currentEntries, {
			player = record.player,
			playerName = record.playerName,
			playerId = record.playerId,
		})
	end
	
	-- Flush final group
	if currentEntries and #currentEntries > 0 then
		table.insert(groups, {
			placement = 0,
			players = currentEntries,
			coins = 0,
			reason = "Eliminated",
		})
	end
	
	-- Determine total match player count (for small-match payout rule)
	local totalMatchPlayers = 0
	for _ in pairs(matchPlayerIds) do totalMatchPlayers += 1 end
	local isSmallMatch = totalMatchPlayers <= CoinConfig.SmallMatchMaxPlayers

	-- Resolve small-match payout table (if applicable)
	local smallPayouts = nil
	if isSmallMatch and CoinConfig.SmallMatchPayouts then
		smallPayouts = CoinConfig.SmallMatchPayouts[totalMatchPlayers]
	end

	-- Assign placements and coin rewards
	local totalGroups = #groups
	
	for i, group in ipairs(groups) do
		group.placement = i
		
		if totalGroups == 1 then
			-- Everyone shares 1st (solo player, everyone died at once, etc.)
			group.coins = CoinConfig.FirstPlace
		elseif smallPayouts then
			-- Small match (2–4 players): use scaled payout table
			-- Index by placement; fallback to Participation if more groups than entries
			group.coins = smallPayouts[i] or CoinConfig.Participation
		else
			-- Normal match (5+ players): standard tiers, last = 0
			if i == totalGroups then
				group.coins = CoinConfig.LastPlace
			elseif i == 1 then
				group.coins = CoinConfig.FirstPlace
			elseif i == 2 then
				group.coins = CoinConfig.SecondPlace
			elseif i == 3 then
				group.coins = CoinConfig.ThirdPlace
			else
				group.coins = CoinConfig.Participation
			end
		end
	end
	
	-- Log summary
	local parts = {}
	for _, group in ipairs(groups) do
		local names = {}
		for _, p in ipairs(group.players) do
			table.insert(names, p.playerName)
		end
		table.insert(parts, string.format(
			"#%d(%d coins): %s",
			group.placement, group.coins, table.concat(names, ",")
		))
	end
	
	if totalGroups > 0 then
		log(string.format("[MatchEnd] playerCount=%d isSmallMatch=%s payoutTable=%s Rankings — %s",
			totalMatchPlayers, tostring(isSmallMatch),
			smallPayouts and "SmallMatchPayouts["..totalMatchPlayers.."]" or "Standard",
			table.concat(parts, " | ")))
	else
		log("[MatchEnd] No players to rank")
	end
	
	-- Log last place explicitly
	if totalGroups > 1 then
		local lastGroup = groups[totalGroups]
		local lastNames = {}
		for _, p in ipairs(lastGroup.players) do
			table.insert(lastNames, p.playerName)
		end
		log(string.format("[MatchEnd] Last place (%d coins, smallMatch=%s): %s",
			lastGroup.coins, tostring(isSmallMatch), table.concat(lastNames, ",")))
	end
	
	return groups
end

--[[
	Get raw elimination records (for debugging).
]]
function EliminationTracker.GetEliminations(): { EliminationRecord }
	return eliminations
end

--[[
	Get current match counter.
]]
function EliminationTracker.GetMatchId(): number
	return matchId
end

return EliminationTracker
