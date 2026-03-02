--[[
	WalkerPetServerController
	Server-side walker pet NPC controller.

	Mirrors TungTungSahurService's exact loop/animation pattern but targets
	owner follow position instead of the nearest enemy.

	Loop parity (from TungTungSahurService):
	  - ChaseInterval   = 0.2   (task.wait between loop ticks)
	  - RepathInterval  = 0.45  (min seconds between MoveTo calls)
	  - RepathTargetMoveDelta = 4.0  (repath if target moved this many studs)
	  - WalkAnimId = "rbxassetid://507777826"
	  - Animation loaded via Humanoid -> Animator:LoadAnimation (exactly as TungTung)
	  - Network owner set to nil (server owns physics)

	Walker pets:
	  Bonnie / Chica / Foxy / FreddyFazbear

	API (called from InventoryService/AttributeChange watcher):
	  WalkerPetServerController.Init()
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")

local Shared            = ReplicatedStorage:WaitForChild("Shared")
local ItemCatalog       = require(Shared:WaitForChild("ItemCatalog"))
local ItemModelRegistry = require(Shared:WaitForChild("ItemModelRegistry"))

local Remotes           = ReplicatedStorage:WaitForChild("Remotes")
local EquipRemote       = Remotes:WaitForChild("EquipWalkerPet")
local UnequipRemote     = Remotes:WaitForChild("UnequipWalkerPet")

local AnimateTemplate   = Shared:WaitForChild("AnimateR15_NPC")

local TAG = "[WalkerPetSV]"

local WALK_SPEED        = 16
local FOLLOW_INTERVAL   = 0.15
local FOLLOW_DISTANCE   = 5
local STOP_DISTANCE     = 3
local TELEPORT_DISTANCE = 60
local HIP_HEIGHT        = 2.0
local ROOT_FOLDER_NAME  = "_EquippedPets"

-- ── Allowed walker pet model names (exactly as in ItemModels) ─────────────────
local WALKER_NAMES: { [string]: boolean } = {
	-- FNAF pets reverted to floating/bobble controller only.
	-- Intentionally empty so server walker spawner never handles them.
}

-- ── State ─────────────────────────────────────────────────────────────────────
-- _active[player] = { model, thread, walkTrack }
type ActiveEntry = {
	model: Model,
	thread: thread,
}

local _active: { [Player]: ActiveEntry } = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function getRootFolder(): Folder
	local root = Workspace:FindFirstChild(ROOT_FOLDER_NAME)
	if root and root:IsA("Folder") then
		return root
	end
	root = Instance.new("Folder")
	root.Name = ROOT_FOLDER_NAME
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

local function getPetDef(petId: string)
	if not petId or petId == "" then
		return nil
	end
	return ItemCatalog.Pets and ItemCatalog.Pets[petId]
end

local function getModelName(petId: string): string?
	local def = ItemCatalog.Pets and ItemCatalog.Pets[petId]
	if not def then return nil end
	if typeof(def.modelName) == "string" and def.modelName ~= "" then
		return def.modelName
	end
	return nil
end

local function ensureAnimator(humanoid: Humanoid): Animator
	local a = humanoid:FindFirstChildOfClass("Animator")
	if a then return a end
	a = Instance.new("Animator")
	a.Parent = humanoid
	return a
end

local function despawnFor(player: Player)
	local entry = _active[player]
	if not entry then return end
	pcall(function() task.cancel(entry.thread) end)
	if entry.model and entry.model.Parent then
		entry.model:Destroy()
	end
	_active[player] = nil
end

local function findHumanoid(model: Model): Humanoid?
	local direct = model:FindFirstChildOfClass("Humanoid")
	if direct then
		return direct
	end
	local nested = model:FindFirstChild("Humanoid", true)
	if nested and nested:IsA("Humanoid") then
		return nested
	end
	return nil
end

local function findHRP(model: Model): BasePart?
	local hrp = model:FindFirstChild("HumanoidRootPart", true)
	if hrp and hrp:IsA("BasePart") then
		return hrp
	end
	return nil
end

local function findFallbackRoot(model: Model, hum: Humanoid?): BasePart?
	if hum and hum.RootPart then
		return hum.RootPart
	end
	if model.PrimaryPart then
		return model.PrimaryPart
	end
	local anyPart = model:FindFirstChildWhichIsA("BasePart", true)
	if anyPart then
		return anyPart
	end
	return nil
end

local function normalizeWalkerRig(model: Model): (Model, Humanoid?, BasePart?)
	local hum = findHumanoid(model)
	local hrp = findHRP(model)

	-- If Humanoid is inside a nested rig model, normalize onto that model.
	if hum and hum.Parent and hum.Parent:IsA("Model") then
		model = hum.Parent
		hum = findHumanoid(model)
		hrp = findHRP(model)
	end

	-- Some imported rigs are missing Humanoid; create one so MoveTo works.
	if not hum then
		hum = Instance.new("Humanoid")
		hum.Name = "Humanoid"
		hum.Parent = model
	end

	if not hrp then
		hrp = findFallbackRoot(model, hum)
	end

	if hum and not hum:FindFirstChildOfClass("Animator") then
		local animator = Instance.new("Animator")
		animator.Parent = hum
	end

	if hrp then
		model.PrimaryPart = hrp
	end

	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.CanCollide = false
		end
	end

	return model, hum, hrp
end

local function isValidWalkerRig(model: Model, hum: Humanoid?, hrp: BasePart?): (boolean, string)
	if not hum then
		return false, "missing Humanoid"
	end
	if not hrp then
		return false, "missing root part"
	end
	if model.PrimaryPart ~= hrp then
		return false, "PrimaryPart not root"
	end
	return true, "ok"
end

local function injectAnimateScript(model: Model): boolean
	local existing = model:FindFirstChild("Animate")
	if existing and existing:IsA("Script") then
		existing:Destroy()
	end
	local clone = AnimateTemplate:Clone()
	clone.Name = "Animate"
	clone.Parent = model
	clone.Disabled = false
	return true
end

local function zeroPitchRoll(hrp: BasePart, faceYaw: number)
	local pos = hrp.Position
	hrp.CFrame = CFrame.new(pos) * CFrame.Angles(0, faceYaw, 0)
end

local function startFollowLoop(model: Model, player: Player, hum: Humanoid, hrp: BasePart): thread
	return task.spawn(function()
		while model.Parent do
			local char = player.Character
			local ownerHrp = char and char:FindFirstChild("HumanoidRootPart")
			if ownerHrp and ownerHrp:IsA("BasePart") and hum.Health > 0 and model.PrimaryPart then
				local targetPos = ownerHrp.Position - ownerHrp.CFrame.LookVector * FOLLOW_DISTANCE
				local petPos = model.PrimaryPart.Position
				local dist = (targetPos - petPos).Magnitude

				if dist > TELEPORT_DISTANCE or petPos.Y < -50 then
					local yaw = math.atan2(-ownerHrp.CFrame.LookVector.X, -ownerHrp.CFrame.LookVector.Z)
					hrp.CFrame = CFrame.new(targetPos + Vector3.new(0, 3, 0)) * CFrame.Angles(0, yaw, 0)
				elseif dist > STOP_DISTANCE then
					hum:MoveTo(targetPos)
				end
			end

			task.wait(FOLLOW_INTERVAL)
		end
	end)
end

local function spawnFor(player: Player, petId: string)
	despawnFor(player)

	local modelName = getModelName(petId)
	if not modelName or not WALKER_NAMES[modelName] then
		return
	end

	local petDef = getPetDef(petId)
	local sourceModel: Instance? = nil
	if petDef and typeof(petDef.modelPath) == "string" and petDef.modelPath ~= "" then
		sourceModel = ItemModelRegistry.Get(petDef.modelPath)
	end
	if not sourceModel then
		sourceModel = ItemModelRegistry.GetByExactName(modelName)
	end
	if not sourceModel then
		warn(TAG, "Model not found:", modelName)
		return
	end

	local char = player.Character
	local ownerHrp = char and char:FindFirstChild("HumanoidRootPart")
	if not ownerHrp then return end

	local clone = sourceModel:Clone() :: Model
	local sourcePath = sourceModel:GetFullName()
	clone:SetAttribute("IsPet", true)

	-- Disable embedded scripts on the PET clone so no internal hitbox/attack
	-- logic can damage players. Enemy asset remains unchanged.
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("Script") or d:IsA("LocalScript") then
			d.Disabled = true
		end
	end

	clone, hum, hrp = normalizeWalkerRig(clone)
	local okRig, reason = isValidWalkerRig(clone, hum, hrp)
	if not okRig then
		warn(TAG, string.format("Invalid walker rig: %s reason=%s source=%s",
			modelName, reason, sourcePath))
		clone:Destroy()
		return
	end

	-- Unanchor and disable collisions to avoid floor snagging.
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		end
	end
	hrp.CanCollide = false

	hum.WalkSpeed = WALK_SPEED
	hum.AutoRotate = true
	hum.PlatformStand = false
	hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	hum.BreakJointsOnDeath = false
	hum.RequiresNeck = false
	if hum.HipHeight < HIP_HEIGHT then
		hum.HipHeight = HIP_HEIGHT
	end

	ensureAnimator(hum)

	clone.Name = "_WalkerPet_" .. player.Name
	clone.Parent = getPlayerFolder(player)

	local targetPos = ownerHrp.Position - ownerHrp.CFrame.LookVector * FOLLOW_DISTANCE + Vector3.new(0, 3, 0)
	local yaw = math.atan2(-ownerHrp.CFrame.LookVector.X, -ownerHrp.CFrame.LookVector.Z)
	hrp.CFrame = CFrame.new(targetPos) * CFrame.Angles(0, yaw, 0)
	zeroPitchRoll(hrp, yaw)

	pcall(function() hrp:SetNetworkOwner(nil) end)
	local injected = injectAnimateScript(clone)
	local thread = startFollowLoop(clone, player, hum, hrp)
	_active[player] = { model = clone, thread = thread }

	local hasAnimator = hum:FindFirstChildOfClass("Animator") ~= nil
	print(string.format(
		"%s spawned %s HRP=%s Humanoid=%s Animator=%s AnimateInjected=%s",
		TAG,
		modelName,
		tostring(hrp ~= nil),
		tostring(hum ~= nil),
		tostring(hasAnimator),
		tostring(injected)
	))
end

-- ── Public API ────────────────────────────────────────────────────────────────
local WalkerPetServerController = {}

function WalkerPetServerController.Init()
	EquipRemote.OnServerEvent:Connect(function(player: Player, petId: string)
		if typeof(petId) ~= "string" then return end
		spawnFor(player, petId)
	end)

	UnequipRemote.OnServerEvent:Connect(function(player: Player)
		despawnFor(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		despawnFor(player)
	end)

	-- Re-spawn pet after character respawn
	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function()
			-- Small delay to let character fully load
			task.wait(1)
			local petId = player:GetAttribute("EquippedPet")
			if petId and petId ~= "" then
				local modelName = getModelName(petId)
				if modelName and WALKER_NAMES[modelName] then
					spawnFor(player, petId)
				end
			end
		end)
	end)

	for _, player in ipairs(Players:GetPlayers()) do
		player.CharacterAdded:Connect(function()
			task.wait(1)
			local petId = player:GetAttribute("EquippedPet")
			if petId and petId ~= "" then
				local modelName = getModelName(petId)
				if modelName and WALKER_NAMES[modelName] then
					spawnFor(player, petId)
				end
			end
		end)
	end

	print(TAG, "Initialized")
end

return WalkerPetServerController
