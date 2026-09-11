--!strict
--[[
	BEACON PROTOCOL — server bootstrap (ServerScriptService.Server).
	Loads every Knit service in src/server/Services and starts Knit.

	Layout (mirrors Knit convention):
		ServerScriptService.Server          <- this Script
			.Services.<Name>Service.lua     <- Knit services (AddServices)
			.Logic.<module>.lua              <- pure server logic (NOT services)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Knit"))

-- Register all service modules (direct children of ./Services only —
-- NEVER AddServicesDeep here, or the .Logic modules would be registered
-- as services and break Knit's service discovery).
Knit.AddServices(script.Services)

-- Boot. Knit.Start resolves after KnitInit of every service has run and
-- re-fires service remotes into ReplicatedStorage.Services.
Knit.Start():catch(warn)

print("[BEACON PROTOCOL] Server booted with Knit", Knit.Version and Knit.Version() or "")
