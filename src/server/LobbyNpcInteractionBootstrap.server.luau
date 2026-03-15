local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LobbyNpcConfig = require(Shared:WaitForChild("LobbyNpcConfig"))

local REMOTE_NAME = "NpcDialogueRequest"
local MODEL_FIND_TIMEOUT = 20
local MODEL_FIND_STEP = 1

local function ensureRemotesFolder(): Folder
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if remotes and remotes:IsA("Folder") then
		return remotes
	end

	if remotes then
		remotes:Destroy()
	end

	remotes = Instance.new("Folder")
	remotes.Name = "Remotes"
	remotes.Parent = ReplicatedStorage
	return remotes
end

local function ensureRemoteEvent(remotes: Folder, name: string): RemoteEvent
	local existing = remotes:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end

	if existing then
		existing:Destroy()
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = remotes
	return remote
end

local function findNpcModel(modelName: string): Model?
	local direct = Workspace:FindFirstChild(modelName)
	if direct and direct:IsA("Model") then
		return direct
	end

	local recursive = Workspace:FindFirstChild(modelName, true)
	if recursive and recursive:IsA("Model") then
		return recursive
	end

	return nil
end

local function waitForNpcModel(modelName: string): Model?
	local elapsed = 0
	while elapsed <= MODEL_FIND_TIMEOUT do
		local model = findNpcModel(modelName)
		if model then
			return model
		end

		if elapsed >= MODEL_FIND_TIMEOUT then
			break
		end

		task.wait(MODEL_FIND_STEP)
		elapsed += MODEL_FIND_STEP
	end

	return nil
end

local function waitForAnyNpcModel(primaryName: string, legacyNames: { string }?): Model?
	local model = waitForNpcModel(primaryName)
	if model then
		return model
	end

	if type(legacyNames) == "table" then
		for _, legacyName in ipairs(legacyNames) do
			if type(legacyName) == "string" and legacyName ~= "" then
				model = waitForNpcModel(legacyName)
				if model then
					return model
				end
			end
		end
	end

	return nil
end

local function ensureHumanoid(model: Model): Humanoid
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		return humanoid
	end

	humanoid = Instance.new("Humanoid")
	humanoid.Name = "Humanoid"
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.BreakJointsOnDeath = false
	humanoid.Parent = model
	return humanoid
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

local function ensureRootPart(model: Model): BasePart?
	local rootPart = model:FindFirstChild("HumanoidRootPart")
	if rootPart and rootPart:IsA("BasePart") then
		model.PrimaryPart = rootPart
		return rootPart
	end

	if model.PrimaryPart and model.PrimaryPart:IsA("BasePart") then
		return model.PrimaryPart
	end

	local fallback = model:FindFirstChildWhichIsA("BasePart", true)
	if fallback then
		model.PrimaryPart = fallback
	end
	return fallback
end

local function ensurePrompt(model: Model, rootPart: BasePart, npcId: string, npcConfig): ProximityPrompt
	local chosen: ProximityPrompt? = nil
	local extraPrompts = {}
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("ProximityPrompt") then
			if descendant.Name == npcConfig.promptName and not chosen then
				chosen = descendant
			else
				table.insert(extraPrompts, descendant)
			end
		end
	end

	if not chosen then
		chosen = table.remove(extraPrompts, 1)
	end

	if not chosen then
		chosen = Instance.new("ProximityPrompt")
	end

	for _, prompt in ipairs(extraPrompts) do
		prompt:Destroy()
	end

	chosen.Name = npcConfig.promptName
	chosen.ActionText = npcConfig.prompt.actionText or "Talk"
	chosen.ObjectText = npcConfig.prompt.objectText or model.Name
	chosen.KeyboardKeyCode = npcConfig.prompt.keyCode or Enum.KeyCode.E
	chosen.HoldDuration = npcConfig.prompt.holdDuration or 0
	chosen.MaxActivationDistance = npcConfig.prompt.maxActivationDistance or 12
	chosen.RequiresLineOfSight = npcConfig.prompt.requiresLineOfSight == true
	chosen.Style = Enum.ProximityPromptStyle.Default
	chosen.Enabled = true
	chosen:SetAttribute("LobbyNpcId", npcId)

	if chosen.Parent ~= rootPart then
		chosen.Parent = rootPart
	end

	return chosen
end

local function playAmbientAnimation(model: Model, animator: Animator, npcId: string, npcConfig)
	local animationConfig = npcConfig.ambientAnimation
	if not animationConfig or animationConfig.animationId == nil or animationConfig.animationId == "" then
		return
	end

	local animationName = npcId .. "AmbientAnimation"
	local animation = model:FindFirstChild(animationName)
	if animation and not animation:IsA("Animation") then
		animation:Destroy()
		animation = nil
	end
	if not animation then
		animation = Instance.new("Animation")
		animation.Name = animationName
		animation.Parent = model
	end
	animation.AnimationId = animationConfig.animationId

	task.defer(function()
		local ok, track = pcall(function()
			return animator:LoadAnimation(animation)
		end)
		if not ok or not track then
			warn(string.format("[LobbyNpcInteractionBootstrap] Failed to load ambient animation for %s: %s", npcId, tostring(track)))
			return
		end

		track.Priority = animationConfig.priority or Enum.AnimationPriority.Action
		track.Looped = true
		local playOk, playErr = pcall(function()
			track:Play(0.15, 1, animationConfig.speed or 1)
		end)
		if not playOk then
			warn(string.format("[LobbyNpcInteractionBootstrap] Failed to play ambient animation for %s: %s", npcId, tostring(playErr)))
		end
	end)
end

local function setupNpc(npcId: string, npcConfig, remote: RemoteEvent)
	local model = waitForAnyNpcModel(npcConfig.modelName, npcConfig.legacyModelNames)
	if not model then
		warn(string.format("[LobbyNpcInteractionBootstrap] NPC model '%s' not found", tostring(npcConfig.modelName)))
		return
	end

	-- Normalize live model naming to the new config name so overhead labels/moderation-safe names match.
	if type(npcConfig.modelName) == "string" and npcConfig.modelName ~= "" and model.Name ~= npcConfig.modelName then
		model.Name = npcConfig.modelName
	end

	model:SetAttribute("LobbyNpcId", npcId)

	local humanoid = ensureHumanoid(model)
	if humanoid.DisplayName ~= model.Name then
		humanoid.DisplayName = model.Name
	end
	local animator = ensureAnimator(humanoid)
	local rootPart = ensureRootPart(model)
	if not rootPart then
		warn(string.format("[LobbyNpcInteractionBootstrap] NPC '%s' has no BasePart for prompt setup", npcId))
		return
	end

	local prompt = ensurePrompt(model, rootPart, npcId, npcConfig)
	playAmbientAnimation(model, animator, npcId, npcConfig)

	prompt.Triggered:Connect(function(player: Player)
		if not player or not player:IsDescendantOf(Players) then
			return
		end
		remote:FireClient(player, npcId, npcConfig.dialogue)
	end)
end

local remotesFolder = ensureRemotesFolder()
local npcDialogueRemote = ensureRemoteEvent(remotesFolder, REMOTE_NAME)

for npcId, npcConfig in pairs(LobbyNpcConfig) do
	task.spawn(function()
		setupNpc(npcId, npcConfig, npcDialogueRemote)
	end)
end
