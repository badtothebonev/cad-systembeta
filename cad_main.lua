_G.CAD_DIAGNOSTICS = {}

local script_running = true

function shutdown()
    log('MAIN', log_levels.INFO, "------ CAD System Shutting Down ------")
    script_running = false
    
    if _G.CAD_DIAGNOSTICS and _G.CAD_DIAGNOSTICS.getDeps then
        local deps = _G.CAD_DIAGNOSTICS.getDeps()
        if deps.ui and deps.ui.shutdown then deps.ui.shutdown() end
        if deps.core and deps.core.shutdown then deps.core.shutdown() end
        if deps.websocket and deps.websocket.disconnect then deps.websocket.disconnect() end
    end
    
    log('MAIN', log_levels.INFO, "Shutdown complete.")
end

function script_unload()
    shutdown()
end


function initialize_cad()
    local script_dir = thisScript().path:match([[^(.*[\/])]])
    package.path = package.path .. ';' .. script_dir .. '?.lua;' .. script_dir .. 'cad_system/?.lua;'
    package.cpath = package.cpath .. ';' .. script_dir .. 'lib/?.dll;'

    local common = require('cad_common_new')
    local log = common.log
    local log_levels = common.log_levels

    log('MAIN', log_levels.INFO, "------ CAD System Initializing ------")
    log('MAIN', log_levels.DEBUG, "Package path updated.")

    log('MAIN', log_levels.INFO, "Loading core libraries...")
    _G.CAD_EVENT_BUS = require('event_bus')
    local copas = require('copas')
    local json = common.json

    local deps = {
        events = _G.CAD_EVENT_BUS,
        copas = copas,
        log = log,
        log_levels = log_levels,
        json = common.json,
        safe_str = common.safe_str,
        cars = common.cars,
        safe_copy = common.safe_copy,
    }

    log('MAIN', log_levels.INFO, "Loading system modules...")
    local modules_to_load = {
        'settings', 'websocket', 'core', 'ui', 'radio_parser'
    }
    for _, name in ipairs(modules_to_load) do
        log('MAIN', log_levels.DEBUG, "Loading module: " .. name)
        
        local require_name
        if name == 'ui' then
            require_name = 'cadui'
        elseif name == 'radio_parser' then
            require_name = '_cadparserradio'
        else
            require_name = 'cad_' .. name
        end

        local ok, module = pcall(require, require_name)
        if ok then
            deps[name] = module
        else
            log('MAIN', log_levels.ERROR, string.format("Failed to load module '%s': %s", require_name, tostring(module)))
            if name == 'settings' or name == 'websocket' or name == 'ui' or name == 'core' then
                error("A critical module failed to load. Stopping script.")
            end
        end
    end
    log('MAIN', log_levels.INFO, "All available modules loaded.")

    log('MAIN', log_levels.INFO, "Initializing modules with dependencies...")
    if deps.settings and deps.settings.initialize then
        log('MAIN', log_levels.DEBUG, "Initializing module: settings")
        deps.settings.initialize()
    end
    for name, module in pairs(deps) do
        if name ~= 'settings' and name ~= 'core' and name ~= 'radio_parser' and type(module) == 'table' and module.initialize then
            log('MAIN', log_levels.DEBUG, "Initializing module: " .. name)
            module.initialize(deps)
        end
    end
    if deps.core and deps.core.initialize then
        log('MAIN', log_levels.DEBUG, "Initializing module: core")
        deps.core.initialize(deps)
    end

    if deps.radio_parser and deps.radio_parser.initialize then
        log('MAIN', log_levels.DEBUG, "Initializing module: radio_parser")
        local ok, err = pcall(deps.radio_parser.initialize, deps)
        if ok then
            log('MAIN', log_levels.INFO, "Radio parser initialized successfully.")
        else
            log('MAIN', log_levels.ERROR, "Radio parser failed to initialize: " .. tostring(err))
        end
    end

    log('MAIN', log_levels.INFO, "Core modules initialized.")

    log('MAIN', log_levels.INFO, "Attempting to connect to WebSocket server...")
    deps.websocket.connect()

    if not deps.core.tryAutoLogin() then
        log('MAIN', log_levels.INFO, "Auto-login failed, manual login required.")
    end

    

    log('MAIN', log_levels.INFO, "Initialization complete. Starting main loop.")

    _G.CAD_DIAGNOSTICS.getDeps = function() return deps end
    log('MAIN', log_levels.INFO, "Dependencies exposed for diagnostics.")

    local vkeys = require 'vkeys'
    while script_running do
        copas.step(0)
        if deps.websocket then
            deps.websocket.process_messages()
        end

        local mdt_key = deps.settings.get('controls_settings', 'open_mdt_key', 'VK_F2')
        local alpr_key = deps.settings.get('controls_settings', 'open_alpr_key', 'VK_1')
        local map_key = deps.settings.get('controls_settings', 'open_map_key', 'VK_M')

        if vkeys[mdt_key] and wasKeyPressed(vkeys[mdt_key]) then
            if deps.ui and deps.ui.isPlayerInPatrolCar and deps.ui.isPlayerInPatrolCar() then
                if deps.ui.toggleMDT then
                    deps.ui.toggleMDT()
                end
            end
        end

        if vkeys[alpr_key] and wasKeyPressed(vkeys[alpr_key]) then
            if deps.ui and deps.ui.toggleALPR then
                deps.ui.toggleALPR()
            end
        end

        if vkeys[map_key] and wasKeyPressed(vkeys[map_key]) then
            if deps.ui and deps.ui.toggleMap then
                deps.ui.toggleMap()
            end
        end

        wait(0)
    end
end

function main()
    lua_thread.create(initialize_cad)
end
