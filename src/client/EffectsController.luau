--[[
	EffectsController
	Client-only match impact visuals:
	  - Camera shake
	  - Screen flash
	  - Elimination burst
	  - Round start text
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local EffectsConfig = require(Shared:WaitForChild("EffectsConfig"))
local MatchState = require(Shared:WaitForChild("MatchState"))
local PlayerState = require(Shared:WaitForChild("PlayerState"))

local LocalPlayer = Players.LocalPlayer
local randomGenerator = Random.new()

type ShakeSpec = {
	Intensity: number,
	Frequency: number,
	Duration: number?,
	AttackTime: number?,
	HoldTime: number?,
	DecayTime: number?,
	Sustain: boolean?,
}

type ActiveShake = {
	StartedAt: number,
	Intensity: number,
	Frequency: number,
	AttackTime: number,
	HoldTime: number,
	DecayTime: number,
	Sustain: boolean,
	MaxDuration: number,
	ReleaseAt: number?,
	ExpiresAt: number?,
	Id: string?,
	SeedX: number,
	SeedY: number,
	SeedZ: number,
}

local EffectsController = {}

local initialized = false
local effectsGui: ScreenGui? = nil
local flashFrame: Frame? = nil
local roundLabel: TextLabel? = nil
local roundLabelStroke: UIStroke? = nil
local roundLabelScale: UIScale? = nil

local matchStateValue: StringValue? = nil
local roundValue: IntValue? = nil
local roundPhaseValue: StringValue? = nil
local killFeedEvent: RemoteEvent? = nil

local activeShakes: { ActiveShake } = {}
local namedShakes: { [string]: ActiveShake } = {}
local shakeRenderBound = false
local roundBannerToken = 0
local flashToken = 0
local lastRoundAnnouncementRound = 0
local lastObservedRound = 0
local lastBeamPreStrikeRound = 0
local lastBeamStrikeRound = 0
local lastBeamDecayRound = 0
local recentEliminationTimes: { [string]: number } = {}
local playerConnections: { [Player]: { RBXScriptConnection } } = {}
local humanoidConnections: { [Player]: RBXScriptConnection } = {}
local eliminationSignalsBound = false
local killFeedRemoteBound = false

local BEAM_PRE_STRIKE_SHAKE_ID = "BeamPreStrikeRumble"

local function log(message: string)
	if EffectsConfig.DebugLogs then
		print("[EffectsController] " .. message)
	end
end

local function getRoundScale(roundNumber: number): number
	local scaling = EffectsConfig.RoundScaling
	if roundNumber <= scaling.LightRoundsMax then
		return scaling.LightMultiplier
	end
	if roundNumber <= scaling.MediumRoundsMax then
		return scaling.MediumMultiplier
	end
	return math.min(scaling.LateMultiplier, scaling.MaxMultiplier or scaling.LateMultiplier)
end

local function getCurrentRound(): number
	return if roundValue then roundValue.Value else 0
end

local function isEligibleForEffects(): boolean
	if LocalPlayer:GetAttribute("PlayerState") ~= PlayerState.States.InMatch then
		return false
	end
	if matchStateValue and matchStateValue.Value ~= MatchState.States.Playing then
		return false
	end
	return true
end

local function stopShakeRenderStep()
	if not shakeRenderBound then
		return
	end
	RunService:UnbindFromRenderStep(EffectsConfig.CameraShake.RenderStepName)
	shakeRenderBound = false
end

local function clearShakes()
	table.clear(activeShakes)
	table.clear(namedShakes)
	stopShakeRenderStep()
end

local function unregisterNamedShake(shake: ActiveShake)
	if shake.Id and namedShakes[shake.Id] == shake then
		namedShakes[shake.Id] = nil
	end
end

local function removeShakeAt(index: number)
	local shake = activeShakes[index]
	if not shake then
		return
	end

	unregisterNamedShake(shake)
	table.remove(activeShakes, index)
end

local function getAttackEnvelope(age: number, attackTime: number): number
	if attackTime <= 0 then
		return 1
	end
	return math.clamp(age / attackTime, 0, 1)
end

local function releaseShake(shake: ActiveShake, releaseAt: number)
	if shake.ReleaseAt then
		return
	end

	shake.ReleaseAt = releaseAt
	shake.ExpiresAt = releaseAt + shake.DecayTime
end

local function maybeAutoReleaseShake(shake: ActiveShake, now: number)
	if not shake.Sustain or shake.ReleaseAt or shake.MaxDuration <= 0 then
		return
	end

	local releaseAt = shake.StartedAt + shake.MaxDuration
	if now >= releaseAt then
		releaseShake(shake, releaseAt)
	end
end

local function computeShakeEnvelope(shake: ActiveShake, now: number): number
	maybeAutoReleaseShake(shake, now)

	local age = now - shake.StartedAt
	if age <= 0 then
		return 0
	end

	if shake.Sustain then
		if shake.ReleaseAt then
			local releaseLevel = getAttackEnvelope(shake.ReleaseAt - shake.StartedAt, shake.AttackTime)
			if shake.DecayTime <= 0 then
				return 0
			end
			local releaseAge = math.max(0, now - shake.ReleaseAt)
			local decayAlpha = math.clamp(releaseAge / shake.DecayTime, 0, 1)
			return releaseLevel * (1 - decayAlpha) * (1 - decayAlpha)
		end

		return getAttackEnvelope(age, shake.AttackTime)
	end

	if age < shake.AttackTime then
		return getAttackEnvelope(age, shake.AttackTime)
	end

	local holdEnd = shake.AttackTime + shake.HoldTime
	if age < holdEnd then
		return 1
	end

	if shake.DecayTime <= 0 then
		return 0
	end

	local decayAge = age - holdEnd
	local decayAlpha = math.clamp(decayAge / shake.DecayTime, 0, 1)
	return (1 - decayAlpha) * (1 - decayAlpha)
end

local function pruneExpiredShakes(now: number)
	for index = #activeShakes, 1, -1 do
		local shake = activeShakes[index]
		maybeAutoReleaseShake(shake, now)

		local expired = false
		if shake.Sustain then
			expired = shake.ExpiresAt ~= nil and now >= shake.ExpiresAt
		else
			expired = now >= (shake.StartedAt + shake.AttackTime + shake.HoldTime + shake.DecayTime)
		end

		if expired then
			removeShakeAt(index)
		end
	end
end

local function computeShakeOffset(now: number): Vector3
	local cameraShakeConfig = EffectsConfig.CameraShake
	local offset = Vector3.zero
	for _, shake in ipairs(activeShakes) do
		local age = now - shake.StartedAt
		local envelope = computeShakeEnvelope(shake, now)
		if envelope <= 0 then
			continue
		end

		local sampleTime = age * shake.Frequency

		local x = math.noise(shake.SeedX, sampleTime, 0) * 2
		local y = math.noise(shake.SeedY, 0, sampleTime) * 2
		local z = math.noise(shake.SeedZ, sampleTime, shake.SeedX) * 2 * cameraShakeConfig.DepthMultiplier

		offset += Vector3.new(x, y, z) * shake.Intensity * envelope
	end

	local maxOffset = cameraShakeConfig.MaxOffsetStuds
	local maxDepth = maxOffset * cameraShakeConfig.DepthMultiplier
	return Vector3.new(
		math.clamp(offset.X, -maxOffset, maxOffset),
		math.clamp(offset.Y, -maxOffset, maxOffset),
		math.clamp(offset.Z, -maxDepth, maxDepth)
	)
end

local function ensureShakeRenderStep()
	if shakeRenderBound then
		return
	end

	shakeRenderBound = true

	-- Bind after the default Roblox camera update so each offset applies to the fresh camera pose.
	RunService:BindToRenderStep(EffectsConfig.CameraShake.RenderStepName, Enum.RenderPriority.Camera.Value + 1, function()
		if not isEligibleForEffects() then
			clearShakes()
			return
		end

		local now = os.clock()
		pruneExpiredShakes(now)
		if #activeShakes == 0 then
			stopShakeRenderStep()
			return
		end

		local camera = Workspace.CurrentCamera
		if not camera then
			return
		end

		local offset = computeShakeOffset(now)
		camera.CFrame = camera.CFrame * CFrame.new(offset)
	end)
end

local function addShake(baseShake: ShakeSpec, roundNumber: number, shakeId: string?)
	local scale = getRoundScale(roundNumber)
	local cameraShakeConfig = EffectsConfig.CameraShake
	local intensity = math.min(baseShake.Intensity * scale, cameraShakeConfig.MaxPerShakeIntensity)
	local attackTime = math.max(0, (baseShake.AttackTime or cameraShakeConfig.DefaultAttackTime or 0) * scale)
	local decayTime = math.max(0, (baseShake.DecayTime or cameraShakeConfig.DefaultDecayTime or cameraShakeConfig.MinDuration) * scale)
	local isSustain = baseShake.Sustain == true
	local holdTime = 0
	local maxDuration = 0

	if isSustain then
		maxDuration = math.clamp(
			(baseShake.Duration or cameraShakeConfig.MaxSustainDuration) * scale,
			cameraShakeConfig.MinDuration,
			cameraShakeConfig.MaxSustainDuration
		)
	else
		if baseShake.HoldTime ~= nil then
			holdTime = math.max(0, baseShake.HoldTime * scale)
		else
			local requestedDuration = math.max(0, (baseShake.Duration or 0) * scale)
			holdTime = math.max(0, requestedDuration - attackTime - decayTime)
		end

		local totalDuration = attackTime + holdTime + decayTime
		if totalDuration > cameraShakeConfig.MaxPulseDuration then
			local ratio = cameraShakeConfig.MaxPulseDuration / totalDuration
			attackTime *= ratio
			holdTime *= ratio
			decayTime *= ratio
			totalDuration = cameraShakeConfig.MaxPulseDuration
		end
		if totalDuration < cameraShakeConfig.MinDuration then
			decayTime += (cameraShakeConfig.MinDuration - totalDuration)
		end
	end

	if shakeId then
		local existing = namedShakes[shakeId]
		if existing then
			releaseShake(existing, os.clock())
		end
	end

	local activeShake: ActiveShake = {
		StartedAt = os.clock(),
		Intensity = intensity,
		Frequency = baseShake.Frequency,
		AttackTime = attackTime,
		HoldTime = holdTime,
		DecayTime = decayTime,
		Sustain = isSustain,
		MaxDuration = maxDuration,
		ReleaseAt = nil,
		ExpiresAt = nil,
		Id = shakeId,
		SeedX = randomGenerator:NextNumber(0, 256),
		SeedY = randomGenerator:NextNumber(256, 512),
		SeedZ = randomGenerator:NextNumber(512, 768),
	}

	table.insert(activeShakes, activeShake)
	if shakeId then
		namedShakes[shakeId] = activeShake
	end

	while #activeShakes > cameraShakeConfig.MaxSimultaneous do
		removeShakeAt(1)
	end

	ensureShakeRenderStep()
end

local function releaseNamedShake(shakeId: string)
	local shake = namedShakes[shakeId]
	if not shake then
		return
	end

	releaseShake(shake, os.clock())
	ensureShakeRenderStep()
end

local function playFlash(flashSpec, roundNumber: number)
	if not flashFrame then
		return
	end

	local scale = getRoundScale(roundNumber)
	flashToken += 1
	local token = flashToken

	flashFrame.Visible = true
	flashFrame.BackgroundColor3 = flashSpec.Color
	flashFrame.BackgroundTransparency = math.max(
		flashSpec.MinimumTransparency or 0,
		1 - (flashSpec.Intensity * scale)
	)

	local flashTween = TweenService:Create(
		flashFrame,
		TweenInfo.new(flashSpec.FadeOutTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = 1 }
	)
	flashTween:Play()

	task.spawn(function()
		flashTween.Completed:Wait()
		if flashFrame and token == flashToken then
			flashFrame.Visible = false
		end
	end)
end

local function showRoundBanner(roundNumber: number)
	if not roundLabel or not roundLabelStroke or not roundLabelScale then
		return
	end

	local roundTextConfig = EffectsConfig.RoundText
	local scale = getRoundScale(roundNumber)
	local scaleBoost = 1 + ((scale - 1) * 0.45)

	roundBannerToken += 1
	local token = roundBannerToken

	roundLabel.Visible = true
	roundLabel.Text = string.format("ROUND %d", roundNumber)
	roundLabel.TextTransparency = 1
	roundLabelStroke.Transparency = 1
	roundLabelScale.Scale = roundTextConfig.StartScale * scaleBoost

	local fadeInTween = TweenService:Create(
		roundLabel,
		TweenInfo.new(roundTextConfig.FadeInTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ TextTransparency = 0 }
	)
	local strokeInTween = TweenService:Create(
		roundLabelStroke,
		TweenInfo.new(roundTextConfig.FadeInTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Transparency = 0.08 }
	)
	local scaleInTween = TweenService:Create(
		roundLabelScale,
		TweenInfo.new(roundTextConfig.FadeInTime, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = roundTextConfig.EndScale * scaleBoost }
	)
	fadeInTween:Play()
	strokeInTween:Play()
	scaleInTween:Play()

	task.spawn(function()
		task.wait(roundTextConfig.FadeInTime + roundTextConfig.HoldTime)
		if token ~= roundBannerToken or not roundLabel or not roundLabelStroke or not roundLabelScale then
			return
		end

		local fadeOutTween = TweenService:Create(
			roundLabel,
			TweenInfo.new(roundTextConfig.FadeOutTime, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ TextTransparency = 1 }
		)
		local strokeOutTween = TweenService:Create(
			roundLabelStroke,
			TweenInfo.new(roundTextConfig.FadeOutTime, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Transparency = 1 }
		)
		local scaleOutTween = TweenService:Create(
			roundLabelScale,
			TweenInfo.new(roundTextConfig.FadeOutTime, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Scale = roundTextConfig.ExitScale * scaleBoost }
		)
		fadeOutTween:Play()
		strokeOutTween:Play()
		scaleOutTween:Play()

		task.wait(roundTextConfig.FadeOutTime + 0.03)
		if token == roundBannerToken and roundLabel then
			roundLabel.Visible = false
		end
	end)
end

local function getEffectsFolder(): Folder
	local existing = Workspace:FindFirstChild("ClientEffects")
	if existing and existing:IsA("Folder") then
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = "ClientEffects"
	folder.Parent = Workspace
	return folder
end

local function resolveCharacterPosition(player: Player?): Vector3?
	if not player or not player.Character then
		return nil
	end

	local rootPart = player.Character:FindFirstChild("HumanoidRootPart")
	if rootPart and rootPart:IsA("BasePart") then
		return rootPart.Position
	end

	local primaryPart = player.Character.PrimaryPart
	if primaryPart then
		return primaryPart.Position
	end

	local fallbackPart = player.Character:FindFirstChildWhichIsA("BasePart")
	return if fallbackPart then fallbackPart.Position else nil
end

local function spawnEliminationBurst(position: Vector3, roundNumber: number)
	local burstConfig = EffectsConfig.EliminationBurst
	local scale = getRoundScale(roundNumber)
	local emitCount = math.clamp(
		math.floor((burstConfig.EmitCount * scale) + 0.5),
		burstConfig.MinEmitCount,
		burstConfig.MaxEmitCount
	)

	local anchor = Instance.new("Part")
	anchor.Name = "EliminationBurstAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = CFrame.new(position)
	anchor.Parent = getEffectsFolder()

	local attachment = Instance.new("Attachment")
	attachment.Parent = anchor

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "EliminationBurst"
	emitter.Texture = burstConfig.Texture
	emitter.Color = ColorSequence.new(burstConfig.ColorStart, burstConfig.ColorEnd)
	emitter.LightEmission = burstConfig.LightEmission
	emitter.LightInfluence = burstConfig.LightInfluence
	emitter.Brightness = burstConfig.Brightness
	emitter.Lifetime = NumberRange.new(burstConfig.LifetimeMin, burstConfig.LifetimeMax)
	emitter.Speed = NumberRange.new(burstConfig.SpeedMin * scale, burstConfig.SpeedMax * scale)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Acceleration = Vector3.new(0, -12, 0)
	emitter.Drag = burstConfig.Drag
	emitter.Rate = 0
	emitter.LockedToPart = true
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, burstConfig.SizeStart),
		NumberSequenceKeypoint.new(0.45, burstConfig.SizeMid),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.6, 0.18),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Parent = attachment
	emitter:Emit(emitCount)

	Debris:AddItem(anchor, burstConfig.CleanupSeconds)
end

local function shouldSuppressEliminationEffect(effectKey: string): boolean
	local now = os.clock()
	local lastTriggeredAt = recentEliminationTimes[effectKey]
	if lastTriggeredAt and (now - lastTriggeredAt) < EffectsConfig.EliminationWindowSeconds then
		return true
	end

	recentEliminationTimes[effectKey] = now
	return false
end

local function triggerBeamPreStrikeEffect(roundNumber: number, triggerSource: string)
	if not isEligibleForEffects() then
		return
	end

	addShake(EffectsConfig.CameraShake.BeamPreStrike, roundNumber, BEAM_PRE_STRIKE_SHAKE_ID)
	log(string.format(
		"beam pre-strike rumble start round=%d phase=BeamWarning trigger=%s scale=%.2f",
		roundNumber,
		triggerSource,
		getRoundScale(roundNumber)
	))
end

local function triggerBeamStrikeEffect(roundNumber: number, triggerSource: string)
	if not isEligibleForEffects() then
		return
	end

	releaseNamedShake(BEAM_PRE_STRIKE_SHAKE_ID)
	addShake(EffectsConfig.CameraShake.BeamStrike, roundNumber)
	playFlash(EffectsConfig.ScreenFlash.BeamStrike, roundNumber)
	log(string.format(
		"beam strike pulse start round=%d phase=Strike trigger=%s scale=%.2f",
		roundNumber,
		triggerSource,
		getRoundScale(roundNumber)
	))
end

local function triggerBeamDecayEffect(roundNumber: number, triggerSource: string)
	if not isEligibleForEffects() then
		return
	end

	addShake(EffectsConfig.CameraShake.BeamDecay, roundNumber)
	log(string.format(
		"beam decay start round=%d phase=Recovery trigger=%s scale=%.2f",
		roundNumber,
		triggerSource,
		getRoundScale(roundNumber)
	))
end

local function triggerRoundStartEffect(roundNumber: number)
	if not isEligibleForEffects() then
		return
	end

	showRoundBanner(roundNumber)
	log(string.format("round start effect round=%d scale=%.2f", roundNumber, getRoundScale(roundNumber)))
end

local function triggerEliminationEffect(player: Player?, rawReason: any, source: string, knownPosition: Vector3?)
	if not isEligibleForEffects() then
		return
	end

	local roundNumber = getCurrentRound()
	if roundNumber <= 0 then
		return
	end

	local effectKey = if player then tostring(player.UserId) else tostring(player and player.Name or rawReason or source)
	if shouldSuppressEliminationEffect(effectKey) then
		return
	end

	addShake(EffectsConfig.CameraShake.Elimination, roundNumber)

	local burstPosition = knownPosition or resolveCharacterPosition(player)
	if burstPosition then
		spawnEliminationBurst(burstPosition, roundNumber)
	end

	log(string.format(
		"elimination effect player=%s source=%s reason=%s burst=%s round=%d",
		if player then player.Name else "unknown",
		source,
		tostring(rawReason),
		tostring(burstPosition ~= nil),
		roundNumber
	))
end

local function evaluateRoundStartEffect()
	local roundNumber = getCurrentRound()
	if roundNumber <= 0 then
		lastRoundAnnouncementRound = 0
		return
	end
	if lastRoundAnnouncementRound == roundNumber then
		return
	end
	if not isEligibleForEffects() then
		return
	end

	lastRoundAnnouncementRound = roundNumber
	triggerRoundStartEffect(roundNumber)
end

local function resetBeamImpactState(clearActiveEffects: boolean)
	lastObservedRound = math.max(getCurrentRound(), 0)
	lastBeamPreStrikeRound = 0
	lastBeamStrikeRound = 0
	lastBeamDecayRound = 0
	if clearActiveEffects then
		clearShakes()
	else
		releaseNamedShake(BEAM_PRE_STRIKE_SHAKE_ID)
	end
end

local function evaluateBeamImpactEffects(triggerSource: string)
	local roundNumber = getCurrentRound()
	local phaseName = if roundPhaseValue then roundPhaseValue.Value else ""

	if roundNumber <= 0 then
		resetBeamImpactState(true)
		return
	end

	if lastObservedRound ~= roundNumber then
		resetBeamImpactState(true)
		lastObservedRound = roundNumber
	end

	if phaseName ~= "BeamWarning" then
		releaseNamedShake(BEAM_PRE_STRIKE_SHAKE_ID)
	end

	if not isEligibleForEffects() then
		return
	end

	if phaseName == "BeamWarning" and lastBeamPreStrikeRound ~= roundNumber then
		lastBeamPreStrikeRound = roundNumber
		triggerBeamPreStrikeEffect(roundNumber, triggerSource)
	end

	if phaseName == "Strike" and lastBeamStrikeRound ~= roundNumber then
		lastBeamStrikeRound = roundNumber
		triggerBeamStrikeEffect(roundNumber, triggerSource)
	end

	if phaseName == "Recovery" and lastBeamDecayRound ~= roundNumber then
		lastBeamDecayRound = roundNumber
		triggerBeamDecayEffect(roundNumber, triggerSource)
	end
end

local function createGui()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui", 10)
	if not playerGui then
		return
	end

	effectsGui = Instance.new("ScreenGui")
	effectsGui.Name = "EffectsGui"
	effectsGui.ResetOnSpawn = false
	effectsGui.IgnoreGuiInset = true
	effectsGui.DisplayOrder = EffectsConfig.DisplayOrder
	effectsGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	effectsGui.Parent = playerGui

	flashFrame = Instance.new("Frame")
	flashFrame.Name = "StrikeFlash"
	flashFrame.Size = UDim2.fromScale(1, 1)
	flashFrame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	flashFrame.BackgroundTransparency = 1
	flashFrame.BorderSizePixel = 0
	flashFrame.Visible = false
	flashFrame.ZIndex = 1
	flashFrame.Parent = effectsGui

	roundLabel = Instance.new("TextLabel")
	roundLabel.Name = "RoundImpactText"
	roundLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	roundLabel.Position = UDim2.new(0.5, 0, EffectsConfig.RoundText.PositionYScale, 0)
	roundLabel.Size = UDim2.new(0.8, 0, 0, 72)
	roundLabel.BackgroundTransparency = 1
	roundLabel.Font = Enum.Font.GothamBlack
	roundLabel.Text = ""
	roundLabel.TextColor3 = EffectsConfig.RoundText.Color
	roundLabel.TextScaled = true
	roundLabel.TextTransparency = 1
	roundLabel.Visible = false
	roundLabel.ZIndex = 2
	roundLabel.Parent = effectsGui

	local sizeConstraint = Instance.new("UITextSizeConstraint")
	sizeConstraint.MaxTextSize = EffectsConfig.RoundText.MaxTextSize
	sizeConstraint.MinTextSize = EffectsConfig.RoundText.MinTextSize
	sizeConstraint.Parent = roundLabel

	roundLabelStroke = Instance.new("UIStroke")
	roundLabelStroke.Color = EffectsConfig.RoundText.StrokeColor
	roundLabelStroke.Thickness = 2.6
	roundLabelStroke.Transparency = 1
	roundLabelStroke.Parent = roundLabel

	roundLabelScale = Instance.new("UIScale")
	roundLabelScale.Scale = 1
	roundLabelScale.Parent = roundLabel
end

local function disconnectHumanoid(player: Player)
	local connection = humanoidConnections[player]
	if connection then
		connection:Disconnect()
		humanoidConnections[player] = nil
	end
end

local function wireCharacter(player: Player, character: Model)
	disconnectHumanoid(player)

	local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5)
	if not humanoid then
		return
	end

	humanoidConnections[player] = humanoid.Died:Connect(function()
		triggerEliminationEffect(player, "HumanoidDied", "HumanoidDied", resolveCharacterPosition(player))
	end)
end

local function unwirePlayer(player: Player)
	disconnectHumanoid(player)

	local connections = playerConnections[player]
	if not connections then
		return
	end

	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	playerConnections[player] = nil
end

local function wirePlayer(player: Player)
	unwirePlayer(player)

	local connections = {}
	table.insert(connections, player.CharacterAdded:Connect(function(character)
		wireCharacter(player, character)
	end))
	table.insert(connections, player.CharacterRemoving:Connect(function()
		disconnectHumanoid(player)
	end))

	if player.Character then
		wireCharacter(player, player.Character)
	end

	playerConnections[player] = connections
end

local function bindEliminationSignals()
	if not eliminationSignalsBound then
		eliminationSignalsBound = true
		for _, player in ipairs(Players:GetPlayers()) do
			wirePlayer(player)
		end

		Players.PlayerAdded:Connect(function(player)
			wirePlayer(player)
		end)

		Players.PlayerRemoving:Connect(function(player)
			unwirePlayer(player)
		end)
	end

	if killFeedEvent and not killFeedRemoteBound then
		killFeedRemoteBound = true
		killFeedEvent.OnClientEvent:Connect(function(playerName, rawReason)
			local victim = Players:FindFirstChild(tostring(playerName))
			triggerEliminationEffect(victim, rawReason, "KillFeedEvent", resolveCharacterPosition(victim))
		end)
	end
end

function EffectsController.Init()
	if initialized then
		return
	end
	initialized = true

	createGui()
	bindEliminationSignals()

	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
		if not remotes then
			warn("[EffectsController] Remotes folder not found")
			return
		end

		local event = remotes:WaitForChild("KillFeedEvent", 10)
		if event and event:IsA("RemoteEvent") then
			killFeedEvent = event
			bindEliminationSignals()
		else
			warn("[EffectsController] KillFeedEvent not found")
		end
	end)

	task.spawn(function()
		local matchStatus = ReplicatedStorage:WaitForChild("MatchStatus", 15)
		if not matchStatus then
			warn("[EffectsController] MatchStatus not found")
			return
		end

		matchStateValue = matchStatus:WaitForChild("State", 10)
		roundValue = matchStatus:WaitForChild("Round", 10)
		roundPhaseValue = matchStatus:WaitForChild("RoundPhase", 10)

		lastRoundAnnouncementRound = math.max(getCurrentRound(), 0)
		resetBeamImpactState(false)

		if matchStateValue then
			matchStateValue.Changed:Connect(function()
				if not isEligibleForEffects() then
					clearShakes()
				end
				evaluateRoundStartEffect()
				evaluateBeamImpactEffects("MatchStateChanged")
			end)
		end

		if roundValue then
			roundValue.Changed:Connect(function()
				if roundValue.Value <= 0 then
					lastRoundAnnouncementRound = 0
					resetBeamImpactState(true)
					return
				end

				evaluateRoundStartEffect()
				evaluateBeamImpactEffects("RoundChanged")
			end)
		end

		if roundPhaseValue then
			roundPhaseValue.Changed:Connect(function()
				evaluateBeamImpactEffects("RoundPhaseChanged")
			end)
		end

		evaluateBeamImpactEffects("InitSync")
	end)

	LocalPlayer:GetAttributeChangedSignal("PlayerState"):Connect(function()
		if not isEligibleForEffects() then
			clearShakes()
		end
		evaluateRoundStartEffect()
		evaluateBeamImpactEffects("PlayerStateChanged")
	end)

	print("[EffectsController] Initialized")
end

return EffectsController
