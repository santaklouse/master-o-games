local H = require("./lib/harness")
local Constants = H.Shared.Constants

local ok, err = H.boot()
print("boot", ok, err)
local players = H.joinPlayers(101, 10)
H.advance(Constants.BuyPhaseDuration)
local match = H.service("Match")
print("phase after buy", match:GetPhase())
print("removing listeners", #H.players.PlayerRemoving._listeners)
print("added listeners", #H.players.PlayerAdded._listeners)

-- kill 4 raiders the way killAll does
for _, id in { 102, 103, 104, 105 } do
    H.service("PlayerState"):ApplyDamage(id, 1000, nil, "TestRig")
    local resolved = match:ReportPlayerEliminated(id)
    print("kill", id, "resolved?", resolved, "phase", match:GetPhase())
end
print("aliveCounts n/a")
print("team101", match:GetPlayerTeam(101))

H.players:Remove(players[1])
print("removed; phase", match:GetPhase())
local snap = H.snapshot()
print("snap phase", snap.phase, "scores", snap.scores.Raiders, snap.scores.Wardens, "history", #snap.roundHistory)
