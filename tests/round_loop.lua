--[[
    BEACON PROTOCOL — Phase 1 executable checks (Lune).

        lune run tests/round_loop.lua          (from the repo root)

    Runs the REAL server code headlessly (see tests/lib/harness.lua) through:
        §1  B1 — server boot (init.server.lua -> Knit.AddServices -> Knit.Start)
        §2  the full cycle: lobby -> buy -> action -> round end -> settlement
        §3  B2 — round history + GetStateSnapshot contents
        §4  B3 — lag-compensation rewind window retention
        §5  B4 — a player joining / leaving mid-round
    Every section asserts the CORRECT behaviour, so each one is a regression
    test for the bug it names.
]]

local H = require("./lib/harness")
local Constants = H.Shared.Constants
local Enums = H.Shared.Enums

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

local function eq(actual, expected, message)
	if actual ~= expected then
		error(
			("%s — expected %s, got %s"):format(message or "value mismatch", tostring(expected), tostring(actual)),
			2
		)
	end
end

local function deepEq(actual, expected, message)
	local function same(a, b)
		if type(a) ~= type(b) then
			return false
		end
		if type(a) == "table" then
			for k, v in a do
				if not same(v, b[k]) then
					return false
				end
			end
			for k in b do
				if a[k] == nil then
					return false
				end
			end
			return true
		end
		return a == b
	end
	check(
		same(actual, expected),
		("%s — expected %s, got %s"):format(message or "table mismatch", tostring(expected), tostring(actual))
	)
end

-- ---------------------------------------------------------------- fixtures

-- Boot the server, fill a lobby (10 players -> both teams full -> match
-- auto-starts) and run the buy phase out, leaving the match in ACTION round 1.
local function freshAction()
	local ok, err = H.boot()
	assert(ok, "server boot failed: " .. tostring(err))
	local players = H.joinPlayers(101, 10)
	H.advance(Constants.BuyPhaseDuration)
	assert(H.service("Match"):IsActionPhase(), "expected ACTION after the buy phase")
	return {
		players = players,
		raiders = { 101, 102, 103, 104, 105 },
		wardens = { 106, 107, 108, 109, 110 },
	}
end

local function killAll(ids)
	for _, id in ids do
		H.kill(id)
	end
end

local function lastHistory(history)
	return history[#history]
end

-- End the current round by eliminating a whole team, then roll the FSM into
-- the next buy phase (RoundEndPause) so the following round can be played.
-- Advancing the buy phase first is what makes this repeatable: an elimination
-- only counts while the round is live (ACTION), and the FSM sits in BUY_PHASE
-- between rounds.
local function finishRoundAndAdvance(losers)
	H.advance(Constants.BuyPhaseDuration)
	killAll(losers)
	H.advance(Constants.RoundEndPause)
end

-- Play `count` full rounds, always ending them by eliminating `losers`.
local function playRounds(losers, count)
	for _ = 1, count do
		finishRoundAndAdvance(losers)
	end
end

-- ==========================================================================
section("B1 — server boot (src/server/init.server.lua)")
-- ==========================================================================

test("the Roblox-shaped `os` library has no `now` (root cause of B1)", function()
	H.boot()
	-- Roblox's os exposes clock/date/difftime/time only. MatchService used to
	-- inject `clock = os` into MatchStateMachine, which calls clock.now().
	eq(type(H.osShape.clock), "function", "os.clock")
	eq(H.osShape.now, nil, "os.now must not exist")
	eq(H.osShape.time, os.time, "os.time")
	eq(H.osShape.date, os.date, "os.date")
	eq(H.osShape.difftime, os.difftime, "os.difftime")
end)

test("no src file treats Roblox's `os` library as a clock object", function()
	-- Regression guard for B1: whatever the harness does, nothing in src/
	-- may pass `os` where a { now = fn } clock is expected, or call os.now.
	local sources = {
		"src/server/init.server.lua",
		"src/server/Logic/MatchStateMachine.lua",
		"src/server/Services/MatchService.lua",
		"src/server/Services/CombatService.lua",
		"src/server/Services/EconomyService.lua",
		"src/server/Services/PlayerStateService.lua",
	}
	for _, path in sources do
		local src = H.readSource(path)
		check(src:find("os%.now") == nil, path .. " calls os.now (Roblox's os has no `now`)")
		check(src:find("clock%s*=%s*os%f[%W]") == nil, path .. " passes `clock = os` (no `now` on Roblox's os)")
	end
end)

test("the FSM's clock fallback is a { now } function, not the `os` library", function()
	-- B1 root cause: the FSM did `self.clock = config.clock or os` and
	-- MatchService passed `clock = os`. Roblox's `os` has no `now`, so
	-- MatchStateMachine.new crashed on `self.clock.now()` and took the whole
	-- server boot with it. The default must therefore be a { now } table.
	local sm = H.Logic.MatchStateMachine.new({ Constants = Constants, Enums = Enums })
	eq(type(sm.clock), "table", "fallback clock is a table, not `os`")
	eq(type(sm.clock.now), "function", "fallback clock exposes now()")
	eq(type(sm.clock.now()), "number", "now() returns a number")
	eq(sm.phase, Enums.Phase.Lobby, "FSM constructs without a clock config")
end)

test("init.server.lua boots: Knit.AddServices(script.Services) + Knit.Start()", function()
	local ok, err = H.boot()
	check(ok, "server tree failed to boot: " .. tostring(err))
	local names = {}
	for name in H.knit._services do
		table.insert(names, name)
	end
	table.sort(names)
	deepEq(names, { "Combat", "Economy", "Match", "PlayerState" }, "registered services")
end)

test("every Knit.GetService(name) lookup matches a service Name", function()
	local sources = {
		"src/server/init.server.lua",
		"src/server/Services/CombatService.lua",
		"src/server/Services/EconomyService.lua",
		"src/server/Services/MatchService.lua",
		"src/server/Services/PlayerStateService.lua",
	}
	local declared = {}
	local requested = {}
	for _, path in sources do
		local src = H.readSource(path)
		for name in src:gmatch('CreateService%s*%(%s*{%s*Name%s*=%s*"([%w_]+)"') do
			declared[name] = path
		end
		for name in src:gmatch('Knit%.GetService%s*%(%s*"([%w_]+)"%s*%)') do
			requested[name] = path
		end
	end
	eq(H.count(declared), 4, "declared services")
	for name, path in requested do
		check(
			declared[name] ~= nil,
			("%s calls Knit.GetService(%q) but no service declares that Name"):format(path, name)
		)
	end
end)

-- ==========================================================================
section("full cycle — lobby -> buy -> action -> round end -> settlement")
-- ==========================================================================

test("10 players fill the lobby and the match auto-starts in BUY_PHASE", function()
	freshAction()
	local match = H.service("Match")
	local snapshot = H.snapshot()
	eq(snapshot.phase, Enums.Phase.Action, "phase")
	eq(snapshot.round, 1, "round")
	eq(#snapshot.teams.Raiders, 5, "raiders")
	eq(#snapshot.teams.Wardens, 5, "wardens")
	eq(snapshot.spectators, 0, "spectators")
	eq(match:GetRound(), 1, "MatchService:GetRound")
end)

test("buy gate: purchases work in BUY_PHASE and are refused in ACTION", function()
	H.boot()
	local players = H.joinPlayers(101, 10)
	local economy = H.service("Economy")
	local buyer = players[1]

	local broke = economy.Client:RequestPurchase(buyer, { type = "WEAPON", id = "CQB2" })
	eq(broke.ok, false, "ok")
	eq(broke.reason, "INSUFFICIENT_CREDITS", "round 1 starts with 0 credits")

	H.advance(Constants.BuyPhaseDuration)
	local late = economy.Client:RequestPurchase(buyer, { type = "WEAPON", id = "CQB2" })
	eq(late.ok, false, "ok")
	eq(late.reason, "NOT_BUY_PHASE", "spawn-locked shopping")
end)

test("round 1: elimination -> round end -> credits settled, scores and history", function()
	local ctx = freshAction()
	local match = H.service("Match")
	local economy = H.service("Economy")

	killAll(ctx.wardens)
	local snapshot = H.snapshot()
	eq(snapshot.phase, Enums.Phase.RoundEnd, "phase after the last Warden dies")
	eq(snapshot.scores.Raiders, 1, "raider score")
	eq(snapshot.scores.Wardens, 0, "warden score")
	eq(#snapshot.roundHistory, 1, "round history length")
	eq(snapshot.roundHistory[1].round, 1, "history round")
	eq(snapshot.roundHistory[1].winner, Enums.Teams and "Raiders" or "Raiders", "history winner")
	eq(snapshot.roundHistory[1].reason, Enums.RoundEndReason.TeamEliminated, "history reason")

	-- Settlement is wired asynchronously (RoundEnded -> MatchService:_SettleRound).
	H.flush()
	local balances = economy.Client.Credits:Get()
	eq(balances[101], 3000, "round win award (§5.1 +3000)")
	eq(balances[106], 1500, "round loss award (§5.1 +1500)")
	eq(match:GetPlayerTeam(101), "Raiders", "roster intact")
end)

test("buy -> action -> settlement loop: purchases, rental reset, credit persistence", function()
	local ctx = freshAction()
	local economy = H.service("Economy")
	local playerState = H.service("PlayerState")
	local raider = ctx.players[1]

	killAll(ctx.wardens)
	H.advance(Constants.RoundEndPause)
	eq(H.snapshot().phase, Enums.Phase.BuyPhase, "round 2 buy phase")
	eq(H.snapshot().round, 2, "round 2")

	local rifle = economy.Client:RequestPurchase(raider, { type = "WEAPON", id = "ARC5" })
	eq(rifle.ok, true, "ARC5 in the win round")
	eq(rifle.balance, 300, "3000 - 2700")
	eq(rifle.loadout.primary, "ARC5", "primary rented")

	local kit = economy.Client:RequestPurchase(raider, { type = "ARMOR", id = "FullKit" })
	eq(kit.ok, false, "Full Kit when broke")
	eq(kit.reason, "INSUFFICIENT_CREDITS", "reason")

	-- Kill attribution / damage application still runs the server authority chain.
	local damage = playerState:ApplyDamage(106, 40, 101, "ARC5")
	eq(damage.lethal, false, "40 damage is not lethal at 100 HP")
	eq(damage.state.hp, 60, "hp after 40 damage")

	H.advance(Constants.BuyPhaseDuration) -- shopping is over: round 2 goes live
	eq(H.snapshot().phase, Enums.Phase.Action, "round 2 in action")
	killAll(ctx.wardens)
	H.advance(Constants.RoundEndPause)
	local balance = economy:GetBalance(101)
	eq(balance, 3300, "credits persist across rounds (300 + 3000)")
	local loadout = economy:GetLoadout(101)
	eq(loadout.primary, nil, "purchased primary resets every round (rental model §5.3)")
	eq(loadout.sidearm, "Viper9", "free sidearm re-issued")
	eq(loadout.melee, "Talon", "free melee re-issued")
	eq(loadout.armor, Enums.Armor.None, "armor rental reset")

	local vest = economy.Client:RequestPurchase(raider, { type = "ARMOR", id = "LightVest" })
	eq(vest.ok, true, "Light Vest affordable in round 3")
	eq(economy:GetArmor(101), Enums.Armor.LightVest, "armor written to the health registry")
end)

test("buy phase and action phase run on the GDD timers", function()
	freshAction()
	local match = H.service("Match")
	killAll({ 106, 107, 108, 109, 110 })
	eq(match:GetPhase(), Enums.Phase.RoundEnd, "round ended")
	H.advance(Constants.RoundEndPause - 0.5)
	eq(match:GetPhase(), Enums.Phase.RoundEnd, "still in the interstitial")
	H.advance(0.5)
	eq(match:GetPhase(), Enums.Phase.BuyPhase, "next buy phase after RoundEndPause")
	H.advance(Constants.BuyPhaseDuration)
	eq(match:GetPhase(), Enums.Phase.Action, "action after the buy phase")
	H.advance(Constants.RoundDuration)
	eq(match:GetPhase(), Enums.Phase.RoundEnd, "105 s timeout resolves the round")
	eq(
		lastHistory(H.snapshot().roundHistory).reason,
		Enums.RoundEndReason.TimeExpiredNotPlanted,
		"no beacon planted -> Wardens"
	)
end)

test("first to 8 wins ends the match and returns the FSM to the lobby", function()
	local ctx = freshAction()
	local match = H.service("Match")
	local economy = H.service("Economy")
	local matchEnd = nil
	local roundEnd = nil
	H.service("Match").Client.MatchEnded:Connect(function(payload)
		matchEnd = payload
	end)
	H.service("Match").Client.RoundEnded:Connect(function(payload)
		roundEnd = payload
	end)

	for _ = 1, Constants.WinScore do
		finishRoundAndAdvance(ctx.wardens)
	end

	check(matchEnd ~= nil, "MatchEnded event payload")
	eq(matchEnd.winnerTeam, "Raiders", "winner team")
	eq(matchEnd.raiders, 8, "raider score")
	eq(matchEnd.wardens, 0, "warden score")
	eq(matchEnd.roundsPlayed, 8, "rounds played")
	eq(#matchEnd.roundHistory, 8, "match end payload carries the round history")
	eq(matchEnd.roundHistory[8].raiders, 8, "the last history entry carries the final score")
	-- The payload is the UI contract in gdd/alpha-ui-spec.md §payloads:
	-- MatchEnded = {winnerTeam, raiders, wardens, roundsPlayed, roundHistory}
	-- and `isMatchWin` belongs to RoundEnded, which fires in the SAME frame
	-- (GDD §art 8: round-end FX must read it there and stand down). Asserting
	-- it on MatchEnded was the harness being wrong, not the machine.
	check(roundEnd ~= nil, "RoundEnded payload")
	eq(roundEnd.isMatchWin, true, "RoundEnded.isMatchWin on the deciding round")
	eq(roundEnd.winnerTeam, "Raiders", "RoundEnded.winnerTeam")
	eq(roundEnd.round, 8, "RoundEnded.round")
	-- The payload must not hand the end screen authoritative history entries.
	matchEnd.roundHistory[1].winner = "HACKED"
	eq(H.snapshot().roundHistory[1].winner, "Raiders", "MatchEnded history is a deep copy")

	eq(match:GetPhase(), Enums.Phase.Lobby, "back to the lobby for rematch voting")
	eq(H.count(economy.Client.Credits:Get()), 0, "credits reset at match end (§5.3)")
	eq(H.service("PlayerState"):GetHealth(101), nil, "health registry reset at match end")

	local snapshot = H.snapshot()
	eq(snapshot.rematchVotes, 0, "no votes yet")
	eq(snapshot.rematchVotesRequired, 10, "all 10 present players must vote")
	eq(#snapshot.roundHistory, 8, "history survives into the lobby for the end screen")
end)

test("rematch vote restarts the match with cleared scores and history", function()
	local ctx = freshAction()
	playRounds(ctx.wardens, Constants.WinScore)
	local match = H.service("Match")
	for _, player in ctx.players do
		match.Client:RequestRematchVote(player)
	end
	local snapshot = H.snapshot()
	eq(snapshot.phase, Enums.Phase.BuyPhase, "rematch started")
	eq(snapshot.round, 1, "round counter reset")
	eq(snapshot.scores.Raiders, 0, "scores reset")
	eq(snapshot.scores.Wardens, 0, "scores reset")
	eq(#snapshot.roundHistory, 0, "round history reset for the new match")
end)

-- ==========================================================================
section("B2 — round history + GetStateSnapshot")
-- ==========================================================================

test("sides swap after round 7 (§4)", function()
	local sm = H.Logic.MatchStateMachine.new({
		Constants = Constants,
		Enums = Enums,
		clock = {
			now = function()
				return 0
			end,
		},
	})
	eq(sm:GetSide("Raiders", 7), Enums.Side.Attack, "round 7 raiders attack")
	eq(sm:GetSide("Raiders", 8), Enums.Side.Defend, "round 8 raiders defend")
	eq(sm:GetSide("Wardens", 8), Enums.Side.Attack, "round 8 wardens attack")
end)

test("round history entries are complete and consistent with the score", function()
	local ctx = freshAction()
	playRounds(ctx.wardens, 3)
	local snapshot = H.snapshot()
	eq(#snapshot.roundHistory, 3, "three rounds recorded")
	eq(snapshot.scores.Raiders, 3, "score matches the history")
	local running = { Raiders = 0, Wardens = 0 }
	for index, entry in snapshot.roundHistory do
		eq(entry.round, index, "round number")
		eq(entry.winner, "Raiders", "winner")
		eq(entry.reason, Enums.RoundEndReason.TeamEliminated, "reason")
		running[entry.winner] += 1
		eq(entry.raiders, running.Raiders, "history entry carries the raider score after the round")
		eq(entry.wardens, running.Wardens, "history entry carries the warden score after the round")
	end
	eq(running.Raiders, snapshot.scores.Raiders, "history and score agree")
end)

test("GetStateSnapshot reports the live roster, alive counts and vote requirement", function()
	local ctx = freshAction()
	killAll({ 106, 107 })
	local snapshot = H.snapshot()

	-- Roster: every connected player stays listed on their team whether or
	-- not they are still alive — that is exactly why aliveCounts exists as a
	-- separate field (eliminated players are rostered until they leave).
	eq(H.count(snapshot.teams.Raiders), 5, "raider roster")
	eq(H.count(snapshot.teams.Wardens), 5, "warden roster")
	deepEq(H.sortedIds(snapshot.teams.Wardens), ctx.wardens, "warden roster ids")
	eq(snapshot.spectators, 0, "spectators")

	-- The live counts, which are what the round resolves on and what the HUD
	-- renders ("4 v 3").
	eq(snapshot.aliveCounts.Raiders, 5, "no raider has died")
	eq(snapshot.aliveCounts.Wardens, 3, "two wardens are down")

	-- Phase / round / rematch fields for the HUD and the end screen.
	eq(snapshot.phase, Enums.Phase.Action, "phase")
	eq(snapshot.round, 1, "round")
	eq(snapshot.rematchVotes, 0, "no votes during a live match")
	eq(snapshot.rematchVotesRequired, 10, "the vote requirement counts the present players")

	-- A snapshot is a value copy: a reader cannot move the authoritative count.
	snapshot.aliveCounts.Raiders = 0
	snapshot.teams.Wardens[1] = 999
	eq(H.snapshot().aliveCounts.Raiders, 5, "alive counts are copied")
	eq(H.snapshot().teams.Wardens[1], 106, "roster is copied")
end)

test("snapshot is a value copy: a reader cannot corrupt authoritative state", function()
	local ctx = freshAction()
	killAll(ctx.wardens)
	H.advance(Constants.RoundEndPause)

	local snapshot = H.snapshot()
	snapshot.roundHistory[1].winner = "HACKED"
	snapshot.roundHistory[1].reason = "HACKED"
	snapshot.scores.Raiders = 99

	local again = H.snapshot()
	eq(again.roundHistory[1].winner, "Raiders", "history winner is copied")
	eq(again.roundHistory[1].reason, Enums.RoundEndReason.TeamEliminated, "history reason is copied")
	eq(again.scores.Raiders, 1, "scores are copied")
	eq(H.service("Match"):GetScores().Raiders, 1, "authoritative score untouched")
end)

test("GetRoundHistory (Logic) hands out copies, not internal entries", function()
	local sm = H.Logic.MatchStateMachine.new({
		Constants = Constants,
		Enums = Enums,
		clock = {
			now = function()
				return 0
			end,
		},
	})
	for i = 1, 10 do
		sm:JoinPlayer(i)
	end
	sm:StartMatch()
	sm:_StartActionPhase()
	for _, id in { 1, 2, 3, 4, 5 } do
		sm:ReportPlayerEliminated(id)
	end
	local history = sm:GetRoundHistory()
	eq(#history, 1, "one round recorded")
	history[1].winner = "HACKED"
	history[1].reason = "HACKED"
	eq(sm:GetRoundHistory()[1].winner, "Wardens", "internal history winner unchanged")
	eq(sm:GetRoundHistory()[1].reason, Enums.RoundEndReason.TeamEliminated, "internal history reason unchanged")
end)

-- ==========================================================================
section("B3 — lag-compensation rewind window (<= 200 ms)")
-- ==========================================================================

local function newCore(windowSeconds)
	return H.Logic.HitDetectionCore.new({
		WindowSeconds = windowSeconds or Constants.LagCompensationWindowMs / 1000,
		SampleInterval = Constants.LagCompensationSampleInterval,
		Enums = Enums,
	})
end

-- Record at 60 Hz, the rate CombatService actually records at (it hooks
-- Heartbeat, not the nominal 0.1 s SampleInterval).
local function recordAt60Hz(core, playerId, duration)
	local steps = math.floor(duration * 60)
	for i = 0, steps do
		local t = i / 60
		core:Record(playerId, t, i * 0.1, 0, 0, 0)
	end
	return steps / 60
end

test("history stays a proper sequence and keeps a full 200 ms of samples at 60 Hz", function()
	local core = newCore()
	local newest = recordAt60Hz(core, 1, 1.0)
	local history = core.history[1]
	check(history ~= nil, "history recorded")
	for i = 2, #history do
		check(
			history[i].t > history[i - 1].t,
			("samples must be ordered oldest->newest and hole-free (index %d)"):format(i)
		)
	end
	local cutoff = newest - core.WindowSeconds
	local retained = 0
	for _, sample in history do
		if sample.t >= cutoff - 1e-9 then
			retained += 1
		end
	end
	check(retained >= 12, ("only %d samples retained inside the 200 ms window (need >= 12 at 60 Hz)"):format(retained))
	check(history[1].t <= cutoff + 1 / 60 + 1e-9, "oldest retained sample sits inside the window")
end)

test("rewinding 200 ms back returns the sample from that instant, not a stale one", function()
	local core = newCore()
	local newest = recordAt60Hz(core, 1, 1.0)
	local fireTime = newest - 0.2
	local snap = core:GetSnapshotAt(1, fireTime)
	check(snap ~= nil, "no snapshot inside the rewind window")
	check(
		math.abs(snap.t - fireTime) <= 1 / 60 + 1e-9,
		("rewind landed %d ms off the fire time"):format(math.round(math.abs(snap.t - fireTime) * 1000))
	)
end)

test("samples older than the window are pruned", function()
	local core = newCore()
	core:Record(1, 0, 0, 0, 0, 0)
	recordAt60Hz(core, 1, 1.2)
	for _, sample in core.history[1] do
		check(
			sample.t >= 1.2 - core.WindowSeconds - 1e-9,
			("stale sample t=%s was retained"):format(tostring(sample.t))
		)
	end
	eq(core:GetSnapshotAt(1, 1.2 - 0.5), nil, "outside the window -> no guess")
end)

test("lag compensation: a 150 ms-old fire time hits the position the victim held then", function()
	local core = newCore()
	-- Victim runs along +X at 10 studs/s; record the last second at 60 Hz.
	for i = 0, 60 do
		core:Record(2, i / 60, i / 6, 0, 0, 0)
	end
	local newest = 1.0
	local fireTime = newest - 0.15
	local rewound = core:GetSnapshotAt(2, fireTime)
	check(rewound ~= nil, "no rewound snapshot")
	local shooter = { x = 0, y = 1.15, z = -20 }
	local hitPoint = { x = rewound.x, y = rewound.y + 1.15, z = rewound.z } -- torso height
	local dir = { x = hitPoint.x - shooter.x, y = hitPoint.y - shooter.y, z = hitPoint.z - shooter.z }

	local hit =
		core:ResolveRay(shooter.x, shooter.y, shooter.z, dir.x, dir.y, dir.z, 300, core:BuildCandidates(2, rewound))
	check(hit ~= nil, "shot at the rewound position missed the victim")
	eq(hit.region, Enums.HitRegion.Torso, "hit region")

	-- Sanity: the same ray against the CURRENT position misses — that is the
	-- shot the server would wrongly resolve without lag compensation.
	local current = core:GetSnapshotAt(2, newest)
	check(current ~= nil, "current snapshot")
	local miss =
		core:ResolveRay(shooter.x, shooter.y, shooter.z, dir.x, dir.y, dir.z, 300, core:BuildCandidates(2, current))
	eq(miss, nil, "no-rewind ray should miss the moved victim")
end)

test("a window above the GDD hard cap of 200 ms is rejected", function()
	local ok, err = pcall(newCore, 0.25)
	eq(ok, false, "0.25 s window must not construct")
	check(tostring(err):find("200 ms") ~= nil, "error names the cap: " .. tostring(err))
end)

-- ==========================================================================
section("P2a — world raycast: cover stops bullets")
-- ==========================================================================

-- A 30-stud shooting lane along -Z: shooter (raider 101, the free Viper-9
-- sidearm) at the origin, victim (warden 106) down the lane. Both stand on
-- the same ground, so torso centres are 4.15 studs up (pivot 3.0 + the
-- torso region's offsetY) and heads are 4.5 (WORKFLOW "Hitbox vertical
-- frame"). One Heartbeat at the current instant records both positions.
local TORSO_Y = 4.15
local function lane(rangeStuds)
	local ctx = freshAction()
	H.setCharacter(101, 0, 3, 0)
	H.setCharacter(106, 0, 3, -rangeStuds)
	H.advance(0)
	return ctx
end

-- Fire level down -Z through the victim's TORSO band. Aiming at the torso
-- centre matters: the pivot is the LIMBS sphere centre, so a ray aimed at
-- the pivot hits limbs, not the torso.
local function fireAtTorso(shooterId, victimId)
	return H.fire(shooterId, "Viper9", { x = 0, y = TORSO_Y, z = 0 }, { x = 0, y = 0, z = -1 })
end

test("a wall in the way turns the shot into a MISS_GEOMETRY with zero damage", function()
	lane(30)
	H.addWall("DockContainer", { 0, 3, -15 }, { 20, 12, 2 })
	local hpBefore = H.service("PlayerState"):GetHealth(106)

	local result = fireAtTorso(101, 106)

	eq(result.ok, true, "the shot itself is legal and resolves (it is a miss, not a refusal)")
	eq(result.hit, nil, "the wall stopped it")
	eq(result.reason, "MISS_GEOMETRY", "explicit, loggable reason")
	eq(result.blockedBy.name, "DockContainer", "the blocking geometry is named")
	eq(result.blockedBy.distance, 14, "block distance along the ray")
	eq(H.service("PlayerState"):GetHealth(106), hpBefore, "zero damage through cover")
end)

test("the same ray with the cover removed hits (the wall is what stopped it)", function()
	lane(30)
	local hpBefore = H.service("PlayerState"):GetHealth(106)

	-- Control: identical origin/direction, no geometry at all.
	local open = fireAtTorso(101, 106)
	eq(open.reason, nil, "an unobstructed shot is not reported as a miss")
	check(open.hit ~= nil, "control shot must hit")
	eq(open.hit.region, Enums.HitRegion.Torso, "the ray runs through the torso band")
	check(open.hit.distance > 28 and open.hit.distance < 29, "torso surface is ~28.9 studs out")

	-- Damage is exactly the config's answer for that range: the whole chain
	-- (config studs -> DamageModel -> PlayerHealth) is pinned to one number.
	-- `hit.distance` is rounded to 0.1 for the HUD while health is kept to 2
	-- decimals, so compare within one rounding step of the falloff slope.
	local expected = H.Shared.Weapons.DamageAtRange("Viper9", open.hit.distance)
	eq(open.damage, math.round(expected * 10) / 10, "damage matches the weapon config at range")
	local hpAfterOpen = H.service("PlayerState"):GetHealth(106)
	check(
		math.abs((hpBefore - hpAfterOpen) - expected) < 0.05,
		("health lost %.4f but the config says %.4f at %s studs"):format(
			hpBefore - hpAfterOpen,
			expected,
			open.hit.distance
		)
	)

	-- Now the same shot with a container in the way.
	H.addWall("DockContainer", { 0, 3, -15 }, { 20, 12, 2 })
	H.advance(0.3) -- clear the Viper-9 fire-rate gate (240 RPM -> 0.25 s)
	local blocked = fireAtTorso(101, 106)
	eq(blocked.reason, "MISS_GEOMETRY", "the wall stops the identical shot")
	eq(blocked.hit, nil, "no hit through cover")
	eq(H.service("PlayerState"):GetHealth(106), hpAfterOpen, "no damage from the blocked shot")
end)

test("only cover NEARER than the victim blocks the shot", function()
	lane(30)

	-- Beyond the victim (z = -40): the shot reaches the victim first.
	H.addWall("FarPipe", { 0, 4, -40 }, { 10, 10, 2 })
	local past = fireAtTorso(101, 106)
	eq(past.reason, nil, "geometry beyond the victim must not block")
	check(past.hit ~= nil, "the victim is still hittable through the far geometry")

	-- Nearer than the victim's torso surface (28.85 studs): it stops the shot.
	-- The gantry's near face is 28 studs out, so the block distance is smaller.
	H.clearWalls()
	H.addWall("Gantry", { 0, 4, -28.5 }, { 10, 10, 1 })
	H.advance(0.3)
	local blocked = fireAtTorso(101, 106)
	eq(blocked.reason, "MISS_GEOMETRY", "cover nearer than the victim blocks")
	eq(blocked.hit, nil, "no hit")
end)

test("HitDetectionCore takes the world query as an injected seam (Logic stays DataModel-free)", function()
	-- Fix #1's shape: the geometry query is a PARAMETER, so cover is provable
	-- headlessly and nothing in Logic/ references Workspace.
	local core = newCore()
	core:Record(9, 1.0, 0, 3.0, -30, 0)
	local snap = core:GetSnapshotAt(9, 1.0)
	check(snap ~= nil, "snapshot")
	local candidates = core:BuildCandidates(9, snap)

	-- (a) No world installed at all: the module still resolves hits.
	local open = core:ResolveRay(0, TORSO_Y, 0, 0, 0, -1, 300, candidates, nil)
	check(open ~= nil, "with no world query the shot reaches the target")
	eq(open.region, Enums.HitRegion.Torso, "torso")

	-- (b) A stub wall 15 studs out — a plain function, not Roblox geometry.
	local wall, block = core:ResolveRay(
		0,
		TORSO_Y,
		0,
		0,
		0,
		-1,
		300,
		candidates,
		function(_, _, _, _, _, _, maxDistance)
			eq(maxDistance, 300, "the provider is handed the hitscan range")
			return { distance = 15, name = "FakeContainer" }
		end
	)
	eq(wall, nil, "the stub wall stops the bullet")
	eq(block.distance, 15, "block distance")
	eq(block.name, "FakeContainer", "the block carries a loggable name")

	-- (c) The same wall beyond the target does not block.
	local behind = core:ResolveRay(0, TORSO_Y, 0, 0, 0, -1, 300, candidates, function()
		return { distance = 40, name = "FarWall" }
	end)
	check(behind ~= nil, "geometry beyond the target does not block the shot")
end)

test("weapon config is in studs and the rename changed no damage number", function()
	local Weapons = H.Shared.Weapons
	-- GDD §6.1 band numbers, unit of record = studs (WORKFLOW.md).
	eq(Weapons.Viper9.falloffStartStuds, 18, "Viper-9 full-damage band")
	eq(Weapons.Viper9.falloffEndStuds, 46, "Viper-9 min-damage band")
	eq(Weapons.CQB2.falloffStartStuds, 12, "CQB-2 full-damage band")
	eq(Weapons.CQB2.falloffEndStuds, 30, "CQB-2 min-damage band")
	eq(Weapons.ARC5.falloffStartStuds, 25, "ARC-5 full-damage band")
	eq(Weapons.ARC5.falloffEndStuds, 60, "ARC-5 min-damage band")

	eq(Weapons.DamageAtRange("Viper9", 18), 34, "Viper-9 body damage at full range")
	eq(Weapons.DamageAtRange("Viper9", 32), 30, "Viper-9 half-way through falloff")
	eq(Weapons.DamageAtRange("Viper9", 46), 26, "Viper-9 body damage at min range")
	eq(Weapons.DamageAtRange("CQB2", 12), 24, "CQB-2 body damage at full range")
	eq(Weapons.DamageAtRange("CQB2", 30), 16, "CQB-2 body damage at min range")
	eq(Weapons.DamageAtRange("ARC5", 25), 30, "ARC-5 body damage at full range")
	eq(Weapons.DamageAtRange("ARC5", 60), 22, "ARC-5 body damage at min range")
	eq(Weapons.DamageAtRange("Longshot", 57), 62, "Longshot is flat 62 across the whole map")

	-- A field name must never lie about its unit again.
	local src = H.readSource("src/shared/Config/Weapons.lua")
	for _, bad in { "falloffStartM", "falloffEndM", "effectiveRangeM" } do
		check(src:find(bad) == nil, "Weapons.lua still names " .. bad .. " (the unit of record is studs)")
	end
end)

-- ==========================================================================
section("B4 — players joining / leaving mid-round")
-- ==========================================================================

test("duplicate elimination reports for one player count once", function()
	local ctx = freshAction()
	local match = H.service("Match")
	for _ = 1, 5 do
		match:ReportPlayerEliminated(ctx.raiders[1])
	end
	H.flush()
	eq(match:GetPhase(), Enums.Phase.Action, "round still live: 4 raiders are alive")
	local snapshot = H.snapshot()
	eq(snapshot.aliveCounts.Raiders, 4, "alive raiders")
	eq(snapshot.aliveCounts.Wardens, 5, "alive wardens")
end)

test("a player leaving mid-round is uncounted: the team can still be eliminated", function()
	local ctx = freshAction()
	local match = H.service("Match")
	H.players:Remove(ctx.players[1]) -- raider 101 leaves during ACTION
	H.flush()
	eq(H.snapshot().aliveCounts.Raiders, 4, "leaving player stops being alive")

	killAll({ 102, 103, 104, 105 })
	eq(match:GetPhase(), Enums.Phase.RoundEnd, "the last living raider's death ends the round")
	eq(H.snapshot().scores.Wardens, 1, "wardens take the round")
	eq(lastHistory(H.snapshot().roundHistory).reason, Enums.RoundEndReason.TeamEliminated, "elimination, not a timeout")
end)

test("the last living player leaving ends the round for the other team", function()
	local ctx = freshAction()
	local match = H.service("Match")
	killAll({ 102, 103, 104, 105 })
	eq(match:GetPhase(), Enums.Phase.Action, "one raider left")
	H.players:Remove(ctx.players[1]) -- the survivor disconnects
	H.flush()
	eq(match:GetPhase(), Enums.Phase.RoundEnd, "round resolved")
	eq(H.snapshot().scores.Wardens, 1, "wardens win")
end)

test("a mid-round joiner fills the open slot and counts as alive", function()
	local ctx = freshAction()
	local match = H.service("Match")
	H.players:Remove(ctx.players[5]) -- raider 105 leaves; the slot opens
	H.flush()
	eq(H.snapshot().aliveCounts.Raiders, 4, "alive after the leave")

	local latecomer = H.players:Add(111)
	H.flush()
	eq(match:GetPlayerTeam(111), "Raiders", "substituted into the understaffed team")
	eq(H.snapshot().aliveCounts.Raiders, 5, "joiner counts as alive")

	killAll({ 101, 102, 103, 104, 111 })
	eq(match:GetPhase(), Enums.Phase.RoundEnd, "all five living raiders are gone")
	eq(H.snapshot().scores.Wardens, 1, "wardens win the round")
end)

test("a mid-round joiner with no free slot spectates and does not join the alive count", function()
	local ctx = freshAction()
	H.players:Add(112)
	H.flush()
	eq(H.service("Match"):GetPlayerRole(112), Enums.Role.Spectator, "spectator seat")
	eq(H.snapshot().aliveCounts.Wardens, 5, "alive count untouched")
	eq(#H.snapshot().teams.Wardens, 5, "roster untouched")
	check(ctx.wardens ~= nil, "ctx")
end)

test("leaving mid-round leaves no stale roster, credit or health state", function()
	local ctx = freshAction()
	local match = H.service("Match")
	local economy = H.service("Economy")
	local playerState = H.service("PlayerState")
	local leaver = ctx.players[1]

	H.players:Remove(leaver)
	H.flush()

	eq(match:GetPlayerTeam(101), nil, "roster entry removed")
	eq(match:GetPlayerRole(101), nil, "role removed")
	local balances = economy.Client.Credits:Get()
	eq(balances[101], nil, "no ghost credit entry for the departed player")
	eq(H.count(balances), 9, "nine players left in the ledger")
	eq(playerState:GetHealth(101), nil, "health entry removed")
	eq(H.count(H.snapshot().teams.Raiders), 4, "snapshot roster updated")
end)

test("a round-ending leave still settles the players who stayed", function()
	local ctx = freshAction()
	local economy = H.service("Economy")
	killAll({ 102, 103, 104, 105 })
	H.players:Remove(ctx.players[1]) -- the last living raider leaves mid-round
	H.flush() -- settlement runs after the leave

	local balances = economy.Client.Credits:Get()
	eq(balances[101], nil, "departed player is not paid by the settlement")
	for _, id in { 106, 107, 108, 109, 110 } do
		eq(balances[id], 3000, ("warden %d paid the round win"):format(id))
	end
	eq(H.count(balances), 9, "ledger holds exactly the nine connected players")
end)

test("a leave during the buy phase is reflected when the round starts", function()
	H.boot()
	local players = H.joinPlayers(101, 10)
	H.players:Remove(players[1])
	H.flush()
	eq(H.snapshot().teams.Raiders[1] == nil, false, "roster readable")
	eq(#H.snapshot().teams.Raiders, 4, "four raiders remain")
	H.advance(Constants.BuyPhaseDuration)
	eq(H.snapshot().phase, Enums.Phase.Action, "round starts 4v5 (a team may play short §4)")
	eq(H.snapshot().aliveCounts.Raiders, 4, "alive count matches the roster")
	eq(H.snapshot().aliveCounts.Wardens, 5, "alive count matches the roster")
end)

test("a team emptied during the buy phase does not inherit its last alive count", function()
	local ctx = freshAction()
	-- Play round 1 out so aliveCounts holds a real, non-zero raider count.
	killAll(ctx.wardens)
	H.advance(Constants.RoundEndPause)
	eq(H.snapshot().phase, Enums.Phase.BuyPhase, "round 2 buy phase")
	eq(H.snapshot().aliveCounts.Raiders, 5, "the raiders who won round 1 are all alive")

	-- Every raider leaves before the round goes live.
	for index = 1, 5 do
		H.players:Remove(ctx.players[index])
	end
	H.flush()
	H.advance(Constants.BuyPhaseDuration)

	local snapshot = H.snapshot()
	eq(snapshot.phase, Enums.Phase.Action, "round 2 is live")
	eq(H.count(snapshot.teams.Raiders), 0, "no raiders are rostered")
	-- Regression: the count used to be left at 5 (the previous round's value,
	-- assigned only for teams that still had a roster entry), so the round
	-- could never resolve — no living raider existed to eliminate.
	eq(snapshot.aliveCounts.Raiders, 0, "an empty team has no living players")
	eq(snapshot.aliveCounts.Wardens, 5, "the wardens who stayed are alive")

	H.advance(Constants.RoundDuration)
	eq(H.snapshot().phase, Enums.Phase.RoundEnd, "the empty-team round still resolves")
	eq(lastHistory(H.snapshot().roundHistory).reason, Enums.RoundEndReason.TimeExpiredNotPlanted, "on the round timer")
end)

-- ==========================================================================
print(("\n%d passed, %d failed"):format(passed, #failed))
if #failed > 0 then
	for _, failure in failed do
		print(("  FAILED  %s\n            %s"):format(failure.name, failure.err))
	end
	error("phase 1 checks failed", 0)
end
