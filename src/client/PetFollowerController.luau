--[[
	PetFollowerController
	Client-side pet follower — spawns equipped pet models for ALL visible
	players, with smooth follow + bobble animation.

	Each client renders pets for every player (reads their EquippedPet
	attribute). This keeps movement smooth while remaining server-authoritative
	for what is equipped.

	Follow behavior:
	  - Position = HumanoidRootPart * scaled offset + vertical bobble
	  - Orientation = HRP yaw (so pet faces same direction as player)
	  - Per-pet YawOffset for models whose forward axis differs
	  - Lerp each frame for smooth motion

	Pet models:
	  - Cloned from ItemModelRegistry (same source as thumbnails)
	  - All parts Anchored, CanCollide/CanQuery/CanTouch = false
	  - VFX (ParticleEmitters etc.) kept enabled (they work in Workspace)
	  - Forced to a max bounding-box size at spawn (smaller than player)

	Handles:
	  - Equip / unequip / swap (only one pet per player)
	  - Character respawn (re-spawns pet after respawn)
	  - Player leaving (cleans up pet)

	API:
	  PetFollowerController.Init()
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared            = ReplicatedStorage:WaitForChild("Shared")
local UIConfig          = require(Shared:WaitForChild("UIConfig"))
local ItemCatalog       = require(Shared:WaitForChild("ItemCatalog"))
local ItemModelRegistry = require(Shared:WaitForChild("ItemModelRegistry"))
local PetVisualConfig   = require(Shared:WaitForChild("PetVisualConfig"))
local ItemModelsFolder  = ReplicatedStorage:WaitForChild("ItemModels")

-- Walker pet remotes — server owns all physics/animation for walkers.
local _remotes       = ReplicatedStorage:WaitForChild("Remotes")
local _equipRemote   = _remotes:WaitForChild("EquipWalkerPet")
local _unequipRemote = _remotes:WaitForChild("UnequipWalkerPet")

local TAG = "[PetFollower]"
local PET_INSTANCE_NAME = "_EquippedPet"
local TUNGTUNG_PET_ID = "pet_tungtungsahur"
local FURRYHUGS_PET_ID = "pet_huggy_wuggy"

local PetFollowerController = {}

-- =====================================================================
-- FOLLOW TUNING
-- =====================================================================

local PET_OFFSET          = CFrame.new(3, 2.5, 2)   -- offset from HumanoidRootPart
local LERP_ALPHA          = 0.08                      -- interpolation speed per frame
local BOBBLE_SPEED        = 3.0                       -- vertical sine frequency
local BOBBLE_AMPLITUDE    = 0.4                       -- vertical sine amplitude (studs)
local YAW_WOBBLE_SPEED    = 1.5
local YAW_WOBBLE_AMP      = 5                         -- degrees
local ROLL_WOBBLE_SPEED   = 2.0
local ROLL_WOBBLE_AMP     = 3                         -- degrees

-- =====================================================================
-- PER-PET OVERRIDES
-- =====================================================================

-- Yaw correction (degrees) for models whose local "face" points the wrong way.
-- When a pet looks backwards while the player faces the camera, add 180 here.
-- When sideways, add 90 or -90, etc.  Default (absent) = 0.
-- Most Blender-exported models face +Z; Roblox forward is -Z → 180° flip.
local PET_YAW_OFFSET_DEG: { [string]: number } = {
	pet_dog              = 180,
	pet_crocodile        = 180,
	pet_rabbit           = 180,
	pet_eagle            = 180,
	pet_scorpion         = 180,
	pet_shark            = -90,  -- faces along X-axis, not Z
	pet_bat              = 180,
	pet_dolphin          = 180,
	pet_pink_butterfly   = -90,  -- faces along X-axis, not Z
	-- Steve rig forward axis requires inverse yaw to face forward in float mode.
	pet_steve            = -90,
	-- Chica float rig forward axis differs; lock with explicit yaw correction.
	pet_chica            = -90,
	-- NOTE: pet_the_puppet rotation handled via PetVisualConfig.OVERRIDES
}

-- Pets that should not receive roll wobble (keeps large/rigged models visually stable).
local PET_NO_ROLL_WOBBLE: { [string]: boolean } = {
	pet_chica            = true,
	pet_foxy             = true,
	pet_bonnie           = true,
	pet_freddy_fazbear   = true,
	pet_golden_freddy    = true,
	pet_the_puppet       = true,
	pet_cupcake          = true,
}

-- Scale override: bypasses auto-scaling for models that need special treatment.
-- Value is used as a raw multiplier on the model's original scale.
local PET_SCALE_OVERRIDES: { [string]: number } = {
	-- Keep base normalization path unchanged for these; massive scaling is applied
	-- later at final spawn stage so it cannot be re-normalized back down.
	pet_huggy_wuggy = 1.0,
	pet_glitched_dragon = 1.0,
	pet_dark_falcon = 1.0,        -- Dark Goblem
	pet_pink_butterfly = 1.0,
	pet_dark_winged_dragon = 1.0, -- Music Winged Dragon
}

local PET_MASSIVE_SCALE_TARGETS: { [string]: boolean } = {
	pet_glitched_dragon = true,
	pet_dark_falcon = true,
	pet_pink_butterfly = true,
	pet_dark_winged_dragon = true,
}

local PET_FINAL_SPAWN_SCALE_MULTIPLIER: { [string]: number } = {
	pet_huggy_wuggy = 1.8,
	pet_glitched_dragon = 3.5, -- slight shrink only
	pet_dark_falcon = 2.8,        -- Dark Goblem
	pet_pink_butterfly = 2.6,
	pet_dark_winged_dragon = 2.8, -- Music Winged Dragon
}

local MOVEMENT_HOVER = "HOVER"
local MOVEMENT_WALKER = "WALKER_R15"
local MOVEMENT_SERVER_MOTOR = "SERVER_MOTOR_RIG"

local SERVER_MOTOR_PET_IDS: { [string]: boolean } = {
	pet_pink_butterfly = true,
	pet_glitched_dragon = true,
	pet_dark_winged_dragon = true, -- Music Winged Dragon
	pet_dark_falcon = true, -- Dark Goblem
}

local PET_MOVEMENT_TYPE: { [string]: string } = {
	-- Reverted to floating/bobble path
	Bonnie = MOVEMENT_HOVER,
	Chica = MOVEMENT_HOVER,
	Foxy = MOVEMENT_HOVER,
	FreddyFazbear = MOVEMENT_HOVER,

	-- HOVERS (must remain existing bobble path)
	GoldenFreddy = MOVEMENT_HOVER,
	ThePuppet = MOVEMENT_HOVER,
	Cupcake = MOVEMENT_HOVER,
}

-- FNAF pets explicitly reverted to floating companions.
local FNAF_REVERTED_FLOAT_IDS: { [string]: boolean } = {
	-- Keep empty: reverted float pets should use the normal anchored hover
	-- follower path for runtime stability during match transitions.
}

-- Final follow-transform rotation fixes for hover-only path.
local PET_ROTATION_FIX: { [string]: CFrame } = {
	-- Chica tilt is lateral in float mode; correct on roll axis.
	pet_chica = CFrame.Angles(0, 0, math.rad(14)),
}

-- Explicit equip offsets for outlier models only.
-- Mirrors the existing "finalCF = uprightCF * perPetOffset" pattern.
local PET_EQUIP_OFFSET_CFRAME: { [string]: CFrame } = {
	-- Huggy also needs a small vertical settle to avoid appearing offset.
	pet_huggy_wuggy = CFrame.new(0, -0.35, 0) * CFrame.Angles(0, math.rad(180), 0),
}

-- Deterministic orientation target list (ONLY these pets).
local DETERMINISTIC_PET_IDS: { [string]: boolean } = {
	pet_crocodile = true,
	pet_shark = true,
	pet_dog = true,
	pet_parrot = true,
	pet_penguin = true,
	pet_rabbit = true,
	pet_eagle = true,
	pet_ray_fish = true,
	pet_scorpion = true,
	pet_spider = true,
	pet_axolotl = true,
	pet_bat = true,
	pet_fredbear_plush = true,
	pet_steve = true,
	pet_huggy_wuggy = true,
	pet_glitched_dragon = true,
	pet_dark_falcon = true,
	pet_pink_butterfly = true,
	pet_dark_winged_dragon = true,
}

-- Per-pet deterministic rotation overrides (identity by default).
-- Only listed pets are allowed here.
local PET_DETERMINISTIC_ROTATION_OVERRIDES: { [string]: CFrame } = {
	pet_crocodile = CFrame.new(),
	pet_shark = CFrame.new(),
	pet_dog = CFrame.new(),
	pet_parrot = CFrame.new(),
	pet_penguin = CFrame.new(),
	pet_rabbit = CFrame.new(),
	pet_eagle = CFrame.new(),
	pet_ray_fish = CFrame.new(),
	pet_scorpion = CFrame.Angles(0, math.rad(180), 0),
	pet_spider = CFrame.new(),
	pet_axolotl = CFrame.new(),
	pet_bat = CFrame.new(),
	pet_fredbear_plush = CFrame.Angles(0, math.rad(-90), 0),
	pet_steve = CFrame.new(),
	pet_huggy_wuggy = CFrame.Angles(0, math.rad(180), 0),
	pet_glitched_dragon = CFrame.Angles(0, math.rad(90), 0),
	pet_dark_falcon = CFrame.Angles(0, math.rad(180), 0),
	pet_pink_butterfly = CFrame.new(),
	pet_dark_winged_dragon = CFrame.new(),
}

-- =====================================================================
-- SIZE NORMALIZATION
-- =====================================================================

local TARGET_MAX_DIM = 3.0   -- max bounding-box dimension (studs); player is ~5
local SCALE_FLOOR    = 0.02  -- never scale below this (prevents invisible pets)
local SCALE_CEIL     = 1.0   -- never scale above original size

local TUNGTUNG_EMOTE_INTERVAL_MIN = 10
local TUNGTUNG_EMOTE_INTERVAL_MAX = 18
local TUNGTUNG_EMOTE_PRIORITY = Enum.AnimationPriority.Action4
local TUNGTUNG_DEBUG_TAG = "[TungTungPetEmote]"
local TUNGTUNG_TRACK_READY_TIMEOUT = 1.0
local TUNGTUNG_EMOTE_FADE_IN = 0.28
local TUNGTUNG_EMOTE_FADE_OUT = 0.24
local TUNGTUNG_EMOTE_PRE_BLEND_WAIT = 0.08
local TUNGTUNG_EMOTE_POST_BLEND_HOLD = 0.16
local TUNGTUNG_EMOTE_ROOT_LERP_ALPHA = 0.32
local TUNGTUNG_LAUGH_ALIASES = { "laugh", "laughing", "emote_laugh" }
local TUNGTUNG_LAUGH_FALLBACK_IDS = {
	"rbxassetid://507770818",
}
local TUNGTUNG_LAUGH_FADE_IN = 0.15
local TUNGTUNG_LAUGH_FADE_OUT = 0.18
local TUNGTUNG_LAUGH_DEFAULT_DURATION = 2.2
local TUNGTUNG_EMOTE_SPECS = {
	{
		label = "Dance1",
		aliases = { "dance1", "dance" },
		fallbackIds = {
			"rbxassetid://507771019",
			"rbxassetid://507771955",
			"rbxassetid://507772104",
		},
		looped = true,
		duration = 4.8,
	},
	{
		label = "Dance2",
		aliases = { "dance2" },
		fallbackIds = {
			"rbxassetid://507776043",
			"rbxassetid://507776720",
			"rbxassetid://507776879",
		},
		looped = true,
		duration = 4.8,
	},
	{
		label = "Dance3",
		aliases = { "dance3" },
		fallbackIds = {
			"rbxassetid://507777268",
			"rbxassetid://507777451",
			"rbxassetid://507777623",
		},
		looped = true,
		duration = 4.8,
	},
}
local SHARED_PET_EMOTE_IDS = {
	[TUNGTUNG_PET_ID] = true,
	[FURRYHUGS_PET_ID] = true,
}
local PET_EMOTE_ROOT_DRIVE_IDS = {
	[TUNGTUNG_PET_ID] = true,
}

-- =====================================================================
-- STATE (per-player pet tracking)
-- =====================================================================

local _activePets: { [Player]: {
	pet: Instance?,
	conn: RBXScriptConnection?,
	pos: Vector3,
	t0: number,
	mover: any?,
	emoteThread: thread?,
	emoteActive: boolean?,
	emoteTrack: AnimationTrack?,
	emoteRoot: BasePart?,
	_isWalker: boolean?,
	_walkerPetId: string?,
	_isServerMotor: boolean?,
	_serverMotorPetId: string?,
} } = {}

local _playerConns: { [Player]: { RBXScriptConnection } } = {}
local _matchRoundConn: RBXScriptConnection? = nil
local _killFeedConn: RBXScriptConnection? = nil
local _trackedRoundNumber = 0
local _sawDeathThisRound = false
local _laughedThisRound = false

local DEBUG_LOGS = RunService:IsStudio() and UIConfig.DebugLogs == true
local LOG_RATE_SECONDS = tonumber(UIConfig.LogRateSeconds) or 20
local _lastLogByKey: { [string]: number } = {}
local _countByKey: { [string]: number } = {}

local function shouldLog(key: string, everySeconds: number?, everyN: number?): boolean
	if not DEBUG_LOGS then
		return false
	end
	local now = tick()
	local minInterval = everySeconds or LOG_RATE_SECONDS
	local last = _lastLogByKey[key] or 0
	if now - last >= minInterval then
		_lastLogByKey[key] = now
		_countByKey[key] = (_countByKey[key] or 0) + 1
		return true
	end
	if everyN and everyN > 0 then
		local count = (_countByKey[key] or 0) + 1
		_countByKey[key] = count
		if count % everyN == 0 then
			_lastLogByKey[key] = now
			return true
		end
	end
	return false
end

local function log(key: string, ...)
	if shouldLog(key) then
		print(TAG, ...)
	end
end

-- =====================================================================
-- HELPERS
-- =====================================================================

--- Get the bounding-box size of a model (or BasePart).
--- Returns nil on failure.
local function getBBoxSize(inst: Instance): Vector3?
	if inst:IsA("Model") then
		local ok, _, sz = pcall(inst.GetBoundingBox, inst)
		if ok and typeof(sz) == "Vector3" then return sz end
		-- Fallback to GetExtentsSize
		local ok2, ext = pcall(inst.GetExtentsSize, inst)
		if ok2 and typeof(ext) == "Vector3" then return ext end
		return nil
	elseif inst:IsA("BasePart") then
		return inst.Size
	end
	return nil
end

--- Apply uniform scale to a model or part.  Returns true on success.
--- For Models: prefers ScaleTo, falls back to manual descendant scaling.
--- For BaseParts: scales Size + SpecialMesh.Scale + Attachment positions.
local function applyScale(inst: Instance, factor: number): boolean
	if factor == 1 then return true end
	if inst:IsA("Model") then
		local ok = pcall(function()
			local cur = inst:GetScale()
			inst:ScaleTo(cur * factor)
		end)
		if ok then return true end
		-- Fallback: scale descendants manually
		for _, d in ipairs(inst:GetDescendants()) do
			if d:IsA("BasePart") then
				d.Size = d.Size * factor
			elseif d:IsA("DataModelMesh") then
				d.Scale = d.Scale * factor
				if d:FindFirstAncestorWhichIsA("BasePart") then
					d.Offset = d.Offset * factor
				end
			elseif d:IsA("Attachment") then
				d.Position = d.Position * factor
			end
		end
		return true
	elseif inst:IsA("BasePart") then
		inst.Size = inst.Size * factor
		-- Also scale child meshes (SpecialMesh etc.) and attachments
		for _, d in ipairs(inst:GetDescendants()) do
			if d:IsA("DataModelMesh") then
				d.Scale = d.Scale * factor
				d.Offset = d.Offset * factor
			elseif d:IsA("Attachment") then
				d.Position = d.Position * factor
			end
		end
		return true
	end
	return false
end

--- Extract yaw-only (Y-axis rotation) from a CFrame.
local function yawOnly(cf: CFrame): number
	local _, ry, _ = cf:ToEulerAnglesYXZ()
	return ry
end

-- =====================================================================
-- PET SPAWN / DESTROY
-- =====================================================================

local function getPetDef(petId: string)
	if not petId or petId == "" then return nil end
	return ItemCatalog.Pets and ItemCatalog.Pets[petId]
end

local function getConfiguredPetModelName(petId: string, petDef): string
	if petDef and typeof(petDef.modelName) == "string" and petDef.modelName ~= "" then
		return petDef.modelName
	end
	if petDef and typeof(petDef.name) == "string" and petDef.name ~= "" then
		return petDef.name
	end
	return petId
end

local function getMovementType(petId: string, petDef): string
	if SERVER_MOTOR_PET_IDS[petId] then
		return MOVEMENT_SERVER_MOTOR
	end
	local modelName = getConfiguredPetModelName(petId, petDef)
	local explicit = PET_MOVEMENT_TYPE[modelName]
	if explicit then return explicit end
	if petDef and petDef.collection == "FNAF" then
		-- Explicit safety: unspecified FNAF defaults to hover, not walker.
		return MOVEMENT_HOVER
	end
	return MOVEMENT_HOVER
end

local function useWalkingFollower(petId: string, petDef): boolean
	return getMovementType(petId, petDef) == MOVEMENT_WALKER
end

local function shouldUseExactNameLookup(modelName: string): boolean
	-- Reverted FNAF float pets must resolve via explicit modelPath to avoid
	-- exact-name collisions with unrelated large world/NPC assets.
	if modelName == "Bonnie"
		or modelName == "Chica"
		or modelName == "Foxy"
		or modelName == "FreddyFazbear"
	then
		return false
	end
	return PET_MOVEMENT_TYPE[modelName] ~= nil
end

local function findHumanoidInModel(model: Model): Humanoid?
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

local function findAnimationControllerInModel(model: Model): AnimationController?
	local direct = model:FindFirstChildOfClass("AnimationController")
	if direct then
		return direct
	end
	local nested = model:FindFirstChild("AnimationController", true)
	if nested and nested:IsA("AnimationController") then
		return nested
	end
	return nil
end

local function findTungTungDriveRoot(model: Model, humanoid: Humanoid?): BasePart?
	local hrp = model:FindFirstChild("HumanoidRootPart", true)
	if hrp and hrp:IsA("BasePart") then
		return hrp
	end
	if humanoid and humanoid.RootPart then
		return humanoid.RootPart
	end
	if model.PrimaryPart then
		return model.PrimaryPart
	end
	return model:FindFirstChildWhichIsA("BasePart", true)
end

local function isSharedPetEmoteEnabled(petId: string?): boolean
	return petId ~= nil and SHARED_PET_EMOTE_IDS[petId] == true
end

local function shouldUseEmoteRootDrive(petId: string?): boolean
	return petId ~= nil and PET_EMOTE_ROOT_DRIVE_IDS[petId] == true
end

local function modelHasMotor6D(model: Model): boolean
	return model:FindFirstChildWhichIsA("Motor6D", true) ~= nil
end

local function sanitizeFollowerRigArtifacts(model: Model, petId: string)
	if petId ~= FURRYHUGS_PET_ID then
		return
	end
	if modelHasMotor6D(model) then
		return
	end
	local humanoid = findHumanoidInModel(model)
	if humanoid then
		humanoid:Destroy()
	end
	local hrp = model:FindFirstChild("HumanoidRootPart", true)
	if hrp and hrp:IsA("BasePart") then
		hrp:Destroy()
	end
	if not model.PrimaryPart then
		local firstPart = model:FindFirstChildWhichIsA("BasePart", true)
		if firstPart then
			model.PrimaryPart = firstPart
		end
	end
	print(string.format(
		"[FurryHugsPetEmote] event=rig_sanitized_for_follow clone=%s motorsPresent=false",
		model:GetFullName()
	))
end

local function ensureAnimatorForPet(model: Model): (Humanoid?, Animator?, string)
	local humanoid = findHumanoidInModel(model)
	if humanoid then
		local animator = humanoid:FindFirstChildOfClass("Animator")
		if not animator then
			animator = Instance.new("Animator")
			animator.Parent = humanoid
		end
		return humanoid, animator, "Humanoid"
	end

	local controller = findAnimationControllerInModel(model)
	if not controller then
		controller = Instance.new("AnimationController")
		controller.Name = "PetAnimationController"
		controller.Parent = model
	end

	local animator = controller:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = controller
	end
	return nil, animator, "AnimationController"
end

local function collectAnimationIdsByAliases(model: Model, aliases: { string }): { string }
	local found: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Animation") and type(d.AnimationId) == "string" and d.AnimationId ~= "" then
			local lowerName = string.lower(d.Name)
			local lowerParent = d.Parent and string.lower(d.Parent.Name) or ""
			for _, alias in ipairs(aliases) do
				local lowerAlias = string.lower(alias)
				if string.find(lowerName, lowerAlias, 1, true) or string.find(lowerParent, lowerAlias, 1, true) then
					if not seen[d.AnimationId] then
						seen[d.AnimationId] = true
						table.insert(found, d.AnimationId)
					end
					break
				end
			end
		end
	end
	return found
end

local function loadPetAnimationTrack(
	animator: Animator,
	animationIds: { string },
	looped: boolean
): (AnimationTrack?, string?)
	for _, animationId in ipairs(animationIds) do
		if type(animationId) == "string" and animationId ~= "" then
			local anim = Instance.new("Animation")
			anim.AnimationId = animationId
			local ok, track = pcall(function()
				return animator:LoadAnimation(anim)
			end)
			anim:Destroy()
			if ok and track then
				track.Looped = looped
				track.Priority = TUNGTUNG_EMOTE_PRIORITY
				return track, animationId
			end
		end
	end
	return nil, nil
end

local function waitForTrackReady(track: AnimationTrack, timeoutSeconds: number): number
	local startedAt = tick()
	local length = track.Length
	while length <= 0 and (tick() - startedAt) < timeoutSeconds do
		task.wait(0.05)
		length = track.Length
	end
	return length
end

local function isTrackPlaying(animator: Animator, track: AnimationTrack): (boolean, number)
	local playing = animator:GetPlayingAnimationTracks()
	for _, activeTrack in ipairs(playing) do
		if activeTrack == track then
			return true, #playing
		end
	end
	return false, #playing
end

local function setTungTungDriveRoot(root: BasePart, targetCF: CFrame)
	root.CFrame = root.CFrame:Lerp(targetCF, TUNGTUNG_EMOTE_ROOT_LERP_ALPHA)
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
end

local function setTungTungEmoteState(player: Player, clone: Model, isActive: boolean, track: AnimationTrack?, root: BasePart?)
	local entry = _activePets[player]
	if entry and entry.pet == clone then
		entry.emoteActive = isActive
		entry.emoteTrack = if isActive then track else nil
		entry.emoteRoot = root
	end
end

local function buildTungTungEmoteTracks(model: Model, animator: Animator, player: Player, petId: string)
	local loaded = {}
	for _, spec in ipairs(TUNGTUNG_EMOTE_SPECS) do
		local animationIds = collectAnimationIdsByAliases(model, spec.aliases)
		local source = "model"
		if #animationIds == 0 then
			animationIds = spec.fallbackIds
			source = "fallback"
		end
		local track, animationId = loadPetAnimationTrack(animator, animationIds, spec.looped)
		local trackLength = 0
		if track then
			trackLength = waitForTrackReady(track, TUNGTUNG_TRACK_READY_TIMEOUT)
		end
		print(string.format(
			"%s owner=%s event=track_loaded pet=%s emote=%s animationId=%s source=%s loadSucceeded=%s trackLength=%.3f",
			TUNGTUNG_DEBUG_TAG,
			player.Name,
			petId,
			spec.label,
			tostring(animationId or "nil"),
			source,
			tostring(track ~= nil),
			trackLength
		))
		if track then
			table.insert(loaded, {
				label = spec.label,
				track = track,
				duration = spec.duration,
				animationId = animationId,
				source = source,
				trackLength = trackLength,
			})
		end
	end
	return loaded
end

local function stopTungTungEmoteTracks(loadedTracks)
	for _, entry in ipairs(loadedTracks) do
		if entry.track then
			pcall(function()
				entry.track:Stop(TUNGTUNG_EMOTE_FADE_OUT)
			end)
		end
	end
end

local function startTungTungPetEmoteLoop(clone: Model, player: Player, petIdOverride: string?): thread?
	local petId = petIdOverride or TUNGTUNG_PET_ID
	local humanoid = findHumanoidInModel(clone)
	local ensuredHumanoid, animator, animationDriver = ensureAnimatorForPet(clone)
	humanoid = ensuredHumanoid or humanoid
	local driveRoot = findTungTungDriveRoot(clone, humanoid)
	local hasAnimator = animator ~= nil

	print(string.format(
		"%s owner=%s event=spawn pet=%s humanoid=%s animator=%s driver=%s clone=%s root=%s",
		TUNGTUNG_DEBUG_TAG,
		player.Name,
		petId,
		tostring(humanoid ~= nil),
		tostring(hasAnimator),
		tostring(animationDriver),
		clone:GetFullName(),
		tostring(driveRoot and driveRoot:GetFullName() or "nil")
	))

	if not animator then
		warn(string.format(
			"%s owner=%s event=loop_not_started reason=missing_animator",
			TUNGTUNG_DEBUG_TAG,
			player.Name
		))
		return nil
	end

	local loadedTracks = buildTungTungEmoteTracks(clone, animator, player, petId)
	if #loadedTracks == 0 then
		warn(string.format(
			"%s owner=%s event=loop_not_started reason=no_tracks_loaded humanoid=%s animator=%s driver=%s",
			TUNGTUNG_DEBUG_TAG,
			player.Name,
			tostring(humanoid ~= nil),
			tostring(hasAnimator),
			tostring(animationDriver)
		))
		return nil
	end

	if humanoid then
		humanoid.AutoRotate = false
		humanoid.PlatformStand = false
	end
	if petId == FURRYHUGS_PET_ID then
		print(string.format(
			"[FurryHugsPetEmote] owner=%s event=initialized_for_emotes clone=%s humanoid=%s animator=%s driver=%s root=%s",
			player.Name,
			clone:GetFullName(),
			tostring(humanoid ~= nil),
			tostring(hasAnimator),
			tostring(animationDriver),
			tostring(driveRoot and driveRoot:GetFullName() or "nil")
		))
	end

	print(string.format(
		"%s owner=%s event=loop_started humanoid=%s animator=%s driver=%s clone=%s root=%s tracks=%d builtinEmoteUsed=false",
		TUNGTUNG_DEBUG_TAG,
		player.Name,
		tostring(humanoid ~= nil),
		tostring(hasAnimator),
		tostring(animationDriver),
		clone:GetFullName(),
		tostring(driveRoot and driveRoot:GetFullName() or "nil"),
		#loadedTracks
	))

	return task.spawn(function()
		local rng = Random.new()
		while clone.Parent do
			local interval = rng:NextInteger(TUNGTUNG_EMOTE_INTERVAL_MIN, TUNGTUNG_EMOTE_INTERVAL_MAX)
			task.wait(interval)
			if not clone.Parent then
				break
			end

			local order = {}
			for index = 1, #loadedTracks do
				order[index] = index
			end
			for index = #order, 2, -1 do
				local swapIndex = rng:NextInteger(1, index)
				order[index], order[swapIndex] = order[swapIndex], order[index]
			end

			local playedTrack = nil
			for _, index in ipairs(order) do
				local chosen = loadedTracks[index]
				stopTungTungEmoteTracks(loadedTracks)
				setTungTungEmoteState(player, clone, true, chosen.track, driveRoot)
				task.wait(TUNGTUNG_EMOTE_PRE_BLEND_WAIT)

				local okPlayTrack, errPlayTrack = pcall(function()
					chosen.track.TimePosition = 0
					chosen.track:Play(TUNGTUNG_EMOTE_FADE_IN, 1, 1)
				end)
				local trackLength = waitForTrackReady(chosen.track, TUNGTUNG_TRACK_READY_TIMEOUT)
				task.wait(math.max(0.18, TUNGTUNG_EMOTE_FADE_IN * 0.8))
				local trackStillPlaying, playingTrackCount = isTrackPlaying(animator, chosen.track)
				local trackActuallyPlayed = okPlayTrack and chosen.track.IsPlaying and trackLength > 0
				local replacedImmediately = okPlayTrack and not trackStillPlaying

				print(string.format(
					"%s owner=%s event=play_emote pet=%s baseWait=%d emote=%s animationId=%s source=%s loadSucceeded=%s trackLength=%.3f trackPlayed=%s replacedImmediately=%s followerDrivenByRoot=%s clone=%s",
					TUNGTUNG_DEBUG_TAG,
					player.Name,
					petId,
					interval,
					tostring(chosen.label),
					tostring(chosen.animationId or "nil"),
					tostring(chosen.source or "unknown"),
					tostring(okPlayTrack),
					trackLength,
					tostring(trackActuallyPlayed),
					tostring(replacedImmediately and playingTrackCount > 0),
					tostring(driveRoot ~= nil),
					clone:GetFullName()
				))

				if not okPlayTrack then
					warn(string.format(
						"%s owner=%s event=play_track_failed emote=%s animationId=%s error=%s",
						TUNGTUNG_DEBUG_TAG,
						player.Name,
						tostring(chosen.label),
						tostring(chosen.animationId or "nil"),
						tostring(errPlayTrack)
					))
					setTungTungEmoteState(player, clone, false, nil, driveRoot)
				elseif trackActuallyPlayed then
					playedTrack = chosen
					if petId == FURRYHUGS_PET_ID then
						print(string.format(
							"[FurryHugsPetEmote] owner=%s event=play_success emote=%s animationId=%s",
							player.Name,
							tostring(chosen.label),
							tostring(chosen.animationId or "nil")
						))
					end
					break
				else
					pcall(function()
						chosen.track:Stop(TUNGTUNG_EMOTE_FADE_OUT)
					end)
					task.wait(TUNGTUNG_EMOTE_POST_BLEND_HOLD)
					setTungTungEmoteState(player, clone, false, nil, driveRoot)
				end
			end

			if playedTrack then
				task.wait(playedTrack.duration)
				pcall(function()
					playedTrack.track:Stop(TUNGTUNG_EMOTE_FADE_OUT)
				end)
				task.wait(TUNGTUNG_EMOTE_POST_BLEND_HOLD)
				setTungTungEmoteState(player, clone, false, nil, driveRoot)
			else
				warn(string.format(
					"%s owner=%s event=no_visible_emote reason=no_track_played clone=%s",
					TUNGTUNG_DEBUG_TAG,
					player.Name,
					clone:GetFullName()
				))
			end
		end

		setTungTungEmoteState(player, clone, false, nil, driveRoot)
		stopTungTungEmoteTracks(loadedTracks)
		print(string.format(
			"%s owner=%s event=loop_stopped reason=pet_removed",
			TUNGTUNG_DEBUG_TAG,
			player.Name
		))
	end)
end

local function resetTungTungLaughStateForRound(newRoundNumber: number, source: string)
	if newRoundNumber == _trackedRoundNumber then
		return
	end
	_trackedRoundNumber = newRoundNumber
	_sawDeathThisRound = false
	_laughedThisRound = false
	print(string.format(
		"[TungTungPetEmote] owner=%s event=round_reset_cleared_laugh_state round=%d source=%s",
		Players.LocalPlayer.Name,
		newRoundNumber,
		source
	))
end

local function tryPlayTungTungLaughOnceThisRound(triggerReason: string): boolean
	local localPlayer = Players.LocalPlayer
	if _laughedThisRound then
		return false
	end
	if localPlayer:GetAttribute("EquippedPet") ~= TUNGTUNG_PET_ID then
		return false
	end

	local entry = _activePets[localPlayer]
	if not entry or not entry.pet or not entry.pet:IsA("Model") then
		return false
	end
	local clone = entry.pet
	if clone:GetAttribute("_petId") ~= TUNGTUNG_PET_ID then
		return false
	end

	if entry.emoteThread then
		task.cancel(entry.emoteThread)
		entry.emoteThread = nil
	end
	if entry.emoteTrack then
		pcall(function()
			entry.emoteTrack:Stop(TUNGTUNG_EMOTE_FADE_OUT)
		end)
	end
	setTungTungEmoteState(localPlayer, clone, false, nil, entry.emoteRoot)

	local humanoid = findHumanoidInModel(clone)
	local _, animator = ensureAnimatorForPet(clone)
	if not animator then
		return false
	end
	local driveRoot = entry.emoteRoot or findTungTungDriveRoot(clone, humanoid)
	local animationIds = collectAnimationIdsByAliases(clone, TUNGTUNG_LAUGH_ALIASES)
	local source = "model"
	if #animationIds == 0 then
		animationIds = TUNGTUNG_LAUGH_FALLBACK_IDS
		source = "fallback"
	end
	local track, animationId = loadPetAnimationTrack(animator, animationIds, false)
	if not track then
		warn(string.format(
			"[TungTungPetEmote] owner=%s event=laugh_failed reason=no_track_loaded source=%s",
			localPlayer.Name,
			source
		))
		entry.emoteThread = startTungTungPetEmoteLoop(clone, localPlayer)
		return false
	end

	track.Priority = TUNGTUNG_EMOTE_PRIORITY
	track.Looped = false
	setTungTungEmoteState(localPlayer, clone, true, track, driveRoot)
	local okPlay = pcall(function()
		track.TimePosition = 0
		track:Play(TUNGTUNG_LAUGH_FADE_IN, 1, 1)
	end)
	if not okPlay then
		setTungTungEmoteState(localPlayer, clone, false, nil, driveRoot)
		entry.emoteThread = startTungTungPetEmoteLoop(clone, localPlayer)
		return false
	end

	_laughedThisRound = true
	print(string.format(
		"[TungTungPetEmote] owner=%s event=pet_laughed_this_round round=%d reason=%s animationId=%s source=%s",
		localPlayer.Name,
		_trackedRoundNumber,
		triggerReason,
		tostring(animationId or "nil"),
		source
	))

	local duration = waitForTrackReady(track, TUNGTUNG_TRACK_READY_TIMEOUT)
	if duration <= 0 then
		duration = TUNGTUNG_LAUGH_DEFAULT_DURATION
	end

	task.spawn(function()
		task.wait(duration + 0.08)
		local liveEntry = _activePets[localPlayer]
		if not liveEntry or liveEntry.pet ~= clone then
			return
		end
		pcall(function()
			track:Stop(TUNGTUNG_LAUGH_FADE_OUT)
		end)
		setTungTungEmoteState(localPlayer, clone, false, nil, driveRoot)
		if clone.Parent then
			liveEntry.emoteThread = startTungTungPetEmoteLoop(clone, localPlayer)
		end
	end)

	return true
end

local function bindKillFeedFirstDeathHook()
	if _killFeedConn then
		return
	end
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local killFeedEvent = remotes and remotes:FindFirstChild("KillFeedEvent")
	if not (killFeedEvent and killFeedEvent:IsA("RemoteEvent")) then
		return
	end
	_killFeedConn = killFeedEvent.OnClientEvent:Connect(function(_victimName, _reasonOrKiller)
		if _trackedRoundNumber <= 0 then
			return
		end
		if _sawDeathThisRound then
			return
		end
		_sawDeathThisRound = true
		tryPlayTungTungLaughOnceThisRound("FirstDeathInRound")
	end)
end

local function bindRoundResetHook()
	if _matchRoundConn then
		return
	end
	local matchStatus = ReplicatedStorage:FindFirstChild("MatchStatus")
	local roundValue = matchStatus and matchStatus:FindFirstChild("Round")
	if not (roundValue and roundValue:IsA("IntValue")) then
		return
	end
	resetTungTungLaughStateForRound(roundValue.Value, "Init")
	_matchRoundConn = roundValue:GetPropertyChangedSignal("Value"):Connect(function()
		resetTungTungLaughStateForRound(roundValue.Value, "RoundValueChanged")
	end)
end

local function findHrpInModel(model: Model): BasePart?
	local hrp = model:FindFirstChild("HumanoidRootPart", true)
	if hrp and hrp:IsA("BasePart") then
		return hrp
	end
	return nil
end

local ROOT_NAME_PRIORITY = {
	"HumanoidRootPart",
	"Root",
	"RootPart",
	"Handle",
	"UpperTorso",
	"LowerTorso",
	"Torso",
}

local function ensureDeterministicPrimaryPart(model: Model): BasePart?
	local current = model.PrimaryPart
	if current and current:IsA("BasePart") then
		return current
	end

	for _, name in ipairs(ROOT_NAME_PRIORITY) do
		local candidate = model:FindFirstChild(name, true)
		if candidate and candidate:IsA("BasePart") then
			model.PrimaryPart = candidate
			return candidate
		end
	end

	local allParts = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			table.insert(allParts, d)
		end
	end
	table.sort(allParts, function(a, b)
		return a:GetFullName() < b:GetFullName()
	end)
	local first = allParts[1]
	if first then
		model.PrimaryPart = first
		return first
	end
	return nil
end

local function pickDeterministicVisualRoot(model: Model): BasePart?
	for _, name in ipairs({ "Root", "Handle", "HumanoidRootPart" }) do
		local part = model:FindFirstChild(name, true)
		if part and part:IsA("BasePart") then
			model.PrimaryPart = part
			return part
		end
	end

	local best: BasePart? = nil
	local bestVolume = -math.huge
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
		return best
	end
	return nil
end

local function ensureInternalWeldsToRoot(model: Model, root: BasePart)
	local hasInternalJoints = false
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("WeldConstraint") or d:IsA("Motor6D") then
			hasInternalJoints = true
			break
		end
	end
	if hasInternalJoints then
		return
	end
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and d ~= root then
			local weld = Instance.new("WeldConstraint")
			weld.Name = "_PetInternalWeld"
			weld.Part0 = root
			weld.Part1 = d
			weld.Parent = root
		end
	end
end

local function moveModelByRootDelta(model: Model, targetRootCF: CFrame): boolean
	local root = model.PrimaryPart
	if not root then
		return false
	end
	local delta = targetRootCF * root.CFrame:Inverse()
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.CFrame = delta * d.CFrame
		end
	end
	return true
end

local function findWalkerRootPart(model: Model, humanoid: Humanoid?): (BasePart?, boolean)
	local hrp = findHrpInModel(model)
	if hrp then
		return hrp, true
	end
	if humanoid and humanoid.RootPart then
		return humanoid.RootPart, false
	end
	if model.PrimaryPart then
		return model.PrimaryPart, false
	end
	local anyPart = model:FindFirstChildWhichIsA("BasePart", true)
	if anyPart then
		return anyPart, false
	end
	return nil, false
end

local function ensureWalkerHumanoid(model: Model): Humanoid
	local hum = findHumanoidInModel(model)
	if hum then
		return hum
	end
	hum = Instance.new("Humanoid")
	hum.Name = "Humanoid"
	hum.Parent = model
	return hum
end

local function ensureWalkerHrp(model: Model, humanoid: Humanoid?): BasePart?
	local existing = findHrpInModel(model)
	if existing then
		return existing
	end

	local base = nil :: BasePart?
	if humanoid and humanoid.RootPart then
		base = humanoid.RootPart
	elseif model.PrimaryPart then
		base = model.PrimaryPart
	else
		base = model:FindFirstChildWhichIsA("BasePart", true)
	end
	if not base then
		return nil
	end

	local hrp = Instance.new("Part")
	hrp.Name = "HumanoidRootPart"
	hrp.Size = Vector3.new(2, 2, 1)
	hrp.Transparency = 1
	hrp.CanCollide = true
	hrp.CanQuery = false
	hrp.CanTouch = false
	hrp.Massless = false
	hrp.Anchored = false
	hrp.CFrame = base.CFrame
	hrp.Parent = model

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = hrp
	weld.Part1 = base
	weld.Parent = hrp

	model.PrimaryPart = hrp
	return hrp
end

local function destroyPetFor(player: Player, reason: string?)
	local entry = _activePets[player]
	if not entry then return end

	if DEBUG_LOGS and shouldLog("pet_destroy_" .. tostring(player.UserId), 3) then
		print(string.format(
			"%s destroy owner=%s reason=%s equippedAttr=%s isWalker=%s isServerMotor=%s activePetId=%s",
			TAG,
			player.Name,
			tostring(reason or "unspecified"),
			tostring(player:GetAttribute("EquippedPet")),
			tostring(entry._isWalker == true),
			tostring(entry._isServerMotor == true),
			tostring(entry.pet and entry.pet:GetAttribute("_petId") or entry._walkerPetId or entry._serverMotorPetId or "nil")
		))
	end

	-- Walker pets live on the server; notify it to clean up.
	if entry._isWalker or entry._isServerMotor then
		if player == Players.LocalPlayer then
			pcall(function() _unequipRemote:FireServer() end)
		end
		_activePets[player] = nil
		return
	end

	if entry.conn then entry.conn:Disconnect() end
	if entry.emoteTrack then
		pcall(function()
			entry.emoteTrack:Stop(TUNGTUNG_EMOTE_FADE_OUT)
		end)
	end
	if entry.emoteThread then
		local activePetId = entry.pet and tostring(entry.pet:GetAttribute("_petId")) or nil
		if isSharedPetEmoteEnabled(activePetId) then
			print(string.format(
				"%s owner=%s event=loop_stop_requested reason=%s",
				TUNGTUNG_DEBUG_TAG,
				player.Name,
				tostring(reason or "unspecified")
			))
		end
		task.cancel(entry.emoteThread)
	end
	if entry.mover and entry.mover.Destroy then
		pcall(function() entry.mover:Destroy() end)
	end
	if entry.pet and entry.pet.Parent then entry.pet:Destroy() end
	_activePets[player] = nil
end

local function spawnPetFor(player: Player, petId: string)
	-- Already tracking this pet? Skip (handles both hover model and walker sentinel).
	local existing = _activePets[player]
	if existing then
		if existing._isWalker and existing._walkerPetId == petId then return end
		if existing._isServerMotor and existing._serverMotorPetId == petId then return end
		if not existing._isWalker and existing.pet and existing.pet.Parent
			and existing.pet:GetAttribute("_petId") == petId then return end
	end

	destroyPetFor(player, "respawn_or_swap")

	if not petId or petId == "" then return end

	local petDef = getPetDef(petId)
	if not petDef then
		warn(TAG, "Pet not in catalog:", petId)
		return
	end

	local movementType = getMovementType(petId, petDef)
	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		return
	end

	local modelName = getConfiguredPetModelName(petId, petDef)
	local sourceModel: Instance? = nil
	local resolutionMode = "none"
	if shouldUseExactNameLookup(modelName) then
		sourceModel = ItemModelRegistry.GetByExactName(modelName)
		if sourceModel then
			resolutionMode = "exact_name"
		end
	end
	if not sourceModel and petDef.modelPath and petDef.modelPath ~= "" then
		sourceModel = ItemModelRegistry.Get(petDef.modelPath)
		if sourceModel then
			resolutionMode = "model_path"
		end
	end
	if not sourceModel and modelName ~= "" then
		sourceModel = ItemModelRegistry.Get(modelName)
		if sourceModel then
			resolutionMode = "model_name_path"
		end
	end
	if DEBUG_LOGS and shouldLog("pet_spawn_lookup_" .. petId, 20) then
		local registryPath = sourceModel and sourceModel:GetFullName() or ItemModelsFolder:GetFullName()
		print(string.format("[PetSpawn] petId=%s petName=%s displayName=%s mode=%s modelPath=%s modelFound=%s registry=%s",
			tostring(petId),
			tostring(modelName),
			tostring(petDef.name),
			tostring(resolutionMode),
			tostring(petDef.modelPath),
			tostring(sourceModel ~= nil),
			registryPath))
	end
	if not sourceModel then
		warn(TAG, "Model not found for pet:", petId, "| displayName:", tostring(petDef.name), "| modelName:", modelName, "| modelPath:", tostring(petDef.modelPath), "| mode:", resolutionMode)
		return
	end

	log("spawn_begin", "Spawning pet for", player.Name .. ":", petId, "modelName:", modelName)
	local movementType = getMovementType(petId, petDef)

	-- ── WALKER PETS ────────────────────────────────────────────────────────────
	if movementType == MOVEMENT_WALKER then
		-- Non-Freddy walker fallback (currently unused): server-owned path.
		if DEBUG_LOGS and shouldLog("walker_pet_client_equip_" .. petId, 20) then
			print(string.format("[WalkerPetCL] equip petId=%s modelName=%s → firing server", petId, modelName))
		end
		_equipRemote:FireServer(petId)
		_activePets[player] = {
			pet          = nil,
			conn         = nil,
			pos          = rootPart.Position,
			t0           = tick(),
			mover        = nil,
			_isWalker    = true,
			_walkerPetId = petId,
		}
		return
	end

	-- ── SERVER MOTOR-RIG PETS (special 4 only) ────────────────────────────────
	if movementType == MOVEMENT_SERVER_MOTOR then
		if player == Players.LocalPlayer then
			_equipRemote:FireServer(petId)
		end
		_activePets[player] = {
			pet              = nil,
			conn             = nil,
			pos              = rootPart.Position,
			t0               = tick(),
			mover            = nil,
			_isServerMotor   = true,
			_serverMotorPetId = petId,
		}
		return
	end

	local clone = sourceModel:Clone()
	local deterministicTarget = DETERMINISTIC_PET_IDS[petId] == true
	if clone:IsA("Model") then
		sanitizeFollowerRigArtifacts(clone, petId)
	end

	-- Unwrap Accessory → extract children into a Model wrapper
	if clone:IsA("Accessory") then
		local wrapper = Instance.new("Model")
		wrapper.Name = clone.Name
		local handle = clone:FindFirstChild("Handle")
		for _, child in ipairs(clone:GetChildren()) do
			child.Parent = wrapper
		end
		if handle and handle:IsA("BasePart") then
			wrapper.PrimaryPart = handle
		else
			local firstPart = wrapper:FindFirstChildWhichIsA("BasePart", true)
			if firstPart then wrapper.PrimaryPart = firstPart end
		end
		clone:Destroy()
		clone = wrapper
	end

	-- Wrap bare BaseParts into a Model so ScaleTo / PivotTo work uniformly.
	if clone:IsA("BasePart") and not clone:IsA("Model") then
		local wrapper = Instance.new("Model")
		wrapper.Name = clone.Name
		clone.Parent = wrapper
		wrapper.PrimaryPart = clone
		clone = wrapper
	end

	-- Ensure consistent pivot behavior for per-pet offsets.
	if clone:IsA("Model") then
		if deterministicTarget then
			local root = pickDeterministicVisualRoot(clone) or ensureDeterministicPrimaryPart(clone)
			if root then
				ensureInternalWeldsToRoot(clone, root)
			end
		elseif not clone.PrimaryPart then
			local preferredRoot = clone:FindFirstChild("HumanoidRootPart", true)
			if preferredRoot and preferredRoot:IsA("BasePart") then
				clone.PrimaryPart = preferredRoot
			else
				local firstPart = clone:FindFirstChildWhichIsA("BasePart", true)
				if firstPart then
					clone.PrimaryPart = firstPart
				end
			end
		end
	end
	local spawnBoundsBeforeStr: string? = nil
	local spawnPrimaryPartName: string = "nil"
	if PET_MASSIVE_SCALE_TARGETS[petId] then
		local b = getBBoxSize(clone)
		spawnBoundsBeforeStr = b and string.format("%.2f,%.2f,%.2f", b.X, b.Y, b.Z) or "nil"
		spawnPrimaryPartName = (clone:IsA("Model") and clone.PrimaryPart and clone.PrimaryPart.Name) or "nil"
	end

	local useUnanchoredFloat = FNAF_REVERTED_FLOAT_IDS[petId] == true or petId == TUNGTUNG_PET_ID

	-- Hover pets: default anchored; reverted FNAF floats are unanchored.
	local function prepPart(part: BasePart)
		part.Anchored   = not useUnanchoredFloat
		part.CanCollide = false
		part.CanQuery   = false
		part.CanTouch   = false
		part.Massless   = true
	end

	if clone:IsA("BasePart") then prepPart(clone) end
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("BasePart") then prepPart(d) end
	end

	-- Enable VFX; destroy embedded scripts (hover pets need no scripting).
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("ParticleEmitter") or d:IsA("Fire") or d:IsA("Sparkles")
			or d:IsA("Smoke") or d:IsA("Beam") or d:IsA("Trail") then
			d.Enabled = true
		elseif d:IsA("Script") or d:IsA("LocalScript") then
			d:Destroy()
		end
	end

	-- ── SIZE NORMALIZATION ─────────────────────────────────────────
	-- Goal: every pet ends up with max bounding-box dim <= TARGET_MAX_DIM.
	local preBBox = getBBoxSize(clone)
	local petScale = 1

	do
		local scaleOverride = PET_SCALE_OVERRIDES[petId]

		if scaleOverride then
			-- Use the explicit override
			petScale = scaleOverride
		elseif preBBox then
			local maxDim = math.max(preBBox.X, preBBox.Y, preBBox.Z, 0.01)
			if maxDim > TARGET_MAX_DIM then
				petScale = TARGET_MAX_DIM / maxDim
			end
		end

		local scaleCeil = SCALE_CEIL
		if scaleOverride and scaleOverride > SCALE_CEIL then
			scaleCeil = scaleOverride
		end
		petScale = math.clamp(petScale, SCALE_FLOOR, scaleCeil)

		-- Apply the primary scale
		if petScale < 1 then
			applyScale(clone, petScale)
		end

		-- POST-SCALE VERIFICATION: re-measure and correct if still too big
		local postBBox = getBBoxSize(clone)
		if postBBox then
			local postMax = math.max(postBBox.X, postBBox.Y, postBBox.Z)
			if postMax > TARGET_MAX_DIM then
				local correction = (TARGET_MAX_DIM / postMax) * 0.95 -- 5% safety margin
				correction = math.max(correction, SCALE_FLOOR)
				applyScale(clone, correction)
				petScale = petScale * correction
				log("post_scale", "Post-scale correction for", petId,
					string.format("extra %.3fx (was %.1f studs)", correction, postMax))
			end
		end
		if PET_MASSIVE_SCALE_TARGETS[petId] then
			local beforeStr = preBBox and string.format("%.2f,%.2f,%.2f", preBBox.X, preBBox.Y, preBBox.Z) or "nil"
			local after = getBBoxSize(clone)
			local afterStr = after and string.format("%.2f,%.2f,%.2f", after.X, after.Y, after.Z) or "nil"
			print(string.format("[PetScale] pet=%s appliedScale=%.2f bounds=%s/%s",
				tostring(petDef and petDef.name or petId),
				petScale,
				beforeStr,
				afterStr))
		end
	end

	log("scaled_pet", "Scaled pet", petId, string.format("%.3fx", petScale),
		preBBox and string.format("(pre-bbox: %.1f x %.1f x %.1f)", preBBox.X, preBBox.Y, preBBox.Z) or "(no bbox)")

	local visual = PetVisualConfig.Get(petId, petDef)

	-- Apply visual scale ONCE per spawn (never in follow loop).
	if visual.scale ~= 1 then
		applyScale(clone, visual.scale)
		petScale = petScale * visual.scale
	end

	if RunService:IsStudio() and visual.debugTag and shouldLog("pet_visual_fix_" .. petId, 20) then
		print(string.format(
			"[PetVisualFix] pet=%s appliedRot=<%.1f,%.1f,%.1f>",
			petId,
			visual.rotDeg.X,
			visual.rotDeg.Y,
			visual.rotDeg.Z
		))
	end

	-- ── FOLLOW OFFSET (scaled to pet size) ─────────────────────────
	local offsetMul = 0.4 + 0.6 * petScale
	local petOffset = CFrame.new(
		PET_OFFSET.X * offsetMul,
		PET_OFFSET.Y * offsetMul,
		PET_OFFSET.Z * offsetMul
	)
	local petBobbleAmp = BOBBLE_AMPLITUDE * math.max(petScale, 0.4)

	-- Per-pet yaw offset in radians (from table + PetVisualConfig rotation).
	-- PetVisualConfig.rotation is a pure-yaw CFrame for backwards-facing models.
	local petYawRad = math.rad(PET_YAW_OFFSET_DEG[petId] or 0)
	do
		-- Extract additional yaw from visual.rotation (ignore any pitch/roll).
		local _, vy, _ = visual.rotation:ToEulerAnglesYXZ()
		petYawRad = petYawRad + vy
	end

	if RunService:IsStudio() and shouldLog("pet_upright_" .. petId, 20) then
		print(string.format("[PetUpright] petId=%s yawOffsetDeg=%.0f",
			petId, math.deg(petYawRad)))
	end

	clone.Name = PET_INSTANCE_NAME
	clone:SetAttribute("IsPet", true)
	clone:SetAttribute("_petId", petId)
	clone:SetAttribute("_owner", player.Name)
	clone.Parent = workspace

	-- Final in-game scale pass for the four tiny legendary pets.
	-- Runs AFTER normalization and parent, BEFORE final attach transform.
	local finalSpawnMult = PET_FINAL_SPAWN_SCALE_MULTIPLIER[petId]
	if finalSpawnMult and finalSpawnMult > 1 then
		print(string.format("[PetSpawnModel] pet=%s modelPath=%s primaryPart=%s boundsBefore=%s",
			tostring(petDef and petDef.name or petId),
			tostring(clone:GetFullName()),
			tostring(spawnPrimaryPartName),
			tostring(spawnBoundsBeforeStr or "nil")))
		applyScale(clone, finalSpawnMult)
		petScale = petScale * finalSpawnMult
		local after = getBBoxSize(clone)
		local afterStr = after and string.format("%.2f,%.2f,%.2f", after.X, after.Y, after.Z) or "nil"
		print(string.format("[PetScaleApplied] pet=%s multiplier=%.2f boundsAfter=%s",
			tostring(petDef and petDef.name or petId),
			finalSpawnMult,
			afterStr))
	end

	-- ── INITIAL POSITION ───────────────────────────────────────────
	local startPos = (rootPart.CFrame * petOffset).Position
	local look0 = rootPart.CFrame.LookVector
	local yaw0  = math.atan2(-look0.X, -look0.Z) + petYawRad
	local startCF = CFrame.new(startPos) * CFrame.Angles(0, yaw0, 0)
	local deterministicOverride = deterministicTarget and (PET_DETERMINISTIC_ROTATION_OVERRIDES[petId] or CFrame.new()) or CFrame.new()
	local attachCF = startCF
		* (PET_EQUIP_OFFSET_CFRAME[petId] or CFrame.new())
		* (PET_ROTATION_FIX[petId] or CFrame.new())
		* deterministicOverride

	if deterministicTarget and clone:IsA("Model") then
		task.wait()
		local root = pickDeterministicVisualRoot(clone) or ensureDeterministicPrimaryPart(clone)
		if not root then
			clone:PivotTo(attachCF)
		else
			ensureInternalWeldsToRoot(clone, root)
			if not moveModelByRootDelta(clone, attachCF) then
				clone:PivotTo(attachCF)
			end
		end
	elseif clone:IsA("Model") then
		clone:PivotTo(attachCF)
	elseif clone:IsA("BasePart") then
		clone.CFrame = attachCF
	end

	if deterministicTarget then
		local rootPath = "nil"
		if clone:IsA("Model") and clone.PrimaryPart then
			rootPath = clone.PrimaryPart:GetFullName()
		elseif clone:IsA("BasePart") then
			rootPath = clone:GetFullName()
		end
		local parts = 0
		local anchored = 0
		local transparent = 0
		local ltmNonZero = 0
		local samplePos = Vector3.new(0, 0, 0)
		for _, d in ipairs(clone:GetDescendants()) do
			if d:IsA("BasePart") then
				parts += 1
				if d.Anchored then anchored += 1 end
				if d.Transparency >= 1 then transparent += 1 end
				if d.LocalTransparencyModifier > 0 then ltmNonZero += 1 end
				samplePos = d.Position
			end
		end
		print(string.format(
			"[PetAttach] pet=%s root=%s parts=%d anchored=%d transparent=%d ltmNonZero=%d samplePos=<%.2f,%.2f,%.2f> finalLook=<%.3f,%.3f,%.3f> finalUp=<%.3f,%.3f,%.3f> overrideApplied=%s",
			tostring(petDef and petDef.name or petId),
			tostring(rootPath),
			parts, anchored, transparent, ltmNonZero,
			samplePos.X, samplePos.Y, samplePos.Z,
			attachCF.LookVector.X, attachCF.LookVector.Y, attachCF.LookVector.Z,
			attachCF.UpVector.X, attachCF.UpVector.Y, attachCF.UpVector.Z,
			tostring(PET_DETERMINISTIC_ROTATION_OVERRIDES[petId] ~= nil)
		))
	end

	-- ── FOLLOW + BOBBLE LOOP ───────────────────────────────────────
	-- Position is lerped for smooth motion; orientation is rebuilt fresh
	-- every frame from the player's LookVector so pitch/roll are ALWAYS 0.
	local currentPos = startPos
	local t0 = tick()
	local sharedEmoteEnabled = isSharedPetEmoteEnabled(petId)
	local useEmoteRootDrive = shouldUseEmoteRootDrive(petId)
	local tungtungDriveRoot = if useEmoteRootDrive and clone:IsA("Model") then findTungTungDriveRoot(clone, findHumanoidInModel(clone)) else nil

	local followConn = RunService.Heartbeat:Connect(function()
		if not clone or not clone.Parent then
			destroyPetFor(player)
			return
		end
		local char = player.Character
		if not char then return end
		local hrp = char:FindFirstChild("HumanoidRootPart")
		if not hrp then return end

		local t = tick() - t0

		-- 1) Target position: offset from HRP + vertical bobble (position only, no rotation)
		local rawTarget = (hrp.CFrame * petOffset).Position
		local bobbleY   = math.sin(t * BOBBLE_SPEED) * petBobbleAmp
		local targetPos = Vector3.new(rawTarget.X, rawTarget.Y + bobbleY, rawTarget.Z)

		-- 2) Lerp position only (no lerp on rotation — orientation is always fresh)
		currentPos = currentPos:Lerp(targetPos, LERP_ALPHA)

		-- 3) Compute yaw from player LookVector — guaranteed pitch=0, roll=0
		local lookVec = hrp.CFrame.LookVector
		local yaw = math.atan2(-lookVec.X, -lookVec.Z) + petYawRad
		-- Small yaw wobble (wobble is yaw-only, no tilt introduced)
		yaw = yaw + math.sin(t * YAW_WOBBLE_SPEED) * math.rad(YAW_WOBBLE_AMP)

		-- 4) Upright CFrame: ONLY yaw rotation, pitch=0, roll=0 always
		local uprightCF = CFrame.new(currentPos) * CFrame.Angles(0, yaw, 0)
		local finalCF = uprightCF
			* (PET_EQUIP_OFFSET_CFRAME[petId] or CFrame.new())
			* (PET_ROTATION_FIX[petId] or CFrame.new())
		if deterministicTarget then
			finalCF = finalCF * (PET_DETERMINISTIC_ROTATION_OVERRIDES[petId] or CFrame.new())
		end

		local activeEntry = _activePets[player]

		-- 5) Apply
		if useEmoteRootDrive and tungtungDriveRoot and activeEntry and activeEntry.pet == clone and activeEntry.emoteActive then
			setTungTungDriveRoot(tungtungDriveRoot, finalCF)
			currentPos = tungtungDriveRoot.Position
		elseif deterministicTarget and clone:IsA("Model") then
			local root = clone.PrimaryPart or pickDeterministicVisualRoot(clone) or ensureDeterministicPrimaryPart(clone)
			if not root then
				clone:PivotTo(finalCF)
			elseif not moveModelByRootDelta(clone, finalCF) then
				clone:PivotTo(finalCF)
			end
		elseif clone:IsA("Model") then
			clone:PivotTo(finalCF)
		elseif clone:IsA("BasePart") then
			clone.CFrame = finalCF
		end
	end)

	local emoteThread
	if sharedEmoteEnabled and clone:IsA("Model") then
		print(string.format(
			"%s owner=%s event=equip pet=%s clone=%s",
			TUNGTUNG_DEBUG_TAG,
			player.Name,
			petId,
			clone:GetFullName()
		))
		emoteThread = startTungTungPetEmoteLoop(clone, player, petId)
	end

	_activePets[player] = {
		pet = clone,
		conn = followConn,
		pos = currentPos,
		t0 = t0,
		mover = nil,
		emoteThread = emoteThread,
		emoteActive = false,
		emoteTrack = nil,
		emoteRoot = tungtungDriveRoot,
	}

	log("spawn_done", "Pet spawned for", player.Name .. ":", petId)
	if DEBUG_LOGS and shouldLog("pet_spawn_" .. tostring(player.UserId), 3) then
		print(string.format(
			"%s spawn owner=%s petId=%s movement=%s anchoredMode=%s equippedAttr=%s",
			TAG,
			player.Name,
			petId,
			movementType,
			useUnanchoredFloat and "unanchored" or "anchored",
			tostring(player:GetAttribute("EquippedPet"))
		))
	end
end

-- =====================================================================
-- PER-PLAYER LIFECYCLE
-- =====================================================================

local function updatePetFor(player: Player)
	local petId = player:GetAttribute("EquippedPet")
	if petId and petId ~= "" then
		spawnPetFor(player, petId)
	else
		destroyPetFor(player, "equipped_attr_empty")
	end
end

local function setupPlayer(player: Player)
	local conns: { RBXScriptConnection } = {}

	table.insert(conns, player:GetAttributeChangedSignal("EquippedPet"):Connect(function()
		updatePetFor(player)
	end))

	table.insert(conns, player.CharacterAdded:Connect(function(character)
		character:WaitForChild("HumanoidRootPart", 10)
		task.wait(0.5)
		updatePetFor(player)
	end))

	table.insert(conns, player.CharacterRemoving:Connect(function()
		destroyPetFor(player, "character_removing")
	end))

	_playerConns[player] = conns

	if player.Character and player.Character:FindFirstChild("HumanoidRootPart") then
		task.spawn(function()
			task.wait(0.3)
			updatePetFor(player)
		end)
	end
end

local function cleanupPlayer(player: Player)
	destroyPetFor(player, "player_cleanup")
	if _playerConns[player] then
		for _, conn in ipairs(_playerConns[player]) do
			conn:Disconnect()
		end
		_playerConns[player] = nil
	end
end

-- =====================================================================
-- PUBLIC API
-- =====================================================================

function PetFollowerController.Init()
	log("init", "Initializing...")

	Players.PlayerAdded:Connect(setupPlayer)
	Players.PlayerRemoving:Connect(cleanupPlayer)

	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(setupPlayer, player)
	end

	bindKillFeedFirstDeathHook()
	bindRoundResetHook()
	task.spawn(function()
		for _ = 1, 30 do
			if _killFeedConn and _matchRoundConn then
				return
			end
			bindKillFeedFirstDeathHook()
			bindRoundResetHook()
			task.wait(1)
		end
	end)

	log("ready", "Ready — tracking pets for all players")
end

return PetFollowerController
