--[[
	SpinWheelBootstrap
	Server script that initializes the Spin The Wheel system.

	Creates:
	  • RemoteFunction: SpinWheel_GetData
	  • RemoteFunction: SpinWheel_RequestSpin
	  • RemoteFunction: SpinWheel_BuySpins
	  • ProximityPrompt on a ground-level invisible anchor near SpinTheWheel

	Also:
	  • Removes ClickDetectors from SpinTheWheel (no click-to-spin)
	  • Removes/disables embedded Scripts/LocalScripts (bad sound assets, old logic)
	  • Handles MarketplaceService.ProcessReceipt for Robux spin purchases

	FIX: ProximityPrompt is now on a dedicated invisible anchor Part at ground level
	     so the "Press E" UI is visible from all angles and distance measurements
	     are consistent between the prompt trigger and the auto-close check.

	Wires player join/leave for data persistence.
]]

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")

-- Ensure Remotes folder
local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
if not remotesFolder then
	remotesFolder = Instance.new("Folder")
	remotesFolder.Name = "Remotes"
	remotesFolder.Parent = ReplicatedStorage
end

-- Create RemoteFunctions
local function ensureRemoteFunc(name: string): RemoteFunction
	local rf = remotesFolder:FindFirstChild(name)
	if not rf then
		rf = Instance.new("RemoteFunction")
		rf.Name = name
		rf.Parent = remotesFolder
	end
	return rf
end

local getDataRF    = ensureRemoteFunc("SpinWheel_GetData")
local requestSpinRF = ensureRemoteFunc("SpinWheel_RequestSpin")
local buySpinsRF    = ensureRemoteFunc("SpinWheel_BuySpins")

-- Load service + config
local Server = ServerScriptService:WaitForChild("Server")
local SpinWheelService = require(Server:WaitForChild("SpinWheelService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SpinWheelConfig = require(Shared:WaitForChild("SpinWheelConfig"))

SpinWheelService.Init()

-- Wire RemoteFunctions
getDataRF.OnServerInvoke = function(player)
	print("[SpinWheelBootstrap] GetData requested by", player.Name)
	return SpinWheelService.GetPlayerData(player)
end

requestSpinRF.OnServerInvoke = function(player)
	print("[SpinWheelBootstrap] RequestSpin from", player.Name)
	local result = SpinWheelService.RequestSpin(player)
	print("[SpinWheelBootstrap] RequestSpin result:", result.success, result.rewardName or result.reason or "")
	return result
end

buySpinsRF.OnServerInvoke = function(player, packageIndex)
	if type(packageIndex) ~= "number" then return { success = false, reason = "Invalid input" } end
	print("[SpinWheelBootstrap] BuySpins from", player.Name, "package:", packageIndex)
	return SpinWheelService.BuySpins(player, packageIndex)
end

-- Wire player events
Players.PlayerAdded:Connect(function(player)
	SpinWheelService.OnPlayerJoined(player)
end)

-- Handle players already in game (Studio)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(function()
		SpinWheelService.OnPlayerJoined(player)
	end)
end

Players.PlayerRemoving:Connect(function(player)
	SpinWheelService.OnPlayerLeaving(player)
end)

-- Save all on shutdown
game:BindToClose(function()
	SpinWheelService.SaveAll()
end)

-- ═══════════════════════════════════════════════════════════════════
-- ROBUX DEVELOPER PRODUCT RECEIPT HANDLING
--
-- Idempotent: tracks PurchaseId in-memory to prevent double-granting.
-- Maps productId → SpinWheelConfig.SpinPrices entry → spins to grant.
-- ═══════════════════════════════════════════════════════════════════

-- Build reverse lookup: productId → spins count
local productIdToSpins: { [number]: number } = {}
for _, pkg in ipairs(SpinWheelConfig.SpinPrices) do
	if pkg.productId and pkg.productId > 0 then
		productIdToSpins[pkg.productId] = pkg.spins
	end
end

-- In-memory receipt tracking (prevents double-granting if Roblox retries)
local processedReceipts: { [string]: boolean } = {}

MarketplaceService.ProcessReceipt = function(receiptInfo)
	local receiptKey = tostring(receiptInfo.PurchaseId)

	-- Already processed this exact receipt → acknowledge
	if processedReceipts[receiptKey] then
		print("[SpinWheelBootstrap] Receipt already processed:", receiptKey)
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		-- Player left; Roblox will retry later when they rejoin
		print("[SpinWheelBootstrap] Player not in game for receipt:", receiptKey, "userId:", receiptInfo.PlayerId)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local productId = receiptInfo.ProductId
	local spinsToGrant = productIdToSpins[productId]

	if spinsToGrant then
		-- This is a spin wheel product
		local success = SpinWheelService.GrantRobuxSpins(player, spinsToGrant)
		if success then
			processedReceipts[receiptKey] = true
			print(string.format(
				"[SpinWheelBootstrap] Robux purchase granted: productId=%d, spins=+%d, newPurchased=?, player=%s, receipt=%s",
				productId, spinsToGrant, player.Name, receiptKey
			))
			return Enum.ProductPurchaseDecision.PurchaseGranted
		else
			warn("[SpinWheelBootstrap] GrantRobuxSpins failed for", player.Name, "receipt:", receiptKey)
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
	end

	-- Not a spin wheel product — if you have other products, handle them here.
	-- For now, acknowledge unknown products to avoid infinite retries.
	warn("[SpinWheelBootstrap] Unknown productId in receipt:", productId, "receipt:", receiptKey)
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

print("[SpinWheelBootstrap] ProcessReceipt handler installed for Robux spin purchases")

-- ═══════════════════════════════════════════════════════════════════
-- SPIN THE WHEEL: CLEANUP + PROXIMITY PROMPT SETUP
-- ═══════════════════════════════════════════════════════════════════

task.defer(function()
	local spinModel = workspace:FindFirstChild("SpinTheWheel", true)
	if not spinModel then
		-- Retry a few times (streaming may delay)
		for i = 1, 5 do
			task.wait(2)
			spinModel = workspace:FindFirstChild("SpinTheWheel", true)
			if spinModel then break end
		end
	end

	if not spinModel then
		warn("[SpinWheelBootstrap] SpinTheWheel model NOT FOUND in Workspace — ProximityPrompt not created")
		return
	end

	print("[SpinWheelBootstrap] SpinTheWheel found:", spinModel:GetFullName())

	-- A) REMOVE all ClickDetectors (disable click-to-spin in the 3D world)
	local clickDetectorsRemoved = 0
	for _, desc in ipairs(spinModel:GetDescendants()) do
		if desc:IsA("ClickDetector") then
			print("[SpinWheelBootstrap] REMOVING ClickDetector:", desc:GetFullName())
			desc:Destroy()
			clickDetectorsRemoved += 1
		end
	end
	if clickDetectorsRemoved > 0 then
		print("[SpinWheelBootstrap] Removed", clickDetectorsRemoved, "ClickDetector(s)")
	end

	-- B) DISABLE/REMOVE embedded Scripts and LocalScripts
	--    These may contain old click-to-spin logic or unauthorized sound assets
	local scriptsRemoved = 0
	for _, desc in ipairs(spinModel:GetDescendants()) do
		if desc:IsA("Script") or desc:IsA("LocalScript") then
			print("[SpinWheelBootstrap] REMOVING embedded script:", desc:GetFullName(), "(" .. desc.ClassName .. ")")
			desc.Disabled = true
			desc:Destroy()
			scriptsRemoved += 1
		end
	end
	if scriptsRemoved > 0 then
		print("[SpinWheelBootstrap] Removed", scriptsRemoved, "embedded script(s)")
	end

	-- C) REMOVE any existing ProximityPrompts (we'll create a fresh one)
	for _, desc in ipairs(spinModel:GetDescendants()) do
		if desc:IsA("ProximityPrompt") then
			print("[SpinWheelBootstrap] Removing old ProximityPrompt:", desc:GetFullName())
			desc:Destroy()
		end
	end

	-- D) Find the GROUND-LEVEL center position of the spin wheel model
	--    The actual wheel is elevated (Y ~16.5 studs), which causes distance
	--    mismatch between the prompt and auto-close checks.
	--    We create an invisible anchor Part at GROUND LEVEL so:
	--    1) The "Press E" prompt renders at a visible height (not behind the wheel)
	--    2) Distance measurements are consistent (horizontal, not affected by elevation)
	local wheelCenter = nil

	-- Try to find the model center
	local anyPart = spinModel:FindFirstChildWhichIsA("BasePart", true)
	if anyPart then
		-- Use horizontal position of any part, but force Y to near-ground level
		wheelCenter = Vector3.new(anyPart.Position.X, 5, anyPart.Position.Z)
		print("[SpinWheelBootstrap] Reference part:", anyPart:GetFullName(), "at", anyPart.Position)
	end

	if not wheelCenter then
		warn("[SpinWheelBootstrap] No BasePart found in SpinTheWheel — cannot create ProximityPrompt")
		return
	end

	-- Create an invisible anchor Part at ground level
	local anchor = Instance.new("Part")
	anchor.Name = "SpinWheelPromptAnchor"
	anchor.Size = Vector3.new(2, 2, 2)
	anchor.Position = wheelCenter
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1 -- invisible
	anchor.Parent = spinModel

	print("[SpinWheelBootstrap] Created invisible anchor at:", wheelCenter)

	-- Create ProximityPrompt on the ground-level anchor
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "SpinWheelPrompt"
	prompt.ActionText = "Spin"
	prompt.ObjectText = "Spin The Wheel"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 14
	prompt.RequiresLineOfSight = false
	prompt.Parent = anchor

	print("[SpinWheelBootstrap] ProximityPrompt created on:", anchor:GetFullName(), "at Y =", wheelCenter.Y)
	print("[SpinWheelBootstrap] Spin The Wheel system fully ready ✓")
end)

print("[SpinWheelBootstrap] Spin The Wheel remotes ready")
