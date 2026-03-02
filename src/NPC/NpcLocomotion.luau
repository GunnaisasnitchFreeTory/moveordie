--[[
	NpcLocomotion
	Direct TungTungSahur locomotion/animation extraction for reuse.

	Core parity:
	  - Loop cadence: 0.2s
	  - MoveTo repath interval: 0.45s
	  - Repath target delta: 4.0 studs
	  - Walk animation loaded through Humanoid.Animator:LoadAnimation
]]

local RunService = game:GetService("RunService")

local NpcLocomotion = {}
NpcLocomotion.__index = NpcLocomotion

local DEFAULTS = {
	WalkSpeed = 26,
	ChaseInterval = 0.2,
	RepathInterval = 0.45,
	RepathTargetMoveDelta = 4.0,
	WalkAnimId = "rbxassetid://507777826",
	IdleAnimId = "rbxassetid://507766666",
	HipHeight = 2.0,
}

local function findRoot(model: Model): BasePart?
	local root = model:FindFirstChild("HumanoidRootPart", true)
	if root and root:IsA("BasePart") then
		model.PrimaryPart = root
		return root
	end
	local primary = model.PrimaryPart
	if primary and primary:IsA("BasePart") then
		return primary
	end
	return nil
end

local function ensureAnimator(humanoid: Humanoid): Animator
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator then
		return animator
	end
	animator = Instance.new("Animator")
	animator.Parent = humanoid
	return animator
end

local function loadTrack(humanoid: Humanoid, animId: string): AnimationTrack?
	local animator = ensureAnimator(humanoid)
	local anim = Instance.new("Animation")
	anim.AnimationId = animId
	local ok, track = pcall(function()
		return animator:LoadAnimation(anim)
	end)
	anim:Destroy()
	if ok and track then
		track.Looped = true
		return track
	end
	return nil
end

function NpcLocomotion.attach(model: Model, cfg)
	cfg = cfg or {}
	local self = setmetatable({}, NpcLocomotion)
	self._model = model
	self._cfg = {
		WalkSpeed = cfg.WalkSpeed or DEFAULTS.WalkSpeed,
		ChaseInterval = cfg.ChaseInterval or DEFAULTS.ChaseInterval,
		RepathInterval = cfg.RepathInterval or DEFAULTS.RepathInterval,
		RepathTargetMoveDelta = cfg.RepathTargetMoveDelta or DEFAULTS.RepathTargetMoveDelta,
		WalkAnimId = cfg.WalkAnimId or DEFAULTS.WalkAnimId,
		IdleAnimId = cfg.IdleAnimId or DEFAULTS.IdleAnimId,
		HipHeight = cfg.HipHeight or DEFAULTS.HipHeight,
	}
	self._target = nil :: Vector3?
	self._active = true
	self._acc = 0
	self._lastMoveToAt = 0
	self._lastMoveToTargetPos = nil :: Vector3?
	self._runConn = nil :: RBXScriptConnection?
	self._loopConn = nil :: RBXScriptConnection?
	self._walkTrack = nil :: AnimationTrack?
	self._idleTrack = nil :: AnimationTrack?
	self._isMoving = false

	local hum = model:FindFirstChildOfClass("Humanoid")
	if not hum then
		hum = Instance.new("Humanoid")
		hum.Parent = model
	end
	self._humanoid = hum
	self._root = findRoot(model)
	if self._root then
		model.PrimaryPart = self._root
	end

	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = false
		end
	end

	hum.WalkSpeed = self._cfg.WalkSpeed
	hum.AutoRotate = true
	hum.PlatformStand = false
	hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	hum.BreakJointsOnDeath = false
	hum.RequiresNeck = false
	if self._root then
		local minHip = math.max(2.0, (self._root.Size.Y * 0.5) + 0.5)
		hum.HipHeight = math.max(self._cfg.HipHeight, minHip)
	else
		hum.HipHeight = self._cfg.HipHeight
	end
	pcall(function()
		hum:ChangeState(Enum.HumanoidStateType.Running)
	end)

	self._walkTrack = loadTrack(hum, self._cfg.WalkAnimId)
	self._idleTrack = loadTrack(hum, self._cfg.IdleAnimId)
	if self._walkTrack then
		self._walkTrack.Looped = true
	end
	if self._idleTrack then
		self._idleTrack.Looped = true
	end

	local function setMoving(moving: boolean)
		if self._isMoving == moving then
			return
		end
		self._isMoving = moving
		if moving then
			if self._idleTrack and self._idleTrack.IsPlaying then
				pcall(function()
					self._idleTrack:Stop(0.2)
				end)
			end
			if self._walkTrack and not self._walkTrack.IsPlaying then
				pcall(function()
					self._walkTrack:Play(0.2)
				end)
			end
		else
			if self._walkTrack and self._walkTrack.IsPlaying then
				pcall(function()
					self._walkTrack:Stop(0.2)
				end)
			end
			if self._idleTrack and not self._idleTrack.IsPlaying then
				pcall(function()
					self._idleTrack:Play(0.2)
				end)
			end
		end
	end

	if self._idleTrack then
		pcall(function()
			self._idleTrack:Play(0.2)
		end)
	end

	self._runConn = hum.Running:Connect(function(speed)
		setMoving(speed > 0.5)
	end)

	self._loopConn = RunService.Heartbeat:Connect(function(dt)
		if not self._active then
			return
		end
		if not self._model or not self._model.Parent then
			return
		end
		self._acc += dt
		if self._acc < self._cfg.ChaseInterval then
			return
		end
		self._acc = 0

		local root = self._root
		local humanoid = self._humanoid
		if not root or not root.Parent or not humanoid or humanoid.Health <= 0 then
			return
		end

		local target = self._target
		if not target then
			humanoid:MoveTo(root.Position)
			return
		end

		local now = tick()
		local shouldRepath = false
		if (now - self._lastMoveToAt) >= self._cfg.RepathInterval then
			shouldRepath = true
		elseif self._lastMoveToTargetPos and (target - self._lastMoveToTargetPos).Magnitude >= self._cfg.RepathTargetMoveDelta then
			shouldRepath = true
		elseif not self._lastMoveToTargetPos then
			shouldRepath = true
		end

		if shouldRepath then
			humanoid:MoveTo(target)
			self._lastMoveToAt = now
			self._lastMoveToTargetPos = target
		end
	end)

	return self
end

function NpcLocomotion:SetTarget(targetPos: Vector3)
	self._target = targetPos
end

function NpcLocomotion:Stop()
	self._target = nil
	if self._humanoid and self._root then
		self._humanoid:MoveTo(self._root.Position)
	end
end

function NpcLocomotion:IsWalkAnimLoaded(): boolean
	return self._walkTrack ~= nil
end

function NpcLocomotion:IsIdleAnimLoaded(): boolean
	return self._idleTrack ~= nil
end

function NpcLocomotion:Destroy()
	self._active = false
	if self._loopConn then
		self._loopConn:Disconnect()
		self._loopConn = nil
	end
	if self._runConn then
		self._runConn:Disconnect()
		self._runConn = nil
	end
	if self._walkTrack then
		pcall(function()
			self._walkTrack:Stop()
		end)
		self._walkTrack = nil
	end
	if self._idleTrack then
		pcall(function()
			self._idleTrack:Stop()
		end)
		self._idleTrack = nil
	end
	self._humanoid = nil
	self._root = nil
	self._model = nil
end

return NpcLocomotion
