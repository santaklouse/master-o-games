--[[
    BEACON PROTOCOL — MERIDIAN DOCKS sightline + cover checks (Lune).

        lune run tests/map_sightlines.lua        (from the repo root)

    Recomputes the art spec's numbers from the map data itself
    (map/meridian_docks.luau — the same table tools/gen_map.luau turns into the
    model the place file ships), so a geometry edit that silently breaks a
    sightline or a cover height fails here instead of in a playtest.

        §1  map integrity: unique names, known materials, spawn points
        §2  cover heights (§1.3): C1 = 4 low cover, C2 = 6 head-blocking, C3 = 9
        §3  the eight longest lines (§1.4), recomputed from the geometry
        §4  doors (§1.2/§1.3 R8) + spawn clearance + place-file fog rule
        §5  FINDINGS: a map-wide ray scan (reported, not asserted — see the
            "LONG RUN" lines; the spec's own eight-line check does not cover
            the back corridors)

    Geometry is axis-aligned boxes in studs; a cylinder's size is given as
    {alongAxis, diameter, diameter} with rotZ 90, i.e. axis along world Y.
    Sightlines are evaluated in the XZ plane at Map.SightlineRayY (3.5 studs —
    torso height; the spec's own Site A blocker is a 4-stud C1 crate, which
    cannot stop a head-height line, and that is exactly the C1 correction).
]]

local fs = require("@lune/fs")

local Map = require("../map/meridian_docks")

local EPS = 0.001
local RAY_Y = Map.SightlineRayY
local LENGTH_TOLERANCE = 2 -- studs; the spec's numbers are rounded whole studs

local passed, failed = 0, {}
local currentSection = "?"

local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then
		passed += 1
		print(("  PASS  %s"):format(name))
	else
		table.insert(failed, { name = currentSection .. " / " .. name, err = tostring(err) })
		print(("  FAIL  %s\n          %s"):format(name, tostring(err)))
	end
end

local function section(name)
	currentSection = name
	print(("\n== %s =="):format(name))
end

local function check(condition, message)
	if not condition then
		error(message or "check failed", 2)
	end
end

local function close(actual, expected, tolerance, message)
	tolerance = tolerance or EPS
	local delta = math.abs(actual - expected)
	if delta > tolerance then
		error(("%s (got %s, expected %s +/- %s)"):format(message or "not close", tostring(actual), tostring(expected), tostring(tolerance)), 2)
	end
end

-- ── geometry ────────────────────────────────────────────────────────────────
local boxes = {}
for _, part in ipairs(Map.Parts) do
	local sx, sy, sz = part.size[1], part.size[2], part.size[3]
	if part.shape == "Cylinder" then
		assert(part.rotZ == 90, part.name .. ": cylinders are only supported with rotZ 90 (axis along Y)")
		-- local X (the axis, size[1]) points at world Y; local Y (size[2]) at world -X
		sx, sy = part.size[2], part.size[1]
	end
	boxes[#boxes + 1] = {
		name = part.name,
		part = part,
		minX = part.pos[1] - sx / 2,
		maxX = part.pos[1] + sx / 2,
		minY = part.pos[2] - sy / 2,
		maxY = part.pos[2] + sy / 2,
		minZ = part.pos[3] - sz / 2,
		maxZ = part.pos[3] + sz / 2,
		heightStuds = sy,
	}
end

local function boxByName(name)
	for _, box in ipairs(boxes) do
		if box.name == name then
			return box
		end
	end
	return nil
end

-- Liang-Barsky: the portion of segment a->b that sits inside the box footprint,
-- as a normalised interval [t0, t1]; nil when the box is not on the line or does
-- not reach the ray height.
local function segmentInterval(ax, az, bx, bz, box)
	if RAY_Y < box.minY - EPS or RAY_Y > box.maxY + EPS then
		return nil
	end
	local dx, dz = bx - ax, bz - az
	local t0, t1 = 0, 1
	local function clip(origin, delta, minimum, maximum)
		if math.abs(delta) < 1e-9 then
			return origin >= minimum - EPS and origin <= maximum + EPS
		end
		local inverse = 1 / delta
		local near = (minimum - origin) * inverse
		local far = (maximum - origin) * inverse
		if near > far then
			near, far = far, near
		end
		if near > t0 then
			t0 = near
		end
		if far < t1 then
			t1 = far
		end
		return t0 <= t1 + EPS
	end
	if not clip(ax, dx, box.minX, box.maxX) then
		return nil
	end
	if not clip(az, dz, box.minZ, box.maxZ) then
		return nil
	end
	if t1 < t0 then
		return nil
	end
	return math.clamp(t0, 0, 1), math.clamp(t1, 0, 1)
end

-- Free runs (in studs) along a line, with the blocking piece named for each end.
local function freeRuns(fromX, fromZ, toX, toZ)
	local length = math.sqrt((toX - fromX) ^ 2 + (toZ - fromZ) ^ 2)
	local intervals = {}
	for _, box in ipairs(boxes) do
		local t0, t1 = segmentInterval(fromX, fromZ, toX, toZ, box)
		if t0 and t1 then
			intervals[#intervals + 1] = { start = t0 * length, stop = t1 * length, name = box.name }
		end
	end
	table.sort(intervals, function(left, right)
		return left.start < right.start
	end)

	local runs, cursor = {}, 0
	for _, interval in ipairs(intervals) do
		if interval.start > cursor + EPS then
			runs[#runs + 1] = { start = cursor, stop = interval.start, length = interval.start - cursor, blocker = interval.name }
		end
		if interval.stop > cursor then
			cursor = interval.stop
		end
	end
	if cursor < length - EPS then
		runs[#runs + 1] = { start = cursor, stop = length, length = length - cursor, blocker = nil }
	end
	return length, runs, intervals
end

local function longestRun(runs)
	local best = { length = 0, blocker = nil }
	for _, run in ipairs(runs) do
		if run.length > best.length then
			best = run
		end
	end
	return best
end

-- Free distance from a point in a direction, up to maxStuds (first entry hit).
local function freeDistance(x, z, directionX, directionZ, maxStuds)
	local nearest = maxStuds
	for _, box in ipairs(boxes) do
		local t0 = segmentInterval(x, z, x + directionX * maxStuds, z + directionZ * maxStuds, box)
		if t0 then
			local distance = t0 * maxStuds
			if distance < nearest then
				nearest = distance
			end
		end
	end
	return nearest
end

-- ── §1 map integrity ────────────────────────────────────────────────────────
section("§1 map data integrity")

test("every part has a unique name", function()
	local seen = {}
	for _, part in ipairs(Map.Parts) do
		check(not seen[part.name], "duplicate part name: " .. part.name)
		seen[part.name] = true
	end
end)

test("every part uses a declared material, colour and positive size", function()
	for _, part in ipairs(Map.Parts) do
		check(Map.Materials[part.material] ~= nil, part.name .. ": unknown material " .. tostring(part.material))
		check(#part.color == 3, part.name .. ": colour must be 3 channels")
		for channel = 1, 3 do
			check(part.color[channel] >= 0 and part.color[channel] <= 255, part.name .. ": colour out of range")
		end
		for axis = 1, 3 do
			check(part.size[axis] > 0, part.name .. ": non-positive size on axis " .. axis)
		end
	end
end)

test("parts stay inside the declared map extent", function()
	local halfWidth = Map.Extent.widthStuds / 2 + 8
	local halfDepth = Map.Extent.depthStuds / 2 + 8
	for _, box in ipairs(boxes) do
		check(box.minX >= -halfWidth and box.maxX <= halfWidth, box.name .. ": X outside the 236-stud extent")
		check(box.minZ >= -halfDepth and box.maxZ <= halfDepth, box.name .. ": Z outside the 220-stud extent")
	end
end)

test("three spawn points: two team rooms plus the practice start", function()
	check(#Map.Spawns == 3, ("expected 3 spawns, found %d"):format(#Map.Spawns))
	local teams, practice = {}, false
	for _, spawn in ipairs(Map.Spawns) do
		teams[spawn.team] = true
		if spawn.team == "Practice" then
			practice = true
		end
	end
	check(teams.Raiders and teams.Wardens, "both team spawns must exist")
	check(practice, "the Alpha needs a practice start for a solo player")
end)

test("the part budget (art spec §4: 200 target / 400 cap) holds", function()
	check(#Map.Parts <= 400, ("%d parts exceeds the 400-part hard cap"):format(#Map.Parts))
	check(#Map.Parts >= 100, ("only %d parts — the blockout is thinner than the art spec"):format(#Map.Parts))
end)

-- ── §2 cover heights (the C1 correction) ────────────────────────────────────
section("§2 cover heights (§1.3 C1 correction)")

test("every cover piece matches its declared class height", function()
	for _, part in ipairs(Map.Parts) do
		if part.cover then
			local expected = Map.CoverClasses[part.cover]
			check(expected ~= nil, part.name .. ": unknown cover class " .. tostring(part.cover))
			close(part.size[2], expected, EPS, part.name .. " (" .. part.cover .. ") height")
		end
	end
end)

test("C1 is low cover only: it must NOT be able to stop a standing head", function()
	local count = 0
	for _, part in ipairs(Map.Parts) do
		if part.cover == "C1" then
			count += 1
			check(part.size[2] == 4, part.name .. ": C1 must be 4 studs")
			check(part.size[2] < 6, part.name .. ": a 6-stud piece is head cover, not low cover")
		end
	end
	check(count >= 3, ("expected the blockout's low cover pieces, found %d"):format(count))
end)

test("anything claiming C2 or above stops a standing head (>= 6 studs)", function()
	local count = 0
	for _, part in ipairs(Map.Parts) do
		local class = part.cover
		if class == "C2" or class == "C3" then
			count += 1
			check(part.size[2] >= 6, part.name .. ": " .. class .. " under 6 studs cannot block a standing head")
		end
	end
	check(count >= 20, ("fewer cover pieces than the art spec's cover table: %d"):format(count))
end)

test("structural walls are 12 studs tall (R10)", function()
	for _, part in ipairs(Map.Parts) do
		if part.bucket == "Structure" and part.name:find("Wall") then
			close(part.size[2], 12, EPS, part.name .. " wall height")
		end
	end
end)

test("boostable tops are marked, 9 studs, and capped at 4 (R6)", function()
	local boosts = 0
	for _, part in ipairs(Map.Parts) do
		if part.boost then
			boosts += 1
			check(part.cover == "C3", part.name .. ": a BOOST top must be the 9-stud class")
			check(part.size[2] >= 6, part.name .. ": a BOOST top must block a standing head")
		end
	end
	check(boosts <= 4, ("%d boostable tops exceeds R6's cap of 4"):format(boosts))
	check(boosts >= 1, "the art spec's Site A boost block is missing")
end)

-- ── §3 the art spec's eight longest lines ───────────────────────────────────
section("§3 art spec §1.4 sightlines, recomputed from the map data")
print(("  ray height: Y %s studs (torso) · tolerance: %s studs"):format(tostring(RAY_Y), tostring(LENGTH_TOLERANCE)))

for _, line in ipairs(Map.Sightlines) do
	test(line.name .. ": recomputes and its declared blocker is on the line", function()
		local fromX, fromZ = line.from[1], line.from[2]
		local toX, toZ = line.to[1], line.to[2]
		local length, runs = freeRuns(fromX, fromZ, toX, toZ)
		close(length, line.lengthStuds, LENGTH_TOLERANCE, line.name .. " line length")

		local run = longestRun(runs)
		close(run.length, line.lengthStuds, LENGTH_TOLERANCE, line.name .. " free run length")
		check(run.length <= Map.SightlineMaxStuds, ("%s: free run %s exceeds the map maximum of %s"):format(line.name, tostring(run.length), tostring(Map.SightlineMaxStuds)))
		check(run.length >= Map.MinEngagementStuds, ("%s: free run %s is under the distance floor"):format(line.name, tostring(run.length)))

		local blocker = boxByName(line.blocker)
		check(blocker ~= nil, line.name .. ": declared blocker " .. line.blocker .. " does not exist in the map")
		local t0 = segmentInterval(fromX, fromZ, toX, toZ, blocker)
		check(t0 ~= nil, line.name .. ": declared blocker " .. line.blocker .. " does not reach this line")

		local headCover = blocker.heightStuds >= Map.CoverClasses.C2
		print(("        %-13s %5.1f studs (spec %d)  blocker %-18s %s studs  %s"):format(
			line.name,
			run.length,
			line.lengthStuds,
			blocker.name,
			tostring(blocker.heightStuds),
			if headCover then "stops a standing head" else "TORSO ONLY - cannot stop a standing head"
		))
	end)
end

test("no declared line exceeds the 60-stud hard cap", function()
	for _, line in ipairs(Map.Sightlines) do
		check(line.lengthStuds <= Map.SightlineHardCapStuds, line.name .. " is declared beyond the hard cap")
	end
end)

-- ── §4 doors, spawns, fog ───────────────────────────────────────────────────
section("§4 doors, spawn clearance, place-file fog rule")

test("every door is at least its band's width (R8)", function()
	local minimums = { standard = Map.DoorWidths.standard, spawn = Map.DoorWidths.standard, choke = Map.DoorWidths.siteANorthChoke, bridge = Map.DoorWidths.tideBridge }
	for _, door in ipairs(Map.Doors) do
		local minimum = minimums[door.band]
		check(minimum ~= nil, door.id .. ": unknown door band " .. tostring(door.band))
		check(door.width >= minimum, ("%s door is %d studs, under the %d-stud minimum"):format(door.id, door.width, minimum))
	end
	check(#Map.Doors == 15, ("the art spec counts 15 doorways, found %d"):format(#Map.Doors))
end)

test("every door is cut out of a real wall (the gap actually exists)", function()
	for _, door in ipairs(Map.Doors) do
		local centreX, centreZ = door.centre[1], door.centre[2]
		for _, box in ipairs(boxes) do
			if box.heightStuds >= 6 and box.name:find("Wall") then
				local inside = centreX > box.minX + EPS and centreX < box.maxX - EPS and centreZ > box.minZ + EPS and centreZ < box.maxZ - EPS
				check(not inside, ("door %s is blocked by %s"):format(door.id, box.name))
			end
		end
	end
end)

test("spawn points are clear of geometry", function()
	for _, spawn in ipairs(Map.Spawns) do
		local half = 6 -- spawn pads are 12 x 12 studs
		for _, box in ipairs(boxes) do
			if box.maxY >= 2 then -- walkable floor paint / pads are exempt
				local overlapsXZ = spawn.pos[1] - half < box.maxX - EPS and spawn.pos[1] + half > box.minX + EPS
					and spawn.pos[3] - half < box.maxZ - EPS and spawn.pos[3] + half > box.minZ + EPS
				check(not overlapsXZ, ("spawn %s overlaps %s"):format(spawn.name, box.name))
			end
		end
	end
end)

test("fog can never hide a target inside the map's maximum sightline", function()
	local ok, raw = pcall(fs.readFile, "default.project.json")
	if not ok then
		print("        (default.project.json not readable from here — skipping the fog cross-check)")
		return
	end
	local serde = require("@lune/serde")
	local project = serde.decode("json", raw)
	local lighting = project.tree.Lighting["$properties"]
	check(lighting.FogStart > Map.SightlineMaxStuds, ("FogStart %s is inside the %s-stud map maximum"):format(tostring(lighting.FogStart), tostring(Map.SightlineMaxStuds)))
	check(lighting.FogEnd > lighting.FogStart, "FogEnd must be beyond FogStart")
	check(lighting.GlobalShadows == true, "GlobalShadows must be on for cover to read (art spec §2)")
end)

-- ── §5 map-wide scan (findings, not assertions) ─────────────────────────────
section("§5 map-wide sightline scan (findings)")
do
	local step = 10
	local directions = 32
	local worst = {}
	local overCap = 0
	-- The scan covers the yard between the two spawn front walls (the lanes, both
	-- sites, the causeway, the staging area and the depot) — the space a round is
	-- actually fought in. Spawn interiors sit behind the front walls.
	for x = -110, 110, step do
		for z = -70, 70, step do
			for index = 0, directions - 1 do
				local angle = index * (2 * math.pi / directions)
				local distance = freeDistance(x, z, math.cos(angle), math.sin(angle), 160)
				worst[#worst + 1] = { x = x, z = z, angle = angle, distance = distance }
				if distance > Map.SightlineHardCapStuds then
					overCap += 1
				end
			end
		end
	end
	table.sort(worst, function(left, right)
		return left.distance > right.distance
	end)
	print(("  scanned %d rays over a 10-stud grid: longest free run %s studs"):format(#worst, tostring(math.floor(worst[1].distance))))
	for index = 1, 8 do
		local hit = worst[index]
		if hit and hit.distance > Map.SightlineHardCapStuds then
			local heading = math.deg(hit.angle)
			print(("  LONG RUN %5.1f studs from (%d, %d) heading %d deg"):format(hit.distance, hit.x, hit.z, math.floor(heading + 0.5)))
		end
	end
	print(("  runs beyond the %s-stud cap: %d of %d rays (%.2f%%)"):format(tostring(Map.SightlineHardCapStuds), overCap, #worst, 100 * overCap / #worst))
	print("  NB: the art spec's §1.4 eight-line check does not cover the back corridors.")
	print("      These findings are reported for the lead, not asserted — closing them")
	print("      means adding cover the art spec does not list.")
end

-- ── summary ────────────────────────────────────────────────────────────────
print(("\n%d passed, %d failed"):format(passed, #failed))
if #failed > 0 then
	for _, failure in ipairs(failed) do
		print(("  FAILED  %s\n            %s"):format(failure.name, failure.err))
	end
	error("meridian docks map checks failed", 0)
end
print(("map: %d parts, %d spawns, %d doors"):format(#Map.Parts, #Map.Spawns, #Map.Doors))
