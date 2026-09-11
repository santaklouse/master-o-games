--!strict
--[[
    BEACON PROTOCOL — string enums (GDD §4, §7).
    Plain strings (not Roblox Enums) so every layer — server logic, Knit
    services, client controllers, headless tests — can serialize them over
    remotes without conversion. Keep values stable: they ship over the wire
    to UI and appear in roundHistory payloads.
]]

local Enums = {
	-- Match / round phase (MatchStateMachine.GetPhase / PhaseChanged)
	Phase = {
		Lobby = "LOBBY", -- waiting to fill, warmup
		BuyPhase = "BUY_PHASE", -- 20 s spawn-locked shopping
		Action = "ACTION", -- round live, <= 105 s
		RoundEnd = "ROUND_END", -- brief interstitial before next buy phase
		MatchEnd = "MATCH_END", -- first-to-8 reached; rematch/lobby
	},

	-- Why a round ended (§7.2 win conditions, checked in this order)
	RoundEndReason = {
		TeamEliminated = "TEAM_ELIMINATED", -- all players of a team dead
		UplinkComplete = "UPLINK_COMPLETE", -- planted + 45 s elapsed -> Raiders win
		BeaconDisabled = "BEACON_DISABLED", -- 7 s disable completed -> Wardens win
		TimeExpiredPlanted = "TIME_EXPIRED_PLANTED", -- 105 s out + beacon planted -> Raiders win
		TimeExpiredNotPlanted = "TIME_EXPIRED_NOT_PLANTED", -- 105 s out, no plant -> Wardens win
	},

	-- Player seat in a match (§4)
	Role = {
		Raider = "RAIDER",
		Warden = "WARDEN",
		Spectator = "SPECTATOR",
		Waitlist = "WAITLIST", -- server full; queued behind the 16 slots
	},

	-- Hit regions (GDD §6 shared damage rules; also used by core rig geometry)
	HitRegion = {
		Head = "HEAD",
		Torso = "TORSO",
		Limbs = "LIMBS",
	},

	-- Armor items (§5.2)
	Armor = {
		None = "NONE",
		LightVest = "LightVest", -- -25% all damage
		FullKit = "FullKit", -- -30% body/limb, headshot cap x2.0
	},

	-- Side of a team for a given round (§4 side swap after round 7)
	Side = {
		Attack = "ATTACK",
		Defend = "DEFEND",
	},

	-- Match state machine event names (single source of truth; MatchService
	-- maps these onto Knit remote signals with the same names and payloads,
	-- and UI binds to them — see README "UI event contract").
	Event = {
		PhaseChanged = "PhaseChanged",
		PlayerJoined = "PlayerJoined",
		PlayerLeft = "PlayerLeft",
		MatchStarted = "MatchStarted",
		BuyPhaseStarted = "BuyPhaseStarted",
		BuyPhaseEnded = "BuyPhaseEnded",
		RoundStarted = "RoundStarted",
		RoundEnded = "RoundEnded",
		ScoreUpdated = "ScoreUpdated",
		MatchEnded = "MatchEnded",
		PlayerEliminated = "PlayerEliminated",
		PlayerDemotedToSpectator = "PlayerDemotedToSpectator",
		RematchVoteUpdated = "RematchVoteUpdated",
	},

	-- Credit award reasons (§5.1) — reflected to clients in CreditsChanged
	CreditReason = {
		RoundWin = "ROUND_WIN",
		RoundLoss = "ROUND_LOSS",
		Kill = "KILL",
		BeaconPlant = "BEACON_PLANT",
		BeaconDisable = "BEACON_DISABLE",
		Refunded = "REFUNDED",
		Reset = "RESET",
	},
}

return Enums
