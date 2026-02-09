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

	FIX: ProximityPrompt is now on a dedicated invisible anchor Part at ground level
	     so the "Press E" UI is visible from all angles and distance measurements
	     are consistent between the prompt trigger and the auto-close check.

	Wires player join/leave for data persistence.
]]

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

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

-- Load service
local Server = ServerScriptService:WaitForChild("Server")
local SpinWheelService = require(Server:WaitForChild("SpinWheelService"))

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
