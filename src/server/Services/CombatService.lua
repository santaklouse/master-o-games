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
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Knit = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Knit"))
local Shared = require(ReplicatedStorage:WaitForChild("Shared"))

local HitDetectionCore = require(script.Parent.Parent.Logic.HitDetectionCore)
local DamageModel = require(script.Parent.Parent.Logic.DamageModel)

local CombatService = Knit.CreateService({
	Name = "Combat",
	Client = {
		-- Server -> all: every registered hit (kill feed / hitmarker math).
		HitConfirmed = Knit.CreateSignal(),
		-- Server -> shooter: confirmation that the shot resolved (Phase 2
		-- weapon feel consumes this for tracer/hit-stop).
		ShotResolved = Knit.CreateSignal(),
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
local SERVER_FIRE_TIME_SKEW_SECONDS = 0.1 -- clock skew tolerance; fireTime is still clamped

local lastFireAt = {} -- playerId -> os.clock() (server-side fire-rate gate)

function CombatService:KnitStart()
	-- Server-side movement recorder: keep a rolling history of every
	-- character's position (10 Hz effective pruning; WindowSeconds cap).
	RunService.Heartbeat:Connect(function()
		local now = os.clock()
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
	-- a weapon can actually shoot.
	if weapon.fireRateRPM and weapon.fireRateRPM > 0 then
		local minInterval = 60 / weapon.fireRateRPM
		local now = os.clock()
		local last = lastFireAt[player.UserId]
		if last and (now - last) < minInterval then
			return { ok = false, reason = "RATE_LIMITED" }
		end
		lastFireAt[player.UserId] = now
	end

	-- 4. Sanitize the ray. The server resolves the hit itself; the client
	-- payload only suggests where the camera pointed. fireTime is clamped
	-- to the compensation window (older -> rejected as stale/fraud).
	local now = os.clock()
	local fireTime = payload.fireTime or now
	local maxLatency = Shared.Constants.LagCompensationWindowMs / 1000
	if fireTime < now - maxLatency - SERVER_FIRE_TIME_SKEW_SECONDS then
		return { ok = false, reason = "STALE_FIRE_TIME" }
	end
	if fireTime > now + SERVER_FIRE_TIME_SKEW_SECONDS then
		fireTime = now -- future timestamps are clamped, not trusted
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

	-- 5. Lag-compensated hit resolution (the actual milestone).
	-- NOTE: Knit binds Client methods with Client.Server = the service, so
	-- self.Server is CombatService; _ResolveHit lives on the service.
	local hit = self.Server:_ResolveHit(player.UserId, origin, dir, fireTime)
	if hit == nil then
		return { ok = true, hit = nil, reason = "MISS" }
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

	-- 8. Broadcast (kill feed / hitmarker data for both sides).
	local result = {
		ok = true,
		hit = { id = hit.id, region = hit.region, distance = math.round(hit.distance * 10) / 10 },
		weaponId = weaponId,
		damage = math.round(resolved.damage * 10) / 10,
		lethal = applied.lethal,
		balance = balance,
	}
	CombatService.Client.HitConfirmed:Fire({
		shooterId = player.UserId,
		victimId = hit.id,
		weaponId = weaponId,
		region = hit.region,
		damage = result.damage,
		lethal = applied.lethal,
		fireTime = fireTime,
	})
	CombatService.Client.ShotResolved:Fire(player, result)
	return result
end

-- Server-internal resolution -------------------------------------------------

-- Rewind to fireTime, cast the ray at the recorded opponent positions.
function CombatService:_ResolveHit(shooterId, origin, dir, fireTime)
	local shooterTeam = Knit.GetService("Match"):GetPlayerTeam(shooterId)
	if shooterTeam == nil then
		return nil
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

	return core:ResolveRay(origin.x, origin.y, origin.z, dir.x, dir.y, dir.z, HITSCAN_MAX_RANGE_STUDS, candidates)
end

return CombatService
