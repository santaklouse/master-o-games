--!strict
--[[
	BEACON PROTOCOL — weapon catalogue (GDD §6.1, exact MVP numbers).
	Data-driven: mechanics (firing, recoil, spread) are Phase 2, but these
	stat blocks are authoritative NOW. Damage model, economy, and the buy
	menu all read from here — if a number changes, change it here only.

	Damage convention:
		damage = bodyBase at range <= falloffStartM
		damage = bodyMin at range >= falloffEndM
		linear between (GDD §6.1 "Full <= X m; min at Y m")
		Longshot Mk.II is FLAT 62 up to 90 m (no falloff in MVP).

	Manufacturers (flavor, §6): VEXEL Ordnance, HALCYON Arms,
	LONGSIGHT Precision, KESSLER Knives.
]]

-- falloff stages are associative: key = damage at range, threshold = range
local function LinearDamage(base, falloffStart, falloffEnd, dmgMin, range)
	if range <= falloffStart then
		return base
	end
	if range >= falloffEnd then
		return dmgMin
	end
	local t = (range - falloffStart) / (falloffEnd - falloffStart)
	return base - (base - dmgMin) * t
end

local Weapons = {
	Viper9 = {
		id = "Viper9",
		name = "Viper-9",
		class = "Sidearm",
		manufacturer = "VEXEL Ordnance",
		price = 0, -- Free — issued to every player each round (§5.2)
		free = true,
		slot = "Sidearm",
		damageBase = 34, -- body damage at full range
		damageMin = 26, -- body damage at min range
		falloffStartM = 18, -- "Full <= 18 m"
		falloffEndM = 46, -- "min at 46 m"
		fireRateRPM = 240, -- semi-auto, 240 RPM cap
		semiAuto = true,
		magazine = 12,
		reserve = 60,
		-- Design notes (§6.1): eco workhorse. One-tap headshot vs no helmet:
		-- 34 * 3.5 = 119. Deliberate "eco miracle" — flagged for playtest (§13).
	},

	CQB2 = {
		id = "CQB2",
		name = 'CQB-2 "Hound"',
		class = "SMG",
		manufacturer = "VEXEL Ordnance",
		price = 1200, -- credits
		free = false,
		slot = "Primary",
		damageBase = 24,
		damageMin = 16,
		falloffStartM = 12, -- "Full <= 12 m"
		falloffEndM = 30, -- "min at 30 m"
		fireRateRPM = 600, -- auto
		semiAuto = false,
		magazine = 25,
		reserve = 75,
		-- Design notes: run-and-gun entry weapon; strongest close range;
		-- weak past 30 m.
	},

	ARC5 = {
		id = "ARC5",
		name = "ARC-5",
		class = "AssaultRifle",
		manufacturer = "HALCYON Arms",
		price = 2700, -- credits
		free = false,
		slot = "Primary",
		damageBase = 30,
		damageMin = 22,
		falloffStartM = 25, -- "Full <= 25 m"
		falloffEndM = 60, -- "min at 60 m"
		fireRateRPM = 620, -- auto
		semiAuto = false,
		magazine = 30,
		reserve = 90,
		-- NOTE (GDD discrepancy, flagged for the designer): §6.1 says
		-- "4 body shots (3 vs helmet-less... 4 vs armor)" but 30 dmg vs
		-- 100 HP gives 4 body shots unarmored (3 = 90, non-lethal). The
		-- damage math below follows the STAT VALUES; the shot-count comment
		-- is a tuning flag for playtest (§13) — see README.
	},

	Longshot = {
		id = "Longshot",
		name = "Longshot Mk.II",
		class = "DMR",
		manufacturer = "LONGSIGHT Precision",
		price = 2900, -- credits
		free = false,
		slot = "Primary",
		damageBase = 62, -- flat in MVP
		damageMin = 62, -- no falloff <= 90 m; flat everywhere in MVP
		falloffStartM = math.huge, -- "No falloff <= 90 m" — none implemented
		falloffEndM = math.huge,
		effectiveRangeM = 90,
		fireRateRPM = 150, -- semi-auto
		semiAuto = true,
		magazine = 10,
		reserve = 40,
		-- Design notes: 1-tap headshot vs no helmet; 2 body shots;
		-- punishes standing peeks. Helmet cap x2.0 (§13 tension with the
		-- DMR one-tap fantasy — first playtest decision).
	},

	Talon = {
		id = "Talon",
		name = "Talon",
		class = "Melee",
		manufacturer = "KESSLER Knives",
		price = 0, -- Free — issued to every player each round (§5.2)
		free = true,
		slot = "Melee",
		slashDamage = 30,
		heavyDamage = 60, -- heavy windup 0.6 s (Phase 2)
		slashCooldown = 0.25, -- seconds
		backstabMultiplier = 4, -- x4 backstab = 120 -> one-hit kill from behind
		reachStuds = 1.5,
		ammo = math.huge,
		moveSpeedMultiplier = 1.05, -- +5% move speed while drawn
	},

	-- Ordered list for buy menus / issue order. Sidearm + melee are free
	-- and issued every round (rental model §5.3).
	Order = { "Viper9", "CQB2", "ARC5", "Longshot", "Talon" },
	FreeWeapons = { "Viper9", "Talon" },
	PurchasableWeapons = { "CQB2", "ARC5", "Longshot" },
}

function Weapons.GetWeapon(id)
	return Weapons[id]
end

-- Damage at range for hit-scan resolution (GDD §6.1 falloff curves).
function Weapons.DamageAtRange(id, rangeStuds)
	local w = Weapons[id]
	assert(w ~= nil, ("Unknown weapon %q"):format(tostring(id)))
	if w.class == "Melee" then
		return w.slashDamage -- melee handled by DamageModel directly
	end
	return LinearDamage(w.damageBase, w.falloffStartM, w.falloffEndM, w.damageMin, rangeStuds)
end

return Weapons
