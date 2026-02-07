--[[
	ShrinkConfig
	Configuration for arena shrinking difficulty.
	
	The active play area shrinks each round, making beams spawn
	in a smaller area and forcing players together.
	
	Shrink accelerates each round (incremental per round):
	  Step i = BaseStepStuds + (i - 1) * StepGrowthStuds
	  Capped at MaxStepStuds, with slowdown near MinBounds.
	
	Example with BaseStep=20, StepGrowth=5, MaxStep=35:
	  Step 1: 20  → total: 20
	  Step 2: 25  → total: 45
	  Step 3: 30  → total: 75
	  Step 4: 35  → total: 110  (hits MaxStep cap)
	  Step 5: 35  → (but slowdown kicks in near MinBounds)
	
	Used by: MapManager, HazardManager, StormFXConfig
]]

local ShrinkConfig = {}

-- Enable/disable shrinking
ShrinkConfig.Enabled = true

-- Shrink timing
ShrinkConfig.StartsAtRound = 2        -- First round to apply shrink (1 = from start)

-- Shrink step tuning (accelerating shrink to prevent prolonged matches)
ShrinkConfig.BaseStepStuds = 20       -- Base shrink amount (studs) for the first shrink round
ShrinkConfig.StepGrowthStuds = 5      -- Additional studs per subsequent shrink round

-- Step clamping + slowdown (prevent sudden "slam" to tiny arena)
ShrinkConfig.MaxStepStuds = 35         -- Per-round step never exceeds this (hard cap)
ShrinkConfig.SlowdownNearMinStuds = 80 -- When within 80 studs of MinBounds, scale step down proportionally

-- Minimum bounds (hard stop — never shrink smaller than this)
ShrinkConfig.MinSizeX = 80            -- Minimum X dimension (studs)
ShrinkConfig.MinSizeZ = 80            -- Minimum Z dimension (studs)

-- OOB grace window (players are NOT killed for this long after a shrink)
ShrinkConfig.OOBGraceSeconds = 0.75   -- Gives players time to move inward after bounds change

-- Visual indicator (storm wall around active area)
ShrinkConfig.ShowBoundsVisual = true  -- Show storm boundary
ShrinkConfig.BoundsColor = Color3.fromRGB(255, 140, 50)  -- Warm orange sunset tone
ShrinkConfig.BoundsTransparency = 0.7  -- See-through but visible
ShrinkConfig.BoundsHeight = 500        -- Massive storm walls (never see the top)

-- Debug (default false — quiet in production)
ShrinkConfig.DebugLog = false

return ShrinkConfig
