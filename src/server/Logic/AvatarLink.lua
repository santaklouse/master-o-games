--!strict
--[[
	AvatarLink — the ONE-WAY mirror from the health registry to a body in the
	world (gdd/alpha-weapon-plan.md §3).

	AUTHORITY RULE: `PlayerHealth.hp` is the truth and the Humanoid is a
	one-way MIRROR. Nothing may ever call `Humanoid:TakeDamage` — that hands
	damage authority to the engine and gives the game two writers of health,
	which is how "the player dies but the server still thinks he is alive"
	(and its reverse) happens. The registry writes; the body is told.

	The body is injected as a RIG ADAPTER — a table of functions — so this
	module stays pure Luau and every rule below is provable headlessly with a
	spy rig, with no DataModel present:

		rig:Setup(maxHealth)                  -- spawn: MaxHealth, BreakJointsOnDeath = false
		rig:SetHealth(hp, maxHealth, armor)   -- the mirror write
		rig:SetAlive(alive)                   -- death pose / stand back up

	`SetAlive(false)` is a stiff, non-gory fall (plan §3: stylized blocky
	violence — PlatformStand + AutoRotate off, `BreakJointsOnDeath = false` so
	the body never comes apart). It is idempotent: a second lethal hit on an
	already-dead body writes the same pose again.
]]

local AvatarLink = {}
AvatarLink.__index = AvatarLink

-- config = { MaxHealth = number }
function AvatarLink.new(config)
	local self = setmetatable({}, AvatarLink)
	self.MaxHealth = config.MaxHealth
	return self
end

-- Spawn / round start: the body is configured once and then mirrors the
-- registry. Returns false when there is no body to configure (a player whose
-- character has not loaded, a spectator), which is never an error.
function AvatarLink:AtSpawn(rig, maxHealth)
	if rig == nil then
		return false
	end
	rig:Setup(maxHealth or self.MaxHealth)
	return true
end

--[[
	Mirror one registry entry onto a body.
	@param rig the injected body adapter (nil = no body, e.g. character unloaded)
	@param hp, maxHealth, armor the authoritative registry values
	@param alive the registry's alive flag
	@return true when a write happened
]]
function AvatarLink:Sync(rig, hp, maxHealth, armor, alive)
	if rig == nil then
		return false
	end
	rig:SetHealth(hp, maxHealth, armor)
	rig:SetAlive(alive and true or false)
	return true
end

return AvatarLink
