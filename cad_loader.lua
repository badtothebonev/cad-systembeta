--[[ 
    CAD System Bootstrapper
    Автообновление и запуск CAD System.
    Алгоритм:
    1. Настраивает package.path (lib, cad_system, корень).
    2. Скачивает manifest.json с GitHub.
    3. Если манифест корректный → проверяет версию, обновляет файлы.
    4. Если манифест не скачан → запускает локальный cad_main.lua.
    5. Всегда запускает cad_main.lua только через require.
]]

-- ==== Пути поиска Lua модулей ====
local separator = package.config:sub(1,1)
local work_dir = getWorkingDirectory()

-- lib
package.path = package.path .. ';' .. work_dir .. separator .. 'lib' .. separator .. '?.lua'
-- корень moonloader (cad_main.lua)
package.path = package.path .. ';' .. work_dir .. separator .. '?.lua'
-- подпапка cad_system
package.path = package.path .. ';' .. work_dir .. separator .. 'cad_system' .. separator .. '?.lua'

-- ==== Константы ====
local MANIFEST_URL = "https://raw.githubusercontent.com/badtothebonev/cad-systembeta/main/manifest.json"
local BASE_URL     = "https://raw.githubusercontent.com/badtothebonev/cad-systembeta/main/"
local LOCAL_VERSION_FILE = work_dir .. "\\cad_version.txt"

-- ==== Библиотеки ====
local json = require('dkjson')
local lfs  = require('lfs')

-- ==== Логгер ====
local function log(msg)
    print("[CAD Loader] " .. msg)
end

-- ==== Создание директорий ====
local function ensure_dir_exists(path)
    local dir = path:match([[(.*[\\/])]])
    if dir and not lfs.attributes(dir, "mode") then
        lfs.mkdir(dir)
    end
end

-- ==== Запуск cad_main ====
local function launch_cad()
    log("Launching CAD System...")
    local ok, err = pcall(require, 'cad_main')
    if not ok then
        log("ERROR loading cad_main: " .. tostring(err))
    end
end

-- ==== Основная функция ====
function main()
    local update_process_finished = false
    log("Starting CAD System...")

    local temp_manifest_path = work_dir .. separator .. 'manifest.tmp'
    local manifest_url_no_cache = MANIFEST_URL .. "?t=" .. tostring(os.clock())

    log("Downloading manifest...")
    downloadUrlToFile(manifest_url_no_cache, temp_manifest_path, function(id, status)
        if status == 1 then -- STATUS_ENDDOWNLOADDATA
            -- Немного ждём, чтобы файл успел записаться
            lua_thread.create(function()
                wait(100)

                local manifest_file = io.open(temp_manifest_path, "r")
                if not manifest_file then
                    log("ERROR: Could not open downloaded manifest file.")
                    update_process_finished = true
                    -- Фолбэк на локальный запуск
                    launch_cad()
                    return
                end

                local content = manifest_file:read("*a")
                manifest_file:close()
                os.remove(temp_manifest_path)

                if not content or content == "" then
                    log("ERROR: Manifest file is empty or invalid.")
                    update_process_finished = true
                    launch_cad()
                    return
                end

                local manifest, _, err = json.decode(content)
                if not manifest then
                    log("ERROR: Could not parse manifest.json: " .. tostring(err))
                    log("Manifest raw preview: " .. string.sub(content, 1, 200))
                    update_process_finished = true
                    launch_cad()
                    return
                end

                local remote_version = manifest.version
                local local_version = "0"

                local version_file = io.open(LOCAL_VERSION_FILE, "r")
                if version_file then
                    local_version = version_file:read("*a") or "0"
                    version_file:close()
                end

                log("Local version: " .. local_version .. ", Remote version: " .. remote_version)

                -- === Версия актуальна ===
                if remote_version == local_version then
                    log("CAD system is up to date.")
                    launch_cad()
                    update_process_finished = true
                    return
                end

                -- === Обновление ===
                log("New version found. Updating files...")
                local files_to_download_list = {}
                for file_path, remote_path in pairs(manifest.files) do
                    table.insert(files_to_download_list, {file_path = file_path, remote_path = remote_path})
                end
                local total_files = #files_to_download_list

                local function download_next_file(index)
                    if index > total_files then
                        log("Update complete. Saving new version info.")
                        local new_version_file = io.open(LOCAL_VERSION_FILE, "w")
                        if new_version_file then
                            new_version_file:write(remote_version)
                            new_version_file:close()
                        end
                        launch_cad()
                        update_process_finished = true
                        return
                    end

                    local file_info = files_to_download_list[index]
                    local file_path = file_info.file_path
                    local remote_path = file_info.remote_path

                    local local_path = work_dir .. separator .. file_path
                    local remote_url = BASE_URL .. remote_path
                    ensure_dir_exists(local_path)

                    log("Downloading (" .. index .. "/" .. total_files .. "): " .. file_path)

                    downloadUrlToFile(remote_url, local_path, function(_, dl_status)
                        if dl_status == 1 then
                            log("Downloaded " .. file_path)
                            download_next_file(index + 1)
                        elseif dl_status == 2 then
                            log("ERROR: Failed to download " .. file_path .. ". Aborting update.")
                            update_process_finished = true
                            launch_cad()
                        end
                    end)
                end

                if total_files > 0 then
                    download_next_file(1)
                else
                    log("No files to update.")
                    launch_cad()
                    update_process_finished = true
                end
            end)
        elseif status == 2 then -- STATUS_ENDDOWNLOAD (ошибка)
            log("ERROR: Manifest download failed. Check URL and internet connection.")
            update_process_finished = true
            launch_cad()
        end
    end)

    while not update_process_finished do
        wait(0)
    end
end
