--[[
	DayNightCycle
	Smoothly cycles Lighting.ClockTime through a full day in CYCLE_SECONDS.
	Also adjusts Ambient / OutdoorAmbient / Brightness so nighttime
	actually looks dark and sunrise/sunset feel warm.

	Runs on server — ClockTime replicates to all clients automatically.
]]

local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")

-- ═══════════════════════════════════════════════════════════════════
-- CONFIG
-- ═══════════════════════════════════════════════════════════════════

local CYCLE_SECONDS = 180         -- one full day/night rotation (3 minutes)
local START_HOUR    = 9           -- start at mid-morning
local SPEED         = 24 / CYCLE_SECONDS  -- ClockTime hours per real second

-- Day (noon) lighting values — very bright and vibrant
local DAY_AMBIENT         = Color3.fromRGB(212, 194, 172)   -- slightly warmer / richer daylight
local DAY_OUTDOOR_AMBIENT = Color3.fromRGB(242, 220, 194)   -- stronger outdoor color lift
local DAY_BRIGHTNESS      = 4.3

-- Night (midnight) lighting values — bright and colorful, never gloomy
local NIGHT_AMBIENT         = Color3.fromRGB(162, 168, 222) -- richer night tint
local NIGHT_OUTDOOR_AMBIENT = Color3.fromRGB(178, 184, 230)
local NIGHT_BRIGHTNESS      = 3.4

-- Sunrise/sunset accent colors (blended in at golden hours)
local GOLDEN_AMBIENT         = Color3.fromRGB(232, 170, 96) -- slightly more vivid golden hour
local GOLDEN_OUTDOOR_AMBIENT = Color3.fromRGB(255, 198, 116)
local GOLDEN_BRIGHTNESS      = 3.7

-- Global post color pass (one notch stronger vibrance).
local GLOBAL_VIBRANCE_SATURATION = 0.14
local GLOBAL_VIBRANCE_CONTRAST   = 0.08
local GLOBAL_VIBRANCE_BRIGHTNESS = 0.02

-- ═══════════════════════════════════════════════════════════════════
-- HELPERS
-- ═══════════════════════════════════════════════════════════════════

--[[
	Returns 0–1 representing how "night" the given hour is.
	0 = noon, 1 = midnight.  Smooth cosine curve.
]]
local function getNightFactor(hour: number): number
	-- Cosine curve centered at noon (12) with period 24
	-- cos(0) = 1 at midnight (hour 0/24), cos(pi) = -1 at noon (hour 12)
	-- We remap: nightFactor = (cos + 1) / 2   → 1 at midnight, 0 at noon
	return (math.cos(math.rad((hour - 12) * (360 / 24))) + 1) / 2
end

--[[
	Returns 0–1 representing how "golden hour" the given hour is.
	Peaks at ~6:30 (sunrise) and ~17:30 (sunset), 0 elsewhere.
]]
local function getGoldenFactor(hour: number): number
	-- Two Gaussian bumps at 6.5 and 17.5
	local sunrise = math.exp(-((hour - 6.5) ^ 2) / 2)
	local sunset  = math.exp(-((hour - 17.5) ^ 2) / 2)
	return math.clamp(math.max(sunrise, sunset), 0, 1)
end

--[[
	Lerp two Color3 values.
]]
local function lerpColor(a: Color3, b: Color3, t: number): Color3
	return Color3.new(
		a.R + (b.R - a.R) * t,
		a.G + (b.G - a.G) * t,
		a.B + (b.B - a.B) * t
	)
end

-- ═══════════════════════════════════════════════════════════════════
-- MAIN LOOP
-- ═══════════════════════════════════════════════════════════════════

Lighting.ClockTime = START_HOUR
print(string.format("[DayNight] Cycle started — %ds per full day, starting at hour %d", CYCLE_SECONDS, START_HOUR))

-- Ensure a single persistent color correction profile for world vibrance.
do
	local cc = Lighting:FindFirstChild("GlobalVibranceCC")
	if not cc or not cc:IsA("ColorCorrectionEffect") then
		if cc then
			cc:Destroy()
		end
		cc = Instance.new("ColorCorrectionEffect")
		cc.Name = "GlobalVibranceCC"
		cc.Parent = Lighting
	end
	cc.Enabled = true
	cc.Saturation = GLOBAL_VIBRANCE_SATURATION
	cc.Contrast = GLOBAL_VIBRANCE_CONTRAST
	cc.Brightness = GLOBAL_VIBRANCE_BRIGHTNESS
end

RunService.Heartbeat:Connect(function(dt: number)
	-- While an exclusive mode preset is active (e.g. Save the Brainrot),
	-- do not mutate Lighting so the preset remains authoritative.
	if Lighting:GetAttribute("ModeLightingExclusive") == true then
		return
	end

	-- Advance clock
	local newTime = (Lighting.ClockTime + SPEED * dt) % 24
	Lighting.ClockTime = newTime

	-- Compute blending factors
	local night  = getNightFactor(newTime)
	local golden = getGoldenFactor(newTime)

	-- Base day→night lerp
	local ambient = lerpColor(DAY_AMBIENT, NIGHT_AMBIENT, night)
	local outdoor = lerpColor(DAY_OUTDOOR_AMBIENT, NIGHT_OUTDOOR_AMBIENT, night)
	local bright  = DAY_BRIGHTNESS + (NIGHT_BRIGHTNESS - DAY_BRIGHTNESS) * night

	-- Layer golden-hour tint on top (additive blend)
	if golden > 0.05 then
		ambient = lerpColor(ambient, GOLDEN_AMBIENT, golden * 0.6)
		outdoor = lerpColor(outdoor, GOLDEN_OUTDOOR_AMBIENT, golden * 0.5)
		bright  = bright + (GOLDEN_BRIGHTNESS - bright) * golden * 0.3
	end

	-- Apply
	Lighting.Ambient = ambient
	Lighting.OutdoorAmbient = outdoor
	Lighting.Brightness = bright
end)

