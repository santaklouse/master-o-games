--!strict
--[[
    BEACON PROTOCOL — client bootstrap (StarterPlayerScripts.Client).
    Loads controllers and starts Knit. The UI itself is deliberately NOT
    built in Phase 1 (see README); MatchController wires the Knit service
    signals to Client/UI/EventBus.lua, which is the single seam the
    UI/UX designer binds to.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Knit"))

-- Register controllers (direct children of ./Controllers only).
Knit.AddControllers(script.Controllers)

-- Boot. Knit.Start resolves after KnitInit of every controller has run.
Knit.Start():catch(warn)

print("[BEACON PROTOCOL] Client booted")
