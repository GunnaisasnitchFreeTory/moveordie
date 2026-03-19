--[[
	SwordPickupController
	Client-side hover animation + spawn announcement for sword pickups.

	Watches Workspace.SwordPickups for models with "SwordPickup" attribute.
	Animates hover + rotation identical to CoinPickupController / BrainrotPickupController.
	Shows "A SWORD HAS RANDOMLY SPAWNED" announcement + plays sound cue on remote.

	API:
		Init()
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlayerState = require(Shared:WaitForChild("PlayerState"))
local FeedbackConfig = require(Shared:WaitForChild("FeedbackConfig"))
local AnnouncementController = require(script.Parent:WaitForChild("AnnouncementController"))

local SwordPickupController = {}

local initialized = false

local FOLDER_NAME = "SwordPickups"
local BOB_AMPLITUDE = 0.4
local BOB_SPEED = 2.5
local ROTATION_SPEED = 25
local PROXIMITY_THRESHOLD_STUDS = 22
local PROXIMITY_RETRIGGER_SECONDS = 10
local PROXIMITY_SAMPLE_SECONDS = 0.35

local activeAnimations = {}
local tipTriggerRemote: RemoteEvent? = nil
local lastProximityTriggerToken = ""
local lastProximityTriggerAt = 0

local function startAnimation(model)
	if activeAnimations[model] then return end

	local allParts = {}
	if model:IsA("BasePart") then
		if not model:GetAttribute("NoAnimate") then
			table.insert(allParts, model)
		end
	else
		for _, desc in ipairs(model:GetDescendants()) do
			if desc:IsA("BasePart") and not desc:GetAttribute("NoAnimate") then
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
	if not model:GetAttribute("SwordPickup") then return end
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

local function showAnnouncement(data)
	AnnouncementController.QueueImmediate({
		text = "A SWORD HAS RANDOMLY SPAWNED",
		style = "Sword",
		priority = FeedbackConfig.Announcements.Priorities.Sword,
		durationSeconds = FeedbackConfig.Announcements.DisplayDurationSeconds,
		dedupeKey = "sword_spawn_announcement",
		cooldownSeconds = 1,
		requiresInMatch = data.matchOnly == true,
		soundId = data.soundId,
		yPosition = FeedbackConfig.Announcements.YPosition,
	})
end

local function isLocalPlayerInMatch(): boolean
	return Players.LocalPlayer:GetAttribute("PlayerState") == PlayerState.States.InMatch
end

local function showDeniedMessage()
	AnnouncementController.QueueLocal({
		text = "You already have a sword!",
		style = "Reward",
		priority = FeedbackConfig.Announcements.Priorities.Reward,
		durationSeconds = 1.35,
		dedupeKey = "sword_denied",
		cooldownSeconds = 1.25,
		requiresInMatch = true,
	})
end

local function getModelWorldPosition(model: Instance): Vector3?
	if model:IsA("Model") then
		local primary = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
		return primary and primary.Position or nil
	elseif model:IsA("BasePart") then
		return model.Position
	end
	return nil
end

local function getLocalRootPosition(): Vector3?
	local player = Players.LocalPlayer
	local character = player and player.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

local function buildSwordProximityToken(swordModel: Instance, position: Vector3): string
	local spawnRound = tostring(swordModel:GetAttribute("SpawnRound") or "")
	return string.format(
		"sr%s_x%d_y%d_z%d",
		spawnRound,
		math.floor(position.X + 0.5),
		math.floor(position.Y + 0.5),
		math.floor(position.Z + 0.5)
	)
end

local function startSwordProximityWatcher()
	local elapsed = 0
	RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed < PROXIMITY_SAMPLE_SECONDS then
			return
		end
		elapsed = 0

		if not tipTriggerRemote then
			return
		end
		if not isLocalPlayerInMatch() then
			return
		end

		local rootPos = getLocalRootPosition()
		if not rootPos then
			return
		end

		local folder = Workspace:FindFirstChild(FOLDER_NAME)
		if not folder then
			return
		end

		local bestDistance = math.huge
		local bestToken = ""
		for _, swordModel in ipairs(folder:GetChildren()) do
			if swordModel:GetAttribute("SwordPickup") == true then
				local worldPos = getModelWorldPosition(swordModel)
				if worldPos then
					local dist = (worldPos - rootPos).Magnitude
					if dist < bestDistance then
						bestDistance = dist
						bestToken = buildSwordProximityToken(swordModel, worldPos)
					end
				end
			end
		end

		if bestToken == "" or bestDistance > PROXIMITY_THRESHOLD_STUDS then
			return
		end

		local now = os.clock()
		if bestToken == lastProximityTriggerToken and (now - lastProximityTriggerAt) < PROXIMITY_RETRIGGER_SECONDS then
			return
		end

		lastProximityTriggerToken = bestToken
		lastProximityTriggerAt = now
		tipTriggerRemote:FireServer({
			type = "SwordProximity",
			token = bestToken,
			distance = math.floor(bestDistance + 0.5),
		})
	end)
end

function SwordPickupController.Init()
	if initialized then return end
	initialized = true
	AnnouncementController.Init()

	task.spawn(function()
		local folder = Workspace:FindFirstChild(FOLDER_NAME)
		if folder then
			watchFolder(folder)
		end

		Workspace.ChildAdded:Connect(function(child)
			if child.Name == FOLDER_NAME and child:IsA("Folder") then
				watchFolder(child)
			end
		end)
	end)

	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
		if not remotes then return end
		local remote = remotes:WaitForChild("SwordSpawned", 15)
		if not remote then return end
		local triggerRemote = remotes:WaitForChild("FirstMatchTipTrigger", 15)
		if triggerRemote and triggerRemote:IsA("RemoteEvent") then
			tipTriggerRemote = triggerRemote
		end

		remote.OnClientEvent:Connect(function(data)
			if type(data) == "table" then
				if data.denied then
					showDeniedMessage()
				else
					if data.matchOnly and not isLocalPlayerInMatch() then
						return
					end
					showAnnouncement(data)
				end
			end
		end)
	end)

	startSwordProximityWatcher()

	print("[SwordPickupController] Initialized")
end

return SwordPickupController
