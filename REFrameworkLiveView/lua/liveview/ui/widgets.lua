-- Shared Live ImGui bits: heights, clickable lists, workspace tab switches.

local Core = require("liveview.core")
local theme = require("refshell.theme")

local COL = theme.COL
local push_color = theme.push_color

local Widgets = {}

local state = Core.state

function Widgets.show_console()
    state.ws_tab = 1
end

function Widgets.show_live()
    state.ws_tab = 2
end

function Widgets.show_chat()
    state.ws_tab = 3
end

function Widgets.remaining_height(pad)
    pad = pad or 18
    local win = imgui.get_window_size()
    local cursor = imgui.get_cursor_pos()
    local h = 120
    if win and cursor and win.y and cursor.y then
        h = win.y - cursor.y - pad
    end
    if h < 80 then
        h = 80
    end
    return h
end

function Widgets.draw_list(id, items, selected, on_click, list_h)
    list_h = list_h or 160
    selected = tonumber(selected) or 0
    local pal = theme.themes.midnight
    imgui.begin_child_window("##" .. id, { 0, list_h }, true)
    if #items == 0 then
        imgui.text_colored("No rows.", 0xFFA0A3AD)
    else
        for i, item in ipairs(items) do
            local label = item
            if type(item) == "table" then
                label = item.label or item.name or tostring(i)
            end
            imgui.push_id(id .. tostring(i))
            local pushed = 0
            if i == selected then
                if push_color(COL.Button, pal.selected) then
                    pushed = pushed + 1
                end
                if push_color(COL.ButtonHovered, pal.accent_d) then
                    pushed = pushed + 1
                end
                if push_color(COL.ButtonActive, pal.accent_d) then
                    pushed = pushed + 1
                end
            end
            if imgui.button(tostring(label), { -1, 24 }) then
                selected = i
                if on_click then
                    on_click(i, item)
                end
            end
            if pushed > 0 then
                imgui.pop_style_color(pushed)
            end
            imgui.pop_id()
        end
    end
    imgui.end_child_window()
    return selected
end

return Widgets
