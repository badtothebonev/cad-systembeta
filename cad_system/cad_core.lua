
local ffi = require('ffi')
local imgui = require('mimgui')

local events, cad_websocket, json, log, log_levels, settings, copas

local core = {}

-- STATE VARIABLES ############################

core.current_user = nil
core.auth_token = nil
core.current_unit = nil

core.login_window = {
    username = imgui.new.char[64](),
    password = imgui.new.char[64](),
    error_message = "",
    is_logging_in = false
}

-- WEBSOCKET HANDLER ######################

-- WEBSOCKET HANDLER ######################

local function broadcastUnitUpdate()
    if not core.isAuthenticated() or not core.current_unit then
        log('CORE', log_levels.WARN, "broadcastUnitUpdate call ignored: not authenticated or no unit data.")
        return
    end
    
    log('CORE', log_levels.INFO, "Broadcasting local unit info to server for synchronization.")
    
    local request = {
        type = 'unit',
        action = 'form_or_update_crew',
        token = core.getToken(),
        payload = core.current_unit
    }

    -- FINAL FIX: Force-inject the user_id into the payload right before sending.
    -- This ensures that no matter what the UI does, the user_id is always present.
    if core.current_user and core.current_user.id then
        request.payload.user_id = core.current_user.id
        log('CORE', log_levels.INFO, "Final check: Injected user_id (" .. tostring(core.current_user.id) .. ") into outgoing unit payload.")
    else
        log('CORE', log_levels.WARN, "Final check: Could not inject user_id, core.current_user.id is nil.")
    end

    cad_websocket.send(request)
end

local function handle_auth_response(data)
    -- This function now makes the SERVER the single source of truth for the unit.
    local function process_unit_data()
        log('CORE', log_levels.INFO, "Login successful. Fetching authoritative unit info from server...")
        
        local request = {
            type = 'unit',
            action = 'fetch_my_unit',
            token = core.getToken()
        }
        cad_websocket.send(request)
        
        -- The response will be handled by 'handle_unit_response', which will update the state
        -- and save the config file.
    end

    if data.action == 'login' then
        core.login_window.is_logging_in = false
        if data.success then
            log('CORE', log_levels.INFO, "Login successful for user: " .. data.user.username)
            core.current_user = data.user
            core.auth_token = data.token
            
            process_unit_data() -- Process unit data using local-first logic

            settings.set("user_settings", "token", core.auth_token)
            settings.set("user_settings", "currentUser", core.current_user)
            settings.set("user_settings", "username", ffi.string(core.login_window.username))
            settings.save()

            ffi.fill(core.login_window.password, ffi.sizeof(core.login_window.password), 0)
            
            _G.CAD_EVENT_BUS.trigger('auth_login_success')
        else
            core.login_window.error_message = data.error or "Unknown error"
        end
    elseif data.action == 'validateToken' then
        if data.success and data.user then
            log('CORE', log_levels.INFO, "Token validation successful.")
            core.current_user = data.user
            core.auth_token = data.token
            
            process_unit_data() -- Process unit data using local-first logic
            
            _G.CAD_EVENT_BUS.trigger('auth_login_success')
        else
            log('CORE', log_levels.WARN, "Token validation failed.")
            core.auth_token = nil
            core.current_user = nil
            settings.set("user_settings", "token", nil)
            settings.set("user_settings", "currentUser", nil)
            settings.save()
        end
    end
end

local function handle_unit_response(data)
    if data.success and data.payload then
        log('CORE', log_levels.INFO, "Unit operation successful.")
        core.current_unit = data.payload
        settings.saveUnitInfo(core.current_unit)
        settings.save()
        _G.CAD_EVENT_BUS.trigger('cad:unit_updated', data.payload)
    elseif data.success then
        log('CORE', log_levels.WARN, "Unit operation successful but received no payload.")
    else
        log('CORE', log_levels.ERROR, "Unit operation failed: " .. (data.error or "Unknown error"))
        _G.CAD_EVENT_BUS.trigger('cad:unit_error', data.error)
    end
end

local function handle_websocket_message(data_str)
    local ok, data = pcall(json.decode, data_str)
    if not ok or not data or not data.type then return end

    if data.type == 'auth_response' then
        handle_auth_response(data)
    elseif data.type == 'unit_response' then
        handle_unit_response(data)
    elseif data.type == 'calls_response' then
        if data.success and data.action == 'create' then
            log('CORE', log_levels.INFO, message)
        elseif not data.success then
            log('CORE', log_levels.ERROR, error_message)
        end
    elseif data.type == 'bolo_response' then
    end
end

-- PUBLIC API ###############№#####№№№№№№№№№№№№№№№№№##

function core.shutdown()
    log('CORE', log_levels.INFO, "Shutting down core module...")
    core.current_user = nil
    core.auth_token = nil
    core.current_unit = nil
end

function core.login(username, password)
    if not cad_websocket.is_connected() then
        core.login_window.error_message = "Not connected"
        return
    end
    log('CORE', log_levels.INFO, "Attempting login...")
    core.login_window.is_logging_in = true
    cad_websocket.send({ type = "auth", action = "login", username = username, password = password })
end

function core.logout()
    log('CORE', log_levels.INFO, "Logging out.")
    core.current_user = nil
    core.auth_token = nil
    core.current_unit = nil
    settings.set("user_settings", "token", nil)
    settings.set("user_settings", "currentUser", nil)
    settings.save()
    _G.CAD_EVENT_BUS.trigger('auth_logout')
end

function core.isAuthenticated() return core.current_user and core.auth_token end
function core.getToken() return core.auth_token end

function core.loadAuthData()
    log('CORE', log_levels.INFO, "Loading auth data from settings...")
    local loaded_username = settings.get("user_settings", "username", "")
    ffi.copy(core.login_window.username, loaded_username)
    core.auth_token = settings.get("user_settings", "token", nil)
    if core.auth_token then
        log('CORE', log_levels.INFO, "Found stored auth token.")
    end
end

function core.tryAutoLogin()
    log('CORE', log_levels.INFO, "Checking for stored token for auto-login...")
    core.auth_token = settings.get("user_settings", "token", nil)
    core.current_user = settings.get("user_settings", "currentUser", nil)

    if core.auth_token and core.current_user then
        log('CORE', log_levels.INFO, "Found stored token and user data. Auto-login will proceed upon connection.")
        core.auto_login_pending = true
        return true
    else
        log('CORE', log_levels.INFO, "No stored token or user data found. Manual login required.")
        return false
    end
end

-- EVENT LISTENERS ########№№№№№№№№№№№№№№№№№№№№№№№№#######################

local function handle_data_error(err_data)
    if err_data and err_data.error and type(err_data.error) == 'string' and err_data.error:find("Invalid or expired token") then
        log('CORE', log_levels.WARN, "Server rejected token. Forcing logout.")
        core.logout()
    end
end

local function handleAddCall(callData)
    log('CORE', log_levels.DEBUG, "DEBUG: handleAddCall triggered at the very top.")
    if not core.isAuthenticated() then
        log('CORE', log_levels.WARN, "handleAddCall ignored: user not authenticated.")
        return
    end

    log('CORE', log_levels.INFO, "handleAddCall event received. Sending to server.")

    local request = {
        type = 'calls',
        action = 'create',
        token = core.getToken(),
        payload = {
            call_id = callData.server_call_id,
            server_call_id = callData.server_call_id,
            summary = callData.summary,
            location = callData.location,
            incident_details = callData.incident_details,
            caller_name = callData.caller_name,
            phone_number = callData.phone_number
        } 
    }
    
    cad_websocket.send(request)
end

local function handleAddBolo(boloData)
    log('CORE', log_levels.DEBUG, "DEBUG: handleAddBolo triggered at the very top.")
    if not core.isAuthenticated() then
        log('CORE', log_levels.WARN, "handleAddBolo ignored: user not authenticated.")
        return
    end

    log('CORE', log_levels.INFO, "handleAddBolo event received. Sending to server.")

    local request = {
        type = 'bolos',
        action = 'create',
        token = core.getToken(),
        payload = boloData
    }
    
    cad_websocket.send(request)
end

--  INITIALIZATION #########№№№№№№№№№№#######################

function core.initialize(deps)
    cad_websocket = deps.websocket
    json = deps.json
    log = deps.log
    log_levels = deps.log_levels
    settings = deps.settings
    copas = deps.copas
    
    core.loadAuthData()

    _G.CAD_EVENT_BUS.register('websocket_message', handle_websocket_message)
    _G.CAD_EVENT_BUS.register('cad:data_error', handle_data_error)
    _G.CAD_EVENT_BUS.register('cad:addCall', handleAddCall)
    _G.CAD_EVENT_BUS.register('cad:addBolo', handleAddBolo)

    _G.CAD_EVENT_BUS.register('websocket_connected', function()
        if core.auto_login_pending then
            log('CORE', log_levels.INFO, "WebSocket connected, completing auto-login.")
            core.auto_login_pending = false
            _G.CAD_EVENT_BUS.trigger('auth_login_success')
        end
    end)

    log('CORE', log_levels.INFO, "Module initialized.")
end

return core