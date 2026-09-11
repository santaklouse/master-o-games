--!strict
--[[
    BEACON PROTOCOL — shared constants (GDD §4 Match Spec, §7, §10).
    Single source of truth for match-wide numbers. Server services and
    client controllers both read from here; nothing magic-numbered in code.
    All times are in SECONDS unless the name says Ms. All distances in studs.

    Mapping to GDD:
        §4  Match Spec table: teams, win condition, round timer, buy phase,
            side swap, server capacity, spectactor slots, player count.
        §5.2 Prices live in Economy.lua (they belong to the economy).
        §10.4 Lag compensation window (≤200 ms).
]]

local Constants = {
	-- Identity (§1.1, §8.1): original IP — no CS names anywhere.
	GameName = "BEACON PROTOCOL",
	MapName = "Meridian Docks", -- §8.1: one map, two sites, 3 lanes

	-- §4 Match Spec
	Teams = {
		Raiders = "Raiders", -- attack
		Wardens = "Wardens", -- defend
	},
	TeamList = { "Raiders", "Wardens" },
	TeamSize = 5, -- 5v5
	ServerCapacity = 16, -- 10 players + 6 spectator slots
	PlayersToStart = 10, -- match starts when 10 players are in the lobby
	SpectatorSlots = 6,
	WinScore = 8, -- first team to 8 round wins
	MaxRounds = 15, -- 7-7 -> round 15 decider (no overtime in MVP, §4)
	SideSwapAfterRound = 7, -- sides swap before round 8 (§4; §9 walkthrough says "side swap at round 8" == after round 7)
	BuyPhaseDuration = 20, -- seconds, spawn-locked (§4)
	RoundDuration = 105, -- seconds (1:45) action phase (§4)
	RoundEndPause = 4, -- interstitial between rounds (presentation seam; not GDD-specified)
	WarmupDuration = 60, -- §9 walkthrough: 60 s warmup in lobby (Phase 2 consumption)
	StartingCredits = 0, -- §5.3: credits reset at match end; pistol round is free

	-- §4 Lobby behavior
	AFKKickSeconds = 60, -- idle in lobby / buy phase -> demoted to spectator

	-- §10.4 Server-authoritative hitscan + lag compensation
	-- HARD CONSTRAINT: rewind window MUST be <= 200 ms.
	LagCompensationWindowMs = 200,
	LagCompensationSampleInterval = 0.1, -- record a position sample every 100 ms

	-- §7 BEACON objective (Phase 2 consumes; values frozen here so the
	-- objective logic and the round timer agree from day one).
	UplinkDuration = 45, -- post-plant uplink countdown (seconds)
	PlantDuration = 4.0, -- hold-to-interact seconds
	DisableDuration = 7.0, -- hold-to-interact seconds; progress does not save

	-- §6 Shared damage rules
	MaxHealth = 100,
}

return Constants
