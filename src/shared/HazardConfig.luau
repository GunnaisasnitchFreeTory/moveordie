--[[
	HazardConfig
	Shared configuration for beam hazards.
	
	BeamColor synced to storm color via ShrinkConfig.BoundsColor (single source of truth).
	
	Used by: HazardManager
]]

local ShrinkConfig = require(script.Parent:WaitForChild("ShrinkConfig"))

local HazardConfig = {}

-- Grid settings (platform divided into GridSize x GridSize cells)
HazardConfig.GridSize = 8  -- 8x8 = 64 cells total

-- Difficulty ramp (unsafe zone count scales with round)
HazardConfig.MinUnsafePercent = 0.12      -- Round 1: ~12% unsafe (~8 cells)
HazardConfig.MaxUnsafePercent = 0.40      -- Cap at 40% unsafe
HazardConfig.UnsafePercentPerRound = 0.06 -- +6% per round

-- Spacing (reduce clustering)
HazardConfig.UseSpacing = true            -- Enable anti-cluster algorithm
HazardConfig.SpacingRadius = 1            -- Avoid cells within 1 cell distance (8-way)
HazardConfig.MaxSelectionAttempts = 500   -- Relax spacing if can't fill

-- Beam visual settings (synced to storm color — single source of truth)
-- BeamWidthStuds is THE single source of truth for hazard footprint:
--   • Beam Part uses it for Size.X and Size.Z
--   • Telegraph tile uses it for its floor overlay size
--   • Kill-zone check uses beam.Size (which comes from this value)
-- If you change this, the beam, telegraph, AND kill zone all stay in sync.
HazardConfig.BeamWidthStuds = 16          -- Beam footprint (studs) — both X and Z
HazardConfig.BeamHeightStuds = 2000       -- Sky-high: beams appear to come from the clouds
HazardConfig.BeamTransparency = 0.3       -- Semi-transparent
HazardConfig.BeamColor = ShrinkConfig.BoundsColor  -- Storm color (single source of truth)

-- Beam storm particles (match barrier style)
HazardConfig.BeamParticlesEnabled = true
HazardConfig.BeamParticleRateMultiplier = 0.5   -- Visible on beams (tune down after confirmed)

-- Kill zone accuracy (limb-accurate detection)
HazardConfig.KillZoneInnerBuffer = 0.02   -- Tiny buffer (2%) to prevent flicker edge deaths
HazardConfig.UseBodyPartCheck = true      -- Check all character body parts (not just HRP)
HazardConfig.GraceThreshold = 0.05        -- Short grace delay (anti one-frame kills)

-- Effects folder
HazardConfig.EffectsFolderName = "ArenaEffects"

-- Tile Warning (fast danger flash on unsafe floor cells during telegraph)
HazardConfig.TileWarningEnabled = true
HazardConfig.TileWarningColor = Color3.fromRGB(200, 50, 20)      -- Dark danger red
HazardConfig.TileWarningMaterial = Enum.Material.Neon             -- Glow effect
HazardConfig.TileWarningThickness = 0.15                          -- Thin overlay (studs)
HazardConfig.TileWarningTranspStart = 0.92                        -- Initial: nearly invisible
HazardConfig.TileWarningTranspPeak = 0.35                         -- Pulse peak: clearly visible
HazardConfig.TileWarningTranspRest = 0.75                         -- Between pulses: subtle tint
HazardConfig.TileWarningPulseCount = 3                            -- Number of fast pulses
HazardConfig.TileWarningPulseFadeIn = 0.08                        -- Seconds: snap to dark (fast)
HazardConfig.TileWarningPulseFadeOut = 0.12                       -- Seconds: ease back
HazardConfig.TileWarningPulseGap = 0.3                            -- Seconds between pulses

-- Debug
HazardConfig.DebugLog = true
HazardConfig.BeamParticleDebugLogs = false  -- Per-beam emitter detail (very spammy)
HazardConfig.TileWarningDebugLogs = false   -- Tile warning spawn/clear logs

return HazardConfig
