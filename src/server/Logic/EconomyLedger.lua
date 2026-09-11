--!strict
--[[
	EconomyLedger — server-side credit + loadout registry (GDD §5, exact).
	Owns one match's worth of economy state:

	§5.1 awards (per player, per event)
		win +3000 | loss +1500 | kill +300 | plant +500 | disable +500
		interest: NONE
	§5.2 prices
		Viper-9/Talon free (issued every round), CQB-2 1200, ARC-5 2700,
		Longshot 2900, Light Vest 650, Full Kit 1000
	§5.3 persistence rules (the dev contract)
		credits persist across rounds, reset at match end
		purchased weapons/armor reset EVERY round (rental model)
		no team-buy assist, no weapon drops (both deferred)

	Anti-exploit rails (enforced here, independently of the service layer):
		- award amounts come from the Economy config table only
		- NO method on this ledger creates credits out of thin air
		- purchases reject on insufficient balance (never negative balance)

	Pure Luau, zero internal requires (config injected).
]]

local EconomyLedger = {}
EconomyLedger.__index = EconomyLedger

-- config = { Economy = EconomyConfig, Enums = Enums, Weapons = WeaponsConfig }
function EconomyLedger.new(config)
	local self = setmetatable({}, EconomyLedger)
	self.Economy = config.Economy
	self.Enums = config.Enums
	self.Weapons = config.Weapons
	self.players = {} -- playerId -> { credits, loadout } (loadout = this round's rentals)
	self.events = nil -- optional { Awarded = connect-like } — services wire their own
	return self
end

-- Internal ----------------------------------------------------------------

function EconomyLedger:_ensure(playerId)
	local p = self.players[playerId]
	if p == nil then
		p = {
			playerId = playerId,
			credits = 0,
			-- This round's rentals: { primary = weaponId|nil, sidearm, melee, armor }
			loadout = { primary = nil, sidearm = nil, melee = nil, armor = self.Enums.Armor.None },
		}
		self.players[playerId] = p
	end
	return p
end

-- Credits -----------------------------------------------------------------

function EconomyLedger:GetBalance(playerId)
	local p = self:_ensure(playerId)
	return p.credits
end

function EconomyLedger:CanAfford(playerId, price)
	return self:GetBalance(playerId) >= price
end

-- Single award path — EVERY credit that enters a player's bank goes
-- through Award(). Stops "free money" bugs at the ledger boundary.
function EconomyLedger:Award(playerId, amount, reason)
	assert(amount > 0, "EconomyLedger:Award amount must be positive")
	assert(reason ~= nil, "EconomyLedger:Award requires a reason")
	local p = self:_ensure(playerId)
	p.credits = math.round((p.credits + amount) * 100) / 100 -- guard float drift
	return {
		playerId = playerId,
		amount = amount,
		reason = reason,
		balance = p.credits,
	}
end

-- §5.1 typed awards (exact amounts from config)
function EconomyLedger:AwardRoundWin(playerId)
	return self:Award(playerId, self.Economy.Awards.RoundWin, self.Enums.CreditReason.RoundWin)
end

function EconomyLedger:AwardRoundLoss(playerId)
	return self:Award(playerId, self.Economy.Awards.RoundLoss, self.Enums.CreditReason.RoundLoss)
end

function EconomyLedger:AwardKill(playerId)
	return self:Award(playerId, self.Economy.Awards.Kill, self.Enums.CreditReason.Kill)
end

function EconomyLedger:AwardBeaconPlant(playerId)
	return self:Award(playerId, self.Economy.Awards.BeaconPlant, self.Enums.CreditReason.BeaconPlant)
end

function EconomyLedger:AwardBeaconDisable(playerId)
	return self:Award(playerId, self.Economy.Awards.BeaconDisable, self.Enums.CreditReason.BeaconDisable)
end

-- Settle a round for one player (win or loss bonus).
function EconomyLedger:SettleRound(playerId, playerTeam, roundWinnerTeam)
	if roundWinnerTeam == playerTeam then
		return self:AwardRoundWin(playerId)
	end
	return self:AwardRoundLoss(playerId)
end

-- Purchases & rentals -------------------------------------------------------

-- Buy a weapon from the shop. Returns { ok = true, loadout } or
-- { ok = false, reason = "INSUFFICIENT_CREDITS" | "ALREADY_OWNED" | "UNKNOWN_ITEM" }.
-- No credit returns, no partial spends, no negative balances.
function EconomyLedger:PurchaseWeapon(playerId, weaponId)
	local w = self.Weapons[weaponId]
	if w == nil then
		return { ok = false, reason = "UNKNOWN_ITEM" }
	end
	local p = self:_ensure(playerId)
	if w.price <= 0 then
		-- Free weapons are issued, not purchased (see IssueFreeLoadout)
		return { ok = false, reason = "FREE_ITEM" }
	end
	if w.slot == "Primary" and p.loadout.primary ~= nil then
		return { ok = false, reason = "ALREADY_OWNED" }
	end
	if w.slot == "Sidearm" and p.loadout.sidearm ~= nil then
		return { ok = false, reason = "ALREADY_OWNED" }
	end
	if p.credits < w.price then
		return { ok = false, reason = "INSUFFICIENT_CREDITS" }
	end

	p.credits = math.round((p.credits - w.price) * 100) / 100
	if w.slot == "Primary" then
		p.loadout.primary = weaponId
	elseif w.slot == "Sidearm" then
		p.loadout.sidearm = weaponId
	elseif w.slot == "Melee" then
		p.loadout.melee = weaponId
	end
	return { ok = true, loadout = p.loadout, balance = p.credits }
end

-- Buy armor. Exact prices §5.2. Full Kit replaces Light Vest (never stacks).
function EconomyLedger:PurchaseArmor(playerId, armorId)
	local price = self.Economy.Prices[armorId]
	if price == nil then
		return { ok = false, reason = "UNKNOWN_ITEM" }
	end
	local p = self:_ensure(playerId)
	local current = p.loadout.armor
	if current == armorId then
		return { ok = false, reason = "ALREADY_OWNED" }
	end
	if p.credits < price then
		return { ok = false, reason = "INSUFFICIENT_CREDITS" }
	end
	p.credits = math.round((p.credits - price) * 100) / 100
	p.loadout.armor = armorId
	return { ok = true, loadout = p.loadout, balance = p.credits }
end

-- §5.3 rental model: issued free every round, then purchases reset.
function EconomyLedger:IssueFreeLoadout(playerId)
	local p = self:_ensure(playerId)
	p.loadout.sidearm = self.Weapons.Order[1] -- Viper-9 (index-ordered free sidearm)
	p.loadout.melee = self.Weapons.Order[5] -- Talon
	return p.loadout
end

-- §5.3 "Reset every round (rental model: re-buy each buy phase)".
-- Keeps credits; drops purchased weapons + armor back to free loadout.
function EconomyLedger:ResetRentals(playerId)
	local p = self:_ensure(playerId)
	p.loadout = { primary = nil, sidearm = nil, melee = nil, armor = self.Enums.Armor.None }
	self:IssueFreeLoadout(playerId)
	return p.loadout
end

function EconomyLedger:GetLoadout(playerId)
	local p = self:_ensure(playerId)
	return p.loadout
end

function EconomyLedger:GetArmor(playerId)
	local p = self:_ensure(playerId)
	return p.loadout.armor
end

-- §5.3 match end: credits reset, loadout cleared.
function EconomyLedger:ResetForNewMatch(playerId)
	self.players[playerId] = nil
end

function EconomyLedger:ResetAll()
	self.players = {}
end

function EconomyLedger:GetAllBalances()
	local out = {}
	for id, p in self.players do
		out[id] = p.credits
	end
	return out
end

return EconomyLedger
