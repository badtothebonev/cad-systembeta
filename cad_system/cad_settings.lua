local encoding = require('encoding')
encoding.default = 'CP1251'
local u8 = encoding.UTF8

local json = require('dkjson')
local settings = {}

local CONFIG_PATH = getWorkingDirectory() .. "\\cad_config.json"

local DEFAULT_CONFIG = {
    version = "2.0",
    user_settings = {
        username = "",
        token = "",
        remember_login = false,
        auto_login = false
    },
    ui_settings = {
        show_notifications = true,
        remember_last_tab = false,
        hide_placeholder_calls = false
    },
    audio_settings = {
        enabled = true,
        volume = 0.5,
        notification_sounds = true
    },
    radio_settings = {
        disableAutoSign = false
    },
    unit_info = {
        unitID = "2L20",
        unitType = 0,
        officer1_name = "John Doe",
        officer1_id = "12345",
        officer2_name = "",
        officer2_id = "",
        status = 0,
        vehiclePlate = "12ABC345",
        division = 0,
        shift = 0,
        notes = "Taser, Bodycam"
    },
    api_settings = {
        url = "ws://35.228.114.115:8443"
    },
    controls_settings = {
        open_mdt_key = "VK_F2",
        open_alpr_key = "VK_1",
        open_map_key = "VK_M",
        accept_call_key = "VK_Y"
    }
}

-- Состояние загрузки, чтобы предотвратить перезапись
local is_config_loaded_successfully = false

-- Функция для глубокого копирования таблиц
local function deepcopy(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in next, orig, nil do
            copy[deepcopy(orig_key)] = deepcopy(orig_value)
        end
        setmetatable(copy, deepcopy(getmetatable(orig)))
    else -- number, string, boolean, etc
        copy = orig
    end
    return copy
end

-- Функция для рекурсивного слияния таблиц
local function deep_merge(target, source)
    for k, v in pairs(source) do
        if type(v) == 'table' and type(target[k] or false) == 'table' then
            deep_merge(target[k], v)
        else
            target[k] = v
        end
    end
    return target
end

settings.config = {}

function settings.load()
    print(u8("[CAD Settings] Loading config..."))
    
    -- Начинаем с полной копии стандартного конфига
    settings.config = deepcopy(DEFAULT_CONFIG)
    
    if doesFileExist(CONFIG_PATH) then
        local file = io.open(CONFIG_PATH, "r")
        if file then
            local content = file:read("*all")
            file:close()
            
            if content == "" then
                print(u8("[CAD Settings] Config file is empty. Using defaults and will save on next update."))
                is_config_loaded_successfully = true -- Считаем успешной загрузкой, чтобы разрешить сохранение
                return
            end

            local loaded_config, pos, err = json.decode(content)
            
            if loaded_config then
                settings.config = deep_merge(settings.config, loaded_config)
                is_config_loaded_successfully = true
                print(u8("[CAD Settings] Config loaded and merged successfully."))
            else
                -- Ключевое изменение: НЕ МЕНЯЕМ конфиг на дефолтный, если файл есть, но он кривой
                is_config_loaded_successfully = false -- Запрещаем сохранение
                print(u8("[CAD Settings] CRITICAL: Could not parse config file. Using default settings for this session only."))
                print(u8("[CAD Settings] ERROR: ") .. (err or u8("unknown error")))
                print(u8("[CAD Settings] IMPORTANT: Your config file will NOT be overwritten."))
            end
        else
            is_config_loaded_successfully = false -- Запрещаем сохранение
            print(u8("[CAD Settings] CRITICAL: Could not open config file for reading. Using default settings for this session only."))
        end
    else
        -- Файла нет, это первый запуск. Создаем пустой, но валидный конфиг.
        is_config_loaded_successfully = true -- Разрешаем сохранение в будущем
        print(u8("[CAD Settings] Config file not found. Creating a new, empty config file..."))
        local file = io.open(CONFIG_PATH, "w")
        if file then
            file:write("{}")
            file:close()
            print(u8("[CAD Settings] Empty config file created. Defaults will be used for this session."))
        else
            -- Если мы даже не можем создать файл, блокируем дальнейшие сохранения
            is_config_loaded_successfully = false
            print(u8("[CAD Settings] CRITICAL: Could not create new config file. Check permissions."))
        end
    end
end

function settings.save()
    if not is_config_loaded_successfully then
        print(u8("[CAD Settings] SAVE BLOCKED: Preventing overwrite of a potentially valid config due to a loading error."))
        return false
    end

    
    local file = io.open(CONFIG_PATH, "w")
    if file then
        local json_string = json.encode(settings.config, { indent = true })
        file:write(json_string)
        file:close()
        return true
    else
        print(u8("[CAD Settings] ERROR: Could not open config file for writing."))
        return false
    end
end

function settings.get(section, key, default_value)
    if settings.config[section] and settings.config[section][key] ~= nil then
        return settings.config[section][key]
    end
    
    -- Возвращаем значение из дефолтного конфига, если оно есть
    if DEFAULT_CONFIG[section] and DEFAULT_CONFIG[section][key] ~= nil then
        return DEFAULT_CONFIG[section][key]
    end

    return default_value
end

function settings.set(section, key, value)
    if not settings.config[section] then
        settings.config[section] = {}
    end
    settings.config[section][key] = value
end

function settings.getApiSettings()
    return settings.config.api_settings
end

function settings.getUiSettings()
    return settings.config.ui_settings
end

function settings.getAudioSettings()
    return settings.config.audio_settings
end

function settings.getRadioSettings()
    return settings.config.radio_settings
end

function settings.getUnitInfo()
    return settings.config.unit_info
end

function settings.saveUnitInfo(unit_info)
    settings.config.unit_info = unit_info
end

-- ВЫПОЛНЯЕМ ЗАГРУЗКУ СРАЗУ ПРИ ПОДКЛЮЧЕНИИ МОДУЛЯ
print(u8("[CAD Settings] Initializing and loading config immediately..."))
settings.load()

return settings