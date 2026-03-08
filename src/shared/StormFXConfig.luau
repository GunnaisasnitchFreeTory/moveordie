--[[
	StormFXConfig
	Shared configuration for storm visual effects.
	
	Client FX logic (StormFXController):
	  shouldStorm = (cameraOutside OR playerOutside)
	  - cameraOutside: camera XZ position is past arena bounds + CamOutsideMargin
	  - playerOutside: HumanoidRootPart XZ position is past arena bounds
	  Both checks use POSITION only — no look-vector, no FOV, no pitch dependency.
	
	Effects are screen-space ONLY (Atmosphere + CC + Bloom).
	No particles are attached to the player character.
	
	ON  transition: tween Atmosphere (smooth 0.15s), enable CC + Bloom
	OFF transition: INSTANT SNAP Atmosphere to original, disable CC + Bloom
	                (no tween on OFF — prevents stuck/dark lighting states)
	
	Particle factory (CreateStormParticles) is server-side only,
	used by MapManager (barrier walls) and HazardManager (beams).
	
	Storm color single source of truth: ShrinkConfig.BoundsColor
]]

local ShrinkConfig = require(script.Parent:WaitForChild("ShrinkConfig"))

local StormFXConfig = {}

---------- STORM COLOR (single source of truth) ----------

StormFXConfig.StormColor = ShrinkConfig.BoundsColor

---------- MASTER SWITCH ----------

StormFXConfig.Enabled = true

---------- TRIGGER THRESHOLDS ----------

-- Camera: ON when camera XZ is >= CamOutsideMargin studs outside the arena bounds
StormFXConfig.CameraOutsideMarginStuds = 5

---------- HYSTERESIS (anti-flicker enter/exit band) ----------
-- Camera: ON at +CamOutMargin (5), OFF at +(CamOutMargin - Hyst) (0 = edge)
-- Player: ON at 0 (just outside),   OFF at -Hyst (-5 = 5 studs back inside)
-- Band is small enough to feel instant, large enough to prevent flicker.
-- Response is immediate once a threshold is crossed — no time-based delay.

StormFXConfig.HysteresisStuds = 5

---------- UPDATE RATE ----------

StormFXConfig.MinUpdateInterval = 0.05  -- 20 Hz evaluation; feels instant, saves CPU

---------- BOUNDS CACHE ----------

StormFXConfig.BoundsCacheInterval = 0.5  -- Refresh wall positions (walls only move on shrink)

---------- ATMOSPHERE OVERLAY (screen-space) ----------

StormFXConfig.AtmosphereDensity = 0.3
StormFXConfig.AtmosphereHaze = 6
StormFXConfig.AtmosphereColor = Color3.fromRGB(255, 180, 130)
StormFXConfig.AtmosphereDecay = Color3.fromRGB(120, 100, 80)

---------- COLOR CORRECTION (screen-space) ----------

StormFXConfig.CCTintColor = Color3.fromRGB(255, 230, 200)  -- Warm tint
StormFXConfig.CCBrightness = -0.02   -- Slight dimming
StormFXConfig.CCContrast = 0.05      -- Slight contrast boost
StormFXConfig.CCSaturation = -0.1    -- Slight desaturation (storm feel)

---------- BLOOM (screen-space) ----------

StormFXConfig.BloomIntensity = 0.3
StormFXConfig.BloomSize = 24
StormFXConfig.BloomThreshold = 2

---------- MODE PROFILES ----------

local PROFILES = {
	Normal = {
		StormColor = ShrinkConfig.BoundsColor,
		ParticleMistStartColor = Color3.fromRGB(255, 180, 100),
		ParticleMistEndColor = Color3.fromRGB(255, 100, 30),
		ParticleSparksColor = Color3.fromRGB(255, 220, 150),
		AtmosphereDensity = 0.3,
		AtmosphereHaze = 6,
		AtmosphereColor = Color3.fromRGB(255, 180, 130),
		AtmosphereDecay = Color3.fromRGB(120, 100, 80),
		CCTintColor = Color3.fromRGB(255, 230, 200),
		CCBrightness = -0.02,
		CCContrast = 0.05,
		CCSaturation = -0.1,
		BloomIntensity = 0.3,
		BloomSize = 24,
		BloomThreshold = 2,
	},
	Brainrot = {
		StormColor = Color3.fromRGB(85, 175, 245),
		ParticleMistStartColor = Color3.fromRGB(195, 238, 255),
		ParticleMistEndColor = Color3.fromRGB(120, 180, 245),
		ParticleSparksColor = Color3.fromRGB(220, 245, 255),
		AtmosphereDensity = 0.3,
		AtmosphereHaze = 6,
		AtmosphereColor = Color3.fromRGB(165, 220, 255),
		AtmosphereDecay = Color3.fromRGB(70, 110, 150),
		CCTintColor = Color3.fromRGB(205, 235, 255),
		CCBrightness = -0.01,
		CCContrast = 0.06,
		CCSaturation = -0.06,
		BloomIntensity = 0.28,
		BloomSize = 22,
		BloomThreshold = 2,
	},
}

StormFXConfig.ActiveProfileName = "Normal"

function StormFXConfig.ApplyProfile(profileName: string?)
	local name = if type(profileName) == "string" and profileName ~= "" then profileName else "Normal"
	local profile = PROFILES[name] or PROFILES.Normal
	StormFXConfig.ActiveProfileName = if PROFILES[name] then name else "Normal"

	StormFXConfig.StormColor = profile.StormColor
	StormFXConfig.ParticleMistStartColor = profile.ParticleMistStartColor
	StormFXConfig.ParticleMistEndColor = profile.ParticleMistEndColor
	StormFXConfig.ParticleSparksColor = profile.ParticleSparksColor
	StormFXConfig.AtmosphereDensity = profile.AtmosphereDensity
	StormFXConfig.AtmosphereHaze = profile.AtmosphereHaze
	StormFXConfig.AtmosphereColor = profile.AtmosphereColor
	StormFXConfig.AtmosphereDecay = profile.AtmosphereDecay
	StormFXConfig.CCTintColor = profile.CCTintColor
	StormFXConfig.CCBrightness = profile.CCBrightness
	StormFXConfig.CCContrast = profile.CCContrast
	StormFXConfig.CCSaturation = profile.CCSaturation
	StormFXConfig.BloomIntensity = profile.BloomIntensity
	StormFXConfig.BloomSize = profile.BloomSize
	StormFXConfig.BloomThreshold = profile.BloomThreshold
end

function StormFXConfig.GetActiveProfileName(): string
	return StormFXConfig.ActiveProfileName
end

function StormFXConfig.IsValidProfile(profileName: string?): boolean
	return type(profileName) == "string" and PROFILES[profileName] ~= nil
end

---------- TRANSITION ----------

StormFXConfig.TweenDuration = 0.15  -- ON tween duration (smooth entry). OFF is instant snap.

---------- DEBUG ----------

StormFXConfig.DebugLogs = false      -- ON/OFF state-change logs (one line per change)
StormFXConfig.DebugTickLogs = false  -- Periodic distance/state dump (~1/s when enabled)

---------- STORM PARTICLE FACTORY (shared, server-side only) ----------

--[[
	Factory: Create storm mist + spark emitters on a parent BasePart.
	Used by MapManager (barrier walls) and HazardManager (beams).
	NOT used by StormFXController (client uses screen-space effects only).
	
	rateMultiplier: Scale emission rates (e.g. 0.5 for beams, 1.0 for walls).
	Returns: mistEmitter, sparksEmitter
]]
function StormFXConfig.CreateStormParticles(parent: BasePart, rateMultiplier: number?): (ParticleEmitter, ParticleEmitter)
	local mult = rateMultiplier or 1
	local stormColor = StormFXConfig.StormColor

	-- Main rising mist particles
	local mist = Instance.new("ParticleEmitter")
	mist.Name = "StormMist"
	mist.Enabled = true
	mist.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, StormFXConfig.ParticleMistStartColor),
		ColorSequenceKeypoint.new(0.5, stormColor),
		ColorSequenceKeypoint.new(1, StormFXConfig.ParticleMistEndColor),
	})
	mist.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 3),
		NumberSequenceKeypoint.new(0.5, 8),
		NumberSequenceKeypoint.new(1, 12),
	})
	mist.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(0.3, 0.3),
		NumberSequenceKeypoint.new(0.7, 0.5),
		NumberSequenceKeypoint.new(1, 1),
	})
	mist.Lifetime = NumberRange.new(2, 4)
	mist.Rate = math.max(1, math.floor(25 * mult))
	mist.Speed = NumberRange.new(8, 20)
	mist.SpreadAngle = Vector2.new(20, 60)
	mist.Rotation = NumberRange.new(0, 360)
	mist.RotSpeed = NumberRange.new(-60, 60)
	mist.Drag = 0.5
	mist.LightEmission = 0.6
	mist.LightInfluence = 0.3
	mist.Acceleration = Vector3.new(0, 5, 0)
	mist.Parent = parent

	-- Sparkle/energy particles for visibility
	local sparks = Instance.new("ParticleEmitter")
	sparks.Name = "StormSparks"
	sparks.Enabled = true
	sparks.Color = ColorSequence.new(StormFXConfig.ParticleSparksColor)
	sparks.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(0.5, 2),
		NumberSequenceKeypoint.new(1, 0),
	})
	sparks.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(0.5, 0.4),
		NumberSequenceKeypoint.new(1, 1),
	})
	sparks.Lifetime = NumberRange.new(1, 2.5)
	sparks.Rate = math.max(1, math.floor(10 * mult))
	sparks.Speed = NumberRange.new(5, 15)
	sparks.SpreadAngle = Vector2.new(40, 40)
	sparks.LightEmission = 1
	sparks.LightInfluence = 0
	sparks.Parent = parent

	return mist, sparks
end

return StormFXConfig
