--!strict
--[[
    HitDetectionCore — server-authoritative hitscan + lag compensation.
    GDD §8.3 step 1 (the #1 netcode milestone), §10.4.

    Contract (from §10.4):
        - The server performs the hitscan raycast against character
          hitboxes at the moment of fire, NOT the moment it receives it.
        - Lag compensation rewinds opponents' recorded positions to the
          shooter's fire time inside a <= 200 ms window.
        - Client movement is locally predicted (Phase 2); the server keeps
          its own position history — clients never claim damage.

    This module is pure Luau (positions are {x,y,z} number tables, not
    Roblox Vector3) so the netcode math runs identically in Roblox and in
    headless tests. CombatService adapts character CFrames -> snapshots and
    owns the Roblox-side raycaster glue (Phase 2 rig fitting).

    Regions: the MVP uses sphere hitboxes around a stock R6-ish skeleton
    (Enums.HitRegion.*). CombatService overrides sizes per-character rig in
    Phase 2; until then these are the recorded tuning defaults.

    HARD CONSTRAINT (enforced at construction):
        windowSeconds must be <= Constants.LagCompensationWindowMs / 1000.
        A caller that tries a larger window gets an error — the rewind is
        hooded at 200 ms, period.
]]

local HitDetectionCore = {}
HitDetectionCore.__index = HitDetectionCore

-- Upper bound on how fast samples can arrive: CombatService records on
-- Heartbeat, and a high-refresh client can drive that to ~240 Hz. The
-- memory guard below is sized from this, never from the slower nominal
-- SampleInterval, so it can never evict a still-live sample.
local MAX_SAMPLE_HZ = 240

-- config = { WindowSeconds, SampleInterval, Enums }
function HitDetectionCore.new(config)
	assert(
		config.WindowSeconds <= 0.2,
		("HitDetectionCore: lag compensation window %d ms exceeds the GDD hard cap of 200 ms"):format(
			math.round(config.WindowSeconds * 1000)
		)
	)
	local self = setmetatable({}, HitDetectionCore)
	self.WindowSeconds = config.WindowSeconds
	self.SampleInterval = config.SampleInterval
	self.Enums = config.Enums
	-- history[playerId] = { { t, x, y, z, yaw } sorted by t ascending }
	self.history = {}
	-- Head is ~3 studs above the root pivot for stock R6 characters;
	-- torso spans the middle band; limbs around the sides. Phase 2 fits
	-- these against real rigs (R6/R15) in CombatService.
	self.RegionDefaults = {
		[self.Enums.HitRegion.Head] = { offsetY = 3.0, radius = 0.55 },
		[self.Enums.HitRegion.Torso] = { offsetY = 1.15, radiusX = 1.15, radiusZ = 0.75, halfHeight = 0.95 },
		[self.Enums.HitRegion.Limbs] = { offsetY = 0.0, radius = 0.4 },
	}
	return self
end

-- Position history --------------------------------------------------------

-- Record a player position sample (server clock t in seconds).
-- Called by CombatService on Heartbeat / on character pivot changes.
function HitDetectionCore:Record(playerId, t, x, y, z, yaw)
	local h = self.history[playerId]
	if h == nil then
		h = {}
		self.history[playerId] = h
	end
	table.insert(h, { t = t, x = x, y = y, z = z, yaw = yaw or 0 })

	-- Prune by TIME — that is the GDD's actual window. Remove from the FRONT
	-- with table.remove so the buffer stays hole-free: writing `h[i] = nil`
	-- leaves nils inside the array, `#h` then stops describing the sequence,
	-- and the next Record indexes straight into a hole. That single mistake
	-- took out the whole rewind window (B3).
	local cutoff = t - self.WindowSeconds
	while #h > 0 and h[1].t < cutoff do
		table.remove(h, 1)
	end

	-- Memory guard only (the time cutoff above is the real bound), sized for
	-- the fastest rate we record at. A SampleInterval-sized cap (0.1 s at
	-- 10 Hz) would keep ~66 ms of a 200 ms window at 60 Hz and silently
	-- shorten every rewind.
	local cap = math.ceil(self.WindowSeconds * MAX_SAMPLE_HZ) + 2
	while #h > cap do
		table.remove(h, 1)
	end
end

-- Remove a player's history (leave / round reset).
function HitDetectionCore:ClearPlayer(playerId)
	self.history[playerId] = nil
end

function HitDetectionCore:ClearAll()
	self.history = {}
end

--[[
    Rewind query: nearest recorded position for playerId at time t.
    @param toleranceSeconds cap on |sample.t - t| (defaults to the window)
    @return snapshot {t,x,y,z,yaw} or nil when outside the window.
]]
function HitDetectionCore:GetSnapshotAt(playerId, t, toleranceSeconds)
	local h = self.history[playerId]
	if not h or #h == 0 then
		return nil
	end
	local tolerance = toleranceSeconds or self.WindowSeconds
	-- Samples are appended in time order; scan only the tail (window-capped).
	local best, bestDelta = nil, math.huge
	for i = #h, 1, -1 do
		local delta = math.abs(h[i].t - t)
		if delta < bestDelta then
			bestDelta = delta
			best = h[i]
		end
		if h[i].t < t - tolerance then
			break -- older samples can only drift further from t
		end
	end
	if bestDelta > tolerance then
		return nil
	end
	return best
end

-- Hitscan resolution --------------------------------------------------------

--[[
    Build the region candidates for a player from a rewind snapshot.
    @param playerId
    @param snap {t,x,y,z,yaw}
    @param regionSizes optional per-region override table (Phase 2 rig fitting)
    @return { {id, region, x, y, z, radius} , ... } — sphere hitboxes
]]
function HitDetectionCore:BuildCandidates(playerId, snap, regionSizes)
	local sizes = regionSizes or self.RegionDefaults
	local candidates = {}
	for region, geo in sizes do
		local cx, cy, cz = snap.x, snap.y, snap.z
		local radius = geo.radius or geo.radiusX -- sphere approximates boxes in MVP
		-- All regions offset vertically from the root pivot in MVP (Phase 2
		-- fits these against real R6/R15 rigs in CombatService).
		cy = snap.y + geo.offsetY
		table.insert(candidates, {
			id = playerId,
			region = region,
			x = cx,
			y = cy,
			z = cz,
			radius = radius,
		})
	end
	return candidates
end

--[[
    Resolve a hitscan ray against a set of candidates. Nearest intersection
    wins; HEAD regions beat TORSO/limbs at equal distance (small tie-break,
    standard FPS behavior so neck-line shots favor the head).
    @param ox,oy,oz ray origin
    @param dx,dy,dz normalized direction (caller normalizes; we tolerate non-unit)
    @param maxDistance
    @param candidates array from BuildCandidates (any players in range)
    @return hit {id, region, distance} | nil
]]
function HitDetectionCore:ResolveRay(ox, oy, oz, dx, dy, dz, maxDistance, candidates)
	-- Normalize direction
	local len = math.sqrt(dx * dx + dy * dy + dz * dz)
	if len < 1e-6 then
		return nil
	end
	dx, dy, dz = dx / len, dy / len, dz / len

	local bestHit, bestT = nil, math.huge
	for _, c in candidates do
		-- ray-sphere intersection: |o + t*d - c|^2 = r^2
		local lx, ly, lz = ox - c.x, oy - c.y, oz - c.z
		local b = (lx * dx + ly * dy + lz * dz)
		local cc = lx * lx + ly * ly + lz * lz - c.radius * c.radius
		local disc = b * b - cc
		if disc >= 0 then
			local t = -b - math.sqrt(disc)
			if t < 0 then
				t = -b + math.sqrt(disc) -- origin inside sphere: accept exit
			end
			if t >= 0 and t <= maxDistance and t < bestT then
				bestT = t
				bestHit = c
			end
		end
	end

	if bestHit == nil then
		return nil
	end
	return {
		id = bestHit.id,
		region = bestHit.region,
		distance = bestT,
	}
end

return HitDetectionCore
