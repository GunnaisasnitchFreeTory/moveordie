--[[
	TungtungLocomotionAdapter
	Wrapper that binds TungTung locomotion core to a pet-owner target provider.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NpcLocomotion = require(ReplicatedStorage:WaitForChild("NPC"):WaitForChild("NpcLocomotion"))

local Adapter = {}
Adapter.__index = Adapter

local DEFAULTS = {
	FollowDistance = 5,
	WalkSpeed = 26,
	ChaseInterval = 0.2,
	RepathInterval = 0.45,
	RepathTargetMoveDelta = 4.0,
	WalkAnimId = "rbxassetid://507777826",
	IdleAnimId = "rbxassetid://507766666",
	HipHeight = 2.0,
}

function Adapter.attach(model: Model, owner: Player, config)
	config = config or {}
	local self = setmetatable({}, Adapter)
	self._owner = owner
	self._followDistance = config.FollowDistance or DEFAULTS.FollowDistance
	self._loco = NpcLocomotion.attach(model, {
		WalkSpeed = config.WalkSpeed or DEFAULTS.WalkSpeed,
		ChaseInterval = config.ChaseInterval or DEFAULTS.ChaseInterval,
		RepathInterval = config.RepathInterval or DEFAULTS.RepathInterval,
		RepathTargetMoveDelta = config.RepathTargetMoveDelta or DEFAULTS.RepathTargetMoveDelta,
		WalkAnimId = config.WalkAnimId or DEFAULTS.WalkAnimId,
		IdleAnimId = config.IdleAnimId or DEFAULTS.IdleAnimId,
		HipHeight = config.HipHeight or DEFAULTS.HipHeight,
	})
	return self
end

function Adapter:GetTargetPosition(): Vector3?
	local owner = self._owner
	local char = owner and owner.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return nil
	end
	return hrp.Position - (hrp.CFrame.LookVector * self._followDistance)
end

function Adapter:SetTarget(targetPos: Vector3)
	self._loco:SetTarget(targetPos)
end

function Adapter:Stop()
	self._loco:Stop()
end

function Adapter:IsWalkAnimLoaded(): boolean
	return self._loco:IsWalkAnimLoaded()
end

function Adapter:IsIdleAnimLoaded(): boolean
	return self._loco:IsIdleAnimLoaded()
end

function Adapter:Destroy()
	self._loco:Destroy()
end

return Adapter
