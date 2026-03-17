--[[
	MusicController
	Centralized client-side music & SFX system.

	CROSSFADE enforcement: on context switch the new track begins fading in
	while the old track is simultaneously fading out.  Both overlap during
	the crossfade window so there is never a silent gap.

	Music:
	  • Lobby  — 70% original track / 30% alt track
	  • Map    — single track, starts at 32s, looped

	SFX (layered, does NOT replace music):
	  • Win / ObbyComplete via PlaySFX RemoteEvent
	  • Intermission 5-second countdown warning

	Integrates with SettingsPanel via SoundGroup "BGM" in SoundService.

	Called from: init.client.luau via MusicController.Init()
]]

local SoundService      = game:GetService("SoundService")
local TweenService      = game:GetService("TweenService")
local RunService        = game:GetService("RunService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared")
local MusicConfig = require(Shared:WaitForChild("MusicConfig"))
local PlayerState = require(Shared:WaitForChild("PlayerState"))

local MusicController = {}

-- ═══════════════════════════════════════════════════════════════════
-- CONFIG
-- ═══════════════════════════════════════════════════════════════════

-- Lobby track A: original lobby music (10%)
local LOBBY_TRACK_A_ID      = MusicConfig.LobbyTracks.Primary.Id
local LOBBY_TRACK_A_START   = MusicConfig.LobbyTracks.Primary.Start
local LOBBY_TRACK_A_VOLUME  = MusicConfig.LobbyTracks.Primary.Volume
local LOBBY_TRACK_A_CHANCE  = MusicConfig.LobbyTracks.Primary.Chance

-- Lobby track B: alt lobby music (90%)
local LOBBY_TRACK_B_ID      = MusicConfig.LobbyTracks.Alternate.Id
local LOBBY_TRACK_B_START   = MusicConfig.LobbyTracks.Alternate.Start
local LOBBY_TRACK_B_VOLUME  = MusicConfig.LobbyTracks.Alternate.Volume

local function buildTrackSequence(trackConfig)
	local tracks = {}
	local playlist = trackConfig.Playlist
	if typeof(playlist) == "table" and #playlist > 0 then
		for _, track in ipairs(playlist) do
			table.insert(tracks, {
				Id = track.Id,
				Start = track.Start or 0,
			})
		end
	elseif trackConfig.Id then
		table.insert(tracks, {
			Id = trackConfig.Id,
			Start = trackConfig.Start or 0,
		})
	end
	return tracks
end

local function describeTrackSequence(tracks): string
	local parts = table.create(#tracks)
	for index, track in ipairs(tracks) do
		parts[index] = string.format("%s@%.2f", track.Id, track.Start or 0)
	end
	return table.concat(parts, ",")
end

-- Match music (mode-aware)
local NORMAL_MAP_TRACKS         = buildTrackSequence(MusicConfig.MapTracks.Normal)
local NORMAL_MAP_TRACK_VOLUME   = MusicConfig.MapTracks.Normal.Volume

-- Save a Brainrot mode track (new)
local BRAINROT_MAP_TRACK_ID     = MusicConfig.MapTracks.Brainrot.Id
local BRAINROT_MAP_TRACK_START  = MusicConfig.MapTracks.Brainrot.Start
local BRAINROT_MAP_TRACK_VOLUME = MusicConfig.MapTracks.Brainrot.Volume

-- Crossfade transition (both tracks overlap — no silent gap)
local CROSSFADE_TIME        = 1.2

-- SFX
local SFX_VOLUME            = MusicConfig.SFX.Win.Volume
local COUNTDOWN_VOLUME      = MusicConfig.SFX.IntermissionCountdown.Volume
local COUNTDOWN_THRESHOLD   = MusicConfig.SFX.IntermissionCountdown.Threshold
local WIN_SFX_ID            = MusicConfig.SFX.Win.Id
local INTERMISSION_SFX_ID   = MusicConfig.SFX.IntermissionCountdown.Id

-- Legacy sounds to purge (old map music + any leftovers)
local LEGACY_SOUND_IDS = {
	["rbxassetid://99521953914772"]  = true,  -- old MapMusicA
	["rbxassetid://140496937016968"] = true,  -- old MapMusicB
}
local LEGACY_SOUND_NAMES = {
	MapMusicA = true,
	MapMusicB = true,
}

-- ═══════════════════════════════════════════════════════════════════
-- INTERNAL STATE
-- ═══════════════════════════════════════════════════════════════════

local bgmGroup: SoundGroup       = nil
local activeSound: Sound?        = nil   -- the ONE playing music Sound
local activeFadeTween: Tween?    = nil
local currentContext: string?    = nil   -- "lobby" | "normal_match" | "brainrot_match"
local lastLoggedPlayerState: string? = nil
local lastLoggedAudioState: string? = nil
local _initialized               = false
local matchStatusModeValue: StringValue? = nil
local matchStatusStateValue: StringValue? = nil
local matchStatusPhaseEndValue: NumberValue? = nil
local modeVoteActiveValue: BoolValue? = nil
local lastWarnedPhaseEnd: number? = nil
local normalPlaylistToken = 0

-- SFX sounds (persistent, not part of single-channel)
local winSfx: Sound?             = nil
local intermissionSfx: Sound?    = nil
local log

-- Hard-stop intermission countdown SFX and reset playback position
local function stopIntermissionSfx()
	if intermissionSfx and intermissionSfx.Playing then
		intermissionSfx:Stop()
		intermissionSfx.TimePosition = 0
	end
end

local function clearIntermissionWarning(reason: string, remaining: number?, phaseEnd: number?, clearWarnedPhase: boolean?)
	local hadWarning = lastWarnedPhaseEnd ~= nil
	local wasPlaying = intermissionSfx ~= nil and intermissionSfx.Playing
	if wasPlaying or hadWarning then
		log(string.format(
			"[IntermissionCountdownSFX] action=stop reason=%s remaining=%.2f phaseEnd=%.2f warned=%s playing=%s",
			reason,
			remaining or -1,
			phaseEnd or -1,
			tostring(hadWarning),
			tostring(wasPlaying)
		))
	end
	stopIntermissionSfx()
	if clearWarnedPhase ~= false then
		lastWarnedPhaseEnd = nil
	end
end

local function syncIntermissionCountdownSfx(reason: string)
	local stateVal = matchStatusStateValue
	local phaseEndVal = matchStatusPhaseEndValue
	if not stateVal or not phaseEndVal then
		return
	end

	local phaseEnd = phaseEndVal.Value
	local remaining = phaseEnd - workspace:GetServerTimeNow()
	local playerState = LocalPlayer:GetAttribute("PlayerState")

	if stateVal.Value ~= "Intermission" then
		clearIntermissionWarning(reason .. "_not_intermission", remaining, phaseEnd, true)
		return
	end

	if playerState == "AFK" then
		clearIntermissionWarning(reason .. "_player_afk", remaining, phaseEnd, true)
		return
	end

	if remaining <= 0.5 then
		clearIntermissionWarning(reason .. "_expired", remaining, phaseEnd, true)
		return
	end

	if remaining > COUNTDOWN_THRESHOLD then
		clearIntermissionWarning(reason .. "_above_threshold", remaining, phaseEnd, true)
		return
	end

	if lastWarnedPhaseEnd == phaseEnd then
		return
	end

	lastWarnedPhaseEnd = phaseEnd
	if intermissionSfx then
		intermissionSfx.Volume = COUNTDOWN_VOLUME
		intermissionSfx:Stop()
		intermissionSfx.TimePosition = 0
		intermissionSfx:Play()
	end
	log(string.format(
		"[IntermissionCountdownSFX] action=start reason=%s remaining=%.2f phaseEnd=%.2f",
		reason,
		remaining,
		phaseEnd
	))
end

-- ═══════════════════════════════════════════════════════════════════
-- LOGGING
-- ═══════════════════════════════════════════════════════════════════

log = function(...)
	print("[MusicController]", ...)
end

local function logState()
	local id = activeSound and activeSound.SoundId or "none"
	local tp = activeSound and string.format("%.1f", activeSound.TimePosition) or "0"
	local vol = activeSound and string.format("%.3f", activeSound.Volume) or "0"
	local soundCount = 0
	for _, child in ipairs(SoundService:GetChildren()) do
		if child:IsA("Sound") then soundCount += 1 end
	end
	local groupCount = 0
	if bgmGroup then
		for _, child in ipairs(bgmGroup:GetChildren()) do
			if child:IsA("Sound") then groupCount += 1 end
		end
	end
	log(string.format("Context=%s nowPlaying=%s timePos=%s volume=%s | SoundService sounds=%d, BGM group sounds=%d",
		tostring(currentContext), id, tp, vol, soundCount, groupCount))
end

local function getInstancePath(instance: Instance?): string
	if not instance then
		return "nil"
	end

	local path = instance.Name
	local current = instance.Parent
	while current do
		path = current.Name .. "." .. path
		current = current.Parent
	end
	return path
end

local function logMusicDiagnostics(stage: string, sound: Sound?, extra: string?)
	if not sound then
		log(string.format("[MapMusicAudit] stage=%s sound=nil %s", stage, extra or ""))
		return
	end

	log(string.format(
		"[MapMusicAudit] stage=%s name=%s id=%s loaded=%s playing=%s time=%.2f volume=%.2f parent=%s %s",
		stage,
		sound.Name,
		sound.SoundId,
		tostring(sound.IsLoaded),
		tostring(sound.Playing),
		sound.TimePosition,
		sound.Volume,
		getInstancePath(sound.Parent),
		extra or ""
	))
end

local function logPossiblePermissionIssue(sound: Sound, stage: string)
	warn(string.format(
		"[MusicController][MapMusicAudit] stage=%s likelyPermissionOrOwnershipIssue=true name=%s id=%s loaded=%s playing=%s volume=%.2f parent=%s",
		stage,
		sound.Name,
		sound.SoundId,
		tostring(sound.IsLoaded),
		tostring(sound.Playing),
		sound.Volume,
		getInstancePath(sound.Parent)
	))
end

-- ═══════════════════════════════════════════════════════════════════
-- LEGACY CLEANUP
-- ═══════════════════════════════════════════════════════════════════

local function purgeLegacySounds()
	local containers = { SoundService, workspace }
	for _, container in ipairs(containers) do
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Sound") then
				local isLegacy = LEGACY_SOUND_NAMES[child.Name] or LEGACY_SOUND_IDS[child.SoundId]
				if isLegacy then
					log(string.format("Removed legacy sound: %s %s", child.Name, child.SoundId))
					child:Stop()
					child:Destroy()
				end
			end
			-- Also check inside SoundGroups
			if child:IsA("SoundGroup") then
				for _, sub in ipairs(child:GetChildren()) do
					if sub:IsA("Sound") then
						local isLegacy = LEGACY_SOUND_NAMES[sub.Name] or LEGACY_SOUND_IDS[sub.SoundId]
						if isLegacy then
							log(string.format("Removed legacy sound (in group %s): %s %s", child.Name, sub.Name, sub.SoundId))
							sub:Stop()
							sub:Destroy()
						end
					end
				end
			end
		end
	end
end

-- ═══════════════════════════════════════════════════════════════════
-- CROSSFADE SOUND MANAGEMENT
-- New track fades in while old track fades out simultaneously.
-- Both overlap during the crossfade window → no silent gap.
-- ═══════════════════════════════════════════════════════════════════

local _fadeOutTween: Tween? = nil
local _fadingOutSound: Sound? = nil

local function killActiveSound()
	if activeFadeTween then
		activeFadeTween:Cancel()
		activeFadeTween = nil
	end
	if activeSound then
		activeSound:Stop()
		activeSound:Destroy()
		activeSound = nil
	end
end

local function killFadingOutSound()
	if _fadeOutTween then
		_fadeOutTween:Cancel()
		_fadeOutTween = nil
	end
	if _fadingOutSound then
		_fadingOutSound:Stop()
		_fadingOutSound:Destroy()
		_fadingOutSound = nil
	end
end

local function createMusicSound(name: string, soundId: string, looped: boolean): Sound
	local sound = Instance.new("Sound")
	sound.Name = name
	sound.SoundId = soundId
	sound.Looped = looped
	sound.Volume = 0
	sound.SoundGroup = bgmGroup
	sound.Parent = SoundService
	logMusicDiagnostics("created", sound, string.format("looped=%s", tostring(looped)))
	return sound
end

local function crossfadeTo(newName: string, newId: string, newStart: number, newVolume: number, looped: boolean)
	-- If there's already a sound fading out from a previous crossfade, kill it immediately
	killFadingOutSound()

	-- Cancel any in-progress fade-in on the current active sound
	if activeFadeTween then
		activeFadeTween:Cancel()
		activeFadeTween = nil
	end

	-- Move the current active sound to "fading out" slot
	local oldSound = activeSound
	activeSound = nil

	if oldSound and oldSound.Parent then
		log(string.format("Previous track stopping: name=%s id=%s", oldSound.Name, oldSound.SoundId))
		_fadingOutSound = oldSound
		local fadeOut = TweenService:Create(oldSound, TweenInfo.new(CROSSFADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Volume = 0,
		})
		_fadeOutTween = fadeOut
		fadeOut:Play()

		local capturedSound = oldSound
		task.spawn(function()
			fadeOut.Completed:Wait()
			if capturedSound and capturedSound.Parent then
				capturedSound:Stop()
				capturedSound:Destroy()
			end
			if _fadingOutSound == capturedSound then
				_fadingOutSound = nil
				_fadeOutTween = nil
			end
		end)
	end

	-- Create and fade in the new sound immediately (overlaps with old fade-out)
	local newSound = createMusicSound(newName, newId, looped)
	newSound.TimePosition = newStart
	newSound.Volume = 0
	activeSound = newSound

	logMusicDiagnostics("before_play", newSound, string.format("requestedStart=%.2f targetVolume=%.2f", newStart, newVolume))
	newSound:Play()
	logMusicDiagnostics("after_play_call", newSound, string.format("requestedStart=%.2f targetVolume=%.2f", newStart, newVolume))

	if not newSound.IsLoaded then
		task.spawn(function()
			newSound.Loaded:Wait()
			if newSound.Parent then
				logMusicDiagnostics("loaded", newSound, "loaded_event=true")
			end
		end)
	end

	task.delay(2, function()
		if activeSound ~= newSound or not newSound.Parent then
			return
		end
		logMusicDiagnostics("post_play_check", newSound, string.format("requestedStart=%.2f targetVolume=%.2f", newStart, newVolume))
		if not newSound.IsLoaded then
			logPossiblePermissionIssue(newSound, "post_play_check")
		end
	end)

	local fadeIn = TweenService:Create(newSound, TweenInfo.new(CROSSFADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Volume = newVolume,
	})
	activeFadeTween = fadeIn
	fadeIn:Play()

	task.spawn(function()
		fadeIn.Completed:Wait()
		if activeFadeTween == fadeIn then
			activeFadeTween = nil
		end
	end)

	log(string.format("Crossfade → %s (%s at %.0fs vol=%.2f)", newName, newId, newStart, newVolume))
	logState()
end

-- ═══════════════════════════════════════════════════════════════════
-- LOBBY MUSIC
-- ═══════════════════════════════════════════════════════════════════

local function cancelNormalMapPlaylist(reason: string)
	normalPlaylistToken += 1
	if currentContext == "normal_match" then
		log(string.format("[MapMusicAudit] context=normal_match playlistCancelled reason=%s token=%d", reason, normalPlaylistToken))
	end
end

local playNormalMapPlaylistTrack

local function scheduleNormalMapPlaylistAdvance(token: number, trackIndex: number, sound: Sound)
	if #NORMAL_MAP_TRACKS <= 1 then
		return
	end

	task.spawn(function()
		if not sound.IsLoaded then
			sound.Loaded:Wait()
		end
		if normalPlaylistToken ~= token or activeSound ~= sound or currentContext ~= "normal_match" or not sound.Parent then
			return
		end

		local remaining = sound.TimeLength - sound.TimePosition
		if remaining <= 0 then
			remaining = CROSSFADE_TIME
		end
		local advanceDelay = math.max(remaining - CROSSFADE_TIME, 0.1)
		log(string.format(
			"[MapMusicAudit] context=normal_match playlistScheduled track=%d/%d soundId=%s delay=%.2f",
			trackIndex,
			#NORMAL_MAP_TRACKS,
			sound.SoundId,
			advanceDelay
		))

		task.wait(advanceDelay)
		if normalPlaylistToken ~= token or activeSound ~= sound or currentContext ~= "normal_match" or not sound.Parent then
			return
		end

		local nextTrackIndex = (trackIndex % #NORMAL_MAP_TRACKS) + 1
		local nextTrack = NORMAL_MAP_TRACKS[nextTrackIndex]
		log(string.format(
			"[MapMusicAudit] context=normal_match playlistAdvance from=%d to=%d nextSoundId=%s",
			trackIndex,
			nextTrackIndex,
			nextTrack.Id
		))
		playNormalMapPlaylistTrack(token, nextTrackIndex)
	end)
end

playNormalMapPlaylistTrack = function(token: number, trackIndex: number)
	if normalPlaylistToken ~= token or currentContext ~= "normal_match" then
		return
	end

	local track = NORMAL_MAP_TRACKS[trackIndex]
	if not track then
		return
	end

	log(string.format(
		"[MapMusicAudit] context=normal_match playlistTrack=%d/%d selectedSoundId=%s start=%.2f volume=%.2f",
		trackIndex,
		#NORMAL_MAP_TRACKS,
		track.Id,
		track.Start or 0,
		NORMAL_MAP_TRACK_VOLUME
	))
	crossfadeTo(string.format("MapMusic_Normal_%d", trackIndex), track.Id, track.Start or 0, NORMAL_MAP_TRACK_VOLUME, false)

	local scheduledSound = activeSound
	if scheduledSound then
		scheduleNormalMapPlaylistAdvance(token, trackIndex, scheduledSound)
	end
end

local function pickLobbyTrack(): (string, number, number)
	if math.random() < LOBBY_TRACK_A_CHANCE then
		return LOBBY_TRACK_A_ID, LOBBY_TRACK_A_START, LOBBY_TRACK_A_VOLUME
	else
		return LOBBY_TRACK_B_ID, LOBBY_TRACK_B_START, LOBBY_TRACK_B_VOLUME
	end
end

local function startLobby()
	if currentContext == "lobby" then return end
	cancelNormalMapPlaylist("switch_to_lobby")
	currentContext = "lobby"
	log("Context → lobby")

	local trackId, startPos, volume = pickLobbyTrack()
	log(string.format("[MapMusicAudit] context=lobby selectedSoundId=%s start=%.2f volume=%.2f", trackId, startPos, volume))
	crossfadeTo("LobbyMusic", trackId, startPos, volume, true)
end

-- ═══════════════════════════════════════════════════════════════════
-- MAP MUSIC
-- ═══════════════════════════════════════════════════════════════════

local function startNormalMap()
	if currentContext == "normal_match" then return end
	cancelNormalMapPlaylist("restart_normal_playlist")
	currentContext = "normal_match"
	log("Context → normal_match")
	normalPlaylistToken += 1
	log(string.format(
		"[MapMusicAudit] context=normal_match playlistStart tracks=%s volume=%.2f token=%d",
		describeTrackSequence(NORMAL_MAP_TRACKS),
		NORMAL_MAP_TRACK_VOLUME,
		normalPlaylistToken
	))
	if #NORMAL_MAP_TRACKS <= 1 then
		local onlyTrack = NORMAL_MAP_TRACKS[1]
		if onlyTrack then
			crossfadeTo("MapMusic_Normal", onlyTrack.Id, onlyTrack.Start or 0, NORMAL_MAP_TRACK_VOLUME, true)
		end
		return
	end
	playNormalMapPlaylistTrack(normalPlaylistToken, 1)
end

local function startBrainrotMap()
	if currentContext == "brainrot_match" then return end
	cancelNormalMapPlaylist("switch_to_brainrot")
	currentContext = "brainrot_match"
	log("Context → brainrot_match")
	log(string.format("[MapMusicAudit] context=brainrot_match selectedSoundId=%s start=%.2f volume=%.2f", BRAINROT_MAP_TRACK_ID, BRAINROT_MAP_TRACK_START, BRAINROT_MAP_TRACK_VOLUME))
	-- Smooth transition requirement: fade from lobby -> brainrot (and any context switch) via crossfade.
	crossfadeTo("MapMusic_Brainrot", BRAINROT_MAP_TRACK_ID, BRAINROT_MAP_TRACK_START, BRAINROT_MAP_TRACK_VOLUME, true)
end

-- ═══════════════════════════════════════════════════════════════════
-- CONTEXT DETECTION
-- ═══════════════════════════════════════════════════════════════════

local function resolveAudioStateFromContext(state: string?): string
	-- Only players actively in the match hear match music.
	local matchState = matchStatusStateValue and matchStatusStateValue.Value or nil
	local modeVoteActive = modeVoteActiveValue and modeVoteActiveValue.Value == true or false
	if state == PlayerState.States.InMatch and matchState == "Playing" and not modeVoteActive then
		local mode = matchStatusModeValue and matchStatusModeValue.Value or "Normal"
		if mode == "Brainrot" then
			return "BrainrotMatch"
		end
		return "NormalMatch"
	end
	-- Lobby/Waiting/AFK/Spectating/default: lobby music only.
	return "Lobby"
end

local function updateContext()
	local state = LocalPlayer:GetAttribute("PlayerState")
	local audioState = resolveAudioStateFromContext(state)
	if audioState == "NormalMatch" then
		startNormalMap()
	elseif audioState == "BrainrotMatch" then
		startBrainrotMap()
	else
		startLobby()
	end

	if state ~= lastLoggedPlayerState or audioState ~= lastLoggedAudioState then
		lastLoggedPlayerState = state
		lastLoggedAudioState = audioState
		local selectedMusicId = activeSound and activeSound.SoundId or "none"
		log(string.format(
			"[MusicState] player=%s audioState=%s playerState=%s selectedMusicId=%s",
			LocalPlayer.Name,
			audioState,
			tostring(state),
			tostring(selectedMusicId)
		))
	end
end

-- ═══════════════════════════════════════════════════════════════════
-- SFX (persistent, not single-channel)
-- ═══════════════════════════════════════════════════════════════════

local function initSFX()
	-- Win SFX
	winSfx = SoundService:FindFirstChild("WinSFX")
	if not winSfx then
		winSfx = Instance.new("Sound")
		winSfx.Name = "WinSFX"
		winSfx.SoundId = WIN_SFX_ID
		winSfx.Looped = false
		winSfx.Volume = SFX_VOLUME
		winSfx.Parent = SoundService
	end

	-- Intermission countdown SFX
	intermissionSfx = SoundService:FindFirstChild("IntermissionSFX")
	if not intermissionSfx then
		intermissionSfx = Instance.new("Sound")
		intermissionSfx.Name = "IntermissionSFX"
		intermissionSfx.SoundId = INTERMISSION_SFX_ID
		intermissionSfx.Looped = false
		intermissionSfx.Volume = COUNTDOWN_VOLUME
		intermissionSfx.Parent = SoundService
	end

	-- PlaySFX remote
	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
		if not remotes then return end
		local sfxRemote = remotes:WaitForChild("PlaySFX", 15)
		if not sfxRemote then return end

		sfxRemote.OnClientEvent:Connect(function(sfxType: string)
			if (sfxType == "Win" or sfxType == "ObbyComplete") and winSfx then
				winSfx.Volume = SFX_VOLUME
				winSfx:Stop()
				winSfx:Play()
				log("SFX → " .. sfxType)
			end
		end)
	end)
end

-- ═══════════════════════════════════════════════════════════════════
-- INIT
-- ═══════════════════════════════════════════════════════════════════

function MusicController.Init()
	if _initialized then return end
	_initialized = true

	-- 1. Create BGM SoundGroup (SettingsPanel finds this)
	bgmGroup = SoundService:FindFirstChild("BGM")
	if not bgmGroup then
		bgmGroup = Instance.new("SoundGroup")
		bgmGroup.Name = "BGM"
		bgmGroup.Volume = 1
		bgmGroup.Parent = SoundService
	end

	-- 2. Purge ALL legacy sounds (old map music, duplicates)
	purgeLegacySounds()

	-- 3. Init SFX (win + intermission — these are persistent, NOT single-channel)
	initSFX()

	-- 4. Listen for PlayerState changes (primary context signal)
	LocalPlayer:GetAttributeChangedSignal("PlayerState"):Connect(function()
		updateContext()
		syncIntermissionCountdownSfx("player_state_changed")
	end)

	-- 5. Listen for MatchStatus (secondary signal + intermission countdown)
	task.spawn(function()
		local matchStatus = ReplicatedStorage:FindFirstChild("MatchStatus")
		if not matchStatus then
			matchStatus = ReplicatedStorage:WaitForChild("MatchStatus", 15)
		end
		if not matchStatus then
			warn("[MusicController] MatchStatus not found — using PlayerState only")
			return
		end

		local stateVal    = matchStatus:WaitForChild("State", 10)
		local phaseEndVal = matchStatus:WaitForChild("PhaseEndTime", 10)
		local modeVal     = matchStatus:WaitForChild("Mode", 10)
		local voteActiveVal = matchStatus:WaitForChild("ModeVoteActive", 10)
		if stateVal and stateVal:IsA("StringValue") then
			matchStatusStateValue = stateVal
		end
		if phaseEndVal and phaseEndVal:IsA("NumberValue") then
			matchStatusPhaseEndValue = phaseEndVal
		end
		if modeVal and modeVal:IsA("StringValue") then
			matchStatusModeValue = modeVal
			modeVal.Changed:Connect(function()
				-- Re-evaluate per-player routing when selected match mode changes.
				updateContext()
			end)
		end
		if voteActiveVal and voteActiveVal:IsA("BoolValue") then
			modeVoteActiveValue = voteActiveVal
			voteActiveVal.Changed:Connect(function()
				updateContext()
			end)
		end

		if stateVal then
			stateVal.Changed:Connect(function()
				-- MatchStatus is global; do not drive per-player music from it.
				-- Re-evaluate using local authoritative PlayerState only.
				updateContext()
				syncIntermissionCountdownSfx("match_state_changed")
			end)
		end

		if phaseEndVal then
			phaseEndVal.Changed:Connect(function()
				syncIntermissionCountdownSfx("phase_end_changed")
			end)
		end

		-- Intermission countdown SFX stays in sync with replicated state/end time.
		if phaseEndVal and stateVal then
			RunService.Heartbeat:Connect(function()
				syncIntermissionCountdownSfx("heartbeat")
			end)
		end

		syncIntermissionCountdownSfx("match_status_ready")
	end)

	-- 6. Start with correct context immediately
	updateContext()
	log(string.format(
		"[MapMusicAudit] configuredIds lobbyA=%s lobbyB=%s normalMap=%s brainrotMap=%s",
		LOBBY_TRACK_A_ID,
		LOBBY_TRACK_B_ID,
		describeTrackSequence(NORMAL_MAP_TRACKS),
		BRAINROT_MAP_TRACK_ID
	))

	log("Initialized — legacy sounds purged, crossfade active")
	logState()
end

return MusicController
