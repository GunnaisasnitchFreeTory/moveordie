--[[
	StatService
	Server-authoritative stat calculation.

	Computes final player stats from:
	  • Base stats (Roblox defaults)
	  • Equipped pet modifiers  (additive speed/jump, multiplicative coins)
	  • Equipped crown modifiers (same)

	Stats are recalculated ONLY on equip / unequip — never per-frame.
	Server owns final stat values.

	API:
		Init()
		RecalculateStats(player)
		GetCoinMultiplier(player)  → number
		SetWalkSpeedOverride(player, key, value)
		ClearWalkSpeedOverride(player, key)
		OnPlayerRemoving(player)
]]

local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Server = ServerScriptService:WaitForChild("Server")

local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))

local ItemCatalogModule = Shared:WaitForChild("ItemCatalog", 10)
local ItemCatalog
if ItemCatalogModule then
	local ok, mod = pcall(require, ItemCatalogModule)
	if ok then ItemCatalog = mod else warn("[StatService] ItemCatalog failed:", mod) end
end
if not ItemCatalog then
	warn("[StatService] ItemCatalog not found — stats will use base values only")
	ItemCatalog = { Get = function() return nil end }
end

local StatService = {}
local initialized = false

local DEBUG_LOG = true
local function log(...)
	if DEBUG_LOG then print("[StatService]", ...) end
end

local BASE_STATS = {
	WalkSpeed      = 20,
	JumpPower      = 50,
	CoinMultiplier = 1.0,
}

local coinMultiplierCache: { [number]: number } = {}
local walkSpeedOverridesByUserId: { [number]: { [string]: number } } = {}

local function getItemStats(catalogCategory: string, itemId: string?): { [string]: number }?
	if not itemId or itemId == "" then return nil end
	local entry = ItemCatalog.Get(catalogCategory, itemId)
	if entry and type(entry.stats) == "table" then
		return entry.stats
	end
	return nil
end

local function getEffectiveWalkSpeed(baseWalkSpeed: number, userId: number): number
	local overrides = walkSpeedOverridesByUserId[userId]
	if not overrides then
		return baseWalkSpeed
	end
	local best = baseWalkSpeed
	local hasAny = false
	for _, value in pairs(overrides) do
		if type(value) == "number" then
			if not hasAny then
				best = value
				hasAny = true
			else
				best = math.min(best, value)
			end
		end
	end
	return hasAny and best or baseWalkSpeed
end

local function isMovementTemporarilyLocked(player: Player, humanoid: Humanoid): boolean
	local state = player:GetAttribute("PlayerState")
	if state ~= "InMatch" then
		return false
	end
	-- RoundManager freeze sets both to 0; avoid fighting that lock.
	return humanoid.WalkSpeed == 0 and humanoid.JumpPower == 0
end

function StatService.Init()
	if initialized then return end
	initialized = true
	log("Initialized")
end

function StatService.RecalculateStats(player: Player)
	local data = PlayerDataService.GetData(player)
	if not data then return end

	local walkSpeed = BASE_STATS.WalkSpeed
	local jumpPower = BASE_STATS.JumpPower
	local coinMult  = BASE_STATS.CoinMultiplier

	local petStats = getItemStats("Pets", data.EquippedPet)
	if petStats then
		walkSpeed += (petStats.WalkSpeed or 0)
		jumpPower += (petStats.JumpPower or 0)
		coinMult  *= (petStats.CoinMultiplier or 1)
	end

	local crownStats = getItemStats("Crowns", data.EquippedCrown)
	if crownStats then
		walkSpeed += (crownStats.WalkSpeed or 0)
		jumpPower += (crownStats.JumpPower or 0)
		coinMult  *= (crownStats.CoinMultiplier or 1)
	end
	walkSpeed = getEffectiveWalkSpeed(walkSpeed, player.UserId)

	coinMultiplierCache[player.UserId] = coinMult
	player:SetAttribute("CoinMultiplier", coinMult)

	local character = player.Character
	if character then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			if isMovementTemporarilyLocked(player, humanoid) then
				log(string.format("%s stats deferred (movement lock active)", player.Name))
			else
				humanoid.WalkSpeed = walkSpeed
				humanoid.JumpPower = jumpPower
			end
		end
	end

	log(string.format("%s stats: WalkSpeed=%.1f JumpPower=%.1f CoinMult=%.2fx",
		player.Name, walkSpeed, jumpPower, coinMult))
end

function StatService.SetWalkSpeedOverride(player: Player, key: string, value: number)
	if type(key) ~= "string" or key == "" or type(value) ~= "number" then
		return
	end
	local userId = player.UserId
	local overrides = walkSpeedOverridesByUserId[userId]
	if not overrides then
		overrides = {}
		walkSpeedOverridesByUserId[userId] = overrides
	end
	overrides[key] = value
	log(string.format("%s WalkSpeed override set key=%s value=%.1f", player.Name, key, value))
	StatService.RecalculateStats(player)
end

function StatService.ClearWalkSpeedOverride(player: Player, key: string)
	if type(key) ~= "string" or key == "" then
		return
	end
	local userId = player.UserId
	local overrides = walkSpeedOverridesByUserId[userId]
	if not overrides then
		return
	end
	overrides[key] = nil
	if next(overrides) == nil then
		walkSpeedOverridesByUserId[userId] = nil
	end
	log(string.format("%s WalkSpeed override cleared key=%s", player.Name, key))
	StatService.RecalculateStats(player)
end

function StatService.GetCoinMultiplier(player: Player): number
	return coinMultiplierCache[player.UserId] or BASE_STATS.CoinMultiplier
end

function StatService.OnPlayerRemoving(player: Player)
	coinMultiplierCache[player.UserId] = nil
	walkSpeedOverridesByUserId[player.UserId] = nil
end

return StatService
