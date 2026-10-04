--!nocheck
--[[
    BEACON PROTOCOL — MERIDIAN DOCKS map data (SINGLE SOURCE OF TRUTH).

    Nothing in here uses Roblox APIs, so it loads under plain Lune:
      * `tools/gen_map.luau`  turns it into the committed Rojo model `map/MeridianDocks.rbxmx`
      * `tests/map_sightlines.lua` recomputes the art spec's sightlines and cover
        heights straight out of this table — geometry and proof read one table.

    Built to /home/team/shared/gdd/alpha-art-spec.md §1 (Tables 1A/1B/1C, cover
    classes §1.3, sightlines §1.4). Units: STUDS, always. Ground top = Y 0.

    Part record:
        { bucket, name, size = {x,y,z}, pos = {x,y,z}, material, color = {r,g,b} (0-255),
          shape = "Block"|"Cylinder" (default Block), rotZ = degrees (cylinder only),
          cover = "C1"|"C2"|"C3" (cover class, art spec §1.3), boost = true (BOOST top),
          castShadow = true (default: false — art spec §4 budget is <= 20 casters) }

    CYLINDERS: Roblox cylinders run along their LOCAL X axis, so a "vertical
    cylinder of height h and diameter d" is size = {h, d, d} with rotZ = 90 (and a
    flat floor disc of diameter d is size = {thickness, d, d}). Always give the
    axis length first — the generator applies the rotation.
]]

local Map = {}

Map.Name = "MeridianDocks"
Map.DisplayName = "Meridian Docks"

-- Art spec §1.1: flat tidal-dock yard 236 x 220 studs, every surface at Y 0.
Map.Extent = { widthStuds = 236, depthStuds = 220, groundTopY = 0 }

-- Art spec §1.3 (C1 correction 2026-09-19): cover classes ARE hitbox heights.
-- C1 = 4 does NOT block a standing head (torso cover only); anything that claims
-- to block a standing head must be >= COVER.C2 (6 studs).
Map.CoverClasses = { C1 = 4, C2 = 6, C3 = 9 }

-- R1: no uninterrupted sightline anywhere; 57 studs is the map maximum, 60 the cap.
Map.SightlineMaxStuds = 57
Map.SightlineHardCapStuds = 60
-- R5 + R8: distance floor and door widths (art spec §1.2/§1.3).
Map.MinEngagementStuds = 6
Map.CoverFootprintStuds = 4
Map.DoorWidths = { standard = 12, tideBridge = 16, siteANorthChoke = 12 }

Map.Materials = {
    Asphalt = 1376,
    Concrete = 816,
    Metal = 1088,
    CorrodedMetal = 1040,
    Slate = 800,
    Neon = 288,
    SmoothPlastic = 272,
}

Map.Buckets = { "Structure", "Cover", "Markers" }

-- Doors (art spec §1.1 layout + §1.4 widths). axis = the wall's long direction.
-- Declared here because the door lintels are generated from this list.
Map.Doors = {
    { id = "MusterDeckW", axis = "x", width = 20, centre = { -90, -78 }, band = "spawn" },
    { id = "MusterDeckMid", axis = "x", width = 28, centre = { 0, -78 }, band = "spawn" },
    { id = "MusterDeckE", axis = "x", width = 20, centre = { 90, -78 }, band = "spawn" },
    { id = "YardHouseW", axis = "x", width = 20, centre = { -90, 78 }, band = "spawn" },
    { id = "YardHouseMid", axis = "x", width = 28, centre = { 0, 78 }, band = "spawn" },
    { id = "YardHouseE", axis = "x", width = 20, centre = { 90, 78 }, band = "spawn" },
    { id = "SiteANorth", axis = "x", width = 12, centre = { -42, -26 }, band = "choke" },
    { id = "SiteAWest", axis = "z", width = 12, centre = { -60, 12 }, band = "standard" },
    { id = "SiteAEast", axis = "z", width = 12, centre = { -24, 2 }, band = "standard" },
    { id = "SiteBNorth", axis = "x", width = 12, centre = { 42, -26 }, band = "standard" },
    { id = "SiteBWest", axis = "z", width = 12, centre = { 24, 2 }, band = "standard" },
    { id = "SiteBEast", axis = "z", width = 12, centre = { 60, 12 }, band = "standard" },
    { id = "SouthDepotNorth", axis = "x", width = 12, centre = { 0, 40 }, band = "standard" },
    { id = "TideBridgeW", axis = "z", width = 16, centre = { -65, -37 }, band = "bridge" },
    { id = "TideBridgeE", axis = "z", width = 16, centre = { 65, -37 }, band = "bridge" },
}

Map.Parts = {}

local function add(part)
    Map.Parts[#Map.Parts + 1] = part
end

local CONCRETE = { 110, 110, 114 }
local CONCRETE_DARK = { 99, 95, 98 }
local CONCRETE_ROOF = { 86, 86, 90 }
local METAL = { 124, 131, 138 }
local SLATE = { 86, 88, 92 }
local RUST = { 128, 82, 51 }
local NEON_MINT = { 0, 255, 170 }
local NEON_SUN = { 255, 213, 0 }
local TEAM_RAIDER = { 200, 110, 40 }
local TEAM_WARDEN = { 40, 120, 190 }

-- ════════════════════════════════════════════════════════════════════════════
-- TABLE 1A — structure (art spec §1.5)
-- ════════════════════════════════════════════════════════════════════════════

-- 1. Ground slab
add({
    bucket = "Structure",
    name = "MD_GroundSlab",
    size = { 236, 4, 220 },
    pos = { 0, -2, 0 },
    material = "Asphalt",
    color = { 74, 76, 78 },
})

-- 2-5. Perimeter (the boundary that makes the yard a box)
local perimeter = {
    { "MD_PerimeterWallN", { 224, 12, 4 }, { 0, 6, -104 } },
    { "MD_PerimeterWallS", { 224, 12, 4 }, { 0, 6, 104 } },
    { "MD_PerimeterWallW", { 4, 12, 208 }, { -112, 6, 0 } },
    { "MD_PerimeterWallE", { 4, 12, 208 }, { 112, 6, 0 } },
}
for _, wall in ipairs(perimeter) do
    add({
        bucket = "Structure",
        name = wall[1],
        size = wall[2],
        pos = wall[3],
        material = "Concrete",
        color = CONCRETE,
        castShadow = true,
    })
end

-- 6-7. Spawn front walls, 4 segments each, mirrored across Z.
-- Doors (art spec §1.1): X -100..-80 | -14..14 | 80..100.
for _, side in ipairs({ { "MusterDeck", -78 }, { "YardHouse", 78 } }) do
    local label, z = side[1], side[2]
    local segments = {
        { "A", 10, -105 },
        { "B", 66, -47 },
        { "C", 66, 47 },
        { "D", 10, 105 },
    }
    for _, segment in ipairs(segments) do
        add({
            bucket = "Structure",
            name = "MD_" .. label .. "FrontWall" .. segment[1],
            size = { segment[2], 12, 4 },
            pos = { segment[3], 6, z },
            material = "Concrete",
            color = CONCRETE,
        })
    end
end

-- 8-9. Lane inner walls (Gangway / Boom Row)
add({
    bucket = "Structure",
    name = "MD_GangwayInnerWall",
    size = { 4, 12, 34 },
    pos = { -65, 6, -61 },
    material = "Concrete",
    color = CONCRETE,
    castShadow = true,
})
add({
    bucket = "Structure",
    name = "MD_BoomRowInnerWall",
    size = { 4, 12, 34 },
    pos = { 65, 6, -61 },
    material = "Concrete",
    color = CONCRETE,
    castShadow = true,
})

-- 10-17. Site A (Port Bay, tight) and Site B (Reactor Deck, open) — mirrored walls,
-- deliberately different interiors. Doors: A north X -48..-36 / A west Z 6..18 /
-- A east Z -4..8; B north X 36..48 / B west Z -4..8 / B east Z 6..18.
local siteWalls = {
    { "MD_SiteANorthWallA", { 12, 12, 4 }, { -54, 6, -26 } },
    { "MD_SiteANorthWallB", { 12, 12, 4 }, { -30, 6, -26 } },
    { "MD_SiteASouthWall", { 36, 12, 4 }, { -42, 6, 26 } },
    { "MD_SiteAWestWallA", { 4, 12, 32 }, { -60, 6, -10 } },
    { "MD_SiteAWestWallB", { 4, 12, 8 }, { -60, 6, 22 } },
    { "MD_SiteAEastWallA", { 4, 12, 22 }, { -24, 6, -15 } },
    { "MD_SiteAEastWallB", { 4, 12, 18 }, { -24, 6, 17 } },
    { "MD_SiteBNorthWallA", { 12, 12, 4 }, { 54, 6, -26 } },
    { "MD_SiteBNorthWallB", { 12, 12, 4 }, { 30, 6, -26 } },
    { "MD_SiteBSouthWall", { 36, 12, 4 }, { 42, 6, 26 } },
    { "MD_SiteBWestWallA", { 4, 12, 22 }, { 24, 6, -15 } },
    { "MD_SiteBWestWallB", { 4, 12, 18 }, { 24, 6, 17 } },
    { "MD_SiteBEastWallA", { 4, 12, 32 }, { 60, 6, -10 } },
    { "MD_SiteBEastWallB", { 4, 12, 8 }, { 60, 6, 22 } },
}
for _, wall in ipairs(siteWalls) do
    local isSouth = wall[1]:find("SouthWall") ~= nil
    add({
        bucket = "Structure",
        name = wall[1],
        size = wall[2],
        pos = wall[3],
        material = "Concrete",
        color = if isSouth then CONCRETE_DARK else CONCRETE,
        castShadow = isSouth,
    })
end

-- 18-20. South Depot (roofed plaza)
add({
    bucket = "Structure",
    name = "MD_SouthDepotNorthWallA",
    size = { 20, 12, 4 },
    pos = { -16, 6, 40 },
    material = "Concrete",
    color = CONCRETE,
})
add({
    bucket = "Structure",
    name = "MD_SouthDepotNorthWallB",
    size = { 20, 12, 4 },
    pos = { 16, 6, 40 },
    material = "Concrete",
    color = CONCRETE,
})
add({
    bucket = "Structure",
    name = "MD_SouthDepotSouthWall",
    size = { 52, 12, 4 },
    pos = { 0, 6, 70 },
    material = "Concrete",
    color = CONCRETE,
})
add({
    bucket = "Structure",
    name = "MD_SouthDepotWestWall",
    size = { 4, 12, 30 },
    pos = { -26, 6, 55 },
    material = "Concrete",
    color = CONCRETE,
})
add({
    bucket = "Structure",
    name = "MD_SouthDepotEastWall",
    size = { 4, 12, 30 },
    pos = { 26, 6, 55 },
    material = "Concrete",
    color = CONCRETE,
})
add({
    bucket = "Structure",
    name = "MD_SouthDepotRoof",
    size = { 56, 1, 34 },
    pos = { 0, 12.5, 55 },
    material = "Concrete",
    color = CONCRETE_ROOF,
    castShadow = true,
})

-- 21-22. North Works blocks (staging area furniture)
add({
    bucket = "Structure",
    name = "MD_NorthWorksWestBlock",
    size = { 28, 10, 18 },
    pos = { -42, 5, -61 },
    material = "Concrete",
    color = CONCRETE,
})
add({
    bucket = "Structure",
    name = "MD_NorthWorksEastBlock",
    size = { 28, 10, 18 },
    pos = { 42, 5, -61 },
    material = "Concrete",
    color = CONCRETE,
})

-- 23. Spillway (mid tower) — C3
add({
    bucket = "Structure",
    name = "MD_SpillwayTower",
    size = { 40, 9, 12 },
    pos = { 0, 4.5, -44 },
    material = "CorrodedMetal",
    color = RUST,
    cover = "C3",
})

-- ════════════════════════════════════════════════════════════════════════════
-- TABLE 1B — cover (art spec §1.6). Classes: C1 4 / C2 6 / C3 9 (studs).
-- ════════════════════════════════════════════════════════════════════════════

-- Gangway blockers: 28 wide in a 45-stud lane, alternating sides (W,E,W,E,W).
-- Instanced so the numbers stay readable instead of a hand-copied pattern.
do
    local zOrder = { -58, -34, 10, 34, 58 }
    local xOrder = { -96, -79, -96, -79, -96 }
    for index = 1, 5 do
        add({
            bucket = "Cover",
            name = "MD_GangwayBlocker" .. index,
            size = { 28, 6, 12 },
            pos = { xOrder[index], 3, zOrder[index] },
            material = "Metal",
            color = METAL,
            cover = "C2",
        })
    end
end

-- Boom Row blockers: mirror of Gangway (E,W,E,W,E).
do
    local zOrder = { -58, -34, 10, 34, 58 }
    local xOrder = { 96, 79, 96, 79, 96 }
    for index = 1, 5 do
        add({
            bucket = "Cover",
            name = "MD_BoomRowBlocker" .. index,
            size = { 28, 6, 12 },
            pos = { xOrder[index], 3, zOrder[index] },
            material = "Metal",
            color = METAL,
            cover = "C2",
        })
    end
end

-- Tide Bridge pylons (the map's only 57-stud lane ends here) — C3
add({ bucket = "Cover", name = "MD_BridgePylonW", size = { 14, 9, 12 }, pos = { -46, 4.5, -44 }, material = "Concrete", color = CONCRETE_DARK, cover = "C3" })
add({ bucket = "Cover", name = "MD_BridgePylonE", size = { 14, 9, 12 }, pos = { 46, 4.5, -44 }, material = "Concrete", color = CONCRETE_DARK, cover = "C3" })

-- Causeway staging containers — C2
local staging = {
    { "MD_StagingBoxA", { 18, 6, 10 }, { -12, 3, -66 }, { 0, 96, 100 } },
    { "MD_StagingBoxB", { 18, 6, 10 }, { 14, 3, -56 }, { 150, 60, 40 } },
    { "MD_StagingBoxC", { 24, 6, 12 }, { 0, 3, -37 }, { 98, 100, 62 } },
}
for _, box in ipairs(staging) do
    add({ bucket = "Cover", name = box[1], size = box[2], pos = box[3], material = "Metal", color = box[4], cover = "C2" })
end

-- Mid Cross: one C2 box plus two C1 crates (low cover — torso only, NOT head cover)
add({ bucket = "Cover", name = "MD_MidCrossBox", size = { 24, 6, 12 }, pos = { 0, 3, -6 }, material = "Metal", color = { 150, 60, 40 }, cover = "C2" })
add({ bucket = "Cover", name = "MD_MidCrossCrateW", size = { 12, 4, 10 }, pos = { -12, 2, 10 }, material = "Slate", color = SLATE, cover = "C1" })
add({ bucket = "Cover", name = "MD_MidCrossCrateE", size = { 12, 4, 10 }, pos = { 12, 2, 10 }, material = "Slate", color = SLATE, cover = "C1" })

-- Causeway south blocker + plaza rotation cover
add({ bucket = "Cover", name = "MD_CausewaySouthBlocker", size = { 24, 6, 12 }, pos = { 0, 3, 30 }, material = "Metal", color = { 98, 100, 62 }, cover = "C2" })
add({ bucket = "Cover", name = "MD_PlazaCoverW", size = { 16, 6, 12 }, pos = { -46, 3, 52 }, material = "Metal", color = { 0, 96, 100 }, cover = "C2" })
add({ bucket = "Cover", name = "MD_PlazaCoverE", size = { 16, 6, 12 }, pos = { 46, 3, 52 }, material = "Metal", color = { 0, 96, 100 }, cover = "C2" })

-- Site A interior — tight/cluttered (C2x3, C3 boost block, C1x2)
add({ bucket = "Cover", name = "MD_SiteACover1", size = { 14, 6, 14 }, pos = { -52, 3, -16 }, material = "Metal", color = { 150, 60, 40 }, cover = "C2" })
add({ bucket = "Cover", name = "MD_SiteACover2", size = { 12, 6, 12 }, pos = { -34, 3, -14 }, material = "Metal", color = { 98, 100, 62 }, cover = "C2" })
add({ bucket = "Cover", name = "MD_SiteACover3", size = { 14, 6, 12 }, pos = { -52, 3, 14 }, material = "Metal", color = { 0, 96, 100 }, cover = "C2" })
add({ bucket = "Cover", name = "MD_SiteACoverBoost", size = { 12, 9, 10 }, pos = { -34, 5, 16 }, material = "Metal", color = CONCRETE_DARK, cover = "C3", boost = true })
add({ bucket = "Cover", name = "MD_SiteACover4", size = { 8, 4, 8 }, pos = { -44, 2, 2 }, material = "Slate", color = SLATE, cover = "C1" })
add({ bucket = "Cover", name = "MD_SiteACover5", size = { 6, 4, 6 }, pos = { -30, 2, 4 }, material = "Slate", color = SLATE, cover = "C1" })

-- Site B interior — open (C3x2 pillars, C2x3, C3 container)
add({ bucket = "Cover", name = "MD_SiteBPillarW", size = { 12, 5, 5 }, pos = { 36, 6, -16 }, material = "CorrodedMetal", color = RUST, shape = "Cylinder", rotZ = 90, cover = "C3" })
add({ bucket = "Cover", name = "MD_SiteBPillarE", size = { 12, 5, 5 }, pos = { 52, 6, -14 }, material = "CorrodedMetal", color = RUST, shape = "Cylinder", rotZ = 90, cover = "C3" })
add({ bucket = "Cover", name = "MD_SiteBContainer", size = { 18, 6, 12 }, pos = { 44, 3, 14 }, material = "Metal", color = { 98, 100, 62 }, cover = "C2" })
add({ bucket = "Cover", name = "MD_SiteBCrateA", size = { 10, 6, 10 }, pos = { 34, 3, 4 }, material = "Metal", color = { 0, 96, 100 }, cover = "C2" })
add({ bucket = "Cover", name = "MD_SiteBCrateB", size = { 12, 6, 12 }, pos = { 56, 3, 4 }, material = "Metal", color = { 0, 96, 100 }, cover = "C2" })
add({ bucket = "Cover", name = "MD_SiteBStack", size = { 14, 12, 10 }, pos = { 44, 6, 20 }, material = "Metal", color = { 98, 100, 62 }, cover = "C3" })

-- Spawn locker rows — C3, 3 per spawn room (X -72 / 0 / 72 at Z -90 and +90)
do
    local rows = {
        { "N", -90 },
        { "S", 90 },
    }
    local xOrder = { -72, 0, 72 }
    for _, row in ipairs(rows) do
        for index, x in ipairs(xOrder) do
            add({
                bucket = "Cover",
                name = "MD_LockerRow" .. row[1] .. index,
                size = { 24, 8, 14 },
                pos = { x, 4, row[2] },
                material = "Metal",
                color = METAL,
                cover = "C3",
            })
        end
    end
end

-- ════════════════════════════════════════════════════════════════════════════
-- TABLE 1C — markers, paint, detail (art spec §1.7, thinned where the spec's
-- row is pure repetition: railing posts are generated in a loop)
-- ════════════════════════════════════════════════════════════════════════════

-- Plant pads (flat cylinders) + mint kerbs
local pads = {
    { "MD_Pad_PortBay", -42, { 255, 213, 0 } },
    { "MD_Pad_ReactorDeck", 42, { 200, 90, 255 } },
}
for _, pad in ipairs(pads) do
    add({
        bucket = "Markers",
        name = pad[1],
        size = { 0.2, 12, 12 },
        pos = { pad[2], 0.11, 0 },
        material = "Concrete",
        color = pad[3],
        shape = "Cylinder",
        rotZ = 90,
    })
    add({ bucket = "Markers", name = pad[1] .. "KerbN", size = { 12, 0.3, 0.4 }, pos = { pad[2], 0.15, -6 }, material = "Neon", color = NEON_MINT })
    add({ bucket = "Markers", name = pad[1] .. "KerbS", size = { 12, 0.3, 0.4 }, pos = { pad[2], 0.15, 6 }, material = "Neon", color = NEON_MINT })
    add({ bucket = "Markers", name = pad[1] .. "KerbW", size = { 0.4, 0.3, 12 }, pos = { pad[2] - 6, 0.15, 0 }, material = "Neon", color = NEON_MINT })
    add({ bucket = "Markers", name = pad[1] .. "KerbE", size = { 0.4, 0.3, 12 }, pos = { pad[2] + 6, 0.15, 0 }, material = "Neon", color = NEON_MINT })
end

-- Causeway centre line + Tide Bridge hazard stripes
add({ bucket = "Markers", name = "MD_CausewayCentreLine", size = { 4, 0.2, 152 }, pos = { 0, 0.11, 0 }, material = "Concrete", color = { 240, 240, 240 } })
add({ bucket = "Markers", name = "MD_HazardStripeN", size = { 220, 0.2, 2 }, pos = { 0, 0.11, -43 }, material = "Concrete", color = NEON_SUN })
add({ bucket = "Markers", name = "MD_HazardStripeS", size = { 220, 0.2, 2 }, pos = { 0, 0.11, -31 }, material = "Concrete", color = NEON_SUN })

-- Spawn decks (team paint; the Alpha has no Teams service wired to spawning yet,
-- so all spawns are Neutral and this paint is what tells the two rooms apart)
add({ bucket = "Markers", name = "MD_MusterDeckPad", size = { 68, 0.2, 20 }, pos = { 0, 0.11, -90 }, material = "Concrete", color = TEAM_RAIDER })
add({ bucket = "Markers", name = "MD_YardHousePad", size = { 68, 0.2, 20 }, pos = { 0, 0.11, 90 }, material = "Concrete", color = TEAM_WARDEN })

-- Spawn marker columns (Neon, tall enough to read from the yard)
add({ bucket = "Markers", name = "MD_SpawnColumn_NW", size = { 1, 14, 1 }, pos = { -34, 7, -96 }, material = "Neon", color = TEAM_RAIDER })
add({ bucket = "Markers", name = "MD_SpawnColumn_NE", size = { 1, 14, 1 }, pos = { 34, 7, -96 }, material = "Neon", color = TEAM_RAIDER })
add({ bucket = "Markers", name = "MD_SpawnColumn_SW", size = { 1, 14, 1 }, pos = { -34, 7, 96 }, material = "Neon", color = TEAM_WARDEN })
add({ bucket = "Markers", name = "MD_SpawnColumn_SE", size = { 1, 14, 1 }, pos = { 34, 7, 96 }, material = "Neon", color = TEAM_WARDEN })

-- Door lintels (15 doorways) — see Map.Doors for the width that each one spans.
for _, door in ipairs(Map.Doors) do
    local along = if door.axis == "x" then { door.width + 2, 1, 1 } else { 1, 1, door.width + 2 }
    add({
        bucket = "Markers",
        name = "MD_DoorLintel_" .. door.id,
        size = along,
        pos = { door.centre[1], 11.5, door.centre[2] },
        material = "Neon",
        color = NEON_SUN,
    })
end

-- Lane kerbs (4)
for _, x in ipairs({ -63.5, 63.5 }) do
    add({ bucket = "Markers", name = "MD_LaneKerb_" .. tostring(x):gsub("%.", "_"), size = { 2, 0.6, 150 }, pos = { x, 0.3, 0 }, material = "Concrete", color = CONCRETE_DARK })
end
for _, x in ipairs({ -111.5, 111.5 }) do
    add({ bucket = "Markers", name = "MD_SpawnKerb_" .. tostring(x):gsub("%.", "_"), size = { 2, 0.6, 150 }, pos = { x, 0.3, 0 }, material = "Concrete", color = CONCRETE_DARK })
end

-- Railing posts: 10 per lane edge x 4 edges (art spec §1.7)
do
    local zStart, zStep = -70, 15.5
    for _, edge in ipairs({ { -63.5, "W" }, { 63.5, "E" }, { -111.5, "SW" }, { 111.5, "SE" } }) do
        local x, tag = edge[1], edge[2]
        for index = 0, 9 do
            add({
                bucket = "Markers",
                name = "MD_RailingPost_" .. tag .. "_" .. tostring(index),
                size = { 0.6, 3, 0.6 },
                pos = { x, 1.5, zStart + index * zStep },
                material = "Metal",
                color = METAL,
            })
        end
    end
end

-- Overhead pipe runs
add({ bucket = "Markers", name = "MD_OverheadPipeW", size = { 0.8, 0.8, 200 }, pos = { -110, 11, 0 }, material = "CorrodedMetal", color = RUST })
add({ bucket = "Markers", name = "MD_OverheadPipeE", size = { 0.8, 0.8, 200 }, pos = { 110, 11, 0 }, material = "CorrodedMetal", color = RUST })

-- ════════════════════════════════════════════════════════════════════════════
-- Sightlines (art spec §1.4 — the eight longest lines, recomputed by the test).
-- `blocker` names the piece that ends the run. Ray height for the recompute is
-- Map.SightlineRayY: the spec's own lines are torso-level (its Site A blocker is
-- a C1 4-stud crate, which cannot stop a head-height line — that is the whole
-- point of the C1 correction).
-- ════════════════════════════════════════════════════════════════════════════
Map.SightlineRayY = 3.5

Map.Sightlines = {
    { name = "TideBridgeW", from = { -110, -44 }, to = { -53, -44 }, lengthStuds = 57, blocker = "MD_BridgePylonW", band = "extreme" },
    { name = "TideBridgeE", from = { 110, -44 }, to = { 53, -44 }, lengthStuds = 57, blocker = "MD_BridgePylonE", band = "extreme" },
    { name = "CausewayN", from = { 0, -78 }, to = { 0, -50 }, lengthStuds = 28, blocker = "MD_SpillwayTower", band = "long" },
    { name = "CausewayMid", from = { 0, -38 }, to = { 0, -12 }, lengthStuds = 26, blocker = "MD_MidCrossBox", band = "long" },
    { name = "GangwayAxial", from = { -79, -40 }, to = { -79, -64 }, lengthStuds = 24, blocker = "MD_GangwayBlocker2", band = "standard" },
    { name = "SpawnAxial", from = { -110, -90 }, to = { -84, -90 }, lengthStuds = 26, blocker = "MD_LockerRowN1", band = "long" },
    { name = "SiteAInterior", from = { -42, -26 }, to = { -42, -2 }, lengthStuds = 24, blocker = "MD_SiteACover4", band = "standard" },
    { name = "SiteBInterior", from = { 42, -26 }, to = { 42, 8 }, lengthStuds = 34, blocker = "MD_SiteBContainer", band = "long" },
}

-- ════════════════════════════════════════════════════════════════════════════
-- Spawns. Art spec §1.1: Muster Deck = Raiders (north), Yard House = Wardens
-- (south). Practice start is the Alpha's solo path — it lives in Muster Deck,
-- clear of the locker rows (X -84..-60, -12..12, 60..84 at Z -97..-83).
-- ════════════════════════════════════════════════════════════════════════════
Map.Spawns = {
    { name = "Spawn_Raiders", pos = { -36, 0.5, -88 }, team = "Raiders" },
    { name = "Spawn_Practice", pos = { 36, 0.5, -88 }, team = "Practice" },
    { name = "Spawn_Wardens", pos = { 36, 0.5, 88 }, team = "Wardens" },
}

-- ════════════════════════════════════════════════════════════════════════════
-- World settings (art spec §2, §4)
-- ════════════════════════════════════════════════════════════════════════════
Map.Workspace = {
    StreamingEnabled = false, -- art spec §4: streaming would let players shoot unloaded cover
}

return Map
