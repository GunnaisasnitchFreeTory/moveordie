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

local MusicController = {}

-- ═══════════════════════════════════════════════════════════════════
-- CONFIG
-- ═══════════════════════════════════════════════════════════════════

-- Lobby track A: original lobby music (10%)
local LOBBY_TRACK_A_ID      = "rbxassetid://132796863583176"
local LOBBY_TRACK_A_START   = 0
local LOBBY_TRACK_A_VOLUME  = 0.35
local LOBBY_TRACK_A_CHANCE  = 0.10

-- Lobby track B: alt lobby music (90%)
local LOBBY_TRACK_B_ID      = "rbxassetid://100199384595840"
local LOBBY_TRACK_B_START   = 10
local LOBBY_TRACK_B_VOLUME  = 1.0

-- Map music (ONLY this track — no others)
local MAP_TRACK_ID          = "rbxassetid://79513722933054"
local MAP_TRACK_START       = 32
local MAP_TRACK_VOLUME      = 0.48

-- Crossfade transition (both tracks overlap — no silent gap)
local CROSSFADE_TIME        = 1.5

-- SFX
local SFX_VOLUME            = 0.8
local COUNTDOWN_VOLUME      = 0.24
local COUNTDOWN_THRESHOLD   = 5.0
local WIN_SFX_ID            = "rbxassetid://111217342629113"
local INTERMISSION_SFX_ID   = "rbxassetid://115128556144522"

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
local currentContext: string?    = nil   -- "lobby" | "map"
local intermissionWarned         = false
local _initialized               = false

-- SFX sounds (persistent, not part of single-channel)
local winSfx: Sound?             = nil
local intermissionSfx: Sound?    = nil

-- Hard-stop intermission countdown SFX and reset playback position
local function stopIntermissionSfx()
	if intermissionSfx and intermissionSfx.Playing then
		intermissionSfx:Stop()
		intermissionSfx.TimePosition = 0
	end
end

-- ═══════════════════════════════════════════════════════════════════
-- LOGGING
-- ═══════════════════════════════════════════════════════════════════

local function log(...)
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

	newSound:Play()

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

local function pickLobbyTrack(): (string, number, number)
	if math.random() < LOBBY_TRACK_A_CHANCE then
		return LOBBY_TRACK_A_ID, LOBBY_TRACK_A_START, LOBBY_TRACK_A_VOLUME
	else
		return LOBBY_TRACK_B_ID, LOBBY_TRACK_B_START, LOBBY_TRACK_B_VOLUME
	end
end

local function startLobby()
	if currentContext == "lobby" then return end
	currentContext = "lobby"
	log("Context → lobby")

	local trackId, startPos, volume = pickLobbyTrack()
	crossfadeTo("LobbyMusic", trackId, startPos, volume, true)
end

-- ═══════════════════════════════════════════════════════════════════
-- MAP MUSIC
-- ═══════════════════════════════════════════════════════════════════

local function startMap()
	if currentContext == "map" then return end
	currentContext = "map"
	log("Context → map")

	crossfadeTo("MapMusic", MAP_TRACK_ID, MAP_TRACK_START, MAP_TRACK_VOLUME, true)
end

-- ═══════════════════════════════════════════════════════════════════
-- CONTEXT DETECTION
-- ═══════════════════════════════════════════════════════════════════

local function updateContext()
	local state = LocalPlayer:GetAttribute("PlayerState")
	if state == "InMatch" then
		startMap()
	else
		startLobby()
	end
end

local function onMatchStateChanged(matchState: string)
	if matchState == "Playing" then
		startMap()
	else
		startLobby()
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
		local state = LocalPlayer:GetAttribute("PlayerState")
		updateContext()
		-- Stop countdown SFX immediately when going AFK; do NOT reset
		-- intermissionWarned so it won't replay on the same intermission
		if state == "AFK" then
			stopIntermissionSfx()
		end
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

		if stateVal then
		stateVal.Changed:Connect(function()
			onMatchStateChanged(stateVal.Value)
			-- Reset flag so the next intermission cycle can trigger the SFX
			intermissionWarned = false
			-- If leaving intermission, hard-stop any playing countdown SFX
			if stateVal.Value ~= "Intermission" then
				stopIntermissionSfx()
			end
		end)
		end

		-- Intermission 5-second countdown SFX
		if phaseEndVal and stateVal then
			RunService.Heartbeat:Connect(function()
				if intermissionWarned then return end
				if stateVal.Value ~= "Intermission" then return end
				if LocalPlayer:GetAttribute("PlayerState") == "AFK" then return end
				local remaining = phaseEndVal.Value - workspace:GetServerTimeNow()
				if remaining <= COUNTDOWN_THRESHOLD and remaining > 0.5 then
					intermissionWarned = true
					if intermissionSfx then
						intermissionSfx.Volume = COUNTDOWN_VOLUME
						intermissionSfx:Stop()
						intermissionSfx:Play()
					end
				end
			end)
		end
	end)

	-- 6. Start with correct context immediately
	updateContext()

	log("Initialized — legacy sounds purged, crossfade active")
	logState()
end

return MusicController