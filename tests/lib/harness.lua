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

--[[
    Resume every task that yielded. Roblox's `task.wait(n)` returns after n
    seconds; the harness clock only moves when a test moves it, so a test asks
    for one turn of the event loop explicitly. Tasks that yield again (the 5 s
    keepalive and AFK loops) are parked again for the next wake.

    Use it to observe periodic work — e.g. one wake after a client boot makes
    the controller's keepalive loop call Match:ReportActive exactly once.
]]
function H.wakeParked()
	local woken = parked
	parked = {}
	for _, item in woken do
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

function InstanceMT:FindFirstChildOfClass(className)
	for _, child in self._order do
		if child.ClassName == className then
			return child
		end
	end
	return nil
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
-- The Roblox `Enum` surface the trees actually touch. One shared table, so an
-- enum item the test fires into UserInputService compares equal to the one the
-- controller reads (A3a firing seam).
EnumStub = {
	RaycastFilterType = { Exclude = "Exclude" },
	UserInputType = { MouseButton1 = "MouseButton1", MouseButton2 = "MouseButton2" },
}

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
			-- `_root` is set on the client tree's nodes: a client module must see
			-- the CLIENT DataModel (its own ReplicatedStorage.Packages.Knit),
			-- not the server tree's.
			game = node._root or H.tree.root,
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
			Enum = EnumStub,
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
		local player = {
			UserId = userId,
			Name = name or ("P" .. userId),
			Character = nil,
			-- Roblox fires this when the engine loads a character; the stub must
			-- too, because the avatar mirror (PlayerStateService:_LinkAvatar)
			-- hangs off it.
			CharacterAdded = SyncSignal.new(),
		}
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

--[[
    The fake Workspace. Roblox always has one, and the server tree asks it for
    three things:
      * the SERVER CLOCK (`GetServerTimeNow`) — the domain every combat
        timestamp lives in (WORKFLOW "Clock domains");
      * WORLD GEOMETRY (`Raycast`) — an actual ray-vs-AABB test against the
        parts registered here, so "a wall blocks the shot" is provable
        headlessly instead of merely asserted;
      * `FindFirstChild` — CombatService excludes the Dummies / Spawns / FX
        FOLDERS from the geometry query (readiness notes §9), and Exclude on a
        foldered instance in Roblox drops its descendants with it, so the
        ignore set below walks descendants exactly as the engine does.
]]
local function newWorkspace()
	local workspace = newInstance("Workspace", "Workspace")
	workspace._parts = {}

	-- The server clock. CombatService records samples, gates fire rate and
	-- validates client fireTimes in this domain only.
	function workspace:GetServerTimeNow()
		return H.clock.t
	end

	local function makePart(name, position, size)
		local part = newInstance("Part", name)
		part.Anchored = true
		part.Position = { X = position[1], Y = position[2], Z = position[3] }
		part.Size = { X = size[1], Y = size[2], Z = size[3] }
		return part
	end

	-- H.addWall(name, {x,y,z}, {x,y,z}) — a solid block of world geometry.
	function workspace:AddWall(name, position, size)
		local part = makePart(name, position, size)
		part._wall = true
		addChild(self, part)
		table.insert(self._parts, part)
		return part
	end

	--[[
        A part inside a named world folder (Dummies / Spawns / FX). Same solid
        geometry as a wall, but parented so the folder-level exclusion can be
        proved: these must never eat a bullet meant for a player.
    ]]
	function workspace:AddWorldPart(name, folderName, position, size)
		local part = makePart(name, position, size)
		local folder = self:FindFirstChild(folderName)
		if folder == nil then
			folder = addChild(self, newInstance("Folder", folderName))
		end
		addChild(folder, part)
		table.insert(self._parts, part)
		return part
	end

	-- Removes the bare walls only: foldered parts (dummies/FX/spawns) belong to
	-- whoever put them there and survive a cover-test cleanup.
	function workspace:ClearWalls()
		for index = #self._parts, 1, -1 do
			local part = self._parts[index]
			if part._wall then
				table.remove(self._parts, index)
				if part.Parent ~= nil then
					local parent = part.Parent
					for i, child in parent._order do
						if child == part then
							table.remove(parent._order, i)
							break
						end
					end
					parent._children[part.Name] = nil
					part.Parent = nil
				end
			end
		end
	end

	-- Workspace:Raycast(origin, direction, params): the direction's
	-- magnitude is the ray length, exactly like Roblox. Honours
	-- FilterDescendantsInstances as an exclusion list, descendants included
	-- (that is how CombatService keeps player characters — and the Dummies /
	-- Spawns / FX folders — out of the geometry query).
	function workspace:Raycast(origin, direction, params)
		local ignored = {}
		local function ignore(instance)
			ignored[instance] = true
			if type(instance.GetDescendants) == "function" then
				for _, descendant in instance:GetDescendants() do
					ignored[descendant] = true
				end
			end
		end
		if params ~= nil then
			for _, instance in params.FilterDescendantsInstances or {} do
				ignore(instance)
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

-- ReplicatedStorage.Shared's module nodes — identical in both trees, so a
-- module loaded on the client resolves the same config as on the server.
-- `runConfigMode` decides which RUN the tree boots under:
--   "alpha"    the shipped overlay: src/shared/Config/AlphaRun.lua is executed
--              by the tree, exactly as it will be in the game.
--   "baseline" (default) the same AlphaRun switch turned OFF, so the 5v5 /
--              win-8 fixtures that pin the round mechanics keep testing a
--              baseline run; Alpha's own numbers are guarded by the alpha-mode
--              cases and by H.Shared.AlphaRun (the real file).
local function addSharedModules(shared)
	moduleNode(shared, "Constants", "src/shared/Constants.lua")
	moduleNode(shared, "Enums", "src/shared/Enums.lua")
	local config = addChild(shared, newInstance("Folder", "Config"))
	moduleNode(config, "Weapons", "src/shared/Config/Weapons.lua")
	moduleNode(config, "Economy", "src/shared/Config/Economy.lua")
	moduleNode(config, "Combat", "src/shared/Config/Combat.lua")
	moduleNode(config, "RigProfile", "src/shared/Config/RigProfile.lua")
	local alphaRun = moduleNode(config, "AlphaRun", "src/shared/Config/AlphaRun.lua")
	moduleNode(config, "RunConfig", "src/shared/Config/RunConfig.lua")
	if H.runConfigMode ~= "alpha" then
		alphaRun._value = { Enabled = false, Overrides = {} }
	end
	return config
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
	addSharedModules(shared)

	local serverScriptService = addChild(root, newInstance("ServerScriptService", "ServerScriptService"))
	local serverScript = moduleNode(serverScriptService, "Server", "src/server/init.server.lua", "Script")
	local logic = addChild(serverScript, newInstance("Folder", "Logic"))
	for _, name in
		{
			"AvatarLink",
			"DamageModel",
			"EconomyLedger",
			"HitDetectionCore",
			"MatchStateMachine",
			"PlayerHealth",
			"Signal",
		}
	do
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
--
-- options.preJoinPlayers = N seats N players in the fake Players list BEFORE
-- the server chunk runs, i.e. before any service exists to hear PlayerAdded.
-- Those players are therefore in Players:GetPlayers() when Knit's
-- task.spawn'ed KnitStart connects its handler — exactly what Studio Play's
-- local player is (Q1-4 join race). options.firstUserId defaults to 101.
function H.boot(options)
	options = options or {}
	ready = {}
	parked = {}
	lastError = nil
	cache = {}
	H.clock.t = 0
	H.runConfigMode = options.runConfig or "baseline"
	H.players = newPlayers()
	for index = 1, (options.preJoinPlayers or 0) do
		H.players:Add((options.firstUserId or 101) + index - 1)
	end
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

-- ------------------------------------------------------------ client boot
--[[
    The client half of the tree, booted the way Roblox boots it:
    StarterPlayerScripts.Client -> Knit.AddControllers(script.Controllers) ->
    Knit.Start().

    The point of this fake is the ONE thing Q2-1 got wrong: on the client the
    reflected service object carries the service's Client signals (and
    properties) DIRECTLY — KnitClient.BuildService() calls
    ClientComm:BuildObject() (packages/knit/src/KnitClient.lua:130-138,
    docs/services.md:210) — and there is NO `.Client` field on it. That is the
    server-side idiom. So a controller that indexes `service.Client` gets nil
    and throws inside KnitInit exactly as it does in Studio.

    Signals are the SERVER's own signal objects (the same table the server
    fires), so a server-side `:Fire(payload)` reaches the controller's
    connection: the client test observes the same objects the game ships.
]]
local function newClientKnit(serverServices, localPlayer, calls)
	local Knit = { _controllers = {}, _services = {}, _started = false, _initError = nil }

	function Knit.CreateController(definition)
		assert(type(definition) == "table", "Knit.CreateController expects a table")
		assert(type(definition.Name) == "string" and #definition.Name > 0, "Controller.Name must be a non-empty string")
		assert(not Knit._started, "Controllers cannot be created after Knit.Start()")
		Knit._controllers[definition.Name] = definition
		return definition
	end

	function Knit.AddControllers(parent)
		local added = {}
		for _, child in parent:GetChildren() do
			if child:IsA("ModuleScript") then
				table.insert(added, stubRequire(child))
			end
		end
		return added
	end

	-- KnitClient.GetService: the reflected service object, signals directly on it.
	function Knit.GetService(name)
		local cached = Knit._services[name]
		if cached ~= nil then
			return cached
		end
		local definition = serverServices[name]
		assert(definition ~= nil, `Could not find service "{name}"`)
		-- Build it BEFORE wiring methods, so Client methods that look a service
		-- up (Economy.NOT_BUY_PHASE -> Match) see a stable object.
		local object = {}
		Knit._services[name] = object
		for key, value in definition.Client do
			if key ~= "Server" then
				if type(value) == "table" and type(value.Connect) == "function" then
					-- A Client signal: the very object the server fires.
					object[key] = value
				elseif type(value) == "table" and type(value.Get) == "function" then
					-- A Client property: readonly reflection (Get + Observe).
					object[key] = {
						Get = function()
							return value:Get()
						end,
						Observe = function(_, fn)
							fn(value:Get())
							return function() end
						end,
					}
				elseif type(value) == "function" then
					-- A Client remote method: InvokeAsync(player, ...) on the
					-- server is what InvokeAsync(...) does from the client.
					object[key] = {
						InvokeAsync = function(_, ...)
							table.insert(calls, name .. ":" .. key)
							return value(definition.Client, localPlayer, ...)
						end,
					}
				end
			end
		end
		return object
	end

	function Knit.Start()
		assert(not Knit._started, "Knit already started")
		Knit._started = true
		for _, controller in Knit._controllers do
			if type(controller.KnitInit) == "function" then
				local ok, err = pcall(controller.KnitInit, controller)
				if not ok then
					Knit._initError = err
				end
			end
		end
		for _, controller in Knit._controllers do
			if type(controller.KnitStart) == "function" then
				spawnTask(function()
					controller:KnitStart()
				end)
			end
		end
		return {
			catch = function(self, handler)
				if Knit._initError ~= nil then
					handler(Knit._initError)
				end
				return self
			end,
			andThen = function(self, handler)
				if Knit._initError == nil then
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

-- Boot the server tree, then the client tree against it. Returns
-- { initError, eventBus, calls, tree } — initError is the error KnitInit threw
-- (nil on a healthy boot), calls the remote-method invocation log.
function H.bootClient(options)
	options = options or {}
	local serverOk, serverErr = H.boot(options.server)
	if not serverOk then
		error("server boot failed before the client could boot: " .. tostring(serverErr))
	end
	local localPlayer = H.players:GetPlayers()[1]
	assert(localPlayer ~= nil, "bootClient needs at least one player (options.server.preJoinPlayers)")
	-- Studio Play always has a LocalPlayer; the client controllers read theirs.
	H.players.LocalPlayer = localPlayer

	local calls = {}
	H.clientKnit = newClientKnit(H.knit._services, localPlayer, calls)

	local root = newInstance("DataModel", "DataModel")
	local replicatedStorage = addChild(root, newInstance("ReplicatedStorage", "ReplicatedStorage"))
	local packages = addChild(replicatedStorage, newInstance("Folder", "Packages"))
	local knitNode = moduleNode(packages, "Knit", nil)
	knitNode._value = H.clientKnit
	-- `game:GetService("Players")` must resolve in the CLIENT tree too, to the
	-- same fake Players the server tree uses: one game, one Players service,
	-- and it is where LocalPlayer lives.
	root._children.Players = H.players
	-- Client-only services the firing input reaches for (A3a): the mouse and
	-- the camera. Mirrors the real client tree — UserInputService.InputBegan,
	-- Workspace.CurrentCamera — and the clock stays the SERVER's, because the
	-- fireTime the combat path validates is in that domain, not the client's.
	local userInput = addChild(root, newInstance("UserInputService", "UserInputService"))
	userInput.InputBegan = SyncSignal.new()
	local clientWorkspace = addChild(root, newInstance("Workspace", "Workspace"))
	clientWorkspace.GetServerTimeNow = function()
		return H.workspace:GetServerTimeNow()
	end
	clientWorkspace.CurrentCamera = {
		CFrame = { Position = { X = 0, Y = 0, Z = 0 }, LookVector = { X = 0, Y = 0, Z = -1 } },
	}
	local shared = moduleNode(replicatedStorage, "Shared", "src/shared/init.lua")
	addSharedModules(shared)

	-- Mirrors default.project.json: StarterPlayer.StarterPlayerScripts.Client
	-- = src/client, i.e. the init.client.lua Script with Controllers/ and UI/.
	local starterPlayer = addChild(root, newInstance("StarterPlayer", "StarterPlayer"))
	local starterPlayerScripts = addChild(starterPlayer, newInstance("StarterPlayerScripts", "StarterPlayerScripts"))
	local client = moduleNode(starterPlayerScripts, "Client", "src/client/init.client.lua", "Script")
	local controllers = addChild(client, newInstance("Folder", "Controllers"))
	moduleNode(controllers, "Match", "src/client/Controllers/MatchController.lua")
	moduleNode(controllers, "Combat", "src/client/Controllers/CombatController.lua")
	local ui = addChild(client, newInstance("Folder", "UI"))
	local eventBus = moduleNode(ui, "EventBus", "src/client/UI/EventBus.lua")

	H.client = {
		root = root,
		script = client,
		knit = H.clientKnit,
		calls = calls,
	}
	-- The registered controller definitions, by Name (Knit._controllers).
	function H.client.controller(name)
		return H.clientKnit._controllers[name]
	end
	-- A real mouse click: UserInputService.InputBegan carrying MouseButton1,
	-- the same input object the engine delivers (A3a firing seam).
	function H.client.click()
		userInput.InputBegan:Fire({ UserInputType = EnumStub.UserInputType.MouseButton1 })
	end
	-- Point the local player's camera at a look vector from a position; the
	-- controller reads .Position/.LookVector exactly as it reads real Vector3s.
	function H.client.aim(x, y, z, lx, ly, lz)
		clientWorkspace.CurrentCamera.CFrame = {
			Position = { X = x, Y = y, Z = z },
			LookVector = { X = lx, Y = ly, Z = lz },
		}
	end
	-- Every module in the client tree resolves `game` to the CLIENT DataModel.
	for _, node in root:GetDescendants() do
		node._root = root
	end

	local chunk = luau.load(readSource(client._path), {
		debugName = client._path,
		environment = newEnv({
			game = root,
			Players = H.players,
			require = stubRequire,
			script = client,
			task = taskStub,
			os = H.osShape,
			Instance = { new = newInstance },
			Enum = EnumStub,
		}),
		injectGlobals = false,
	})
	local ok, err = pcall(chunk)
	H.client.bootOk = ok
	H.client.bootErr = err
	H.client.initError = H.clientKnit._initError
	H.client.eventBus = stubRequire(eventBus)
	-- Knit.Start() spawns KnitStart, which the harness only runs on flush — so a
	-- test that wants to observe the boot itself (e.g. subscribe to the
	-- EventBus before the snapshot lands) passes options.beforeFlush(client).
	if ok and options.beforeFlush then
		options.beforeFlush(H.client)
	end
	if ok then
		H.client.flushError = H.flush()
	end
	return H.client
end

-- --------------------------------------------------------------- helpers
-- Solid world geometry for cover tests: H.addWall("Wall", {x,y,z}, {sx,sy,sz}).
function H.addWall(name, position, size)
	return H.workspace:AddWall(name, position, size)
end

function H.clearWalls()
	H.workspace:ClearWalls()
end

--[[
    A part inside a named world folder (Dummies / Spawns / FX): solid geometry
    that must NEVER eat a bullet meant for a player (readiness notes §9). The
    folder is created on first use. Parts added this way survive H.clearWalls().
]]
function H.addWorldPart(name, folderName, position, size)
	return H.workspace:AddWorldPart(name, folderName, position, size)
end

-- The server clock the combat path uses (Workspace:GetServerTimeNow()).
function H.serverNow()
	return H.workspace:GetServerTimeNow()
end

--[[
    Attach a minimal character to a player. The server tree reads exactly two
    things off a character's transform:
        character:GetPivot().Position / .ToEulerAnglesYXZ()  (the recorder)
        character.Head.Position                             (origin sanity)
    and one thing off its Humanoid — the health/death mirror (PlayerStateService
    -> AvatarLink):
        Humanoid.Health / .MaxHealth / .BreakJointsOnDeath / .PlatformStand / .AutoRotate

    `y` is the ROOT PIVOT height — the TORSO CENTRE, ~3 studs above the feet for
    a stock R6 character (Constants/RigProfile "TorsoCentreAboveFeetStuds").
    Head sits 1.5 studs above the pivot, where a real R6 head part is: exactly
    the head offset said RigProfile.R6 uses.

    Firing CharacterAdded at the end mirrors the engine loading a character, so
    the avatar mirror is exercised on the real code path.
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

	local humanoid = newInstance("Humanoid", "Humanoid")
	humanoid.MaxHealth = H.Shared.Constants.MaxHealth
	humanoid.Health = H.Shared.Constants.MaxHealth
	humanoid.BreakJointsOnDeath = true -- the engine default; the service sets false
	humanoid.PlatformStand = false
	humanoid.AutoRotate = true
	addChild(character, humanoid)

	player.Character = character
	player.CharacterAdded:Fire(character)
	return character
end

-- The Humanoid of a player's current character (for the death/hp mirror tests).
function H.humanoid(playerId)
	local player = H.players:GetPlayerByUserId(playerId)
	assert(player ~= nil, ("H.humanoid: no player %d in the game"):format(playerId))
	if player.Character == nil then
		return nil
	end
	return player.Character:FindFirstChild("Humanoid")
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

--[[
    Per-client combat feedback spy (2026-09-20 fix: no hit-feedback broadcast).

    Knit's contract is that `Client.Signal:Fire(player, ...)` is delivered to
    THAT player's client ONLY — the player argument IS the delivery. So the
    spy records every delivery together with the player it was addressed to,
    and counts deliveries with no player at all: in Knit that is a broadcast
    to every client, which for hit/damage feedback is the defect being
    regression-tested (it leaked every player's hits to everyone).

    usage:
        local log = H.spyCombat()
        ... fire a shot ...
        H.signalsFor(log, 101)        -> { "HitConfirmed", "ShotResolved" }
        H.payloadFor(log, 106, "DamageTaken").hp
        H.recipients(log)             -> { 101, 106 }
        log.broadcast                 -> must be 0
]]
function H.spyCombat()
	local combat = H.service("Combat")
	local log = { entries = {}, broadcast = {} }

	local function record(signalName)
		return function(player, payload)
			local userId = nil
			if type(player) == "table" then
				userId = player.UserId
			end
			if userId == nil then
				table.insert(log.broadcast, signalName)
			end
			table.insert(log.entries, { signal = signalName, to = userId, payload = payload })
		end
	end

	combat.Client.HitConfirmed:Connect(record("HitConfirmed"))
	combat.Client.ShotResolved:Connect(record("ShotResolved"))
	combat.Client.DamageTaken:Connect(record("DamageTaken"))
	return log
end

-- Every signal name delivered to one player, sorted (order-independent).
function H.signalsFor(log, userId)
	local names = {}
	for _, entry in log.entries do
		if entry.to == userId then
			table.insert(names, entry.signal)
		end
	end
	table.sort(names)
	return names
end

-- The payload delivered to `userId` on `signal`, or nil when they got none.
function H.payloadFor(log, userId, signalName)
	for _, entry in log.entries do
		if entry.to == userId and entry.signal == signalName then
			return entry.payload
		end
	end
	return nil
end

-- Every player id that received ANY signal, sorted.
function H.recipients(log)
	local seen, out = {}, {}
	for _, entry in log.entries do
		if entry.to ~= nil and not seen[entry.to] then
			seen[entry.to] = true
			table.insert(out, entry.to)
		end
	end
	table.sort(out)
	return out
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
	AvatarLink = require("../../src/server/Logic/AvatarLink"),
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
	-- The hitbox rig (A3a): pure data, so the suite guards the SHIPPED profile
	-- (the one CombatService injects) instead of a copy of it.
	RigProfile = require("../../src/shared/Config/RigProfile"),
	-- The real Alpha run overlay + the (pure) resolver that binds it to the
	-- baseline. Both are plain Luau, so the suite can guard the shipped run
	-- numbers directly instead of only through a booted tree.
	AlphaRun = require("../../src/shared/Config/AlphaRun"),
	RunConfig = require("../../src/shared/Config/RunConfig"),
}

return H
