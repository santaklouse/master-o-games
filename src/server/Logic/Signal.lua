--!strict
-- Roblox provides the global `task` library; standalone Luau does not.
-- Rebinding through _G keeps strict analysis green while letting headless
-- tests inject a scheduler (see tools/phase1_check.lua).
local task = _G.task

--[[
    Signal — minimal pure-Luau event emitter used by server Logic modules.
    No Roblox dependencies (Instance.new("BindableEvent") is overkill for
    these internal seams and would break headless testing). Interface is
    mirrored on purpose: Connect(...) -> (disconnect function), Fire(...),
    Once(..). Fired arguments are FORWARDED to every listener; listener
    errors are isolated (one bad listener cannot kill the match loop).

    Knit REMOTE signals (client-facing) are created separately in each
    service's Client table — this Signal is only for intra-server wiring.
]]

local Signal = {}
Signal.__index = Signal

function Signal.new()
	local self = setmetatable({ _listeners = {} }, Signal)
	return self
end

function Signal:Connect(listener)
	assert(type(listener) == "function", "Signal listener must be a function")
	table.insert(self._listeners, listener)
	local closed = false
	return function()
		if closed then
			return
		end
		closed = true
		for i = #self._listeners, 1, -1 do
			if self._listeners[i] == listener then
				table.remove(self._listeners, i)
				break
			end
		end
	end
end

function Signal:Once(listener)
	local disconnect
	disconnect = self:Connect(function(...)
		disconnect()
		listener(...)
	end)
	return disconnect
end

function Signal:Fire(...)
	local args = { ... }
	local listeners = table.clone(self._listeners)
	for _, listener in listeners do
		task.spawn(function()
			-- isolate listener failures; args is captured so the inner
			-- function stays non-vararg (varargs cannot cross that boundary)
			pcall(listener, table.unpack(args))
		end)
	end
end

function Signal:DisconnectAll()
	self._listeners = {}
end

function Signal:GetListenerCount()
	return #self._listeners
end

return Signal
