--!nocheck
--[[
	BEACON PROTOCOL — MERIDIAN DOCKS map data (phase 1: coarse world).

	SINGLE SOURCE OF TRUTH for the Alpha map. Nothing in here uses Roblox APIs,
	so it loads under plain Lune: `tools/gen_map.luau` turns it into the committed
	Rojo model `map/MeridianDocks.rbxmx`, and `tests/map_sightlines.lua` recomputes
	the art spec's sightlines and cover heights straight out of this table.

	Units: STUDS, always. Ground top = Y 0 (art spec §1.1: every surface at Y 0).
	Geometry, cover and markers follow /home/team/shared/gdd/alpha-art-spec.md.

	Part record:
		{ name, size = {x,y,z}, pos = {x,y,z}, material, color = {r,g,b} (0-255),
		  shape = "Block"|"Cylinder" (default Block), rotZ = degrees (cylinder axis),
		  cover = "C1"|"C2"|"C3" (cover class, art spec §1.3), boost = true (BOOST-marked top),
		  castShadow = true (default false) }
]]

local Map = {}

Map.Name = "MeridianDocks"
Map.DisplayName = "Meridian Docks"

-- Art spec §1.1: flat tidal-dock yard 236 x 220 studs, every surface at Y 0.
Map.Extent = { widthStuds = 236, depthStuds = 220, groundTopY = 0 }

-- Art spec §1.3 (C1 correction 2026-09-19): cover classes ARE hitbox heights.
-- C1 = 4 does NOT block a standing head. Anything claiming to block a standing
-- head must be >= COVER.C2 (6 studs).
Map.CoverClasses = { C1 = 4, C2 = 6, C3 = 9 }

-- R1: no uninterrupted sightline anywhere; 57 studs is the map maximum, 60 the cap.
Map.SightlineMaxStuds = 57
Map.SightlineHardCapStuds = 60

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

-- ── Phase 1: the coarse world (ground, boundary, spawn pads) ────────────────
Map.Parts = {
	-- Ground slab (art spec Table 1A row 1)
	{ bucket = "Structure", name = "MD_GroundSlab", size = { 236, 4, 220 }, pos = { 0, -2, 0 }, material = "Asphalt", color = { 74, 76, 78 } },
	-- Perimeter (art spec Table 1A rows 2-5)
	{ bucket = "Structure", name = "MD_PerimeterWallN", size = { 224, 12, 4 }, pos = { 0, 6, -104 }, material = "Concrete", color = { 110, 110, 114 }, castShadow = true },
	{ bucket = "Structure", name = "MD_PerimeterWallS", size = { 224, 12, 4 }, pos = { 0, 6, 104 }, material = "Concrete", color = { 110, 110, 114 }, castShadow = true },
	{ bucket = "Structure", name = "MD_PerimeterWallW", size = { 4, 12, 208 }, pos = { -112, 6, 0 }, material = "Concrete", color = { 110, 110, 114 }, castShadow = true },
	{ bucket = "Structure", name = "MD_PerimeterWallE", size = { 4, 12, 208 }, pos = { 112, 6, 0 }, material = "Concrete", color = { 110, 110, 114 }, castShadow = true },
	-- Spawn decks (art spec Table 1C pads, minus the mid-lane dressing)
	{ bucket = "Markers", name = "MD_MusterDeckPad", size = { 68, 0.2, 20 }, pos = { 0, 0.11, -90 }, material = "Concrete", color = { 200, 110, 40 } },
	{ bucket = "Markers", name = "MD_YardHousePad", size = { 68, 0.2, 20 }, pos = { 0, 0.11, 90 }, material = "Concrete", color = { 40, 120, 190 } },
}

-- Spawns (art spec §1.1: Muster Deck = Raiders, Yard House = Wardens, + practice).
-- All three are Neutral/Enabled in phase 1: the Alpha has no Teams service wired
-- to spawning yet, so a solo player must always land somewhere valid.
Map.Spawns = {
	{ name = "Spawn_Raiders", pos = { 0, 0.5, -90 } },
	{ name = "Spawn_Wardens", pos = { 0, 0.5, 90 } },
	{ name = "Spawn_Practice", pos = { -40, 0.5, -90 } },
}

-- Art spec §2. `Technology` is read-only at runtime: it must be in the place file.
Map.Workspace = {
	StreamingEnabled = false, -- art spec §4: streaming would let players shoot unloaded cover
}

Map.Lighting = {
	ClockTime = 17.4,
	GeographicLatitude = 25,
	Brightness = 2.0,
	ExposureCompensation = 0.15,
	GlobalShadows = true,
	ShadowSoftness = 0.25,
	EnvironmentDiffuseScale = 0.4,
	EnvironmentSpecularScale = 0.3,
	FogStart = 60,
	FogEnd = 340,
}

Map.Sightlines = {}

return Map
