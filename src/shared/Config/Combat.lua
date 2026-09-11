--!strict
--[[
	BEACON PROTOCOL — combat config (GDD §6 shared damage rules).
	Health, hit multipliers, armor rules. Shared with clients so
	hitmarkers/HUD math stays consistent (read-only; only the server
	APP LIES damage — see server Logic/DamageModel.lua).

	§6 shared damage rules (exact):
		health = 100 HP
		hit multipliers: head x3.5, body x1.0, limbs x0.8
		armor: Light Vest -25% ALL damage
		       Full Kit -30% body/limb damage, headshot multiplier capped at x2.0
]]

local Combat = {
	MaxHealth = 100,

	HeadMultiplier = 3.5,
	BodyMultiplier = 1.0,
	LimbMultiplier = 0.8,

	Armor = {
		-- §5.2 prices are in Economy.Prices; combat effects here.
		LightVest = {
			id = "LightVest",
			price = 650,
			-- -25% all damage (head, body, limbs alike)
			damageReduction = 0.25,
			appliesToAllRegions = true,
		},
		FullKit = {
			id = "FullKit",
			price = 1000,
			-- -30% body/limb damage
			damageReduction = 0.30,
			appliesToAllRegions = false, -- limbs/body only
			-- headshot multiplier capped at x2.0 (helmet)
			headshotCapMultiplier = 2.0,
		},
	},
}

return Combat
