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
