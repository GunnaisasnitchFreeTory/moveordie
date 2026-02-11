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
	WalkSpeed      = 16,
	JumpPower      = 50,
	CoinMultiplier = 1.0,
}

local coinMultiplierCache: { [number]: number } = {}

local function getItemStats(catalogCategory: string, itemId: string?): { [string]: number }?
	if not itemId or itemId == "" then return nil end
	local entry = ItemCatalog.Get(catalogCategory, itemId)
	if entry and type(entry.stats) == "table" then
		return entry.stats
	end
	return nil
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

	coinMultiplierCache[player.UserId] = coinMult
	player:SetAttribute("CoinMultiplier", coinMult)

	local character = player.Character
	if character then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.WalkSpeed = walkSpeed
			humanoid.JumpPower = jumpPower
		end
	end

	log(string.format("%s stats: WalkSpeed=%.1f JumpPower=%.1f CoinMult=%.2fx",
		player.Name, walkSpeed, jumpPower, coinMult))
end

function StatService.GetCoinMultiplier(player: Player): number
	return coinMultiplierCache[player.UserId] or BASE_STATS.CoinMultiplier
end

function StatService.OnPlayerRemoving(player: Player)
	coinMultiplierCache[player.UserId] = nil
end

return StatService
