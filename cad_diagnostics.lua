
script_name('CAD Diagnostics')
script_author('badtothebone')
script_version('2.1')

local imgui = require 'mimgui'
local ffi = require 'ffi'
local inspect = require 'inspect'

local show_diag_window = imgui.new.bool(true)
local log_buffer = {}
local MAX_LOG_LINES = 100

local colors = {
    ERROR = imgui.ImVec4(1.0, 0.2, 0.2, 1.0), -- Red
    WARN = imgui.ImVec4(1.0, 1.0, 0.0, 1.0),  -- Yellow
    INFO = imgui.ImVec4(1.0, 1.0, 1.0, 1.0),  -- White
    DEBUG = imgui.ImVec4(0.6, 0.6, 0.6, 1.0), -- Gray
    UNKNOWN = imgui.ImVec4(0.8, 0.5, 1.0, 1.0) -- Purple
}


local function parse_log_line(line)
    local timestamp, module, level, message = line:match("^(%[%d%d:%d%d:%d%d%]) %[(.-)%] %[(.-)%] (.*)$")
    if timestamp then
        module = module:gsub("%s*$", "")
        level = level:gsub("%s*$", "")
        return { timestamp = timestamp, module = module, level = level, message = message, color = colors[level] or colors.UNKNOWN }
    end
    return { message = line, color = colors.INFO }
end

local function read_last_log_lines()
    local file = io.open("moonloader/cad_debug.log", "r")
    if not file then
        return { { message = "[ERROR] Could not open cad_debug.log", color = colors.ERROR } }
    end
    
    local lines = {}
    for line in file:lines() do
        table.insert(lines, parse_log_line(line))
        if #lines > MAX_LOG_LINES then
            table.remove(lines, 1)
        end
    end
    file:close()
    return lines
end


local function render_status_panel()
    imgui.BeginChild("StatusPanel", imgui.ImVec2(0, 100), true)
    imgui.Text("Live System Status")
    imgui.Separator()

    local deps = _G.CAD_DIAGNOSTICS and _G.CAD_DIAGNOSTICS.getDeps and _G.CAD_DIAGNOSTICS.getDeps()

    if not deps or not deps.websocket or not deps.auth then
        imgui.Text("CAD Main script not running or accessible.")
        imgui.EndChild()
        return
    end

    local status = deps.websocket.get_status()
    local status_color = colors.WARN
    if status == 'CONNECTED' then status_color = colors.INFO and imgui.ImVec4(0, 1, 0, 1) -- Green
    elseif status == 'DISCONNECTED' then status_color = colors.ERROR end
    imgui.Text("WebSocket:")
    imgui.SameLine()
    imgui.TextColored(status_color, status)

    imgui.SameLine(200)
    local auth_status = "Not Authenticated"
    local auth_color = colors.DEBUG
    if deps.auth.isAuthenticated() then
        auth_status = "Authenticated as " .. (deps.auth.current_user.username or "Unknown")
        auth_color = imgui.ImVec4(0.2, 0.8, 1, 1) -- Blue
    end
    imgui.Text("Authentication:")
    imgui.SameLine()
    imgui.TextColored(auth_color, auth_status)

    imgui.EndChild()
end

local function render_log_panel()
    imgui.BeginChild("LogPanel", imgui.ImVec2(0, 0), true)
    imgui.Text("Live Log Viewer")
    imgui.SameLine()
    if imgui.SmallButton("Refresh Log") then
        log_buffer = read_last_log_lines()
    end
    imgui.Separator()

    for _, line in ipairs(log_buffer) do
        if line.timestamp then
            imgui.TextColored(colors.DEBUG, line.timestamp)
            imgui.SameLine()
            imgui.TextColored(line.color, string.format("[%-10s] [%-5s]", line.module, line.level))
            imgui.SameLine()
            imgui.PushTextWrapPos(imgui.GetContentRegionAvail().x)
            imgui.TextWrapped(line.message)
            imgui.PopTextWrapPos()
        else
            imgui.PushTextWrapPos(imgui.GetContentRegionAvail().x)
            imgui.TextWrapped(line.message)
            imgui.PopTextWrapPos()
        end
    end
    
    imgui.EndChild()
end

imgui.OnFrame(
    function() return show_diag_window[0] end,
    function()
        local sw, sh = getScreenResolution()
        imgui.SetNextWindowSize(imgui.ImVec2(800, 500), imgui.Cond.FirstUseEver)
        imgui.SetNextWindowPos(imgui.ImVec2(sw / 2, sh / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))

        if imgui.Begin("CAD Diagnostics", show_diag_window) then
            render_status_panel()
            render_log_panel()
        end
        imgui.End()
    end
)


function main()
    sampRegisterChatCommand('caddiag', function()
        show_diag_window[0] = not show_diag_window[0]
        if show_diag_window[0] then
            log_buffer = read_last_log_lines()
        end
    end)

    sampRegisterChatCommand('diag_settings', function()
        sampAddChatMessage("[CAD Diagnostics] Waiting for modules to be ready...", 0xFFFF00)
        lua_thread.create(function()
            wait(2000) 

            local deps = _G.CAD_DIAGNOSTICS and _G.CAD_DIAGNOSTICS.getDeps and _G.CAD_DIAGNOSTICS.getDeps()
            if not deps or not deps.settings then
                sampAddChatMessage("[CAD Diagnostics] Settings module not ready after wait.", 0xFF0000)
                return
            end
            
            local file = io.open("moonloader/cad_debug.log", "a")
            if file then
                file:write("\n--- SETTINGS.CONFIG DIAGNOSTIC DUMP ---")
                file:write(inspect(deps.settings.config))
                file:write("\n--- END OF DUMP ---")
                file:close()
                sampAddChatMessage("[CAD Diagnostics] Dumped settings.config to cad_debug.log", 0x00FF00)
            else
                sampAddChatMessage("[CAD Diagnostics] Failed to open log file for writing.", 0xFF0000)
            end
        end)
    end)
    
    wait(1000)
    log_buffer = read_last_log_lines()
    if isSampAvailable() then
        sampAddChatMessage("[CAD Diagnostics] Loaded. Use /caddiag to toggle the debug window.", 0x00FF00)
    end
    
    wait(-1)
end
