--[[
	DailyRewardService
	Server-side daily reward claim logic.

	API:
	  Init()             — creates remotes, wires handlers
	  GetStatus(player)  — returns current streak state
	  Claim(player)      — attempts to claim today's reward

	Uses PlayerDataService for persistence, EconomyService for coins,
	InventoryService for crown grants, CrateService for crate openings.
]]

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = ServerScriptService:WaitForChild("Server")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local DailyRewardConfig = require(Shared:WaitForChild("DailyRewardConfig"))

-- Lazy-loaded services
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

local function log(...)
	print("[DailyRewardService]", ...)
end

-- STATUS

function DailyRewardService.GetStatus(player)
	local PDS = getPDS()
	if not PDS or not PDS.IsLoaded(player) then
		return { streak = 0, canClaim = false, secondsUntilNext = 0, rewards = DailyRewardConfig.Rewards }
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

	-- If too long since last claim, streak will reset on claim
	local effectiveStreak = streak
	if elapsed >= DailyRewardConfig.StreakResetSeconds and lastClaim > 0 then
		effectiveStreak = 0 -- will reset on next claim
	end

	return {
		streak = effectiveStreak,
		lastClaimTime = lastClaim,
		canClaim = canClaim,
		secondsUntilNext = secondsUntilNext,
		rewards = DailyRewardConfig.Rewards,
	}
end

-- CLAIM

function DailyRewardService.Claim(player)
	local PDS = getPDS()
	if not PDS or not PDS.IsLoaded(player) then
		return { success = false, reason = "Data not loaded" }
	end

	local lastClaim = PDS.GetField(player, "LastDailyRewardTime") or 0
	local streak = PDS.GetField(player, "DailyStreak") or 0
	local now = os.time()
	local elapsed = now - lastClaim

	-- Check cooldown
	if elapsed < DailyRewardConfig.CooldownSeconds then
		local remaining = DailyRewardConfig.CooldownSeconds - elapsed
		return { success = false, reason = "On cooldown", secondsUntilNext = remaining }
	end

	-- Reset streak if too long since last claim
	if elapsed >= DailyRewardConfig.StreakResetSeconds and lastClaim > 0 then
		streak = 0
		log(string.format("%s streak reset (%.0f hours since last claim)", player.Name, elapsed / 3600))
	end

	-- Advance streak (wrapping from MaxStreak back to 1)
	streak = streak + 1
	if streak > DailyRewardConfig.MaxStreak then
		streak = 1
	end

	-- Look up reward
	local rewardDef = DailyRewardConfig.Rewards[streak]
	if not rewardDef then
		warn("[DailyRewardService] No reward defined for day", streak)
		return { success = false, reason = "No reward for day " .. tostring(streak) }
	end

	-- Grant reward (include icon info from config so popup can display it)
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
			eco.AwardCoins(player, rewardDef.amount, "DailyReward_Day" .. streak)
			grantResult.amount = rewardDef.amount
			log(string.format("%s claimed Day %d: %d coins", player.Name, streak, rewardDef.amount))
		else
			return { success = false, reason = "Economy unavailable" }
		end

	elseif rewardDef.type == "Crown" then
		local inv = getInventory()
		if inv then
			local alreadyOwned = inv.OwnsItem(player, "Crowns", rewardDef.crownId)
			if alreadyOwned then
				-- Direct DailyReward crowns: do NOT convert duplicates to coins.
				-- No EconomyService call, no leaderboard stat updates.
				-- Just mark as claimed; popup still shows the crown.
				grantResult.duplicate = true
				grantResult.coinsInstead = 0
				log(string.format("%s claimed Day %d: crown %s (already owned, NO coins — DailyReward bypass)",
					player.Name, streak, rewardDef.crownId))
			else
				inv.GrantItem(player, "Crowns", rewardDef.crownId)
				grantResult.crownId = rewardDef.crownId
				log(string.format("%s claimed Day %d: crown %s", player.Name, streak, rewardDef.crownId))
			end
		else
			return { success = false, reason = "Inventory unavailable" }
		end

	elseif rewardDef.type == "Crate" then
		-- FREE crate rolls — NO coin fund, NO coin charge.
		-- Only coins come from duplicate conversions (if any).
		local crateService = getCrate()
		if crateService and crateService.RollCrateFree then
			local rollCount = rewardDef.amount or 1
			log(string.format("day=%d type=crate_%s count=%d", streak, rewardDef.crateId or "?", rollCount))

			local rollResult = crateService.RollCrateFree(player, rewardDef.crateId, rollCount)
			local crateResults = rollResult and rollResult.results or {}

			-- Log each roll and track duplicate conversion coins
			local totalDupCoins = 0
			for i, r in ipairs(crateResults) do
				local dupCoins = r.coinsAwarded or 0
				log(string.format("  rolled crownId=%s dup=%s dupCoins=%d",
					r.itemId or "?", tostring(r.isDuplicate), dupCoins))
				totalDupCoins = totalDupCoins + dupCoins
			end
			log(string.format("  FINAL coin delta from Day%d: %d (all from duplicate conversions)",
				streak, totalDupCoins))

			grantResult.crateResults = crateResults
			log(string.format("%s claimed Day %d: %dx %s (%d items rolled)",
				player.Name, streak, rollCount, rewardDef.crateId, #crateResults))
		else
			return { success = false, reason = "Crate service unavailable" }
		end

	elseif rewardDef.type == "Spins" then
		-- Grant free spins via SpinWheelService (uses its own DataStore persistence)
		local spinsToGrant = rewardDef.amount or 1
		local spinService = getSpinWheel()
		if spinService and type(spinService.GrantRobuxSpins) == "function" then
			local granted = spinService.GrantRobuxSpins(player, spinsToGrant)
			if granted then
				grantResult.amount = spinsToGrant
				log(string.format("%s claimed Day %d: %d free spins", player.Name, streak, spinsToGrant))
			else
				warn("[DailyRewardService] SpinWheelService.GrantRobuxSpins failed for", player.Name)
				grantResult.amount = spinsToGrant
			end
		else
			warn("[DailyRewardService] SpinWheelService not available for granting spins")
			grantResult.amount = spinsToGrant
		end
	end

	-- Update persistent data
	PDS.SetField(player, "LastDailyRewardTime", now)
	PDS.SetField(player, "DailyStreak", streak)

	return {
		success = true,
		reward = grantResult,
		newStreak = streak,
	}
end

-- INIT

function DailyRewardService.Init()
	if initialized then return end
	initialized = true

	local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotesFolder then
		remotesFolder = Instance.new("Folder")
		remotesFolder.Name = "Remotes"
		remotesFolder.Parent = ReplicatedStorage
	end

	-- GetStatus RemoteFunction
	local getStatusFunc = remotesFolder:FindFirstChild("DailyReward_GetStatus")
	if not getStatusFunc then
		getStatusFunc = Instance.new("RemoteFunction")
		getStatusFunc.Name = "DailyReward_GetStatus"
		getStatusFunc.Parent = remotesFolder
	end
	getStatusFunc.OnServerInvoke = function(player)
		return DailyRewardService.GetStatus(player)
	end

	-- Claim RemoteFunction
	local claimFunc = remotesFolder:FindFirstChild("DailyReward_Claim")
	if not claimFunc then
		claimFunc = Instance.new("RemoteFunction")
		claimFunc.Name = "DailyReward_Claim"
		claimFunc.Parent = remotesFolder
	end
	claimFunc.OnServerInvoke = function(player)
		return DailyRewardService.Claim(player)
	end

	log("Initialized (GetStatus + Claim remotes ready)")
end

return DailyRewardService
