-- Shared per-pet visual overrides for spawn/follow presentation only.
-- Does not modify source assets in ReplicatedStorage.

local PetVisualConfig = {}

local DEFAULT_FNAF_SCALE = 2.4

type VisualOverride = {
	scale: number?,
	rotation: CFrame?,
	rotDeg: Vector3?,
	debugTag: boolean?,
}

-- Per-pet rotation correction applied every follow frame via visual.rotation.
-- Yaw offsets (180°) for backwards-facing models.
-- Add pitch/roll corrections here if a model is inherently tilted.
local OVERRIDES: { [string]: VisualOverride } = {
	pet_steve = {
		rotation = CFrame.new(),
		rotDeg   = Vector3.zero,
		debugTag = true,
	},
	pet_the_puppet = {
		rotation = CFrame.Angles(0, math.rad(180), 0),
		rotDeg   = Vector3.new(0, 180, 0),
		debugTag = true,
	},
	pet_chica = {
		scale = 2.9,
	},
}

function PetVisualConfig.Get(petId: string, petDef)
	local override = OVERRIDES[petId]
	local isFNAF = petDef and petDef.collection == "FNAF"

	local scale = 1
	if isFNAF then
		scale = DEFAULT_FNAF_SCALE
	end
	if override and override.scale then
		scale = override.scale
	end

	local rotation = (override and override.rotation) or CFrame.new()
	local rotDeg = (override and override.rotDeg) or Vector3.zero
	local hasOverride = (scale ~= 1) or (rotDeg.Magnitude > 0)

	return {
		scale = scale,
		rotation = rotation,
		rotDeg = rotDeg,
		hasOverride = hasOverride,
		isFNAF = isFNAF,
		debugTag = override and override.debugTag == true,
	}
end

return PetVisualConfig
