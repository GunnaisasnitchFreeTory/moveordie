--[[
	DeveloperProductConfig
	Canonical developer-product definitions used by both prompt flows and receipt handlers.

	NOTE:
	FreezePlayer.productId must match the live Roblox developer product ID.
]]

local DeveloperProductConfig = {}
local MonetizationConfig = require(script.Parent:WaitForChild("MonetizationConfig"))

local function makeEntry(entryId: string, fallbackName: string, fallbackRobux: number)
	local entry = MonetizationConfig.GetDeveloperProduct(entryId) or {}
	return {
		id = entryId,
		name = tostring(entry.name or fallbackName),
		robux = tonumber(entry.robux) or fallbackRobux,
		productId = tonumber(entry.productId) or 0,
	}
end

DeveloperProductConfig.FreezePlayer = makeEntry("freeze_player", "Freeze Player", 15)
DeveloperProductConfig.ForceNextMode = makeEntry("force_next_mode", "FORCE NEXT MODE!", 5)
DeveloperProductConfig.PerkSpeed = makeEntry("perk_speed", "Speed Ability", 5)
DeveloperProductConfig.PerkJump = makeEntry("perk_jump", "Jump Ability", 5)

return DeveloperProductConfig
