--!strict
--[[
	BEACON PROTOCOL — buy economy config (GDD §5, exact MVP numbers).
	Credit awards (§5.1), prices (§5.2), persistence rules (§5.3).
	The EconomyLedger (server Logic) enforces these; this file is the
	read-only source of truth shared with clients (buy menu prices).

	Anti-exploit (GDD §11): credits are NEVER purchasable. This config
	only defines in-match awards and shop prices.
]]

local Economy = {
	-- §5.1 Credit awards (per player, per event) — MVP exact numbers
	Awards = {
		RoundWin = 3000, -- flat; no team-skill scaling in MVP
		RoundLoss = 1500, -- flat loss bonus; no loss-streak scaling (deferred)
		Kill = 300, -- any kill, any weapon
		BeaconPlant = 500, -- one-time per plant (Raider who plants)
		BeaconDisable = 500, -- one-time per disable (Warden who disables)
		Interest = 0, -- NONE in MVP (§5.1, deferred — keeps economy math readable)
	},

	-- §5.2 Prices (credits)
	Prices = {
		Viper9 = 0, -- free, issued every round
		Talon = 0, -- free, issued every round
		CQB2 = 1200,
		ARC5 = 2700,
		Longshot = 2900,
		LightVest = 650, -- -25% all damage
		FullKit = 1000, -- vest + helmet; -30% body/limb, headshot cap x2.0
	},

	-- §5.2 sample economy math (design targets, for tests & docs):
	--   pistol round = free loadout
	--   lose round 1 (+1500) -> SMG round 2
	--   win round 1 (+3000) -> ARC-5 or Longshot round 2
	--   full buy (2700 + 1000 = 3700) ~= one win + one kill (3300)
	--   eco rounds (Viper-9 only) are a real strategic choice

	-- §5.3 Persistence rules (dev contract, enforced by EconomyLedger):
	--   credits:  persist across rounds within a match; reset at match end
	--   purchased weapons/armor: reset EVERY round (rental model)
	--   score/side: persist across rounds; reset at match end
	--   account XP/rank: post-MVP (not in MVP, §8.2)
}

return Economy
