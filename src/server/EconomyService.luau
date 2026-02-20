--[[
	EconomyService
	Server-authoritative coin management.

	Coins are persisted via PlayerDataService (DataStore).
	Falls back to player attributes if PlayerDataService is unavailable.

	CoinMultiplier from StatService is automatically applied to AwardCoins
	UNLESS skipMultiplier is true (used by fixed-reward systems like DailyReward, SpinWheel).

	Tracks LifetimeCoinsAchieved and WeeklyCoinsAchieved for leaderboards.

	Leaderboard updates are sent via DIRECT MODULE CALL to
	GlobalLeaderboardService.ReportStatById() — no BindableEvent.

	API:
		Init()
		GetCoins(player)                                  → number
		AwardCoins(player, amount, reason, skipMultiplier) → (boolean, finalAmount)
		DeductCoins(player, amount, reason)                → boolean
		SetCoins(player, amount)                           → boolean
		ResetMatchCoins()
		TrackMatchCoins(player, amount)
		GetMatchCoins(player)                              → number
]]

local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService          = game:GetService("RunService")

local IS_STUDIO = RunService:IsStudio()

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CoinConfig = require(Shared:WaitForChild("CoinConfig"))

local ATTRIBUTE_NAME = "Coins"

local EconomyService = {}
local initialized = false
local matchCoinsEarned: { [number]: number } = {}

local _PlayerDataService = nil
local _StatService = nil
local _GLBS = nil

local ACHIEVED_DEBUG = true

local function log(...)
	if CoinConfig.DebugLog then
		print("[EconomyService]", ...)
	end
end

local function achievedLog(...)
	if ACHIEVED_DEBUG then
		warn("[EconomyService:Achieved]", ...)
	end
end

local function getPDS()
	if _PlayerDataService ~= nil then return _PlayerDataService end
	local ok, mod = pcall(function()
		local Server = ServerScriptService:WaitForChild("Server", 5)
		if Server then
			return require(Server:WaitForChild("PlayerDataService", 5))
		end
		return nil
	end)
	if ok and mod then
		_PlayerDataService = mod
	else
		_PlayerDataService = false
	end
	return _PlayerDataService
end

local function getStatService()
	if _StatService ~= nil then return _StatService end
	local ok, mod = pcall(function()
		local Server = ServerScriptService:WaitForChild("Server", 5)
		if Server then
			return require(Server:WaitForChild("StatService", 5))
		end
		return nil
	end)
	if ok and mod then
		_StatService = mod
	else
		_StatService = false
	end
	return _StatService
end

local function getGLBS()
	if _GLBS ~= nil then return _GLBS end
	local ok, mod = pcall(function()
		return require(script.Parent:WaitForChild("GlobalLeaderboardService", 10))
	end)
	if ok and mod then
		_GLBS = mod
		warn("[EconomyService] GLBS loaded via direct require — ReportStatById available")
	else
		_GLBS = false
		warn("[EconomyService] GLBS not available:", tostring(mod))
	end
	return _GLBS
end

local function reportStats(userId: number, username: string, updates: { [string]: number })
	local GLBS = getGLBS()
	if not GLBS or GLBS == false then
		achievedLog("reportStats SKIPPED — GLBS not available")
		return
	end

	for statKey, value in pairs(updates) do
		local callOk, callErr = pcall(function()
			GLBS.ReportStatById(userId, statKey, value)
		end)
		if callOk then
			achievedLog(string.format("DIRECT CALL OK: ReportStatById(%d, '%s', %d)", userId, statKey, value))
		else
			warn(string.format("[EconomyService] DIRECT CALL FAILED: ReportStatById(%d, '%s', %d) err=%s",
				userId, statKey, value, tostring(callErr)))
		end
	end
end

local function registerPlayer(player: Player)
	if player:GetAttribute(ATTRIBUTE_NAME) == nil then
		player:SetAttribute(ATTRIBUTE_NAME, 0)
	end
end

function EconomyService.Init()
	if initialized then
		warn("[EconomyService] Already initialized")
		return
	end
	initialized = true

	task.spawn(function()
		getGLBS()
	end)

	task.spawn(function()
		local PDS = getPDS()
		local mode = (PDS and PDS ~= false) and "DATASTORE_MODE" or "ATTRIBUTE_FALLBACK"
		warn(string.format("[EconomyService] Data authority: IS_STUDIO=%s, mode=%s", tostring(IS_STUDIO), mode))
	end)

	for _, player in ipairs(Players:GetPlayers()) do
		registerPlayer(player)
	end

	Players.PlayerAdded:Connect(function(player)
		registerPlayer(player)
	end)

	warn(string.format("[EconomyService] Initialized — IS_STUDIO=%s, leaderboard updates via direct GLBS calls",
		tostring(IS_STUDIO)))
end

function EconomyService.GetCoins(player: Player): number
	local PDS = getPDS()
	if PDS then
		local data = PDS.GetData(player)
		if data then
			return data.Coins or 0
		end
	end
	return player:GetAttribute(ATTRIBUTE_NAME) or 0
end

function EconomyService.GetMultipliedAmount(player: Player, baseAmount: number): number
	local SS = getStatService()
	local multiplier = 1
	if SS and type(SS.GetCoinMultiplier) == "function" then
		multiplier = SS.GetCoinMultiplier(player)
	else
		multiplier = player:GetAttribute("CoinMultiplier") or 1
	end
	return math.floor(baseAmount * multiplier)
end

function EconomyService.AwardCoins(player: Player, amount: number, reason: string?, skipMultiplier: boolean?): (boolean, number)
	if amount <= 0 then return true, 0 end

	if not player.Parent then
		log(string.format("Skipped award for %s (left game) — %d coins (%s)",
			player.Name, amount, reason or "unknown"))
		return false, 0
	end

	local multiplier = 1
	if not skipMultiplier then
		local SS = getStatService()
		if SS and type(SS.GetCoinMultiplier) == "function" then
			multiplier = SS.GetCoinMultiplier(player)
		else
			multiplier = player:GetAttribute("CoinMultiplier") or 1
		end
	end
	local finalAmount = math.floor(amount * multiplier)
	if finalAmount <= 0 then return true, 0 end

	local PDS = getPDS()
	if PDS then
		local data = PDS.GetData(player)
		if data then
			local oldCoins = data.Coins or 0
			local newTotal = oldCoins + finalAmount
			PDS.SetField(player, "Coins", newTotal)

			local oldLifetime = data.LifetimeCoinsAchieved or 0
			local oldWeekly   = data.WeeklyCoinsAchieved or 0

			local lifetimeEarned = oldLifetime + finalAmount
			PDS.SetField(player, "LifetimeCoinsAchieved", lifetimeEarned)

			local weeklyEarned = oldWeekly + finalAmount
			PDS.SetField(player, "WeeklyCoinsAchieved", weeklyEarned)

			warn(string.format(
				"[COIN_AUDIT] player=%s userId=%d | +%d (base=%d mult=%.2fx skip=%s) reason=%s | %d -> %d | t=%d",
				player.Name, player.UserId, finalAmount, amount, multiplier,
				tostring(skipMultiplier or false), reason or "?",
				oldCoins, newTotal, os.time()
			))

			reportStats(player.UserId, player.Name, {
				WeeklyCoins  = weeklyEarned,
				LifetimeCoins = lifetimeEarned,
			})

			return true, finalAmount
		else
			achievedLog(string.format(
				"%s PDS.GetData returned nil — using attribute fallback (achieved stats SKIPPED)",
				player.Name
			))
		end
	else
		achievedLog(string.format(
			"%s PDS not available — using attribute fallback (achieved stats SKIPPED)",
			player.Name
		))
	end

	local current = player:GetAttribute(ATTRIBUTE_NAME) or 0
	local newTotal = current + finalAmount
	player:SetAttribute(ATTRIBUTE_NAME, newTotal)
	warn(string.format(
		"[COIN_AUDIT] player=%s userId=%d | +%d (base=%d mult=%.2fx skip=%s) reason=%s | %d -> %d [attr] | t=%d",
		player.Name, player.UserId, finalAmount, amount, multiplier,
		tostring(skipMultiplier or false), reason or "?",
		current, newTotal, os.time()
	))
	return true, finalAmount
end

function EconomyService.DeductCoins(player: Player, amount: number, reason: string?): boolean
	if amount <= 0 then return true end

	local current = EconomyService.GetCoins(player)
	if current < amount then
		log(string.format("%s deduct failed: need %d, have %d (%s)",
			player.Name, amount, current, reason or "unknown"))
		return false
	end

	local newTotal = current - amount

	local PDS = getPDS()
	if PDS then
		local data = PDS.GetData(player)
		if data then
			PDS.SetField(player, "Coins", newTotal)
			warn(string.format(
				"[COIN_AUDIT] player=%s userId=%d | -%d reason=%s | %d -> %d | t=%d",
				player.Name, player.UserId, amount, reason or "?",
				current, newTotal, os.time()
			))
			return true
		end
	end

	player:SetAttribute(ATTRIBUTE_NAME, newTotal)
	warn(string.format(
		"[COIN_AUDIT] player=%s userId=%d | -%d reason=%s | %d -> %d [attr] | t=%d",
		player.Name, player.UserId, amount, reason or "?",
		current, newTotal, os.time()
	))
	return true
end

function EconomyService.SetCoins(player: Player, amount: number): boolean
	if amount < 0 then
		warn("[EconomyService] Cannot set negative coins")
		return false
	end

	local PDS = getPDS()
	if PDS then
		local data = PDS.GetData(player)
		if data then
			PDS.SetField(player, "Coins", amount)
			return true
		end
	end

	player:SetAttribute(ATTRIBUTE_NAME, amount)
	return true
end

function EconomyService.ResetMatchCoins()
	matchCoinsEarned = {}
end

function EconomyService.TrackMatchCoins(player: Player, amount: number)
	local key = player.UserId
	matchCoinsEarned[key] = (matchCoinsEarned[key] or 0) + amount
end

function EconomyService.GetMatchCoins(player: Player): number
	return matchCoinsEarned[player.UserId] or 0
end

return EconomyService