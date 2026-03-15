local PerkCatalog = {}

PerkCatalog.Speed = {
	id = "perk_speed",
	name = "Speed Ability",
	productConfigKey = "PerkSpeed",
	robux = 5,
	description = "Run faster for one match. Grants +5 speed normally and +2 while carrying a sword.",
	statusAttribute = "PerkSpeedStatus",
	walkSpeedBonus = 5,
	swordWalkSpeedBonus = 2,
}

PerkCatalog.Jump = {
	id = "perk_jump",
	name = "Jump Ability",
	productConfigKey = "PerkJump",
	robux = 5,
	description = "Get a jump boost for one match.",
	statusAttribute = "PerkJumpStatus",
	jumpPowerBonus = 10,
}

PerkCatalog.All = {
	PerkCatalog.Speed,
	PerkCatalog.Jump,
}

function PerkCatalog.Get(perkId: string)
	for _, perk in ipairs(PerkCatalog.All) do
		if perk.id == perkId then
			return perk
		end
	end
	return nil
end

return PerkCatalog
