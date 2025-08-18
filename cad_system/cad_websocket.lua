
local success, ws_lib_or_err = pcall(require, 'websocketsamp')
local ws_lib = success and ws_lib_or_err or nil
local err = not success and ws_lib_or_err or nil

local common, events, settings, json, log, log_levels, copas

local M = {}

local connection_status = 'DISCONNECTED' 
local receive_thread = nil
local message_queue = {} 

local connection_config = require('cad_connection')

local function get_server_url()
    if connection_config and connection_config.websocket_url then
        local url = connection_config.websocket_url
        log('WEBSOCKET', log_levels.INFO, "Server URL found: " .. url)
        return url
    else
        log('WEBSOCKET', log_levels.ERROR, "CRITICAL: WebSocket URL not found in cad_connection.lua!")
        return nil
    end
end

local function flush_queue()
    if connection_status ~= 'CONNECTED' then return end
    if #message_queue == 0 then return end

    log('WEBSOCKET', log_levels.INFO, "Flushing message queue (" .. #message_queue .. " messages)...")
    for i, json_data in ipairs(message_queue) do
        if ws_lib then
            ws_lib.SendMessage(json_data)
            log('WEBSOCKET', log_levels.DEBUG, "Sent queued data: " .. json_data)
        end
    end
    message_queue = {}
end

function M.send(data)
    local ok, json_data = pcall(json.encode, data)
    if not ok then
        log('WEBSOCKET', log_levels.ERROR, "Failed to encode JSON data for sending: " .. tostring(json_data))
        return false, "JSON encoding error"
    end

    table.insert(message_queue, json_data)
    log('WEBSOCKET', log_levels.DEBUG, "Queued data for sending: " .. json_data)

    if connection_status == 'CONNECTED' then
        flush_queue()
    else
        log('WEBSOCKET', log_levels.WARN, "Queued message while disconnected. Will send upon connection.")
    end
    
    return true
end

function M.process_messages()
    if not ws_lib then return end

    local status = ws_lib.GetConnectionStatus()

    if status == 'OPEN' and connection_status ~= 'CONNECTED' then
        log('WEBSOCKET', log_levels.INFO, "WebSocket connection ESTABLISHED.")
        connection_status = 'CONNECTED'
        events.trigger('websocket_connected')
        flush_queue() 
    elseif (status == 'CLOSING' or status == 'CLOSED') and connection_status == 'CONNECTED' then
        log('WEBSOCKET', log_levels.WARN, "WebSocket connection has been closed.")
        connection_status = 'DISCONNECTED'
        events.trigger('websocket_disconnected', 1006, "Connection closed by server or network.")
        return 
    end

    if connection_status == 'CONNECTED' then
        local message = ws_lib.GetMessage()
        if message and message ~= '' then
            log('WEBSOCKET', log_levels.DEBUG, "Received data: " .. message)
            events.trigger('websocket_message', message)
        end
    end
end

function M.connect()
    if not ws_lib then
        log('WEBSOCKET', log_levels.FATAL, "websocketsamp library is not available! Check for websocketsamp.dll in /lib/. Error: " .. tostring(err))
        return
    end

    if connection_status == 'CONNECTING' or connection_status == 'CONNECTED' then
        log('WEBSOCKET', log_levels.WARN, "Connect called while already connecting or connected. Ignoring.")
        return
    end

    local url = get_server_url()
    if not url then return end

    log('WEBSOCKET', log_levels.INFO, "Attempting to connect to " .. url)
    connection_status = 'CONNECTING'
    events.trigger('websocket_connecting')

    ws_lib.Connect(url)
end

function M.disconnect(code, reason)
    if not ws_lib or connection_status == 'DISCONNECTED' then return end
    log('WEBSOCKET', log_levels.INFO, "Manual disconnect called.")
    
    ws_lib.Disconnect()
    
    if receive_thread then
        lua_thread.kill(receive_thread)
        receive_thread = nil
    end
    
    connection_status = 'DISCONNECTED'
    events.trigger('websocket_disconnected', code or 1000, reason or "Manual disconnect")
end

function M.is_connected()
    return connection_status == 'CONNECTED'
end

function M.get_status()
    return connection_status
end

function M.initialize(deps)
    events = deps.events
    settings = deps.settings
    json = deps.json
    log = deps.log
    log_levels = deps.log_levels
    copas = deps.copas
    
    if not ws_lib then
        log('WEBSOCKET', log_levels.FATAL, "Module could not be initialized because 'websocketsamp' library failed to load. Error: " .. tostring(err))
    else
        log('WEBSOCKET', log_levels.INFO, "Module initialized with 'websocketsamp' library.")
    end
end

return M