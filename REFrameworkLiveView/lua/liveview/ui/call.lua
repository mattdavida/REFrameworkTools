-- Find-functions window: method list, Call, Result, Go to object.

local theme = require("refshell.theme")
local Core = require("liveview.core")
local Invoke = require("liveview.invoke")
local Widgets = require("liveview.ui.widgets")

local COND = theme.COND
local WIN = theme.WIN

local Call = {}

local state = Core.state

local function route_to_object(obj, name)
    if not Core.is_managed(obj) then
        return
    end
    Core.go_to(obj, name, "return")
    Widgets.show_live()
    state.find_fn_open = false
    state.last_call = nil
end

local function route_to_item(obj, name)
    if not Core.is_managed(obj) then
        return
    end
    Core.go_to(obj, name, "return")
    Widgets.show_live()
end

local function draw_call_items(ui, call)
    local items = call.items
    if type(items) ~= "table" or #items == 0 then
        if (call.item_n or 0) > 0 then
            ui.muted("Collection is empty or could not be unpacked.")
        end
        return
    end
    local typed, text = ui.input_text("live_call_items", state.call_items_filter, {
        label = "Filter items",
        placeholder = "name or type…",
    })
    if typed and type(text) == "string" then
        state.call_items_filter = text
    end
    local shown = {}
    for i = 1, #items do
        local row = items[i]
        local hay = tostring(row.index) .. " " .. tostring(row.text or "")
        if Core.contains_all(hay, state.call_items_filter) then
            shown[#shown + 1] = row
        end
    end
    local cap_note = ""
    if call.item_n > #items then
        cap_note = string.format("  showing %d of %d", #items, call.item_n)
    end
    imgui.text_colored(string.format("%d items%s", #shown, cap_note), 0xFFA0A3AD)
    local list_h = Widgets.remaining_height(8)
    imgui.begin_child_window("##live_call_items", { 0, list_h }, true)
    if #shown == 0 then
        imgui.text_colored("No items match.", 0xFFA0A3AD)
    else
        for i = 1, #shown do
            local row = shown[i]
            imgui.push_id("live_call_item_" .. tostring(row.index))
            imgui.text(string.format("[%s]  %s", tostring(row.index), row.text or "?"))
            if row.object then
                imgui.same_line()
                if imgui.button("Go", { 36, 0 }) then
                    route_to_item(row.object, string.format("%s[%s]", call.via or "item", tostring(row.index)))
                end
            end
            imgui.pop_id()
        end
    end
    imgui.end_child_window()
end

local function draw_arg_slot(ui, index, slot)
    local title = string.format("%s %s", slot.type_name or "?", slot.param_name or ("arg" .. tostring(index)))
    imgui.text(title)
    imgui.push_id("live_arg_" .. tostring(index))
    if slot.kind == "bool" then
        local changed, on = imgui.checkbox("##arg_bool", slot.bool_value and true or false)
        if changed then
            slot.bool_value = on
        end
    elseif slot.kind == "enum" then
        local labels = {}
        for i = 1, #slot.enum_items do
            labels[i] = slot.enum_items[i].label
        end
        local caption = labels[slot.selected] or "Pick enum…"
        local list_h = 160
        if #labels > 40 then
            list_h = 240
        end
        local pick, changed = ui.filter_dropdown(
            "arg_enum_" .. tostring(index),
            caption,
            labels,
            slot.selected,
            slot.dropdown,
            { header = slot.type_full or "Enum", height = list_h, placeholder = "Pick enum…" }
        )
        if changed then
            slot.selected = pick
        end
        if not slot.selected or slot.selected < 1 then
            ui.muted(string.format("%d members — pick one. INVALID is not chosen for you.", #slot.enum_items))
        end
    elseif slot.kind == "object" then
        local labels = {}
        for i = 1, #slot.candidates do
            labels[i] = slot.candidates[i].label
        end
        local caption = labels[slot.selected] or "(nil)"
        local pick, changed = ui.filter_dropdown(
            "arg_obj_" .. tostring(index),
            caption,
            labels,
            slot.selected,
            slot.dropdown,
            { header = slot.type_full or "Object", height = 180, placeholder = "Pick live object..." }
        )
        if changed then
            slot.selected = pick
        end
        if ui.button("Find live") then
            Invoke.refresh_object_candidates(slot, true)
        end
        ui.muted(string.format("%d live %s — Find live walks the scene.", math.max(0, #slot.candidates - 1), slot.type_name or "objects"))
    elseif slot.kind == "number" or slot.kind == "string" or slot.kind == "valuetype" then
        local hint = "0"
        if slot.kind == "string" then
            hint = "text"
        elseif slot.kind == "valuetype" then
            hint = "value"
        end
        local typed, text = ui.input_text("arg_text", slot.text or "", {
            placeholder = hint,
        })
        if typed and type(text) == "string" then
            slot.text = text
        end
        if slot.kind == "valuetype" then
            ui.muted("Value type — type a primitive if the method accepts one.")
        end
    else
        local typed, text = ui.input_text("arg_raw", slot.text or "", {
            placeholder = "comma or literal",
        })
        if typed and type(text) == "string" then
            slot.text = text
        end
        ui.muted("No picker for this type yet. Comma-style text still works.")
    end
    imgui.pop_id()
    imgui.spacing()
end

local function draw_call_pane(ui)
    if state.method_name == "" then
        ui.muted("Click a method above, then Call. Go to opens that object in Live View.")
        return
    end
    if not Core.is_managed(state.pinned) then
        if state.pinned_kind == "type" and state.pinned_td then
            ui.muted("Type inspect — Call works for static methods only.")
        else
            ui.muted("Pin an object in Live, then call methods here.")
            return
        end
    end
    if state.method_sig ~= "" then
        ui.label(state.method_sig)
    end
    if #state.call_slots == 0 then
        if state.method_sig ~= "" and (state.method_args_hint == nil or state.method_args_hint == "") then
            ui.muted("No args.")
        else
            local atyped, atext = ui.input_text("live_args", state.method_args, {
                label = "Arguments",
                placeholder = "1, true",
            })
            if atyped and type(atext) == "string" then
                state.method_args = atext
            end
        end
    else
        for i = 1, #state.call_slots do
            draw_arg_slot(ui, i, state.call_slots[i])
        end
    end
    if ui.button("Call") then
        Invoke.run_call()
    end
    local call = state.last_call
    if not call then
        return
    end
    imgui.spacing()
    imgui.separator()
    if call.ok then
        imgui.text("Result")
        imgui.same_line()
        if call.can_go and call.object ~= nil then
            local go_label = call.is_collection and "Go to list" or "Go to object"
            if imgui.button(go_label .. "##live_call_go", { 108, 22 }) then
                route_to_object(call.object, call.text or call.via)
            end
        end
        imgui.text_colored(tostring(call.text or ""), 0xFFA0A3AD)
    else
        imgui.text_colored("Error: " .. tostring(call.text), 0xFF6E6EFF)
    end
    if call.ok and call.is_collection then
        ui.section(string.format("Items  %d", call.item_n or 0), function()
            if call.items == nil and call.object ~= nil then
                local pack = Core.unpack_items(call.object, call.item_n or 0)
                call.items = pack.items
                call.item_n = pack.total
            end
            draw_call_items(ui, call)
        end, false)
    end
end

local function draw_methods_list(ui, list_h)
    if not Core.is_managed(state.pinned) and not (state.pinned_kind == "type" and state.pinned_td) then
        ui.muted("Pin an object in Live, then call methods here.")
        return
    end
    local mftyped, mftext = ui.input_text("live_method_filter", state.method_filter, {
        label = "Filter methods",
        placeholder = "name contains…",
    })
    if mftyped and type(mftext) == "string" then
        state.method_filter = mftext
    end

    local method_rows = {}
    for i = 1, #state.methods do
        if Core.contains_all(state.methods[i].label, state.method_filter) then
            method_rows[#method_rows + 1] = state.methods[i]
        end
    end

    imgui.begin_child_window("##live_methods", { 0, list_h or Widgets.remaining_height(8) }, true)
    if #method_rows == 0 then
        imgui.text_colored("No methods match.", 0xFFA0A3AD)
    else
        for i = 1, #method_rows do
            local row = method_rows[i]
            local key = row.label or row.name
            local selected = state.method_picked == key
            imgui.push_id("live_m_" .. tostring(i))
            local caption = tostring(row.label or row.name or i)
            if selected then
                caption = "▸  " .. caption
            end
            if imgui.button(caption, { -1, 24 }) then
                Invoke.select_method(row)
            end
            imgui.pop_id()
        end
    end
    imgui.end_child_window()
end

function Call.draw_window(menu)
    if not state.find_fn_open then
        return
    end
    local ui = menu and menu.ui
    if not ui then
        return
    end
    local wr = menu._ws_rect
    local width = 640
    local height = 520
    local x, y = 80, 80
    if wr then
        width = math.max(480, (wr.w or 640) - 48)
        height = math.max(360, (wr.h or 520) - 72)
        x = (wr.x or 0) + 24
        y = (wr.y or 0) + 56
    end
    imgui.set_next_window_pos({ x, y }, COND.Appearing)
    imgui.set_next_window_size({ width, height }, COND.Appearing)
    local color_n, var_n = theme.push_theme(theme.themes.violet)
    local open = imgui.begin_window("Select a function to call", true, WIN.NoSavedSettings)
    if open then
        local win = imgui.get_window_size()
        local methods_h = 160
        if win and win.y then
            methods_h = math.max(140, math.floor(win.y * 0.38))
        end
        draw_methods_list(ui, methods_h)
        imgui.spacing()
        imgui.separator()
        imgui.spacing()
        imgui.begin_child_window("##live_call_pane", { 0, Widgets.remaining_height(8) }, true)
        draw_call_pane(ui)
        imgui.end_child_window()
        menu:note_imgui_hover(true)
    end
    imgui.end_window()
    theme.pop_theme(color_n, var_n)
    if not open then
        state.find_fn_open = false
    end
end

return Call
