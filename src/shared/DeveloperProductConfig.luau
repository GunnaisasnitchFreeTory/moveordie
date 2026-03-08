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

return DeveloperProductConfig
