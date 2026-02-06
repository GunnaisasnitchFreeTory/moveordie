--[[
	ShrinkConfig
	Configuration for arena shrinking difficulty.
	
	The active play area shrinks each round, making beams spawn
	in a smaller area and forcing players together.
	
	Used by: MapManager, HazardManager
]]

local ShrinkConfig = {}

-- Enable/disable shrinking
ShrinkConfig.Enabled = true

-- Shrink timing
ShrinkConfig.StartsAtRound = 2        -- First round to apply shrink (1 = from start)
ShrinkConfig.ShrinkPerRoundStuds = 20 -- Shrink X and Z by this amount each round

-- Minimum bounds (never shrink smaller than this)
ShrinkConfig.MinSizeX = 80            -- Minimum X dimension (studs)
ShrinkConfig.MinSizeZ = 80            -- Minimum Z dimension (studs)

-- Visual indicator (storm wall around active area)
ShrinkConfig.ShowBoundsVisual = true  -- Show storm boundary
ShrinkConfig.BoundsColor = Color3.fromRGB(255, 140, 50)  -- Warm orange sunset tone
ShrinkConfig.BoundsTransparency = 0.7  -- See-through but visible
ShrinkConfig.BoundsHeight = 500        -- Massive storm walls (never see the top)

-- Debug
ShrinkConfig.DebugLog = true

return ShrinkConfig

