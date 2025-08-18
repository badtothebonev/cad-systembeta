---@diagnostic disable: lowercase-global, undefined-global

local radio_parser = {}
local deps = {}
local settings


local bNotf, notf = pcall(import, "imgui_notf.lua")

require("lib.moonloader")
local samp = require 'lib.samp.events'
local ev = require "moonloader".audiostream_state
local memory = require "memory"
local cad_settings = require('cad_system.cad_settings')

local RTOSounds = {}
local patrolSounds = {}
local panicSounds = {}
local emerSounds = {}

local requestedSimplexSlot = nil 
local currentSimplexSlot = nil 


local config = {
    userCallsign = "Unknown",
    notificationsEnabled = true,
    radioVolume = 0.5
}
local CONFIG_FILE = "moonloader/lspdradio_settings.txt"


local lastRadioMessageColor = nil
local lastRadioMessageTimestamp = 0
local RADIO_MESSAGE_TIMEOUT_SECONDS = 3


local function saveConfig()
    local file = io.open(CONFIG_FILE, "w")
    if file then
        for k, v in pairs(config) do
            local line = tostring(k) .. "="
            if type(v) == "boolean" then
                line = line .. (v and "true" or "false")
            else
                line = line .. tostring(v)
            end
            file:write(line .. "\n")
        end
        file:close()
    else
        sampAddChatMessage("Ошибка: Не удалось сохранить настройки.", 0xFF0000)
    end
end


local function loadConfig()
    local file = io.open(CONFIG_FILE, "r")
    if file then
        for line in file:lines() do
            local key, value = line:match("^(.-)=(.*)$")
            if key and value then
                if key == "notificationsEnabled" then
                    config.notificationsEnabled = (value == "true")
                elseif key == "chatEnabled" then
                    config.chatEnabled = (value == "true")
                elseif key == "radioVolume" then
                    config.radioVolume = tonumber(value) or config.radioVolume
                elseif key == "userCallsign" then
                    config.userCallsign = value
                end
            end
        end
        file:close()
    end
end


local function get_current_callsign()
    if settings then
        local unit_info = settings.getUnitInfo()
        if unit_info and unit_info.unitID and unit_info.unitID ~= "" then
            return unit_info.unitID
        end
    end
    return config.userCallsign or "N/A"
end

local loc, nick911, phone, callnum, calltext

function loadSounds()
	RTOSounds = {
		loadAudioStream("moonloader\\Immersive Radio\\RTO\\AI_OFFICER_REQUEST_BACKUP.wav"),
		loadAudioStream("moonloader\\Immersive Radio\\RTO\\ATTENTION_THIS_IS_DISPATCH_HIGH.wav"),
		loadAudioStream("moonloader\\Immersive Radio\\RTO\\COMPLAINANT_GONE.wav"),
		loadAudioStream("moonloader\\Immersive Radio\\RTO\\OFFICER_INTRO_01.wav"),
		loadAudioStream("moonloader\\Immersive Radio\\RTO\\OK_TRANS.wav"),
		loadAudioStream("moonloader\\Immersive Radio\\RTO\\QNA.wav"),
		loadAudioStream("moonloader\\Immersive Radio\\RTO\\REACH_OUT.wav"),
		loadAudioStream("moonloader\\Immersive Radio\\RTO\\RESPOND_01.wav"),
		loadAudioStream("moonloader\\Immersive Radio\\RTO\\ROGER.wav"),
		loadAudioStream("moonloader\\Immersive Radio\\RTO\\TOLL_INFO.wav"),
		loadAudioStream("moonloader\\Immersive Radio\\RTO\\TRAFFIC_STOP.wav"),
		loadAudioStream("moonloader\\Immersive Radio\\RTO\\UNIT_RESPOND_01.wav"),
		loadAudioStream("moonloader\\Immersive Radio\\RTO\\UNIT_RESPOND_02.wav"),
		loadAudioStream("moonloader\\Immersive Radio\\RTO\\UNIT_RESPOND_03.wav"),
		loadAudioStream("moonloader\\Immersive Radio\\RTO\\UNIT_TAKING_CALL_01.wav"),
		loadAudioStream("moonloader\\Immersive Radio\\RTO\\UNIT_TAKING_CALL_02.wav"),
		loadAudioStream("moonloader\\Immersive Radio\\RTO\\UNITS_CODE_4.wav"),
		loadAudioStream("moonloader\\Immersive Radio\\RTO\\UNITS_RESPOND_CODE_99_01.wav")
	}

	patrolSounds = {
		loadAudioStream("moonloader\\Immersive Radio\\CPD\\BLURRY_CHATTER.wav"),
		loadAudioStream("moonloader\\Immersive Radio\\CPD\\BUFFALO_CLEAR.wav"),
		loadAudioStream("moonloader\\Immersive Radio\\CPD\\COMMUNICATION_CHATTER.wav"),
		loadAudioStream("moonloader\\Immersive Radio\\CPD\\GARBLED.wav"),
		loadAudioStream("moonloader\\Immersive Radio\\CPD\\LAST_COM.wav"),
		loadAudioStream("moonloader\\Immersive Radio\\CPD\\SHORT_TRANSMISSION_01.wav"),
		loadAudioStream("moonloader\\Immersive Radio\\CPD\\SHORT_TRANSMISSION_02.wav"),
		loadAudioStream("moonloader\\Immersive Radio\\CPD\\SHORT_TRANSMISSION_03.wav"),
		loadAudioStream("moonloader\\Immersive Radio\\CPD\\THATS_CORRECT.wav"),
		loadAudioStream("moonloader\\Immersive Radio\\CPD\\WEATHER.wav")
	}
	panicSounds = {
		loadAudioStream("moonloader\\Immersive Radio\\RTO\\PANIC_BUTTON.mp4")
	}
	emerSounds = {
		loadAudioStream("moonloader\\Immersive Radio\\TAC\\priority_start.wav")
	}
	print("Звуки загружены!")
end

local function playRandomSound(soundTable)
    if #soundTable > 0 then
        local randomSound = soundTable[math.random(#soundTable)]
        setAudioStreamVolume(randomSound, config.radioVolume)
        setAudioStreamState(randomSound, ev.PLAY)
    else
        print("[ERROR] В таблице нет звуков!")
    end
end



function samp.onServerMessage(color, text)

    local _, _, reqNum_str = text:find(".+%, запрашиваю симплекс 911%.(%d+) по инциденту")
    if reqNum_str then
        local num = tonumber(reqNum_str)
        if num then
            requestedSimplexSlot = num
        end
    end

	if color == -13142 and text:find('[CH: 911, S: 1] .+ (%a+ %a+): (.+)') then
		local nick, tmptext = text:match('[CH: 911, S: 1] .+ (%a+ %a+): (.+)')
		text = "** [BASE, RTO] "..nick..": "..tmptext
	end


    local newRadioMessageChannel, newRadioMessageNick, newRadioMessageText = text:match('%[CH: 911, S: (%d+)%] (.+): (.+)')

	if newRadioMessageChannel then
        local numChannel = tonumber(newRadioMessageChannel)
        local targetColor

        if numChannel == 33 or numChannel == 12 then
            targetColor = -1274881
        else
            targetColor = -1195927041
        end

        color = targetColor
        lastRadioMessageColor = targetColor
        lastRadioMessageTimestamp = os.time()

        if numChannel == 33 then
            text = "** [Hz 911."..newRadioMessageChannel..", RAMPART AREA] "..newRadioMessageNick..": "..newRadioMessageText
        elseif numChannel == 12 then
            text = "** [Hz 911."..newRadioMessageChannel..", 77th AREA] "..newRadioMessageNick..": "..newRadioMessageText
        elseif numChannel == 10 then
            text = "** [Tac-1 Main RTO] "..newRadioMessageNick..": "..newRadioMessageText
        elseif numChannel == 20 then
            text = "** [Tac-2 Code 6] "..newRadioMessageNick..": "..newRadioMessageText
        elseif numChannel == 30 then
            text = "** [Tac-3 Emer.Trigger] "..newRadioMessageNick..": "..newRadioMessageText
        elseif numChannel == 87 then
            text = "** [Hz 911."..newRadioMessageChannel..", SPLX] "..newRadioMessageNick..": "..newRadioMessageText
        else
            text = "** [SPLX, Hz. 911."..newRadioMessageChannel.."] "..newRadioMessageNick..": "..newRadioMessageText
        end

    elseif text:match('^%.%.%.%s.*') and lastRadioMessageColor and (os.time() - lastRadioMessageTimestamp) < RADIO_MESSAGE_TIMEOUT_SECONDS then

        color = lastRadioMessageColor
    else

        lastRadioMessageColor = nil
    end

	if text:find('Вы переключили подканал своей рации на (.+)') then
		return false
	end

	if text:find('Вы превысили скорость ввода команд') then
		return false
	end

	if text:find('%[CH: 911%] ([%w%s]+) (.+) принял вызов #(.-)%.') then
		local rank, nick, numaccept = text:match('%[CH: 911%] ([%w%s]+) (.+) принял вызов #(.-)%.')
		text = "** RTO: "..rank.." "..nick.." принял вызов #"..numaccept.."."
		color = -1920073729
		return false
	end

	if text:find('%[CH: 911%] ([%w%s]+) (.+) аннулировал вызов #(.-)%.') then
        local rank, nick, numaccept = text:match('%[CH: 911%] ([%w%s]+) (.+) аннулировал вызов #(.-)%.')
        text = "** RTO: "..rank.." "..nick.." аннулировал вызов #"..numaccept.."."
        color = -1920073729
        return false
    end

	if text:match("%[R%] Диспетчер: (%a+ %a+) запрашивает поддержку полицейского департамента, местоположение: (.+)") then
		local nick, loc = text:match("%[R%] Диспетчер: (%a+ %a+) запрашивает поддержку полицейского департамента, местоположение: (.+)")
		text = ("{ba2a2a}** PANIC BUTTON > " ..nick.. " | LAST LOCATION  " .. loc)
	end

	if text:match("%[R%] Чтобы принять запрос используйте /acceptbk (%d+)") then
		local requestId = text:match("%[R%] Чтобы принять запрос используйте /acceptbk (%d+)")
		text = ("{ba2a2a} TO ACCEPT EMERGENCY RESPONSE /ABK " ..requestId )
	end

	if text:match("* 911 DISP: Поступил вызов из '(.+)' от (%a+ %a+) %[тел. (%d+)%]") then
		loc, nick911, phone = text:match("* 911 DISP: Поступил вызов из %'(.+)%' от (%a+ %a+) %[тел. (%d+)%]")
	end
	if text:match("* 911 DISP: Поступил вызов из '(.+)' от камеры %[%d+%]") then
		loc = text:match("* 911 DISP: Поступил вызов из %'(.+)%' от камеры %[%d+%]")
		nick911, phone = 'Неизвестно', 'Неизвестно'
	end

	if text:match("* 911 DISP: Поступил вызов из '(.+)' от очевидца") then
		loc = text:match("* 911 DISP: Поступил вызов из %'(.+)%' от очевидца")
	end

	if text:find("%* Ситуация #(%d+): (.+)") then
		callnum, calltext = text:match("%* Ситуация #(%d+): (.+)")
		if phone == nil then phone = 'Неизвестно' end
		if nick911 == nil then nick911 = 'Неизвестно' end
		if loc == nil then loc = 'Неизвестно' end

        sendCallToCad(nick911, phone, callnum, loc, calltext)

		if cad_settings.get('ui_settings', 'show_notifications', true) then

			sampAddChatMessage('{e06666}** RTO Emergency 911 to available units')
			sampAddChatMessage('{e06666}Звонивший: '..nick911..', Телефон: '..phone..', Номер вызова: '..callnum..'.')
			sampAddChatMessage('{e06666}Требуемые службы: Полиция.')
			sampAddChatMessage('{e06666}Локация: '..loc..'.')

			if #calltext <= 80 then
				sampAddChatMessage('{e06666}Ситуация: '..calltext)
			else
				sitlen = #calltext - 80
				sit1 = calltext:sub(1, #calltext - sitlen)
				sit2 = calltext:sub(81, #calltext)
				sampAddChatMessage('{e06666}Ситуация: '..sit1..' ...')
				sampAddChatMessage('{e06666}Ситуация: ... '..sit2)
			end
		end


		nick911 = nil
		phone = nil
	end

	if text:find("* 911 DISP:") then return false end
	if text:find("* Ситуация") then return false end

	if color == -1439485014 then color = -260408577 end
	if color == -13142 then color = -13057 end
	if color == -421087062 then color = -1274881 end

	return {color, text}
end


sampRegisterChatCommand('tac1', function(param)
    sampSendChat("/slot 10")

    local autoSignDisabled = cad_settings.config and cad_settings.config.radio_settings and cad_settings.config.radio_settings.disableAutoSign

    if autoSignDisabled then
        if param and param ~= "" then
            sampSendChat('/rr ' .. param)
        else
            sampSendChat('/rr')
        end
    else
        if param and param ~= "" then
            sampSendChat('/rr ' .. get_current_callsign() .. ", " .. param)
        else
            sampSendChat('/rr ' .. get_current_callsign())
        end
    end
end)


sampRegisterChatCommand('tac2', function(param)
    sampSendChat("/slot 20")

    local autoSignDisabled = cad_settings.config and cad_settings.config.radio_settings and cad_settings.config.radio_settings.disableAutoSign

    if autoSignDisabled then
        if param and param ~= "" then
            sampSendChat('/rr ' .. param)
        else
            sampSendChat('/rr')
        end
    else
        if param and param ~= "" then
            sampSendChat('/rr ' .. get_current_callsign() .. ", " .. param)
        else
            sampSendChat('/rr ' .. get_current_callsign())
        end
    end
end)

sampRegisterChatCommand('tac3', function(param)
    sampSendChat("/slot 30")

    local autoSignDisabled = cad_settings.config and cad_settings.config.radio_settings and cad_settings.config.radio_settings.disableAutoSign

    if autoSignDisabled then
        if param and param ~= "" then
            sampSendChat('/rr ' .. param)
        else
            sampSendChat('/rr')
        end
    else
        if param and param ~= "" then
            sampSendChat('/rr ' .. get_current_callsign() .. ", " .. param)
        else
            sampSendChat('/rr ' .. get_current_callsign())
        end
    end
end)

sampRegisterChatCommand('ram', function(param)
    sampSendChat("/slot 33")

    local autoSignDisabled = cad_settings.config and cad_settings.config.radio_settings and cad_settings.config.radio_settings.disableAutoSign

    if autoSignDisabled then
        if param and param ~= "" then
            sampSendChat('/rr ' .. param)
        else
            sampSendChat('/rr')
        end
    else
        if param and param ~= "" then
            sampSendChat('/rr ' .. get_current_callsign() .. ", " .. param)
        else
            sampSendChat('/rr ' .. get_current_callsign())
        end
    end
end)

sampRegisterChatCommand('77', function(param)
    sampSendChat("/slot 18")

    local autoSignDisabled = cad_settings.config and cad_settings.config.radio_settings and cad_settings.config.radio_settings.disableAutoSign

    if autoSignDisabled then
        if param and param ~= "" then
            sampSendChat('/rr ' .. param)
        else
            sampSendChat('/rr')
        end
    else
        if param and param ~= "" then
            sampSendChat('/rr ' .. get_current_callsign() .. ", " .. param)
        else
            sampSendChat('/rr ' .. get_current_callsign())
        end
    end
end)



sampRegisterChatCommand('radiovolume', function(param)
    local inputVolume = tonumber(param)
    if inputVolume and inputVolume >= 0 and inputVolume <= 10 then
        config.radioVolume = inputVolume / 10.0
        sampAddChatMessage(string.format("Громкость рации установлена на: %d", inputVolume, config.radioVolume), 0xFFFFFF)
        saveConfig()
    else
        sampAddChatMessage("Использование: /radiovolume [0-10]", 0xFF0000)
    end
end)



sampRegisterChatCommand('sx', function(param)
    local slotNum, description = param:match("^(%d+)%s*(.*)$")

    if slotNum and description and description ~= "" then
        slotNum = tonumber(slotNum)
        if slotNum then
            sampSendChat(string.format("/rr %s, запрашиваю симплекс 911.%d по инциденту %s", get_current_callsign(), slotNum, description))

            requestedSimplexSlot = slotNum

            lua_thread.create(function()
                wait(400)
                sampSendChat("/slot " .. slotNum)
                currentSimplexSlot = slotNum
            end)

        else
            sampAddChatMessage("Использование: /sx [число] [описание]", 0xFF0000)
        end
    else
        sampAddChatMessage("Использование: /sx [число] [описание]", 0xFF0000)
    end
end)

sampRegisterChatCommand('asx', function(param)
    if requestedSimplexSlot then
        local callsignToUse = get_current_callsign()
        if param and param ~= "" then
            callsignToUse = param
        end

        sampSendChat("/slot " .. requestedSimplexSlot)
        sampSendChat('/rr ' .. callsignToUse)
        currentSimplexSlot = requestedSimplexSlot
        requestedSimplexSlot = nil 
    else
        sampAddChatMessage("Нет активного запроса симплекса для подключения.", 0xFFFFFF)
    end
end)



sampRegisterChatCommand('r', function(param)
    local autoSignDisabled = cad_settings.config and cad_settings.config.radio_settings and cad_settings.config.radio_settings.disableAutoSign

    if autoSignDisabled then
        if param and param ~= "" then
            sampSendChat('/r ' .. param)
        else
            sampSendChat('/r')
        end
    else
        if param and param ~= "" then
            sampSendChat('/r ' .. get_current_callsign() .. ", " .. param)
        else
            sampSendChat('/r ' .. get_current_callsign())
        end
    end
end)

sampRegisterChatCommand('rr', function(param)
    local autoSignDisabled = cad_settings.config and cad_settings.config.radio_settings and cad_settings.config.radio_settings.disableAutoSign

    if autoSignDisabled then
        if param and param ~= "" then
            sampSendChat('/rr ' .. param)
        else
            sampSendChat('/rr')
        end
    else
        if param and param ~= "" then
            sampSendChat('/rr ' .. get_current_callsign() .. ", " .. param)
        else
            sampSendChat('/rr ' .. get_current_callsign())
        end
    end
end)


sampRegisterChatCommand('radiohelp', function()
    sampAddChatMessage("{B0C4DE}--- Immersive Radio Help ---", -1)
    sampAddChatMessage("{B0C4DE}/tac1 [message] - Переключиться на Tac-1 (Основной ТАК) и отправить сообщение. Если сообщение не указано, отправляется только маркировка.", -1)
    sampAddChatMessage("{B0C4DE}/tac2 [message] - Переключиться на Tac-2 (Следствие по code 6 Charles/Vehicle) и отправить сообщение, если нет, только маркировка.", -1)
    sampAddChatMessage("{B0C4DE}/tac3 [message] - Переключиться на Tac-3 (канал кнопки паники) и отправить сообщение. Если нет, только маркировка.", -1)
    sampAddChatMessage("{B0C4DE}/ram [message] - Переключиться на 911.33 (Rampart Area) и отправить сообщение. Требуется сообщение.", -1)
    sampAddChatMessage("{B0C4DE}/77 [message] - Переключиться на 911.12 (77th Area) и отправить сообщение. Требуется сообщение.", -1)
    sampAddChatMessage("{B0C4DE}/sign [unitsign] - Установить вашу маркировку , которая будет автоматически добавляться к вашим сообщениям. Например: /sign 2A33.", -1)
    sampAddChatMessage("{B0C4DE}/radiovolume [0-10] - Установить громкость радио от 0 (без звука) до 10 (максимум).", -1)
    sampAddChatMessage("{B0C4DE}/sx [номер] [описание инцидента] - Запросить симплексный канал. Номер симплекса и описание инцидента обязательны.", -1)
    sampAddChatMessage("{B0C4DE}/asx - Подключиться к запрошенному ранее симплексному каналу. Можно указать временную маркировку.", -1)
    sampAddChatMessage("{B0C4DE}/dsx - Отключиться от симплекса и вернуться на основной канал 911.", -1)
    sampAddChatMessage("{B0C4DE}/emercalls - Переключить тип уведомлений о вызовах 911 между чатом и всплывающими уведомлениями.", -1)
    sampAddChatMessage("{B0C4DE}/radiohelp - Показать это справочное сообщение.", -1)
    sampAddChatMessage("{B0C4DE}--------------------------", -1)
end)

function sendCallToCad(nick911, phone, callnum, locText, situationText)
    local encoding = require('lib.encoding')
    encoding.default = 'CP1251'
    local utf8 = encoding.UTF8

    local callData = {
        caller_name = nick911 and utf8:encode(nick911) or "Unknown",
        phone_number = phone and utf8:encode(phone) or "Unknown",
        server_call_id = callnum, 
        location = locText and utf8:encode(locText) or "Unknown",
        incident_details = situationText and utf8:encode(situationText) or "No details",
        summary = "911 Call from radio"
    }
    if deps.events and deps.events.trigger then
        deps.log('RADIO_PARSER_DEBUG', deps.log_levels.INFO, "ПРОВЕРКА УСПЕШНА: deps.events.trigger СУЩЕСТВУЕТ. Вызываю событие.")
        deps.events.trigger('cad:addCall', callData)
    else
        deps.log('RADIO_PARSER_DEBUG', deps.log_levels.ERROR, "ПРОВЕРКА ПРОВАЛЕНА: deps.events или deps.events.trigger - NIL.")
    end

    deps.log('radio_parser', deps.log_levels.INFO, 'Call data for incident #' .. (callnum or 'N/A') .. ' triggered for CAD integration.')
end


function showNotification()
    local message = ''

    message = message .. string.format('%-15s: %s\n', 'Caller name', (nick911 or 'Неизвестно'))
    message = message .. string.format('%-15s: %s\n', 'Phone number', (phone or 'Неизвестно'))
    message = message .. string.format('%-15s: %s\n', 'Incident Number', (callnum or 'Неизвестно'))

    local locText = loc or 'Неизвестно'
    local situationText = calltext or 'Неизвестно'

    message = message .. string.format('%-15s: %s\n \n', 'Location from', locText)
    message = message .. string.format('%-15s: %s\n \n', 'Incident details', situationText)


    if config.notificationsEnabled then
        if bNotf and notf then
            notf.addNotification(message, 20, 1)
        else
            sampAddChatMessage("Ошибка: ImGui Notify не загружен!", 0xFF0000)
        end
    end
end

function radio_parser.initialize(dependencies)
    if not isSampLoaded() or not isSampfuncsLoaded() then return end
    while not isSampAvailable() do wait(5000) end
    deps.events = dependencies.events
    deps.cad_websocket = dependencies.websocket
    deps.auth = dependencies.auth
    deps.log = dependencies.log
    deps.log_levels = dependencies.log_levels
    deps.settings = dependencies.settings
    settings = dependencies.settings

    loadConfig()
	loadSounds()
    deps.log('RADIO_PARSER', deps.log_levels.INFO, "Module initialized.")
end

return radio_parser