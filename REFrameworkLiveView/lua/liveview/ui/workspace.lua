-- DevTools workspace: Console | Live View | Chat (violet theme, trainer stays midnight).

local Log = require("refshell.log")
local theme = require("refshell.theme")
local Core = require("liveview.core")
local Inspect = require("liveview.ui.inspect")
local Call = require("liveview.ui.call")
local Chat = require("liveview.ui.chat")
local Widgets = require("liveview.ui.widgets")

local COL = theme.COL
local WIN = theme.WIN
local COND = theme.COND
local push_color = theme.push_color

local Workspace = {}

local state = Core.state
local WS_TABS = { "Console", "Live View", "Chat" }

local function draw_ws_tabs(menu)
    if state.ws_tab < 1 or state.ws_tab > #WS_TABS then
        state.ws_tab = 2
    end
    local avail = 400
    pcall(function()
        local w = imgui.get_content_region_avail()
        if w and w.x then
            avail = w.x
        end
    end)
    local gap = 8
    local reset_w = 128
    local btn_w = (avail - gap * #WS_TABS - reset_w) / #WS_TABS
    if btn_w < 72 then
        btn_w = 72
    end
    local violet = theme.themes.violet
    for i = 1, #WS_TABS do
        if i > 1 then
            imgui.same_line()
        end
        local pushed = 0
        if state.ws_tab == i then
            if push_color(COL.Button, violet.selected) then
                pushed = pushed + 1
            end
            if push_color(COL.ButtonHovered, violet.selected) then
                pushed = pushed + 1
            end
        end
        if imgui.button(WS_TABS[i] .. "##ws_tab", { btn_w, 28 }) then
            state.ws_tab = i
        end
        if pushed > 0 then
            imgui.pop_style_color(pushed)
        end
    end
    imgui.same_line()
    if imgui.button("Refresh##ws_reset", { reset_w, 28 }) then
        require("liveview.cache").rebuild()
        Log.info(Core.SOURCE, "Live cache refreshed")
        if menu and menu.toast then
            menu:toast("Live cache refreshed", "info", 1600)
        end
    end
    imgui.spacing()
end

function Workspace.draw(menu)
    if not menu or not menu._logs_open then
        return
    end

    Log.mark_seen()

    local rect = menu._win_rect
    local live = menu._live_layout == true
    local width = 920
    local height = 420
    local x, y
    if live then
        local split = theme.live_split(menu.cfg and menu.cfg.margin or 16)
        x, y = split.right.x, split.right.y
        width, height = split.right.w, split.right.h
    else
        if rect and rect.h and rect.h > 240 then
            height = math.min(rect.h, 560)
        end
        x, y = Log.place(menu, width, height)
    end

    imgui.set_next_window_pos({ x, y }, COND.Always)
    imgui.set_next_window_size({ width, height }, COND.Always)

    local color_n, var_n = theme.push_theme(theme.themes.violet)
    local open = imgui.begin_window("DevTools", true, WIN.NoCollapse + WIN.NoSavedSettings)
    if open then
        draw_ws_tabs(menu)
        if state.ws_tab == 1 then
            Log.draw_contents(menu, { list_h = Widgets.remaining_height(8) })
        elseif state.ws_tab == 3 then
            Chat.draw(menu)
        else
            Inspect.draw(menu)
        end

        menu:note_imgui_hover(true)
        local pos_ok, pos = pcall(imgui.get_window_pos)
        local size_ok, size = pcall(imgui.get_window_size)
        if pos_ok and size_ok and pos and size then
            menu._ws_rect = { x = pos.x, y = pos.y, w = size.x, h = size.y }
        end
    end
    imgui.end_window()
    menu:note_imgui_hover(false)
    theme.pop_theme(color_n, var_n)

    if open then
        Call.draw_window(menu)
    end

    if not open then
        menu._logs_open = false
        menu._ws_rect = nil
        state.find_fn_open = false
    end
end

return Workspace
