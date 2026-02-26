--[[
	DailyRewardService
	Server-side daily reward claim logic.

	API:
	  Init()             — creates remotes, wires handlers
	  GetStatus(player)  — returns current streak state
	  Claim(player)      — attempts to claim today's reward

	Uses PlayerDataService for persistence, EconomyService for coins,
	InventoryService for crown grants, CrateService for crate openings.

	Coin rewards use skipMultiplier=true so players receive the exact
	configured amount (no pet/crown multiplier applied).
]]

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = ServerScriptService:WaitForChild("Server")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local DailyRewardConfig = require(Shared:WaitForChild("DailyRewardConfig"))

local _PDS, _Economy, _Inventory, _Crate, _SpinWheel = nil, nil, nil, nil, nil

local function getPDS()
	if _PDS then return _PDS end
	local ok, mod = pcall(require, Server:WaitForChild("PlayerDataService", 5))
	if ok and mod then _PDS = mod end
	return _PDS
end

local function getEconomy()
	if _Economy then return _Economy end
	local ok, mod = pcall(require, Server:WaitForChild("EconomyService", 5))
	if ok and mod then _Economy = mod end
	return _Economy
end

local function getInventory()
	if _Inventory then return _Inventory end
	local ok, mod = pcall(require, Server:WaitForChild("InventoryService", 5))
	if ok and mod then _Inventory = mod end
	return _Inventory
end

local function getCrate()
	if _Crate then return _Crate end
	local ok, mod = pcall(require, Server:WaitForChild("CrateService", 5))
	if ok and mod then _Crate = mod end
	return _Crate
end

local function getSpinWheel()
	if _SpinWheel then return _SpinWheel end
	local ok, mod = pcall(require, Server:WaitForChild("SpinWheelService", 5))
	if ok and mod then _SpinWheel = mod end
	return _SpinWheel
end

local DailyRewardService = {}
local initialized = false
local _claimLock: { [number]: boolean } = {}

local function log(...)
	print("[DailyRewardService]", ...)
end

function DailyRewardService.GetStatus(player)
	local PDS = getPDS()
	if not PDS or not PDS.IsLoaded(player) then
		return { dataLoaded = false, streak = 0, canClaim = false, secondsUntilNext = 0, rewards = DailyRewardConfig.Rewards }
	end

	local lastClaim = PDS.GetField(player, "LastDailyRewardTime") or 0
	local streak = PDS.GetField(player, "DailyStreak") or 0
	local now = os.time()
	local elapsed = now - lastClaim

	local canClaim = elapsed >= DailyRewardConfig.CooldownSeconds
	local secondsUntilNext = 0
	if not canClaim then
		secondsUntilNext = math.max(0, DailyRewardConfig.CooldownSeconds - elapsed)
	end

	local effectiveStreak = streak
	if elapsed >= DailyRewardConfig.StreakResetSeconds and lastClaim > 0 then
		effectiveStreak = 0
	end

	return {
		dataLoaded = true,
		streak = effectiveStreak,
		lastClaimTime = lastClaim,
		canClaim = canClaim,
		secondsUntilNext = secondsUntilNext,
		rewards = DailyRewardConfig.Rewards,
	}
end

function DailyRewardService.Claim(player)
	local userId = player.UserId
	if _claimLock[userId] then
		return { success = false, reason = "AlreadyClaiming" }
	end
	_claimLock[userId] = true

	local PDS = getPDS()
	if not PDS or not PDS.IsLoaded(player) then
		_claimLock[userId] = nil
		return { success = false, reason = "Data not loaded" }
	end

	local lastClaim = PDS.GetField(player, "LastDailyRewardTime") or 0
	local streak = PDS.GetField(player, "DailyStreak") or 0
	local now = os.time()
	local elapsed = now - lastClaim

	if elapsed < DailyRewardConfig.CooldownSeconds then
		_claimLock[userId] = nil
		local remaining = DailyRewardConfig.CooldownSeconds - elapsed
		return { success = false, reason = "AlreadyClaimed", secondsUntilNext = remaining }
	end

	if elapsed >= DailyRewardConfig.StreakResetSeconds and lastClaim > 0 then
		streak = 0
		log(string.format("%s streak reset (%.0f hours since last claim)", player.Name, elapsed / 3600))
	end

	streak = streak + 1
	if streak > DailyRewardConfig.MaxStreak then
		streak = 1
	end

	local rewardDef = DailyRewardConfig.Rewards[streak]
	if not rewardDef then
		_claimLock[userId] = nil
		warn("[DailyRewardService] No reward defined for day", streak)
		return { success = false, reason = "No reward for day " .. tostring(streak) }
	end

	local grantResult = {
		type = rewardDef.type,
		label = rewardDef.label,
		icon = rewardDef.icon or "",
		iconText = rewardDef.iconText or "",
		iconColor = rewardDef.iconColor,
		crownId = rewardDef.crownId,
		crateId = rewardDef.crateId,
	}

	if rewardDef.type == "Coins" then
		local eco = getEconomy()
		if eco then
			local ok, actualAmount = eco.AwardCoins(player, rewardDef.amount, "DailyReward_Day" .. streak, true)
			if not ok then
				_claimLock[userId] = nil
				return { success = false, reason = "Coin grant failed" }
			end
			grantResult.amount = actualAmount or rewardDef.amount
		else
			_claimLock[userId] = nil
			return { success = false, reason = "Economy unavailable" }
		end

	elseif rewardDef.type == "Crown" then
		local inv = getInventory()
		if inv then
			local alreadyOwned = inv.OwnsItem(player, "Crowns", rewardDef.crownId)
			if alreadyOwned then
				grantResult.duplicate = true
				grantResult.coinsInstead = 0
			else
				inv.GrantItem(player, "Crowns", rewardDef.crownId)
				grantResult.crownId = rewardDef.crownId
			end
		else
			_claimLock[userId] = nil
			return { success = false, reason = "Inventory unavailable" }
		end

	elseif rewardDef.type == "Crate" then
		local crateService = getCrate()
		if crateService and crateService.RollCrateFree then
			local rollCount = rewardDef.amount or 1
			local rollResult = crateService.RollCrateFree(player, rewardDef.crateId, rollCount)
			local crateResults = rollResult and rollResult.results or {}
			grantResult.crateResults = crateResults
		else
			_claimLock[userId] = nil
			return { success = false, reason = "Crate service unavailable" }
		end

	elseif rewardDef.type == "Spins" then
		local spinsToGrant = rewardDef.amount or 1
		local spinService = getSpinWheel()
		if not spinService or type(spinService.GrantRobuxSpins) ~= "function" then
			_claimLock[userId] = nil
			return { success = false, reason = "SpinWheelService unavailable" }
		end
		local granted = spinService.GrantRobuxSpins(player, spinsToGrant)
		if not granted then
			_claimLock[userId] = nil
			return { success = false, reason = "Spins grant failed" }
		end
		grantResult.amount = spinsToGrant
		log(string.format("%s claimed Day %d: %d free spins", player.Name, streak, spinsToGrant))
	end

	PDS.SetField(player, "LastDailyRewardTime", now)
	PDS.SetField(player, "DailyStreak", streak)

	warn(string.format("[DAILY_AUDIT] player=%s userId=%d day=%d type=%s label=%s | t=%d",
		player.Name, userId, streak, rewardDef.type, grantResult.label, os.time()))

	_claimLock[userId] = nil
	return {
		success = true,
		reward = grantResult,
		newStreak = streak,
	}
end

function DailyRewardService.Init()
	if initialized then return end
	initialized = true

	local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotesFolder then
		remotesFolder = Instance.new("Folder")
		remotesFolder.Name = "Remotes"
		remotesFolder.Parent = ReplicatedStorage
	end

	local getStatusFunc = remotesFolder:FindFirstChild("DailyReward_GetStatus")
	if not getStatusFunc then
		getStatusFunc = Instance.new("RemoteFunction")
		getStatusFunc.Name = "DailyReward_GetStatus"
		getStatusFunc.Parent = remotesFolder
	end
	getStatusFunc.OnServerInvoke = function(player)
		return DailyRewardService.GetStatus(player)
	end

	local claimFunc = remotesFolder:FindFirstChild("DailyReward_Claim")
	if not claimFunc then
		claimFunc = Instance.new("RemoteFunction")
		claimFunc.Name = "DailyReward_Claim"
		claimFunc.Parent = remotesFolder
	end
	claimFunc.OnServerInvoke = function(player)
		return DailyRewardService.Claim(player)
	end

	game:GetService("Players").PlayerRemoving:Connect(function(player)
		_claimLock[player.UserId] = nil
	end)

	log(string.format("Initialized — cooldown=%ds, streakReset=%ds, maxStreak=%d",
		DailyRewardConfig.CooldownSeconds, DailyRewardConfig.StreakResetSeconds, DailyRewardConfig.MaxStreak))
end

return DailyRewardService
