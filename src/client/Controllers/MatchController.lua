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
	-- CLIENT idiom: on the client the reflected service object carries the
	-- Client signals/properties DIRECTLY (KnitClient.BuildService ->
	-- ClientComm:BuildObject; packages/knit/docs/services.md:210,
	-- packages/knit/test/client/KnitClientTest.client.lua:8-17). `.Client` is
	-- the SERVER-side idiom (docs/services.md:199) and is nil here — indexing it
	-- threw inside KnitInit, the boot promise swallowed it via
	-- init.client.lua's :catch(warn), KnitStart never ran, and with it went the
	-- FetchMatchState snapshot and the 5 s ReportActive keepalive (Q2-1).
	local match = Knit.GetService("Match")
	local economy = Knit.GetService("Economy")
	local combat = Knit.GetService("Combat")

	for _, name in MATCH_SIGNALS do
		match[name]:Connect(function(payload)
			EventBus.Publish(name, payload)
		end)
	end

	for _, name in ECONOMY_SIGNALS do
		economy[name]:Connect(function(payload)
			EventBus.Publish(name, payload)
		end)
	end

	-- Combat hits are combat UI (hitmarker/kill feed) — Phase 2, but wire
	-- the seam now so no service changes are needed later.
	combat.HitConfirmed:Connect(function(payload)
		EventBus.Publish("HitConfirmed", payload)
	end)

	self._connections = {}
end

function MatchController:KnitStart()
	-- Same client idiom as KnitInit: the remote methods hang off the reflected
	-- service object itself. With `.Client` here these two calls fail inside
	-- their pcall and are SILENT — no snapshot and no keepalive, which is the
	-- other half of the Q2-1 symptom (Q4-3: 60 s idle -> demoted to spectator).
	local match = Knit.GetService("Match")

	-- Bootstrap HUD state (phase, round, scores, teams) for late joiners.
	task.spawn(function()
		local ok, snapshot = pcall(function()
			return match.FetchMatchState:InvokeAsync()
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
				match.ReportActive:InvokeAsync()
			end)
		end
	end)
end

return MatchController
