--!strict
--[[
    MatchController (Knit controller) — Phase 1 UI seam.
    Subscribes to every Match/Economy/Combat signal and re-emits onto
    Client/UI/EventBus.lua so the UI/UX designer binds one place
    (see README "UI event contract" for exact names + payloads).

    Also fetches the authoritative match snapshot on join (for HUD bootstrap)
    and sends a light keepalive that feeds the server's AFK kick timer (§4).

    No UI is built here — this is plumbing only.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Knit"))

local EventBus = require(script.Parent.Parent.UI.EventBus)

local MatchController = Knit.CreateController({
	Name = "Match",
})

-- Signal names surfaced to UI, per service (README event contract).
local MATCH_SIGNALS = {
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

local ECONOMY_SIGNALS = {
	"CreditsChanged",
}

function MatchController:KnitInit()
	local match = Knit.GetService("Match")
	local economy = Knit.GetService("Economy")
	local combat = Knit.GetService("Combat")

	for _, name in MATCH_SIGNALS do
		match.Client[name]:Connect(function(payload)
			EventBus.Publish(name, payload)
		end)
	end

	for _, name in ECONOMY_SIGNALS do
		economy.Client[name]:Connect(function(payload)
			EventBus.Publish(name, payload)
		end)
	end

	-- Combat hits are combat UI (hitmarker/kill feed) — Phase 2, but wire
	-- the seam now so no service changes are needed later.
	combat.Client.HitConfirmed:Connect(function(payload)
		EventBus.Publish("HitConfirmed", payload)
	end)

	self._connections = {}
end

function MatchController:KnitStart()
	-- Bootstrap HUD state (phase, round, scores, teams) for late joiners.
	task.spawn(function()
		local ok, snapshot = pcall(function()
			return Knit.GetService("Match").Client.FetchMatchState:InvokeAsync()
		end)
		if ok and snapshot then
			EventBus.Publish("MatchSnapshot", snapshot)
		end
	end)

	-- Keepalive every 5 s so a live player is never AFK-kicked (§4).
	task.spawn(function()
		while true do
			task.wait(5)
			pcall(function()
				Knit.GetService("Match").Client.ReportActive:InvokeAsync()
			end)
		end
	end)
end

return MatchController
