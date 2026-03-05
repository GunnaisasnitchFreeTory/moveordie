local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemCatalog = require(Shared:WaitForChild("ItemCatalog"))
local ItemModelRegistry = require(Shared:WaitForChild("ItemModelRegistry"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local EquipRemote = Remotes:WaitForChild("EquipWalkerPet")
local UnequipRemote = Remotes:WaitForChild("UnequipWalkerPet")

local TAG = "[SpecialPetMotorRig]"
local ROOT_FOLDER_NAME = "_EquippedPetsMotor"
local DEBUG_SPECIAL_PET_RIG = RunService:IsStudio()
local TARGET_MAX_DIM = 3.0
local SCALE_HARD_MAX = 5.0

local PET_SCALE_MULTIPLIER: { [string]: number } = {
	pet_pink_butterfly = 1.5,
	pet_glitched_dragon = 1.8,
	pet_dark_winged_dragon = 1.6, -- Music Winged Dragon
	pet_dark_falcon = 1.4, -- Dark Goblem
}

local TARGET_PETS: { [string]: boolean } = {
	pet_pink_butterfly = true,
	pet_glitched_dragon = true,
	pet_dark_winged_dragon = true, -- Music Winged Dragon
	pet_dark_falcon = true, -- Dark Goblem
}

local ORBIT_PETS: { [string]: boolean } = {
	pet_pink_butterfly = true,
	pet_glitched_dragon = true,
	pet_dark_winged_dragon = true,
}

local YAW_OVERRIDE_RAD: { [string]: number } = {
	pet_pink_butterfly = 0,
	pet_glitched_dragon = math.rad(90),
	pet_dark_winged_dragon = 0,
	pet_dark_falcon = math.rad(180),
}

type MotorInfo = {
	motor: Motor6D,
	mode: "wing_h" | "wing_v" | "arm",
	sign: number,
}

type ActiveEntry = {
	player: Player,
	petId: string,
	model: Model,
	root: BasePart,
	rootWeld: Weld,
	motors: { MotorInfo },
	orbitEnabled: boolean,
	t0: number,
	phase: number,
}

local _active: { [Player]: ActiveEntry } = {}
local _scaleApplyCountByModel: { [string]: number } = {}
local _spawnLoopCountByPlayer: { [number]: number } = {}

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
	local key = tostring(player.UserId)
	local folder = root:FindFirstChild(key)
	if folder and folder:IsA("Folder") then
		return folder
	end
	folder = Instance.new("Folder")
	folder.Name = key
	folder.Parent = root
	return folder
end

local function chooseRoot(model: Model): BasePart?
	local preferred = { "HumanoidRootPart", "Root", "RootPart", "Handle", "UpperTorso", "Torso", "LowerTorso" }
	for _, name in ipairs(preferred) do
		local p = model:FindFirstChild(name, true)
		if p and p:IsA("BasePart") then
			model.PrimaryPart = p
			return p
		end
	end

	local best: BasePart? = nil
	local bestVolume = -1
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			local v = d.Size.X * d.Size.Y * d.Size.Z
			if v > bestVolume then
				bestVolume = v
				best = d
			end
		end
	end
	if best then
		model.PrimaryPart = best
	end
	return best
end

local function sanitizeParts(model: Model)
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
		elseif d:IsA("Script") or d:IsA("LocalScript") then
			d:Destroy()
		end
	end
end

local function removePartJoints(model: Model, part: BasePart)
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Motor6D") or d:IsA("Weld") or d:IsA("WeldConstraint") then
			local p0 = (d :: any).Part0
			local p1 = (d :: any).Part1
			if p0 == part or p1 == part then
				d:Destroy()
			end
		end
	end
end

local function hasJointForPart(model: Model, part: BasePart): boolean
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Motor6D") or d:IsA("Weld") or d:IsA("WeldConstraint") then
			local p0 = (d :: any).Part0
			local p1 = (d :: any).Part1
			if p0 == part or p1 == part then
				return true
			end
		end
	end
	return false
end

local function ensureStaticWelds(model: Model, root: BasePart, skipParts: { [BasePart]: boolean })
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and d ~= root and not skipParts[d] then
			if not hasJointForPart(model, d) then
				local wc = Instance.new("WeldConstraint")
				wc.Name = "_PetStaticWeld"
				wc.Part0 = root
				wc.Part1 = d
				wc.Parent = root
			end
		end
	end
end

local function getMaxDim(model: Model): number
	local _, size = model:GetBoundingBox()
	return math.max(size.X, size.Y, size.Z, 0.01)
end

local function applyDeterministicScale(model: Model, petId: string)
	local baselineScale = model:GetAttribute("_baselineScale")
	if type(baselineScale) ~= "number" then
		baselineScale = model:GetScale()
		model:SetAttribute("_baselineScale", baselineScale)
	end

	local baselineMaxDim = model:GetAttribute("_baselineMaxDim")
	if type(baselineMaxDim) ~= "number" then
		baselineMaxDim = getMaxDim(model)
		model:SetAttribute("_baselineMaxDim", baselineMaxDim)
	end

	local normalizeMul = TARGET_MAX_DIM / math.max(baselineMaxDim, 0.01)
	local finalMul = normalizeMul * (PET_SCALE_MULTIPLIER[petId] or 1.0)
	finalMul = math.clamp(finalMul, 0.05, SCALE_HARD_MAX)

	local targetScale = (baselineScale :: number) * finalMul
	targetScale = math.clamp(targetScale, 0.01, SCALE_HARD_MAX)

	model:ScaleTo(targetScale)
	model:SetAttribute("_appliedScale", targetScale)
	model:SetAttribute("_scaleAppliedOnce", true)

	local key = tostring(model:GetDebugId())
	_scaleApplyCountByModel[key] = (_scaleApplyCountByModel[key] or 0) + 1

	if DEBUG_SPECIAL_PET_RIG and TARGET_PETS[petId] then
		local _, box = model:GetBoundingBox()
		local primarySize = model.PrimaryPart and model.PrimaryPart.Size or Vector3.zero
		print(string.format(
			"[PetScaleDbg] pet=%s scale=%.3f primarySize=<%.2f,%.2f,%.2f> bounds=<%.2f,%.2f,%.2f> appliedCount=%d",
			tostring(petId),
			targetScale,
			primarySize.X, primarySize.Y, primarySize.Z,
			box.X, box.Y, box.Z,
			_scaleApplyCountByModel[key]
		))
	end
end

local function motorFromRoot(root: BasePart, part: BasePart, name: string): Motor6D
	local m = Instance.new("Motor6D")
	m.Name = name
	m.Part0 = root
	m.Part1 = part
	m.C0 = root.CFrame:ToObjectSpace(part.CFrame)
	m.C1 = CFrame.new()
	m.Parent = root
	return m
end

local function collectAnimatedParts(model: Model, petId: string): ({ BasePart }, { MotorInfo })
	local parts: { BasePart } = {}
	local motors: { MotorInfo } = {}
	local root = model.PrimaryPart
	if not root then
		return parts, motors
	end

	local function addPart(part: BasePart, mode: "wing_h" | "wing_v" | "arm")
		removePartJoints(model, part)
		local localPos = root.CFrame:PointToObjectSpace(part.Position)
		local sign = localPos.X >= 0 and 1 or -1
		local m = motorFromRoot(root, part, "_PetAnimMotor_" .. part.Name)
		table.insert(parts, part)
		table.insert(motors, {
			motor = m,
			mode = mode,
			sign = sign,
		})
	end

	if petId == "pet_pink_butterfly" then
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") and d.Name == "ButterFlyWing" then
				addPart(d, "wing_h")
			end
		end
		if #motors == 0 then
			warn("[PetRigWarn] pet=Pink Butterfly missingPart=ButterFlyWing")
		end
	elseif petId == "pet_glitched_dragon" then
		local found = 0
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") and d.Name == "WingsFloatDrag" then
				addPart(d, "wing_v")
				found += 1
			end
		end
		if found == 0 then
			warn("[PetRigWarn] pet=Glitched Dragon missingPart=WingsFloatDrag")
		end
	elseif petId == "pet_dark_winged_dragon" then
		local found = 0
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") and (d.Name == "WingsFloat" or d.Name == "WingsFloat ") then
				addPart(d, "wing_v")
				found += 1
			end
		end
		if found == 0 then
			warn("[PetRigWarn] pet=Music Winged Dragon missingPart=WingsFloat")
		end
	elseif petId == "pet_dark_falcon" then
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") and string.find(string.lower(d.Name), "arm", 1, true) then
				addPart(d, "arm")
			end
		end
		if #motors == 0 then
			warn("[PetRigWarn] pet=Dark Goblem missingPart=Arm*")
		end
	end

	return parts, motors
end

local function petDisplayName(petId: string): string
	local petDef = ItemCatalog.Pets and ItemCatalog.Pets[petId]
	if petDef and type(petDef.name) == "string" and petDef.name ~= "" then
		return petDef.name
	end
	return petId
end

local function resolveSource(petId: string): Instance?
	local petDef = ItemCatalog.Pets and ItemCatalog.Pets[petId]
	if not petDef then
		return nil
	end

	if type(petDef.modelPath) == "string" and petDef.modelPath ~= "" then
		local byPath = ItemModelRegistry.Get(petDef.modelPath)
		if byPath then
			return byPath
		end
	end

	if type(petDef.modelName) == "string" and petDef.modelName ~= "" then
		local byName = ItemModelRegistry.GetByExactName(petDef.modelName)
		if byName then
			return byName
		end
		local byAlias = ItemModelRegistry.Get(petDef.modelName)
		if byAlias then
			return byAlias
		end
	end

	return nil
end

local function destroyFor(player: Player)
	local entry = _active[player]
	if not entry then
		return
	end
	if entry.model and entry.model.Parent then
		entry.model:Destroy()
	end
	_active[player] = nil
end

local function makeRootWeld(ownerHrp: BasePart, root: BasePart): Weld
	local weld = Instance.new("Weld")
	weld.Name = "_PetRootWeld"
	weld.Part0 = ownerHrp
	weld.Part1 = root
	weld.C1 = CFrame.new()
	weld.C0 = CFrame.new(3, 2.8, 2)
	weld.Parent = ownerHrp
	return weld
end

local function spawnFor(player: Player, petId: string)
	if not TARGET_PETS[petId] then
		destroyFor(player)
		return
	end

	local char = player.Character
	local ownerHrp = char and char:FindFirstChild("HumanoidRootPart")
	if not ownerHrp or not ownerHrp:IsA("BasePart") then
		return
	end

	local source = resolveSource(petId)
	if not source then
		warn(TAG, "source not found for", petId)
		return
	end

	destroyFor(player)

	local cloneInst = source:Clone()
	local model: Model
	if cloneInst:IsA("Model") then
		model = cloneInst
	elseif cloneInst:IsA("BasePart") then
		model = Instance.new("Model")
		model.Name = cloneInst.Name
		cloneInst.Parent = model
		model.PrimaryPart = cloneInst
	else
		local firstPart = cloneInst:FindFirstChildWhichIsA("BasePart", true)
		if not firstPart then
			cloneInst:Destroy()
			return
		end
		model = Instance.new("Model")
		model.Name = cloneInst.Name
		cloneInst.Parent = model
		model.PrimaryPart = firstPart
	end

	model.Name = "_MotorPet_" .. player.Name
	model:SetAttribute("IsPet", true)
	model:SetAttribute("_petId", petId)
	model:SetAttribute("_owner", player.Name)
	model:SetAttribute("_serverMotorRig", true)
	model.Parent = getPlayerFolder(player)

	sanitizeParts(model)

	local root = chooseRoot(model)
	if not root then
		model:Destroy()
		return
	end
	model.PrimaryPart = root
	pcall(function() root:SetNetworkOwner(nil) end)

	applyDeterministicScale(model, petId)

	local animatedParts, motors = collectAnimatedParts(model, petId)
	local skip: { [BasePart]: boolean } = {}
	for _, p in ipairs(animatedParts) do
		skip[p] = true
	end
	ensureStaticWelds(model, root, skip)

	local rootWeld = makeRootWeld(ownerHrp, root)
	root.CFrame = ownerHrp.CFrame * rootWeld.C0

	print(string.format("[PetRig] pet=%s root=%s motorsCreated=%d",
		petDisplayName(petId),
		root:GetFullName(),
		#motors))
	print(string.format("[PetAnim] pet=%s loopRunning=true", petDisplayName(petId)))
	print(string.format("[PetOrbit] pet=%s orbitEnabled=%s attachType=weld",
		petDisplayName(petId),
		tostring(ORBIT_PETS[petId] == true)))

	_active[player] = {
		player = player,
		petId = petId,
		model = model,
		root = root,
		rootWeld = rootWeld,
		motors = motors,
		orbitEnabled = ORBIT_PETS[petId] == true,
		t0 = tick(),
		phase = (player.UserId % 37) * 0.17,
	}

	_spawnLoopCountByPlayer[player.UserId] = (_spawnLoopCountByPlayer[player.UserId] or 0) + 1
	if DEBUG_SPECIAL_PET_RIG then
		print(string.format(
			"[PetSpawnDbg] pet=%s loopsCreated=%d motors=%d orbit=%s",
			petDisplayName(petId),
			_spawnLoopCountByPlayer[player.UserId],
			#motors,
			tostring(ORBIT_PETS[petId] == true)
		))
	end
end

local function updateEntry(entry: ActiveEntry, dt: number)
	local player = entry.player
	local char = player.Character
	local ownerHrp = char and char:FindFirstChild("HumanoidRootPart")
	if not ownerHrp or not ownerHrp:IsA("BasePart") then
		return
	end
	if not entry.model.Parent or not entry.root.Parent then
		return
	end
	if not entry.rootWeld.Parent then
		return
	end

	local t = tick() - entry.t0

	local yaw = YAW_OVERRIDE_RAD[entry.petId] or 0
	if entry.orbitEnabled then
		local radius = 4.2
		local orbitSpeed = 0.9
		local bobAmp = 0.9
		local bobSpeed = 2.1
		local theta = t * orbitSpeed + entry.phase
		local x = math.cos(theta) * radius
		local z = math.sin(theta) * radius
		local y = 2.6 + math.sin(t * bobSpeed + entry.phase) * bobAmp
		entry.rootWeld.C0 = CFrame.new(x, y, z) * CFrame.Angles(0, yaw, 0)
	else
		entry.rootWeld.C0 = CFrame.new(3, 2.8, 2) * CFrame.Angles(0, yaw, 0)
	end

	for _, info in ipairs(entry.motors) do
		if info.mode == "wing_h" then
			local flap = math.sin(t * 8.0) * math.rad(35)
			info.motor.Transform = CFrame.Angles(0, flap, 0)
		elseif info.mode == "wing_v" then
			local flap = math.sin(t * 7.0) * math.rad(30)
			info.motor.Transform = CFrame.Angles(flap * info.sign, 0, 0)
		elseif info.mode == "arm" then
			local sway = math.sin(t * 3.8 + info.sign * 0.2) * math.rad(18)
			info.motor.Transform = CFrame.Angles(0, 0, sway * info.sign)
		end
	end
end

local function syncFor(player: Player)
	local petId = player:GetAttribute("EquippedPet")
	if type(petId) ~= "string" or petId == "" then
		destroyFor(player)
		return
	end
	if not TARGET_PETS[petId] then
		destroyFor(player)
		return
	end

	local active = _active[player]
	if active and active.petId == petId and active.model.Parent then
		return
	end
	spawnFor(player, petId)
end

EquipRemote.OnServerEvent:Connect(function(player: Player, petId: string)
	if type(petId) ~= "string" then
		return
	end
	if not TARGET_PETS[petId] then
		return
	end
	if player:GetAttribute("EquippedPet") ~= petId then
		return
	end
	spawnFor(player, petId)
end)

UnequipRemote.OnServerEvent:Connect(function(player: Player)
	local equipped = player:GetAttribute("EquippedPet")
	if type(equipped) ~= "string" or equipped == "" or not TARGET_PETS[equipped] then
		destroyFor(player)
	end
end)

Players.PlayerAdded:Connect(function(player)
	player:GetAttributeChangedSignal("EquippedPet"):Connect(function()
		syncFor(player)
	end)
	player.CharacterAdded:Connect(function()
		task.wait(0.25)
		syncFor(player)
	end)
	player.CharacterRemoving:Connect(function()
		destroyFor(player)
	end)
	task.defer(function()
		syncFor(player)
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	destroyFor(player)
end)

for _, player in ipairs(Players:GetPlayers()) do
	task.defer(function()
		syncFor(player)
	end)
	player:GetAttributeChangedSignal("EquippedPet"):Connect(function()
		syncFor(player)
	end)
	player.CharacterAdded:Connect(function()
		task.wait(0.25)
		syncFor(player)
	end)
	player.CharacterRemoving:Connect(function()
		destroyFor(player)
	end)
end

RunService.Heartbeat:Connect(function(dt)
	for player, entry in pairs(_active) do
		if not player.Parent then
			destroyFor(player)
		else
			updateEntry(entry, dt)
		end
	end
end)
