--!strict
-- Roblox provides the global `task` library; standalone Luau does not.
-- Rebinding through _G keeps strict analysis green while letting headless
-- tests inject a scheduler (see tools/phase1_check.lua).
local task = _G.task

--[[
    MatchStateMachine — round/match flow state machine (GDD §4 Match Spec,
    §7.2 win conditions, §9 walkthrough).

    Phases (Enums.Phase): LOBBY -> BUY_PHASE -> ACTION -> ROUND_END -> ...
        LOBBY      waiting to fill (16-slot server, 10 players start,
                   60 s warmup is a Phase 2 presentation concern)
        BUY_PHASE  20 s spawn-locked shopping (§4), timer-driven
        ACTION     round live, <= 105 s (§4), timer-driven timeout
        ROUND_END  brief interstitial (RoundEndPause) then next round
        MATCH_END  first-to-8 (§4) fires MatchEnded; machine returns to
                   LOBBY for rematch voting / re-fill

    Rules implemented exactly:
        - 5v5 Raiders (attack) vs Wardens (defend)
        - first to 8 round wins, max 15 rounds, no overtime (§4)
        - 105 s round timer, 20 s buy phase (§4)
        - side swap after round 7 (rounds 1-7 normal, 8+ swapped) (§4)
        - subscription: mid-match join fills understaffed team slots,
          else spectator (6 slots), else waitlist; team may play short (§4)
        - AFK kick API (60 s idle -> demoted to spectator) (§4)
        - win condition ORDER (GDD §7.2) is honored via four explicit
          report methods; Phase 2's BEACON logic calls ReportUplinkComplete /
          ReportBeaconDisabled; CombatService calls ReportPlayerEliminated.
        - timeout rule without objective data (Phase 1 default): no beacon
          planted -> Wardens win (TimeExpiredNotPlanted). Set a custom
          timeout resolver via SetTimeoutResolver once BEACON exists (§7.2.4).

    Purity: no Roblox dependencies, zero internal requires; config injected
    ({Constants, Enums, clock}). Events are a small inline listener registry
    (same API shape as Server Logic/Signal.lua) so this module is fully
    headless-testable; MatchService maps these onto Knit remote signals.
]]

local MatchStateMachine = {}
MatchStateMachine.__index = MatchStateMachine

-- config = { Constants = Constants, Enums = Enums, clock = { now = fn } }
function MatchStateMachine.new(config)
    local self = setmetatable({}, MatchStateMachine)
    self.Constants = config.Constants
    self.Enums = config.Enums
    -- `clock` is an injected { now = fn } time source. It is NEVER the `os`
    -- library itself: Roblox's os exposes clock/date/difftime/time and has no
    -- `now`, so passing `os` (or falling back to it) crashed the FSM at
    -- construction and took the whole server boot with it (B1).
    self.clock = config.clock or { now = os.clock }

    self.phase = self.Enums.Phase.Lobby
    self.round = 0
    self.phaseStartedAt = self.clock.now()

    self.scores = { Raiders = 0, Wardens = 0 }
    self.roster = {} -- playerId -> { role = Enums.Role.*, team = "Raiders"|"Wardens"|nil }
    -- INVARIANT: aliveCounts[team] == (roster members on team) - (team members
    -- who died, left or were demoted this round). Every path that changes one
    -- side must change the other: elimination, leave, mid-round substitution,
    -- AFK demotion. A desync here is unrecoverable mid-round (B4).
    self.aliveCounts = { Raiders = 0, Wardens = 0 }
    self.eliminated = {} -- playerId -> true for this round (dead / gone)
    self.roundHistory = {} -- { { round, winner, reason, raiders, wardens } }
    self.timeoutResolver = nil
    self.rematchVotes = {} -- playerId -> true
    self.requireRematchVotes = true -- after a match ends, LOBBY auto-start waits for votes
    self.listeners = {} -- eventName -> { fn }
    return self
end

-- Listener registry ---------------------------------------------------------

function MatchStateMachine:Connect(eventName, listener)
    assert(type(listener) == "function", "MatchStateMachine listener must be a function")
    local list = self.listeners[eventName]
    if list == nil then
        list = {}
        self.listeners[eventName] = list
    end
    table.insert(list, listener)
    local closed = false
    return function()
        if closed then
            return
        end
        closed = true
        for i = #list, 1, -1 do
            if list[i] == listener then
                table.remove(list, i)
                break
            end
        end
    end
end

function MatchStateMachine:_fire(eventName, payload)
    local list = self.listeners[eventName]
    if list == nil then
        return
    end
    for _, listener in table.clone(list) do
        task.spawn(function()
            pcall(listener, payload) -- one bad listener never breaks the match
        end)
    end
end

-- Getters -------------------------------------------------------------------

function MatchStateMachine:GetPhase()
    return self.phase
end

function MatchStateMachine:GetRound()
    return self.round
end

function MatchStateMachine:GetScores()
    return table.clone(self.scores)
end

function MatchStateMachine:GetRoundHistory()
    -- Deep copy: a caller (or a serialized snapshot on its way to a client)
    -- must not be able to mutate the authoritative history entries.
    local out = {}
    for index, entry in self.roundHistory do
        out[index] = table.clone(entry)
    end
    return out
end

function MatchStateMachine:GetPlayerRole(playerId)
    local entry = self.roster[playerId]
    return if entry then entry.role else nil
end

function MatchStateMachine:GetPlayerTeam(playerId)
    local entry = self.roster[playerId]
    return if entry then entry.team else nil
end

function MatchStateMachine:GetTeamRoster(team)
    local out = {}
    for id, entry in self.roster do
        if entry.team == team then
            table.insert(out, id)
        end
    end
    -- Sorted: snapshots are payloads (HUD/end screen), so a roster that
    -- reorders itself between two identical reads is a bug for consumers.
    table.sort(out)
    return out
end

function MatchStateMachine:GetPlayerCount()
    local n = 0
    for _ in self.roster do
        n += 1
    end
    return n
end

-- Team counts (team players only, not spectators)
function MatchStateMachine:GetTeamSize(team)
    local n = 0
    for _, entry in self.roster do
        if entry.team == team then
            n += 1
        end
    end
    return n
end

function MatchStateMachine:GetSpectatorCount()
    local n = 0
    for _, entry in self.roster do
        if entry.role == self.Enums.Role.Spectator then
            n += 1
        end
    end
    return n
end

function MatchStateMachine:GetSide(team, roundNumber)
    -- §4: side swap after round 7. Rounds 1-7: Raiders attack, Wardens
    -- defend. Rounds 8+: swapped.
    local r = roundNumber or self.round
    local normal = r <= self.Constants.SideSwapAfterRound
    if team == self.Constants.Teams.Raiders then
        return if normal then self.Enums.Side.Attack else self.Enums.Side.Defend
    else
        return if normal then self.Enums.Side.Defend else self.Enums.Side.Attack
    end
end

function MatchStateMachine:IsBuyPhase()
    return self.phase == self.Enums.Phase.BuyPhase
end

function MatchStateMachine:IsActionPhase()
    return self.phase == self.Enums.Phase.Action
end

function MatchStateMachine:GetStateSnapshot()
    return {
        phase = self.phase,
        round = self.round,
        scores = table.clone(self.scores),
        -- Deep-copied (see GetRoundHistory): a client must never be able to
        -- reach authoritative history through the snapshot it was sent.
        roundHistory = self:GetRoundHistory(),
        teams = {
            Raiders = self:GetTeamRoster(self.Constants.Teams.Raiders),
            Wardens = self:GetTeamRoster(self.Constants.Teams.Wardens),
        },
        -- Live counts for the round (HUD "4 v 3"); they are aliveCounts, not
        -- roster sizes: eliminated players stay rostered until they leave.
        aliveCounts = table.clone(self.aliveCounts),
        spectators = self:GetSpectatorCount(),
        rematchVotes = self:GetRematchVoteCount(),
        rematchVotesRequired = self:GetRematchVoteRequired(),
    }
end

-- Player lifecycle -----------------------------------------------------------

-- Slot assignment: 5v5 first, then spectators, then waitlist (§4).
-- Shared by lobby fill and mid-match substitution (team plays short until
-- a waiting player substitutes in).
function MatchStateMachine:_AssignSlot()
    if self:GetTeamSize(self.Constants.Teams.Raiders) < self.Constants.TeamSize then
        return self.Enums.Role.Raider, self.Constants.Teams.Raiders
    elseif self:GetTeamSize(self.Constants.Teams.Wardens) < self.Constants.TeamSize then
        return self.Enums.Role.Warden, self.Constants.Teams.Wardens
    elseif self:GetSpectatorCount() < self.Constants.SpectatorSlots then
        return self.Enums.Role.Spectator, nil
    else
        return self.Enums.Role.Waitlist, nil
    end
end

-- Returns { role = Role, team = Team|nil }
function MatchStateMachine:JoinPlayer(playerId)
    local existing = self.roster[playerId]
    if existing ~= nil then
        return { role = existing.role, team = existing.team }
    end

    local role, team = self:_AssignSlot()

    self.roster[playerId] = { role = role, team = team }
    -- Mid-round substitution (§4: a team may play short until someone fills
    -- the slot): the seat is a LIVE one, so aliveCounts has to grow with the
    -- roster or the round resolves on a stale count. A player who already
    -- died this round keeps their seat's death (no respawns, §7.3).
    if self.phase == self.Enums.Phase.Action and team ~= nil and not self.eliminated[playerId] then
        self.aliveCounts[team] = (self.aliveCounts[team] or 0) + 1
    end
    self:_fire(self.Enums.Event.PlayerJoined, { playerId = playerId, role = role, team = team })

    if self.phase == self.Enums.Phase.Lobby then
        self:_TryStartMatch()
    end
    return { role = role, team = team }
end

function MatchStateMachine:LeavePlayer(playerId)
    local entry = self.roster[playerId]
    if entry == nil then
        return
    end
    self.roster[playerId] = nil
    self.rematchVotes[playerId] = nil

    -- Rosters keep eliminated players, so roster size alone cannot tell us
    -- whether a team is out. A player who leaves while alive has to be
    -- uncounted, otherwise the last living player can disconnect mid-round
    -- and the round never resolves (B4).
    local wasAlive = self.phase == self.Enums.Phase.Action and entry.team ~= nil and not self.eliminated[playerId]
    if wasAlive then
        self.eliminated[playerId] = true
        self.aliveCounts[entry.team] = math.max(0, self.aliveCounts[entry.team] - 1)
    end

    self:_fire(self.Enums.Event.PlayerLeft, { playerId = playerId, role = entry.role, team = entry.team })

    -- A team reduced to zero living players mid-match cannot continue;
    -- the other team wins the round.
    if wasAlive and self:IsActionPhase() and self.aliveCounts[entry.team] <= 0 then
        local winner = self:_OtherTeam(entry.team)
        self:_ResolveRound(winner, self.Enums.RoundEndReason.TeamEliminated)
    end
end

function MatchStateMachine:DemoteToSpectator(playerId)
    -- §4 AFK kick: idle in buy phase / lobby -> demoted to spectator.
    local entry = self.roster[playerId]
    if entry == nil or entry.role == self.Enums.Role.Spectator then
        return false
    end
    local wasTeam = entry.team
    entry.role = self.Enums.Role.Spectator
    entry.team = nil
    -- Same invariant as LeavePlayer: taking a live player off a team takes
    -- them out of that team's alive count.
    local wasAlive = wasTeam ~= nil and self:IsActionPhase() and not self.eliminated[playerId]
    if wasAlive then
        self.eliminated[playerId] = true
        self.aliveCounts[wasTeam] = math.max(0, self.aliveCounts[wasTeam] - 1)
    end
    self:_fire(self.Enums.Event.PlayerDemotedToSpectator, { playerId = playerId, previousTeam = wasTeam })
    if wasAlive and self:IsActionPhase() and self.aliveCounts[wasTeam] <= 0 then
        self:_ResolveRound(self:_OtherTeam(wasTeam), self.Enums.RoundEndReason.TeamEliminated)
    end
    return true
end

-- Match / round control ------------------------------------------------------

function MatchStateMachine:StartMatch()
    if self.phase ~= self.Enums.Phase.Lobby then
        return false
    end
    self.scores = { Raiders = 0, Wardens = 0 }
    self.roundHistory = {}
    self.rematchVotes = {}
    self.round = 0
    self:_StartBuyPhase(1)
    self:_fire(self.Enums.Event.MatchStarted, {})
    return true
end

-- Called by tick loop or service. On match end, machine returns to LOBBY.
function MatchStateMachine:RestartMatch()
    self.phase = self.Enums.Phase.Lobby
    self.phaseStartedAt = self.clock.now()
end

function MatchStateMachine:VoteRematch(playerId)
    if self.phase ~= self.Enums.Phase.Lobby then
        return false
    end
    if self.roster[playerId] == nil then
        return false
    end
    self.rematchVotes[playerId] = true
    self:_fire(self.Enums.Event.RematchVoteUpdated, {
        votes = self:GetRematchVoteCount(),
        required = self:GetRematchVoteRequired(),
    })
    self:_TryStartMatch()
    return true
end

function MatchStateMachine:GetRematchVoteCount()
    local n = 0
    for _ in self.rematchVotes do
        n += 1
    end
    return n
end

function MatchStateMachine:GetRematchVoteRequired()
    local present = 0
    for _ in self.roster do
        present += 1
    end
    return math.min(self.Constants.PlayersToStart, math.max(2, present))
end

function MatchStateMachine:_TryStartMatch()
    if self.phase ~= self.Enums.Phase.Lobby then
        return false
    end
    local teamsFull = self:GetTeamSize(self.Constants.Teams.Raiders) >= self.Constants.TeamSize
        and self:GetTeamSize(self.Constants.Teams.Wardens) >= self.Constants.TeamSize
    if not teamsFull then
        return false
    end
    if self.requireRematchVotes and self:GetRematchVoteCount() < self:GetRematchVoteRequired() then
        -- First lobby (no prior match): rematchVotes is 0 but that must not
        -- block the very first match of a server session.
        if #self.roundHistory > 0 then
            return false
        end
    end
    return self:StartMatch()
end

function MatchStateMachine:_StartBuyPhase(roundNumber)
    self.round = roundNumber
    self.phase = self.Enums.Phase.BuyPhase
    self.phaseStartedAt = self.clock.now()
    self:_fire(self.Enums.Event.BuyPhaseStarted, {
        round = self.round,
        raidersSide = self:GetSide(self.Constants.Teams.Raiders, self.round),
        wardensSide = self:GetSide(self.Constants.Teams.Wardens, self.round),
    })
end

function MatchStateMachine:_StartActionPhase()
    self.phase = self.Enums.Phase.Action
    self.phaseStartedAt = self.clock.now()
    -- Fresh alive counts for the round (§7.3 no respawns) and a fresh
    -- elimination ledger to match them.
    self.eliminated = {}
    -- Zero BOTH counts before counting: a team with nobody left when the
    -- round starts (everyone left in the buy phase) must not inherit the
    -- previous round's count — a stale positive count is a live round nobody
    -- can end, and the HUD would show ghosts (B4).
    self.aliveCounts = { Raiders = 0, Wardens = 0 }
    for _, entry in self.roster do
        if entry.team ~= nil then
            self.aliveCounts[entry.team] = self:GetTeamSize(entry.team)
        end
    end
    self:_fire(self.Enums.Event.BuyPhaseEnded, { round = self.round })
    self:_fire(self.Enums.Event.RoundStarted, {
        round = self.round,
        raiders = self.scores.Raiders,
        wardens = self.scores.Wardens,
        raidersSide = self:GetSide(self.Constants.Teams.Raiders, self.round),
        wardensSide = self:GetSide(self.Constants.Teams.Wardens, self.round),
        startTime = self.phaseStartedAt,
    })
end

-- Win-condition reports (§7.2, checked in order; CombatService / BEACON call
-- these — they DO NOT touch scores or health themselves).

-- Called when a player's health hits 0 (CombatService). Double-elimination
-- reports for the same player are ignored (one player dies at most once per
-- round); the round only resolves when a team's count actually reaches 0.
function MatchStateMachine:ReportPlayerEliminated(playerId)
    if self.phase ~= self.Enums.Phase.Action then
        return false
    end
    local team = self:GetPlayerTeam(playerId)
    if team == nil then
        return false
    end
    if self.eliminated[playerId] then
        return false -- duplicate report (retry, double lethal frame, forged)
    end
    self.eliminated[playerId] = true
    self.aliveCounts[team] = math.max(0, self.aliveCounts[team] - 1)
    local opponent = self:_OtherTeam(team)
    self:_fire(self.Enums.Event.PlayerEliminated, {
        playerId = playerId,
        team = team,
        teamAlive = self.aliveCounts[team],
        opponentAlive = self.aliveCounts[opponent],
    })
    if self.aliveCounts[team] <= 0 then
        -- §7.2.1 all players of a team eliminated -> other team wins instantly
        self:_ResolveRound(opponent, self.Enums.RoundEndReason.TeamEliminated)
        return true
    end
    return false
end

-- §7.2.2 uplink completes (beacon planted + 45 s) -> Raiders win
function MatchStateMachine:ReportUplinkComplete()
    if self.phase ~= self.Enums.Phase.Action then
        return false
    end
    self:_ResolveRound(self.Constants.Teams.Raiders, self.Enums.RoundEndReason.UplinkComplete)
    return true
end

-- §7.2.3 beacon disabled (7 s) -> Wardens win
function MatchStateMachine:ReportBeaconDisabled()
    if self.phase ~= self.Enums.Phase.Action then
        return false
    end
    self:_ResolveRound(self.Constants.Teams.Wardens, self.Enums.RoundEndReason.BeaconDisabled)
    return true
end

-- §7.2.4 timeout: Phase 2 BEACON logic replaces the default resolver.
-- Default (no objective data): no beacon planted -> Wardens win.
function MatchStateMachine:SetTimeoutResolver(resolverFn)
    self.timeoutResolver = resolverFn
end

-- Tick: buy-phase and action-phase timers plus round-end interstitial.
-- Services call this from RunService.Heartbeat; tests drive synthetic clocks.
function MatchStateMachine:Tick(now)
    now = now or self.clock.now()
    if self.phase == self.Enums.Phase.BuyPhase then
        if now - self.phaseStartedAt >= self.Constants.BuyPhaseDuration then
            self:_StartActionPhase()
        end
    elseif self.phase == self.Enums.Phase.Action then
        if now - self.phaseStartedAt >= self.Constants.RoundDuration then
            self:_ResolveRoundTimeout()
        end
    elseif self.phase == self.Enums.Phase.RoundEnd then
        if now - self.phaseStartedAt >= self.Constants.RoundEndPause then
            self:_BeginNextRound()
        end
    end
end

function MatchStateMachine:_ResolveRoundTimeout()
    -- §7.2.4 evaluated
    local winner = self.Constants.Teams.Wardens
    local reason = self.Enums.RoundEndReason.TimeExpiredNotPlanted
    if self.timeoutResolver then
        local result = pcall(self.timeoutResolver, self)
        if result then
            if type(result) == "table" and result.winner ~= nil then
                winner = result.winner
                reason = result.reason or reason
            end
        end
    end
    self:_ResolveRound(winner, reason)
end

function MatchStateMachine:_ResolveRound(winnerTeam, reason)
    if self.phase ~= self.Enums.Phase.Action then
        return false
    end
    self.scores[winnerTeam] += 1
    -- The history entry carries the score AS OF the end of that round: it is
    -- what the end-of-match screen and any score audit read back (B2).
    table.insert(self.roundHistory, {
        round = self.round,
        winner = winnerTeam,
        reason = reason,
        raiders = self.scores.Raiders,
        wardens = self.scores.Wardens,
    })
    local isMatchWin = self.scores[winnerTeam] >= self.Constants.WinScore
    self.phase = self.Enums.Phase.RoundEnd
    self.phaseStartedAt = self.clock.now()
    self:_fire(self.Enums.Event.RoundEnded, {
        round = self.round,
        winnerTeam = winnerTeam,
        reason = reason,
        raiders = self.scores.Raiders,
        wardens = self.scores.Wardens,
        isMatchWin = isMatchWin,
    })
    self:_fire(self.Enums.Event.ScoreUpdated, {
        raiders = self.scores.Raiders,
        wardens = self.scores.Wardens,
    })
    if isMatchWin then
        -- Payload contract: gdd/alpha-ui-spec.md lists the MatchEnded fields
        -- as {winnerTeam, raiders, wardens, roundsPlayed, roundHistory} and
        -- puts `isMatchWin` on RoundEnded (fired just above, same frame), so
        -- it is deliberately NOT duplicated here.
        -- History is DEEP-copied (GetRoundHistory): the end screen receives
        -- this payload and must not be handed authoritative entries (B2).
        self:_fire(self.Enums.Event.MatchEnded, {
            winnerTeam = winnerTeam,
            raiders = self.scores.Raiders,
            wardens = self.scores.Wardens,
            roundsPlayed = #self.roundHistory,
            roundHistory = self:GetRoundHistory(),
        })
        -- Match over: back to lobby for rematch vote / re-fill (§4).
        self.phase = self.Enums.Phase.Lobby
        self.phaseStartedAt = self.clock.now()
    end
    return true
end

function MatchStateMachine:_BeginNextRound()
    if self.phase ~= self.Enums.Phase.RoundEnd then
        return false
    end
    self:_StartBuyPhase(self.round + 1)
    return true
end

function MatchStateMachine:_OtherTeam(team)
    return if team == self.Constants.Teams.Raiders then self.Constants.Teams.Wardens else self.Constants.Teams.Raiders
end

return MatchStateMachine
