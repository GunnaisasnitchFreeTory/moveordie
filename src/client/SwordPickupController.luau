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

local SwordPickupController = {}

local initialized = false

local FOLDER_NAME = "SwordPickups"
local BOB_AMPLITUDE = 0.4
local BOB_SPEED = 2.5
local ROTATION_SPEED = 25

local activeAnimations = {}

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
	local player = Players.LocalPlayer
	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui then return end

	local sound = Instance.new("Sound")
	sound.SoundId = data.soundId or ""
	sound.Volume = 0.4
	sound.PlayOnRemove = false
	sound.Parent = playerGui
	sound:Play()
	task.delay(5, function()
		if sound and sound.Parent then sound:Destroy() end
	end)

	local sg = Instance.new("ScreenGui")
	sg.Name = "SwordAnnouncement"
	sg.ResetOnSpawn = false
	sg.DisplayOrder = 50
	sg.IgnoreGuiInset = true
	sg.Parent = playerGui

	local label = Instance.new("TextLabel")
	label.Name = "AnnouncementLabel"
	label.Size = UDim2.new(1, 0, 0, 40)
	label.Position = UDim2.new(0.5, 0, 0, 150)
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 22
	label.TextColor3 = Color3.fromRGB(255, 80, 80)
	label.TextStrokeColor3 = Color3.fromRGB(50, 0, 0)
	label.TextStrokeTransparency = 0.3
	label.Text = "A SWORD HAS RANDOMLY SPAWNED"
	label.TextTransparency = 0
	label.Parent = sg

	task.delay(2, function()
		if not label or not label.Parent then return end
		local tween = TweenService:Create(
			label,
			TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ TextTransparency = 1, TextStrokeTransparency = 1 }
		)
		tween:Play()
		tween.Completed:Wait()
		if sg and sg.Parent then sg:Destroy() end
	end)
end

local function isLocalPlayerInMatch(): boolean
	return Players.LocalPlayer:GetAttribute("PlayerState") == PlayerState.States.InMatch
end

local function showDeniedMessage()
	local player = Players.LocalPlayer
	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui then return end

	local sg = Instance.new("ScreenGui")
	sg.Name = "SwordDenied"
	sg.ResetOnSpawn = false
	sg.DisplayOrder = 50
	sg.IgnoreGuiInset = true
	sg.Parent = playerGui

	local lbl = Instance.new("TextLabel")
	lbl.Name = "DeniedLabel"
	lbl.Size = UDim2.new(1, 0, 0, 30)
	lbl.Position = UDim2.new(0.5, 0, 0, 150)
	lbl.AnchorPoint = Vector2.new(0.5, 0)
	lbl.BackgroundTransparency = 1
	lbl.Font = Enum.Font.GothamBold
	lbl.TextSize = 16
	lbl.TextColor3 = Color3.fromRGB(255, 200, 80)
	lbl.TextStrokeColor3 = Color3.fromRGB(50, 30, 0)
	lbl.TextStrokeTransparency = 0.3
	lbl.Text = "You already have a sword!"
	lbl.Parent = sg

	task.delay(1.5, function()
		if not lbl or not lbl.Parent then return end
		local tween = TweenService:Create(
			lbl,
			TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ TextTransparency = 1, TextStrokeTransparency = 1 }
		)
		tween:Play()
		tween.Completed:Wait()
		if sg and sg.Parent then sg:Destroy() end
	end)
end

function SwordPickupController.Init()
	if initialized then return end
	initialized = true

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

	print("[SwordPickupController] Initialized")
end

return SwordPickupController