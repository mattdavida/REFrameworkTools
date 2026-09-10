-- Live tab: Search + Results. Finder stays on the left.

local Core = require("liveview.core")
local Cache = require("liveview.cache")
local Widgets = require("liveview.ui.widgets")

local Finder = {}

local function pin_row(row)
    local ok = Core.open_row(row)
    if ok then
        Widgets.show_live()
    end
    return ok
end

local function live_rows()
    local state = Core.state
    local needle = Core.trim(state.filter)
    local rows = Cache.filter(needle)
    if state.show_types and needle ~= "" and Core.plugin_ok() then
        local types = {}
        pcall(function()
            types = reflive.search_types(needle)
        end)
        if type(types) == "table" then
            for i = 1, #types do
                rows[#rows + 1] = types[i]
            end
        end
    end
    state.results = rows
    return rows
end

local function row_is_opened(row)
    if type(row) ~= "table" then
        return false
    end
    local st = Core.state
    if Core.is_managed(st.pinned) and Core.is_managed(row.object) then
        return Core.object_key(st.pinned) == Core.object_key(row.object)
    end
    local opened = tostring(st.pinned_name or "")
    if opened == "" then
        return false
    end
    return tostring(row.path or "") == opened or tostring(row.name or "") == opened
end

local function opened_index(shown)
    if type(shown) ~= "table" then
        return 0
    end
    for i = 1, #shown do
        if row_is_opened(shown[i]) then
            return i
        end
    end
    local idx = tonumber(Core.state.selected) or 0
    if idx < 1 or idx > #shown then
        return 0
    end
    return idx
end

local function filtered_results(rows)
    local state = Core.state
    local needle = Core.trim(state.results_filter)
    if needle == "" then
        return rows
    end
    local out = {}
    for i = 1, #rows do
        local row = rows[i]
        local hay = table.concat({
            tostring(row.path or ""),
            tostring(row.name or ""),
            tostring(row.kind or ""),
            tostring(row.type or ""),
            tostring(row.label or ""),
        }, " ")
        if Core.contains_all(hay, needle) then
            out[#out + 1] = row
        end
    end
    return out
end

function Finder.draw(menu, ui)
    local state = Core.state
    if not Core.plugin_ok() then
        ui.muted("ref_live.dll not loaded. Cache still seeds PlayerManager.")
    end

    local typed, text = ui.input_text("live_query", state.filter, {
        label = "Search",
        placeholder = "cPlayerContextParam, health, Player…",
    })
    if type(text) == "string" and (typed or text ~= "") then
        if text ~= state.filter then
            state.filter = text
        end
    end
    local changed_types, types_on = ui.toggle("Include types", state.show_types)
    if changed_types then
        state.show_types = types_on and true or false
    end
    local stats = Cache.stats()
    if not Cache.enabled() then
        ui.muted("Cache paused — enable Live cache at the top right.")
    else
        ui.muted(string.format(
            "Live cache %d — %d hops, %d singletons, %d scene.",
            stats.total,
            stats.hops,
            stats.singleton,
            stats.scene
        ))
    end

    ui.section("Results", function()
        local rows = live_rows()
        local shown = filtered_results(rows)
        ui.label(string.format("Results %d / %d", #shown, #rows))
        local rtyped, rtext = ui.input_text("live_results_filter", state.results_filter, {
            label = "Filter results",
            placeholder = "narrow this list…",
        })
        if type(rtext) == "string" and (rtyped or rtext ~= "") then
            state.results_filter = rtext
            shown = filtered_results(rows)
        end
        local list_h = Widgets.remaining_height(56)
        state.selected = Widgets.draw_list("live_results", shown, opened_index(shown), function(i, row)
            state.selected = i
            pin_row(row)
            menu._logs_open = true
        end, list_h)
    end, true)

    if Core.can_back() then
        if imgui.button("Back##live_find_back", { 72, 26 }) then
            Core.back()
        end
        imgui.same_line()
    end
    if state.pinned_name ~= "" then
        ui.kv("Opened", state.pinned_name .. "  (" .. state.pinned_kind .. ")")
    else
        ui.muted("Click a result to open it — inspect and Chat both see that object.")
    end
end

function Finder.attach(menu)
    if menu:has_tab("Live") then
        return
    end
    menu:add_tab("Live", function(ui)
        require("liveview.ui.finder").draw(menu, ui)
    end)
end

return Finder
