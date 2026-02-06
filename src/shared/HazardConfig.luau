--[[
	HazardConfig
	Shared configuration for beam hazards.
	
	Used by: HazardManager
]]

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

-- Beam visual settings (matches storm color for visual consistency)
HazardConfig.BeamWidthStuds = 16          -- Beam thickness (studs) — chunky and visible
HazardConfig.BeamHeightStuds = 400        -- Very tall, visible from lobby
HazardConfig.BeamTransparency = 0.3       -- Semi-transparent
HazardConfig.BeamColor = Color3.fromRGB(255, 140, 50)  -- Orange to match storm wall

-- Kill zone accuracy (limb-accurate detection)
HazardConfig.KillZoneInnerBuffer = 0.02   -- Tiny buffer (2%) to prevent flicker edge deaths
HazardConfig.UseBodyPartCheck = true      -- Check all character body parts (not just HRP)
HazardConfig.GraceThreshold = 0.05        -- Short grace delay (anti one-frame kills)

-- Effects folder
HazardConfig.EffectsFolderName = "ArenaEffects"

-- Debug
HazardConfig.DebugLog = true

return HazardConfig
