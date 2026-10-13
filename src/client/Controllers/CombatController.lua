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
-- The rematch key (see TryRematchVote below): after a match the FSM returns to
-- LOBBY and auto-start waits for GetRematchVoteRequired() votes, which for a
-- lone player is 1. The end screen that would cast it is A5's and A5 has not
-- shipped, so without this key a solo session plays match #1 and then sits in
-- the lobby forever. R is that way out; nothing else in the Alpha is bound to R.
local KEY_REMATCH = Enum.KeyCode.R
local MATCH_TAG = "[Match]"
-- Firing feedback (see "The print contract for firing" below).
local FIRE_TAG = "[Fire]"
-- Holding a mouse button or a buy key must not flood the output: one line per
-- outcome, but no more than one line per FIRE_LOG_MIN_INTERVAL seconds. This
-- throttles the PRINTING only — the server's own RPM gate stays the authority
-- on how fast a weapon may actually shoot.
local FIRE_LOG_MIN_INTERVAL = 0.25
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
	self._lastFireLogAt = nil -- os.clock() of the last fire line printed
	self._atMatchEnd = false -- the server ended a match and is waiting for a rematch vote
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
	-- The end screen (A5) is what will own the rematch vote; until it exists the R
	-- key does, and it has to know it is looking at the END of a match rather than
	-- at the first lobby of a server session — the phase alone cannot tell them
	-- apart, because MatchEnded puts the FSM back in LOBBY.
	self._services.Match.MatchEnded:Connect(function()
		self._atMatchEnd = true
	end)
end

function CombatController:KnitStart()
	self:_refresh()
	-- `gameProcessedEvent` is the engine's word for "something in the GUI
	-- already consumed this input" (the chat bar, a text box, CoreGui, the
	-- escape menu). Ignoring it meant a click or a key that went to CHAT still
	-- reached TryFire / TryBuyKey — and with 1 / 2 / B live as buy keys, typing
	-- a message containing those keys would BUY a weapon. The guard is first
	-- for that reason: nothing in this controller runs on a consumed input.
	UserInputService.InputBegan:Connect(function(input, gameProcessedEvent)
		if gameProcessedEvent then
			return
		end
		if input.UserInputType == FIRE_INPUT then
			self:TryFire()
		elseif input.UserInputType == BUY_INPUT then
			-- One handler, three keys: R is the rematch vote, 1 / 2 / B are the buy
			-- keys (and every other key stays silent, which is why TryBuyKey ignores
			-- KeyCodes it does not bind).
			if input.KeyCode == KEY_REMATCH then
				self:TryRematchVote()
			else
				self:TryBuyKey(input.KeyCode)
			end
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
		if self.phase ~= Shared.Enums.Phase.Lobby then
			-- A live phase means the rematch vote was answered (or a new match is
			-- already under way): the end screen is behind us.
			self._atMatchEnd = false
		end
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

-- Same print contract as _say, under the match tag.
function CombatController:_sayMatch(message)
	print(("%s %s"):format(MATCH_TAG, message))
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
    THE PRINT CONTRACT FOR FIRING. The kill feed and the round banner do not
    exist yet (A5/UI-2), so this one line IS the player's whole feedback loop,
    and until now there was none: TryFire's return value was discarded at the
    call site, which made "the server refused the shot" (DEAD, RATE_LIMITED,
    NOT_OWNED, NOT_A_RANGED_WEAPON, STALE_FIRE_TIME) indistinguishable from "I
    missed" — and both indistinguishable from "nothing is wired up at all".
    One line per outcome now says which of those it was, throttled so holding
    the mouse button cannot flood the output.
]]
function CombatController:_logFire(message)
	local now = os.clock()
	if self._lastFireLogAt ~= nil and (now - self._lastFireLogAt) < FIRE_LOG_MIN_INTERVAL then
		return
	end
	self._lastFireLogAt = now
	print(("%s %s"):format(FIRE_TAG, message))
end

-- A weapon's display name for the log line, falling back to the id: a config
-- drift must not turn a feedback line into an error.
function CombatController:_weaponLabel(weaponId)
	local weapon = Shared.Weapons[weaponId]
	if type(weapon) == "table" and type(weapon.name) == "string" then
		return weapon.name
	end
	return tostring(weaponId)
end

-- The server's answer, in one line: refused (with the reason), fired without a
-- hit, or a hit (with region, damage and distance).
function CombatController:_logFireOutcome(weaponId, result)
	local label = self:_weaponLabel(weaponId)
	if not result.ok then
		self:_logFire(("%s refused by the server: %s"):format(label, tostring(result.reason)))
		return
	end
	local hit = result.hit
	if type(hit) ~= "table" then
		self:_logFire(("%s fired - no hit (%s)"):format(label, tostring(result.reason)))
		return
	end
	local line = ("%s hit %s for %s damage (%.1f studs)"):format(
		label,
		tostring(hit.region),
		tostring(result.damage),
		tonumber(hit.distance) or 0
	)
	if result.lethal then
		line ..= " - target eliminated"
	end
	self:_logFire(line)
end

--[[
    The ONE entry point for "this player wants another match".

    THE DEAD END THIS CLOSES (P2B, 2026-10). After a match the FSM returns to
    LOBBY and auto-start waits for GetRematchVoteRequired() votes. Nothing on the
    client ever cast one — the end screen is A5's work and has not shipped — so a
    session could play match #1 and then sit in the lobby with no key, no menu and
    no way forward. For a lone player that vote count is 1, so his own vote is
    enough; he just had no way to cast it. R casts it through the same remote the
    end screen will call. Silence when this is not the end screen (the first
    lobby, the buy phase, a live round): the key is not ours to answer there, and
    a key can be held down.
]]
function CombatController:TryRematchVote()
	if not self._atMatchEnd then
		return nil
	end
	local ok, result = pcall(function()
		return self._services.Match.RequestRematchVote:InvokeAsync()
	end)
	if not ok or result == nil then
		self:_sayMatch("the server did not answer the rematch vote")
		return nil
	end
	if result == true then
		self:_sayMatch("rematch vote cast")
	else
		self:_sayMatch("the server refused the rematch vote")
	end
	return result
end

--[[
    The ONE entry point for "this player pulled the trigger". Returns the
    server's result table, or nil when the shot never left the client (outside
    ACTION, nothing equipped, no character or camera to aim from).

    The phase gate stays SILENT on purpose (outside ACTION a click is expected,
    not an error) — but every other outcome prints one throttled line, including
    the two local drops, because "I clicked and nothing happened" is exactly the
    state this build must never leave the player in.
]]
function CombatController:TryFire()
	if self.phase ~= Shared.Enums.Phase.Action then
		return nil
	end
	local weaponId = self.equipped
	if weaponId == nil or Shared.Weapons[weaponId] == nil then
		self:_logFire("nothing equipped - no request sent")
		return nil
	end
	local aim = self:_aim()
	if aim == nil then
		self:_logFire(
			("%s: no character head or camera to aim from - no request sent"):format(self:_weaponLabel(weaponId))
		)
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
	if not ok or type(result) ~= "table" then
		self:_logFire(("%s: no answer from the server - nothing resolved"):format(self:_weaponLabel(weaponId)))
		return nil
	end
	self:_logFireOutcome(weaponId, result)
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
