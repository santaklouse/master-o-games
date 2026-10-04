--!strict
--[[
	RunConfig — the GDD baseline (Constants) with the Alpha overlay applied.

	Pure on purpose (no `script`, no requires): the numbers it merges are
	arguments, so the same module runs in Roblox, in the Lune harness and in a
	one-off probe. src/shared/init.lua does the binding once:

		Shared.RunConfig = require(script.Config.RunConfig).resolve(
			Shared.Constants, Shared.AlphaRun
		)

	`Shared.RunConfig` is the table services construct logic modules with
	(MatchStateMachine etc.), so the FSM, the economy and any later UI all read
	the SAME run numbers — the Alpha overlay is not a second copy of the match
	spec, it is an override of it.
]]

local RunConfig = {}

-- base = the GDD baseline table (Constants); alphaRun = the overlay module.
-- Returns a fresh table: callers must never be handed `base` itself, or a
-- resolution would mutate the GDD numbers for everyone.
function RunConfig.resolve(base, alphaRun)
	assert(type(base) == "table", "RunConfig.resolve requires the base config table")
	local resolved = {}
	for key, value in base do
		resolved[key] = value
	end
	if alphaRun == nil or not alphaRun.Enabled then
		return resolved -- AlphaRun.Enabled = false: the untouched GDD run
	end

	local allowed = alphaRun.AllowedFields
	for key, value in alphaRun.Overrides or {} do
		if allowed ~= nil then
			assert(allowed[key], ("AlphaRun.Overrides.%s is not an overridable run number"):format(key))
		end
		assert(base[key] ~= nil, ("AlphaRun.Overrides.%s is not a field of the GDD baseline"):format(key))
		assert(
			type(value) == type(base[key]),
			("AlphaRun.Overrides.%s has type %s but the baseline is %s"):format(key, type(value), type(base[key]))
		)
		resolved[key] = value
	end
	return resolved
end

return RunConfig
