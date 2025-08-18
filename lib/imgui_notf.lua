--[[
    Modern ImGui Notification System
    Credits: Legacy version by Squer, significant rewrite by Gemini.
]]

local imgui = require 'mimgui'
local fa = require 'fAwesome6' -- Используем FontAwesome 6
local encoding = require 'encoding'
encoding.default = 'CP1251'
local u8 = encoding.UTF8

local EXPORTS = {}

local notifications = {}
local max_on_screen = 5
local notification_width = 380.0
local notification_padding = 10.0
local last_notification_pos_y = 0

-- Стили для разных типов уведомлений
local styles = {
    default = {
        icon = fa.FA_INFO_CIRCLE,
        color = imgui.ImVec4(0.2, 0.6, 1.0, 1.0) -- Blue
    },
    success = {
        icon = fa.FA_CHECK_CIRCLE,
        color = imgui.ImVec4(0.3, 0.8, 0.3, 1.0) -- Green
    },
    warning = {
        icon = fa.FA_EXCLAMATION_TRIANGLE,
        color = imgui.ImVec4(1.0, 0.8, 0.2, 1.0) -- Yellow
    },
    error = {
        icon = fa.FA_TIMES_CIRCLE,
        color = imgui.ImVec4(1.0, 0.3, 0.3, 1.0) -- Red
    },
    info = {
        icon = fa.FA_INFO_CIRCLE,
        color = imgui.ImVec4(0.2, 0.6, 1.0, 1.0) -- Blue
    }
}

-- Главная функция рендеринга, вызывается в главном цикле
function EXPORTS.render()
    if #notifications == 0 then return end

    local display_size = imgui.GetIO().DisplaySize
    local screen_width = display_size.x
    
    local current_pos_y = notification_padding
    local new_notifications = {}

    -- Отрисовываем уведомления
    for i, notif in ipairs(notifications) do
        if notif.is_active then
            local time_left = notif.destroy_time - os.clock()
            if time_left > 0 then
                table.insert(new_notifications, notif)

                -- Анимация появления/исчезания
                local alpha_multiplier = 1.0
                if time_left < 0.5 then
                    alpha_multiplier = time_left / 0.5
                elseif notif.start_time and (os.clock() - notif.start_time) < 0.5 then
                    alpha_multiplier = (os.clock() - notif.start_time) / 0.5
                end
                
                local window_pos = imgui.new('ImVec2', screen_width - notification_width - notification_padding, current_pos_y)
                
                mimgui.SetNextWindowPos(window_pos)
                mimgui.SetNextWindowSize(imgui.new('ImVec2', notification_width, 0))
                mimgui.SetNextWindowBgAlpha(0.9 * alpha_multiplier)

                local flags = mimgui.WindowFlags.NoTitleBar + mimgui.WindowFlags.NoResize + mimgui.WindowFlags.NoMove + mimgui.WindowFlags.NoScrollbar + mimgui.WindowFlags.NoSavedSettings + mimgui.WindowFlags.NoFocusOnAppearing

                mimgui.PushStyleVar(mimgui.StyleVar.WindowRounding, 5.0)
                mimgui.Begin('Notification##' .. i, nil, flags)

                local draw_list = mimgui.GetWindowDrawList()

                -- Линия-индикатор типа
                local p1 = mimgui.GetWindowPos()
                local p2 = imgui.new('ImVec2', p1.x, p1.y + mimgui.GetWindowHeight())
                draw_list:AddLine(p1, p2, mimgui.GetColorU32(notif.style.color), 4.0)

                mimgui.PushFont(fa.getFont(20))
                mimgui.TextColored(notif.style.color, notif.style.icon)
                mimgui.PopFont()
                mimgui.SameLine()

                mimgui.BeginGroup()
                mimgui.TextWrapped(u8(notif.title))
                mimgui.Separator()
                mimgui.TextWrapped(u8(notif.text))
                mimgui.EndGroup()

                -- Прогресс-бар времени жизни
                local progress = time_left / notif.duration
                local p_bar_y = p1.y + mimgui.GetWindowHeight() - 2
                local p_bar_x_end = p1.x + (notification_width * progress)
                draw_list:AddLine(imgui.new('ImVec2', p1.x, p_bar_y), imgui.new('ImVec2', p_bar_x_end, p_bar_y), mimgui.GetColorU32(notif.style.color), 2.0)

                current_pos_y = current_pos_y + mimgui.GetWindowHeight() + notification_padding
                
                mimgui.End()
                mimgui.PopStyleVar()
            else
                notif.is_active = false
            end
        end
    end
    notifications = new_notifications
end

-- Функция для добавления уведомлений
function EXPORTS.add(title, text, duration, type)
    duration = duration or 8
    type = type or 'default'

    local style = styles[type] or styles.default

    local new_notification = {
        title = title,
        text = text,
        duration = duration,
        start_time = os.clock(),
        destroy_time = os.clock() + duration,
        style = style,
        is_active = true
    }

    table.insert(notifications, 1, new_notification)

    if #notifications > max_on_screen then
        table.remove(notifications, max_on_screen + 1)
    end
end

return EXPORTS