--[[
	LocomotionController
	Reusable Humanoid + Animator movement controller copied from the TungTungSahur
	chase pipeline in `src/server/TungTungSahurService.luau`.

	TungTung parity points:
	  - Target loop cadence: `ChaseInterval = 0.2`
	  - MoveTo repath gate: `RepathInterval = 0.45`
	  - Repath on target movement: `RepathTargetMoveDelta = 4.0`
	  - Animator loading flow: Animator -> LoadAnimation -> Loop -> Play
]]

local LocomotionController = {}
LocomotionController.__index = LocomotionController

local DEFAULTS = {
	WalkSpeed = 14,
	HipHeight = 2.0,
	RepathInterval = 0.18,
	RepathTargetMoveDelta = 1.5,
	WalkAnimId = "rbxassetid://507777826", -- TungTung walk
	IdleAnimId = "rbxassetid://507766666", -- default Roblox idle
}

local function ensureRoot(model: Model): BasePart?
	local root = model:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		model.PrimaryPart = root
		return root
	end

	local primary = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	if not primary then
		return nil
	end

	-- Create a lightweight HumanoidRootPart and weld it to existing primary.
	local hrp = Instance.new("Part")
	hrp.Name = "HumanoidRootPart"
	hrp.Size = Vector3.new(2, 2, 1)
	hrp.Transparency = 1
	hrp.CanCollide = true
	hrp.CanQuery = false
	hrp.CanTouch = false
	hrp.Massless = false
	hrp.Anchored = false
	hrp.CFrame = primary.CFrame
	hrp.Parent = model

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = hrp
	weld.Part1 = primary
	weld.Parent = hrp

	model.PrimaryPart = hrp
	return hrp
end

local function ensureHumanoid(model: Model, root: BasePart?, walkSpeed: number, hipHeight: number): Humanoid?
	local hum = model:FindFirstChildOfClass("Humanoid")
	if not hum then
		hum = Instance.new("Humanoid")
		hum.Name = "Humanoid"
		hum.Parent = model
	end
	hum.WalkSpeed = walkSpeed
	local minHip = 2.0
	if root then
		minHip = math.max(2.0, (root.Size.Y * 0.5) + 0.5)
	end
	hum.HipHeight = math.max(hipHeight, minHip)
	hum.AutoRotate = true
	hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	hum.BreakJointsOnDeath = false
	hum.RequiresNeck = false
	hum.PlatformStand = false
	hum.MaxHealth = math.max(hum.MaxHealth, 1000)
	hum.Health = hum.MaxHealth
	pcall(function()
		hum:ChangeState(Enum.HumanoidStateType.Running)
	end)
	return hum
end

local function ensureAnimator(humanoid: Humanoid): Animator
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator then return animator end
	animator = Instance.new("Animator")
	animator.Parent = humanoid
	return animator
end

local function tryLoadTrack(animator: Animator, animId: string): AnimationTrack?
	if animId == "" then return nil end
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

local function resolveAnimId(model: Model, wanted: string, fallbackId: string): string
	if typeof(wanted) == "string" and wanted ~= "" then
		return wanted
	end
	local wantedLower = string.lower(fallbackId)
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Animation") then
			local n = string.lower(d.Name)
			local p = d.Parent and string.lower(d.Parent.Name) or ""
			if string.find(n, wantedLower, 1, true) or string.find(p, wantedLower, 1, true) then
				if d.AnimationId and d.AnimationId ~= "" then
					return d.AnimationId
				end
			end
		end
	end
	return ""
end

function LocomotionController.new(model: Model, opts)
	local self = setmetatable({}, LocomotionController)
	opts = opts or {}
	self._model = model
	self._cfg = {
		WalkSpeed = opts.WalkSpeed or DEFAULTS.WalkSpeed,
		HipHeight = opts.HipHeight or DEFAULTS.HipHeight,
		RepathInterval = opts.RepathInterval or DEFAULTS.RepathInterval,
		RepathTargetMoveDelta = opts.RepathTargetMoveDelta or DEFAULTS.RepathTargetMoveDelta,
		WalkAnimId = opts.WalkAnimId or DEFAULTS.WalkAnimId,
		IdleAnimId = opts.IdleAnimId or DEFAULTS.IdleAnimId,
	}

	self._root = ensureRoot(model)
	if not self._root then
		return self
	end
	if self._root then
		self._root.Anchored = false
		self._root.CanCollide = true
		self._root.Massless = false
	end
	self._humanoid = ensureHumanoid(model, self._root, self._cfg.WalkSpeed, self._cfg.HipHeight)
	self._animator = self._humanoid and ensureAnimator(self._humanoid) or nil
	local walkAnimId = resolveAnimId(model, self._cfg.WalkAnimId, "walk")
	local idleAnimId = resolveAnimId(model, self._cfg.IdleAnimId, "idle")
	self._walkTrack = self._animator and tryLoadTrack(self._animator, walkAnimId) or nil
	self._idleTrack = self._animator and tryLoadTrack(self._animator, idleAnimId) or nil
	self._moving = false
	self._lastMoveToAt = 0
	self._lastMoveTarget = nil
	self._runConn = nil
	if self._humanoid then
		self._runConn = self._humanoid.Running:Connect(function(speed)
			self:_setMoving(speed > 0.1)
		end)
	end
	self:_setMoving(false)
	return self
end

function LocomotionController:_setMoving(moving: boolean)
	if self._moving == moving then return end
	self._moving = moving
	if moving then
		if self._idleTrack then pcall(function() self._idleTrack:Stop() end) end
		if self._walkTrack then pcall(function() self._walkTrack:Play() end) end
	else
		if self._walkTrack then pcall(function() self._walkTrack:Stop() end) end
		if self._idleTrack then pcall(function() self._idleTrack:Play() end) end
	end
end

function LocomotionController:GetPosition(): Vector3?
	if self._root and self._root.Parent then
		return self._root.Position
	end
	if self._model and self._model.PrimaryPart then
		return self._model.PrimaryPart.Position
	end
	return nil
end

function LocomotionController:MoveTo(targetPos: Vector3)
	if not self._humanoid or not self._root then return end
	local now = tick()
	local lastTarget = self._lastMoveTarget
	local shouldRepath = false
	if (now - self._lastMoveToAt) >= self._cfg.RepathInterval then
		shouldRepath = true
	elseif lastTarget and (targetPos - lastTarget).Magnitude >= self._cfg.RepathTargetMoveDelta then
		shouldRepath = true
	elseif not lastTarget then
		shouldRepath = true
	end
	if not shouldRepath then return end
	self._humanoid:MoveTo(targetPos)
	self._lastMoveToAt = now
	self._lastMoveTarget = targetPos
end

function LocomotionController:Stop()
	if not self._humanoid then return end
	local pos = self:GetPosition()
	if pos then
		self._humanoid:MoveTo(pos)
	end
	self:_setMoving(false)
end

function LocomotionController:Teleport(targetCF: CFrame)
	if not self._model then return end
	self._model:PivotTo(targetCF)
	self:Stop()
end

function LocomotionController:Destroy()
	self:Stop()
	if self._walkTrack then pcall(function() self._walkTrack:Stop() end) end
	if self._idleTrack then pcall(function() self._idleTrack:Stop() end) end
	if self._runConn then
		self._runConn:Disconnect()
		self._runConn = nil
	end
	self._walkTrack = nil
	self._idleTrack = nil
	self._animator = nil
	self._humanoid = nil
	self._root = nil
end

function LocomotionController:IsWalkAnimLoaded(): boolean
	return self._walkTrack ~= nil
end

function LocomotionController:IsIdleAnimLoaded(): boolean
	return self._idleTrack ~= nil
end

return LocomotionController
