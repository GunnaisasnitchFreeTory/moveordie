--[[
	ModeEnvironmentConfig
	Config-driven mapping for mode -> map + lighting environment.

	Normal mode keeps the default Workspace map + default lighting.
	Brainrot mode swaps to a ServerStorage map template and applies
	a lighting preset folder for the duration of the match.
]]

local ModeEnvironmentConfig = {}

ModeEnvironmentConfig.DefaultMode = "Normal"
ModeEnvironmentConfig.DefaultMapName = "SquarePlatformMap"

ModeEnvironmentConfig.Modes = {
	Normal = {
		mapTemplatePath = nil,
		lightingPresetPath = nil,
		mapAnchorPartName = "SquarePlatformMap",
		barrierColorRGB = nil, -- nil = keep default barrier color
		stormVfxProfile = "Normal",
		barrierPresentationProfile = "Normal",
	},
	Brainrot = {
		mapTemplatePath = "ServerStorage.Maps.BrainrotPlatformmap",
		lightingPresetPath = "ServerStorage.Maps.UnwrapInLighting",
		mapAnchorPartName = "BrainrotPlatformMap",
		barrierColorRGB = { 85, 175, 245 }, -- darker blue-cyan
		stormVfxProfile = "Brainrot",
		barrierPresentationProfile = "Brainrot",
	},
}

function ModeEnvironmentConfig.Get(modeName: string?): { [string]: any }
	local mode = if type(modeName) == "string" and modeName ~= "" then modeName else ModeEnvironmentConfig.DefaultMode
	return ModeEnvironmentConfig.Modes[mode] or ModeEnvironmentConfig.Modes[ModeEnvironmentConfig.DefaultMode]
end

return ModeEnvironmentConfig
