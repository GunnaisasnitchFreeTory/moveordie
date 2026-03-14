--[[
	CoinPickupController
	Client-side hover + rotation animation for round coins.

	Reuses the SAME animation constants as BrainrotPickupController
	(BOB_AMPLITUDE, BOB_SPEED, ROTATION_SPEED) so coins hover and
	spin identically to brainrot pickups.

	Watches Workspace.RoundCoins for children with a "CoinValue" attribute.

	API:
		Init()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace  = game:GetService("Workspace")

local SoundUtil = require(script.Parent:WaitForChild("UI"):WaitForChild("SoundUtil"))

local CoinPickupController = {}

local initialized = false

local FOLDER_NAME     = "RoundCoins"
local COLLECT_REMOTE_NAME = "RoundCoinCollected"
local BOB_AMPLITUDE   = 0.4
local BOB_SPEED       = 2.5
local ROTATION_SPEED  = 25

local activeAnimations = {}
local collectRemoteConnected = false

local function startAnimation(model)
	if activeAnimations[model] then return end

	local allParts = {}
	if model:IsA("BasePart") then
		table.insert(allParts, model)
	else
		for _, desc in ipairs(model:GetDescendants()) do
			if desc:IsA("BasePart") then
				table.insert(allParts, desc)
			end
		end
	end

	if #allParts == 0 then return end

	local refPart = allParts[1]
	local refCF = refPart.CFrame
	local refInv = refCF:Inverse()

	local relatives = {}
	for _, part in ipairs(allParts) do
		relatives[part] = refInv * part.CFrame
	end

	local basePos = refCF.Position
	local baseTilt = refCF.Rotation

	local startTime = tick()

	local conn = RunService.Heartbeat:Connect(function()
		if not model or not model.Parent then return end

		local elapsed = tick() - startTime
		local bobY = math.sin(elapsed * BOB_SPEED) * BOB_AMPLITUDE
		local rotAngle = elapsed * ROTATION_SPEED

		local newRefCF = CFrame.new(basePos + Vector3.new(0, bobY, 0))
			* CFrame.Angles(0, math.rad(rotAngle), 0)
			* baseTilt

		for _, part in ipairs(allParts) do
			if part and part.Parent then
				part.CFrame = newRefCF * relatives[part]
			end
		end
	end)

	activeAnimations[model] = {
		connection = conn,
		startTime = startTime,
	}
end

local function stopAnimation(model)
	local anim = activeAnimations[model]
	if anim then
		if anim.connection and anim.connection.Connected then
			anim.connection:Disconnect()
		end
		activeAnimations[model] = nil
	end
end

local function onModelAdded(model)
	if not model:GetAttribute("CoinValue") then return end
	task.defer(function()
		if model and model.Parent then
			startAnimation(model)
		end
	end)
end

local function onModelRemoved(model)
	stopAnimation(model)
end

local function watchFolder(folder)
	for _, child in ipairs(folder:GetChildren()) do
		onModelAdded(child)
	end
	folder.ChildAdded:Connect(onModelAdded)
	folder.ChildRemoved:Connect(onModelRemoved)
end

local function connectCollectRemote()
	if collectRemoteConnected then
		return
	end

	local remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
	if not remotes then
		warn("[CoinPickupController] Remotes folder not found for pickup audio")
		return
	end

	local remote = remotes:WaitForChild(COLLECT_REMOTE_NAME, 15)
	if not remote or not remote:IsA("RemoteEvent") then
		warn("[CoinPickupController] Round coin collect remote missing")
		return
	end

	collectRemoteConnected = true
	remote.OnClientEvent:Connect(function()
		SoundUtil.CoinCollectPrimary()
	end)
	print("[CoinPickupController] Connected pickup audio remote")
end

function CoinPickupController.Init()
	if initialized then return end
	initialized = true
	SoundUtil.Init()

	task.spawn(function()
		connectCollectRemote()

		local folder = Workspace:FindFirstChild(FOLDER_NAME)
		if folder then
			watchFolder(folder)
			print("[CoinPickup] Watching folder")
		end

		Workspace.ChildAdded:Connect(function(child)
			if child.Name == FOLDER_NAME and child:IsA("Folder") then
				watchFolder(child)
				print("[CoinPickup] Folder appeared — watching")
			end
		end)
	end)

	print("[CoinPickupController] Initialized")
end

return CoinPickupController
