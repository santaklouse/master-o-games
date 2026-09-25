--!strict
--[[
    CombatService (Knit) — server-authoritative hitscan + lag compensation.
    GDD §8.3 step 1, §10.4.

    AUTHORITY MODEL (non-negotiable, §0.3):
        - Clients NEVER claim damage. The only client input is a fire
          intent: { weaponId, fireTime, origin, dir }.
        - The SERVER rewinds its own recorded opponent positions to
          fireTime (<= 200 ms window), raycasts at that instant, applies
          damage through PlayerStateService, and only then credits kills
          through EconomyService.
        - No damage-mutating remote exists anywhere; PlayerStateService:ApplyDamage
          is callable only by server code (this service).

    Phase 2 plug points (Gameplay Scripter):
        - Client fires: Knit.GetService("Combat").Client.FireRequest:InvokeAsync(...)
        - Movement recording is automatic (Heartbeat -> core:Record) but
          Phase 2 may switch to CFrame-based pivot events; keep calling
          Record(playerId, t, x, y, z, yaw).
        - Hitscan origin/dir validation against camera FOV (angular culling)
          is deliberately NOT enforced yet (needs the Phase 2 camera rig).

    CLIENT FEEDBACK IS TARGETED, NEVER BROADCAST (§10.4, fix 2026-09-20):
        hit/damage outcomes are private to the two players involved —
        HitConfirmed + ShotResolved go to the SHOOTER only, DamageTaken goes
        to the VICTIM only. Nothing about a shot may be fired to all clients
        (that used to happen and leaked every player's hits to everyone).
        A broadcast "hit" signal is also an information leak: enemy health,
        positions and who is shooting whom must not be pushed to the whole
        server.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Knit = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Knit"))
local Shared = require(ReplicatedStorage:WaitForChild("Shared"))

local HitDetectionCore = require(script.Parent.Parent.Logic.HitDetectionCore)
local DamageModel = require(script.Parent.Parent.Logic.DamageModel)

local CombatService = Knit.CreateService({
    Name = "Combat",
    Client = {
        -- Server -> SHOOTER only: this shot landed (hitmarker + damage dealt).
        HitConfirmed = Knit.CreateSignal(),
        -- Server -> SHOOTER only: the shot resolved (hit or miss) — tracer,
        -- impact FX and hit-stop consume this. Never fired to anyone else.
        ShotResolved = Knit.CreateSignal(),
        -- Server -> VICTIM only: you were hit — your own damage + resulting
        -- health, for the damage flash / HUD. Nobody else learns about it.
        DamageTaken = Knit.CreateSignal(),
    },
})

local core = HitDetectionCore.new({
    WindowSeconds = Shared.Constants.LagCompensationWindowMs / 1000, -- <= 0.2 enforced inside
    SampleInterval = Shared.Constants.LagCompensationSampleInterval,
    Enums = Shared.Enums,
})

local damageModel = DamageModel.new({
    Combat = Shared.Combat,
    Weapons = Shared.Weapons,
    Enums = Shared.Enums,
})

-- Tuning (Phase 2 flags; see GDD §10.4 / §13)
local HITSCAN_MAX_RANGE_STUDS = 300
local MAX_ORIGIN_DISTANCE_FROM_HEAD_STUDS = 8 -- client camera vs head drift tolerance
-- Clock-skew allowance for a client timestamp that is slightly AHEAD of the
-- server's. Inside this band we clamp to `now`; beyond it we reject the shot
-- (FUTURE_FIRE_TIME) rather than resolving a shot that has not happened yet.
local FIRE_TIME_FUTURE_TOLERANCE_SECONDS = 0.1

local lastFireAt = {} -- playerId -> server-clock seconds (server-side fire-rate gate)

--[[
    THE SERVER CLOCK (WORKFLOW.md "Clock domains").
    Every combat timestamp — recorded position samples, the fire-rate gate,
    and the client's fireTime — lives in Workspace:GetServerTimeNow().
    Roblox's `os.clock()` is process CPU time: an unrelated domain whose
    rate is not wall time. Comparing a client fireTime (server clock)
    against os.clock() made every rewind delta meaningless, so
    GetSnapshotAt never landed inside its tolerance and lag compensation
    silently resolved nothing (the "~4 samples / always stale" defect).
    os.clock() is for local client feel only; it is never used here.
]]
local function serverNow()
    return Workspace:GetServerTimeNow()
end

--[[
    World-geometry seam: cover must stop bullets. HitDetectionCore is pure
    Luau and may not touch the DataModel, so this service builds the
    provider and hands it in per shot. The result is exactly what
    HitDetectionCore documents:
        worldQuery(ox,oy,oz,dx,dy,dz,maxDistance) -> { distance, name } | nil

    Characters are excluded from the query on purpose: player hitboxes are
    resolved by HitDetectionCore against the REWOUND snapshots, never by the
    engine. Without the exclusion a shooter's own body would eat every shot
    (the ray starts at their head), and a victim's CURRENT character would
    block shots aimed at their rewound position — lag-compensation false
    cover. So the engine answers one question only: is there world geometry
    in the way, and how far away is it?
]]
local function newWorldQuery()
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ignore = {}
    for _, player in Players:GetPlayers() do
        if player.Character ~= nil then
            table.insert(ignore, player.Character)
        end
    end
    params.FilterDescendantsInstances = ignore

    return function(ox, oy, oz, dx, dy, dz, maxDistance)
        -- The ray's LENGTH is the direction vector's magnitude, so scale the
        -- unit direction by the hitscan range.
        local result = Workspace:Raycast(
            Vector3.new(ox, oy, oz),
            Vector3.new(dx * maxDistance, dy * maxDistance, dz * maxDistance),
            params
        )
        if result == nil then
            return nil
        end
        return {
            distance = result.Distance,
            name = if result.Instance ~= nil then result.Instance.Name else "World",
        }
    end
end

function CombatService:KnitStart()
    -- Server-side movement recorder: keep a rolling history of every
    -- character's position (10 Hz effective pruning; WindowSeconds cap).
    RunService.Heartbeat:Connect(function()
        local now = serverNow()
        for _, player in Players:GetPlayers() do
            local character = player.Character
            if character then
                local pivot = character:GetPivot()
                local pos = pivot.Position
                local _, yaw = pivot:ToEulerAnglesYXZ()
                core:Record(player.UserId, now, pos.X, pos.Y, pos.Z, yaw)
            end
        end
    end)
end

-- Client-facing fire intent (the ONLY combat remote) -------------------------

-- payload = { weaponId, fireTime, origin = {x,y,z}, dir = {x,y,z} }
-- Returns { ok = boolean, reason? , hit = {id, region, distance}? ,
--           damage? , lethal? , balance? }
function CombatService.Client:FireRequest(player, payload)
    -- 1. Server-side context checks
    local phase = Knit.GetService("Match"):GetPhase()
    if phase ~= Shared.Enums.Phase.Action then
        return { ok = false, reason = "NOT_IN_ACTION" }
    end
    if not Knit.GetService("PlayerState"):IsAlive(player.UserId) then
        return { ok = false, reason = "DEAD" }
    end
    if not payload or type(payload) ~= "table" then
        return { ok = false, reason = "BAD_PAYLOAD" }
    end

    -- 2. Weapon ownership: must be this round's rented loadout (ledger).
    local loadout = Knit.GetService("Economy"):GetLoadout(player.UserId)
    local weaponId = payload.weaponId
    if weaponId ~= loadout.primary and weaponId ~= loadout.sidearm and weaponId ~= loadout.melee then
        return { ok = false, reason = "NOT_OWNED" }
    end
    local weapon = Shared.Weapons[weaponId]
    if weapon == nil then
        return { ok = false, reason = "UNKNOWN_WEAPON" }
    end

    -- 3. Server-side fire-rate gate (RPM -> min interval). The client
    -- predicts firing for feel; the server is the authority on how fast
    -- a weapon can actually shoot. Both stamps come from serverNow().
    local now = serverNow()
    if weapon.fireRateRPM and weapon.fireRateRPM > 0 then
        local minInterval = 60 / weapon.fireRateRPM
        local last = lastFireAt[player.UserId]
        if last and (now - last) < minInterval then
            return { ok = false, reason = "RATE_LIMITED" }
        end
        lastFireAt[player.UserId] = now
    end

    -- 4. Sanitize the ray. The server resolves the hit itself; the client
    -- payload only suggests where the camera pointed. fireTime is a
    -- server-clock timestamp (Workspace:GetServerTimeNow() on the client,
    -- the same domain this service records in); anything outside the
    -- rewind window is REJECTED with an explicit reason and logged.
    local fireTime = payload.fireTime or now
    local maxLatency = Shared.Constants.LagCompensationWindowMs / 1000
    local age = now - fireTime
    if age > maxLatency then
        -- Too old: the server has no position history that far back, so
        -- resolving it would be a guess. Reject, don't guess (§10.4).
        warn(
            ("[Combat] %d: fireTime %.3f s is %.0f ms old — outside the %d ms rewind window (STALE_FIRE_TIME)")
                :format(player.UserId, fireTime, age * 1000, Shared.Constants.LagCompensationWindowMs)
        )
        return { ok = false, reason = "STALE_FIRE_TIME", ageMs = math.round(age * 1000) }
    elseif age < -FIRE_TIME_FUTURE_TOLERANCE_SECONDS then
        -- In the future by more than clock skew allows: impossible without
        -- a forged or badly desynced clock.
        warn(
            ("[Combat] %d: fireTime %.3f s is %.0f ms in the future (FUTURE_FIRE_TIME)")
                :format(player.UserId, fireTime, -age * 1000)
        )
        return { ok = false, reason = "FUTURE_FIRE_TIME", ageMs = math.round(age * 1000) }
    elseif age < 0 then
        fireTime = now -- inside the skew allowance: clamp, never trust the future
    end

    local origin, dir = payload.origin, payload.dir
    if type(origin) ~= "table" or type(dir) ~= "table" then
        return { ok = false, reason = "BAD_RAY" }
    end

    -- Origin sanity: the in-world origin must sit near the shooter's own
    -- character (head). Keeps forged origins from becoming "no-clip" rays.
    local character = player.Character
    if character then
        local head = character:FindFirstChild("Head")
        if head then
            local hp = head.Position
            local dx, dy, dz = origin.x - hp.X, origin.y - hp.Y, origin.z - hp.Z
            local distSq = dx * dx + dy * dy + dz * dz
            if distSq > MAX_ORIGIN_DISTANCE_FROM_HEAD_STUDS ^ 2 then
                return { ok = false, reason = "ORIGIN_OUT_OF_RANGE" }
            end
        end
    end

    -- 5. Lag-compensated hit resolution (the actual milestone), with the
    -- world-geometry cover test inside the same ray.
    -- NOTE: Knit binds Client methods with Client.Server = the service, so
    -- self.Server is CombatService; _ResolveHit lives on the service.
    local hit, block = self.Server:_ResolveHit(player.UserId, origin, dir, fireTime)
    if hit == nil then
        -- A shot that stops in cover is a MISS: zero damage, explicit reason.
        local reason = if block ~= nil then "MISS_GEOMETRY" else "MISS"
        if block ~= nil then
            warn(
                ("[Combat] %d: shot stopped by world geometry %q %.1f studs out (%s)")
                    :format(player.UserId, tostring(block.name or "World"), block.distance, reason)
            )
        end
        local missResult = {
            ok = true,
            hit = nil,
            reason = reason,
            blockedBy = block,
            fireTime = fireTime,
        }
        -- The shooter still gets their own shot resolution (tracer/impact FX).
        -- Nobody else is told about it.
        CombatService.Client.ShotResolved:Fire(player, missResult)
        return missResult
    end

    -- 6. Damage application (server-only authority chain).
    local range = hit.distance
    local victimArmor = Knit.GetService("PlayerState"):GetArmor(hit.id)
    local resolved = damageModel:ResolveRangedHit(weaponId, range, hit.region, victimArmor)
    local applied = Knit.GetService("PlayerState"):ApplyDamage(hit.id, resolved.damage, player.UserId, weaponId)

    -- 7. Consequences: kill credit + elimination report.
    local balance = nil
    if applied.lethal then
        balance = Knit.GetService("Economy"):AwardKill(player.UserId).balance -- §5.1: kill +300
        Knit.GetService("Match"):ReportPlayerEliminated(hit.id) -- §7.2.1 check
    end

    -- 8. TARGETED feedback — one signal per player, never a broadcast.
    -- Shooter: hitmarker + damage dealt. Victim: their own damage + health.
    -- (The kill feed is not this signal: it reads Match:PlayerEliminated.)
    local result = {
        ok = true,
        hit = { id = hit.id, region = hit.region, distance = math.round(hit.distance * 10) / 10 },
        weaponId = weaponId,
        damage = math.round(resolved.damage * 10) / 10,
        lethal = applied.lethal,
        balance = balance,
        fireTime = fireTime,
    }
    CombatService.Client.HitConfirmed:Fire(player, {
        victimId = hit.id,
        weaponId = weaponId,
        region = hit.region,
        distance = result.hit.distance,
        damage = result.damage,
        lethal = applied.lethal,
        fireTime = fireTime,
    })
    local victim = Players:GetPlayerByUserId(hit.id)
    if victim ~= nil then
        CombatService.Client.DamageTaken:Fire(victim, {
            attackerId = player.UserId,
            weaponId = weaponId,
            region = hit.region,
            damage = result.damage,
            lethal = applied.lethal,
            hp = applied.state.hp,
            maxHp = applied.state.maxHp,
            armor = applied.state.armor,
            fireTime = fireTime,
        })
    end
    CombatService.Client.ShotResolved:Fire(player, result)
    return result
end

-- Server-internal resolution -------------------------------------------------

-- Rewind to fireTime, cast the ray at the recorded opponent positions.
-- Returns the entity hit (or nil) plus the world-geometry block (or nil) —
-- see HitDetectionCore:ResolveRay. Cover is resolved by the SAME ray, at the
-- SAME instant, so a rewound opponent behind a wall is not hittable.
function CombatService:_ResolveHit(shooterId, origin, dir, fireTime)
    local shooterTeam = Knit.GetService("Match"):GetPlayerTeam(shooterId)
    if shooterTeam == nil then
        return nil, nil
    end

    local candidates = {}
    local playerState = Knit.GetService("PlayerState")
    for _, player in Players:GetPlayers() do
        local victimId = player.UserId
        if victimId ~= shooterId then
            local victimTeam = Knit.GetService("Match"):GetPlayerTeam(victimId)
            if victimTeam ~= nil and victimTeam ~= shooterTeam then
                -- Only living, currently-tracked opponents can be hit.
                if playerState:IsAlive(victimId) then
                    local snap = core:GetSnapshotAt(victimId, fireTime)
                    if snap ~= nil then
                        local built = core:BuildCandidates(victimId, snap)
                        for _, c in built do
                            table.insert(candidates, c)
                        end
                    end
                    -- No snapshot -> outside the 200 ms rewind window:
                    -- no hit, per GDD §10.4 (the skilled server never
                    -- guesses beyond the rewind budget).
                end
            end
        end
    end

    return core:ResolveRay(
        origin.x,
        origin.y,
        origin.z,
        dir.x,
        dir.y,
        dir.z,
        HITSCAN_MAX_RANGE_STUDS,
        candidates,
        newWorldQuery() -- the injected Roblox-side geometry seam
    )
end

return CombatService
