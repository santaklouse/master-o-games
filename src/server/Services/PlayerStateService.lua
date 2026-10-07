--!strict
--[[
    PlayerStateService (Knit) — server-authoritative player health state
    (GDD §6 shared rules, §7.3 no respawns within a round).

    AUTHORITY RULE (GDD §0.3 / §10.4): the server is the ONLY writer of
    health. This service owns the PlayerHealth registry, exposes NO damage-
    applying remote to clients, and CombatService (server) is the only
    caller of ApplyDamage. Client reads happen through the read-only
    RemoteProperty below (per-player stats), which the server publishes.

    THE MIRROR (A3a, gdd/alpha-weapon-plan.md §3): the registry is the truth
    and the body in the world is told, one-way, through AvatarLink. A player's
    character is linked on join (with the same catch-up loop the P2B join-race
    fix uses, so Studio Play's local player is linked too), and every health
    mutation republishes BOTH the HUD property and the body — so "the HUD says
    40 HP, the character is a corpse" cannot happen. Nothing here ever calls
    Humanoid:TakeDamage: the engine must never become a second writer.

    Practice dummies (A3b) take the identical path: DummyService registers its
    rig with SetAvatar(-id, rig) and gets the same mirror, damage and death.

    Phase 2 plug points:
        - warmup respawn: Revive(playerId) exists for the lobby loop
        - damage VFX/hitmarker math reads PlayerState.PlayerStats property
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Knit = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Knit"))
local Shared = require(ReplicatedStorage:WaitForChild("Shared"))

local PlayerHealth = require(script.Parent.Parent.Logic.PlayerHealth)
local AvatarLink = require(script.Parent.Parent.Logic.AvatarLink)

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

local avatarLink = AvatarLink.new({ MaxHealth = Shared.Constants.MaxHealth })

-- entityId -> rig adapter (a player's character, or a dummy's model in A3b).
local avatars = {}

--[[
    The Roblox adapter: wrap a character as the rig interface AvatarLink
    defines. Returns nil for anything without a Humanoid (a streamed-out or
    still-loading character) — "no body" is a normal state, not an error.

    Death is the plan's stylized blocky fall: PlatformStand + AutoRotate off, a
    limp avatar that stops fighting, out until the round ends. BreakJointsOnDeath
    is set false at spawn so the body never comes apart (no gore, §3).
]]
local function newCharacterRig(character)
    local humanoid = nil
    if type(character.FindFirstChildOfClass) == "function" then
        humanoid = character:FindFirstChildOfClass("Humanoid")
    end
    if humanoid == nil and type(character.FindFirstChild) == "function" then
        humanoid = character:FindFirstChild("Humanoid")
    end
    if humanoid == nil then
        return nil
    end

    local rig = {}
    -- COLON methods: AvatarLink calls them as rig:Method(...), so the adapter
    -- (and A3b's dummy adapter) must take self first. Getting this wrong is
    -- silent — the first argument lands in the parameter and the body ends up
    -- written a table — so the interface is stated once, here.
    function rig:Setup(maxHealth)
        humanoid.MaxHealth = maxHealth
        humanoid.Health = maxHealth
        humanoid.BreakJointsOnDeath = false
    end
    function rig:SetHealth(hp, maxHealth, _armor)
        humanoid.MaxHealth = maxHealth
        humanoid.Health = hp -- a literal SET, never Humanoid:TakeDamage
    end
    function rig:SetAlive(alive)
        humanoid.PlatformStand = not alive
        humanoid.AutoRotate = alive
    end
    -- Exposed for tests: the character this adapter wraps.
    rig.Character = character
    return rig
end

-- Server-private helpers ----------------------------------------------------

function PlayerStateService:_PublishAll()
    self.Client.PlayerStats:Set(self:_BuildStatsTable())
    self:_SyncAvatars()
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

-- Mirror every registered body. Called after EVERY mutation, from one place.
function PlayerStateService:_SyncAvatars()
    for entityId, rig in avatars do
        local p = health:Get(entityId)
        if p ~= nil then
            avatarLink:Sync(rig, p.hp, p.maxHp, p.armor, p.alive)
        end
    end
end

function PlayerStateService:_SetCharacter(player, character)
    local rig = newCharacterRig(character)
    if rig == nil then
        return nil
    end
    self:SetAvatar(player.UserId, rig)
    return rig
end

--[[
    Link a player's body, now and whenever the engine loads a new one. The
    catch-up call for players already in the game is the same Q1-4 join race
    MatchService fixes: in Studio Play the local player exists (and usually has
    a character) before this service's KnitStart runs.
]]
function PlayerStateService:_LinkAvatar(player)
    local characterAdded = player.CharacterAdded
    if characterAdded ~= nil and type(characterAdded.Connect) == "function" then
        characterAdded:Connect(function(character)
            self:_SetCharacter(player, character)
        end)
    end
    if player.Character ~= nil then
        self:_SetCharacter(player, player.Character)
    end
end

-- Server-facing mutation API (server code only — never exposed to clients) --

-- (Re)register a player for a round: full health, armor from buy ledger.
function PlayerStateService:RegisterForRound(playerId, team)
    local economy = Knit.GetService("Economy")
    local armor = economy:GetArmor(playerId)
    local state = health:Register(playerId, team, armor)
    local rig = avatars[playerId]
    if rig ~= nil then
        -- Round start: configure and stand the body back up with the registry.
        avatarLink:AtSpawn(rig, state.maxHp)
    end
    self:_PublishAll()
end

--[[
    The single damage application path on the server. Returns
    { state, lethal, applied } — `applied = false` (with state = nil) when the
    id was never registered for this round: the server refuses to damage a
    player it never seated, instead of inventing a 100 HP ghost (readiness
    notes §7 / the match-2 DEAD defect). sourcePlayerId/weaponId are recorded
    for kill attribution (kill feed Phase 2).
]]
function PlayerStateService:ApplyDamage(playerId, amount, sourcePlayerId, weaponId)
    assert(type(amount) == "number" and amount >= 0, "ApplyDamage requires a non-negative number")
    local state = health:ApplyDamage(playerId, amount, sourcePlayerId, weaponId)
    if state == nil then
        return { state = nil, lethal = false, applied = false, reason = "NOT_REGISTERED" }
    end
    self:_PublishAll()
    return { state = state, lethal = not state.alive, applied = true }
end

-- Armor writes go through the registry, which refuses unregistered ids: a
-- purchase by someone the server never seated must not create state.
function PlayerStateService:SetArmor(playerId, armor)
    local state = health:SetArmor(playerId, armor)
    if state == nil then
        return false
    end
    self:_PublishAll()
    return true
end

-- Warmup / revive (Phase 2; no mid-round respawns in MVP §7.3).
function PlayerStateService:Revive(playerId)
    health:Revive(playerId)
    self:_PublishAll()
end

-- Avatar sink registry (characters now, practice dummies in A3b) ------------

function PlayerStateService:SetAvatar(entityId, rig)
    if rig == nil then
        avatars[entityId] = nil
        return false
    end
    avatars[entityId] = rig
    local p = health:Get(entityId)
    if p ~= nil then
        avatarLink:AtSpawn(rig, p.maxHp)
        avatarLink:Sync(rig, p.hp, p.maxHp, p.armor, p.alive)
    end
    return true
end

function PlayerStateService:ClearAvatar(entityId)
    avatars[entityId] = nil
end

function PlayerStateService:GetCharacter(entityId)
    local rig = avatars[entityId]
    if rig == nil then
        return nil
    end
    return rig.Character
end

-- Read API (safe for client-facing remotes) ---------------------------------

function PlayerStateService:GetHealth(playerId)
    return health:GetHealth(playerId)
end

function PlayerStateService:IsAlive(playerId)
    return health:IsAlive(playerId)
end

-- Is this id seated for the current round? The combat path's gate (never a
-- "GetHealth ~= nil" test — that was true for the old ghost entries).
function PlayerStateService:IsRegistered(playerId)
    return health:IsRegistered(playerId)
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
    avatars[playerId] = nil
    self:_PublishAll()
end

-- §5.3 match end: full health reset (match-scoped registry).
function PlayerStateService:ResetAllForNewMatch()
    -- Clears every roster entry; next match restarts all players at 100 HP
    -- via RegisterForRound.
    health:ResetAll()
    self:_PublishAll()
end

-- Join lifecycle -------------------------------------------------------------

function PlayerStateService:KnitStart()
    Players.PlayerAdded:Connect(function(player)
        self:_LinkAvatar(player)
    end)
    Players.PlayerRemoving:Connect(function(player)
        avatars[player.UserId] = nil
    end)
    -- Catch-up: players already in the game before this KnitStart (Q1-4).
    for _, player in Players:GetPlayers() do
        self:_LinkAvatar(player)
    end
end

return PlayerStateService
