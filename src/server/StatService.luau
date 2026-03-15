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
		SetTemporaryMovementBonus(player, key, bonus)
		ClearTemporaryMovementBonus(player, key)
		OnPlayerRemoving(player)
]]

local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local MarketplaceService  = game:GetService("MarketplaceService")
local Players             = game:GetService("Players")

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

local BundleCatalogModule = Shared:WaitForChild("BundleCatalog", 10)
local BundleCatalog
if BundleCatalogModule then
	local ok, mod = pcall(require, BundleCatalogModule)
	if ok then BundleCatalog = mod else warn("[StatService] BundleCatalog failed:", mod) end
end
if not BundleCatalog then
	warn("[StatService] BundleCatalog not found — VIP checks will fail")
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
local VIP_COIN_MULTIPLIER = 1.5

local coinMultiplierCache: { [number]: number } = {}
local walkSpeedOverridesByUserId: { [number]: { [string]: number } } = {}
local temporaryMovementBonusesByUserId: { [number]: { [string]: { WalkSpeed: number?, JumpPower: number? } } } = {}
local vipOwnershipChecksInFlight: { [number]: boolean } = {}

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

local function getTemporaryMovementBonusTotals(userId: number): (number, number)
	local bonuses = temporaryMovementBonusesByUserId[userId]
	if not bonuses then
		return 0, 0
	end

	local walkSpeedBonus = 0
	local jumpPowerBonus = 0
	for _, bonus in pairs(bonuses) do
		if type(bonus) == "table" then
			walkSpeedBonus += tonumber(bonus.WalkSpeed) or 0
			jumpPowerBonus += tonumber(bonus.JumpPower) or 0
		end
	end

	return walkSpeedBonus, jumpPowerBonus
end

local function isMovementTemporarilyLocked(player: Player, humanoid: Humanoid): boolean
	local state = player:GetAttribute("PlayerState")
	if state ~= "InMatch" then
		return false
	end
	-- RoundManager freeze sets both to 0; avoid fighting that lock.
	return humanoid.WalkSpeed == 0 and humanoid.JumpPower == 0
end

local function getVipBundleGamepassId(): number?
	if not BundleCatalog then
		return nil
	end

	local vipBundle = nil
	if type(BundleCatalog.Get) == "function" then
		vipBundle = BundleCatalog.Get("bundle_vip")
	end
	if type(vipBundle) ~= "table" then
		vipBundle = BundleCatalog.bundle_vip
	end
	if type(vipBundle) ~= "table" then
		return nil
	end

	return tonumber(vipBundle.gamepassId)
end

local function checkVipOwnership(player: Player)
	StatService.RefreshVipOwnership(player, "PlayerAdded")
end

local function getPersistedVipBundleOwned(player: Player, data: { [string]: any }?): boolean
	if player:GetAttribute("VIPBundleOwned") == true then
		return true
	end

	local resolvedData = data or PlayerDataService.GetData(player)
	return resolvedData ~= nil and resolvedData.VIPBundleOwned == true
end

local function getEffectiveVipOwned(player: Player, data: { [string]: any }?): boolean
	return (player:GetAttribute("OwnsVIP") == true) or getPersistedVipBundleOwned(player, data)
end

function StatService.HasVipEntitlement(player: Player, data: { [string]: any }?): boolean
	if not player then
		return false
	end

	return getEffectiveVipOwned(player, data)
end

function StatService.SetVipOwnership(player: Player, ownsVip: boolean, source: string?)
	if not player or not player.Parent then
		return
	end

	local normalizedOwnsVip = ownsVip == true
	local data = PlayerDataService.GetData(player)
	local persistedBefore = getPersistedVipBundleOwned(player, data)

	if normalizedOwnsVip then
		player:SetAttribute("VIPBundleOwned", true)
		if PlayerDataService.IsLoaded(player) and data and data.VIPBundleOwned ~= true then
			PlayerDataService.SetField(player, "VIPBundleOwned", true)
		end
	end

	local effectiveVipOwned = normalizedOwnsVip or getPersistedVipBundleOwned(player, data)
	player:SetAttribute("OwnsVIP", effectiveVipOwned)
	log(string.format(
		"VIP entitlement sync player=%s source=%s marketVip=%s persistedBefore=%s persistedAfter=%s effectiveVip=%s dataLoaded=%s",
		player.Name,
		tostring(source or "unknown"),
		tostring(normalizedOwnsVip),
		tostring(persistedBefore),
		tostring(getPersistedVipBundleOwned(player, data)),
		tostring(effectiveVipOwned),
		tostring(PlayerDataService.IsLoaded(player))
	))

	if PlayerDataService.IsLoaded(player) then
		StatService.RecalculateStats(player)
	end
end

function StatService.RefreshVipOwnership(player: Player, source: string?): boolean
	local gamepassId = getVipBundleGamepassId()
	if not player or not player.Parent or not gamepassId or gamepassId <= 0 then
		return false
	end

	if vipOwnershipChecksInFlight[player.UserId] then
		return false
	end

	vipOwnershipChecksInFlight[player.UserId] = true
	task.spawn(function()
		local success, hasPass = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, gamepassId)
		end)
		vipOwnershipChecksInFlight[player.UserId] = nil

		if not player or not player.Parent then
			return
		end

		if success then
			StatService.SetVipOwnership(player, hasPass == true, source or "RefreshVipOwnership")
			log(string.format("VIP verification player=%s source=%s vip=%s",
				player.Name, tostring(source or "RefreshVipOwnership"), tostring(hasPass == true)))
		else
			warn(string.format("[StatService] VIP check failed for %s: %s", player.Name, tostring(hasPass)))
		end
	end)

	return true
end

function StatService.Init()
	if initialized then return end
	initialized = true

	Players.PlayerAdded:Connect(function(player)
		checkVipOwnership(player)
	end)

	for _, player in ipairs(Players:GetPlayers()) do
		checkVipOwnership(player)
	end

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

	local vipPersisted = getPersistedVipBundleOwned(player, data)
	local vipOwned = getEffectiveVipOwned(player, data)
	if vipOwned and data.VIPBundleOwned ~= true then
		PlayerDataService.SetField(player, "VIPBundleOwned", true)
		vipPersisted = true
	end
	player:SetAttribute("VIPBundleOwned", vipPersisted)
	player:SetAttribute("OwnsVIP", vipOwned)
	if vipOwned then
		coinMult = coinMult * VIP_COIN_MULTIPLIER
	end

	walkSpeed = getEffectiveWalkSpeed(walkSpeed, player.UserId)
	local walkSpeedBonus, jumpPowerBonus = getTemporaryMovementBonusTotals(player.UserId)
	walkSpeed += walkSpeedBonus
	jumpPower += jumpPowerBonus

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

	log(string.format("%s stats: WalkSpeed=%.1f JumpPower=%.1f CoinMult=%.2fx (VIP=%s persistedVIP=%s)",
		player.Name, walkSpeed, jumpPower, coinMult, tostring(vipOwned), tostring(vipPersisted)))
	if vipPersisted or vipOwned then
		warn(string.format("[VIPPersistence] player=%s vipBundleOwned=%s loaded=%s multiplier=%.2f",
			player.Name, tostring(vipPersisted), tostring(PlayerDataService.IsLoaded(player)), coinMult))
	end
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

function StatService.SetTemporaryMovementBonus(player: Player, key: string, bonus: { WalkSpeed: number?, JumpPower: number? })
	if type(key) ~= "string" or key == "" or type(bonus) ~= "table" then
		return
	end

	local walkSpeed = tonumber(bonus.WalkSpeed)
	local jumpPower = tonumber(bonus.JumpPower)
	if walkSpeed == nil and jumpPower == nil then
		return
	end

	local userId = player.UserId
	local bonuses = temporaryMovementBonusesByUserId[userId]
	if not bonuses then
		bonuses = {}
		temporaryMovementBonusesByUserId[userId] = bonuses
	end

	bonuses[key] = {
		WalkSpeed = walkSpeed,
		JumpPower = jumpPower,
	}

	log(string.format(
		"%s temporary movement bonus set key=%s walk=%.1f jump=%.1f",
		player.Name,
		key,
		walkSpeed or 0,
		jumpPower or 0
	))
	StatService.RecalculateStats(player)
end

function StatService.ClearTemporaryMovementBonus(player: Player, key: string)
	if type(key) ~= "string" or key == "" then
		return
	end

	local userId = player.UserId
	local bonuses = temporaryMovementBonusesByUserId[userId]
	if not bonuses then
		return
	end

	bonuses[key] = nil
	if next(bonuses) == nil then
		temporaryMovementBonusesByUserId[userId] = nil
	end

	log(string.format("%s temporary movement bonus cleared key=%s", player.Name, key))
	StatService.RecalculateStats(player)
end

function StatService.GetCoinMultiplier(player: Player): number
	return coinMultiplierCache[player.UserId]
		or tonumber(player:GetAttribute("CoinMultiplier"))
		or BASE_STATS.CoinMultiplier
end

function StatService.OnPlayerRemoving(player: Player)
	coinMultiplierCache[player.UserId] = nil
	walkSpeedOverridesByUserId[player.UserId] = nil
	temporaryMovementBonusesByUserId[player.UserId] = nil
	vipOwnershipChecksInFlight[player.UserId] = nil
end

return StatService
