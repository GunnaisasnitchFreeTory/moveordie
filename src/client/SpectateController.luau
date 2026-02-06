--[[
	SpectateController
	Client-side camera control for spectating.
	
	When player is eliminated:
	- Server fires SpectateTarget with target UserId
	- Client attaches camera to target's character
	- When target is nil (no one alive), reverts to own character
	
	Future: Add next/prev cycling keybinds
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera

-- Wait for remotes
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
if not Remotes then
	warn("[SpectateController] Remotes folder not found")
	return
end

local SpectateTarget = Remotes:WaitForChild("SpectateTarget", 5)
if not SpectateTarget then
	warn("[SpectateController] SpectateTarget remote not found")
	return
end

-- State
local isSpectating = false
local currentTarget: Player? = nil
local originalCameraSubject = nil

--[[ HELPERS ]]

local function log(...)
	print("[SpectateController]", ...)
end

local function getHumanoid(player: Player): Humanoid?
	local character = player.Character
	if not character then return nil end
	return character:FindFirstChildOfClass("Humanoid")
end

local function attachCameraToTarget(target: Player?)
	if not target then
		-- Revert to own character
		if originalCameraSubject then
			Camera.CameraSubject = originalCameraSubject
		else
			local myHumanoid = getHumanoid(LocalPlayer)
			if myHumanoid then
				Camera.CameraSubject = myHumanoid
			end
		end
		currentTarget = nil
		isSpectating = false
		log("Stopped spectating - camera reverted")
		return
	end
	
	local targetHumanoid = getHumanoid(target)
	if targetHumanoid then
		Camera.CameraSubject = targetHumanoid
		currentTarget = target
		isSpectating = true
		log("Now spectating:", target.Name)
	else
		-- Target has no humanoid yet, wait and retry
		task.spawn(function()
			for _ = 1, 10 do
				task.wait(0.2)
				local humanoid = getHumanoid(target)
				if humanoid then
					Camera.CameraSubject = humanoid
					currentTarget = target
					isSpectating = true
					log("Now spectating:", target.Name)
					return
				end
			end
			log("Failed to find target humanoid for:", target.Name)
		end)
	end
end

--[[ EVENT HANDLERS ]]

SpectateTarget.OnClientEvent:Connect(function(targetUserId: number?)
	-- Store original camera subject if not already spectating
	if not isSpectating and not originalCameraSubject then
		originalCameraSubject = Camera.CameraSubject
	end
	
	if not targetUserId then
		-- No target - revert camera
		attachCameraToTarget(nil)
		return
	end
	
	-- Find player by UserId
	local target = Players:GetPlayerByUserId(targetUserId)
	if target then
		attachCameraToTarget(target)
	else
		log("Target player not found for UserId:", targetUserId)
		attachCameraToTarget(nil)
	end
end)

-- Handle target leaving
Players.PlayerRemoving:Connect(function(player)
	if currentTarget == player then
		log("Spectate target left, finding new target...")
		-- Server should send new target, but as fallback revert
		task.delay(0.5, function()
			if currentTarget == player then
				attachCameraToTarget(nil)
			end
		end)
	end
end)

-- Reset on respawn
LocalPlayer.CharacterAdded:Connect(function(character)
	if isSpectating then
		-- Keep spectating if we were spectating
		return
	end
	
	-- Reset original camera subject
	local humanoid = character:WaitForChild("Humanoid", 5)
	if humanoid then
		originalCameraSubject = humanoid
	end
end)

log("Initialized")

