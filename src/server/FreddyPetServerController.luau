local Players = game:GetService("Players")
local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemCatalog = require(Shared:WaitForChild("ItemCatalog"))
local ItemModelRegistry = require(Shared:WaitForChild("ItemModelRegistry"))
local AnimateTemplate = Shared:WaitForChild("AnimateR15_NPC")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local EquipRemote = Remotes:WaitForChild("EquipFreddyPet")
local UnequipRemote = Remotes:WaitForChild("UnequipFreddyPet")

local TAG = "[FreddyPetSV]"
local PET_ID = "pet_freddy_fazbear"
local FOLLOW_DISTANCE = 5
local STOP_DISTANCE = 3
local LOOP_INTERVAL = 0.1
local WALK_SPEED = 26
local REPATH_INTERVAL = 0.5

type ActiveEntry = {
	model: Model,
	thread: thread,
}

local _active: {[Player]: ActiveEntry} = {}

local function log(...)
	print(TAG, ...)
end

local function getRootFolder(): Folder
	local root = Workspace:FindFirstChild("_EquippedPets")
	if root and root:IsA("Folder") then
		return root
	end
	root = Instance.new("Folder")
	root.Name = "_EquippedPets"
	root.Parent = Workspace
	return root
end

local function getPlayerFolder(player: Player): Folder
	local root = getRootFolder()
	local name = tostring(player.UserId)
	local f = root:FindFirstChild(name)
	if f and f:IsA("Folder") then
		return f
	end
	f = Instance.new("Folder")
	f.Name = name
	f.Parent = root
	return f
end

local function despawnFor(player: Player, reason: string?)
	local entry = _active[player]
	if not entry then
		if reason then
			log(string.format("despawn skip owner=%s reason=%s (no active)", player.Name, reason))
		end
		return
	end
	log(string.format("despawn owner=%s reason=%s model=%s", player.Name, tostring(reason), entry.model:GetFullName()))
	pcall(function() task.cancel(entry.thread) end)
	if entry.model and entry.model.Parent then
		entry.model:Destroy()
	end
	_active[player] = nil
end

local function isAnimateScript(inst: Instance): boolean
	local name = string.lower(inst.Name)
	return name == "animate"
end

local function isFreddyNativeAnimationDriver(inst: Instance): boolean
	if not inst:IsA("Script") then
		return false
	end
	if isAnimateScript(inst) then
		return true
	end
	-- Baseplate Freddy uses a script named "Script" with animation data.
	if inst.Name == "Script" then
		if inst:FindFirstChild("AnimSaves") then
			return true
		end
		local animCount = 0
		for _, d in ipairs(inst:GetDescendants()) do
			if d:IsA("Animation") then
				animCount += 1
				if animCount >= 2 then
					return true
				end
			end
		end
	end
	return false
end

local function hasTransformMover(model: Model): boolean
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BodyMover")
			or d:IsA("AlignPosition")
			or d:IsA("AlignOrientation")
			or d:IsA("LinearVelocity")
			or d:IsA("VectorForce")
			or d:IsA("LineForce")
			or d:IsA("Torque")
			or d:IsA("AngularVelocity")
			or d:IsA("RocketPropulsion")
		then
			return true
		end
	end
	return false
end

local function getAnimator(hum: Humanoid): Animator?
	local animator = hum:FindFirstChildOfClass("Animator")
	if animator then
		return animator
	end
	local found = hum:FindFirstChild("Animator")
	if found and found:IsA("Animator") then
		return found
	end
	return nil
end

local function getPlayingTrackSnapshot(animator: Animator?): (number, string)
	if not animator then
		return 0, "none"
	end
	local tracks = animator:GetPlayingAnimationTracks()
	local n = #tracks
	if n == 0 then
		return 0, "none"
	end
	local items = {}
	for i, t in ipairs(tracks) do
		if i > 4 then break end
		local aid = ""
		local anim = t.Animation
		if anim and anim.AnimationId then
			aid = anim.AnimationId
		end
		table.insert(items, (t.Name or "?") .. ":" .. aid)
	end
	return n, table.concat(items, ",")
end

local function computeFollowTarget(ownerHrp: BasePart): Vector3
	-- Keep Freddy behind and slightly to the side to avoid overlap with owner.
	return ownerHrp.Position
		- ownerHrp.CFrame.LookVector * FOLLOW_DISTANCE
		+ ownerHrp.CFrame.RightVector * 1.5
end

local function ensureAnimateScript(model: Model): string
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Script") and isFreddyNativeAnimationDriver(d) then
			d.Disabled = false
			return "native:" .. d.Name
		end
	end
	local existing = model:FindFirstChild("Animate")
	if existing and existing:IsA("Script") then
		existing:Destroy()
	end
	local s = AnimateTemplate:Clone()
	s.Name = "Animate"
	s.Parent = model
	s.Disabled = false
	return "template_fallback"
end

local function resolveFreddySource(): Instance?
	local petDef = ItemCatalog.Pets and ItemCatalog.Pets[PET_ID]
	if petDef and typeof(petDef.modelPath) == "string" and petDef.modelPath ~= "" then
		local byPath = ItemModelRegistry.Get(petDef.modelPath)
		if byPath then
			log("source found by path:", petDef.modelPath, "=>", byPath:GetFullName())
			return byPath
		end
		log("source miss by path:", petDef.modelPath)
	end
	local byName = ItemModelRegistry.GetByExactName("FreddyFazbear")
	if byName then
		log("source fallback by exact name =>", byName:GetFullName())
	else
		log("source miss by exact name: FreddyFazbear")
	end
	return byName
end

local function ensureFreddyRootPart(model: Model, hum: Humanoid): BasePart?
	-- 1) Prefer an actual HumanoidRootPart if present.
	local existing = model:FindFirstChild("HumanoidRootPart", true)
	if existing and existing:IsA("BasePart") then
		model.PrimaryPart = existing
		return existing
	end

	-- 2) Prefer Humanoid.RootPart if it's not UpperTorso.
	if hum.RootPart and hum.RootPart.Name ~= "UpperTorso" then
		model.PrimaryPart = hum.RootPart
		return hum.RootPart
	end

	-- 3) Try common alternate root names before creating a new HRP.
	for _, altName in ipairs({ "RootPart", "Root", "TorsoRoot", "HumanoidRoot" }) do
		local alt = model:FindFirstChild(altName, true)
		if alt and alt:IsA("BasePart") then
			model.PrimaryPart = alt
			return alt
		end
	end

	-- 4) Create a dedicated HumanoidRootPart and attach to rig root.
	local attachTo = hum.RootPart or model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	if not attachTo then
		return nil
	end

	local hrp = Instance.new("Part")
	hrp.Name = "HumanoidRootPart"
	hrp.Size = Vector3.new(2, 2, 1)
	hrp.Transparency = 1
	hrp.CanCollide = false
	hrp.CanQuery = false
	hrp.CanTouch = false
	hrp.Anchored = false
	hrp.Massless = false
	hrp.CFrame = attachTo.CFrame
	hrp.Parent = model

	local existingRootJoint = hrp:FindFirstChild("RootJoint")
	if existingRootJoint then
		existingRootJoint:Destroy()
	end
	local rootJoint = Instance.new("Motor6D")
	rootJoint.Name = "RootJoint"
	rootJoint.Part0 = hrp
	rootJoint.Part1 = attachTo
	rootJoint.C0 = CFrame.new()
	rootJoint.C1 = attachTo.CFrame:ToObjectSpace(hrp.CFrame)
	rootJoint.Parent = hrp

	model.PrimaryPart = hrp
	return hrp
end

local function limbHasMotor(model: Model, limbName: string): boolean
	local limb = model:FindFirstChild(limbName, true)
	if not limb or not limb:IsA("BasePart") then
		return false
	end
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Motor6D") and (d.Part0 == limb or d.Part1 == limb) then
			return true
		end
	end
	return false
end

local function auditRigJoints(model: Model): (number, number, number, string)
	local motorCount = 0
	local weldCount = 0
	local anchoredCount = 0
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Motor6D") then
			motorCount += 1
		elseif d:IsA("WeldConstraint") then
			weldCount += 1
		elseif d:IsA("BasePart") and d.Anchored then
			anchoredCount += 1
		end
	end
	local limbReport = string.format(
		"ll=%s rl=%s la=%s ra=%s",
		tostring(limbHasMotor(model, "LeftLowerLeg")),
		tostring(limbHasMotor(model, "RightLowerLeg")),
		tostring(limbHasMotor(model, "LeftUpperArm")),
		tostring(limbHasMotor(model, "RightUpperArm"))
	)
	return motorCount, weldCount, anchoredCount, limbReport
end

local function startFollowLoop(model: Model, owner: Player, hum: Humanoid, hrp: BasePart): thread
	return task.spawn(function()
		local path = PathfindingService:CreatePath({
			AgentRadius = 2,
			AgentHeight = 5,
			AgentCanJump = true,
		})
		local waypoints: { PathWaypoint } = {}
		local waypointIndex = 1
		local lastRepath = 0
		local lastProofLog = 0
		local baseMotorCount, _, _, _ = auditRigJoints(model)

		while model.Parent do
			local char = owner.Character
			local ownerHrp = char and char:FindFirstChild("HumanoidRootPart")
			if ownerHrp and ownerHrp:IsA("BasePart") and hum.Health > 0 and model.PrimaryPart then
				local target = computeFollowTarget(ownerHrp)
				local petPos = hrp.Position
				local dist = (target - petPos).Magnitude
				local now = tick()

				if dist > STOP_DISTANCE and (now - lastRepath >= REPATH_INTERVAL or waypointIndex > #waypoints) then
					lastRepath = now
					local ok = pcall(function()
						path:ComputeAsync(petPos, target)
					end)
					if ok and path.Status == Enum.PathStatus.Success then
						waypoints = path:GetWaypoints()
						waypointIndex = 2 -- 1 is current position
					else
						waypoints = {}
						waypointIndex = 1
					end
				end

				local moveTarget = target
				if waypointIndex <= #waypoints then
					moveTarget = waypoints[waypointIndex].Position
					if (moveTarget - petPos).Magnitude <= 2.5 then
						waypointIndex += 1
					end
				end

				if dist > STOP_DISTANCE then
					-- True humanoid locomotion: navigation via MoveTo + input vector via Move.
					hum:MoveTo(moveTarget)
					local moveVec = moveTarget - petPos
					if moveVec.Magnitude > 0.05 then
						hum:Move(moveVec.Unit, false)
					end
				else
					hum:Move(Vector3.zero, false)
				end

				if now - lastProofLog >= 1.0 then
					lastProofLog = now
					local stateName = tostring(hum:GetState())
					local moveMag = hum.MoveDirection.Magnitude
					local moverFound = hasTransformMover(model)
					local motorCount, weldCount, anchoredCount, limbReport = auditRigJoints(model)
					if motorCount < baseMotorCount then
						warn(TAG, string.format(
							"joint regression owner=%s motors=%d->%d welds=%d anchored=%d",
							owner.Name, baseMotorCount, motorCount, weldCount, anchoredCount
						))
					end
					local animator = getAnimator(hum)
					local trackCount, trackInfo = getPlayingTrackSnapshot(animator)
					local stationary = dist <= STOP_DISTANCE + 0.25
					local idleWhileStill = stationary and trackCount > 0
					log(string.format(
						"proof owner=%s state=%s moveDirMag=%.3f transformFollowRan=%s dist=%.2f animator=%s tracks=%d idleWhileStill=%s trackInfo=%s motors=%d welds=%d anchored=%d limbs=%s",
						owner.Name,
						stateName,
						moveMag,
						tostring(moverFound),
						dist,
						tostring(animator ~= nil),
						trackCount,
						tostring(idleWhileStill),
						trackInfo,
						motorCount,
						weldCount,
						anchoredCount,
						limbReport
					))
				end
			end
			task.wait(LOOP_INTERVAL)
		end
	end)
end

local function spawnFor(player: Player)
	log("spawn begin owner=", player.Name)
	despawnFor(player, "respawn")

	local source = resolveFreddySource()
	if not source then
		warn(TAG, "spawn abort: Freddy source model not found")
		return
	end
	local clone = source:Clone()
	log("clone created:", clone:GetFullName(), "class=", clone.ClassName)
	if not clone:IsA("Model") then
		local wrapper = Instance.new("Model")
		wrapper.Name = clone.Name
		clone.Parent = wrapper
		clone = wrapper
		log("clone wrapped to Model:", clone:GetFullName())
	end

	clone:SetAttribute("IsPet", true)
	clone:SetAttribute("MovementMode", "Humanoid")
	clone:SetAttribute("HumanoidPet", true)
	log("attribute set IsPet=true")

	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		elseif d:IsA("BodyMover")
			or d:IsA("AlignPosition")
			or d:IsA("AlignOrientation")
			or d:IsA("LinearVelocity")
			or d:IsA("VectorForce")
			or d:IsA("LineForce")
			or d:IsA("Torque")
			or d:IsA("AngularVelocity")
			or d:IsA("RocketPropulsion")
		then
			-- Remove transform/body movers that cause glide-like non-humanoid motion.
			d:Destroy()
		elseif d:IsA("Script") or d:IsA("LocalScript") then
			-- Keep only Freddy's native animation driver; disable all others.
			if d:IsA("Script") then
				d.Disabled = not isFreddyNativeAnimationDriver(d)
			else
				d.Disabled = true
			end
		end
	end

	local hum = clone:FindFirstChildOfClass("Humanoid")
	if not hum then
		hum = clone:FindFirstChild("Humanoid", true)
	end
	if not hum or not hum:IsA("Humanoid") then
		hum = Instance.new("Humanoid")
		hum.Parent = clone
		log("humanoid created on clone")
	end
	local hrp = ensureFreddyRootPart(clone, hum)
	if not hrp or not hrp:IsA("BasePart") then
		warn(TAG, "spawn abort: Freddy pet missing root part")
		clone:Destroy()
		return
	end

	clone.PrimaryPart = hrp
	hum.WalkSpeed = math.max(hum.WalkSpeed, WALK_SPEED)
	hum.AutoRotate = true
	hum.PlatformStand = false
	hum.HipHeight = math.max(hum.HipHeight, 2.0)

	local char = player.Character
	local ownerHrp = char and char:FindFirstChild("HumanoidRootPart")
	if not ownerHrp or not ownerHrp:IsA("BasePart") then
		warn(TAG, "spawn abort: owner missing HumanoidRootPart")
		clone:Destroy()
		return
	end

	clone.Name = "_FreddyPet_" .. player.Name
	clone.Parent = getPlayerFolder(player)
	log("parent set:", clone:GetFullName())
	clone.Destroying:Connect(function()
		log("destroying:", clone.Name, "owner=", player.Name)
	end)
	clone.AncestryChanged:Connect(function(_, parent)
		if not parent then
			log("ancestry nil:", clone.Name, "owner=", player.Name)
		end
	end)

	-- Explicit post-parent placement so model appears beside owner immediately.
	local spawnPos = ownerHrp.Position - ownerHrp.CFrame.LookVector * FOLLOW_DISTANCE + ownerHrp.CFrame.RightVector * 2 + Vector3.new(0, 2.5, 0)
	clone:PivotTo(CFrame.new(spawnPos))

	-- Debug verification block requested by user.
	local modelPos = clone:GetPivot().Position
	local dist = (modelPos - ownerHrp.Position).Magnitude
	log(string.format("post-spawn root=%s modelPos=(%.1f, %.1f, %.1f) distFromOwner=%.1f",
		hrp.Name, modelPos.X, modelPos.Y, modelPos.Z, dist))

	-- Safety clamp for visibility during debugging.
	if dist > 40 or modelPos.Y < -20 or modelPos.Y > 1500 then
		local safePos = ownerHrp.Position + ownerHrp.CFrame.RightVector * 3 + Vector3.new(0, 2.5, 0)
		clone:PivotTo(CFrame.new(safePos))
		local clampedPos = clone:GetPivot().Position
		log(string.format("visibility clamp applied pos=(%.1f, %.1f, %.1f)",
			clampedPos.X, clampedPos.Y, clampedPos.Z))
	end

	pcall(function() hrp:SetNetworkOwner(nil) end)
	log("network owner set to server")
	local animateSource = ensureAnimateScript(clone)
	log("animate source:", animateSource)
	log("transform movers present after sanitize:", hasTransformMover(clone))
	local motorCount, weldCount, anchoredCount, limbReport = auditRigJoints(clone)
	log(string.format(
		"rig audit motors=%d welds=%d anchored=%d limbs=%s",
		motorCount, weldCount, anchoredCount, limbReport
	))
	local animatorAfterSpawn = getAnimator(hum)
	local trackCountAfterSpawn, trackInfoAfterSpawn = getPlayingTrackSnapshot(animatorAfterSpawn)
	log(string.format(
		"spawn anim-proof animator=%s tracks=%d trackInfo=%s",
		tostring(animatorAfterSpawn ~= nil),
		trackCountAfterSpawn,
		trackInfoAfterSpawn
	))
	hum.StateChanged:Connect(function(_, newState)
		log("state changed:", tostring(newState))
	end)
	hum.Running:Connect(function(speed)
		if speed > 0.5 then
			log(string.format("running speed=%.2f", speed))
		end
	end)
	local thread = startFollowLoop(clone, player, hum, hrp)
	_active[player] = { model = clone, thread = thread }
	log("spawn success owner=", player.Name, "model=", clone.Name)
end

local FreddyPetServerController = {}

function FreddyPetServerController.Init()
	EquipRemote.OnServerEvent:Connect(function(player: Player)
		log("equip remote from", player.Name)
		spawnFor(player)
	end)
	UnequipRemote.OnServerEvent:Connect(function(player: Player)
		log("unequip remote from", player.Name)
		despawnFor(player, "remote_unequip")
	end)
	Players.PlayerRemoving:Connect(function(player)
		despawnFor(player, "player_removing")
	end)
	log("initialized")
end

return FreddyPetServerController

