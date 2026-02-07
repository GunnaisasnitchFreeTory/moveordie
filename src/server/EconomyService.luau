--[[
	EconomyService
	Server-authoritative coin management.
	
	Coins are stored as player attributes (replicated to client).
	Will be upgraded to DataStore persistence in Step 10.
	
	API:
		Init()                                → Initialize the service
		GetCoins(player)                      → number
		AwardCoins(player, amount, reason)    → boolean
		SetCoins(player, amount)              → boolean
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CoinConfig = require(Shared:WaitForChild("CoinConfig"))

local ATTRIBUTE_NAME = "Coins"

local EconomyService = {}
local initialized = false

local function log(...)
	if CoinConfig.DebugLog then
		print("[EconomyService]", ...)
	end
end

--[[
	Initialize coins attribute for a player (if not already set).
]]
local function registerPlayer(player: Player)
	if player:GetAttribute(ATTRIBUTE_NAME) == nil then
		player:SetAttribute(ATTRIBUTE_NAME, 0)
	end
end

--[[ PUBLIC API ]]

function EconomyService.Init()
	if initialized then
		warn("[EconomyService] Already initialized")
		return
	end
	initialized = true
	
	-- Register existing players
	for _, player in ipairs(Players:GetPlayers()) do
		registerPlayer(player)
	end
	
	-- Register new players automatically
	Players.PlayerAdded:Connect(function(player)
		registerPlayer(player)
	end)
	
	log("Initialized")
end

--[[
	Get a player's current coin balance.
]]
function EconomyService.GetCoins(player: Player): number
	return player:GetAttribute(ATTRIBUTE_NAME) or 0
end

--[[
	Award coins to a player. No-op if amount <= 0.
	Returns true on success.
]]
function EconomyService.AwardCoins(player: Player, amount: number, reason: string?): boolean
	if amount <= 0 then
		return true -- No-op
	end
	
	-- Safety: ensure player is still in game
	if not player.Parent then
		log(string.format("Skipped award for %s (left game) — %d coins (%s)",
			player.Name, amount, reason or "unknown"))
		return false
	end
	
	local current = EconomyService.GetCoins(player)
	local newTotal = current + amount
	
	player:SetAttribute(ATTRIBUTE_NAME, newTotal)
	
	log(string.format("%s +%d coins (%s) → %d total",
		player.Name, amount, reason or "unknown", newTotal))
	
	return true
end

--[[
	Set a player's coin balance directly.
	Use sparingly (prefer AwardCoins for normal flow).
]]
function EconomyService.SetCoins(player: Player, amount: number): boolean
	if amount < 0 then
		warn("[EconomyService] Cannot set negative coins")
		return false
	end
	
	player:SetAttribute(ATTRIBUTE_NAME, amount)
	return true
end

return EconomyService

