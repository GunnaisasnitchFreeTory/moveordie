--[[
	PetFollowController
	Owner-follow brain that reuses LocomotionController (TungTung-style MoveTo flow).
]]

local RunService = game:GetService("RunService")
local LocomotionController = require(script.Parent:WaitForChild("LocomotionController"))

local PetFollowController = {}

local DEFAULTS = {
	FollowDistance = 5,
	SideOffset = 0,
	BackOffset = 0,
	StopDistance = 3.0,
	RepathThreshold = 1.5,
	UpdateInterval = 0.15,
	TeleportDistance = 60,
	WalkSpeed = 14,
	HipHeight = 2.0,
}

export type FollowHandle = {
	Destroy: (self: FollowHandle) -> (),
	IsWalkAnimLoaded: (self: FollowHandle) -> boolean,
	IsIdleAnimLoaded: (self: FollowHandle) -> boolean,
}

function PetFollowController.Start(model: Model, owner: Player, petId: string, opts): FollowHandle?
	if not model or not owner then return nil end
	opts = opts or {}

	local cfg = {
		FollowDistance = opts.FollowDistance or DEFAULTS.FollowDistance,
		SideOffset = opts.SideOffset or DEFAULTS.SideOffset,
		BackOffset = opts.BackOffset or DEFAULTS.BackOffset,
		StopDistance = opts.StopDistance or DEFAULTS.StopDistance,
		RepathThreshold = opts.RepathThreshold or DEFAULTS.RepathThreshold,
		UpdateInterval = opts.UpdateInterval or DEFAULTS.UpdateInterval,
		TeleportDistance = opts.TeleportDistance or DEFAULTS.TeleportDistance,
		WalkSpeed = opts.WalkSpeed or DEFAULTS.WalkSpeed,
		HipHeight = opts.HipHeight or DEFAULTS.HipHeight,
		WalkAnimId = opts.WalkAnimId,
		IdleAnimId = opts.IdleAnimId,
	}

	local loco = LocomotionController.new(model, cfg)
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
			loco:Stop()
			return
		end

		local followPos =
			hrp.Position
			+ (hrp.CFrame.LookVector * -cfg.FollowDistance)
			+ (hrp.CFrame.RightVector * cfg.SideOffset)
			+ Vector3.new(0, 0, cfg.BackOffset)

		local petPos = loco:GetPosition()
		if not petPos then
			return
		end

		local dist = (followPos - petPos).Magnitude
		if dist > cfg.TeleportDistance or petPos.Y < -50 then
			loco:Teleport(CFrame.new(followPos))
			return
		end

		if dist > cfg.StopDistance then
			-- TungTung-style pipeline: brain requests target at interval;
			-- locomotion controller handles repath throttling and target-move delta.
			loco:MoveTo(followPos)
		else
			loco:Stop()
		end
	end)


	local handle = {}
	function handle:Destroy()
		if conn then conn:Disconnect() end
		if loco then loco:Destroy() end
	end
	function handle:IsWalkAnimLoaded(): boolean
		return loco and loco:IsWalkAnimLoaded() or false
	end
	function handle:IsIdleAnimLoaded(): boolean
		return loco and loco:IsIdleAnimLoaded() or false
	end
	return handle
end

return PetFollowController
