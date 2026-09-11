--!strict
--[[
    PlayerHealth — server-authoritative player health registry (GDD §6
    shared damage rules: 100 HP; §7.3 no respawns within a round).

    Only CombatService (server) may call the mutation methods on this
    registry; there is NO client-accessible mutator anywhere in the game.
    This module is pure Luau with zero internal requires (see DamageModel
    header for the dependency-injection rule).

    State per player (keyed by player.UserId / playerId string):
        {
            playerId, team, hp, maxHp = 100, armor = Enums.Armor.None,
            alive = true, lastDamagedByPlayerId, lastDamageWeaponId,
            roundKills = 0 (deaths this round)
        }
]]

local PlayerHealth = {}
PlayerHealth.__index = PlayerHealth

-- config = { Enums = Enums, MaxHealth = number }
function PlayerHealth.new(config)
	local self = setmetatable({}, PlayerHealth)
	self.Enums = config.Enums
	self.MaxHealth = config.MaxHealth
	self.players = {} -- playerId -> state
	return self
end

function PlayerHealth:_ensure(playerId, team)
	local p = self.players[playerId]
	if p == nil then
		p = {
			playerId = playerId,
			team = team,
			hp = self.MaxHealth,
			maxHp = self.MaxHealth,
			armor = self.Enums.Armor.None,
			alive = true,
			deathsThisRound = 0,
			lastDamagedByPlayerId = nil,
			lastDamageWeaponId = nil,
		}
		self.players[playerId] = p
	end
	return p
end

-- Server-only mutation entry points ------------------------------------

-- Register a player for a new round / first join (health restored to 100,
-- armor comes from the buy ledger — the SERVICE re-applies it afterwards).
function PlayerHealth:Register(playerId, team, armor)
	local p = self:_ensure(playerId, team)
	p.team = team
	p.hp = self.MaxHealth
	p.alive = true
	p.deathsThisRound = 0
	p.armor = armor or self.Enums.Armor.None
	return p
end

-- Server-only damage application. Returns the resulting state; caller
-- (CombatService) decides follow-ups (kill credit, elimination report).
function PlayerHealth:ApplyDamage(playerId, amount, sourcePlayerId, weaponId)
	local p = self:_ensure(playerId)
	-- Round to 2 decimals to avoid float drift accumulating over a match
	-- (amounts like 25.5 / 22.5 / 20.999...). Health never goes below 0.
	p.hp = math.max(0.0, math.round((p.hp - amount) * 100) / 100)
	p.lastDamagedByPlayerId = sourcePlayerId
	p.lastDamageWeaponId = weaponId
	if p.hp <= 0.0 and p.alive then
		p.alive = false
		p.deathsThisRound += 1
	end
	return p
end

function PlayerHealth:SetArmor(playerId, armor)
	local p = self:_ensure(playerId)
	p.armor = armor
	return p
end

function PlayerHealth:Revive(playerId) -- Phase 2 / warmup use
	local p = self:_ensure(playerId)
	p.hp = self.MaxHealth
	p.alive = true
	p.deathsThisRound = 0
	return p
end

-- Read-only queries (safe to expose anywhere) ---------------------------

function PlayerHealth:Get(playerId)
	return self.players[playerId]
end

function PlayerHealth:GetHealth(playerId)
	local p = self.players[playerId]
	return if p then p.hp else nil
end

function PlayerHealth:IsAlive(playerId)
	local p = self.players[playerId]
	return if p then p.alive else false
end

function PlayerHealth:GetArmor(playerId)
	local p = self.players[playerId]
	return if p then p.armor else self.Enums.Armor.None
end

function PlayerHealth:GetAliveCount(team)
	local count = 0
	for _, p in self.players do
		if p.team == team and p.alive then
			count += 1
		end
	end
	return count
end

function PlayerHealth:TeamAlive(team)
	return self:GetAliveCount(team) > 0
end

function PlayerHealth:GetAll()
	return self.players
end

function PlayerHealth:Remove(playerId)
	self.players[playerId] = nil
end

-- Reset all health state (match end / new match).
function PlayerHealth:ResetAll()
	self.players = {}
end

return PlayerHealth
