--!nocheck
--[[
	tools/gen_map.luau — build map/MeridianDocks.rbxmx from map/meridian_docks.luau.

	Why this exists: the place must contain the world as real, greppable geometry
	(so the owner sees a map the moment the .rbxl opens in Studio), and Rojo pulls
	binary/XML models in via `$path` (packages/knit/Knit.rbxm is the working
	example). Hand-written Rojo `.model.json` does not parse, and Lune's
	`roblox.serializeModel` fails — so the committed artifact is a plain
	`.rbxmx` (XML) model, generated from the data table and committed to the repo.

		rrun:  lune run tools/gen_map.luau

	Format notes proven 2026-09-28 (do not "simplify" without re-proving):
	  * Vector3 values MUST be <X>/<Y>/<Z> child elements, not a text payload
	    (rojo: "Unexpected XML event Characters(236,4,220)").
	  * Material / shape are <token> elements; Color3uint8 is the packed int.
	  * Rojo replaces the model's root instance with the project node, so the
	    root here is just a container named "Workspace".
]]

local fs = require("@lune/fs")

local map = require("../map/meridian_docks")

local TAB = "\t"

local function indent(level)
	return TAB:rep(level)
end

local function esc(text)
	return (tostring(text):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function num(value)
	if value == math.floor(value) then
		return string.format("%d", value)
	end
	return string.format("%.6f", value)
end

local function packedColor(color)
	return 4278190080 + color[1] * 65536 + color[2] * 256 + color[3]
end

-- Cylinder parts in Roblox run along their LOCAL X axis, so a vertical cylinder
-- and a flat floor disc are the same shape rotated 90 degrees about Z.
local function rotation(rotZ)
	local radians = math.rad(rotZ or 0)
	local c, s = math.cos(radians), math.sin(radians)
	return {
		{ c, -s, 0 },
		{ s, c, 0 },
		{ 0, 0, 1 },
	}
end

local function vector3Element(key, value, level)
	return table.concat({
		indent(level) .. "<Vector3 name=\"" .. key .. "\">",
		indent(level + 1) .. "<X>" .. num(value[1]) .. "</X>",
		indent(level + 1) .. "<Y>" .. num(value[2]) .. "</Y>",
		indent(level + 1) .. "<Z>" .. num(value[3]) .. "</Z>",
		indent(level) .. "</Vector3>",
	}, "\n")
end

local function cframeElement(pos, rotZ, level)
	local r = rotation(rotZ)
	local rows = {
		"<X>" .. num(pos[1]) .. "</X>",
		"<Y>" .. num(pos[2]) .. "</Y>",
		"<Z>" .. num(pos[3]) .. "</Z>",
	}
	for i = 1, 3 do
		for j = 1, 3 do
			local key = "R" .. (i - 1) .. (j - 1)
			rows[#rows + 1] = "<" .. key .. ">" .. num(r[i][j]) .. "</" .. key .. ">"
		end
	end
	local lines = { indent(level) .. "<CoordinateFrame name=\"CFrame\">" }
	for _, row in ipairs(rows) do
		lines[#lines + 1] = indent(level + 1) .. row
	end
	lines[#lines + 1] = indent(level) .. "</CoordinateFrame>"
	return table.concat(lines, "\n")
end

local referentCounter = 0
local function nextReferent()
	local ref = "RBX" .. tostring(referentCounter)
	referentCounter += 1
	return ref
end

local function partItem(part)
	local material = map.Materials[part.material]
	assert(material, "unknown material '" .. tostring(part.material) .. "' on " .. part.name)
	local properties = {
		indent(3) .. "<bool name=\"Anchored\">true</bool>",
	}
	if part.castShadow then
		properties[#properties + 1] = indent(3) .. "<bool name=\"CastShadow\">true</bool>"
	end
	properties[#properties + 1] = indent(3) .. "<Color3uint8 name=\"Color3uint8\">" .. tostring(packedColor(part.color)) .. "</Color3uint8>"
	properties[#properties + 1] = cframeElement(part.pos, part.rotZ, 3)
	properties[#properties + 1] = indent(3) .. "<token name=\"Material\">" .. tostring(material) .. "</token>"
	properties[#properties + 1] = indent(3) .. "<string name=\"Name\">" .. esc(part.name) .. "</string>"
	properties[#properties + 1] = indent(3) .. "<token name=\"shape\">" .. (if part.shape == "Cylinder" then "2" else "1") .. "</token>"
	properties[#properties + 1] = vector3Element("size", part.size, 3)

	return table.concat({
		indent(1) .. "<Item class=\"Part\" referent=\"" .. nextReferent() .. "\">",
		indent(2) .. "<Properties>",
		table.concat(properties, "\n"),
		indent(2) .. "</Properties>",
		indent(1) .. "</Item>",
	}, "\n")
end

local function spawnItem(spawn)
	return table.concat({
		indent(1) .. "<Item class=\"SpawnLocation\" referent=\"" .. nextReferent() .. "\">",
		indent(2) .. "<Properties>",
		indent(3) .. "<bool name=\"Anchored\">true</bool>",
		cframeElement(spawn.pos, 0, 3),
		indent(3) .. "<bool name=\"Enabled\">true</bool>",
		indent(3) .. "<string name=\"Name\">" .. esc(spawn.name) .. "</string>",
		indent(3) .. "<bool name=\"Neutral\">true</bool>",
		vector3Element("size", { 12, 1, 12 }, 3),
		indent(2) .. "</Properties>",
		indent(1) .. "</Item>",
	}, "\n")
end

local function folderItem(name, body)
	local lines = {
		indent(1) .. "<Item class=\"Folder\" referent=\"" .. nextReferent() .. "\">",
		indent(2) .. "<Properties>",
		indent(3) .. "<string name=\"Name\">" .. esc(name) .. "</string>",
		indent(2) .. "</Properties>",
	}
	if #body > 0 then
		lines[#lines + 1] = table.concat(body, "\n")
	end
	lines[#lines + 1] = indent(1) .. "</Item>"
	return table.concat(lines, "\n")
end

-- ── assemble ────────────────────────────────────────────────────────────────
local failures = {}

local rootLines = {
	"<roblox xmlns:xmime=\"http://www.w3.org/2005/05/xmlmime\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xsi:noNamespaceSchemaLocation=\"http://www.roblox.com/roblox.xsd\" version=\"4\">",
	indent(1) .. "<Item class=\"Folder\" referent=\"" .. nextReferent() .. "\">",
	indent(2) .. "<Properties>",
	indent(3) .. "<string name=\"Name\">" .. esc(map.Name) .. "</string>",
	indent(2) .. "</Properties>",
}

local seenParts = {}
for _, bucket in ipairs(map.Buckets) do
	local body = {}
	for _, part in ipairs(map.Parts) do
		if part.bucket == bucket then
			if seenParts[part.name] then
				failures[#failures + 1] = "duplicate part name: " .. part.name
			end
			seenParts[part.name] = true
			body[#body + 1] = partItem(part)
		end
	end
	rootLines[#rootLines + 1] = folderItem(bucket, body)
end

local spawnBody = {}
local seenSpawns = {}
for _, spawn in ipairs(map.Spawns) do
	if seenSpawns[spawn.name] then
		failures[#failures + 1] = "duplicate spawn name: " .. spawn.name
	end
	seenSpawns[spawn.name] = true
	spawnBody[#spawnBody + 1] = spawnItem(spawn)
end
rootLines[#rootLines + 1] = folderItem("Spawns", spawnBody)

rootLines[#rootLines + 1] = indent(1) .. "</Item>"
rootLines[#rootLines + 1] = "</roblox>"

if #failures > 0 then
	for _, failure in ipairs(failures) do
		print("[gen_map] FAILURE: " .. failure)
	end
	error("map data is inconsistent")
end

local xml = table.concat(rootLines, "\n") .. "\n"
fs.writeFile("map/MeridianDocks.rbxmx", xml)

print(string.format(
	"[gen_map] wrote map/MeridianDocks.rbxmx — %d anchored parts, %d spawn points, %d bytes",
	#map.Parts,
	#map.Spawns,
	#xml
))
