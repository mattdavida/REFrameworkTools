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

local function pack_abgr(rgba)
    local r = math.floor((rgba[1] or 0) * 255 + 0.5)
    local g = math.floor((rgba[2] or 0) * 255 + 0.5)
    local b = math.floor((rgba[3] or 0) * 255 + 0.5)
    local a = math.floor((rgba[4] or 1) * 255 + 0.5)
    return a * 16777216 + b * 65536 + g * 256 + r
end

local SWITCH_W = 44
local SWITCH_H = 22
local ROW_H = 28
local LABEL_GAP = 8
local CHIP_GAP = 16
local DOT_R = 4
local LIVE_DOT = { 0.32, 0.78, 0.46, 1.00 }
local STALE_DOT = { 0.92, 0.40, 0.38, 1.00 }
local OFF_TRACK = { 0.30, 0.28, 0.34, 1.00 }
local THUMB = { 0.94, 0.93, 0.96, 1.00 }

local function text_size(s)
    local ok, sz = pcall(imgui.calc_text_size, s)
    if ok and sz then
        return sz.x or (#s * 7), sz.y or 13
    end
    return #s * 7, 13
end

local function draw_cache_switch(on, violet)
    local label = on and "Enabled" or "Disabled"
    local tw, th = text_size(label)
    local cluster_w = tw + LABEL_GAP + SWITCH_W
    local origin = imgui.get_cursor_screen_pos()
    local clicked = imgui.invisible_button("##ws_cache_switch", { cluster_w, ROW_H })
    local hovered = imgui.is_item_hovered()
    pcall(function()
        local dl = imgui.get_window_draw_list()
        if not dl or not origin then
            return
        end
        local x = origin.x or origin[1] or 0
        local y = origin.y or origin[2] or 0
        local mid = y + ROW_H * 0.5
        dl:add_text({ x, mid - th * 0.5 }, pack_abgr(on and violet.accent or violet.muted), label)
        local sx = x + tw + LABEL_GAP
        local sy = mid - SWITCH_H * 0.5
        local fill = on and violet.selected or OFF_TRACK
        if hovered then
            fill = on and violet.button_h or violet.header
        end
        local r = SWITCH_H * 0.5
        dl:add_rect_filled({ sx, sy }, { sx + SWITCH_W, sy + SWITCH_H }, pack_abgr(fill), r, 0)
        local thumb_r = r - 3
        local cx = on and (sx + SWITCH_W - 3 - thumb_r) or (sx + 3 + thumb_r)
        dl:add_circle_filled({ cx, mid }, thumb_r, pack_abgr(THUMB), 16)
    end)
    return clicked
end

local function bridge_chip_label(link, busy)
    if link == "live" and busy then
        return "Bridge · busy", LIVE_DOT
    end
    if link == "live" then
        return "Bridge · live", LIVE_DOT
    end
    if link == "waiting" then
        return "Bridge · wait", nil
    end
    return "Bridge · stale", STALE_DOT
end

local function draw_bridge_chip(link, busy, violet)
    local label, dot = bridge_chip_label(link, busy)
    if not dot then
        dot = violet.muted
    end
    local tw, th = text_size(label)
    local cluster_w = DOT_R * 2 + LABEL_GAP + tw
    local origin = imgui.get_cursor_screen_pos()
    local clicked = imgui.invisible_button("##ws_bridge_chip", { cluster_w, ROW_H })
    local hovered = imgui.is_item_hovered()
    pcall(function()
        local dl = imgui.get_window_draw_list()
        if not dl or not origin then
            return
        end
        local x = origin.x or origin[1] or 0
        local y = origin.y or origin[2] or 0
        local mid = y + ROW_H * 0.5
        if hovered then
            dl:add_rect_filled({ x - 6, y }, { x + cluster_w + 6, y + ROW_H }, pack_abgr(violet.header), 6, 0)
        end
        dl:add_circle_filled({ x + DOT_R, mid }, DOT_R, pack_abgr(dot), 12)
        local text_col = (link == "live") and violet.accent or (link == "stale" and STALE_DOT or violet.muted)
        dl:add_text({ x + DOT_R * 2 + LABEL_GAP, mid - th * 0.5 }, pack_abgr(text_col), label)
    end)
    return clicked
end

local function notify_cache(menu, enabled)
    if enabled then
        Log.info(Core.SOURCE, "Live cache enabled")
        if menu and menu.toast then
            menu:toast("Live cache refreshed", "info", 1600)
        end
    else
        Log.info(Core.SOURCE, "Live cache paused")
        if menu and menu.toast then
            menu:toast("Live cache paused", "info", 1600)
        end
    end
end

local Workspace = {}

local state = Core.state
local WS_TABS = { "Console", "Live View", "Chat" }

local function set_pos(x, y)
    if Vector2f and Vector2f.new then
        imgui.set_cursor_pos(Vector2f.new(x, y))
    else
        imgui.set_cursor_pos({ x, y })
    end
end

local function pill_w(label, min_w)
    local w = min_w
    local ok, sz = pcall(imgui.calc_text_size, label)
    if ok and sz and sz.x then
        w = math.max(min_w, sz.x + 24)
    end
    return w
end

local function draw_ws_tabs(menu)
    if state.ws_tab < 1 or state.ws_tab > #WS_TABS then
        state.ws_tab = 2
    end
    local origin = imgui.get_cursor_pos()
    local row_x = (origin and origin.x) or 14
    local row_y = (origin and origin.y) or 0
    local win = imgui.get_window_size()
    local pad = row_x
    local right = ((win and win.x) or 400) - pad
    local reset_w = pill_w("Refresh", 80)
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
        if imgui.button(WS_TABS[i] .. "##ws_tab", { pill_w(WS_TABS[i], 72), 28 }) then
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

    local Cache = require("liveview.cache")
    local cache_on = Cache.enabled()
    local switch_label = cache_on and "Enabled" or "Disabled"
    local switch_w = select(1, text_size(switch_label)) + LABEL_GAP + SWITCH_W
    local link, busy = require("liveview.bridge").link_state()
    local chip_label = select(1, bridge_chip_label(link, busy))
    local chip_w = DOT_R * 2 + LABEL_GAP + select(1, text_size(chip_label))

    set_pos(right - switch_w - CHIP_GAP - chip_w, row_y)
    if draw_bridge_chip(link, busy, violet) then
        Chat.recover(menu)
    end
    set_pos(right - switch_w, row_y)
    if draw_cache_switch(cache_on, violet) then
        Cache.set_enabled(not cache_on)
        notify_cache(menu, Cache.enabled())
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
