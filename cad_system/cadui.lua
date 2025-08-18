local cadui_module = {}

local ffi = require('ffi')
local bit = require('bit')
samp_events = require 'samp.events'
imgui = require 'mimgui'
local memory = require 'memory'
local vkeys = require 'vkeys'
local addons = require 'ADDONS'
local sampfuncs = require 'sampfuncs' 

local fonts = {}
local claimed_vehicle = nil
local assigned_vehicle_id = nil

local events, core, cad_websocket, json, settings, copas, log, log_levels, safe_str, cars, safe_copy

-- #################### DATA HANDLING (WebSocket) #####################

local request_callbacks = {}
local request_id_counter = 0

local function send_ws_request(type, action, payload, callback)
    if not cad_websocket or not cad_websocket.is_connected() then
        log('UI', log_levels.ERROR, "send_ws_request failed: Not connected.")
        if callback then callback(nil, "Not connected") end
        return
    end
    request_id_counter = request_id_counter + 1
    local request_id = "ui_req_" .. request_id_counter
    if callback then request_callbacks[request_id] = callback end
    
    local data_to_send = {
        type = type, action = action,
        request_id = request_id, payload = payload
    }
    local token = core.getToken()
    if token then
        data_to_send.token = token
    end
    log('UI', log_levels.DEBUG, string.format("Sending WS request: %s/%s (ID: %s)", type, action, request_id))
    cad_websocket.send(data_to_send)
end

local function merge_unit_data(local_unit, server_unit)
    for k, v in pairs(server_unit) do
        if v ~= nil and v ~= "" then
            if type(v) ~= "number" or v ~= 0 or (local_unit[k] == nil) then
                local_unit[k] = v
            end
        end
    end
    return local_unit
end

local function handle_websocket_message(data_str)
    local ok, response = pcall(json.decode, data_str)
    if not ok or not response or not response.type then
        log('UI', log_levels.WARN, "Received invalid WebSocket message or JSON.")
        return
    end

    if response.request_id and request_callbacks[response.request_id] then
        log('UI', log_levels.DEBUG, "Handling callback for request ID: " .. response.request_id)
        local callback = request_callbacks[response.request_id]
        request_callbacks[response.request_id] = nil
        pcall(callback, response.success and response or nil, not response.success and (response.error or "Unknown error"))
        return
    end

    if response.type == 'data_broadcast' then
        log('UI', log_levels.INFO, string.format("Received broadcast for '%s'. Requesting full data refresh to sync UI.", response.dataType))
        forceDataRefresh()
        return
    elseif response.type == 'map_update' then
        handle_map_update(response)
        return
    elseif response.type == 'unit_update' then
        local updated_unit = response.payload
        if not updated_unit or not updated_unit.id then
            log('UI', log_levels.WARN, 'Received unit_update broadcast with invalid payload.')
            return
        end

        log('UI', log_levels.INFO, 'Received unit_update for unit ID: ' .. tostring(updated_unit.unitID or updated_unit.id))

        local unit_found = false
        for i, unit in ipairs(data_storage.units) do
            if unit.id == updated_unit.id then
                data_storage.units[i] = merge_unit_data(unit, updated_unit)
                unit_found = true
                log('UI', log_levels.DEBUG, 'Updated existing unit: ' .. tostring(updated_unit.unitID or updated_unit.id))
                break
            end
        end

        if not unit_found then
            table.insert(data_storage.units, updated_unit)
            log('UI', log_levels.DEBUG, 'Added new unit: ' .. tostring(updated_unit.unitID or updated_unit.id))
        end

        if core and core.current_unit and core.current_unit.id == updated_unit.id then
            log('UI', log_levels.DEBUG, 'Received update for our own unit. Syncing UI buffers.')
            core.current_unit = merge_unit_data(core.current_unit, updated_unit)

            safe_copy(unitInfoBuffers.unitID, core.current_unit.unitID or "")
            unitInfoBuffers.unitType[0] = core.current_unit.unitType or 0
            safe_copy(unitInfoBuffers.officer1_name, core.current_unit.officer1_name or "")
            safe_copy(unitInfoBuffers.officer2_name, core.current_unit.officer2_name or "")
            unitInfoBuffers.status[0] = core.current_unit.status or 4
            safe_copy(unitInfoBuffers.vehiclePlate, core.current_unit.vehiclePlate or "")
            unitInfoBuffers.division[0] = core.current_unit.division or 0
            safe_copy(unitInfoBuffers.notes, core.current_unit.notes or "")
        end
    end
end

local wanted_plates_list = {}
local new_wanted_plate_buffer = imgui.new.char[32]()
local alpr_is_wanted_plate = false
alpr_flash_end_time = os.clock() + 5
alpr_last_wanted_plate = ""
alpr_wanted_sound = nil
panic_sound = nil
last_map_window_pos = nil

local threads_started = false

local UI = {
    mdt = imgui.new.bool(false),
    bolo_editor = imgui.new.bool(false),
    bolo_creator_window = imgui.new.bool(false),
    alpr_window = imgui.new.bool(false),
    alpr_log_window = imgui.new.bool(false),
    login_window = imgui.new.bool(false),
    map_window = imgui.new.bool(false)
}

local map_zoom = 1.0
local map_max_zoom = 4.0
local map_min_zoom = 1.0
local map_offset_x = 0.0
local map_offset_y = 0.0

local map_tile_textures = {
    standard = {},
    k = {}
}


local loginBuffers = {
    username = imgui.new.char[64](),
    password = imgui.new.char[64](),
    error = "",
    loading = false
}

local keyBindBuffers = {
    mdt = imgui.new.char[32](),
    alpr = imgui.new.char[32](),
    map = imgui.new.char[32]()
}

local key_being_bound = nil

alpr_scan_log = {}
local selected_alpr_log_index = nil
alpr_log_comment_buffer = imgui.new.char[256]()
local last_alpr_scan_time = 0

local registerBuffers = {
    username = imgui.new.char[64](),
    password = imgui.new.char[64](),
    password_confirm = imgui.new.char[64](),
    full_name = imgui.new.char[128](),
    badge_number = imgui.new.char[32](),
    division = imgui.new.int(0),
    error = "",
    success_message = "",
    loading = false
}

--alpr
local patrol_cars = { 596, 597, 598, 599 }
local distance_car_search = 15
alpr_current_scan = { model = "Scanning...", plate = "---", driver = "---", found = false }
drivers = {}


samp_events.onPlayerSync = function(playerId, data)
    if data.vehicleId and data.vehicleId > 0 then
        drivers[data.vehicleId] = { playerId, os.time() }
    end
end

samp_events.onVehicleSync = function(playerId, vehicleId, data)
    drivers[vehicleId] = { playerId, os.time() }
end

function getplate(vehicleId)
    local vehicleId = tonumber(vehicleId)
    if not vehicleId then return "" end
    local handle = sampGetBase() + 0x21A0F8
    handle = memory.getint32(handle, false)
    handle = memory.getint32(handle + 0x3CD, false)
    handle = memory.getint32(handle + 0x1C, false)
    handle = (handle + 0x1134) + (vehicleId * 4)
    handle = memory.getint32(handle, false)
    handle = handle + 0x93
    local str = memory.tostring(handle, 20, false)
    return str
end



function getAngleBetweenPoints(x1, y1, x2, y2)
    local angle = -math.deg(math.atan2(x2 - x1, y2 - y1))
    if angle < 0 then angle = angle + 360.0 end
    return angle
end

function cadui_module.isPlayerInPatrolCar()
    if isCharInAnyCar(PLAYER_PED) then
        local vehicleHandle = storeCarCharIsInNoSave(PLAYER_PED)
        local vehicleModel = getCarModel(vehicleHandle)
        for _, patrolCarModel in ipairs(patrol_cars) do
            if vehicleModel == patrolCarModel then
                return true
            end
        end
    end
    return false
end

-- #################### REUSABLE UI COMPONENTS ########################

function renderLabeledText(label, text, label_color, text_color)
    label_color = label_color or imgui.ImVec4(1,1,0,1)
    text_color = text_color or imgui.ImVec4(1,1,1,1)
    imgui.TextColored(label_color, label)
    imgui.SameLine()
    imgui.TextColored(text_color, text)
end

function renderInfoBlock(title, data_table)
    imgui.Text(title)
    imgui.Separator()
    for _, item in ipairs(data_table) do
        if item.label and item.value then
            renderLabeledText(item.label, tostring(item.value), item.label_color, item.value_color)
            if item.separator then
                imgui.Separator()
            end
        end
    end
end

function renderTable(id, columns, data, row_renderer, selection_state)
    imgui.Columns(#columns, id, true)
    for i, col in ipairs(columns) do
        imgui.SetColumnWidth(i - 1, col.width)
    end

    for _, col in ipairs(columns) do
        imgui.Text(col.name)
        imgui.NextColumn()
    end
    imgui.Separator()

    for i, item in ipairs(data) do
        local is_selected = selection_state and selection_state.selected_index == i
        if imgui.Selectable("##row" .. tostring(item.id or i), is_selected, 1, imgui.new('ImVec2', 0, 20)) then
            if selection_state then
                selection_state.selected_index = i
            end
        end
        imgui.SameLine()
        
        row_renderer(item, i)
        imgui.NextColumn()
    end
    imgui.Columns(1)
end

function drawOutlinedText(draw_list, pos, text, text_color, outline_color)
    outline_color = outline_color or 0xFF000000 -- Default to black
    draw_list:AddText(imgui.new('ImVec2', pos.x - 1, pos.y), outline_color, text)
    draw_list:AddText(imgui.new('ImVec2', pos.x + 1, pos.y), outline_color, text)
    draw_list:AddText(imgui.new('ImVec2', pos.x, pos.y - 1), outline_color, text)
    draw_list:AddText(imgui.new('ImVec2', pos.x, pos.y + 1), outline_color, text)
    draw_list:AddText(pos, text_color, text)
end



function updateALPRData()
    alpr_current_scan = { model = "Scanning...", plate = "---", driver = "---", found = false }
    if not isCharInAnyCar(PLAYER_PED) then alpr_current_scan.model = "Not in a vehicle."; return end
    
    local ok, playerCarHandle, playerCarModel, player_car_id = pcall(function()
        local handle = storeCarCharIsInNoSave(PLAYER_PED)
        local model = getCarModel(handle)
        local _, id = sampGetVehicleIdByCarHandle(handle)
        return handle, model, id
    end)
    if not ok then alpr_current_scan.model = "Error getting player vehicle."; return end

    local isPatrolCar = false
    for _, id in ipairs(patrol_cars) do if id == playerCarModel then isPatrolCar = true; break end end
    if not isPatrolCar then alpr_current_scan.model = "Not in a valid patrol car."; return end

    local target_car_data = { distance = distance_car_search, vehicleId = -1 }
    local pX, pY, pZ = getCharCoordinates(PLAYER_PED)
    local fX, fY, fZ = getOffsetFromCharInWorldCoords(PLAYER_PED, 0.0, 7.0, 0.0)

    local max_vehicles = 1000 
    if sampGetVehiclePoolSize then 
        max_vehicles = sampGetVehiclePoolSize()
    end

    for vehicleId = 0, max_vehicles do
        local result, vehicleHandle = sampGetCarHandleBySampVehicleId(vehicleId)
        if result and vehicleId ~= player_car_id and doesVehicleExist(vehicleHandle) then
            local success, data = pcall(function()
                local cX, cY, cZ = getCarCoordinates(vehicleHandle)
                local dist = getDistanceBetweenCoords3d(fX, fY, fZ, cX, cY, cZ)
                return { x=cX, y=cY, z=cZ, distance=dist }
            end)

            if success and data.distance < target_car_data.distance then
                local angle = getAngleBetweenPoints(pX, pY, data.x, data.y)
                local heading = getCharHeading(PLAYER_PED)
                local angleDiff = math.abs(heading - angle)
                if angleDiff > 180 then angleDiff = 360 - angleDiff end
                if angleDiff < 45 then
                    target_car_data.distance = data.distance
                    target_car_data.vehicleId = vehicleId
                    target_car_data.vehicleModel = getCarModel(vehicleHandle)
                end
            end
        end
    end

    if target_car_data.vehicleId > -1 then
        local plate = getplate(target_car_data.vehicleId):gsub("%[", ""):gsub("%]", ""):gsub("^%s*(.-)%s*$", "%1")
        local vehicleModelName = (cars[target_car_data.vehicleModel] or "Unknown Model")
        local driverId = -1
        local driverName = "No driver"

        if drivers[target_car_data.vehicleId] ~= nil and (os.time() - drivers[target_car_data.vehicleId][2] < 2 or sampIsPlayerPaused(drivers[target_car_data.vehicleId][1]) ) then
            driverId = drivers[target_car_data.vehicleId][1]
            if sampIsPlayerConnected(driverId) then
                local _, driverPedHandle = sampGetCharHandleBySampPlayerId(driverId)
                if _ then
                    driverName = sampGetPlayerNickname(driverId)
                end
            end
        end
        
        alpr_current_scan = { model = vehicleModelName, plate = plate, driver = driverName, found = true }

        

        local is_wanted = false
        local cleaned_plate = plate:gsub("[%z%s]", ""):upper()
        
        log('ALPR', log_levels.DEBUG, 'Checking plate: ' .. plate .. ' (Cleaned: ' .. cleaned_plate .. ')')

        for i, wanted in ipairs(wanted_plates_list) do
            local cleaned_wanted_plate = wanted.plate:gsub("[%z%s]", ""):upper()
            if cleaned_wanted_plate == cleaned_plate then
                is_wanted = true
                log('ALPR', log_levels.INFO, 'MATCH FOUND for plate: ' .. plate)
                break
            end
        end

        if is_wanted then
            if not alpr_is_wanted_plate then 
                log('ALPR', log_levels.INFO, 'Plate is wanted and was not previously wanted. Playing sound.')
                if alpr_wanted_sound then
                    setAudioStreamState(alpr_wanted_sound, 1)
                end
            end
            alpr_is_wanted_plate = true
        else
            alpr_is_wanted_plate = false
        end

        local already_logged = false
        for _, entry in ipairs(alpr_scan_log) do
            if entry.plate == plate then
                already_logged = true
                break
            end
        end

        if plate ~= "" and not already_logged then
            local scan_entry = {
                model = vehicleModelName, plate = plate, driver = driverName,
                timestamp = os.time(), notes = ""
            }
            table.insert(alpr_scan_log, 1, scan_entry)
            if #alpr_scan_log > 100 then table.remove(alpr_scan_log) end
        end
    else
        alpr_current_scan.model = "No vehicle detected in range."
        alpr_is_wanted_plate = false 
    end
end

local fetchMyUnitData, fetchCalls, fetchBolos, fetchUnits, fetchWantedPlates

function forceDataRefresh()
    if not core.isAuthenticated() then return end
    log('UI', log_levels.INFO, 'Requesting all data from server via forceDataRefresh.')
    send_ws_request('data', 'fetch_all', {}, function(data, err) 
        if err then 
            log('UI', log_levels.ERROR, 'forceDataRefresh callback failed: ' .. tostring(err))
            events.trigger('cad:data_error', { error = err })
            return
        end
        if data and data.payload then
            log('UI', log_levels.INFO, 'forceDataRefresh callback successful. Triggering event.')
            events.trigger('cad:data_refreshed', data.payload)
        else
            log('UI', log_levels.WARN, 'forceDataRefresh callback: No data or payload received.')
            if data and data.error then
                events.trigger('cad:data_error', { error = data.error })
            end
        end
    end)
end

function sendPositionUpdate()
    if not core.isAuthenticated() or not core.current_unit then
        return
    end

    local playerPed = PLAYER_PED
    if not (playerPed and doesCharExist(playerPed)) then return end

    if isCharInAnyCar(playerPed) then
        local vehicleHandle = storeCarCharIsInNoSave(playerPed)
        local ok, vehicleId = sampGetVehicleIdByCarHandle(vehicleHandle)
        
        if ok then
            local x, y, z = getCarCoordinates(vehicleHandle)
            local heading = getCarHeading(vehicleHandle)
            local payload = {
                pos_x = x,
                pos_y = y,
                pos_z = z,
                heading = heading,
                vehicleId = vehicleId
            }
            send_ws_request('unit', 'unit_update_position', payload)
        end
    end
end

function broadcastUnitStatus(extra_params)
    extra_params = extra_params or {}
    updateCurrentLocation()
    local payload = {
        unitID = safe_str(unitInfoBuffers.unitID),
        unitType = unitInfoBuffers.unitType[0],
        officer1_name = safe_str(unitInfoBuffers.officer1_name),
        officer2_name = safe_str(unitInfoBuffers.officer2_name),
        status = unitInfoBuffers.status[0],
        vehiclePlate = safe_str(unitInfoBuffers.vehiclePlate),
        division = unitInfoBuffers.division[0],
        notes = safe_str(unitInfoBuffers.notes),
        location = currentLocation,
        is_active = (unitInfoBuffers.status[0] ~= 4),
        vehicleId = assigned_vehicle_id, 
        user_id = core.current_user and core.current_user.id or nil
    }
    for k, v in pairs(extra_params) do payload[k] = v end

    local action = 'form_or_update_crew'

    log('UI', log_levels.INFO, "--- BROADCASTING UNIT STATUS ---")
    log('UI', log_levels.INFO, "Action: " .. action)
    log('UI', log_levels.INFO, "Payload: " .. json.encode(payload))

    send_ws_request('unit', action, payload, function(data, err) 
        if err then
            addUnitLogEntry("ERROR", "Failed to broadcast unit status: " .. err)
        elseif data and data.success and data.payload then
            log('UI', log_levels.INFO, "Unit status broadcast successful, payload received.")
            events.trigger('cad:unit_updated', data.payload)
        end
    end)
end

function startBackgroundThreads()
    if threads_started then return end
    threads_started = true
    log('UI', log_levels.INFO, 'Starting background threads (heartbeat and position updates).')

    lua_thread.create(function()
        wait(5000)
        while threads_started do
            if core.isAuthenticated() then
                broadcastUnitStatus()
            end
            wait(15000)
        end
    end)

    lua_thread.create(function()
        while threads_started do
            wait(4000)
            if core.isAuthenticated() then
                sendPositionUpdate()
            end
        end
    end)
end


local radioConfig = {}

local data_storage = {
    calls = {},
    bolos = {},
    units = {},
    wanted_plates = {},
    global_event_log = {},
    latest_unit_data = nil
}

local last_known_call_id = 0
local last_unit_update_timestamp = 0 
local selected_bolo_index = nil 
local bolo_note_buffer = imgui.new.char[256]()

local newBoloData = {
    id = imgui.new.char[128](),
    type = imgui.new.int(0), 
    subject_name = imgui.new.char[128](),
    last_location = imgui.new.char[128](),
    description = imgui.new.char[512](),
    crime_summary = imgui.new.char[512]()
}

local boloTypes = { "Person", "Vehicle" }
local boloStatuses = { "In Progress", "Clear", "In Custody" }
local boloStatusColors = {
    ["In Progress"] = imgui.ImVec4(1.0, 0.6, 0.0, 1.0), -- Orange
    ["Clear"] = imgui.ImVec4(0.2, 0.8, 0.2, 1.0),       -- Green
    ["In Custody"] = imgui.ImVec4(0.2, 0.5, 1.0, 1.0)    -- Blue
}
local boloTypes_c = nil
local boloStatuses_c = nil

local callStatusTypes = { "Pending", "En-route", "Clear" }
local callStatusColors = { Pending = imgui.ImVec4(1.0, 0.8, 0.0, 1.0), ["En-route"] = imgui.ImVec4(0.0, 0.6, 1.0, 1.0), Clear = imgui.ImVec4(0.2, 0.8, 0.2, 1.0) }
local selected_call_index = nil
local selected_unit_index = nil
local call_note_buffer = imgui.new.char[256]()
local isEditingUnitInfo = false
local unitInfo = { unitID = "2L20", unitType = 0, officer1_name = "John Doe", officer1_id = "12345", officer2_name = "", officer2_id = "", status = 0, vehiclePlate = "12ABC345", division = 0, shift = 0, notes = "Taser, Bodycam" }
local unitInfoBuffers = {
    unitID = imgui.new.char[32](unitInfo.unitID), unitType = imgui.new.int(unitInfo.unitType),
    officer1_name = imgui.new.char[64](unitInfo.officer1_name), officer1_id = imgui.new.char[32](unitInfo.officer1_id),
    officer2_name = imgui.new.char[64](unitInfo.officer2_name), officer2_id = imgui.new.char[32](unitInfo.officer2_id),
    status = imgui.new.int(unitInfo.status), vehiclePlate = imgui.new.char[32](unitInfo.vehiclePlate),
    division = imgui.new.int(unitInfo.division), shift = imgui.new.int(unitInfo.shift),
    notes = imgui.new.char[256](unitInfo.notes) 
}
local comboBoxData = {
    unitType = { "A/L: Basic Patrol Unit", "S/SL: Senior Lead Officer Unit", "XL/X: Extra Basic Patrol Unit", "W: Area Detective Unit", "T/TL: Collision Investigation Unit", "M: Traffic Enforcement Motorcycle Unit", "G: Area Gang Enforcement Detail Unit", "4K: Robbery-Homicide Division", "5K: Gang and Narcotics Division", "4I: Internal Affairs Division", "E: Traffic Enforcement Unit", "R: Metropolitan Division CS", "AIR: Air Support Division Unit" },
    status = { "Available / 10-8", "En Route", "On Scene / C6", "Busy", "Out of Service" },
    shift = { "Watch I (22:00-06:00)", "Watch II (06:00-14:00)", "Watch III (14:00-22:00)" },
    division = { "RAMPART AREA", "77'th STREET AREA", "METROPOLITAN DIVISION" }
}

local divisionOptions_c, unitTypeOptions_c, shiftOptions_c = nil, nil, nil
local unitActivityLog = { { time = os.date("%H:%M:%S"), event = "SYSTEM", details = "CAD/MDT Initialized" } }
local selectedPatrolUnit = nil
local currentLocation = "Updating..."
local lastLocationUpdate = 0
local LOCATION_UPDATE_INTERVAL = 2000 

function getCityNameFromCoords(x, y, z)
    if x >= -3000 and x <= -1200 and y >= -2000 and y <= 1500 then
        return "Los Santos"
    elseif x >= -3000 and x <= -1200 and y >= -1000 and y <= 500 then
        return "San Fierro"
    elseif x >= 500 and x <= 3000 and y >= 500 and y <= 3000 then
        return "Las Venturas"
    else
        return "San Andreas"
    end
end

function getShortLocationCode(x, y, z)
    local zone = getNameOfZone(x, y, z)
    if not zone or zone == "" then
        return "N/A"
    end
    local zone_codes = {
        ["Rodeo"] = "ROD", ["Verona Beach"] = "VER", ["Santa Monica Beach"] = "SMB", ["Venice Beach"] = "VEN", ["Downtown Los Santos"] = "DTLS",
        ["East Los Santos"] = "ELS", ["Glen Park"] = "GP", ["Idlewood"] = "IDL", ["Jefferson"] = "JEF", ["Las Colinas"] = "LC", ["Little Mexico"] = "LM",
        ["Los Flores"] = "LF", ["Marina"] = "MAR", ["Market"] = "MKT", ["Mulholland"] = "MUL", ["Pershing Square"] = "PS", ["Richman"] = "RCH",
        ["Santa Maria Beach"] = "SMB", ["Temple"] = "TMP", ["Unity Station"] = "US", ["Verdant Bluffs"] = "VB", ["Vinewood"] = "VW", ["Willowfield"] = "WF"
    }
    return zone_codes[zone] or zone:sub(1, 3):upper()
end

function updateCurrentLocation()
    if os.clock() * 1000 - lastLocationUpdate < LOCATION_UPDATE_INTERVAL then
        return
    end
    
    if isCharInAnyCar(PLAYER_PED) then
        local vehicle = storeCarCharIsInNoSave(PLAYER_PED)
        local x, y, z = getCarCoordinates(vehicle)
        local zone = getNameOfZone(x, y, z)
        local area = getCityNameFromCoords(x, y, z)
        currentLocation = string.format("%s, %s", zone, area)
    else
        local x, y, z = getCharCoordinates(PLAYER_PED)
        local zone = getNameOfZone(x, y, z)
        local area = getCityNameFromCoords(x, y, z)
        currentLocation = string.format("%s, %s (On foot)", zone, area)
    end
    
    lastLocationUpdate = os.clock() * 1000
end

function generateNewBoloId()
    local year = os.date("%y")
    local highest_id = 0
    for _, bolo in ipairs(data_storage.bolos) do
        if bolo.id and type(bolo.id) == 'string' then
            local id_year, id_num = bolo.id:match("^(%d+)-(%d+)$")
            if id_year == year and id_num then
                if tonumber(id_num) > highest_id then
                    highest_id = tonumber(id_num)
                end
            end
        end
    end
    return string.format("%s-%04d", year, highest_id + 1)
end

function drawBoloCreatorWindow()
    if not UI.bolo_creator_window[0] then return end

    imgui.SetNextWindowSize(imgui.new('ImVec2', 500, 550), imgui.Cond.FirstUseEver)
    if imgui.Begin("Create New BOLO", UI.bolo_creator_window, imgui.WindowFlags.NoResize) then
        imgui.Text("BOLO Details"); imgui.Separator()
        imgui.Combo("Type", newBoloData.type, boloTypes_c, #boloTypes)
        imgui.InputText("Subject Name / Plate", newBoloData.subject_name, ffi.sizeof(newBoloData.subject_name))
        imgui.InputText("Last Known Location", newBoloData.last_location, ffi.sizeof(newBoloData.last_location))
        imgui.Separator(); imgui.Text("Description (Appearance, clothing, vehicle model, etc.)")
        imgui.InputTextMultiline("##Description", newBoloData.description, ffi.sizeof(newBoloData.description), imgui.new('ImVec2', -1, 100))
        imgui.Separator(); imgui.Text("Crime / Reason for BOLO")
        imgui.InputTextMultiline("##CrimeSummary", newBoloData.crime_summary, ffi.sizeof(newBoloData.crime_summary), imgui.new('ImVec2', -1, 100))
        imgui.Separator()

        if imgui.Button("Save BOLO", imgui.new('ImVec2', 120, 30)) then
            local new_bolo = {
                bolo_id = "",
                type = boloTypes[newBoloData.type[0] + 1],
                subject_name = safe_str(newBoloData.subject_name),
                last_location = safe_str(newBoloData.last_location),
                description = safe_str(newBoloData.description),
                crime_summary = safe_str(newBoloData.crime_summary),
                status = "In Progress",
                created_by = safe_str(unitInfoBuffers.officer1_name)
            }
            events.trigger('cad:addBolo', new_bolo)
            UI.bolo_creator_window[0] = false
        end
        imgui.SameLine()
        if imgui.Button("Cancel", imgui.new('ImVec2', 120, 30)) then
            UI.bolo_creator_window[0] = false
        end

    end
    imgui.End()
end



local alpr_interaction_mode = false

function renderALPRWindow()
    if not UI.alpr_window[0] then
        if alpr_interaction_mode then alpr_interaction_mode = false end
        return
    end

    if wasKeyPressed(vkeys.VK_F2) then
        alpr_interaction_mode = not alpr_interaction_mode
    end

    imgui.SetNextWindowSize(imgui.new('ImVec2', 450, 280), imgui.Cond.FirstUseEver)

    local style_pushed = false
    if alpr_is_wanted_plate then
        local time = os.clock()
        local title_color
        local border_color = imgui.ImVec4(1.0, 0.0, 0.0, 1.0)

        if time < alpr_flash_end_time then
            local pulse = (math.sin(time * 15) + 1) / 2
            title_color = imgui.ImVec4(0.5 + pulse * 0.5, 0.0, 0.0, 1.0)
        else
            title_color = imgui.ImVec4(0.7, 0.0, 0.0, 1.0)
        end
        
        imgui.PushStyleColor(imgui.Col.TitleBgActive, title_color)
        imgui.PushStyleColor(imgui.Col.TitleBg, title_color)
        imgui.PushStyleColor(imgui.Col.Border, border_color)
        style_pushed = true
    end

    local success, err = pcall(function()
        if imgui.Begin("ALPR Scan", UI.alpr_window, imgui.WindowFlags.NoResize) then
            if os.clock() * 1000 - last_alpr_scan_time > 1000 then
                updateALPRData()
                last_alpr_scan_time = os.clock() * 1000
            end

            imgui.PushFont(fonts[22])
            imgui.Text("Automatic License Plate Reader")
            imgui.PopFont()
            imgui.Separator()
            imgui.BeginChild("ALPRInfo", imgui.new('ImVec2', -1, -110))

            if not alpr_current_scan.found and alpr_current_scan.model == "Scanning..." then
                imgui.Text("Scanning for vehicles...")
            elseif not alpr_current_scan.found then
                imgui.Text(tostring(alpr_current_scan.model))
            else
                renderLabeledText("VEHICLE MODEL:", tostring(alpr_current_scan.model), imgui.ImVec4(1,1,0,1), imgui.ImVec4(1,1,1,1))
                renderLabeledText("LICENSE PLATE:", tostring(alpr_current_scan.plate), imgui.ImVec4(1,1,0,1), imgui.ImVec4(1,1,1,1))
                renderLabeledText("DRIVER:", tostring(alpr_current_scan.driver), imgui.ImVec4(1,1,0,1), imgui.ImVec4(1,1,1,1))
            end
            imgui.EndChild()
            imgui.Separator()

            imgui.TextDisabled("Press F2 to toggle cursor and controls")

            local button_size = imgui.new('ImVec2', imgui.GetContentRegionAvail().x / 4 - 4, 40)
            if not alpr_current_scan.found then
                imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, imgui.GetStyle().Alpha * 0.5)
                imgui.Button("T/S", button_size)
                imgui.PopStyleVar()
            else
                if imgui.Button("T/S", button_size) then
                    addUnitLogEntry("ALPR", "Traffic stop announced for: " .. tostring(alpr_current_scan.plate))
                end
            end
            if imgui.IsItemHovered() then
                imgui.SetTooltip("Announce traffic stop on radio")
            end
            imgui.SameLine()
            if not alpr_current_scan.found then
                imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, imgui.GetStyle().Alpha * 0.5)
                imgui.Button("GET INFO", button_size)
                imgui.PopStyleVar()
            else
                if imgui.Button("GET INFO", button_size) then
                    setClipboardText(tostring(alpr_current_scan.plate))
                    print(string.format("[CAD/MDT] License plate '%s' copied to clipboard.", tostring(alpr_current_scan.plate)))
                end
            end
            if imgui.IsItemHovered() then
                imgui.SetTooltip("Copy license plate to clipboard")
            end
            imgui.SameLine()
            if imgui.Button("VIEW LOG", button_size) then
                UI.alpr_log_window[0] = true
            end
            imgui.SameLine()
            if imgui.Button("CLOSE", button_size) then
                UI.alpr_window[0] = false
            end
        end
        imgui.End()
    end)

    if style_pushed then
        imgui.PopStyleColor(3)
    end

    if not success then
        log('UI', log_levels.ERROR, "An error occurred in renderALPRWindow: " .. tostring(err))
    end
end

function renderALPRLogWindow()
    if not UI.alpr_log_window[0] then return end

    imgui.SetNextWindowSize(imgui.new('ImVec2', 700, 500), imgui.Cond.FirstUseEver)
    if imgui.Begin("ALPR Scan Log", UI.alpr_log_window) then
        if imgui.Button("Clear Log") then
            alpr_scan_log = {}
            selected_alpr_log_index = nil
        end
        imgui.Separator()

        imgui.Columns(2)
        imgui.SetColumnWidth(0, 250)

        imgui.BeginChild("ScanList")
        for i, scan in ipairs(alpr_scan_log) do
            local label = string.format("%s (%s)", scan.plate, scan.model)
            if imgui.Selectable(label, selected_alpr_log_index == i) then
                selected_alpr_log_index = i
                safe_copy(alpr_log_comment_buffer, scan.notes or "")
            end
        end
        imgui.EndChild()

        imgui.NextColumn()

        imgui.BeginChild("ScanDetails")
        if selected_alpr_log_index and alpr_scan_log[selected_alpr_log_index] then
            local scan = alpr_scan_log[selected_alpr_log_index] 
            
            imgui.Text("Scan Details")
            imgui.Separator() 
            
                        renderLabeledText("Timestamp:", os.date("%Y-%m-%d %H:%M:%S", scan.timestamp), imgui.ImVec4(1,1,0,1), imgui.ImVec4(1,1,1,1))
            renderLabeledText("Vehicle Model:", scan.model, imgui.ImVec4(1,1,0,1), imgui.ImVec4(1,1,1,1))
            renderLabeledText("License Plate:", scan.plate, imgui.ImVec4(1,1,0,1), imgui.ImVec4(1,1,1,1))
            renderLabeledText("Driver:", scan.driver, imgui.ImVec4(1,1,0,1), imgui.ImVec4(1,1,1,1))
            
            if imgui.Button("Copy Plate") then setClipboardText(scan.plate) end
            imgui.SameLine()
            if imgui.Button("Copy Driver") then setClipboardText(scan.driver) end
            
            imgui.Separator()
            imgui.Text("Notes:")
            imgui.InputTextMultiline("##alpr_notes", alpr_log_comment_buffer, ffi.sizeof(alpr_log_comment_buffer), imgui.new('ImVec2', -1, 100))
            
            if imgui.Button("Save Notes") then
                scan.notes = safe_str(alpr_log_comment_buffer)
            end
        else
            imgui.Text("Select a scan from the list to see details.")
        end
        imgui.EndChild()

        imgui.Columns(1)
        
    end
    imgui.End()
end

local function renderUnitTable(title, unit_list)
    imgui.Text(string.format("%s (%d)", title, #unit_list));
    imgui.Separator()

    if #unit_list == 0 then
        imgui.Text("No active units found or data not yet loaded.")
        return
    end

    local columns = {
        {name="Unit", width=100},
        {name="Officer 1", width=220},
        {name="Officer 2", width=220},
        {name="Status", width=140},
        {name="Location", width=-1},
    }

    local function row_renderer(unit, i)
        imgui.Text(unit.unitID or "N/A"); imgui.NextColumn()
        imgui.Text(unit.officer1_name or "N/A"); imgui.NextColumn()
        imgui.Text(unit.officer2_name or ""); imgui.NextColumn()

        local current_status = tonumber(unit.status)
        if current_status and comboBoxData and comboBoxData.status[current_status + 1] then
             local status_text = comboBoxData.status[current_status + 1]
             local status_color = (patrol_status_color_map and patrol_status_color_map[current_status + 1]) or status_colors.gray
             imgui.TextColored(status_color, status_text); imgui.NextColumn()
        else
             imgui.Text("Invalid Status"); imgui.NextColumn()
        end

        imgui.Text(unit.location or "N/A");
    end

    renderTable("unit_table", columns, unit_list, row_renderer, {selected_index = selectedPatrolUnit, on_select = function(i) selectedPatrolUnit = unit_list[i] end})
end

local show_register_form = imgui.new.bool(false)
local show_password = imgui.new.bool(false)

function renderLoginForm()
    imgui.Text("Department Terminal Login")
    imgui.Spacing()
    imgui.InputText("Username", core.login_window.username, ffi.sizeof(core.login_window.username))
    
    local flags = show_password[0] and imgui.InputTextFlags.None or imgui.InputTextFlags.Password
    imgui.InputText("Password", core.login_window.password, ffi.sizeof(core.login_window.password), flags)
    imgui.SameLine()
    if imgui.Checkbox("Show", show_password) then end

    if core.login_window.is_logging_in then
        imgui.TextColored(imgui.ImVec4(1, 0.8, 0, 1), "Logging in...")
    elseif core.login_window.error_message ~= "" then
        imgui.TextColored(imgui.ImVec4(1, 0.2, 0.2, 1), core.login_window.error_message)
    end
    imgui.Spacing()

    if not core.login_window.is_logging_in and imgui.Button("Login", imgui.new('ImVec2', -1, 35)) then
        log('UI', log_levels.INFO, "Login button clicked.")
        local username = safe_str(core.login_window.username)
        local password = safe_str(core.login_window.password)
        core.login(username, password) 
    end
end

function renderRegisterForm()
    if not divisionOptions_c then return end
    imgui.Text("New Officer Registration")
    imgui.Spacing()
    imgui.InputText("Username", registerBuffers.username, ffi.sizeof(registerBuffers.username))
    imgui.InputText("Full Name (First Last)", registerBuffers.full_name, ffi.sizeof(registerBuffers.full_name))
    imgui.InputText("Badge Number", registerBuffers.badge_number, ffi.sizeof(registerBuffers.badge_number))
    imgui.Combo("Division", registerBuffers.division, divisionOptions_c, #comboBoxData.division)
    imgui.Separator()
    imgui.InputText("Password", registerBuffers.password, ffi.sizeof(registerBuffers.password), imgui.InputTextFlags.Password)
    imgui.InputText("Confirm Password", registerBuffers.password_confirm, ffi.sizeof(registerBuffers.password_confirm), imgui.InputTextFlags.Password)

    if registerBuffers.error ~= "" then
        imgui.TextColored(imgui.ImVec4(1,0.2,0.2,1), registerBuffers.error)
    end
    if registerBuffers.success_message ~= "" then
        imgui.TextColored(imgui.ImVec4(0.2,1,0.2,1), registerBuffers.success_message)
    end

    imgui.Spacing()
    if not registerBuffers.loading then
        if imgui.Button("Register", imgui.new('ImVec2', -1, 35)) then
            log('UI', log_levels.INFO, "Register button clicked.")
            registerBuffers.loading = true
            registerBuffers.error = ""
            registerBuffers.success_message = ""
            
            if not cad_websocket or not cad_websocket.is_connected() then
                log('UI', log_levels.ERROR, "Registration failed: Not connected to server.")
                registerBuffers.error = "Not connected to server"
                registerBuffers.loading = false
                return
            end

            local pass = safe_str(registerBuffers.password)
            local pass_confirm = safe_str(registerBuffers.password_confirm)

            if pass ~= pass_confirm then
                registerBuffers.error = "Passwords do not match"
                registerBuffers.loading = false
                return
            end
            
            if #pass < 6 then
                registerBuffers.error = "Password must be at least 6 characters long"
                registerBuffers.loading = false
                return
            end

            local payload = {
                username = safe_str(registerBuffers.username),
                password = pass,
                full_name = safe_str(registerBuffers.full_name),
                badge_number = safe_str(registerBuffers.badge_number),
                division = registerBuffers.division[0]
            }

            send_ws_request('auth', 'register', payload, function(data, err) 
                registerBuffers.loading = false
                if err then
                    log('UI', log_levels.ERROR, "Registration request failed: " .. err)
                    registerBuffers.error = err
                else
                    log('UI', log_levels.INFO, "Registration successful.")
                    registerBuffers.success_message = data.message or "Registration successful! You can now log in."
                    ffi.copy(core.login_window.username, ffi.string(registerBuffers.username))
                    show_register_form[0] = false
                end
            end)
        end
    else
        imgui.Text("Registering... Please wait...")
    end
end

function renderLoginWindow()
    local sw, sh = getScreenResolution()
    imgui.SetNextWindowSize(imgui.new('ImVec2', 450, 180), imgui.Cond.FirstUseEver)
    imgui.SetNextWindowPos(imgui.new('ImVec2', sw / 2, sh / 2), imgui.Cond.FirstUseEver, imgui.new('ImVec2', 0.5, 0.5))

    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.06, 0.06, 0.08, 0.98))
    imgui.PushStyleColor(imgui.Col.Border, imgui.ImVec4(0.2, 0.2, 0.25, 0.5))

    if imgui.Begin("Computer-Aided Dispatch ", UI.login_window, imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize) then
        imgui.Separator()        
        if show_register_form[0] then
            renderRegisterForm()
        else
            renderLoginForm()
        end

        imgui.Separator()        
        if show_register_form[0] then
            if imgui.SmallButton("Already have an account? Login") then
                show_register_form[0] = false
                registerBuffers.error = ""
            end
        else
            if imgui.SmallButton("No account? Register") then
                show_register_form[0] = true
                loginBuffers.error = ""
            end
        end

        imgui.End()
    end
    imgui.PopStyleColor(2)
end

function renderUnitMiniMap(unit)
    imgui.Dummy(imgui.new('ImVec2', 0.0, 150.0)) -- Add 150px vertical space

    if not unit or not unit.pos_x or not unit.pos_y then
        imgui.Text("Unit position not available.")
        return
    end

    imgui.Text("Unit Location")
    imgui.Separator()

    local minimap_width = imgui.GetContentRegionAvail().x
    local minimap_height = 250

    local draw_list = imgui.GetWindowDrawList()
    local widget_pos = imgui.GetCursorScreenPos()

    local world_view_height = 750.0
    local world_view_width = world_view_height * (minimap_width / minimap_height)

    local world_x_start = unit.pos_x - world_view_width / 2
    local world_y_start = unit.pos_y + world_view_height / 2

    for y_tile = 0, 3 do
        for x_tile = 0, 3 do
            local tile_index = y_tile * 4 + x_tile + 1
            local texture = map_tile_textures.standard[tile_index]

            if texture then
                local tile_world_x0 = -3000.0 + x_tile * 1500.0
                local tile_world_y1 = 3000.0 - y_tile * 1500.0
                local tile_world_x1 = tile_world_x0 + 1500.0
                local tile_world_y0 = tile_world_y1 - 1500.0

                local intersect_x0 = math.max(world_x_start, tile_world_x0)
                local intersect_y1 = math.min(world_y_start, tile_world_y1)
                local intersect_x1 = math.min(world_x_start + world_view_width, tile_world_x1)
                local intersect_y0 = math.max(world_y_start - world_view_height, tile_world_y0)

                if intersect_x1 > intersect_x0 and intersect_y1 > intersect_y0 then

                    local u0 = (intersect_x0 - tile_world_x0) / 1500.0
                    local v0 = (tile_world_y1 - intersect_y1) / 1500.0
                    local u1 = (intersect_x1 - tile_world_x0) / 1500.0
                    local v1 = (tile_world_y1 - intersect_y0) / 1500.0

                    local screen_x0 = widget_pos.x + ((intersect_x0 - world_x_start) / world_view_width) * minimap_width
                    local screen_y0 = widget_pos.y + ((world_y_start - intersect_y1) / world_view_height) * minimap_height
                    local screen_x1 = widget_pos.x + ((intersect_x1 - world_x_start) / world_view_width) * minimap_width
                    local screen_y1 = widget_pos.y + ((world_y_start - intersect_y0) / world_view_height) * minimap_height

                    draw_list:AddImage(texture, imgui.new('ImVec2', screen_x0, screen_y0), imgui.new('ImVec2', screen_x1, screen_y1), imgui.new('ImVec2', u0, v0), imgui.new('ImVec2', u1, v1))
                end
            end
        end
    end
    
    imgui.SetCursorPosY(imgui.GetCursorPosY() + minimap_height)

    local center_x = widget_pos.x + minimap_width / 2
    local center_y = widget_pos.y + minimap_height / 2

    draw_list:AddCircleFilled(imgui.new('ImVec2', center_x, center_y), 5, 0xFF00FF00) -- Green for selected
    draw_list:AddText(imgui.new('ImVec2', center_x + 8, center_y - 8), 0xFFFFFFFF, unit.unitID or 'N/A')
end

function renderMDTWindow()
    if not core.isAuthenticated() then
        if not UI.login_window[0] then
            UI.login_window[0] = true
        end
        return
    end

    UI.login_window[0] = false
    updateCurrentLocation()

    if not divisionOptions_c or not unitTypeOptions_c or not shiftOptions_c then return end
    local sizeX, sizeY = getScreenResolution()    
    imgui.SetNextWindowPos(imgui.new('ImVec2', sizeX / 2, sizeY / 2), imgui.Cond.FirstUseEver, imgui.new('ImVec2', 0.5, 0.5))
    imgui.SetNextWindowSize(imgui.new('ImVec2', 1400, 800), imgui.Cond.FirstUseEver)
    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.06, 0.06, 0.08, 0.98)); imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.10, 0.10, 0.12, 0.98)); imgui.PushStyleColor(imgui.Col.Border, imgui.ImVec4(0.2, 0.2, 0.25, 0.5)); imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.2, 0.2, 0.4, 0.4)); imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.3, 0.3, 0.6, 0.6)); imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.4, 0.4, 0.8, 0.8)); imgui.PushStyleColor(imgui.Col.Tab, imgui.ImVec4(0.15, 0.15, 0.20, 0.98)); imgui.PushStyleColor(imgui.Col.TabHovered, imgui.ImVec4(0.3, 0.3, 0.6, 0.8)); imgui.PushStyleColor(imgui.Col.TabActive, imgui.ImVec4(0.2, 0.2, 0.4, 1.0)); imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 3.0); imgui.PushStyleVarFloat(imgui.StyleVar.ChildRounding, 3.0)
    
    imgui.Begin("Computer-Aided Dispatch", UI.mdt)
    local left_panel_width = 200; local bottom_panel_height = 90
    
    local status_colors = { 
        green = imgui.ImVec4(0.2, 0.8, 0.2, 1.0), 
        orange = imgui.ImVec4(1.0, 0.6, 0.0, 1.0), 
        blue = imgui.ImVec4(0.2, 0.5, 1.0, 1.0), 
        red = imgui.ImVec4(1.0, 0.2, 0.2, 1.0), 
        gray = imgui.ImVec4(0.6, 0.6, 0.6, 1.0) 
    } 
    local patrol_status_color_map = { status_colors.green, status_colors.orange, status_colors.blue, status_colors.red, status_colors.gray }

    imgui.BeginChild("LeftPanel", imgui.new('ImVec2', left_panel_width, 0), true)
        local button_size = imgui.new('ImVec2', left_panel_width - 15, 50)
        if imgui.Button("OUT OF SERVICE", button_size) then
            setUnitActiveStatus(false)
        end
        if imgui.Button("BUSY", button_size) then
            unitInfoBuffers.status[0] = 3; broadcastUnitStatus()
            addUnitLogEntry("STATUS", "Status changed to: " .. (comboBoxData.status[4] or "Busy"))
        end
        if imgui.Button("CODE 6", button_size) then
            unitInfoBuffers.status[0] = 2; broadcastUnitStatus()
            addUnitLogEntry("STATUS", "Status changed to: " .. (comboBoxData.status[3] or "On Scene / C6"))
        end
        if imgui.Button("ENROUTE", button_size) then
            unitInfoBuffers.status[0] = 1; broadcastUnitStatus()
            addUnitLogEntry("STATUS", "Status changed to: " .. (comboBoxData.status[2] or "En Route"))
        end
        if imgui.Button("CLEAR", button_size) then
            setUnitActiveStatus(true)
        end

        imgui.SetCursorPosY(imgui.GetWindowHeight() - 150)
        imgui.Separator()

        local panic_button_size = imgui.new('ImVec2', left_panel_width - 15, 40)
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.8, 0.1, 0.1, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(1.0, 0.2, 0.2, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.7, 0.0, 0.0, 1.0))
        if imgui.Button("PANIC", panic_button_size) then
            if panic_sound then
                setAudioStreamState(panic_sound, 1)
            end
            addUnitLogEntry("STATUS", "PANIC BUTTON ACTIVATED")
            sampSendChat("/bk")
        end
        imgui.PopStyleColor(3)
        imgui.Spacing()

        imgui.Text("STATUS:")
        local current_status_idx = (unitInfoBuffers.status and unitInfoBuffers.status[0] or 4) + 1
        local status_text_display = comboBoxData.status[current_status_idx] or "Unknown"
        local status_color_display = patrol_status_color_map[current_status_idx] or status_colors.gray
        imgui.PushStyleColor(imgui.Col.Text, status_color_display)
        imgui.TextWrapped(status_text_display)
        imgui.PopStyleColor()
        imgui.Separator()
        imgui.Text("SYSTEM:")
        local is_connected = cad_websocket and cad_websocket.is_connected()
        local system_status_text = is_connected and "ONLINE" or "OFFLINE"
        local system_status_color = is_connected and status_colors.green or status_colors.red
        imgui.PushStyleColor(imgui.Col.Text, system_status_color)
        imgui.TextWrapped(system_status_text)
        imgui.PopStyleColor()
        imgui.Separator()

    imgui.EndChild(); imgui.SameLine() 

    imgui.BeginGroup()
    isEditingUnitInfo = false
    if imgui.BeginTabBar("MainTabs") then
        local unitLookup = {}
        for _, unit in ipairs(data_storage.units) do 
            if unit and unit.unitID then
                unitLookup[unit.unitID] = unit 
            end
        end

        if imgui.BeginTabItem("CALL LOG") then
            local calls_to_display = {}
            local should_hide_placeholders = settings.get('ui_settings', 'hide_placeholder_calls', false)
            local placeholder_text = "Происходит что-то неладное!"

            for _, call in ipairs(data_storage.calls) do
                local should_hide = false
                if should_hide_placeholders and call.description and call.description.incident_details == placeholder_text then
                    should_hide = true
                end

                if not should_hide then
                    table.insert(calls_to_display, call)
                end
            end

            local call_status_counts = { Pending = 0, ["En-route"] = 0, Clear = 0 }
            for _, call in ipairs(calls_to_display) do
                local status_text = call.status
                if status_text and call_status_counts[status_text] ~= nil then
                    call_status_counts[status_text] = call_status_counts[status_text] + 1
                end
            end

            local main_content_width = imgui.GetContentRegionAvail().x
            imgui.Columns(2, "CallLogLayout", false)
            imgui.SetColumnWidth(0, main_content_width * 0.35); imgui.SetColumnWidth(1, main_content_width * 0.65)

            imgui.BeginChild("CallDetails", imgui.new('ImVec2', 0, imgui.GetContentRegionAvail().y - bottom_panel_height - 10), true)
            if selected_call_index and data_storage.calls[selected_call_index] then
                local call = data_storage.calls[selected_call_index]
                if call and type(call) == 'table' then
                    imgui.Text("Call Details: #" .. tostring(call.id or 'N/A') .. " (Server ID: " .. tostring(call.server_call_id or 'N/A') .. ")"); imgui.Separator()
                    
                    local date_str = call.created_at or call.timestamp or ""
                    if date_str ~= "" then
                        local formatted_date = tostring(date_str):gsub("T", " "):gsub("%.%d+Z", "")
                        imgui.TextColored(imgui.ImVec4(1,1,0,1), "Time Received:"); imgui.TextWrapped(formatted_date)
                    end

                    local details = call.description or {}
                    imgui.TextColored(imgui.ImVec4(1,1,0,1), "Summary:"); imgui.TextWrapped(details.incident_details or "N/A")
                    imgui.TextColored(imgui.ImVec4(1,1,0,1), "Location:"); imgui.TextWrapped(details.location or "N/A")
                    imgui.TextColored(imgui.ImVec4(1,1,0,1), "Caller Name:"); imgui.TextWrapped(details.caller_name or "N/A")
                    imgui.TextColored(imgui.ImVec4(1,1,0,1), "Caller Number:"); imgui.TextWrapped(details.phone_number or "N/A")
                    imgui.Separator()                    
                    
                    local button_size = imgui.new('ImVec2', imgui.GetContentRegionAvail().x / 2 - 5, 30)
                    if imgui.Button("ASSIGN", button_size) then 
                        updateCallStatus(call.id, "accept", safe_str(unitInfoBuffers.unitID)) 
                        sampSendChat('/accept ' .. tostring(call.server_call_id))
                        cadui_module.setPendingCheckpointForCall(call.id)

                        unitInfoBuffers.status[0] = 1 -- Set status to En-Route
                        broadcastUnitStatus()
                        addUnitLogEntry("STATUS", "Status auto-set to En-Route for call #" .. tostring(call.id or 'N/A'))
                    end
                    imgui.SameLine() 
                    if imgui.Button("RESOLVE", button_size) then updateCallStatus(call.id, "clear", safe_str(unitInfoBuffers.unitID)) end
                    if imgui.Button("Deselect", imgui.new('ImVec2', -1, 30)) then selected_call_index = nil end
                    
                    imgui.Separator(); imgui.Text("Assigned Units:")
                    if call.assigned_units and type(call.assigned_units) == 'table' and #call.assigned_units > 0 then
                        for _, unitID in ipairs(call.assigned_units) do
                            local unitData = unitLookup[unitID]; imgui.Bullet(); imgui.SameLine(); imgui.Text(tostring(unitID))
                            if unitData and unitData.status ~= nil then
                                imgui.SameLine() 
                                local status_idx = (tonumber(unitData.status) or 4) + 1
                                local status_text = comboBoxData.status[status_idx] or "Unknown"
                                local status_color = patrol_status_color_map[status_idx] or status_colors.gray
                                local text_width = imgui.CalcTextSize(status_text or "").x
                                imgui.SetCursorPosX(imgui.GetCursorPosX() + imgui.GetContentRegionAvail().x - text_width - imgui.GetStyle().ItemSpacing.x)
                                imgui.TextColored(status_color, status_text)
                            end
                        end
                    else
                        imgui.Text("No units assigned.")
                    end

                    imgui.Separator(); imgui.Text("Event Log:");
                    imgui.BeginChild("CallEventLog", imgui.new('ImVec2', 0, 150), true)
                    if call.event_log and type(call.event_log) == 'table' and #call.event_log > 0 then
                        for _, event in ipairs(call.event_log) do 
                            if event and event.time and event.event then
                                imgui.TextWrapped(string.format("[%s] %s", event.time, event.event)) 
                            end
                        end
                    else
                        imgui.Text("No events for this call.")
                    end
                    imgui.EndChild()

                    imgui.InputTextMultiline("##call_note", call_note_buffer, ffi.sizeof(call_note_buffer), imgui.new('ImVec2', imgui.GetContentRegionAvail().x - 80, 40))
                    imgui.SameLine()
                    if imgui.Button("Add Note", imgui.new('ImVec2', 70, 40)) then
                        local note_text = safe_str(call_note_buffer)
                        if note_text ~= "" then
                            addCallLogEntry(call.id, note_text)
                            ffi.copy(call_note_buffer, "")
                        end
                    end
                end
            else 
                imgui.Text("Select a call to view details.") 
            end
            imgui.EndChild(); imgui.NextColumn()

            imgui.BeginChild("CallList", imgui.new('ImVec2', 0, imgui.GetContentRegionAvail().y - bottom_panel_height - 10), true)
            imgui.Text("Incoming Calls"); imgui.SameLine() 
            imgui.TextDisabled("(" .. #calls_to_display .. ")"); imgui.SameLine() 
            imgui.TextColored(callStatusColors.Pending, "Pending: " .. call_status_counts.Pending); imgui.SameLine() 
            imgui.TextColored(callStatusColors["En-route"], "En-route: " .. call_status_counts["En-route"]); imgui.SameLine() 
            imgui.TextColored(callStatusColors.Clear, "Clear: " .. call_status_counts.Clear)
            imgui.Separator()

            if #calls_to_display == 0 then
                imgui.Text("No active calls.")
            else
                local list_width = imgui.GetContentRegionAvail().x
                imgui.Columns(4, "CallListHeader", false)
                imgui.SetColumnWidth(0, 70); imgui.SetColumnWidth(1, list_width - 350); imgui.SetColumnWidth(2, 200); imgui.SetColumnWidth(3, 80)
                imgui.Text("Call ID"); imgui.NextColumn()
                imgui.Text("Summary"); imgui.NextColumn()
                imgui.Text("Location"); imgui.NextColumn()
                imgui.Text("Status"); imgui.NextColumn()
                imgui.Separator(); imgui.Columns(1)

                local success, err = pcall(function()
                    for i, call in ipairs(calls_to_display) do
                        if call and call.id then
                            local is_selected = false
                            if selected_call_index and data_storage.calls[selected_call_index] then
                                if data_storage.calls[selected_call_index].id == call.id then
                                    is_selected = true
                                end
                            end
                            if imgui.Selectable("##call" .. tostring(call.id), is_selected, 1, imgui.new('ImVec2', 0, 20)) then 
                                for original_idx, original_call in ipairs(data_storage.calls) do
                                    if original_call.id == call.id then
                                        selected_call_index = original_idx
                                        break
                                    end
                                end
                            end
                            imgui.SameLine(); imgui.Columns(4, "CallListItem"..i, false)
                            imgui.SetColumnWidth(0, 70); imgui.SetColumnWidth(1, list_width - 350); imgui.SetColumnWidth(2, 200); imgui.SetColumnWidth(3, 80)
                            
                            local details = call.description or {}
                            imgui.Text("#" .. tostring(call.id)); imgui.NextColumn()
                            imgui.Text(details.incident_details or "No description"); imgui.NextColumn()
                            imgui.Text(details.location or "N/A"); imgui.NextColumn()
                            
                            local status_text = call.status or "Unknown"
                            local status_color = callStatusColors[status_text] or callStatusColors.Pending
                            imgui.TextColored(status_color, status_text); imgui.NextColumn()
                            
                            imgui.Columns(1)
                        end
                    end
                end)

                if not success then
                    log('UI', log_levels.ERROR, "CRITICAL: Error rendering call list: " .. tostring(err))
                    imgui.TextColored(imgui.ImVec4(1, 0, 0, 1), "Error rendering call list. Check cad_debug.log for details.")
                end
            end
            imgui.EndChild(); imgui.Columns(1); imgui.EndTabItem()
        end

        if imgui.BeginTabItem("UNITS") then
            local main_content_width = imgui.GetContentRegionAvail().x
            imgui.Columns(2, "UnitViewLayout", false)
            imgui.SetColumnWidth(0, main_content_width * 0.35)

            imgui.BeginChild("UnitList", imgui.new('ImVec2', 0, 0), true)
            if #data_storage.units == 0 then
                imgui.Text("No active units.")
            else
                for i, unit in ipairs(data_storage.units) do
                    local status_idx = (tonumber(unit.status) or 4) + 1
                    local status_color = patrol_status_color_map[status_idx] or status_colors.gray
                    
                    if imgui.Selectable("##unit_selectable" .. tostring(unit.id or i), selected_unit_index == i, 0, imgui.new('ImVec2', 0, 20)) then
                        selected_unit_index = i
                    end
                    imgui.SameLine()
                    imgui.Text(unit.unitID or "N/A")
                    imgui.SameLine()
                    local status_text = comboBoxData.status[status_idx] or "Unknown"
                    imgui.TextColored(status_color, status_text)
                    imgui.SameLine()
                    imgui.Text(unit.location or "N/A")
                end
            end
            imgui.EndChild()
            imgui.NextColumn()

            imgui.BeginChild("UnitDetailsView", imgui.new('ImVec2', 0, 0), true)
            if selected_unit_index and data_storage.units[selected_unit_index] then
                local unit = data_storage.units[selected_unit_index]
                imgui.Text("Unit Details: " .. tostring(unit.unitID or 'N/A')); imgui.Separator() 
                
                local label_color = imgui.ImVec4(1,1,0,1)
                local text_color = imgui.ImVec4(1,1,1,1)
                
                local status_idx = (tonumber(unit.status) or 4) + 1
                local status_text = comboBoxData.status[status_idx] or "Unknown"
                
                renderLabeledText("Officer 1:", tostring(unit.officer1_name or "N/A"), label_color, text_color)
                renderLabeledText("Officer 2:", tostring(unit.officer2_name or "N/A"), label_color, text_color)
                renderLabeledText("Unit Type:", (comboBoxData.unitType[tonumber(unit.unitType) + 1] or "N/A"), label_color, text_color)
                renderLabeledText("Status:", status_text, label_color, text_color)
                renderLabeledText("Vehicle Plate:", tostring(unit.vehiclePlate or "N/A"), label_color, text_color)
                renderLabeledText("Location:", tostring(unit.location or "N/A"), label_color, text_color)
                renderLabeledText("Notes:", tostring(unit.notes or "N/A"), label_color, text_color)
                
                imgui.Separator()
                local button_size = imgui.new('ImVec2', (imgui.GetContentRegionAvail().x / 2) - 5, 30)
                if imgui.Button("Request Status", button_size) then
                    log('UI', log_levels.INFO, "Status request for unit " .. unit.unitID .. " (not implemented)")
                end
                imgui.SameLine()
                if imgui.Button("Radio Simplex", button_size) then
                    log('UI', log_levels.INFO, "Radio simplex for unit " .. unit.unitID .. " (not implemented)")
                end

                if unit and unit.pos_x and unit.pos_y then
                    imgui.Separator()
                    renderUnitMiniMap(unit)
                end

            else
                imgui.Text("Select a unit from the list to see details.")
            end
            imgui.EndChild()
            imgui.Columns(1)
            imgui.EndTabItem()
        end

        if imgui.BeginTabItem("UNIT INFO") then
            isEditingUnitInfo = true
            imgui.BeginChild("UnitInfoTop", imgui.new('ImVec2', 0, 250), false)
                imgui.Columns(2, "UnitInfoColumns", false); imgui.SetColumnWidth(0, 450)
                imgui.Text("Unit Details")                
                imgui.InputText("Unit Number", unitInfoBuffers.unitID, ffi.sizeof(unitInfoBuffers.unitID))
                imgui.Combo("Unit Type", unitInfoBuffers.unitType, unitTypeOptions_c, #comboBoxData.unitType)
                imgui.InputText("Vehicle Plate", unitInfoBuffers.vehiclePlate, ffi.sizeof(unitInfoBuffers.vehiclePlate))
                imgui.SameLine()
                if imgui.Button("Assign Car") then
                    if isCharInAnyCar(PLAYER_PED) then
                        local vehicleHandle = storeCarCharIsInNoSave(PLAYER_PED)
                        local ok, vehicleId = sampGetVehicleIdByCarHandle(vehicleHandle)
                        if ok then
                            assigned_vehicle_id = vehicleId
                            local plate = getplate(vehicleId)
                            if plate then
                                ffi.copy(unitInfoBuffers.vehiclePlate, plate:gsub("[%z%s]", ""):upper())
                            end
                            addUnitLogEntry("VEHICLE", "Vehicle assigned with ID: " .. vehicleId)
                            broadcastUnitStatus()
                        end
                    else
                        addUnitLogEntry("VEHICLE", "Assign failed: Not in a vehicle.")
                    end
                end
                imgui.Combo("Division / Area", unitInfoBuffers.division, divisionOptions_c, #comboBoxData.division)
                imgui.Combo("Shift Time / Watch", unitInfoBuffers.shift, shiftOptions_c, #comboBoxData.shift)
                
                imgui.Text("LOCATION: " .. currentLocation)
                imgui.NextColumn()
                imgui.Text("Assigned Officers")

                imgui.InputText("Officer 1 Name", unitInfoBuffers.officer1_name, ffi.sizeof(unitInfoBuffers.officer1_name))
                imgui.InputText("Officer 2 Name", unitInfoBuffers.officer2_name, ffi.sizeof(unitInfoBuffers.officer2_name))

                imgui.Text("Special Equipment / Notes")
                imgui.InputTextMultiline("##Notes", unitInfoBuffers.notes, ffi.sizeof(unitInfoBuffers.notes), imgui.new('ImVec2', -1, 80))

                imgui.Spacing()
                if imgui.Button("Update Unit Information", imgui.new('ImVec2', -1, 35)) then
                    broadcastUnitStatus()
                    addUnitLogEntry("REQUEST", string.format("Unit %s updated information about Status", safe_str(unitInfoBuffers.unitID)))
                    
                    local unit_data_to_save = {
                        unitID = safe_str(unitInfoBuffers.unitID),
                        unitType = unitInfoBuffers.unitType[0],
                        officer1_name = safe_str(unitInfoBuffers.officer1_name),
                        officer1_id = safe_str(unitInfoBuffers.officer1_id),
                        officer2_name = safe_str(unitInfoBuffers.officer2_name),
                        officer2_id = safe_str(unitInfoBuffers.officer2_id),
                        status = unitInfoBuffers.status[0],
                        vehiclePlate = safe_str(unitInfoBuffers.vehiclePlate),
                        division = unitInfoBuffers.division[0],
                        shift = unitInfoBuffers.shift[0],
                        notes = safe_str(unitInfoBuffers.notes),
                        user_id = core.current_user and core.current_user.id or nil,
                        assigned_vehicle_id = assigned_vehicle_id
                    }
                    settings.saveUnitInfo(unit_data_to_save)
                    settings.save()
                    updateRadioParserSign(unit_data_to_save.unitID)
                end                
                imgui.Spacing();

                imgui.Columns(1)
            imgui.EndChild(); imgui.Separator()
            imgui.BeginChild("UnitInfoBottom", imgui.new('ImVec2', 0, 0), false)
                imgui.Columns(2, "UnitInfoBottomColumns", false)
                imgui.Text("Unit Activity Log")
                imgui.BeginChild("UnitLog", imgui.new('ImVec2', 0, -120), true)
                for _, entry in ipairs(unitActivityLog) do 
                    if entry and entry.time and entry.event and entry.details then
                        imgui.Text(string.format("[%s] %s: %s", entry.time, entry.event, entry.details)) 
                    end
                end
                imgui.EndChild()
                imgui.NextColumn()
                
                imgui.Columns(1)
            imgui.EndChild()
            imgui.EndTabItem()
        end

        if imgui.BeginTabItem("CAD Settings") then
            local content_width = imgui.GetContentRegionAvail().x
            local child_width = (content_width - imgui.GetStyle().ItemSpacing.x) / 2

            imgui.BeginChild("SettingsLeft", imgui.new('ImVec2', child_width, 0), true)
                imgui.Text("Functional Settings"); imgui.Separator()

                local show_notif = imgui.new.bool(settings.get('ui_settings', 'show_notifications', true))
                if imgui.Checkbox("Enable 911 Call Notifications in Chat (need restart)", show_notif) then
                    settings.set('ui_settings', 'show_notifications', show_notif[0])
                    settings.save()
                end

                local alpr_sound = imgui.new.bool(settings.get('audio_settings', 'notification_sounds', true))
                if imgui.Checkbox("Enable ALPR sound alert", alpr_sound) then
                    settings.set('audio_settings', 'notification_sounds', alpr_sound[0])
                    settings.save()
                end

                local remember_tab = imgui.new.bool(settings.get('ui_settings', 'remember_last_tab', false))
                if imgui.Checkbox("Remember last active tab", remember_tab) then
                    settings.set('ui_settings', 'remember_last_tab', remember_tab[0])
                    settings.save()
                end

                local hide_calls = imgui.new.bool(settings.get('ui_settings', 'hide_placeholder_calls', false))
                if imgui.Checkbox("Hide standart 911 calls", hide_calls) then
                    settings.set('ui_settings', 'hide_placeholder_calls', hide_calls[0])
                    settings.save()
                end

                local disable_auto_sign = imgui.new.bool(settings.get('radio_settings', 'disableAutoSign', false))
                if imgui.Checkbox("Disable Auto Sign in radio (Need restart :( ))", disable_auto_sign) then
                    settings.set('radio_settings', 'disableAutoSign', disable_auto_sign[0])
                    settings.save()
                end

                imgui.Spacing(); imgui.Separator(); imgui.Spacing()

                if imgui.Button("Logout", imgui.new('ImVec2', 200, 30)) then
                    core.logout()
                    UI.login_window[0] = true
                    UI.mdt[0] = false
                end
                if imgui.IsItemHovered() then
                    imgui.SetTooltip("Log out of the current account and return to the login screen.")
                end
            imgui.EndChild()

            imgui.SameLine()

            imgui.BeginChild("SettingsRight", imgui.new('ImVec2', 0, 0), true)
                imgui.Text("Keybind Settings"); imgui.Separator()

                local function render_key_binding(label, key_type)
                    imgui.Text(label)
                    imgui.SameLine(150)
                    imgui.Text(safe_str(keyBindBuffers[key_type]):gsub("VK_", ""))
                    imgui.SameLine(250)
                    
                    local button_text = "Bind"
                    if key_being_bound == key_type then
                        button_text = "Press a key..."
                    end

                    if imgui.Button(button_text .. "##" .. key_type, imgui.new('ImVec2', 120, 20)) then
                        key_being_bound = key_type
                    end
                end

                render_key_binding("Open Main Window", "mdt")
                render_key_binding("Open ALPR", "alpr")
                render_key_binding("Open Map", "map")

                if key_being_bound then
                    imgui.TextColored(imgui.ImVec4(1,1,0,1), "Press ESC to cancel binding.")
                end
            imgui.EndChild()

            imgui.EndTabItem()
        end

        imgui.EndTabBar()
    end
    imgui.EndGroup()
    
    imgui.SetCursorPos(imgui.new('ImVec2', left_panel_width + 8, imgui.GetWindowHeight() - bottom_panel_height - 8)); 
    imgui.BeginChild("BottomPanel", imgui.new('ImVec2', -8, bottom_panel_height), false, imgui.WindowFlags.NoScrollbar)
    local bottom_button_size = imgui.new('ImVec2', 270, 68) 
        if imgui.Button("BOLO", bottom_button_size) then UI.bolo_editor[0] = not UI.bolo_editor[0] end; imgui.SameLine() 
        if imgui.Button("ALPR", bottom_button_size) then UI.alpr_window[0] = not UI.alpr_window[0] end; imgui.SameLine() 
        if imgui.Button("MAP", bottom_button_size) then UI.map_window[0] = not UI.map_window[0] end
    imgui.EndChild()
    
    imgui.End()
    imgui.PopStyleVar(2); imgui.PopStyleColor(9)
end

function updateRadioParserSign(new_sign)
    if not new_sign or new_sign == "" then return end
    
    local file_path = "moonloader/lspdradio_settings.txt"
    local lines = {}
    local found = false

    local file = io.open(file_path, "r")
    if file then
        for line in file:lines() do
            if line:match("^userCallsign=") then
                table.insert(lines, "userCallsign=" .. new_sign)
                found = true
            else
                table.insert(lines, line)
            end
        end
        file:close()
    end

    if not found then
        table.insert(lines, "userCallsign=" .. new_sign)
    end

    local out_file = io.open(file_path, "w")
    if out_file then
        out_file:write(table.concat(lines, "\n"))
        out_file:close()
    end
end

function loadUnitInfoFromSettings()
    local loaded_unit_info = settings.getUnitInfo()
    if loaded_unit_info then
        log('UI', log_levels.INFO, 'Loading unit info from settings.')
        safe_copy(unitInfoBuffers.unitID, loaded_unit_info.unitID or "")
        unitInfoBuffers.unitType[0] = loaded_unit_info.unitType or 0
        safe_copy(unitInfoBuffers.officer1_name, loaded_unit_info.officer1_name or "")
        safe_copy(unitInfoBuffers.officer2_name, loaded_unit_info.officer2_name or "")
        unitInfoBuffers.status[0] = loaded_unit_info.status or 4
        safe_copy(unitInfoBuffers.vehiclePlate, loaded_unit_info.vehiclePlate or "")
        unitInfoBuffers.division[0] = loaded_unit_info.division or 0
        safe_copy(unitInfoBuffers.notes, loaded_unit_info.notes or "")
        assigned_vehicle_id = loaded_unit_info.assigned_vehicle_id or nil
    else
        log('UI', log_levels.WARN, 'No saved unit info found, using defaults.')
    end
end

function drawBoloEditor()
    if not UI.bolo_editor[0] then return end

    imgui.SetNextWindowSize(imgui.new('ImVec2', 900, 700), imgui.Cond.FirstUseEver)
    if imgui.Begin("BOLO & Wanted Plates Management", UI.bolo_editor) then
        if imgui.BeginTabBar("ManagementTabs") then
            
            -- #################### BOLO TAB ####################
            if imgui.BeginTabItem("BOLO") then
                if imgui.Button("Create New BOLO") then
                    UI.bolo_creator_window[0] = true
                end
                imgui.Separator()

                local main_content_width = imgui.GetContentRegionAvail().x
                imgui.Columns(2, "BoloLayout", false)
                imgui.SetColumnWidth(0, main_content_width * 0.35)

                imgui.BeginChild("BoloList", imgui.new('ImVec2', 0, 0), true)
                if #data_storage.bolos == 0 then
                    imgui.Text("No active BOLOs.")
                else
                    for i, bolo in ipairs(data_storage.bolos) do
                        local date_part = "??-??"
                        if bolo.timestamp_created then
                            local y, m, d = tostring(bolo.timestamp_created):match("(%d%d%d%d)-(%d%d)-(%d%d)")
                            if m and d then
                                date_part = string.format("%s-%s", d, m)
                            end
                        end
                        
                        local id_part = tostring(bolo.id or "N/A")
                        local subject_part = tostring(bolo.subject_name or "N/A")
                        local status_color = boloStatusColors[bolo.status or "In Progress"] or boloStatusColors["In Progress"]

                        if imgui.Selectable("##bolo_selectable" .. i, selected_bolo_index == i, 0, imgui.new('ImVec2', 0, 20)) then
                            selected_bolo_index = i
                            safe_copy(bolo_note_buffer, "")
                        end
                        imgui.SameLine()
                        imgui.Text(string.format("[%s-%s]", date_part, id_part))
                        imgui.SameLine()
                        imgui.TextColored(status_color, subject_part)
                    end
                end
                imgui.EndChild()
                imgui.NextColumn()

                imgui.BeginChild("BoloDetails", imgui.new('ImVec2', 0, 0), true)
                if selected_bolo_index and data_storage.bolos[selected_bolo_index] then
                    local bolo = data_storage.bolos[selected_bolo_index]
                    imgui.Text("BOLO Details: #" .. tostring(bolo.id or 'N/A')); imgui.Separator() 
                    
                    local label_color = imgui.ImVec4(1,1,0,1)
                    local text_color = imgui.ImVec4(1,1,1,1)

                    renderLabeledText("Type:", tostring(bolo.type or "N/A"), label_color, text_color)
                    renderLabeledText("Subject:", tostring(bolo.subject_name or "N/A"), label_color, text_color)
                    
                    local current_status_idx = 0
                    for i, status_name in ipairs(boloStatuses) do
                        if status_name == (bolo.status or "In Progress") then
                            current_status_idx = i - 1
                            break
                        end
                    end
                    local status_combo_buffer = imgui.new.int(current_status_idx)
                    imgui.Text("Status:")
                    imgui.SameLine()
                    imgui.PushItemWidth(150)
                    if imgui.Combo("##BoloStatus", status_combo_buffer, boloStatuses_c, #boloStatuses) then
                        local new_status_idx = status_combo_buffer[0] + 1
                        local new_status = boloStatuses[new_status_idx]
                        if bolo.id and new_status then
                            updateBoloStatus(bolo.id, new_status)
                        end
                    end
                    imgui.PopItemWidth()

                    renderLabeledText("Created:", tostring(bolo.timestamp_created or "N/A"):gsub("T", " "):gsub("%.%d+Z", ""), label_color, text_color)

                    imgui.Separator(); imgui.Text("Description:"); imgui.TextWrapped(tostring(bolo.description or "N/A"))
                    imgui.Separator(); imgui.Text("Crime/Reason:"); imgui.TextWrapped(tostring(bolo.crime_summary or "N/A"))
                    imgui.Separator(); imgui.Text("Last Location:"); imgui.TextWrapped(tostring(bolo.last_location or "N/A") )
                    
                    imgui.Separator(); imgui.Text("Event Log:")
                    imgui.BeginChild("BoloEventLog", imgui.new('ImVec2', 0, 150), true)
                    if bolo.event_log and type(bolo.event_log) == 'table' and #bolo.event_log > 0 then
                        for _, event in ipairs(bolo.event_log) do
                            imgui.TextWrapped(string.format("[%s] %s", event.time, event.event))
                        end
                    else
                        imgui.Text("No events for this BOLO.")
                    end
                    imgui.EndChild()

                    imgui.InputTextMultiline("##bolo_note", bolo_note_buffer, ffi.sizeof(bolo_note_buffer), imgui.new('ImVec2', -1, 40))
                    if imgui.Button("Add Note", imgui.new('ImVec2', -1, 30)) then
                        local note_text = safe_str(bolo_note_buffer)
                        if note_text ~= "" and bolo.id then
                            addBoloNote(bolo.id, note_text)
                            ffi.copy(bolo_note_buffer, "")
                        end
                    end

                else
                    imgui.Text("Select a BOLO from the list to see details.")
                end
                imgui.EndChild()
                imgui.Columns(1)
                imgui.EndTabItem()
            end

            -- #################### WANTED PLATES TAB ####################
            if imgui.BeginTabItem("Wanted Plates") then
                imgui.Text("Add New Wanted Plate")
                imgui.InputText("##new_plate", new_wanted_plate_buffer, ffi.sizeof(new_wanted_plate_buffer))
                imgui.SameLine()
                if imgui.Button("Add Plate") then
                    addWantedPlate(safe_str(new_wanted_plate_buffer))
                end
                imgui.Separator()
                
                imgui.Text("Current Wanted Plates")
                imgui.BeginChild("WantedPlatesList", imgui.new('ImVec2', 0, 0), true)
                if #data_storage.wanted_plates == 0 then
                    imgui.Text("No plates are currently marked as wanted.")
                else
                    for i, plate_entry in ipairs(data_storage.wanted_plates) do
                        imgui.Text(tostring(plate_entry.plate))
                        imgui.SameLine(imgui.GetWindowWidth() - 100)
                        if imgui.SmallButton("Remove##" .. i) then
                            removeWantedPlate(plate_entry.id)
                        end
                    end
                end
                imgui.EndChild()
                imgui.EndTabItem()
            end

            imgui.EndTabBar()
        end
    end
    imgui.End()
end

imgui.OnInitialize(function()
    safe_copy(keyBindBuffers.mdt, settings.get('controls_settings', 'open_mdt_key', 'VK_F2'))
    safe_copy(keyBindBuffers.alpr, settings.get('controls_settings', 'open_alpr_key', 'VK_1'))
    safe_copy(keyBindBuffers.map, settings.get('controls_settings', 'open_map_key', 'VK_M'))

    loadUnitInfoFromSettings()
    imgui.GetIO().IniFilename = nil
    local font_path = getFolderPath(0x14) .. '/arialbd.TTF'
    if doesFileExist(font_path) then
        fonts[18] = imgui.GetIO().Fonts:AddFontFromFileTTF(font_path, 18, nil, imgui.GetIO().Fonts:GetGlyphRangesCyrillic())
        fonts[22] = imgui.GetIO().Fonts:AddFontFromFileTTF(font_path, 22, nil, imgui.GetIO().Fonts:GetGlyphRangesCyrillic())
    else log('UI', log_levels.WARN, "CAD font not found at: " .. font_path) end

    divisionOptions_c = imgui.new['const char*'][#comboBoxData.division](comboBoxData.division)
    unitTypeOptions_c = imgui.new['const char*'][#comboBoxData.unitType](comboBoxData.unitType)
    shiftOptions_c = imgui.new['const char*'][#comboBoxData.shift](comboBoxData.shift)
    
    boloTypes_c = imgui.new['const char*'][#boloTypes](boloTypes)
    boloStatuses_c = imgui.new['const char*'][#boloStatuses](boloStatuses)

    local sound_path = string.format("%s/moonloader/cad_system/resource/sound/SirenToggle.wav", getGameDirectory())
    if doesFileExist(sound_path) then
        alpr_wanted_sound = loadAudioStream(sound_path)
    else
        log('UI', log_levels.WARN, "ALPR wanted sound not found at: " .. sound_path)
    end

    local panic_sound_path = string.format("%s/moonloader/cad_system/resource/sound/PANIC_BUTTON.mp4", getGameDirectory())
    if doesFileExist(panic_sound_path) then
        panic_sound = loadAudioStream(panic_sound_path)
    else
        log('UI', log_levels.WARN, "PANIC button sound not found at: " .. panic_sound_path)
    end

    local cad_system_path = getGameDirectory() .. "/moonloader/cad_system/"
    local resource_dir = cad_system_path .. "resource/"

    local function load_texture(filename)
        local path = resource_dir .. filename
        if doesFileExist(path) then
            local file = io.open(path, "rb")
            if file then
                local data = file:read("*a")
                file:close()
                local texture = imgui.CreateTextureFromFileInMemory(data, #data)
                if texture then
                    log('UI', log_levels.INFO, "Map texture loaded: " .. filename)
                    return texture
                else
                    log('UI', log_levels.ERROR, "Failed to create texture from memory for: " .. filename)
                end
            else
                log('UI', log_levels.ERROR, "Could not open map texture file: " .. filename)
            end
        else
            log('UI', log_levels.WARN, "Map texture not found: " .. path)
        end
        return nil
    end

    for i = 1, 16 do
        map_tile_textures.standard[i] = load_texture(i .. ".png")
        map_tile_textures.k[i] = load_texture(i .. "k.png")
    end
    unit_marker_texture = load_texture("radar_centre.png")
end)




local unit_marker_texture = nil
local next_marker_id = 1
local context_marker = nil
local show_marker_edit_modal = imgui.new.bool(false)
local marker_edit_buffer = {
    text = imgui.new.char[128](),
    radius = imgui.new.float(100.0)
}

local last_map_window_pos = nil
local map_data_loaded = false
local map_markers = {}
local map_lines = {}
local map_interaction_mode = "pan"
local map_context_menu_unit = nil
local map_context_menu_pos = nil
local latched_hovered_item = nil
local is_context_menu_open = false
local active_line_points = {}

function send_map_request(action, payload, callback)
    log('UI', log_levels.DEBUG, string.format("Sending map request: %s", action))
    send_ws_request('map', action, payload, callback)
end

function handle_map_update(response)
    local action = response.action
    local payload = response.payload
    log('UI', log_levels.INFO, string.format("Handling map update: %s", action))

    if not payload then return end

    if action == 'marker_added' then
        local marker = payload
        if marker.marker_type == 'line' then
            marker.points_data = json.decode(marker.points_data)
            table.insert(map_lines, marker)
        else
            table.insert(map_markers, marker)
        end
    elseif action == 'marker_removed' then
        local id_to_remove = payload.id
        for i = #map_markers, 1, -1 do
            if map_markers[i].id == id_to_remove then
                table.remove(map_markers, i)
                break
            end
        end
        for i = #map_lines, 1, -1 do
            if map_lines[i].id == id_to_remove then
                table.remove(map_lines, i)
                break
            end
        end
    elseif action == 'all_markers_cleared' and payload.type == 'temporary' then
        local remaining_markers = {}
        local remaining_lines = {}
        for _, marker in ipairs(map_markers) do
            if marker.is_permanent == 1 then
                table.insert(remaining_markers, marker)
            end
        end
        for _, line in ipairs(map_lines) do
            if line.is_permanent == 1 then
                table.insert(remaining_lines, line)
            end
        end
        map_markers = remaining_markers
        map_lines = remaining_lines
    elseif action == 'marker_updated' then
        local updated_marker = payload
        local found = false
        for i, marker in ipairs(map_markers) do
            if marker.id == updated_marker.id then
                map_markers[i] = updated_marker
                found = true
                break
            end
        end
        if not found then
             for i, line in ipairs(map_lines) do
                if line.id == updated_marker.id then
                    updated_marker.points_data = json.decode(updated_marker.points_data)
                    map_lines[i] = updated_marker
                    break
                end
            end
        end
    elseif action == 'markers_removed_stale' then
        local ids_to_remove = payload.ids
        local remaining_markers = {}
        local remaining_lines = {}
        for _, marker in ipairs(map_markers) do
            local should_keep = true
            for _, id in ipairs(ids_to_remove) do
                if marker.id == id then
                    should_keep = false
                    break
                end
            end
            if should_keep then table.insert(remaining_markers, marker) end
        end
        for _, line in ipairs(map_lines) do
            local should_keep = true
            for _, id in ipairs(ids_to_remove) do
                if line.id == id then
                    should_keep = false
                    break
                end
            end
            if should_keep then table.insert(remaining_lines, line) end
        end
        map_markers = remaining_markers
        map_lines = remaining_lines
    end
end

function screenToWorld(screen_x, screen_y, window_pos)
    local map_total_width_unzoomed = 205 * 4
    local map_total_height_unzoomed = 205 * 4

    local map_x_unzoomed = (screen_x - window_pos.x - map_offset_x) / map_zoom
    local map_y_unzoomed = (screen_y - window_pos.y - map_offset_y) / map_zoom

    local world_x = (map_x_unzoomed / map_total_width_unzoomed) * 6000 - 3000
    local world_y = -((map_y_unzoomed / map_total_height_unzoomed) * 6000 - 3000)

    return world_x, world_y
end

local pending_checkpoint_for_call_id = nil

function cadui_module.setPendingCheckpointForCall(call_id)
    if call_id then
        log('UI', log_levels.INFO, 'Pending checkpoint interception for call ID: ' .. tostring(call_id))
        pending_checkpoint_for_call_id = call_id
    end
end

function cadui_module.toggleMap()
    UI.map_window[0] = not UI.map_window[0]
end

function cadui_module.toggleALPR()
    -- If the window is currently open, always allow it to be closed.
    if UI.alpr_window[0] then
        UI.alpr_window[0] = false
        return
    end

    -- If the window is closed, only open it if the player is in a patrol car.
    if not UI.alpr_window[0] and cadui_module.isPlayerInPatrolCar() then
        UI.alpr_window[0] = true
    end
end



function renderMarkerEditModal()
    if not show_marker_edit_modal[0] or not context_marker then return end

    imgui.SetNextWindowSize(imgui.new('ImVec2', 300, 200), imgui.Cond.FirstUseEver)
    local sw, sh = getScreenResolution()
    local window_pos = imgui.new('ImVec2', sw / 2, sh / 2)
    imgui.SetNextWindowPos(window_pos, imgui.Cond.FirstUseEver, imgui.new('ImVec2', 0.5, 0.5))
    
    if imgui.Begin("Edit Marker##marker_edit_modal", show_marker_edit_modal) then
        imgui.InputText("Label", marker_edit_buffer.text, ffi.sizeof(marker_edit_buffer.text))
        
        if context_marker.marker_type == 'circle' then
            imgui.InputFloat("Radius", marker_edit_buffer.radius, 10.0, 50.0, '%.1f')
        end

        if imgui.Button("Save", imgui.new('ImVec2', -1, 0)) then
            context_marker.label = safe_str(marker_edit_buffer.text)
            if context_marker.marker_type == 'circle' then
                context_marker.radius = marker_edit_buffer.radius[0]
            end
            send_map_request('update_marker', context_marker)
            show_marker_edit_modal[0] = false
        end
    end
    imgui.End()
end

function renderMapWindow()
    if not UI.map_window[0] then 
        map_data_loaded = false
        return
    end

    local function findUnitById(unit_id)
        if not unit_id then return nil end
        for _, unit in ipairs(data_storage.units) do
            if unit.id == unit_id or unit.unitID == unit_id then
                return unit
            end
        end
        return nil
    end

    if not map_data_loaded then
        send_map_request('fetch_markers', {}, function(data, err) 
            if err then
                log('UI', log_levels.ERROR, "Failed to fetch map markers: " .. tostring(err))
                return
            end
            if data and data.payload then
                log('UI', log_levels.INFO, "Successfully fetched " .. #data.payload .. " markers.")
                map_markers = {}
                map_lines = {}
                for _, marker in ipairs(data.payload) do
                    if marker.marker_type == 'line' then
                        marker.points_data = json.decode(marker.points_data)
                        table.insert(map_lines, marker)
                    else
                        table.insert(map_markers, marker)
                    end
                end
                map_data_loaded = true
            end
        end)
        if imgui.Begin("Global Map", UI.map_window) then
            imgui.Text("Loading map data...")
            imgui.End()
        end
        return
    end

    local sw, sh = getScreenResolution()
    local window_width = 820
    local window_height = 840
    imgui.SetNextWindowSize(imgui.new('ImVec2', window_width, window_height), imgui.Cond.FirstUseEver)
    imgui.SetNextWindowPos(imgui.new('ImVec2', (sw - window_width) / 2, (sh - window_height) / 2), imgui.Cond.FirstUseEver)

    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.new('ImVec2', 0, 0))
    if imgui.Begin("Global Map", UI.map_window, imgui.WindowFlags.NoResize + imgui.WindowFlags.MenuBar) then
        imgui.PopStyleVar()

        if imgui.BeginMenuBar() then
            if imgui.Button("Select") then map_interaction_mode = "pan"; active_line_points = {} end
            if imgui.Button("Place Point") then map_interaction_mode = "point"; active_line_points = {} end
            if imgui.Button("Place Circle") then map_interaction_mode = "circle"; active_line_points = {} end
            if imgui.Button("Draw Line") then map_interaction_mode = "line"; active_line_points = {} end
            imgui.EndMenuBar()
        end

        imgui.BeginChild("MapCanvas", imgui.new('ImVec2', -1, -1), false, imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse)

        local io = imgui.GetIO()
        local canvas_pos = imgui.GetCursorScreenPos()
        local canvas_size = imgui.GetContentRegionAvail()
        local mouse_pos = imgui.GetMousePos()

        if imgui.IsWindowHovered() then
            if io.MouseWheel ~= 0 then
                local old_zoom = map_zoom
                local new_zoom = map_zoom + io.MouseWheel * 0.1
                map_zoom = math.max(map_min_zoom, math.min(map_max_zoom, new_zoom))
                local mouse_x_in_canvas = mouse_pos.x - canvas_pos.x
                local mouse_y_in_canvas = mouse_pos.y - canvas_pos.y
                map_offset_x = mouse_x_in_canvas - (mouse_x_in_canvas - map_offset_x) * (map_zoom / old_zoom)
                map_offset_y = mouse_y_in_canvas - (mouse_y_in_canvas - map_offset_y) * (map_zoom / old_zoom)
            end
        end

        local map_width_zoomed = 820 * map_zoom
        local map_height_zoomed = 820 * map_zoom
        map_offset_x = math.max(map_offset_x, -(map_width_zoomed - canvas_size.x))
        map_offset_x = math.min(map_offset_x, 0)
        map_offset_y = math.max(map_offset_y, -(map_height_zoomed - canvas_size.y))
        map_offset_y = math.min(map_offset_y, 0)

        local draw_list = imgui.GetWindowDrawList()
        if map_tile_textures and map_tile_textures.standard and #map_tile_textures.standard > 0 then
            for y = 0, 3 do
                for x = 0, 3 do
                    local tile_index = y * 4 + x + 1
                    local texture = map_tile_textures.standard[tile_index]
                    if texture then
                        local tile_size = 205 * map_zoom
                        local tile_x = canvas_pos.x + map_offset_x + x * tile_size
                        local tile_y = canvas_pos.y + map_offset_y + y * tile_size
                        draw_list:AddImage(texture, imgui.new('ImVec2', tile_x, tile_y), imgui.new('ImVec2', tile_x + tile_size, tile_y + tile_size))
                    end
                end
            end
        else
            imgui.Text("Map textures not loaded!")
        end

        local hovered_item = nil
        
        local status_colors = { 
            green = 0xFF228B22, -- ForestGreen (Available)
            orange = 0xFF008CFF, -- OrangeRed (En Route)
            blue = 0xFFFF7F50,   -- Coral (On Scene)
            red = 0xFF3232CD,   -- Crimson (Busy)
            gray = 0xFF808080    -- Gray (Out of Service)
        }
        local patrol_status_color_map = { status_colors.green, status_colors.orange, status_colors.blue, status_colors.red, status_colors.gray }

        for _, unit in ipairs(data_storage.units) do
            if unit.pos_x and unit.pos_y and unit.is_active then
                local map_x_unzoomed = (unit.pos_x + 3000) / 6000 * (205 * 4)
                local map_y_unzoomed = (-unit.pos_y + 3000) / 6000 * (205 * 4)
                local final_map_x = canvas_pos.x + map_offset_x + map_x_unzoomed * map_zoom
                local final_map_y = canvas_pos.y + map_offset_y + map_y_unzoomed * map_zoom
                
                local status_idx = (tonumber(unit.status) or 4) + 1
                local unit_color = patrol_status_color_map[status_idx] or status_colors.gray

                draw_list:AddCircleFilled(imgui.new('ImVec2', final_map_x, final_map_y), 6, 0xFF000000)
                draw_list:AddCircleFilled(imgui.new('ImVec2', final_map_x, final_map_y), 5, unit_color)

                local status_text = comboBoxData.status[status_idx] or "Unknown"
                local unit_text = unit.unitID or 'N/A'
                local text_color_white = 0xFFFFFFFF
                local text_color_gray = 0xFFBBBBBB
                local outline_color = 0xFF000000

                drawOutlinedText(draw_list, imgui.new('ImVec2', final_map_x + 12, final_map_y - 8), unit_text, text_color_white, outline_color)
                drawOutlinedText(draw_list, imgui.new('ImVec2', final_map_x + 12, final_map_y + 4), status_text, text_color_gray, outline_color)

                local dist_sq = (mouse_pos.x - final_map_x)^2 + (mouse_pos.y - final_map_y)^2
                if dist_sq < (10)^2 then hovered_item = {type = 'unit', data = unit} end
            end
        end

        -- NEW CODE BLOCK STARTS HERE
        for _, call in ipairs(data_storage.calls) do
            if call.map_pos then
                local call_map_x_unzoomed = (call.map_pos.x + 3000) / 6000 * (205 * 4)
                local call_map_y_unzoomed = (-call.map_pos.y + 3000) / 6000 * (205 * 4)
                local call_final_map_x = canvas_pos.x + map_offset_x + call_map_x_unzoomed * map_zoom
                local call_final_map_y = canvas_pos.y + map_offset_y + call_map_y_unzoomed * map_zoom

                -- Draw call marker (a red square)
                draw_list:AddRectFilled(imgui.new('ImVec2', call_final_map_x - 5, call_final_map_y - 5), imgui.new('ImVec2', call_final_map_x + 5, call_final_map_y + 5), 0xFF0000FF)
                drawOutlinedText(draw_list, imgui.new('ImVec2', call_final_map_x + 8, call_final_map_y - 6), "#" .. tostring(call.id), 0xFFFFFFFF, 0xFF000000)

                -- Draw lines to assigned units
                if call.assigned_units and #call.assigned_units > 0 then
                    for _, unitID in ipairs(call.assigned_units) do
                        local unit = findUnitById(unitID)
                        if unit and unit.pos_x and unit.pos_y then
                            local unit_map_x_unzoomed = (unit.pos_x + 3000) / 6000 * (205 * 4)
                            local unit_map_y_unzoomed = (-unit.pos_y + 3000) / 6000 * (205 * 4)
                            local unit_final_map_x = canvas_pos.x + map_offset_x + unit_map_x_unzoomed * map_zoom
                            local unit_final_map_y = canvas_pos.y + map_offset_y + unit_map_y_unzoomed * map_zoom
                            
                            draw_list:AddLine(imgui.new('ImVec2', call_final_map_x, call_final_map_y), imgui.new('ImVec2', unit_final_map_x, unit_final_map_y), 0x90FFFFFF, 1.5)
                        end
                    end
                end
            end
        end
        -- NEW CODE BLOCK ENDS HERE

        for _, marker in ipairs(map_markers) do
            if marker and marker.points_data then
                local points = json.decode(marker.points_data)
                if not points or not points[1] then goto continue end
                local map_x_unzoomed = (points[1].x + 3000) / 6000 * (205 * 4)
                local map_y_unzoomed = (-points[1].y + 3000) / 6000 * (205 * 4)
                local final_map_x = canvas_pos.x + map_offset_x + map_x_unzoomed * map_zoom
                local final_map_y = canvas_pos.y + map_offset_y + map_y_unzoomed * map_zoom
                local color = marker.is_permanent == 1 and 0xFF00D8FF or 0xFF00FF00
                if marker.marker_type == 'point' then
                    draw_list:AddCircleFilled(imgui.new('ImVec2', final_map_x, final_map_y), 6, 0xFF000000)
                    draw_list:AddCircleFilled(imgui.new('ImVec2', final_map_x, final_map_y), 5, color)
                    if marker.label then drawOutlinedText(draw_list, imgui.new('ImVec2', final_map_x + 8, final_map_y - 8), marker.label, 0xFFFFFFFF) end
                elseif marker.marker_type == 'circle' and marker.radius then
                    local radius_on_map = marker.radius / 6000 * (205 * 4) * map_zoom
                    local transparent_color = bit.bor(bit.band(color, 0x00FFFFFF), 0x33000000)
                    draw_list:AddCircleFilled(imgui.new('ImVec2', final_map_x, final_map_y), radius_on_map, transparent_color, 32)
                    draw_list:AddCircle(imgui.new('ImVec2', final_map_x, final_map_y), radius_on_map, color, 32, 2.0)
                    if marker.label then drawOutlinedText(draw_list, imgui.new('ImVec2', final_map_x + 8, final_map_y - 8), marker.label, 0xFFFFFFFF) end
                elseif marker.marker_type == 'call_waypoint' then
                    local call_color = 0xFF0000FF -- Red
                    local outline_color = 0xFF000000 -- Black
                    -- Draw outline first
                    draw_list:AddRect(imgui.new('ImVec2', final_map_x - 6, final_map_y - 6), imgui.new('ImVec2', final_map_x + 6, final_map_y + 6), outline_color, 0.0, 0, 2.0)
                    -- Draw filled rectangle
                    draw_list:AddRectFilled(imgui.new('ImVec2', final_map_x - 5, final_map_y - 5), imgui.new('ImVec2', final_map_x + 5, final_map_y + 5), call_color)

                    if marker.label then drawOutlinedText(draw_list, imgui.new('ImVec2', final_map_x + 12, final_map_y - 8), marker.label, 0xFFFFFFFF) end

                    -- Find the corresponding call and draw lines to assigned units
                    local call_data
                    if marker.related_call_id then
                        for _, call in ipairs(data_storage.calls) do
                            if call.id == marker.related_call_id then
                                call_data = call
                                break
                            end
                        end
                    end

                    if call_data and call_data.assigned_units and #call_data.assigned_units > 0 then
                        local marker_world_pos = json.decode(marker.points_data)[1]

                        for _, unitID in ipairs(call_data.assigned_units) do
                            local unit_data
                            for _, unit in ipairs(data_storage.units) do
                                if unit.unitID == unitID then
                                    unit_data = unit
                                    break
                                end
                            end

                            if unit_data and unit_data.pos_x and unit_data.pos_y then
                                -- Calculate unit's screen position
                                local unit_map_x_unzoomed = (unit_data.pos_x + 3000) / 6000 * (205 * 4)
                                local unit_map_y_unzoomed = (-unit_data.pos_y + 3000) / 6000 * (205 * 4)
                                local unit_final_map_x = canvas_pos.x + map_offset_x + unit_map_x_unzoomed * map_zoom
                                local unit_final_map_y = canvas_pos.y + map_offset_y + unit_map_y_unzoomed * map_zoom

                                -- Draw red line from unit to call
                                draw_list:AddLine(imgui.new('ImVec2', final_map_x, final_map_y), imgui.new('ImVec2', unit_final_map_x, unit_final_map_y), 0x900000FF, 1.5)

                                -- Calculate distance and draw it
                                local distance = math.sqrt((unit_data.pos_x - marker_world_pos.x)^2 + (unit_data.pos_y - marker_world_pos.y)^2)
                                local mid_x = (final_map_x + unit_final_map_x) / 2
                                local mid_y = (final_map_y + unit_final_map_y) / 2
                                drawOutlinedText(draw_list, imgui.new('ImVec2', mid_x, mid_y), string.format("%.0fm", distance), 0xFFFFFFFF)
                            end
                        end
                    end
                end
                local dist_sq = (mouse_pos.x - final_map_x)^2 + (mouse_pos.y - final_map_y)^2
                if dist_sq < (10)^2 then hovered_item = {type = 'marker', data = marker} end
            end
            ::continue::
        end
        
        for _, line in ipairs(map_lines) do
            if #line.points_data >= 2 then
                for i = 1, #line.points_data - 1 do
                    local p1 = line.points_data[i]
                    local p2 = line.points_data[i+1]
                    local map_x1_unzoomed = (p1.x + 3000) / 6000 * (205 * 4)
                    local map_y1_unzoomed = (-p1.y + 3000) / 6000 * (205 * 4)
                    local final_map_x1 = canvas_pos.x + map_offset_x + map_x1_unzoomed * map_zoom
                    local final_map_y1 = canvas_pos.y + map_offset_y + map_y1_unzoomed * map_zoom
                    local map_x2_unzoomed = (p2.x + 3000) / 6000 * (205 * 4)
                    local map_y2_unzoomed = (-p2.y + 3000) / 6000 * (205 * 4)
                    local final_map_x2 = canvas_pos.x + map_offset_x + map_x2_unzoomed * map_zoom
                    local final_map_y2 = canvas_pos.y + map_offset_y + map_y2_unzoomed * map_zoom
                    draw_list:AddLine(imgui.new('ImVec2', final_map_x1, final_map_y1), imgui.new('ImVec2', final_map_x2, final_map_y2), 0xFF00FF00, 2.0)
                end
            end
        end

        if map_interaction_mode == "line" and #active_line_points > 0 then
            if #active_line_points >= 2 then
                for i = 1, #active_line_points - 1 do
                    local p1 = active_line_points[i]
                    local p2 = active_line_points[i+1]
                    local map_x1_unzoomed = (p1.x + 3000) / 6000 * (205 * 4)
                    local map_y1_unzoomed = (-p1.y + 3000) / 6000 * (205 * 4)
                    local final_map_x1 = canvas_pos.x + map_offset_x + map_x1_unzoomed * map_zoom
                    local final_map_y1 = canvas_pos.y + map_offset_y + map_y1_unzoomed * map_zoom
                    local map_x2_unzoomed = (p2.x + 3000) / 6000 * (205 * 4)
                    local map_y2_unzoomed = (-p2.y + 3000) / 6000 * (205 * 4)
                    local final_map_x2 = canvas_pos.x + map_offset_x + map_x2_unzoomed * map_zoom
                    local final_map_y2 = canvas_pos.y + map_offset_y + map_y2_unzoomed * map_zoom
                    draw_list:AddLine(imgui.new('ImVec2', final_map_x1, final_map_y1), imgui.new('ImVec2', final_map_x2, final_map_y2), 0xFF00FF00, 2.0)
                end
            end
            local last_point = active_line_points[#active_line_points]
            local map_x_unzoomed = (last_point.x + 3000) / 6000 * (205 * 4)
            local map_y_unzoomed = (-last_point.y + 3000) / 6000 * (205 * 4)
            local final_map_x = canvas_pos.x + map_offset_x + map_x_unzoomed * map_zoom
            local final_map_y = canvas_pos.y + map_offset_y + map_y_unzoomed * map_zoom
            draw_list:AddLine(imgui.new('ImVec2', final_map_x, final_map_y), mouse_pos, 0xFF00FF00, 2.0)
        end

        imgui.SetCursorPos(imgui.new('ImVec2', 0, 0))
        imgui.InvisibleButton("MapInteractionLayer", canvas_size)

        -- Pan the map if dragging with the left mouse button in pan mode.
        if imgui.IsItemActive() and map_interaction_mode == "pan" and imgui.IsMouseDragging(0) then
            map_offset_x = map_offset_x + io.MouseDelta.x
            map_offset_y = map_offset_y + io.MouseDelta.y
        end

        -- In line mode, right-click finishes the line.
        if map_interaction_mode == 'line' then
            if imgui.IsItemHovered() and imgui.IsMouseClicked(1) then
                if #active_line_points >= 2 then
                    send_map_request('add_marker', { marker_type = 'line', points_data = active_line_points, is_permanent = 0 })
                end
                active_line_points = {}
            end
        else
            -- In other modes, use BeginPopupContextItem which is more reliable for opening the menu.
            if imgui.BeginPopupContextItem("MapContextMenu") then
                -- On the first frame the menu is opened, latch the hovered item.
                if not is_context_menu_open then
                    latched_hovered_item = hovered_item
                    is_context_menu_open = true
                end

                -- Build the menu based on the latched item, not the current one.
                if latched_hovered_item then
                    if latched_hovered_item.type == 'marker' then
                        context_marker = latched_hovered_item.data
                        imgui.Text("Edit Marker #" .. tostring(context_marker.id or '?')); imgui.Separator()
                        if imgui.Selectable("Edit...") then
                            safe_copy(marker_edit_buffer.text, context_marker.label or "")
                            marker_edit_buffer.radius[0] = context_marker.radius or 100.0
                            show_marker_edit_modal[0] = true
                        end
                        local toggle_text = context_marker.is_permanent == 1 and "Make Temporary" or "Make Permanent"
                        if imgui.Selectable(toggle_text) then
                            context_marker.is_permanent = 1 - (context_marker.is_permanent or 0)
                            send_map_request('update_marker', context_marker)
                        end
                        if imgui.Selectable("Delete") then
                            send_map_request('remove_marker', { id = context_marker.id })
                        end
                    elseif latched_hovered_item.type == 'unit' then
                        map_context_menu_unit = latched_hovered_item.data
                        imgui.Text("Unit: " .. (map_context_menu_unit.unitID or "N/A")); imgui.Separator()
                        if map_context_menu_unit.pos_x and map_context_menu_unit.pos_y and imgui.Selectable("Copy Coords") then 
                            setClipboardText(string.format("%.2f, %.2f", map_context_menu_unit.pos_x, map_context_menu_unit.pos_y)) 
                        end
                    end
                else
                    if imgui.Selectable("Clear Temporary Markers") then
                        send_map_request('clear_temporary_markers', {})
                    end
                end
                imgui.EndPopup()
            else
                -- If the popup is not open, reset the state.
                is_context_menu_open = false
                latched_hovered_item = nil
            end
        end

        -- Handle left-clicks for placing markers, only if the context menu isn't open.
        if imgui.IsItemHovered() and imgui.IsMouseClicked(0) and not is_context_menu_open then
            local world_x, world_y = screenToWorld(mouse_pos.x, mouse_pos.y, canvas_pos)
            if map_interaction_mode == "point" then
                send_map_request('add_marker', { marker_type = 'point', label = 'Marker', points_data = {{x=world_x, y=world_y}}, is_permanent = 0 })
            elseif map_interaction_mode == "circle" then
                send_map_request('add_marker', { marker_type = 'circle', label = 'Area', points_data = {{x=world_x, y=world_y}}, radius = 100.0, is_permanent = 0 })
            elseif map_interaction_mode == "line" then
                table.insert(active_line_points, {x=world_x, y=world_y})
            end
        end

        imgui.EndChild()

    else
        imgui.PopStyleVar()
    end
    imgui.End()
    renderMarkerEditModal()
end

imgui.OnFrame(
    function()
        return UI.mdt[0] or UI.login_window[0] or UI.alpr_window[0] or UI.alpr_log_window[0] or UI.bolo_editor[0] or UI.bolo_creator_window[0] or UI.map_window[0]
    end,
    function(self)
        if key_being_bound then
            for key_name, key_code in pairs(vkeys) do
                -- Check if the value is a number before passing to IsKeyPressed
                if type(key_code) == 'number' and imgui.IsKeyPressed(key_code, false) then
                    if key_code == vkeys.VK_ESCAPE then
                        key_being_bound = nil
                        break
                    end

                    local target_buffer = keyBindBuffers[key_being_bound]
                    local setting_key = 'open_' .. key_being_bound .. '_key'
                    
                    if target_buffer then
                        ffi.copy(target_buffer, key_name) -- Save the string name (e.g., "VK_F2")
                        settings.set('controls_settings', setting_key, key_name)
                        settings.save()
                        log('UI', log_levels.INFO, string.format("Key '%s' bound to %s", key_name, key_being_bound))
                    end
                    
                    key_being_bound = nil
                    break
                end
            end
        end

        -- Polling logic for checkpoint
        if pending_checkpoint_for_call_id then
            if sampGetPlayerCheckpoint then
                local active, x, y, z = sampGetPlayerCheckpoint()
                if active then
                    log('UI', log_levels.INFO, string.format('Polled and found active checkpoint at %.2f, %.2f, %.2f for call ID %s', x, y, z, pending_checkpoint_for_call_id))
                    
                    local payload = {
                        marker_type = 'call_waypoint',
                        label = 'Call #' .. tostring(pending_checkpoint_for_call_id),
                        points_data = {{x = x, y = y, z = z}}, -- Use real coordinates
                        is_permanent = 0,
                        related_call_id = pending_checkpoint_for_call_id
                    }

                    send_map_request('add_marker', payload, function(data, err)
                        if err then
                            log('UI', log_levels.ERROR, 'Failed to add call checkpoint marker via polling: ' .. tostring(err))
                        else
                            log('UI', log_levels.INFO, 'Successfully sent request for polled checkpoint marker.')
                            UI.map_window[0] = true
                        end
                    end)

                    -- Stop polling
                    pending_checkpoint_for_call_id = nil
                end
            end
        end

        local other_windows_active = UI.mdt[0] or UI.login_window[0] or UI.alpr_log_window[0] or UI.bolo_editor[0] or UI.bolo_creator_window[0]
        -- Make sure cursor is visible when binding a key
        local show_cursor = other_windows_active or (UI.alpr_window[0] and alpr_interaction_mode) or key_being_bound
        
        self.HideCursor = not show_cursor

        if UI.mdt[0] then
            renderMDTWindow()
        end
        if UI.login_window[0] then
            renderLoginWindow()
        end        
        if UI.alpr_window[0] then
            renderALPRWindow()
        end
        if UI.alpr_log_window[0] then
            renderALPRLogWindow()
        end
        if UI.bolo_editor[0] then
            drawBoloEditor()
        end
        if UI.bolo_creator_window[0] then
            drawBoloCreatorWindow()
        end
        if UI.map_window[0] then
            renderMapWindow()
        end
    end
)
function fetchWantedPlates()
    send_ws_request('data', 'fetch_wanted_plates', {}, function(data, err) 
        if err then 
            log('UI', log_levels.ERROR, 'Failed to fetch wanted plates: ' .. tostring(err))
            return 
        end
        if data and data.payload then
            wanted_plates_list = data.payload or {}
            log('UI', log_levels.INFO, 'Successfully fetched and updated ' .. #wanted_plates_list .. ' wanted plates.')
        else
            log('UI', log_levels.ERROR, 'Failed to fetch wanted plates: ' .. tostring(data and data.error or "Unknown error"))
        end
    end)
end

function addWantedPlate(plate)
    if not plate or plate == "" then return end
    send_ws_request('data', 'add_wanted_plate', { plate = plate }, function(data, err) 
        if err then addUnitLogEntry("ERROR", "Failed to add wanted plate: " .. err) return end
        addUnitLogEntry("SYSTEM", "Added plate to wanted list: " .. plate)
        forceDataRefresh()
        safe_copy(new_wanted_plate_buffer, "")
    end)
end

function removeWantedPlate(id)
    if not id then return end
    send_ws_request('data', 'remove_wanted_plate', { id = id }, function(data, err) 
        if err then addUnitLogEntry("ERROR", "Failed to remove wanted plate: " .. err) return end
        addUnitLogEntry("SYSTEM", "Removed plate from wanted list.")
        forceDataRefresh()
    end)
end

function updateCallStatus(call_id, action, unit_id)
    log('UI', log_levels.INFO, string.format("Attempting to %s call %s for unit %s", action, call_id, unit_id))
    local payload = {
        call_id = call_id,
        unit_id = unit_id
    }
    send_ws_request('calls', action, payload, function(data, err) 
        if err then
            log('UI', log_levels.ERROR, "Failed to update call status: " .. tostring(err))
            addUnitLogEntry("ERROR", "Failed to update call status: " .. tostring(err))
        else
            log('UI', log_levels.INFO, "Call status updated successfully. Refreshing data.")
            forceDataRefresh()
        end
    end)
end

function addCallLogEntry(call_id, note_text)
    log('UI', log_levels.INFO, string.format("Attempting to add note to call %s", call_id))
    local payload = {
        call_id = call_id,
        note = note_text,
        unit_id = safe_str(unitInfoBuffers.unitID)
    }
    send_ws_request('calls', 'add_note', payload, function(data, err) 
        if err then
            log('UI', log_levels.ERROR, "Failed to add call note: " .. tostring(err))
            addUnitLogEntry("ERROR", "Failed to add call note: " .. tostring(err))
        else
            log('UI', log_levels.INFO, "Successfully added call note. Refreshing data.")
            forceDataRefresh()
        end
    end)
end

function addBoloNote(bolo_id, note_text)
    log('UI', log_levels.INFO, string.format("Attempting to add note to BOLO %s", bolo_id))
    local payload = {
        bolo_id = bolo_id,
        note = note_text,
        unit_id = safe_str(unitInfoBuffers.unitID)
    }
    send_ws_request('bolos', 'add_note', payload, function(data, err) 
        if err then
            log('UI', log_levels.ERROR, "Failed to add BOLO note: " .. tostring(err))
        else
            log('UI', log_levels.INFO, "Successfully added BOLO note. Refreshing data.")
            forceDataRefresh()
        end
    end)
end

function updateBoloStatus(bolo_id, status)
    log('UI', log_levels.INFO, string.format("Attempting to update BOLO %s status to %s", bolo_id, status))
    local payload = {
        bolo_id = bolo_id,
        status = status,
        unit_id = safe_str(unitInfoBuffers.unitID)
    }
    send_ws_request('bolos', 'update_status', payload, function(data, err) 
        if err then
            log('UI', log_levels.ERROR, "Failed to update BOLO status: " .. tostring(err))
        else
            log('UI', log_levels.INFO, "Successfully updated BOLO status. Refreshing data.")
            forceDataRefresh()
        end
    end)
end

function broadcastUnitStatus(extra_params)
    extra_params = extra_params or {}
    updateCurrentLocation()
    local payload = {
        unitID = safe_str(unitInfoBuffers.unitID),
        unitType = unitInfoBuffers.unitType[0],
        officer1_name = safe_str(unitInfoBuffers.officer1_name),
        officer2_name = safe_str(unitInfoBuffers.officer2_name),
        status = unitInfoBuffers.status[0],
        vehiclePlate = safe_str(unitInfoBuffers.vehiclePlate),
        division = unitInfoBuffers.division[0],
        notes = safe_str(unitInfoBuffers.notes),
        location = currentLocation,
        is_active = (unitInfoBuffers.status[0] ~= 4),
        vehicleId = assigned_vehicle_id, -- Use the manually assigned vehicle ID
        user_id = core.current_user and core.current_user.id or nil
    }
    for k, v in pairs(extra_params) do payload[k] = v end

    local action = 'form_or_update_crew'

    log('UI', log_levels.INFO, "--- BROADCASTING UNIT STATUS ---")
    log('UI', log_levels.INFO, "Action: " .. action)
    log('UI', log_levels.INFO, "Payload: " .. json.encode(payload))

    send_ws_request('unit', action, payload, function(data, err) 
        if err then
            addUnitLogEntry("ERROR", "Failed to broadcast unit status: " .. err)
        elseif data and data.success and data.payload then
            log('UI', log_levels.INFO, "Unit status broadcast successful, payload received.")
            events.trigger('cad:unit_updated', data.payload)
        end
    end)
end

function addUnitLogEntry(event_type, details)
    if not unitActivityLog or type(unitActivityLog) ~= "table" then unitActivityLog = {} end

    local allowed_unit_log_types = { ["STATUS"] = true, ["CALL"] = true, ["ERROR"] = true, ["OFFICER"] = true, ["ALPR"] = true, ["REQUEST"] = true, ["VEHICLE"] = true }
    
    if not allowed_unit_log_types[event_type] then return end
    
    local entry = { time = os.date("%H:%M:%S"), event = event_type, details = details }

    table.insert(unitActivityLog, 1, entry)
    if #unitActivityLog > 50 then table.remove(unitActivityLog, #unitActivityLog) end
end

function setUnitActiveStatus(isActive)
    local status_code = isActive and 0 or 4
    unitInfoBuffers.status[0] = status_code
    local log_message = isActive and "Unit is now ON DUTY (10-8)" or "Unit is now OFF DUTY"
    addUnitLogEntry("STATUS", log_message)
    broadcastUnitStatus({ is_active = isActive and 'true' or 'false' })
end



function validateTokenOnStartup()
    log('UI', log_levels.DEBUG, 'validateTokenOnStartup: Starting token validation.')
    if not token or token == "" then
        log('UI', log_levels.DEBUG, 'validateTokenOnStartup: No token found. Waiting for user login.')
        return
    end

    copas.addthread(function()
        log('UI', log_levels.DEBUG, 'validateTokenOnStartup: Thread created, validating stored token.')
        local params = { action = "validateToken", token = token }
        local data, err = copas.await(copas.http.request{ url = get_server_url(), params = params, method = "GET" })

        if data and data.success then
            log('UI', log_levels.INFO, 'validateTokenOnStartup: Token is valid. Pre-loading data.')
            onSuccessfulLogin()
        else
            log('UI', log_levels.WARN, 'validateTokenOnStartup: Stored token is invalid. Clearing token.')
            token = ""
            settings.set("user_settings", "token", "")
            settings.save()
        end
    end)
end

cadui_module.shutdown = function()
    log('UI', log_levels.INFO, 'Shutting down UI background threads.')
    threads_started = false
end

cadui_module.toggleMDT = function()
    if not core.isAuthenticated() then
        log('UI', log_levels.INFO, "MDT toggled but user not coreenticated. Showing login window.")
        UI.login_window[0] = not UI.login_window[0]
        return
    end
    UI.mdt[0] = not UI.mdt[0]
    log('UI', log_levels.INFO, "MDT window toggled " .. (UI.mdt[0] and "ON" or "OFF"))
    if UI.mdt[0] then
        forceDataRefresh()
    end
end

cadui_module.initialize = function(deps)
    events = deps.events
    core = deps.core
    cad_websocket = deps.websocket
    json = deps.json
    settings = deps.settings
    copas = deps.copas
    log = deps.log
    log_levels = deps.log_levels
    safe_str = deps.safe_str
    cars = deps.cars
    safe_copy = deps.safe_copy

    radioConfig = {
        userCallsign = "Unknown",
        notificationsEnabled = settings.get("radio_settings", "notifications", true),
        chatEnabled = false,
        radioVolume = settings.get("radio_settings", "volume", 0.5),
        logStatusChanges = settings.get("log_settings", "status_changes", true),
        logDataChanges = settings.get("log_settings", "data_changes", true),
        logAllEvents = settings.get("log_settings", "all_events", false)
    }

    local saved_username = settings.get("user_settings", "username", "")
    if saved_username ~= "" then
        ffi.copy(core.login_window.username, saved_username)
    end

    events.register('websocket_message', handle_websocket_message)
    
    events.register('auth_login_success', function()
        log('UI', log_levels.INFO, "Login success event received. User is authenticated.")
        UI.login_window[0] = false
        
        copas.addthread(function()
            wait(1500)
            broadcastUnitStatus()
        end)
        
        forceDataRefresh()
        startBackgroundThreads()
    end)

    events.register('core_logout', function()
        log('UI', log_levels.INFO, "Logout event received. Closing MDT and stopping threads.")
        threads_started = false
        UI.mdt[0] = false
        UI.login_window[0] = true
    end)
    
    events.register('cad:data_refreshed', function(payload)
        log('UI', log_levels.INFO, 'cad:data_refreshed event received. Updating data_storage.')
        
        if payload.calls then
            if type(payload.calls) == "table" then
                for i, call in ipairs(payload.calls) do
                    if type(call.description) == "string" then
                        local ok, decoded = pcall(json.decode, call.description)
                        if ok then 
                            payload.calls[i].description = decoded 
                        else
                            payload.calls[i].description = {}
                        end
                    end
                    if type(call.event_log) == "string" then
                        local ok, decoded = pcall(json.decode, call.event_log)
                        if ok then 
                            payload.calls[i].event_log = decoded 
                        else
                            payload.calls[i].event_log = {}
                        end
                    end

                    local units = call.assigned_units
                    if type(units) == 'string' then
                        local ok, decoded = pcall(json.decode, units)
                        units = ok and decoded or { units }
                    elseif type(units) == 'number' then
                        units = { tostring(units) }
                    elseif type(units) ~= 'table' then
                        units = {}
                    end
                    payload.calls[i].assigned_units = units
                end
            end
            data_storage.calls = payload.calls
        end

        if payload.bolos then
            if type(payload.bolos) == "table" then
                for i, bolo in ipairs(payload.bolos) do
                    if type(bolo.event_log) == "string" then
                        local ok, decoded = pcall(json.decode, bolo.event_log)
                        if ok then payload.bolos[i].event_log = decoded 
                        else payload.bolos[i].event_log = {} end
                    elseif type(bolo.event_log) ~= 'table' then
                        payload.bolos[i].event_log = {}
                    end
                end
            end
            data_storage.bolos = payload.bolos
        end

        if payload.units then
            data_storage.units = payload.units
            if core and core.current_user then
                for _, unit in ipairs(data_storage.units) do
                    if unit.user_id == core.current_user.id then
                        core.current_unit = unit 
                        events.trigger('cad:unit_updated', unit)
                        break
                    end
                end
            end
        end

        if payload.wanted_plates then
            data_storage.wanted_plates = payload.wanted_plates
            wanted_plates_list = data_storage.wanted_plates
        end

        log('UI', log_levels.INFO, string.format('Data storage updated. Calls: %d, BOLOs: %d, Units: %d', #(data_storage.calls or {}), #(data_storage.bolos or {}), #(data_storage.units or {})))
    end)

    events.register('cad:unit_updated', function(unit_data)
        if not unit_data or isEditingUnitInfo then return end
        log('UI', log_levels.INFO, 'cad:unit_updated event received. Syncing UI buffers.')
        safe_copy(unitInfoBuffers.unitID, unit_data.unitID or "")
        unitInfoBuffers.unitType[0] = unit_data.unitType or 0
        safe_copy(unitInfoBuffers.officer1_name, unit_data.officer1_name or "")
        safe_copy(unitInfoBuffers.officer2_name, unit_data.officer2_name or "")
        unitInfoBuffers.status[0] = unit_data.status or 4
        safe_copy(unitInfoBuffers.vehiclePlate, unit_data.vehiclePlate or "")
        unitInfoBuffers.division[0] = unit_data.division or 0
        safe_copy(unitInfoBuffers.notes, unit_data.notes or "")
        assigned_vehicle_id = unit_data.vehicleId or nil
    end)

    

    divisionOptions_c = imgui.new['const char*'][#comboBoxData.division](comboBoxData.division)
    unitTypeOptions_c = imgui.new['const char*'][#comboBoxData.unitType](comboBoxData.unitType)
    shiftOptions_c = imgui.new['const char*'][#comboBoxData.shift](comboBoxData.shift)
    
    boloTypes_c = imgui.new['const char*'][#boloTypes](boloTypes)

        

    log('UI', log_levels.INFO, "Module initialized.")
end

return cadui_module