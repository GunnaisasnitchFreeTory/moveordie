--[[
	PetNpcFollower
	Walker-pet follow brain that reuses NpcLocomotion (TungTung-style loop).
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TungtungLocomotionAdapter = require(ReplicatedStorage:WaitForChild("Pets"):WaitForChild("TungtungLocomotionAdapter"))

local PetNpcFollower = {}

local DEFAULTS = {
	FollowDistance = 5,
	StopDistance = 3,
	UpdateInterval = 0.2,
	TeleportDistance = 60,
	WalkSpeed = 26,
	ChaseInterval = 0.2,
	RepathInterval = 0.45,
	RepathTargetMoveDelta = 4.0,
	WalkAnimId = "rbxassetid://507777826",
	IdleAnimId = "rbxassetid://507766666",
	HipHeight = 2.0,
}

export type FollowHandle = {
	Destroy: (self: FollowHandle) -> (),
	IsWalkAnimLoaded: (self: FollowHandle) -> boolean,
	IsIdleAnimLoaded: (self: FollowHandle) -> boolean,
}

function PetNpcFollower.Start(model: Model, owner: Player, opts): FollowHandle?
	if not model or not owner then
		return nil
	end
	opts = opts or {}
	local cfg = {
		FollowDistance = opts.FollowDistance or DEFAULTS.FollowDistance,
		StopDistance = opts.StopDistance or DEFAULTS.StopDistance,
		UpdateInterval = opts.UpdateInterval or DEFAULTS.UpdateInterval,
		TeleportDistance = opts.TeleportDistance or DEFAULTS.TeleportDistance,
		WalkSpeed = opts.WalkSpeed or DEFAULTS.WalkSpeed,
		ChaseInterval = opts.ChaseInterval or DEFAULTS.ChaseInterval,
		RepathInterval = opts.RepathInterval or DEFAULTS.RepathInterval,
		RepathTargetMoveDelta = opts.RepathTargetMoveDelta or DEFAULTS.RepathTargetMoveDelta,
		WalkAnimId = opts.WalkAnimId or DEFAULTS.WalkAnimId,
		IdleAnimId = opts.IdleAnimId or DEFAULTS.IdleAnimId,
		HipHeight = opts.HipHeight or DEFAULTS.HipHeight,
	}

	local adapter = TungtungLocomotionAdapter.attach(model, owner, {
		FollowDistance = cfg.FollowDistance,
		WalkSpeed = cfg.WalkSpeed,
		ChaseInterval = cfg.ChaseInterval,
		RepathInterval = cfg.RepathInterval,
		RepathTargetMoveDelta = cfg.RepathTargetMoveDelta,
		WalkAnimId = cfg.WalkAnimId,
		IdleAnimId = cfg.IdleAnimId,
		HipHeight = cfg.HipHeight,
	})

	local acc = 0
	local conn = RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < cfg.UpdateInterval then
			return
		end
		acc = 0

		if not model.Parent then
			return
		end

		local char = owner.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if not hrp or not hrp:IsA("BasePart") then
			adapter:Stop()
			return
		end

		local followPos = adapter:GetTargetPosition()
		if not followPos then
			adapter:Stop()
			return
		end

		local root = model:FindFirstChild("HumanoidRootPart", true)
		local petPos = root and root:IsA("BasePart") and root.Position or (model.PrimaryPart and model.PrimaryPart.Position)
		if not petPos then
			return
		end

		local dist = (followPos - petPos).Magnitude
		if dist > cfg.TeleportDistance or petPos.Y < -50 then
			model:PivotTo(CFrame.new(followPos + Vector3.new(0, 2, 0)))
			adapter:Stop()
			return
		end

		if dist > cfg.StopDistance then
			adapter:SetTarget(followPos)
		else
			adapter:Stop()
		end
	end)

	local handle = {}
	function handle:Destroy()
		if conn then
			conn:Disconnect()
		end
		if adapter then
			adapter:Destroy()
		end
	end
	function handle:IsWalkAnimLoaded(): boolean
		return adapter and adapter:IsWalkAnimLoaded() or false
	end
	function handle:IsIdleAnimLoaded(): boolean
		return adapter and adapter:IsIdleAnimLoaded() or false
	end
	return handle
end

return PetNpcFollower
