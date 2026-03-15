--[[
	DeveloperProductConfig
	Canonical developer-product definitions used by both prompt flows and receipt handlers.

	NOTE:
	FreezePlayer.productId must match the live Roblox developer product ID.
]]

local DeveloperProductConfig = {}

DeveloperProductConfig.FreezePlayer = {
	id = "freeze_player",
	name = "Freeze Player",
	robux = 15,
	productId = 3552077669,
}

DeveloperProductConfig.ForceNextMode = {
	id = "force_next_mode",
	name = "FORCE NEXT MODE!",
	robux = 5,
	productId = 3554497295,
}

DeveloperProductConfig.PerkSpeed = {
	id = "perk_speed",
	name = "Speed Ability",
	robux = 5,
	productId = 3556716610,
}

DeveloperProductConfig.PerkJump = {
	id = "perk_jump",
	name = "Jump Ability",
	robux = 5,
	productId = 3556733510,
}

return DeveloperProductConfig
