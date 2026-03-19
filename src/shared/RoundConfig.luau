--[[
	RoundConfig
	Shared configuration for round timing and behavior.
	
	Round cycle: FreeMove → Telegraph → BeamWarning → Strike → Recovery
	
	Used by: RoundManager
]]

local RoundConfig = {}

RoundConfig.BaseTimings = {
	InteractionWindowSeconds = 1.8,
	FreeMoveSeconds = 5.0,
	TelegraphGraceSeconds = 0.3,
	TelegraphSeconds = 1.3,
	FreezeSeconds = 3.2,
	StrikeSeconds = 0.22,
	RecoverySeconds = 0.35,
}

RoundConfig.RoundPacingConfig = {
	EarlyRounds = {
		startRound = 1,
		endRound = 4,
		start = {
			InteractionWindowSeconds = 2.2,
			FreeMoveSeconds = 4.2,
			TelegraphGraceSeconds = 0.22,
			TelegraphSeconds = 1.1,
			FreezeSeconds = 2.8,
			StrikeSeconds = 0.22,
			RecoverySeconds = 0.28,
		},
		finish = {
			InteractionWindowSeconds = 2.0,
			FreeMoveSeconds = 4.9,
			TelegraphGraceSeconds = 0.3,
			TelegraphSeconds = 1.35,
			FreezeSeconds = 3.2,
			StrikeSeconds = 0.22,
			RecoverySeconds = 0.34,
		},
	},
	MidRounds = {
		startRound = 5,
		endRound = 10,
		start = {
			InteractionWindowSeconds = 1.9,
			FreeMoveSeconds = 5.0,
			TelegraphGraceSeconds = 0.3,
			TelegraphSeconds = 1.3,
			FreezeSeconds = 3.15,
			StrikeSeconds = 0.22,
			RecoverySeconds = 0.34,
		},
		finish = {
			InteractionWindowSeconds = 1.7,
			FreeMoveSeconds = 4.5,
			TelegraphGraceSeconds = 0.25,
			TelegraphSeconds = 1.1,
			FreezeSeconds = 2.85,
			StrikeSeconds = 0.2,
			RecoverySeconds = 0.3,
		},
	},
	LateRounds = {
		startRound = 11,
		endRound = 20,
		start = {
			InteractionWindowSeconds = 1.6,
			FreeMoveSeconds = 4.4,
			TelegraphGraceSeconds = 0.24,
			TelegraphSeconds = 1.05,
			FreezeSeconds = 2.75,
			StrikeSeconds = 0.2,
			RecoverySeconds = 0.28,
		},
		finish = {
			InteractionWindowSeconds = 1.4,
			FreeMoveSeconds = 3.8,
			TelegraphGraceSeconds = 0.2,
			TelegraphSeconds = 0.9,
			FreezeSeconds = 2.3,
			StrikeSeconds = 0.18,
			RecoverySeconds = 0.22,
		},
	},
	EndgameRounds = {
		startRound = 21,
		endRound = 35,
		start = {
			InteractionWindowSeconds = 1.35,
			FreeMoveSeconds = 3.75,
			TelegraphGraceSeconds = 0.2,
			TelegraphSeconds = 0.88,
			FreezeSeconds = 2.25,
			StrikeSeconds = 0.18,
			RecoverySeconds = 0.22,
		},
		finish = {
			InteractionWindowSeconds = 1.2,
			FreeMoveSeconds = 3.2,
			TelegraphGraceSeconds = 0.15,
			TelegraphSeconds = 0.75,
			FreezeSeconds = 2.0,
			StrikeSeconds = 0.16,
			RecoverySeconds = 0.18,
		},
	},
}

RoundConfig.TimingLimits = {
	MinInteractionWindowSeconds = 1.2,
	MinFreeMoveSeconds = 3.0,
	MinTelegraphGraceSeconds = 0.12,
	MinTelegraphSeconds = 0.72,
	MinFreezeSeconds = 1.95,
	MinStrikeSeconds = 0.16,
	MinRecoverySeconds = 0.18,
	MinBeamWarningSeconds = 0.9,
}

RoundConfig.EarlyRoundOverrides = {
	[1] = {
		InteractionWindowSeconds = 2.4,
		FreeMoveSeconds = 4.8,
		TelegraphGraceSeconds = 0.35,
		TelegraphSeconds = 1.45,
		FreezeSeconds = 3.35,
		StrikeSeconds = 0.22,
		RecoverySeconds = 0.32,
	},
	[2] = {
		InteractionWindowSeconds = 2.25,
		FreeMoveSeconds = 4.95,
		TelegraphGraceSeconds = 0.34,
		TelegraphSeconds = 1.42,
		FreezeSeconds = 3.3,
		StrikeSeconds = 0.22,
		RecoverySeconds = 0.32,
	},
	[3] = {
		InteractionWindowSeconds = 2.15,
		FreeMoveSeconds = 5.0,
		TelegraphGraceSeconds = 0.32,
		TelegraphSeconds = 1.38,
		FreezeSeconds = 3.25,
		StrikeSeconds = 0.22,
		RecoverySeconds = 0.32,
	},
}

local function cloneTimings(source)
	return {
		InteractionWindowSeconds = tonumber(source.InteractionWindowSeconds) or 0,
		FreeMoveSeconds = tonumber(source.FreeMoveSeconds) or 0,
		TelegraphGraceSeconds = tonumber(source.TelegraphGraceSeconds) or 0,
		TelegraphSeconds = tonumber(source.TelegraphSeconds) or 0,
		FreezeSeconds = tonumber(source.FreezeSeconds) or 0,
		StrikeSeconds = tonumber(source.StrikeSeconds) or 0,
		RecoverySeconds = tonumber(source.RecoverySeconds) or 0,
	}
end

local function lerp(a: number, b: number, alpha: number): number
	return a + (b - a) * alpha
end

local function clamp(v: number, minV: number, maxV: number): number
	return math.max(minV, math.min(maxV, v))
end

local function getPhaseProfile(roundNumber: number)
	for _, key in ipairs({ "EarlyRounds", "MidRounds", "LateRounds", "EndgameRounds" }) do
		local profile = RoundConfig.RoundPacingConfig[key]
		if profile and roundNumber >= profile.startRound and roundNumber <= profile.endRound then
			return profile
		end
	end
	return nil
end

local function applyTimingLimits(timings)
	local limits = RoundConfig.TimingLimits
	timings.InteractionWindowSeconds = math.max(limits.MinInteractionWindowSeconds, timings.InteractionWindowSeconds)
	timings.FreeMoveSeconds = math.max(limits.MinFreeMoveSeconds, timings.FreeMoveSeconds)
	timings.TelegraphGraceSeconds = math.max(limits.MinTelegraphGraceSeconds, timings.TelegraphGraceSeconds)
	timings.TelegraphSeconds = math.max(limits.MinTelegraphSeconds, timings.TelegraphSeconds)
	timings.FreezeSeconds = math.max(limits.MinFreezeSeconds, timings.FreezeSeconds)
	timings.StrikeSeconds = math.max(limits.MinStrikeSeconds, timings.StrikeSeconds)
	timings.RecoverySeconds = math.max(limits.MinRecoverySeconds, timings.RecoverySeconds)
	if timings.FreezeSeconds < timings.TelegraphSeconds + limits.MinBeamWarningSeconds then
		timings.FreezeSeconds = timings.TelegraphSeconds + limits.MinBeamWarningSeconds
	end
	if timings.InteractionWindowSeconds > timings.FreeMoveSeconds then
		timings.InteractionWindowSeconds = timings.FreeMoveSeconds
	end
	return timings
end

function RoundConfig.IsEarlyOverrideRound(roundNumber: number): boolean
	return roundNumber >= RoundConfig.RoundPacingConfig.EarlyRounds.startRound
		and roundNumber <= RoundConfig.RoundPacingConfig.EarlyRounds.endRound
end

function RoundConfig.GetPacingTier(roundNumber: number): string
	if RoundConfig.EarlyRoundOverrides[roundNumber] ~= nil then
		return "EarlyRelaxed"
	end
	local profile = getPhaseProfile(roundNumber)
	if not profile then
		if roundNumber > RoundConfig.RoundPacingConfig.EndgameRounds.endRound then
			return "Endgame+"
		end
		return "Base"
	end
	for tierName, candidate in pairs(RoundConfig.RoundPacingConfig) do
		if candidate == profile then
			return tierName
		end
	end
	return "Base"
end

function RoundConfig.GetTimingsForRound(roundNumber: number)
	local resolved = cloneTimings(RoundConfig.BaseTimings)
	local profile = getPhaseProfile(roundNumber)
	if profile then
		local startRound = tonumber(profile.startRound) or roundNumber
		local endRound = tonumber(profile.endRound) or roundNumber
		local span = math.max(1, endRound - startRound)
		local alpha = clamp((roundNumber - startRound) / span, 0, 1)
		local from = profile.start or resolved
		local to = profile.finish or from
		resolved = {
			InteractionWindowSeconds = lerp(tonumber(from.InteractionWindowSeconds) or resolved.InteractionWindowSeconds, tonumber(to.InteractionWindowSeconds) or resolved.InteractionWindowSeconds, alpha),
			FreeMoveSeconds = lerp(tonumber(from.FreeMoveSeconds) or resolved.FreeMoveSeconds, tonumber(to.FreeMoveSeconds) or resolved.FreeMoveSeconds, alpha),
			TelegraphGraceSeconds = lerp(tonumber(from.TelegraphGraceSeconds) or resolved.TelegraphGraceSeconds, tonumber(to.TelegraphGraceSeconds) or resolved.TelegraphGraceSeconds, alpha),
			TelegraphSeconds = lerp(tonumber(from.TelegraphSeconds) or resolved.TelegraphSeconds, tonumber(to.TelegraphSeconds) or resolved.TelegraphSeconds, alpha),
			FreezeSeconds = lerp(tonumber(from.FreezeSeconds) or resolved.FreezeSeconds, tonumber(to.FreezeSeconds) or resolved.FreezeSeconds, alpha),
			StrikeSeconds = lerp(tonumber(from.StrikeSeconds) or resolved.StrikeSeconds, tonumber(to.StrikeSeconds) or resolved.StrikeSeconds, alpha),
			RecoverySeconds = lerp(tonumber(from.RecoverySeconds) or resolved.RecoverySeconds, tonumber(to.RecoverySeconds) or resolved.RecoverySeconds, alpha),
		}
	end

	local override = RoundConfig.EarlyRoundOverrides[roundNumber]
	if override then
		for key, value in pairs(override) do
			if resolved[key] ~= nil then
				resolved[key] = tonumber(value) or resolved[key]
			end
		end
	end

	return applyTimingLimits(resolved)
end

-- Backward-compatible flat accessors for code that still reads the base profile directly.
RoundConfig.InteractionWindowSeconds = RoundConfig.BaseTimings.InteractionWindowSeconds
RoundConfig.FreeMoveSeconds = RoundConfig.BaseTimings.FreeMoveSeconds
RoundConfig.TelegraphGraceSeconds = RoundConfig.BaseTimings.TelegraphGraceSeconds
RoundConfig.TelegraphSeconds = RoundConfig.BaseTimings.TelegraphSeconds
RoundConfig.FreezeSeconds = RoundConfig.BaseTimings.FreezeSeconds
RoundConfig.StrikeSeconds = RoundConfig.BaseTimings.StrikeSeconds
RoundConfig.RecoverySeconds = RoundConfig.BaseTimings.RecoverySeconds

-- Match limits (caps to prevent infinite matches)
RoundConfig.MaxRoundsPerMatch = 0     -- 0 = unlimited
RoundConfig.MaxMatchSeconds = 360     -- 6 minutes max (allows full 20-round matches with current pacing)

-- Winner detection
RoundConfig.MinPlayersForWinner = 2   -- Need at least 2 players to declare a winner
                                       -- Solo player matches run until cap or death

-- Debug
RoundConfig.DebugLog = true

return RoundConfig
