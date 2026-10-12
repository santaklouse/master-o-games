--!strict
--[[
    CombatController (Knit client) — the firing input seam (A3a).

    WHY THIS FILE EXISTS
    Nothing on the client ever called CombatService.Client:FireRequest(player,
    payload): a human could walk Meridian Docks and click the mouse and nothing
    happened. This is the smallest honest path from "mouse button pressed" to
    "the server answered". It owns three things and nothing else:

      1. EQUIPPED STATE. There is no Tool anywhere in this repo and nothing
         touches the Backpack, and the ledger is the only authority on what a
         player may shoot this round (the server answers NOT_OWNED otherwise).
         So "equipped" is READ FROM THE SERVER (Economy.FetchLoadout) instead of
         being invented on the client, and it is re-read whenever the round or
         the wallet moves: the buy phase issuing the free sidearm, a purchase
         landing (Economy.CreditsChanged — the only signal a purchase emits),
         a round starting. The client keeps no durable copy it can drift from.
         Slot switching (rifle vs pistol in hand) is an A5 UI decision, not a
         firing-seam one: primary if the player rented one, else the sidearm.
      2. INPUT. MouseButton1 while a weapon is in hand -> one fire request per
         click (semi-auto semantics; the server's RPM gate stays the authority
         on how fast a weapon may shoot).
      3. THE PHASE GATE, client-side as well as server-side: outside ACTION the
         click is dropped silently — no remote call, no warn, no error spam.
         The server re-checks the phase anyway; this is a UX gate, never an
         authority.
      4. THE BUY KEYS (owner-approved, 2026-09-30). Alpha ships no buy menu, so
         without a key a player can only ever fire the free sidearm and the loop
         the Alpha exists to prove (earn credits -> buy -> carry into the next
         round) cannot be demonstrated. Three keys, nothing else, in the BUY
         PHASE only: 1 = CQB-2, 2 = ARC-5, B = the cheapest affordable Alpha
         weapon not already in hand. The purchase goes through the server like
         the A5 menu will (Economy.Client:RequestPurchase), the price comes from
         Shared.Weapons and the affordability from the replicated credits. No
         HUD, no list, no timer — one plain printed line per key that does
         something. See "Buy keys" below.

    WHAT IT DELIBERATELY DOES NOT DO: no HUD, no ammo, no tracers, no client
    prediction, recoil or spread. Those are A5/ART-2, and the server owns every
    one of those decisions anyway.

    THE RAY: origin is the shooter's HEAD, direction is the CAMERA's look
    vector. The camera is deliberately NOT the origin — CombatService rejects an
    origin more than MAX_ORIGIN_DISTANCE_FROM_HEAD_STUDS (8) from the head, and
    Roblox's stock third-person camera sits ~12+ studs behind the character, so
    a camera-position origin would make every shot from the default camera fail
    ORIGIN_OUT_OF_RANGE. Head + camera direction is what the crosshair means,
    and it stays inside the tolerance at any camera distance.

    THE FIELD NAMES ARE CAPITALISED (fixed 2026-09-30 — this was why every click
    did nothing). A Vector3's components are `.X/.Y/.Z`; `.x/.y/.z` is simply
    nil — and nil is silent. The payload went out as
    `origin = { x = nil, y = nil, z = nil }`, the server's ray validation and
    hitscan then did arithmetic on nil, and the remote errored / the shot was
    refused, so a correct-looking click from a real player landed nothing. The
    fix is at the payload, where the Vector3 is turned into the wire table, and
    the server now also refuses a ray whose components are not numbers instead
    of erroring on it (CombatService step 4).

    ONE MORE THING WORTH KNOWING: this controller does NOT listen to
    Match.Client.PhaseChanged. The state machine never fires it — there is no
    `_fire(Enums.Event.PhaseChanged, ...)` anywhere in
    Logic/MatchStateMachine.lua — so that signal is dead in the shipped flow
    (tests that fire it by hand are the only thing that exercises it). The
    phase-relevant events below are the ones the FSM actually emits.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local Knit = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Knit"))
local Shared = require(ReplicatedStorage:WaitForChild("Shared"))

local CombatController = Knit.CreateController({
	Name = "Combat",
})

-- Roblox EnumItem, read once at load: it cannot change at runtime.
local FIRE_INPUT = Enum.UserInputType.MouseButton1
local BUY_INPUT = Enum.UserInputType.Keyboard

-- Buy keys ------------------------------------------------------------------
--[[
    WHY A KEY, AND WHY THESE KEYS. The Alpha has no buy menu (A5/UI-2 own the
    HUD, the list and the timer) but the Alpha's whole point is the loop
    earn credits -> buy -> carry into the next round, and a build where the only
    weapon anyone can fire is the free sidearm cannot prove that loop. So three
    keys, owner-approved, and nothing else:

        1  -> CQB2   the Alpha entry rifle (1200 credits)
        2  -> ARC5   the Alpha rifle (2700 credits)
        B  -> the cheapest Alpha weapon that is affordable and not already in
              hand, so a player who does not know the ids can still shop

    WHERE EVERYTHING COMES FROM (nothing is invented on the client):
      * the shop list is Shared.Weapons.AlphaPurchasable, the same config the
        server's ledger prices from, so a key can never offer a weapon the
        server will not sell (Longshot/Talon are deliberately NOT in it);
      * the price is Shared.Weapons[id].price — never a hardcoded number here;
      * affordability is read from the REPLICATED credits (Economy.Credits,
        written by the server on every balance change), and the credits move
        only when the server's ledger says so (RequestPurchase);
      * "already in hand" mirrors the ledger's own ALREADY_OWNED rule off the
        loadout the server reported.

    THE PRINT CONTRACT (the entire UX, on purpose): exactly one plain line per
    key press that does something — what was bought and what it cost, or why
    nothing was bought. Outside the buy phase, silence: no request, no line, no
    error spam, because a key can be held down.
]]
local KEY_WEAPONS = {
	[Enum.KeyCode.One] = "CQB2",
	[Enum.KeyCode.Two] = "ARC5",
}
local KEY_CHEAPEST = Enum.KeyCode.B
local BUY_TAG = "[Buy]"
-- The Alpha shop by id, built once from config. An id that is in the list but
-- missing from the catalogue is dropped here (and refused at press time) rather
-- than becoming a request the server answers UNKNOWN_ITEM.
local ALPHA_SHOP = {}
local ALPHA_ORDER = {}
for _, id in ipairs(Shared.Weapons.AlphaPurchasable or {}) do
	local weapon = Shared.Weapons[id]
	if weapon ~= nil then
		ALPHA_SHOP[id] = weapon
		table.insert(ALPHA_ORDER, id)
	end
end

--[[
    Every event that moves the phase. Re-fetching the snapshot on these (a
    handful of remote calls per round) keeps the client's idea of the phase
    server-derived instead of guessed from its own timers.
]]
local REFRESH_ON = {
	"BuyPhaseStarted",
	"BuyPhaseEnded",
	"RoundStarted",
	"RoundEnded",
	"MatchStarted",
	"MatchEnded",
}

function CombatController:KnitInit()
	self.phase = nil -- last phase the server reported (Enums.Phase)
	self.loadout = nil -- last loadout the server reported
	self.equipped = nil -- weaponId in hand, or nil
	self._services = {
		Match = Knit.GetService("Match"),
		Economy = Knit.GetService("Economy"),
		Combat = Knit.GetService("Combat"),
	}
	for _, name in REFRESH_ON do
		local signal = self._services.Match[name]
		if signal ~= nil then
			signal:Connect(function()
				self:_refresh()
			end)
		end
	end
	-- A purchase or a round payout moves credits, and the loadout may have
	-- moved with it, so re-read it here too. This is what makes a bought rifle
	-- the weapon the next click fires, with no buy menu in the loop yet.
	self._services.Economy.CreditsChanged:Connect(function()
		self:_refreshLoadout()
	end)
end

function CombatController:KnitStart()
	self:_refresh()
	UserInputService.InputBegan:Connect(function(input)
		if input.UserInputType == FIRE_INPUT then
			self:TryFire()
		elseif input.UserInputType == BUY_INPUT then
			self:TryBuyKey(input.KeyCode)
		end
	end)
end

-- Server state read-back -----------------------------------------------------

function CombatController:_refresh()
	local ok, snapshot = pcall(function()
		return self._services.Match.FetchMatchState:InvokeAsync()
	end)
	if ok and type(snapshot) == "table" and snapshot.phase ~= nil then
		self.phase = snapshot.phase
	end
	self:_refreshLoadout()
end

function CombatController:_refreshLoadout()
	local ok, loadout = pcall(function()
		return self._services.Economy.FetchLoadout:InvokeAsync()
	end)
	if not ok or type(loadout) ~= "table" then
		return
	end
	self.loadout = loadout
	-- Primary first: a player who rented a rifle means to shoot the rifle, and
	-- with nothing rented the round's free sidearm is what is in hand. Melee is
	-- not in the chain — a knife has no ranged fire in this design (A3b/A5).
	self.equipped = loadout.primary or loadout.sidearm
end

-- Buy keys -------------------------------------------------------------------

-- One plain line, the only output this controller produces for shopping.
function CombatController:_say(message)
	print(("%s %s"):format(BUY_TAG, message))
end

--[[
    The player's own balance, off the REPLICATED credits (Economy.Credits: the
    server-written map of playerId -> credits). nil when the client has not been
    told yet — no default, no guess: a balance we cannot read is a balance we
    will not spend against.
]]
function CombatController:_credits()
	local property = self._services.Economy.Credits
	if property == nil then
		return nil
	end
	local ok, balances = pcall(function()
		return property:Get()
	end)
	if not ok or type(balances) ~= "table" then
		return nil
	end
	local player = Players.LocalPlayer
	local mine = player and balances[player.UserId]
	if type(mine) ~= "number" then
		return nil
	end
	return mine
end

-- Is this weapon's slot already filled this round? Mirrors the ledger's own
-- ALREADY_OWNED rule (EconomyLedger:PurchaseWeapon reads the same slot), from
-- the loadout the SERVER reported — the client keeps no rental state of its own.
function CombatController:_slotTaken(weapon)
	local loadout = self.loadout
	if loadout == nil then
		return false
	end
	if weapon.slot == "Primary" then
		return loadout.primary ~= nil
	elseif weapon.slot == "Sidearm" then
		return loadout.sidearm ~= nil
	elseif weapon.slot == "Melee" then
		return loadout.melee ~= nil
	end
	return false
end

--[[
    The cheapest Alpha weapon this player can actually take right now: cheapest
    first, skipping anything already in hand and anything above the balance.
    nil when there is nothing to buy — the caller says so in one line.
]]
function CombatController:_cheapestAffordable(balance)
	if balance == nil then
		return nil
	end
	local choice, choicePrice = nil, nil
	for _, id in ipairs(ALPHA_ORDER) do
		local weapon = ALPHA_SHOP[id]
		if balance >= weapon.price and not self:_slotTaken(weapon) then
			if choicePrice == nil or weapon.price < choicePrice then
				choice, choicePrice = id, weapon.price
			end
		end
	end
	return choice
end

--[[
    The ONE entry point for a buy key (1 / 2 / B). Returns the server's answer,
    or nil when nothing was sent: not the buy phase (silent), nothing
    affordable, or a weapon the Alpha does not sell. Every refusal is a single
    printed line AND no remote call — a held-down key must not spam either.
]]
function CombatController:TryBuyKey(keyCode)
	-- Gate 1: shopping is a buy-phase activity. The server re-checks this on
	-- RequestPurchase (NOT_BUY_PHASE); this is the UX half, exactly like TryFire.
	if self.phase ~= Shared.Enums.Phase.BuyPhase then
		return nil
	end
	local balance = self:_credits()
	local weaponId = KEY_WEAPONS[keyCode]
	if weaponId == nil then
		if keyCode ~= KEY_CHEAPEST then
			return nil -- a key that is not a buy key: not ours to answer
		end
		weaponId = self:_cheapestAffordable(balance)
	end
	if weaponId == nil then
		self:_say(("nothing affordable (credits %d) - no request sent"):format(balance or 0))
		return nil
	end
	local weapon = ALPHA_SHOP[weaponId]
	if weapon == nil then
		-- Config drift, not player error: a bound id that is not in the Alpha
		-- shop is refused here instead of being sent as a doomed request.
		self:_say(("%s is not an Alpha purchasable weapon - no request sent"):format(weaponId))
		return nil
	end
	if balance == nil or balance < weapon.price then
		self:_say(
			("cannot afford %s (%d credits, needs %d) - no request sent"):format(
				weapon.name,
				balance or 0,
				weapon.price
			)
		)
		return nil
	end
	if self:_slotTaken(weapon) then
		self:_say(("%s is already in hand this round - no request sent"):format(weapon.name))
		return nil
	end
	-- The purchase itself. Same client idiom as FetchLoadout, same remote the
	-- A5 buy menu will call, and the server's ledger is the only thing that
	-- moves credits or grants the weapon.
	local ok, result = pcall(function()
		return self._services.Economy.RequestPurchase:InvokeAsync({ type = "WEAPON", id = weaponId })
	end)
	if not ok or type(result) ~= "table" then
		self:_say(("the server did not answer the purchase of %s - nothing bought"):format(weapon.name))
		return nil
	end
	if result.ok then
		-- The server also fires CreditsChanged at this client, which is what
		-- moves self.equipped onto the new weapon (_refreshLoadout) — the
		-- controller never assumes the purchase landed, it follows the ledger.
		self:_say(("bought %s for %d credits (balance %s)"):format(weapon.name, weapon.price, tostring(result.balance)))
	else
		self:_say(("%s refused by the server: %s"):format(weapon.name, tostring(result.reason)))
	end
	return result
end

-- Firing ---------------------------------------------------------------------

--[[
    The ONE entry point for "this player pulled the trigger". Returns the
    server's result table, or nil when the shot never left the client (outside
    ACTION, nothing equipped, no character or camera to aim from). Silence is
    deliberate: this runs on every click, so it never warns.
]]
function CombatController:TryFire()
	if self.phase ~= Shared.Enums.Phase.Action then
		return nil
	end
	local weaponId = self.equipped
	if weaponId == nil or Shared.Weapons[weaponId] == nil then
		return nil
	end
	local aim = self:_aim()
	if aim == nil then
		return nil
	end
	local ok, result = pcall(function()
		return self._services.Combat.FireRequest:InvokeAsync({
			weaponId = weaponId,
			-- Server clock domain: CombatService compares this against
			-- Workspace:GetServerTimeNow(), never os.clock().
			fireTime = Workspace:GetServerTimeNow(),
			origin = { x = aim.origin.X, y = aim.origin.Y, z = aim.origin.Z },
			dir = { x = aim.dir.X, y = aim.dir.Y, z = aim.dir.Z },
		})
	end)
	if not ok then
		return nil
	end
	return result
end

-- Head position (origin) + camera look vector (direction), or nil when the
-- character or the camera is not there yet (respawn, load, Studio Play).
function CombatController:_aim()
	local player = Players.LocalPlayer
	local character = player and player.Character
	local head = character and character:FindFirstChild("Head")
	if head == nil then
		return nil
	end
	local camera = Workspace.CurrentCamera
	if camera == nil or camera.CFrame == nil then
		return nil
	end
	return { origin = head.Position, dir = camera.CFrame.LookVector }
end

return CombatController
