-- Live View tab: pin path + field values (Set / Go).

local Log = require("refshell.log")
local theme = require("refshell.theme")
local Core = require("liveview.core")
local Tdb = require("liveview.tdb")
local Widgets = require("liveview.ui.widgets")

local COND = theme.COND

local Inspect = {}

local SOURCE = Core.SOURCE
local state = Core.state

local function read_field(name)
    if not Core.is_managed(state.pinned) then
        return nil, false
    end
    local ok, result = pcall(function()
        return state.pinned:get_field(name)
    end)
    if ok then
        return result, true
    end
    return nil, false
end

local function write_field(name, value)
    if not Core.is_managed(state.pinned) then
        Log.skipped_reason(SOURCE, "nothing pinned")
        return false
    end
    local ok, err = pcall(function()
        state.pinned:set_field(name, value)
    end)
    if ok then
        Log.found(SOURCE, string.format("set %s = %s", name, tostring(value)))
        return true
    end
    Log.error(SOURCE, "set " .. name .. " failed — " .. tostring(err))
    return false
end

local function field_edit(name)
    local slot = state.field_edits[name]
    if not slot then
        slot = { text = "", dirty = false, last_live = "" }
        state.field_edits[name] = slot
    end
    return slot
end

local function draw_field_row(ui, row)
    local name = row.name
    local live, ok = read_field(name)
    if ok and Core.is_managed(live) then
        Core.remember_object(live, name)
    end
    local live_text = ok and Tdb.format_value(live) or "?"
    local slot = field_edit(name)
    if not slot.dirty then
        slot.text = live_text
        slot.last_live = live_text
    else
        slot.last_live = live_text
    end

    imgui.push_id("live_field_" .. name)
    imgui.text(row.label or name)
    if slot.dirty then
        imgui.same_line()
        imgui.text_colored("live " .. live_text, 0xFFA0A3AD)
    end

    local kind = row.kind
    if not ok then
        ui.muted("unreadable")
    elseif kind == "enum" then
        local items = Tdb.enum_members(row.type_full)
        local labels = {}
        local selected = 0
        local live_n = Tdb.enum_numeric(live)
        for i = 1, #items do
            labels[i] = items[i].label
            if items[i].value == live or items[i].value == live_n or tostring(items[i].value) == live_text then
                selected = i
            end
        end
        if #labels == 0 then
            imgui.text_colored(live_text, 0xFFA0A3AD)
        else
            slot.dropdown = slot.dropdown or { open = false, filter = "" }
            local pick, changed = ui.filter_dropdown(
                "enum_" .. name,
                labels[selected],
                labels,
                selected,
                slot.dropdown,
                { header = row.type_name or "Enum", height = 160, placeholder = "Pick enum..." }
            )
            if changed and items[pick] then
                if write_field(name, items[pick].value) then
                    slot.dirty = false
                    slot.text = tostring(items[pick].value)
                    slot.last_live = slot.text
                end
            end
        end
    elseif kind == "bool" then
        local changed, on = imgui.checkbox("##live_bool", live == true)
        if changed then
            if write_field(name, on) then
                slot.dirty = false
                slot.text = on and "true" or "false"
                slot.last_live = slot.text
            end
        end
    elseif Tdb.value_editable(kind, live) then
        local typed, text = ui.input_text("live_edit", slot.text, {
            placeholder = "value",
            width = -52,
        })
        if typed and type(text) == "string" then
            slot.text = text
            slot.dirty = (text ~= live_text)
        end
        imgui.same_line()
        if imgui.button("Set", { 44, 0 }) then
            local value = Tdb.coerce_value(slot.text)
            if write_field(name, value) then
                slot.dirty = false
                slot.last_live = Tdb.format_value(value)
                slot.text = slot.last_live
            end
        end
    else
        imgui.text_colored(live_text, 0xFFA0A3AD)
        if ok and Core.is_managed(live) then
            imgui.same_line()
            if imgui.button("Go", { 36, 0 }) then
                Core.go_to(live, row.label or name, "field")
            end
            local info = Core.collection_info(live)
            if info.collection then
                if slot.array_src ~= live then
                    slot.array_src = live
                    slot.array_pack = nil
                end
                imgui.set_next_item_open(false, COND.Once)
                if imgui.collapsing_header(string.format("Items  %d##arr_%s", info.total, name)) then
                    if slot.array_pack == nil then
                        slot.array_pack = Core.unpack_items(live, info.total)
                    end
                    local pack = slot.array_pack
                    local typed, text = ui.input_text("live_field_items_" .. name, slot.array_filter or "", {
                        label = "Filter items",
                        placeholder = "index or name…",
                    })
                    if typed and type(text) == "string" then
                        slot.array_filter = text
                    end
                    local shown = 0
                    for i = 1, #pack.items do
                        local item = pack.items[i]
                        local hay = tostring(item.index) .. " " .. tostring(item.text or "")
                        if Core.contains_all(hay, slot.array_filter or "") then
                            shown = shown + 1
                            imgui.push_id("live_field_item_" .. name .. "_" .. tostring(item.index))
                            imgui.text(string.format("  [%s]  %s", tostring(item.index), item.text or "?"))
                            if item.object then
                                imgui.same_line()
                                if imgui.button("Go", { 36, 0 }) then
                                    Core.go_to(item.object, string.format("%s[%s]", name, tostring(item.index)), "field")
                                end
                            end
                            imgui.pop_id()
                        end
                    end
                    if shown == 0 then
                        ui.muted("No items match.")
                    elseif pack.total > #pack.items then
                        ui.muted(string.format("showing %d of %d", #pack.items, pack.total))
                    end
                end
            end
        end
    end
    if ok and Core.is_managed(live) and imgui.begin_popup_context_item then
        if imgui.begin_popup_context_item("##live_go_" .. name) then
            if imgui.menu_item and imgui.menu_item("Go to object") then
                Core.go_to(live, row.label or name, "field")
            end
            imgui.end_popup()
        end
    end
    imgui.separator()
    imgui.pop_id()
end

local function draw_fields_inspector(ui, list_h)
    if not Core.is_managed(state.pinned) then
        if state.pinned_kind == "type" and state.pinned_td then
            ui.muted("Type inspect — no live values. Has or Go to get an instance.")
        else
            ui.muted("Open an object from Finder. Values update here like UE4SS Live View.")
            return
        end
    end
    local typed, text = ui.input_text("live_field_filter", state.field_filter, {
        label = "Filter fields",
        placeholder = "name or type…",
    })
    if typed and type(text) == "string" then
        state.field_filter = text
    end

    local rows = {}
    for i = 1, #state.fields do
        local row = state.fields[i]
        local filter = state.field_filter
        local name_hit = Core.contains_all(row.name, filter)
        local type_hit = Core.type_hits(row.type_full, filter) or Core.type_hits(row.type_name, filter)
        if name_hit or type_hit then
            rows[#rows + 1] = row
        end
    end
    imgui.text_colored(string.format("%d fields", #rows), 0xFFA0A3AD)

    imgui.begin_child_window("##live_field_rows", { 0, list_h or Widgets.remaining_height(8) }, true)
    if #rows == 0 then
        imgui.text_colored("No fields match.", 0xFFA0A3AD)
    else
        for i = 1, #rows do
            draw_field_row(ui, rows[i])
        end
    end
    imgui.end_child_window()
end

local function draw_object_section(ui)
    if Core.can_back() then
        if imgui.button("Back##live_insp_back", { 72, 26 }) then
            Core.back()
        end
        imgui.same_line()
        imgui.text_colored(string.format("%d deep", #state.history), 0xFFA0A3AD)
    end
    if state.pinned_name ~= "" then
        ui.kv("Pinned", state.pinned_name .. "  (" .. state.pinned_kind .. ")")
        if state.pinned_kind == "type" then
            ui.muted("Type only — Call statics, or Has-search a live instance.")
        end
    else
        ui.muted("Nothing pinned.")
    end
    if ui.button("Find functions") then
        state.find_fn_open = true
        state.last_call = nil
    end
end

function Inspect.draw(menu)
    local ui = menu and menu.ui
    if not ui then
        return
    end
    draw_object_section(ui)
    imgui.separator()
    imgui.spacing()
    draw_fields_inspector(ui, Widgets.remaining_height(8))
end

return Inspect
