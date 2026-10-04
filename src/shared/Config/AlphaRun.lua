--!strict
--[[
	AlphaRun — the Alpha RUN config overlay (gdd/alpha-weapon-plan.md §1/§5).
	The single source of Alpha's run numbers: small teams so two or four people
	can play, PlayersToStart = 1 so a solo practice session can start, and the
	shorter match the acceptance contract's Alpha playtest assumes.

	`Enabled` is the ONE switch: `AlphaRun.Enabled = false` restores every GDD
	value with no code change (RunConfig.resolve returns the plain Constants).

	Run numbers only — weapon/economy/combat tuning stays in their own config
	files. RunConfig.resolve() rejects any key that is not both listed in
	AllowedFields and a real field of the GDD baseline (Constants), so a typo'd
	override fails loudly instead of silently doing nothing.

	Unit of record: studs / seconds, exactly as in Constants.lua.
]]

local AlphaRun = {}

AlphaRun.Enabled = true
-- Server logging verbosity (Phase 2 Log.lua consumes this; nothing reads it yet).
AlphaRun.Verbose = false

-- The Alpha overlay: plan §5 and the acceptance contract's Alpha column agree
-- on these five (the contract's 3v3/win-4 variant is the pre-Alpha one; the
-- ruling in gdd/weapons-tranche-readiness-notes.md §14 makes this file it).
AlphaRun.Overrides = {
	TeamSize = 2, -- 2v2: four people, or one human + practice dummies (A3b)
	PlayersToStart = 1, -- a single human can start (practice start)
	WinScore = 3, -- first to 3 round wins
	MaxRounds = 5, -- short match, no overtime
	SideSwapAfterRound = 2, -- sides swap before round 3
}

-- The run numbers the overlay is allowed to change. AFKKickSeconds is listed
-- because the acceptance contract's Alpha playtest must not be kicked while
-- the operator inspects the world; it is NOT overridden above, so the GDD's
-- 60 s still applies (the client keepalive now keeps a live player active).
AlphaRun.AllowedFields = {
	TeamSize = true,
	PlayersToStart = true,
	WinScore = true,
	MaxRounds = true,
	SideSwapAfterRound = true,
	AFKKickSeconds = true,
}

return AlphaRun
