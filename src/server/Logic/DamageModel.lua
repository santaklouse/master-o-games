--!strict
--[[
    DamageModel — pure damage math (GDD §6 shared rules + armor + §6.1
    falloff curves). Server-authoritative: CombatService is the ONLY caller
    that applies results to player health.

    DESIGN RULE for headless testing: this module has ZERO internal
    requires; every dependency (Combat/Weapons/Enums config tables) is
    injected via DamageModel.new(config). The Knit services pass the real
    Shared config; tests pass the same tables loaded by path.

    Behavior (exact to GDD):
        base damage      = Weapons.DamageAtRange(weaponId, rangeStuds)
        region multiplier = head x3.5 / body x1.0 / limbs x0.8
        Light Vest       = final damage -25% on ALL regions
        Full Kit         = body/limbs -30%; headshot multiplier capped at x2.0
        Melee (Talon)    = slash 30 / heavy 60; backstab x4 = 120

    All arithmetic is float-exact; health clamps at 0 on application
    (PlayerHealth). No rounding here — tuning stays transparent.
]]

local DamageModel = {}
DamageModel.__index = DamageModel

-- config = { Combat = CombatConfig, Weapons = WeaponsConfig, Enums = Enums }
function DamageModel.new(config)
	local self = setmetatable({}, DamageModel)
	self.Combat = config.Combat
	self.Weapons = config.Weapons
	self.Enums = config.Enums
	return self
end

function DamageModel:RegionMultiplier(region)
	local m = self.Combat
	if region == self.Enums.HitRegion.Head then
		return m.HeadMultiplier
	elseif region == self.Enums.HitRegion.Limbs then
		return m.LimbMultiplier
	end
	return m.BodyMultiplier
end

function DamageModel:GetWeapon(weaponId)
	local w = self.Weapons[weaponId] -- requires self.Weapons to be the Weapons module table
	if w ~= nil and w.id ~= nil then
		return w
	end
	error(("DamageModel: unknown weapon %q"):format(tostring(weaponId)), 2)
end

--[[
    Damage after region + armor for a RANGED hit.
    @return { damage: number, region: string, armor: string, lethal: boolean }
]]
function DamageModel:ResolveRangedHit(weaponId, rangeStuds, region, armor)
	local base = self.Weapons.DamageAtRange(weaponId, rangeStuds)
	local damage = base * self:RegionMultiplier(region)
	local result = self:ApplyArmor(damage, region, armor)
	result.weaponId = weaponId
	result.rangeStuds = rangeStuds
	result.region = region
	result.armor = armor
	return result
end

--[[
    Armor application (GDD §6). region: Enums.HitRegion.* ; armor: Enums.Armor.*
    Returns { damage, lethal }
]]
function DamageModel:ApplyArmor(damage, region, armor)
	armor = armor or self.Enums.Armor.None

	if armor == self.Enums.Armor.LightVest then
		-- -25% all damage (head, body, limbs alike)
		damage = damage * (1.0 - self.Combat.Armor.LightVest.damageReduction)
	elseif armor == self.Enums.Armor.FullKit then
		local config = self.Combat.Armor.FullKit
		if region == self.Enums.HitRegion.Head then
			-- Helmet: headshot multiplier capped at x2.0. Cap applies to the
			-- multiplier, i.e. final = base damage * min(regionMult, 2.0).
			local base = damage / self:RegionMultiplier(region)
			damage = base * math.min(self:RegionMultiplier(region), config.headshotCapMultiplier)
		else
			-- -30% body/limb damage
			damage = damage * (1.0 - config.damageReduction)
		end
	end

	return { damage = damage, lethal = damage >= self.Combat.MaxHealth }
end

--[[
    Melee resolution (GDD §6.1 Talon): slash 30, heavy 60, backstab x4.
    @param meleeKind "slash" | "heavy"
    @return { damage, lethal }
]]
function DamageModel:ResolveMelee(meleeKind, backstab)
	meleeKind = meleeKind or "slash"
	local w = self:GetWeapon("Talon")
	local damage = if meleeKind == "heavy" then w.heavyDamage else w.slashDamage
	if backstab then
		damage = damage * w.backstabMultiplier
	end
	return { damage = damage, lethal = damage >= self.Combat.MaxHealth }
end

return DamageModel
