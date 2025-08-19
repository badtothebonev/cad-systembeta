--[[ 
    CAD System Bootstrapper
    Downloads and validates all necessary script files before launching the main application.
]]

-- Add lib folder to package path to find dependencies
package.path = package.path .. ';' .. getWorkingDirectory() .. '\lib\?.lua;'

local MANIFEST_URL = "https://raw.githubusercontent.com/badtothebonev/cad-systembeta/main/manifest.json"

local BASE_URL = "https://raw.githubusercontent.com/badtothebonev/cad-systembeta/main/"
local LOCAL_VERSION_FILE = getWorkingDirectory() .. "\\cad_version.txt"

local json = require('dkjson')
local lfs = require('lfs')

-- Helper function to create directories
local function ensure_dir_exists(path)
    local dir = path:match([[(.*[\/])]])
    if dir then
        lfs.mkdir(dir)
    end
end

-- Helper function for logging
local function log(msg)
    print("[CAD Loader] " .. msg)
end

-- Main function
function main()
    log("Starting CAD System...")

    -- Add a random query to bypass caches
    local manifest_url_no_cache = MANIFEST_URL .. "?t=" .. tostring(os.clock())
    local temp_manifest_path = os.tmpname()

    log("Downloading manifest...")
    downloadUrlToFile(manifest_url_no_cache, temp_manifest_path, function(id, status, p1, p2)
        if status ~= 1 then -- 1 = STATUS_ENDDOWNLOADDATA
            return
        end

        log("Manifest downloaded.")
        local manifest_file = io.open(temp_manifest_path, "r")
        if not manifest_file then
            log("ERROR: Could not open downloaded manifest file.")
            return
        end

        local content = manifest_file:read("*a")
        manifest_file:close()
        os.remove(temp_manifest_path)

        local manifest, _, err = json.decode(content)
        if not manifest then
            log("ERROR: Could not parse manifest.json: " .. (err or "unknown error"))
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

        if remote_version == local_version then
            log("CAD system is up to date. Launching...")
            -- Use pcall to catch errors during main script execution
            local ok, err = pcall(require, 'cad_main')
            if not ok then
                log("CRITICAL: Failed to run cad_main.lua: " .. tostring(err))
            end
            return
        end

        log("New version found. Updating files...")

        local files_to_download = manifest.files
        local total_files = 0
        for _ in pairs(files_to_download) do total_files = total_files + 1 end
        local downloaded_files = 0

        for file_path, remote_path in pairs(files_to_download) do
            local local_path = getWorkingDirectory() .. "\\" .. file_path
            local remote_url = BASE_URL .. remote_path

            ensure_dir_exists(local_path)

            log("Downloading (" .. (downloaded_files + 1) .. "/" .. total_files .. "): " .. file_path)

            downloadUrlToFile(remote_url, local_path, function(dl_id, dl_status, _, _)
                if dl_status == 1 then
                    downloaded_files = downloaded_files + 1
                    log("Downloaded " .. file_path)
                end
            end)
        end

        -- Wait for all downloads to complete (with a timeout)
        local timeout = 30000 -- 30 seconds
        local timer = os.clock()
        while downloaded_files < total_files and (os.clock() - timer) * 1000 < timeout do
            wait(100)
        end

        if downloaded_files == total_files then
            log("Update complete. Saving new version info.")
            local new_version_file = io.open(LOCAL_VERSION_FILE, "w")
            if new_version_file then
                new_version_file:write(remote_version)
                new_version_file:close()
            end
            log("Launching CAD System...")
            local ok, err = pcall(require, 'cad_main')
            if not ok then
                log("CRITICAL: Failed to run cad_main.lua: " .. tostring(err))
            end
        else
            log("ERROR: Update failed. Some files could not be downloaded. Please try again later.")
        end
    end)
end
