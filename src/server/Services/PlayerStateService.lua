--!strict
--[[
    PlayerStateService (Knit) — server-authoritative player health state
    (GDD §6 shared rules, §7.3 no respawns within a round).

    AUTHORITY RULE (GDD §0.3 / §10.4): the server is the ONLY writer of
    health. This service owns the PlayerHealth registry, exposes NO damage-
    applying remote to clients, and CombatService (server) is the only
    caller of ApplyDamage. Client reads happen through the read-only
    RemoteProperty below (per-player stats), which the server publishes.

    Phase 2 plug points:
        - warmup respawn: Revive(playerId) exists for the lobby loop
        - damage VFX/hitmarker math reads PlayerState.PlayerStats property
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Knit"))
local Shared = require(ReplicatedStorage:WaitForChild("Shared"))

local PlayerHealth = require(script.Parent.Parent.Logic.PlayerHealth)

local PlayerStateService = Knit.CreateService({
	Name = "PlayerState",
	Client = {
		-- Read-only replication for HUD: playerId -> { hp, maxHp, armor, alive, team }
		PlayerStats = Knit.CreateProperty({}),
	},
})

local health = PlayerHealth.new({
	Enums = Shared.Enums,
	MaxHealth = Shared.Constants.MaxHealth,
})

-- Server-private helpers ----------------------------------------------------

function PlayerStateService:_PublishAll()
	self.Client.PlayerStats:Set(self:_BuildStatsTable())
end

function PlayerStateService:_BuildStatsTable()
	local out = {}
	for id, p in health:GetAll() do
		out[id] = {
			hp = p.hp,
			maxHp = p.maxHp,
			armor = p.armor,
			alive = p.alive,
			team = p.team,
		}
	end
	return out
end

-- Server-facing mutation API (server code only — never exposed to clients) --

-- (Re)register a player for a round: full health, armor from buy ledger.
function PlayerStateService:RegisterForRound(playerId, team)
	local economy = Knit.GetService("Economy")
	local armor = economy:GetArmor(playerId)
	health:Register(playerId, team, armor)
	self:_PublishAll()
end

-- The single damage application path on the server. Returns { state, lethal }.
-- sourcePlayerId/weaponId are recorded for kill attribution (kill feed Phase 2).
function PlayerStateService:ApplyDamage(playerId, amount, sourcePlayerId, weaponId)
	assert(type(amount) == "number" and amount >= 0, "ApplyDamage requires a non-negative number")
	local state = health:ApplyDamage(playerId, amount, sourcePlayerId, weaponId)
	self:_PublishAll()
	return { state = state, lethal = not state.alive }
end

function PlayerStateService:SetArmor(playerId, armor)
	health:SetArmor(playerId, armor)
	self:_PublishAll()
end

-- Warmup / revive (Phase 2; no mid-round respawns in MVP §7.3).
function PlayerStateService:Revive(playerId)
	health:Revive(playerId)
	self:_PublishAll()
end

-- Read API (safe for client-facing remotes) ---------------------------------

function PlayerStateService:GetHealth(playerId)
	return health:GetHealth(playerId)
end

function PlayerStateService:IsAlive(playerId)
	return health:IsAlive(playerId)
end

function PlayerStateService:GetArmor(playerId)
	return health:GetArmor(playerId)
end

function PlayerStateService:GetAliveCount(team)
	return health:GetAliveCount(team)
end

function PlayerStateService:TeamAlive(team)
	return health:TeamAlive(team)
end

-- Match cleanup -------------------------------------------------------------

function PlayerStateService:CleanupPlayer(playerId)
	health:Remove(playerId)
	self:_PublishAll()
end

-- §5.3 match end: full health reset (match-scoped registry).
function PlayerStateService:ResetAllForNewMatch()
	-- Clears every roster entry; next match restarts all players at 100 HP
	-- via RegisterForRound.
	health:ResetAll()
	self:_PublishAll()
end

return PlayerStateService
