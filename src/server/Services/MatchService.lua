--!strict
--[[
    MatchService (Knit) — match & round flow (GDD §4) + objective win
    conditions seam (§7.2). Thin wrapper over Logic/MatchStateMachine.lua
    (pure FSM). Maps the SM's internal events onto Knit remote signals that
    the UI/UX designer binds to (see README "UI event contract").

    Phase 2 plug points (Gameplay Scripter):
        - BEACON service calls:
              Knit.GetService("Match"):ReportUplinkComplete()
              Knit.GetService("Match"):ReportBeaconDisabled()
          and sets the timeout resolver with planted-state awareness:
              Knit.GetService("Match"):SetTimeoutResolver(fn)
        - CombatService calls Knit.GetService("Match"):ReportPlayerEliminated(id)
        - warmup: LOBBY phase is ready for a 60 s warmup (Constants.WarmupDuration)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Knit = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Knit"))
local Shared = require(ReplicatedStorage:WaitForChild("Shared"))

local MatchStateMachine = require(script.Parent.Parent.Logic.MatchStateMachine)

local MatchService = Knit.CreateService({
	Name = "Match",
	Client = {
		-- UI-facing signals (README event contract). Each carries ONE table
		-- payload; server fires all clients via :Fire(payload).
		PhaseChanged = Knit.CreateSignal(),
		PlayerJoined = Knit.CreateSignal(),
		PlayerLeft = Knit.CreateSignal(),
		MatchStarted = Knit.CreateSignal(),
		BuyPhaseStarted = Knit.CreateSignal(),
		BuyPhaseEnded = Knit.CreateSignal(),
		RoundStarted = Knit.CreateSignal(),
		RoundEnded = Knit.CreateSignal(),
		ScoreUpdated = Knit.CreateSignal(),
		MatchEnded = Knit.CreateSignal(),
		PlayerEliminated = Knit.CreateSignal(),
		PlayerDemotedToSpectator = Knit.CreateSignal(),
		RematchVoteUpdated = Knit.CreateSignal(),
	},
})

local sm = MatchStateMachine.new({
	Constants = Shared.Constants,
	Enums = Shared.Enums,
	-- Roblox's `os` is not a clock object (no `now`); hand the FSM the
	-- function it actually calls. os.clock() is the server's monotonic
	-- second counter and is what every timer below uses.
	clock = { now = os.clock },
})

-- AFK kick bookkeeping (GDD §4: 60 s idle in buy phase / lobby -> spectator)
local lastActive = {} -- playerId -> os.clock()

-- Knit signal markers are placeholders until Knit.Start binds remotes; only
-- these named Client signals are wired to state-machine events.
local CLIENT_SIGNALS = {
	"PhaseChanged",
	"PlayerJoined",
	"PlayerLeft",
	"MatchStarted",
	"BuyPhaseStarted",
	"BuyPhaseEnded",
	"RoundStarted",
	"RoundEnded",
	"ScoreUpdated",
	"MatchEnded",
	"PlayerEliminated",
	"PlayerDemotedToSpectator",
	"RematchVoteUpdated",
}

function MatchService:KnitStart()
	-- Wire SM events -> Knit remote signals (single payload, fire all).
	for _, eventName in CLIENT_SIGNALS do
		local signal = self.Client[eventName]
		if type(signal) == "table" and type(signal.Fire) == "function" then
			sm:Connect(eventName, function(payload)
				signal:Fire(payload)
			end)
		end
	end

	-- Round settlement (§5): award win/loss credits, reset rentals + health.
	sm:Connect(Shared.Enums.Event.RoundEnded, function(data)
		self:_SettleRound(data)
	end)
	-- Match end: clear credits + health across the board (§5.3).
	sm:Connect(Shared.Enums.Event.MatchEnded, function()
		local economy = Knit.GetService("Economy")
		local playerState = Knit.GetService("PlayerState")
		economy:ResetAllForNewMatch()
		playerState:ResetAllForNewMatch()
	end)

	-- Player lifecycle
	Players.PlayerAdded:Connect(function(player)
		lastActive[player.UserId] = os.clock()
		local result = sm:JoinPlayer(player.UserId)
		-- Initialize economy + health for the player's role.
		Knit.GetService("Economy"):InitPlayer(player.UserId)
		if result.role ~= Shared.Enums.Role.Spectator and result.role ~= Shared.Enums.Role.Waitlist then
			Knit.GetService("PlayerState"):RegisterForRound(player.UserId, result.team)
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		sm:LeavePlayer(player.UserId)
		lastActive[player.UserId] = nil
		Knit.GetService("Economy"):CleanupPlayer(player.UserId)
		Knit.GetService("PlayerState"):CleanupPlayer(player.UserId)
	end)

	-- Timer tick drives buy/action/round-end transitions.
	RunService.Heartbeat:Connect(function()
		sm:Tick(os.clock())
	end)

	-- AFK kick (lobby / buy phase only, per §4).
	task.spawn(function()
		while true do
			task.wait(5)
			local phase = sm:GetPhase()
			if phase == Shared.Enums.Phase.Lobby or phase == Shared.Enums.Phase.BuyPhase then
				local now = os.clock()
				for _, player in Players:GetPlayers() do
					local last = lastActive[player.UserId]
					if last and (now - last) > Shared.Constants.AFKKickSeconds then
						sm:DemoteToSpectator(player.UserId)
					end
				end
			end
		end
	end)
end

-- Client-facing remote methods ---------------------------------------------

-- Late-joiner / HUD bootstrap: current authoritative match state.
function MatchService.Client:FetchMatchState(_player)
	return sm:GetStateSnapshot()
end

-- End-of-match rematch vote (§4).
function MatchService.Client:RequestRematchVote(player)
	if sm:VoteRematch(player.UserId) then
		lastActive[player.UserId] = os.clock()
		return true
	end
	return false
end

-- Cheap client keepalive that also resets the AFK timer.
function MatchService.Client:ReportActive(player)
	lastActive[player.UserId] = os.clock()
	return true
end

-- Server-facing API used by CombatService / Phase 2 BEACON ------------------

function MatchService:ReportPlayerEliminated(playerId)
	return sm:ReportPlayerEliminated(playerId)
end

function MatchService:ReportUplinkComplete()
	return sm:ReportUplinkComplete()
end

function MatchService:ReportBeaconDisabled()
	return sm:ReportBeaconDisabled()
end

function MatchService:SetTimeoutResolver(resolverFn)
	sm:SetTimeoutResolver(resolverFn)
end

function MatchService:IsBuyPhase()
	return sm:IsBuyPhase()
end

function MatchService:IsActionPhase()
	return sm:IsActionPhase()
end

function MatchService:GetPhase()
	return sm:GetPhase()
end

function MatchService:GetRound()
	return sm:GetRound()
end

function MatchService:GetScores()
	return sm:GetScores()
end

function MatchService:GetPlayerTeam(playerId)
	return sm:GetPlayerTeam(playerId)
end

function MatchService:GetPlayerRole(playerId)
	return sm:GetPlayerRole(playerId)
end

-- Internal ------------------------------------------------------------------

function MatchService:_SettleRound(data)
	local economy = Knit.GetService("Economy")
	local playerState = Knit.GetService("PlayerState")
	for _, player in Players:GetPlayers() do
		local team = sm:GetPlayerTeam(player.UserId)
		if team ~= nil then
			-- §5.1: round win +3000 / round loss +1500 (flat; no scaling in MVP)
			economy:SettleRoundForPlayer(player.UserId, team, data.winnerTeam)
			-- §5.3 rental reset + §7.3 heal for the NEXT round.
			economy:ResetRentals(player.UserId)
			playerState:RegisterForRound(player.UserId, team)
		end
	end
end

return MatchService
