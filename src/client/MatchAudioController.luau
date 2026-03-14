--[[
	MatchAudioController
	Client-side round feedback audio.

	Adds subtle match-only cues for:
	  - Freeze activation
	  - Late-round tension
	  - Active beam phase

	Playback is driven by existing replicated match signals plus the
	existing FreezeIndicator remote, so no gameplay logic changes.
]]

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MatchState = require(Shared:WaitForChild("MatchState"))
local PlayerState = require(Shared:WaitForChild("PlayerState"))

local LocalPlayer = Players.LocalPlayer

local MatchAudioController = {}

local FREEZE_SOUND_ID = "rbxassetid://76550802183957"
local TENSION_SOUND_ID = "rbxassetid://132014926399178"
local BEAM_SOUND_ID = "rbxassetid://112553783607296"

local FREEZE_VOLUME = 0.65
local TENSION_VOLUME = 0.40
local BEAM_VOLUME = 0.32

local FREEZE_FADE_IN = 0.12
local FREEZE_FADE_OUT = 0.24
local TENSION_FADE_IN = 0.24
local TENSION_FADE_OUT = 0.36
local BEAM_FADE_IN = 0.25
local BEAM_FADE_OUT = 0.22

local TENSION_TRIGGER_REMAINING = 4.5
local FREEZE_DUPLICATE_WINDOW = 0.35
local ONE_SHOT_TIME_LENGTH_WAIT = 3.0

local initialized = false
local matchStateValue: StringValue? = nil
local roundValue: IntValue? = nil
local roundPhaseValue: StringValue? = nil
local movementCountdownVisibleValue: BoolValue? = nil
local movementCountdownEndTimeValue: NumberValue? = nil
local lastFreezeTriggerAt = 0
local lastTensionRoundPlayed = -1

type Track = {
	name: string,
	sound: Sound,
	targetVolume: number,
	fadeIn: number,
	fadeOut: number,
	looped: boolean,
	active: boolean,
	token: number,
	tween: Tween?,
}

local freezeTrack: Track? = nil
local tensionTrack: Track? = nil
local beamTrack: Track? = nil

local function isLocalPlayerInMatch(): boolean
	return LocalPlayer:GetAttribute("PlayerState") == PlayerState.States.InMatch
end

local function canPlayMatchAudio(): boolean
	if not isLocalPlayerInMatch() then
		return false
	end
	if not matchStateValue then
		return false
	end
	return matchStateValue.Value == MatchState.States.Playing
end

local function createTrack(container: Instance, name: string, soundId: string, looped: boolean, volume: number, fadeIn: number, fadeOut: number): Track
	local sound = Instance.new("Sound")
	sound.Name = name
	sound.SoundId = soundId
	sound.Looped = looped
	sound.Volume = 0
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.Parent = container

	return {
		name = name,
		sound = sound,
		targetVolume = volume,
		fadeIn = fadeIn,
		fadeOut = fadeOut,
		looped = looped,
		active = false,
		token = 0,
		tween = nil,
	}
end

local function cancelTween(track: Track)
	if track.tween then
		track.tween:Cancel()
		track.tween = nil
	end
end

local function tweenVolume(track: Track, goalVolume: number, duration: number, onComplete: (() -> ())?)
	cancelTween(track)
	if duration <= 0 then
		track.sound.Volume = goalVolume
		if onComplete then
			onComplete()
		end
		return
	end

	local tween = TweenService:Create(
		track.sound,
		TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Volume = goalVolume }
	)
	track.tween = tween
	tween:Play()

	task.spawn(function()
		tween.Completed:Wait()
		if track.tween == tween then
			track.tween = nil
			if onComplete then
				onComplete()
			end
		end
	end)
end

local function stopTrack(track: Track, fadeDuration: number?)
	track.active = false
	track.token += 1
	local token = track.token
	local duration = fadeDuration
	if duration == nil then
		duration = track.fadeOut
	end

	tweenVolume(track, 0, duration, function()
		if track.token ~= token then
			return
		end
		track.sound:Stop()
		track.sound.TimePosition = 0
	end)
end

local function scheduleOneShotFadeOut(track: Track, token: number)
	task.spawn(function()
		local waited = 0
		while track.token == token and track.sound.Parent and track.sound.TimeLength <= 0 and waited < ONE_SHOT_TIME_LENGTH_WAIT do
			task.wait(0.05)
			waited += 0.05
		end

		if track.token ~= token or not track.sound.Parent then
			return
		end

		local duration = track.sound.TimeLength
		if duration <= 0 then
			return
		end

		local fadeLead = math.min(track.fadeOut, math.max(duration * 0.35, 0.15))
		local waitTime = math.max(0, duration - fadeLead)
		if waitTime > 0 then
			task.wait(waitTime)
		end

		if track.token ~= token or not track.sound.Parent then
			return
		end

		tweenVolume(track, 0, fadeLead, function()
			if track.token ~= token then
				return
			end
			track.sound:Stop()
			track.sound.TimePosition = 0
			track.active = false
		end)
	end)
end

local function playOneShot(track: Track)
	track.active = true
	track.token += 1
	local token = track.token

	cancelTween(track)
	track.sound.Looped = false
	track.sound.Volume = 0
	track.sound:Stop()
	track.sound.TimePosition = 0
	track.sound:Play()

	tweenVolume(track, track.targetVolume, track.fadeIn, nil)
	scheduleOneShotFadeOut(track, token)
end

local function startLoopTrack(track: Track)
	if track.active and track.sound.Playing then
		return
	end

	track.active = true
	track.token += 1
	track.sound.Looped = true
	if not track.sound.Playing then
		track.sound.Volume = 0
		track.sound.TimePosition = 0
		track.sound:Play()
	end
	tweenVolume(track, track.targetVolume, track.fadeIn, nil)
end

local function syncBeamTrack()
	if not beamTrack then
		return
	end

	local phaseName = roundPhaseValue and roundPhaseValue.Value or ""
	local beamShouldBeActive = canPlayMatchAudio()
		and (phaseName == "BeamWarning" or phaseName == "Strike")

	if beamShouldBeActive then
		startLoopTrack(beamTrack)
	else
		stopTrack(beamTrack)
	end
end

local function stopNonLoopingMatchAudio()
	if freezeTrack and freezeTrack.sound.Playing then
		stopTrack(freezeTrack, 0.15)
	end
	if tensionTrack and tensionTrack.sound.Playing then
		stopTrack(tensionTrack, 0.18)
	end
end

local function updateEligibility()
	if matchStateValue and matchStateValue.Value ~= MatchState.States.Playing then
		lastTensionRoundPlayed = -1
	end
	if canPlayMatchAudio() then
		syncBeamTrack()
		return
	end

	syncBeamTrack()
	stopNonLoopingMatchAudio()
end

local function maybePlayFreezeCue()
	if not freezeTrack then
		return
	end
	local now = os.clock()
	if now - lastFreezeTriggerAt < FREEZE_DUPLICATE_WINDOW then
		return
	end
	lastFreezeTriggerAt = now
	playOneShot(freezeTrack)
end

local function maybePlayTensionCue()
	if not tensionTrack or not roundValue or not movementCountdownVisibleValue or not movementCountdownEndTimeValue then
		return
	end
	if not canPlayMatchAudio() then
		return
	end

	local currentRound = roundValue.Value
	if currentRound <= 0 or lastTensionRoundPlayed == currentRound then
		return
	end
	if not movementCountdownVisibleValue.Value then
		return
	end

	local remaining = movementCountdownEndTimeValue.Value - workspace:GetServerTimeNow()
	if remaining <= 0 or remaining > TENSION_TRIGGER_REMAINING then
		return
	end

	lastTensionRoundPlayed = currentRound
	playOneShot(tensionTrack)
end

function MatchAudioController.Init()
	if initialized then
		return
	end
	initialized = true

	local folder = SoundService:FindFirstChild("MatchAudio")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "MatchAudio"
		folder.Parent = SoundService
	end

	freezeTrack = createTrack(folder, "FreezeCue", FREEZE_SOUND_ID, false, FREEZE_VOLUME, FREEZE_FADE_IN, FREEZE_FADE_OUT)
	tensionTrack = createTrack(folder, "RoundTensionCue", TENSION_SOUND_ID, false, TENSION_VOLUME, TENSION_FADE_IN, TENSION_FADE_OUT)
	beamTrack = createTrack(folder, "BeamActiveCue", BEAM_SOUND_ID, true, BEAM_VOLUME, BEAM_FADE_IN, BEAM_FADE_OUT)

	task.spawn(function()
		pcall(function()
			ContentProvider:PreloadAsync({
				freezeTrack.sound,
				tensionTrack.sound,
				beamTrack.sound,
			})
		end)
	end)

	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
		if not remotes then
			warn("[MatchAudioController] Remotes folder not found")
			return
		end

		local freezeRemote = remotes:WaitForChild("FreezeIndicator", 15)
		if freezeRemote and freezeRemote:IsA("RemoteEvent") then
			freezeRemote.OnClientEvent:Connect(function(action: string)
				if action == "Freeze" then
					maybePlayFreezeCue()
				end
			end)
		else
			warn("[MatchAudioController] FreezeIndicator remote missing")
		end
	end)

	task.spawn(function()
		local matchStatus = ReplicatedStorage:WaitForChild("MatchStatus", 15)
		if not matchStatus then
			warn("[MatchAudioController] MatchStatus not found")
			return
		end

		matchStateValue = matchStatus:WaitForChild("State", 10)
		roundValue = matchStatus:WaitForChild("Round", 10)
		roundPhaseValue = matchStatus:WaitForChild("RoundPhase", 10)
		movementCountdownVisibleValue = matchStatus:WaitForChild("MovementCountdownVisible", 10)
		movementCountdownEndTimeValue = matchStatus:WaitForChild("MovementCountdownEndTime", 10)

		if roundValue then
			roundValue.Changed:Connect(function()
				if roundValue.Value <= 0 then
					lastTensionRoundPlayed = -1
				end
				if tensionTrack and tensionTrack.sound.Playing then
					stopTrack(tensionTrack, 0.18)
				end
				syncBeamTrack()
			end)
		end
		if matchStateValue then
			matchStateValue.Changed:Connect(function()
				updateEligibility()
			end)
		end
		if roundPhaseValue then
			roundPhaseValue.Changed:Connect(function()
				syncBeamTrack()
			end)
		end
		if movementCountdownVisibleValue then
			movementCountdownVisibleValue.Changed:Connect(function()
				maybePlayTensionCue()
			end)
		end
		if movementCountdownEndTimeValue then
			movementCountdownEndTimeValue.Changed:Connect(function()
				maybePlayTensionCue()
			end)
		end

		updateEligibility()
		maybePlayTensionCue()
	end)

	LocalPlayer:GetAttributeChangedSignal("PlayerState"):Connect(function()
		updateEligibility()
	end)

	RunService.Heartbeat:Connect(function()
		maybePlayTensionCue()
	end)

	print("[MatchAudioController] Initialized")
end

return MatchAudioController
