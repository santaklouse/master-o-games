--!strict
--[[
	BEACON PROTOCOL — RigProfile: hitbox regions in the TORSO-CENTRE frame.
	(gdd/alpha-weapon-plan.md §1/§7.2, gdd/weapons-tranche-readiness-notes.md §4)

	THE BUG THIS FILE EXISTS TO KILL (Q1-3 in gdd/spawn-and-boot-audit.md):
	CombatService records `character:GetPivot().Position`, which for a stock
	R6/R15 character IS the root part's centre — i.e. the TORSO centre, about
	3 studs above the feet. HitDetectionCore's old RegionDefaults then put the
	head at `offsetY = 3.0` ABOVE that point, i.e. ~6 studs above the feet,
	while a real standing head centre is ~4.5 studs up. Every chest shot hit
	nothing and every "headshot" aimed at the sky.

	So this is the ONE place that says where a body is, and it is stated in the
	recorded frame: every offset below is relative to the TORSO CENTRE, which
	is exactly what the recorder writes. No other module re-states an offset.

	UNIT OF RECORD: studs (WORKFLOW.md). Stock R6 proportions, which the Alpha
	place's primitives-first dummies are built to as well (plan §1 "the same
	frame as the player profile, so cover classes hold for both"), so R6 and
	Dummy share one row set on purpose — change one, change both.

	Region keys are Enums.HitRegion values ("HEAD"/"TORSO"/"LIMBS"). They are
	carried as plain strings so this module stays pure data (no requires) and
	loads identically in Roblox and in the Lune harness; tests/round_loop.lua
	asserts every key really is a live Enums.HitRegion value, so a renamed enum
	fails the suite instead of silently matching nothing.
]]

local RigProfile = {}

-- How high the recorded torso centre sits above the feet (Constants
-- .TorsoCentreAboveFeetStuds carries the same number for geometry/art work).
RigProfile.TorsoCentreAboveFeetStuds = 3.0

--[[
	R6 stock rig, torso-centre-relative:
	    head   centre +1.5  (radius 0.55 — the head is a 2x1x1 block)
	    torso  centre  0.0  (sphere r 1.15 approximates the 2x2x1 torso)
	    arms   x ±1.5, y 0.0 (1x2x1 each)
	    legs   x ±0.5, y −2.0 (1x2x1 each; the sphere's lower half covers the feet)

	Four separate limb spheres instead of one: the old single 0.4-radius limb
	sphere sat inside the torso and was effectively unhittable, so "you hit the
	arm" could never be reported.
]]
RigProfile.R6 = {
	name = "R6",
	regions = {
		{ region = "HEAD", offsetX = 0, offsetY = 1.5, offsetZ = 0, radius = 0.55 },
		{ region = "TORSO", offsetX = 0, offsetY = 0.0, offsetZ = 0, radius = 1.15 },
		{ region = "LIMBS", offsetX = 1.5, offsetY = 0.0, offsetZ = 0, radius = 0.5 },
		{ region = "LIMBS", offsetX = -1.5, offsetY = 0.0, offsetZ = 0, radius = 0.5 },
		{ region = "LIMBS", offsetX = 0.5, offsetY = -2.0, offsetZ = 0, radius = 0.55 },
		{ region = "LIMBS", offsetX = -0.5, offsetY = -2.0, offsetZ = 0, radius = 0.55 },
	},
}

-- Practice dummies are built to the same frame (plan §1), so the same rows.
RigProfile.Dummy = {
	name = "Dummy",
	regions = {
		{ region = "HEAD", offsetX = 0, offsetY = 1.5, offsetZ = 0, radius = 0.55 },
		{ region = "TORSO", offsetX = 0, offsetY = 0.0, offsetZ = 0, radius = 1.15 },
		{ region = "LIMBS", offsetX = 1.5, offsetY = 0.0, offsetZ = 0, radius = 0.5 },
		{ region = "LIMBS", offsetX = -1.5, offsetY = 0.0, offsetZ = 0, radius = 0.5 },
		{ region = "LIMBS", offsetX = 0.5, offsetY = -2.0, offsetZ = 0, radius = 0.55 },
		{ region = "LIMBS", offsetX = -0.5, offsetY = -2.0, offsetZ = 0, radius = 0.55 },
	},
}

-- The profile the game ships until a rig is actually measured. R15 is
-- deliberately NOT guessed here: inventing offsets we have not measured would
-- re-create exactly the bug above. Add an R15 row set when a real rig is
-- measured, and point RigProfile.Default at it.
RigProfile.Default = "R6"

function RigProfile.For(rigType)
	if rigType == nil then
		rigType = RigProfile.Default
	end
	if type(rigType) == "table" then
		return rigType -- already a profile
	end
	local profile = RigProfile[rigType]
	assert(profile ~= nil, ("RigProfile: unknown rig type %q (known: R6, Dummy)"):format(tostring(rigType)))
	return profile
end

--[[
	The RECORDED frame: turn a character pivot into the torso centre the
	recorder stores and every region offset above is measured from.

	`player.Character:GetPivot().Position` is the model's PrimaryPart centre,
	which for a stock R6/R15 character is the HumanoidRootPart — the torso
	centre. Keeping this an explicit, named conversion (rather than an
	unexplained `GetPivot()` at the call site) is what makes the frame a
	documented decision instead of an accident; if a rig family ever needs a
	correction it lands here and every region follows it.
]]
function RigProfile.TorsoCentreFromPivot(pivotPosition)
	return { x = pivotPosition.X, y = pivotPosition.Y, z = pivotPosition.Z }
end

return RigProfile
