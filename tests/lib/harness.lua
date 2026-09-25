--[[
    BEACON PROTOCOL — Phase 1 headless harness (Lune).

    Roblox Studio is not available to the team, so this file builds the
    smallest environment that the SERVER TREE actually needs and then runs
    the real files out of src/ inside it:

        * Logic modules (src/server/Logic/*) are ordinary Lune requires —
          they are pure Luau and only need the `_G.task` shim.
        * Services + init.server.lua are executed with `luau.load(..., env)`
          because they touch Roblox globals (`game`, `script`, `Players`,
          `RunService`, `require`). The env supplies faithful, minimal
          stand-ins: a DataModel whose tree matches default.project.json,
          a Knit API surface, a synchronous Players/RunService, and an
          `os` library that looks like Roblox's (clock/time/date/difftime,
          NO `now`).

    Nothing in src/ is modified, stubbed or copied — the harness reads the
    real source text and executes it. Run it from the repo root:

        lune run tests/round_loop.lua
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")

local H = {}

-- ---------------------------------------------------------------- scheduler
-- Deterministic replacement for Roblox's `task`: spawned work is queued and
-- only runs when the test calls flush(), so event ordering is explicit.
-- A task that yields (the AFK-kick `while true do task.wait(5)` loop) is
-- parked forever — the harness clock only moves when a test moves it.
local ready = {}
local parked = {}
local lastError = nil

local function spawnTask(fn, ...)
	table.insert(ready, { co = coroutine.create(fn), args = { ... } })
end

local taskStub = {
	spawn = spawnTask,
	defer = spawnTask,
	delay = function(_, fn, ...)
		spawnTask(fn, ...)
	end,
	wait = function()
		coroutine.yield()
	end,
}

-- Logic modules capture `_G.task` at require time (Roblox provides the global,
-- standalone Luau does not), so install it before loading anything.
_G.task = taskStub

-- Run every queued task to completion. Returns the last uncaught task error.
function H.flush(maxSteps)
	local steps = 0
	while #ready > 0 do
		steps += 1
		if steps > (maxSteps or 500) then
			error("harness scheduler did not settle after " .. steps .. " tasks")
		end
		local item = table.remove(ready, 1)
		local ok, err = coroutine.resume(item.co, table.unpack(item.args))
		if not ok then
			lastError = err
		end
		if coroutine.status(item.co) ~= "dead" then
			table.insert(parked, item)
		end
	end
	return lastError
end

function H.taskCount()
	return #ready
end

-- ------------------------------------------------------------------ stdlib
-- luau.load() environments do not inherit the standard library, so hand the
-- stub-loaded files an explicit one (the harness itself still has real globals).
local STDLIB = {
	assert = assert,
	coroutine = coroutine,
	debug = debug,
	error = error,
	getmetatable = getmetatable,
	ipairs = ipairs,
	math = math,
	next = next,
	newproxy = newproxy,
	pairs = pairs,
	pcall = pcall,
	print = print,
	rawequal = rawequal,
	rawget = rawget,
	rawset = rawset,
	select = select,
	setmetatable = setmetatable,
	string = string,
	table = table,
	tonumber = tonumber,
	tostring = tostring,
	type = type,
	typeof = typeof,
	unpack = unpack,
	warn = warn,
	xpcall = xpcall,
}

-- --------------------------------------------------------------- instances
-- `InstanceMT` holds the methods; the per-instance metatable adds Roblox's
-- dot-child lookup (`script.Services`, `script.Parent.Parent.Logic.Foo`)
-- on top of them, which is how services reach their siblings and modules.
local InstanceMT = {}

local InstanceMeta = {
	__index = function(self, key)
		local child = self._children[key]
		if child ~= nil then
			return child
		end
		return InstanceMT[key]
	end,
}

local function newInstance(className, name)
	return setmetatable({ ClassName = className, Name = name, _children = {}, _order = {} }, InstanceMeta)
end

function InstanceMT:IsA(className)
	return self.ClassName == className
end

function InstanceMT:GetChildren()
	return table.clone(self._order)
end

function InstanceMT:GetDescendants()
	local out = {}
	local function walk(node)
		for _, child in node._order do
			table.insert(out, child)
			walk(child)
		end
	end
	walk(self)
	return out
end

function InstanceMT:FindFirstChild(name)
	return self._children[name]
end

function InstanceMT:WaitForChild(name)
	local child = self._children[name]
	if child == nil then
		error(("WaitForChild(%q) not present on %s"):format(name, self.Name))
	end
	return child
end

function InstanceMT:GetService(name)
	local service = self._children[name]
	if service == nil then
		error(("game:GetService(%q) — no such service in the harness tree"):format(name))
	end
	return service
end

local function addChild(parent, child)
	-- Roblox instances always have a Name before they are parented; the stub
	-- must too, otherwise `_children[nil] = child` fails with "table index is
	-- nil" far from the real mistake. Name non-instance stubs (Players,
	-- RunService) at construction, not after parenting.
	assert(type(child.Name) == "string", "harness stub added to " .. tostring(parent.Name) .. " has no Name")
	parent._children[child.Name] = child
	table.insert(parent._order, child)
	child.Parent = parent
	return child
end

-- A module node: `_path` is the real source file to execute, `_value` a
-- pre-supplied module value (used for the Knit package).
local function moduleNode(parent, name, path, className)
	local node = newInstance(className or "ModuleScript", name)
	node._path = path
	addChild(parent, node)
	return node
end

-- ----------------------------------------------------------------- loader
-- Stands in for Roblox's require(): a ModuleScript node resolves to its
-- source file executed with a Roblox-ish environment (cached per boot).
local cache = {}

-- Lune's `@lune/fs` has no `exists` (isFile/isDir only) — probe by reading,
-- so the friendly "run me from the repo root" message survives on any Lune.
local function readSource(path)
	local ok, contents = pcall(fs.readFile, path)
	if not ok then
		error("harness must run from the repo root: missing " .. path .. " (use: lune run tests/round_loop.lua)")
	end
	return contents
end

H.readSource = readSource

local stubRequire

-- Roblox globals the server tree expects in _G: `task` (Logic modules capture
-- `local task = _G.task`) and `_G` itself. `env._G = env` makes _G.task
-- resolve to the stub while every other global falls through to STDLIB.
local function newEnv(fields)
	local env = setmetatable(fields, { __index = STDLIB })
	env._G = env
	return env
end

local function loadNode(node)
	if node._value ~= nil then
		return node._value
	end
	if cache[node] ~= nil then
		return cache[node]
	end
	if node._path == nil then
		error(("no source path for module %s"):format(node.Name))
	end
	local chunk = luau.load(readSource(node._path), {
		debugName = node._path,
		environment = newEnv({
			game = H.tree.root,
			Players = H.players,
			RunService = H.runService,
			require = stubRequire,
			script = node,
			task = taskStub,
			Instance = { new = newInstance },
			os = H.osShape,
			-- Only the Roblox surface the hit path actually touches: the
			-- world-geometry raycast built in CombatService.
			Vector3 = {
				new = function(x, y, z)
					return { X = x, Y = y, Z = z }
				end,
			},
			RaycastParams = {
				new = function()
					return { FilterType = nil, FilterDescendantsInstances = {} }
				end,
			},
			Enum = { RaycastFilterType = { Exclude = "Exclude" } },
		}),
		injectGlobals = false,
	})
	local value = chunk()
	cache[node] = value
	return value
end

stubRequire = function(target)
	if type(target) == "string" then
		error("stub-loaded modules must require tree nodes, got string " .. target)
	end
	if type(target) ~= "table" or target.ClassName == nil then
		error("cannot require " .. tostring(target))
	end
	return loadNode(target)
end

-- -------------------------------------------------------------- fake Knit
local SyncSignal = {}
SyncSignal.__index = SyncSignal

function SyncSignal.new()
	return setmetatable({ _listeners = {} }, SyncSignal)
end

function SyncSignal:Connect(listener)
	table.insert(self._listeners, listener)
	local alive = true
	return function()
		if not alive then
			return
		end
		alive = false
		for i = #self._listeners, 1, -1 do
			if self._listeners[i] == listener then
				table.remove(self._listeners, i)
				break
			end
		end
	end
end

function SyncSignal:Fire(...)
	for _, listener in table.clone(self._listeners) do
		local ok, err = pcall(listener, ...)
		if not ok then
			error("signal listener error: " .. tostring(err))
		end
	end
end

H.SyncSignal = SyncSignal

local function newProperty(initial)
	return {
		_value = initial,
		Set = function(self, value)
			self._value = value
		end,
		Get = function(self)
			return self._value
		end,
	}
end

-- The Knit surface the server tree uses, with Knit's own contract checks
-- (duplicate service names, unknown GetService lookups) kept intact.
local function newKnit()
	local Knit = { _services = {}, _started = false }

	function Knit.CreateService(definition)
		assert(type(definition) == "table", "Knit.CreateService expects a table")
		assert(type(definition.Name) == "string" and #definition.Name > 0, "Service.Name must be a non-empty string")
		assert(Knit._services[definition.Name] == nil, `Service "{definition.Name}" already exists`)
		assert(not Knit._started, "Services cannot be created after Knit.Start()")
		definition.Client = definition.Client or {}
		definition.Client.Server = definition
		Knit._services[definition.Name] = definition
		return definition
	end

	function Knit.CreateSignal()
		return SyncSignal.new()
	end

	function Knit.CreateProperty(initial)
		return newProperty(initial)
	end

	function Knit.AddServices(parent)
		local added = {}
		for _, child in parent:GetChildren() do
			if child:IsA("ModuleScript") then
				table.insert(added, stubRequire(child))
			end
		end
		return added
	end

	function Knit.GetService(name)
		local service = Knit._services[name]
		assert(service ~= nil, `Could not find service "{name}"`)
		return service
	end

	function Knit.Start()
		assert(not Knit._started, "Knit already started")
		Knit._started = true
		local initError = nil
		for _, service in Knit._services do
			if type(service.KnitInit) == "function" then
				local ok, err = pcall(service.KnitInit, service)
				if not ok then
					initError = err
				end
			end
		end
		for _, service in Knit._services do
			if type(service.KnitStart) == "function" then
				spawnTask(function()
					service:KnitStart()
				end)
			end
		end
		return {
			catch = function(self, handler)
				if initError ~= nil then
					handler(initError)
				end
				return self
			end,
			andThen = function(self, handler)
				if initError == nil then
					handler()
				end
				return self
			end,
			await = function(self)
				return self
			end,
		}
	end

	return Knit
end

-- ------------------------------------------------------------- fake Players
local function newPlayers()
	local players = {
		ClassName = "Players",
		Name = "Players",
		_list = {},
		PlayerAdded = SyncSignal.new(),
		PlayerRemoving = SyncSignal.new(),
	}

	function players:GetPlayers()
		return table.clone(self._list)
	end

	function players:GetPlayerByUserId(userId)
		for _, player in self._list do
			if player.UserId == userId then
				return player
			end
		end
		return nil
	end

	function players:Add(userId, name)
		local player = { UserId = userId, Name = name or ("P" .. userId), Character = nil }
		table.insert(self._list, player)
		self.PlayerAdded:Fire(player)
		return player
	end

	-- Matches Roblox: the player is out of GetPlayers() by the time
	-- PlayerRemoving fires, so cleanup handlers cannot pay a departed player.
	function players:Remove(player)
		for i, existing in self._list do
			if existing == player then
				table.remove(self._list, i)
				break
			end
		end
		self.PlayerRemoving:Fire(player)
	end

	return players
end

-- ------------------------------------------------------------- fake Workspace
-- Roblox always has a Workspace and the server tree now asks it for two
-- things: the SERVER CLOCK (`GetServerTimeNow`, the domain every combat
-- timestamp lives in — see WORKFLOW "Clock domains") and WORLD GEOMETRY
-- (`Raycast`, so cover can stop bullets). Both contracts are stubbed for
-- real here: the clock is the harness clock, and Raycast is an actual
-- ray-vs-AABB test against parts added with H.addWall, so "a wall blocks the
-- shot" is provable headlessly instead of merely asserted.
local function rayBoxDistance(ox, oy, oz, dx, dy, dz, part)
	-- Slab test. Returns the distance along the ray at which the box is
	-- entered, or nil when the ray misses it.
	local lo, hi = {}, {}
	local size = { part.Size.X, part.Size.Y, part.Size.Z }
	local origin = { ox, oy, oz }
	local dir = { dx, dy, dz }
	local centre = { part.Position.X, part.Position.Y, part.Position.Z }

	local tmin, tmax = -math.huge, math.huge
	for axis = 1, 3 do
		lo[axis] = centre[axis] - size[axis] / 2
		hi[axis] = centre[axis] + size[axis] / 2
		local o, d = origin[axis], dir[axis]
		if math.abs(d) < 1e-9 then
			if o < lo[axis] or o > hi[axis] then
				return nil -- parallel and outside this slab
			end
		else
			local t1 = (lo[axis] - o) / d
			local t2 = (hi[axis] - o) / d
			if t1 > t2 then
				t1, t2 = t2, t1
			end
			tmin = math.max(tmin, t1)
			tmax = math.min(tmax, t2)
			if tmin > tmax then
				return nil
			end
		end
	end
	if tmin >= 0 then
		return tmin
	end
	if tmax >= 0 then
		return tmax -- origin is inside the box
	end
	return nil
end

local function newWorkspace()
	local workspace = {
		ClassName = "Workspace",
		Name = "Workspace",
		_parts = {},
	}

	-- The server clock. CombatService records samples, gates fire rate and
	-- validates client fireTimes in this domain only.
	function workspace:GetServerTimeNow()
		return H.clock.t
	end

	-- H.addWall(name, {x,y,z}, {x,y,z}) — a solid block of world geometry.
	function workspace:AddWall(name, position, size)
		local part = {
			ClassName = "Part",
			Name = name,
			Anchored = true,
			Position = { X = position[1], Y = position[2], Z = position[3] },
			Size = { X = size[1], Y = size[2], Z = size[3] },
		}
		table.insert(self._parts, part)
		return part
	end

	function workspace:ClearWalls()
		self._parts = {}
	end

	-- Workspace:Raycast(origin, direction, params): the direction's
	-- magnitude is the ray length, exactly like Roblox. Honours
	-- FilterDescendantsInstances as an exclusion list (that is how
	-- CombatService keeps player characters out of the geometry query).
	function workspace:Raycast(origin, direction, params)
		local ignored = {}
		if params ~= nil then
			for _, instance in params.FilterDescendantsInstances or {} do
				ignored[instance] = true
			end
		end
		local dx, dy, dz = direction.X, direction.Y, direction.Z
		local rayLength = math.sqrt(dx * dx + dy * dy + dz * dz)
		if rayLength < 1e-6 then
			return nil
		end
		dx, dy, dz = dx / rayLength, dy / rayLength, dz / rayLength

		local ox, oy, oz = origin.X, origin.Y, origin.Z
		local best = nil
		for _, part in self._parts do
			if not ignored[part] then
				local distance = rayBoxDistance(ox, oy, oz, dx, dy, dz, part)
				if distance ~= nil and distance <= rayLength and (best == nil or distance < best.Distance) then
					best = {
						Instance = part,
						Distance = distance,
						Position = { X = ox + dx * distance, Y = oy + dy * distance, Z = oz + dz * distance },
					}
				end
			end
		end
		return best
	end

	return workspace
end

-- ----------------------------------------------------------------- the tree
-- Mirrors what `rojo build default.project.json` produces (verified with
-- `rojo sourcemap`): ServerScriptService.Server is the init.server.lua Script
-- with .Logic and .Services as its children.
local function buildTree()
	local root = newInstance("DataModel", "DataModel")

	local replicatedStorage = addChild(root, newInstance("ReplicatedStorage", "ReplicatedStorage"))
	local packages = addChild(replicatedStorage, newInstance("Folder", "Packages"))
	local knitNode = moduleNode(packages, "Knit", nil)
	knitNode._value = H.knit

	local shared = moduleNode(replicatedStorage, "Shared", "src/shared/init.lua")
	moduleNode(shared, "Constants", "src/shared/Constants.lua")
	moduleNode(shared, "Enums", "src/shared/Enums.lua")
	local config = addChild(shared, newInstance("Folder", "Config"))
	moduleNode(config, "Weapons", "src/shared/Config/Weapons.lua")
	moduleNode(config, "Economy", "src/shared/Config/Economy.lua")
	moduleNode(config, "Combat", "src/shared/Config/Combat.lua")

	local serverScriptService = addChild(root, newInstance("ServerScriptService", "ServerScriptService"))
	local serverScript = moduleNode(serverScriptService, "Server", "src/server/init.server.lua", "Script")
	local logic = addChild(serverScript, newInstance("Folder", "Logic"))
	for _, name in { "DamageModel", "EconomyLedger", "HitDetectionCore", "MatchStateMachine", "PlayerHealth", "Signal" } do
		moduleNode(logic, name, `src/server/Logic/{name}.lua`)
	end
	local services = addChild(serverScript, newInstance("Folder", "Services"))
	for _, name in { "CombatService", "EconomyService", "MatchService", "PlayerStateService" } do
		moduleNode(services, name, `src/server/Services/{name}.lua`)
	end

	addChild(root, H.players)
	addChild(root, H.runService)
	addChild(root, H.workspace)

	return {
		root = root,
		replicatedStorage = replicatedStorage,
		serverScriptService = serverScriptService,
		serverScript = serverScript,
		services = services,
		logic = logic,
	}
end

-- ------------------------------------------------------------------- boot
H.clock = { t = 0 }

function H.clock.now()
	return H.clock.t
end

-- Advance the harness clock and deliver one Heartbeat, exactly like the
-- server's RunService loop does (MatchService:Tick + CombatService:Record).
function H.advance(seconds)
	H.clock.t += seconds
	H.runService.Heartbeat:Fire()
	return H.flush()
end

-- Boot the real server tree: src/server/init.server.lua through
-- Knit.AddServices(script.Services) + Knit.Start(), the same path Roblox runs.
function H.boot()
	ready = {}
	parked = {}
	lastError = nil
	cache = {}
	H.clock.t = 0
	H.players = newPlayers()
	H.knit = newKnit()
	H.workspace = newWorkspace()
	H.runService = {
		ClassName = "RunService",
		Name = "RunService",
		Heartbeat = SyncSignal.new(),
		IsServer = function()
			return true
		end,
		IsRunning = function()
			return true
		end,
	}
	-- Roblox's `os` library: clock/time/date/difftime and NO `now`.
	H.osShape = {
		clock = function()
			return H.clock.t
		end,
		time = os.time,
		date = os.date,
		difftime = os.difftime,
	}
	H.tree = buildTree()
	H.services = {}

	local chunk = luau.load(readSource(H.tree.serverScript._path), {
		debugName = H.tree.serverScript._path,
		environment = newEnv({
			game = H.tree.root,
			require = stubRequire,
			script = H.tree.serverScript,
			task = taskStub,
			os = H.osShape,
			Instance = { new = newInstance },
		}),
		injectGlobals = false,
	})

	local ok, err = pcall(chunk)
	H.bootOk = ok
	H.bootErr = err
	if not ok then
		return false, err
	end
	local flushError = H.flush()
	for name, service in H.knit._services do
		H.services[name] = service
	end
	return flushError == nil, flushError
end

function H.service(name)
	local service = H.services[name]
	if service == nil then
		error(
			("service %q is not registered (boot ok=%s, err=%s)"):format(name, tostring(H.bootOk), tostring(H.bootErr))
		)
	end
	return service
end

-- --------------------------------------------------------------- helpers
-- Solid world geometry for cover tests: H.addWall("Wall", {x,y,z}, {sx,sy,sz}).
function H.addWall(name, position, size)
	return H.workspace:AddWall(name, position, size)
end

function H.clearWalls()
	H.workspace:ClearWalls()
end

-- The server clock the combat path uses (Workspace:GetServerTimeNow()).
function H.serverNow()
	return H.workspace:GetServerTimeNow()
end

--[[
    Attach a minimal character to a player. The server tree reads exactly two
    things off a character:
        character:GetPivot().Position / .ToEulerAnglesYXZ()  (the recorder)
        character.Head.Position                             (origin sanity)
    `y` is the ROOT PIVOT height — the torso centre, ~3 studs above the feet
    for a stock R6 character (WORKFLOW "Hitbox vertical frame"). Head sits
    1.5 studs above the pivot, where a real R6 head part is.
]]
function H.setCharacter(playerId, x, y, z)
	local player = H.players:GetPlayerByUserId(playerId)
	assert(player ~= nil, ("H.setCharacter: no player %d in the game"):format(playerId))
	local character = newInstance("Model", ("Character%d"):format(playerId))
	character.GetPivot = function()
		return {
			Position = { X = x, Y = y, Z = z },
			ToEulerAnglesYXZ = function()
				return 0, 0, 0
			end,
		}
	end
	local head = newInstance("Part", "Head")
	head.Position = { X = x, Y = y + 1.5, Z = z }
	addChild(character, head)
	player.Character = character
	return character
end

--[[
    Drive a real client fire intent through the real remote:
        CombatService.Client:FireRequest(player, payload)
    `origin`/`dir` are plain {x,y,z} tables. fireTime defaults to the server
    clock, which is what a correct client sends (Workspace:GetServerTimeNow).
]]
function H.fire(playerId, weaponId, origin, dir, fireTime)
	local player = H.players:GetPlayerByUserId(playerId)
	assert(player ~= nil, ("H.fire: no player %d in the game"):format(playerId))
	return H.service("Combat").Client:FireRequest(player, {
		weaponId = weaponId,
		fireTime = fireTime or H.serverNow(),
		origin = origin,
		dir = dir,
	})
end

-- Aim from `from` at the torso centre of a player's character, returning the
-- origin/dir pair a client would send. Used to write cover tests in studs.
function H.aimAt(fromX, fromY, fromZ, victimId)
	local player = H.players:GetPlayerByUserId(victimId)
	local pivot = player.Character:GetPivot()
	local target = pivot.Position
	local dx, dy, dz = target.X - fromX, target.Y - fromY, target.Z - fromZ
	return { x = fromX, y = fromY, z = fromZ }, { x = dx, y = dy, z = dz }
end

-- Join `count` players through the real Players.PlayerAdded path.
function H.joinPlayers(firstUserId, count)
	local players = {}
	for i = 0, count - 1 do
		table.insert(players, H.players:Add(firstUserId + i))
	end
	H.flush()
	return players
end

function H.snapshot()
	return H.service("Match").Client:FetchMatchState(nil)
end

-- Kill a player through the real server authority chain: health first, then
-- the match FSM's elimination report (what CombatService does on a lethal hit).
function H.kill(playerId)
	local playerState = H.service("PlayerState")
	playerState:ApplyDamage(playerId, 1000, nil, "TestRig")
	H.service("Match"):ReportPlayerEliminated(playerId)
	H.flush()
end

-- Cheap deep-enough clone used to prove the snapshot/history values are
-- independent of authoritative state.
function H.cloneHistory(history)
	local out = {}
	for i, entry in history do
		local copy = {}
		for key, value in entry do
			copy[key] = value
		end
		out[i] = copy
	end
	return out
end

function H.sortedIds(list)
	local out = table.clone(list)
	table.sort(out)
	return out
end

function H.count(list)
	local n = 0
	for _ in list do
		n += 1
	end
	return n
end

-- Logic + config modules are plain Lune requires (they are pure Luau and need
-- only the `_G.task` shim installed above). Exposed from here so the ordering
-- guarantee lives in one place.
H.Logic = {
	DamageModel = require("../../src/server/Logic/DamageModel"),
	EconomyLedger = require("../../src/server/Logic/EconomyLedger"),
	HitDetectionCore = require("../../src/server/Logic/HitDetectionCore"),
	MatchStateMachine = require("../../src/server/Logic/MatchStateMachine"),
	PlayerHealth = require("../../src/server/Logic/PlayerHealth"),
}

H.Shared = {
	Constants = require("../../src/shared/Constants"),
	Enums = require("../../src/shared/Enums"),
	Weapons = require("../../src/shared/Config/Weapons"),
	Economy = require("../../src/shared/Config/Economy"),
	Combat = require("../../src/shared/Config/Combat"),
}

return H
