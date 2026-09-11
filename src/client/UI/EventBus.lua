--!strict
--[[
	Client/UI/EventBus.lua — the ONE place client UI binds to (Phase 1
	contract). MatchController (below) subscribes to every Knit service
	signal and re-emits them here with typed payloads. The UI/UX designer
	should NEVER touch Knit services directly for Phase 2 screens:

		local EventBus = require(ReplicatedStorage.Shared) -- no
		local EventBus = require(script.Parent.UI.EventBus) -- controller sibling

	API:
		EventBus.Subscribe(eventName, fn) -> disconnect
		EventBus.Publish(eventName, payload)  (internal, called by MatchController)
	Event names + payloads: see README "UI event contract" — they match the
	Knit signal names and the MatchStateMachine events 1:1.
]]

-- Minimal inline signal (client-safe; no Roblox instances needed).
local EventBus = { _listeners = {} }

function EventBus.Subscribe(eventName, fn)
	assert(type(fn) == "function", "EventBus.Subscribe expects a function")
	local list = EventBus._listeners[eventName]
	if list == nil then
		list = {}
		EventBus._listeners[eventName] = list
	end
	table.insert(list, fn)
	local closed = false
	return function()
		if closed then
			return
		end
		closed = true
		for i = #list, 1, -1 do
			if list[i] == fn then
				table.remove(list, i)
				break
			end
		end
	end
end

function EventBus.Publish(eventName, payload)
	local list = EventBus._listeners[eventName]
	if list == nil then
		return
	end
	for _, fn in table.clone(list) do
		task.spawn(fn, payload)
	end
end

return EventBus
