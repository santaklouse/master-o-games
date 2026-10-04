--!strict
--[[
    BEACON PROTOCOL — Shared root module (ReplicatedStorage.Shared).
    Re-exports the read-only config used by both server logic and client
    controllers. Require submodules directly when you need one:
        require(ReplicatedStorage.Shared.Constants)
    or require the root for convenience:
        local Shared = require(ReplicatedStorage.Shared)
        Shared.Weapons.GetWeapon("ARC5")
]]

local Shared = {}

Shared.Constants = require(script.Constants)
Shared.Enums = require(script.Enums)

Shared.Weapons = require(script.Config.Weapons)
Shared.Economy = require(script.Config.Economy)
Shared.Combat = require(script.Config.Combat)

-- Run numbers: the GDD baseline (Constants) with the Alpha overlay applied.
-- Services construct logic modules with Shared.RunConfig, never with a
-- scattered constant, so flipping AlphaRun.Enabled flips the whole run.
Shared.AlphaRun = require(script.Config.AlphaRun)
Shared.RunConfig = require(script.Config.RunConfig).resolve(Shared.Constants, Shared.AlphaRun)

return Shared
