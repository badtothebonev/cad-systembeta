-- Simple, generic event bus system.
-- Allows scripts to communicate without direct dependencies.

local event_bus = {}
local listeners = {}

-- Register a listener for a specific event
function event_bus.register(event_name, callback)
    if not listeners[event_name] then
        listeners[event_name] = {}
    end
    table.insert(listeners[event_name], callback)
end

-- Unregister a listener
function event_bus.unregister(event_name, callback_to_remove)
    if not listeners[event_name] then return end
    
    local listeners_for_event = listeners[event_name]
    for i = #listeners_for_event, 1, -1 do
        if listeners_for_event[i] == callback_to_remove then
            table.remove(listeners_for_event, i)
        end
    end
end

-- Trigger an event, calling all its listeners
function event_bus.trigger(event_name, ...)
    if not listeners[event_name] then return end
    
    local listeners_to_call = {}
    for _, callback in ipairs(listeners[event_name]) do
        table.insert(listeners_to_call, callback)
    end

    for _, callback in ipairs(listeners_to_call) do
        pcall(callback, ...)
    end
end

return event_bus
