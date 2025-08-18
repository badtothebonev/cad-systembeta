
local ffi = require('ffi')


local LOG_FILE_PATH = "moonloader/cad_debug.log"
local log_levels = { DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4 }
local current_log_level = log_levels.DEBUG

local file = io.open(LOG_FILE_PATH, "w")
if file then
    file:write(string.format("---\n--- CAD System Log Initialized at %s ---\n", os.date("%Y-%m-%d %H:%M:%S")))
    file:close()
end

local function log(module, level, message)
    if type(message) ~= "string" then
        message = tostring(message)
    end

    if level == nil then level = log_levels.INFO end

    local level_name = "UNKNOWN"
    for name, num in pairs(log_levels) do
        if num == level then
            level_name = name
            break
        end
    end

    if level < current_log_level then
        return 
    end

    local timestamp = os.date("[%H:%M:%S]")
    local log_message = string.format("%s [%-10s] [%-5s] %s\n", timestamp, string.upper(module), level_name, message:gsub("[\r\n]*$", ""))
    
    local file = io.open(LOG_FILE_PATH, "a")
    if file then
        file:write(log_message)
        file:close()
    end

    if level == log_levels.ERROR then
        print(log_message)
    end
end


local function requireLib(name, url, is_critical)
    local ok, lib = pcall(require, name)
    if not ok then
        local err_msg = string.format("Missing library or module: '%s'", name)
        log('COMMON', log_levels.ERROR, err_msg)
        if url then log('COMMON', log_levels.INFO, "Download it from: " .. url) end
        if is_critical then
            error(err_msg)
        end
        return nil
    end
    log('COMMON', log_levels.DEBUG, "Library loaded: " .. name)
    return lib
end

local json = requireLib('dkjson', 'Place dkjson.lua in moonloader/lib', true)

local function safe_str(ffi_char_array)
    if ffi_char_array == nil then return "" end
    local ok, str = pcall(ffi.string, ffi_char_array)
    return ok and str or ""
end

local function safe_copy(dest, src)
    if dest == nil or src == nil then return end
    pcall(ffi.copy, dest, src)
end

local cars = {
    [400] = 'Landstalker', [401] = 'Bravura', [402] = 'Buffalo', [403] = 'Linerunner', [404] = 'Perenniel', [405] = 'Sentinel', [406] = 'Dumper', [407] = 'Firetruck',
    [408] = 'Trashmaster', [409] = 'Stretch', [410] = 'Manana', [411] = 'Infernus', [412] = 'Voodoo', [413] = 'Pony', [414] = 'Mule', [415] = 'Cheetah', [416] = 'Ambulance',
    [417] = 'Leviathan', [418] = 'Moonbeam', [419] = 'Esperanto', [420] = 'Taxi', [421] = 'Washington', [422] = 'Bobcat', [423] = 'Mr Whoopee', [424] = 'BF Injection',
    [425] = 'Hunter', [426] = 'Premier', [427] = 'Enforcer', [428] = 'Securicar', [429] = 'Banshee', [430] = 'Predator', [431] = 'Bus', [432] = 'Rhino', [433] = 'Barracks',
    [434] = 'Hotknife', [435] = 'Article Trailer', [436] = 'Previon', [437] = 'Coach', [438] = 'Cabbie', [439] = 'Stallion', [440] = 'Rumpo', [441] = 'RC Bandit',
    [442] = 'Romero', [443] = 'Packer', [444] = 'Monster', [445] = 'Admiral', [446] = 'Squallo', [447] = 'Seasparrow', [448] = 'Pizzaboy', [449] = 'Tram', [450] = 'Article Trailer 2',
    [451] = 'Turismo', [452] = 'Speeder', [453] = 'Reefer', [454] = 'Tropic', [455] = 'Flatbed', [456] = 'Yankee', [457] = 'Caddy', [458] = 'Solair', [459] = 'Berkley\'s RC',
    [460] = 'Skimmer', [461] = 'PCJ-600', [462] = 'Faggio', [463] = 'Freeway', [464] = 'RC Baron', [465] = 'RC Raider', [466] = 'Glendale', [467] = 'Oceanic', [468] = 'Sanchez',
    [469] = 'Sparrow', [470] = 'Patriot', [471] = 'Quad', [472] = 'Coastguard', [473] = 'Dinghy', [474] = 'Hermes', [475] = 'Sabre', [476] = 'Rustler', [477] = 'ZR-350',
    [478] = 'Walton', [479] = 'Regina', [480] = 'Comet', [481] = 'BMX', [482] = 'Burrito', [483] = 'Camper', [484] = 'Marquis', [485] = 'Baggage', [486] = 'Dozer', [487] = 'Maverick',
    [488] = 'SAN News Maverick', [489] = 'Rancher', [490] = 'FBI Rancher', [491] = 'Virgo', [492] = 'Greenwood', [493] = 'Jetmax', [494] = 'Hotring Racer', [495] = 'Sandking',
    [496] = 'Blista Compact', [497] = 'Police Maverick', [498] = 'Boxville', [499] = 'Benson', [500] = 'Mesa', [501] = 'RC Goblin', [502] = 'Hotring Racer A', [503] = 'Hotring Racer B',
    [504] = 'Bloodring Banger', [505] = 'Rancher', [506] = 'Super GT', [507] = 'Elegant', [508] = 'Journey', [509] = 'Bike', [510] = 'Mountain Bike', [511] = 'Beagle',
    [512] = 'Cropduster', [513] = 'Stuntplane', [514] = 'Tanker', [515] = 'Roadtrain', [516] = 'Nebula', [517] = 'Majestic', [518] = 'Buccaneer', [519] = 'Shamal', [520] = 'Hydra',
    [521] = 'FCR-900', [522] = 'NRG-500', [523] = 'HPV1000', [524] = 'Cement Truck', [525] = 'Towtruck', [526] = 'Fortune', [527] = 'Cadrona', [528] = 'FBI Truck', [529] = 'Willard',
    [530] = 'Forklift', [531] = 'Tractor', [532] = 'Combine Harvester', [533] = 'Feltzer', [534] = 'Remington', [535] = 'Slamvan', [536] = 'Blade', [537] = 'Freight (Train)',
    [538] = 'Brownstreak (Train)', [539] = 'Vortex', [540] = 'Vincent', [541] = 'Bullet', [542] = 'Clover', [543] = 'Sadler', [544] = 'Firetruck LA', [545] = 'Hustler',
    [546] = 'Intruder', [547] = 'Primo', [548] = 'Cargobob', [549] = 'Tampa', [550] = 'Sunrise', [551] = 'Merit', [552] = 'Utility Van', [553] = 'Nevada', [554] = 'Yosemite',
    [555] = 'Windsor', [556] = 'Monster A', [557] = 'Monster B', [558] = 'Uranus', [559] = 'Jester', [560] = 'Sultan', [561] = 'Stratum', [562] = 'Elegy', [563] = 'Raindance',
    [564] = 'RC Tiger', [565] = 'Flash', [566] = 'Tahoma', [567] = 'Savanna', [568] = 'Bandito', [569] = 'Freight Flat Trailer', [570] = 'Streak Trailer', [571] = 'Kart',
    [572] = 'Mower', [573] = 'Dune', [574] = 'Sweeper', [575] = 'Broadway', [576] = 'Tornado', [577] = 'AT400', [578] = 'DFT-30', [579] = 'Huntley', [580] = 'Stafford',
    [581] = 'BF-400', [582] = 'Newsvan', [583] = 'Tug', [584] = 'Petrol Trailer', [585] = 'Emperor', [586] = 'Wayfarer', [587] = 'Euros', [588] = 'Hotdog', [589] = 'Club',
    [590] = 'Freight Box Trailer', [591] = 'Article Trailer 3', [592] = 'Andromada', [593] = 'Dodo', [594] = 'RC Cam', [595] = 'Launch', [596] = 'Police Car (LSPD)',
    [597] = 'Police Car (SFPD)', [598] = 'Police Car (LVPD)', [599] = 'Police Ranger', [600] = 'Picador', [601] = 'S.W.A.T.', [602] = 'Alpha', [603] = 'Phoenix',
    [604] = 'Glendale Shit', [605] = 'Sadler Shit', [606] = 'Baggage Trailer A', [607] = 'Baggage Trailer B', [608] = 'Tug Stairs Trailer', [609] = 'Boxville',
    [610] = 'Farm Trailer', [611] = 'Utility Trailer'
}

log('COMMON', log_levels.INFO, "Common module initialized.")

return {
    log = log,
    log_levels = log_levels,
    requireLib = requireLib,
    json = json,
    safe_str = safe_str,
    safe_copy = safe_copy,
    cars = cars
}
