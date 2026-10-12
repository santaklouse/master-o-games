--!strict
--[[
    EconomyService (Knit) — server-side credit ledger + buy gate (GDD §5).
    Thin wrapper over Logic/EconomyLedger.lua (pure ledger with exact
    §5.1 awards and §5.3 persistence). Enforces the phase rule: purchases
    are ONLY valid during the 20 s buy phase (spawn-locked, §4).

    AUTHORITY RULE: only server flows create credits — MatchService round
    settlement, CombatService kills, and (Phase 2) the BEACON service for
    plant/disable. Clients only read their balance (RemoteProperty) and
    submit purchase requests that the server validates against the ledger.

    Phase 2 plug points (buy menu):
        knit.GetService("Economy"):Client:RequestPurchase:InvokeAsync({
            type = "WEAPON" | "ARMOR", id = "ARC5"
        })
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Knit"))
local Shared = require(ReplicatedStorage:WaitForChild("Shared"))

local EconomyLedger = require(script.Parent.Parent.Logic.EconomyLedger)

local EconomyService = Knit.CreateService({
	Name = "Economy",
	Client = {
		-- Read-only replication for HUD: playerId -> credits (server writes)
		Credits = Knit.CreateProperty({}),
		-- Per-player payout event for the buy menu / round end screen:
		-- payload { playerId, amount, reason, balance, event = "ROUND_WIN" | ... }
		CreditsChanged = Knit.CreateSignal(),
	},
})

local ledger = EconomyLedger.new({
	Economy = Shared.Economy,
	Enums = Shared.Enums,
	Weapons = Shared.Weapons,
})

-- Client-facing remote methods ----------------------------------------------

-- The only purchase entry point. Returns { ok, reason, loadout, balance }.
function EconomyService.Client:RequestPurchase(player, request)
	-- Phase gate: buy phase only (spawn-locked shopping, §4).
	if not Knit.GetService("Match"):IsBuyPhase() then
		return { ok = false, reason = "NOT_BUY_PHASE" }
	end
	local result
	if request and request.type == "WEAPON" then
		result = ledger:PurchaseWeapon(player.UserId, request.id)
	elseif request and request.type == "ARMOR" then
		result = ledger:PurchaseArmor(player.UserId, request.id)
	else
		return { ok = false, reason = "BAD_REQUEST" }
	end
	if result.ok then
		Knit.GetService("PlayerState"):SetArmor(player.UserId, ledger:GetArmor(player.UserId))
		-- Knit calls Client methods with self = the Client table, so the
		-- service (and its private helpers) is reached through self.Server.
		self.Server:_PublishCredits()
		-- A purchase MOVES THE LOADOUT, not just the balance (2026-09-30 fix).
		-- Publishing only the balance left clients that track what is in hand
		-- (the A3a firing input re-reads its loadout off this signal) still
		-- firing the weapon they had before the purchase: the owner would have
		-- rented the ARC-5 and every click would have kept firing the pistol.
		-- Targeted at the buyer — a purchase is that player's business.
		self.Server:_FireCreditsChanged({
			playerId = player.UserId,
			amount = -(Shared.Economy.Prices[request.id] or 0),
			reason = "PURCHASE",
			balance = result.balance,
			loadout = result.loadout,
			itemId = request.id,
		}, player)
	end
	return result
end

-- Server-facing API (called by MatchService / CombatService / Phase2) -------

function EconomyService:InitPlayer(playerId)
	-- Starter loadout is free every round; pistol round costs nothing.
	ledger:IssueFreeLoadout(playerId)
	self:_PublishCredits()
end

function EconomyService:AwardKill(playerId)
	local result = ledger:AwardKill(playerId)
	self:_PublishCredits()
	self:_FireCreditsChanged(result)
	return result
end

function EconomyService:AwardBeaconPlant(playerId)
	local result = ledger:AwardBeaconPlant(playerId)
	self:_PublishCredits()
	self:_FireCreditsChanged(result)
	return result
end

function EconomyService:AwardBeaconDisable(playerId)
	local result = ledger:AwardBeaconDisable(playerId)
	self:_PublishCredits()
	self:_FireCreditsChanged(result)
	return result
end

-- §5.1 win/loss settlement for one player (called from MatchService).
function EconomyService:SettleRoundForPlayer(playerId, playerTeam, roundWinnerTeam)
	local result = ledger:SettleRound(playerId, playerTeam, roundWinnerTeam)
	self:_PublishCredits()
	self:_FireCreditsChanged(result)
	return result
end

-- Read-back of the caller's OWN loadout (A3a firing seam). The client's firing
-- input may only shoot what the server says is in hand this round, so it asks
-- here rather than caching a guess. There is no player argument to forge: the
-- id comes from the invoking player, never from the payload.
function EconomyService.Client:FetchLoadout(player)
	return ledger:GetLoadout(player.UserId)
end
-- §5.3 rental reset (re-buy each buy phase); keeps credits.
function EconomyService:ResetRentals(playerId)
	ledger:ResetRentals(playerId)
	self:_PublishCredits()
end

-- §5.3 match end: ALL credits reset (match-scoped ledger).
function EconomyService:ResetAllForNewMatch()
	ledger:ResetAll()
	self:_PublishCredits()
end

-- Per-player cleanup on leave (drops only that player from the ledger).
function EconomyService:CleanupPlayer(playerId)
	ledger:ResetForNewMatch(playerId) -- drops the player from the ledger
	self:_PublishCredits()
end

-- Reads for other services (Phase 2 buy menu pricing, HUD) ------------------

function EconomyService:GetBalance(playerId)
	return ledger:GetBalance(playerId)
end

function EconomyService:CanAfford(playerId, price)
	return ledger:CanAfford(playerId, price)
end

function EconomyService:GetLoadout(playerId)
	return ledger:GetLoadout(playerId)
end

function EconomyService:GetArmor(playerId)
	return ledger:GetArmor(playerId)
end

-- Internal ------------------------------------------------------------------

function EconomyService:_PublishCredits()
	self.Client.Credits:Set(ledger:GetAllBalances())
end

--[[
    CreditsChanged is the buy-menu/round-end feed. Called with a `player` it is
    delivered to THAT client only (Knit: the player argument IS the delivery);
    called without one it broadcasts, which is what the round-wide award paths
    do. A per-player purchase is the targeted case (2026-09-30).
]]
function EconomyService:_FireCreditsChanged(result, player)
	if player ~= nil then
		self.Client.CreditsChanged:Fire(player, result)
	else
		self.Client.CreditsChanged:Fire(result)
	end
end

return EconomyService
