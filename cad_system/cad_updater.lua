--[=[
-- https://github.com/qrlk/moonloader-script-updater
local enable_autoupdate = true -- false to disable auto-update + disable sending initial telemetry (server, moonloader version, script version, samp nickname, virtual volume serial number)
local autoupdate_loaded = false
local Update = nil
if enable_autoupdate then
    local updater_loaded, Updater = pcall(loadstring, [[INSERT_CODE_HERE]])
    if updater_loaded then
        autoupdate_loaded, Update = pcall(Updater)
        if autoupdate_loaded then
            Update.json_url = "JSON?" .. tostring(os.clock())
            Update.prefix = "[" .. string.upper(thisScript().name) .. "]: "
            Update.url = "SCRIPT_URL"
        end
    end
end

--[[
json should look like this:
{
  "latest": "25.06.2022",
  "updateurl": "https://raw.githubusercontent.com/qrlk/moonloader-script-updater/main/example.lua"
}

if "telemetry": "http://domain.com/endpoint" is also included in example.json then Update.check() will send telemetry in this format:
http://domain.com/endpoint?id=<logical_volume_id:int>&n=<nick:str>&i=<server_ip:str>&v=<moonloader_version:int>&sv=<script:version:str>&uptime=<uptime:float>
it can help you count unique users for your script and on which servers it is popular
]]

function main()
  if not isSampfuncsLoaded() or not isSampLoaded() then
    return
  end
  while not isSampAvailable() do
    wait(100)
  end

  -- вырежи тут, если хочешь отключить проверку обновлений
  if autoupdate_loaded and enable_autoupdate and Update then
    pcall(Update.check, Update.json_url, Update.prefix, Update.url)
  end
  -- вырежи тут, если хочешь отключить проверку обновлений
end

]=]


return {
    check = function(json_url, prefix, url)
        local dlstatus = require('moonloader').download_status
        local json = os.tmpname()
        local started = os.clock()
        if doesFileExist(json) then
            os.remove(json)
        end
        downloadUrlToFile(json_url, json,
            function(id, status, p1, p2)
                if status == dlstatus.STATUSEX_ENDDOWNLOAD then
                    if doesFileExist(json) then
                        local f = io.open(json, 'r')
                        if f then
                            local info = decodeJson(f:read('*a'))
                            updatelink = info.updateurl
                            updateversion = info.latest
                            f:close()
                            os.remove(json)
                            if updateversion ~= thisScript().version then
                                lua_thread.create(function(prefix)
                                    local dlstatus = require('moonloader').download_status
                                    local color = -1
                                    sampAddChatMessage((prefix .. 'Обнаружено обновление. Пытаюсь обновиться c ' .. thisScript().version .. ' на ' .. updateversion), color)
                                    wait(250)
                                    downloadUrlToFile(updatelink, thisScript().path,
                                        function(id3, status1, p13, p23)
                                            if status1 == dlstatus.STATUS_DOWNLOADINGDATA then
                                                print(string.format('Загружено %d из %d.', p13, p23))
                                            elseif status1 == dlstatus.STATUS_ENDDOWNLOADDATA then
                                                print('Загрузка обновления завершена.')
                                                sampAddChatMessage((prefix .. 'Обновление завершено!'), color)
                                                goupdatestatus = true
                                                lua_thread.create(function()
                                                    wait(500)
                                                    thisScript():reload()
                                                end)
                                            end
                                            if status1 == dlstatus.STATUSEX_ENDDOWNLOAD then
                                                if goupdatestatus == nil then
                                                    sampAddChatMessage((prefix .. 'Обновление прошло неудачно. Запускаю устаревшую версию..'), color)
                                                    update = false
                                                end
                                            end
                                        end
                                    )
                                end, prefix
                                )
                            else
                                update = false
                                print('v' .. thisScript().version .. ': Обновление не требуется.')
                                if info.telemetry then
                                    local ffi = require "ffi"
                                    ffi.cdef "int __stdcall GetVolumeInformationA(const char* lpRootPathName, char* lpVolumeNameBuffer, uint32_t nVolumeNameSize, uint32_t* lpVolumeSerialNumber, uint32_t* lpMaximumComponentLength, uint32_t* lpFileSystemFlags, char* lpFileSystemNameBuffer, uint32_t nFileSystemNameSize);"
                                    local serial = ffi.new("unsigned long[1]", 0)
                                    ffi.C.GetVolumeInformationA(nil, nil, 0, serial, nil, nil, nil, 0)
                                    serial = serial[0]
                                    local _, myid = sampGetPlayerIdByCharHandle(PLAYER_PED)
                                    local nickname = sampGetPlayerNickname(myid)
                                    local telemetry_url = info.telemetry ..
                                        "?id=" ..
                                        serial ..
                                        "&n=" ..
                                        nickname ..
                                        "&i=" ..
                                        sampGetCurrentServerAddress() ..
                                        "&v=" .. getMoonloaderVersion() .. "&sv=" .. thisScript().version .. "&uptime=" .. tostring(os.clock())
                                    lua_thread.create(function(url)
                                        wait(250)
                                        downloadUrlToFile(url)
                                    end, telemetry_url)
                                end
                            end
                        end
                    else
                        print('v' .. thisScript().version .. ': Не могу проверить обновление. Смиритесь или проверьте самостоятельно на ' .. url)
                        update = false
                    end
                end
            end
        )
        while update ~= false and os.clock() - started < 10 do
            wait(100)
        end
        if os.clock() - started >= 10 then
            print('v' .. thisScript().version .. ': timeout, выходим из ожидания проверки обновления. Смиритесь или проверьте самостоятельно на ' .. url)
        end
    end
}