--[[
	EffectsConfig
	Client-side-only visual impact tuning for match feedback.
]]

local EffectsConfig = {}

EffectsConfig.DebugLogs = true
EffectsConfig.DisplayOrder = 60

EffectsConfig.RoundScaling = {
	LightRoundsMax = 2,
	MediumRoundsMax = 4,
	LightMultiplier = 1.06,
	MediumMultiplier = 1.16,
	LateMultiplier = 1.28,
	MaxMultiplier = 1.3,
}

EffectsConfig.CameraShake = {
	RenderStepName = "FateBeamsEffectsShake",
	MaxSimultaneous = 8,
	MaxOffsetStuds = 0.68,
	DepthMultiplier = 0.52,
	MinDuration = 0.18,
	MaxPulseDuration = 0.72,
	MaxSustainDuration = 5.0,
	MaxPerShakeIntensity = 0.44,
	DefaultAttackTime = 0.02,
	DefaultHoldTime = 0.05,
	DefaultDecayTime = 0.26,

	BeamPreStrike = {
		Intensity = 0.18,
		Duration = 4.0,
		Frequency = 13,
		AttackTime = 0.12,
		DecayTime = 0.24,
		Sustain = true,
	},

	BeamStrike = {
		Intensity = 0.42,
		Duration = 0.46,
		Frequency = 22,
		AttackTime = 0.01,
		HoldTime = 0.1,
		DecayTime = 0.36,
	},

	BeamDecay = {
		Intensity = 0.15,
		Duration = 0.34,
		Frequency = 15,
		AttackTime = 0.0,
		HoldTime = 0.04,
		DecayTime = 0.28,
	},

	Elimination = {
		Intensity = 0.15,
		Duration = 0.32,
		Frequency = 17,
		AttackTime = 0.01,
		HoldTime = 0.04,
		DecayTime = 0.26,
	},
}

EffectsConfig.ScreenFlash = {
	BeamStrike = {
		Color = Color3.fromRGB(255, 242, 234),
		Intensity = 0.24,
		FadeOutTime = 0.22,
		MinimumTransparency = 0.77,
	},
}

EffectsConfig.RoundText = {
	FadeInTime = 0.12,
	HoldTime = 0.42,
	FadeOutTime = 0.18,
	PositionYScale = 0.40,
	MaxTextSize = 56,
	MinTextSize = 28,
	StartScale = 1.08,
	EndScale = 1.0,
	ExitScale = 0.96,
	Color = Color3.fromRGB(255, 243, 184),
	StrokeColor = Color3.fromRGB(63, 21, 0),
}

EffectsConfig.EliminationBurst = {
	Texture = "rbxasset://textures/particles/sparkles_main.dds",
	EmitCount = 10,
	MinEmitCount = 7,
	MaxEmitCount = 14,
	CleanupSeconds = 1.25,
	LifetimeMin = 0.25,
	LifetimeMax = 0.45,
	SpeedMin = 6,
	SpeedMax = 10,
	Drag = 4,
	SizeStart = 0.5,
	SizeMid = 0.22,
	LightEmission = 0.85,
	LightInfluence = 0,
	Brightness = 2,
	ColorStart = Color3.fromRGB(255, 194, 82),
	ColorEnd = Color3.fromRGB(255, 94, 70),
}

EffectsConfig.EliminationWindowSeconds = 0.35

return EffectsConfig
