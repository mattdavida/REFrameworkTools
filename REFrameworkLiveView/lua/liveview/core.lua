-- Shared Live kernel: state, type helpers, pin, history, go-to.
-- Search and the Live UI require this. Do not draw ImGui here.

local Log = require("refshell.log")

local Core = {}

Core.SOURCE = "Live"

Core.state = {
    filter = "",
    results_filter = "",
    results = {},
    selected = 0,
    pinned = nil,
    pinned_td = nil,
    pinned_name = "",
    pinned_kind = "",
    method_filter = "",
    method_name = "",
    method_sig = "",
    method_args = "",
    method_args_hint = nil,
    field_filter = "",
    field_name = "",
    field_value = "",
    methods = {},
    fields = {},
    field_edits = {},
    inspector_tab = 1,
    call_slots = {},
    method_picked = "",
    known_objects = {},
    history = {},
    last_result = nil,
    last_call = nil,
    call_items_filter = "",
    ws_tab = 2,
    find_fn_open = false,
    show_types = false,
}

local state = Core.state
local SOURCE = Core.SOURCE
local refresh_members_fn = nil

function Core.on_refresh(fn)
    refresh_members_fn = fn
end

function Core.trim(s)
    if s == nil then
        return ""
    end
    return tostring(s):match("^%s*(.-)%s*$") or ""
end

function Core.contains(haystack, needle)
    if needle == nil or needle == "" then
        return true
    end
    if haystack == nil then
        return false
    end
    return tostring(haystack):lower():find(tostring(needle):lower(), 1, true) ~= nil
end

function Core.split_needles(filter)
    local terms = {}
    if filter == nil or filter == "" then
        return terms
    end
    for part in tostring(filter):gmatch("[^,]+") do
        local term = part:match("^%s*(.-)%s*$")
        if term ~= nil and term ~= "" then
            terms[#terms + 1] = term
        end
    end
    return terms
end

function Core.contains_all(haystack, filter)
    local terms = Core.split_needles(filter)
    if #terms == 0 then
        return true
    end
    if haystack == nil then
        return false
    end
    local text = tostring(haystack)
    for i = 1, #terms do
        local term = terms[i]
        if string.sub(term, 1, 1) == "!" then
            local neg = Core.trim(string.sub(term, 2))
            if neg ~= "" and Core.contains(text, neg) then
                return false
            end
        elseif not Core.contains(text, term) then
            return false
        end
    end
    return true
end

function Core.plugin_ok()
    return type(reflive) == "table" and type(reflive.search_types) == "function"
end

function Core.is_managed(obj)
    if obj == nil or type(obj) ~= "userdata" then
        return false
    end
    local ok, valid = pcall(function()
        return obj.get_type_definition and obj:get_type_definition() ~= nil
    end)
    return ok and valid
end

function Core.type_name_of(obj)
    if not Core.is_managed(obj) then
        return nil
    end
    local ok, name = pcall(function()
        return obj:get_type_definition():get_full_name()
    end)
    if ok then
        return name
    end
    return nil
end

function Core.collect_list(getter)
    local ok, list = pcall(getter)
    if not ok or list == nil then
        return {}
    end
    if type(list) == "table" then
        return list
    end
    local out = {}
    local n = 0
    pcall(function()
        n = #list
    end)
    if n > 0 then
        for i = 1, n do
            out[i] = list[i]
        end
    end
    return out
end

local member_cache = {}

local function td_of(obj)
    local td = nil
    pcall(function()
        td = obj:get_type_definition()
    end)
    return td
end

--- TDB field + method names for a live object, cached per type. No invokes.
function Core.member_index(obj)
    local empty = { hay = "", names = {} }
    if not Core.is_managed(obj) then
        return empty
    end
    local td = td_of(obj)
    local key = Core.type_full_td(td)
    if type(key) ~= "string" or key == "" then
        return empty
    end
    if member_cache[key] then
        return member_cache[key]
    end
    local names = {}
    local fields = Core.collect_list(function()
        return td:get_fields()
    end)
    for i = 1, #fields do
        local name = nil
        pcall(function()
            name = fields[i]:get_name()
        end)
        if type(name) == "string" and name ~= "" then
            names[#names + 1] = name
        end
    end
    local methods = Core.collect_list(function()
        return td:get_methods()
    end)
    for i = 1, #methods do
        local name = nil
        pcall(function()
            name = methods[i]:get_name()
        end)
        if type(name) == "string" and name ~= "" then
            names[#names + 1] = name
        end
    end
    local index = {
        hay = key .. " " .. table.concat(names, " "),
        names = names,
    }
    member_cache[key] = index
    return index
end

function Core.first_member_match(index, filter)
    if type(index) ~= "table" or type(index.names) ~= "table" then
        return nil
    end
    for i = 1, #index.names do
        if Core.contains_all(index.names[i], filter) then
            return index.names[i]
        end
    end
    return nil
end

local SHORT_TYPE = {
    ["System.Void"] = "void",
    ["System.Boolean"] = "bool",
    ["System.Byte"] = "byte",
    ["System.SByte"] = "sbyte",
    ["System.Int16"] = "short",
    ["System.UInt16"] = "ushort",
    ["System.Int32"] = "int",
    ["System.UInt32"] = "uint",
    ["System.Int64"] = "long",
    ["System.UInt64"] = "ulong",
    ["System.Single"] = "float",
    ["System.Double"] = "double",
    ["System.String"] = "string",
    ["System.Object"] = "object",
    ["System.IntPtr"] = "nint",
}

function Core.type_full_td(td)
    if not td then
        return nil
    end
    local name = nil
    pcall(function()
        name = td:get_full_name()
    end)
    if type(name) ~= "string" or name == "" then
        pcall(function()
            name = td:get_name()
        end)
    end
    if type(name) ~= "string" or name == "" then
        return nil
    end
    return name
end

function Core.type_name_td(td)
    local name = Core.type_full_td(td)
    if not name then
        return "?"
    end
    return SHORT_TYPE[name] or name
end

function Core.object_key(obj)
    return tostring(obj)
end

function Core.object_caption(obj, hint)
    local tn = Core.type_name_of(obj) or "?"
    local name = nil
    pcall(function()
        name = obj:call("get_Name")
    end)
    if type(name) ~= "string" or name == "" then
        pcall(function()
            local go = obj:call("get_GameObject")
            if go then
                name = go:call("get_Name")
            end
        end)
    end
    if type(name) == "string" and name ~= "" then
        return string.format("%s  (%s)", name, tn)
    end
    if type(hint) == "string" and hint ~= "" then
        return string.format("%s  (%s)", hint, tn)
    end
    return tn
end

function Core.remember_object(obj, hint)
    if not Core.is_managed(obj) then
        return
    end
    local key = Core.object_key(obj)
    if state.known_objects[key] then
        return
    end
    local n = 0
    for _ in pairs(state.known_objects) do
        n = n + 1
    end
    if n >= 200 then
        return
    end
    state.known_objects[key] = {
        object = obj,
        label = Core.object_caption(obj, hint),
        type_name = Core.type_name_of(obj) or "?",
    }
end

function Core.object_is_a(obj, type_full)
    if not Core.is_managed(obj) or type(type_full) ~= "string" or type_full == "" then
        return false
    end
    local ok, yes = pcall(function()
        local td = obj:get_type_definition()
        return td ~= nil and td:is_a(type_full) == true
    end)
    return ok and yes
end

--- True when full is the needle type, not a nested type that merely contains it.
--- cPlayerContextParam matches app.cPlayerContextParam
--- and does not match app.cPlayerContextParam.cPlayerSkillTreeInfo
function Core.type_hits(full, needle)
    needle = Core.trim(needle)
    if needle == "" or full == nil or full == "" then
        return false
    end
    local f = tostring(full)
    local n = needle
    if f:lower() == n:lower() then
        return true
    end
    if f:lower():sub(-( #n + 1 )) == "." .. n:lower() then
        return true
    end
    return false
end

function Core.object_hits_type(obj, needle)
    if not Core.is_managed(obj) then
        return false
    end
    local tn = Core.type_name_of(obj)
    if Core.type_hits(tn, needle) then
        return true
    end
    if Core.object_is_a(obj, needle) then
        return true
    end
    if not needle:find(".", 1, true) then
        if Core.object_is_a(obj, "app." .. needle) then
            return true
        end
        if Core.object_is_a(obj, "snow." .. needle) then
            return true
        end
        if Core.object_is_a(obj, "snow.player." .. needle) then
            return true
        end
        if Core.object_is_a(obj, "snow.enemy." .. needle) then
            return true
        end
    end
    return false
end

local function read_count(value)
    local size = nil
    if type(value) == "userdata" and type(value.get_size) == "function" and type(value.get_element) == "function" then
        pcall(function()
            size = value:get_size()
        end)
        if type(size) == "number" then
            return size, "array"
        end
    end
    for i = 1, 4 do
        local name = ({ "get_Count", "get_Length", "get_size", "getSize" })[i]
        pcall(function()
            size = value:call(name)
        end)
        if type(size) == "number" then
            return size, "call"
        end
    end
    return nil, nil
end

local function read_index(value, index, kind)
    local item = nil
    if kind == "array" and type(value.get_element) == "function" then
        pcall(function()
            item = value:get_element(index)
        end)
        if item ~= nil then
            return item
        end
    end
    pcall(function()
        item = value:call("get_Item(System.Int32)", index)
    end)
    if item ~= nil then
        return item
    end
    pcall(function()
        item = value:call("get_Item", index)
    end)
    if item ~= nil then
        return item
    end
    pcall(function()
        item = value:call("get_element", index)
    end)
    if item ~= nil then
        return item
    end
    pcall(function()
        item = value[index]
    end)
    return item
end

local BASIC_KIND = {
    bool = "bool",
    byte = "number",
    sbyte = "number",
    short = "number",
    ushort = "number",
    int = "number",
    uint = "number",
    long = "number",
    ulong = "number",
    float = "number",
    double = "number",
    nint = "number",
    string = "string",
}

local function primitive_kind(value)
    local t = type(value)
    if t == "boolean" then
        return "bool"
    end
    if t == "number" then
        return "number"
    end
    if t == "string" then
        return "string"
    end
    if not Core.is_managed(value) then
        return nil
    end
    local td = nil
    pcall(function()
        td = value:get_type_definition()
    end)
    local full = Core.type_full_td(td)
    local short = full and SHORT_TYPE[full]
    if short and BASIC_KIND[short] then
        return BASIC_KIND[short]
    end
    local prim, is_enum = false, false
    pcall(function()
        prim = td:is_primitive() == true
    end)
    pcall(function()
        is_enum = td:is_enum() == true
    end)
    if is_enum then
        return "enum"
    end
    if prim then
        if full == "System.Boolean" then
            return "bool"
        end
        return "number"
    end
    return nil
end

local function unbox_text(value, kind)
    if value == nil then
        return "nil"
    end
    local t = type(value)
    if t == "boolean" then
        if value then
            return "true"
        end
        return "false"
    end
    if t == "number" or t == "string" then
        return tostring(value)
    end
    local raw = nil
    pcall(function()
        raw = value:get_field("m_value")
    end)
    if raw == nil then
        pcall(function()
            raw = value:call("get_Value")
        end)
    end
    if kind == "bool" then
        if raw == true or raw == 1 then
            return "true"
        end
        if raw == false or raw == 0 then
            return "false"
        end
        local s = tostring(raw ~= nil and raw or value):lower()
        if s == "true" or s == "1" then
            return "true"
        end
        if s == "false" or s == "0" then
            return "false"
        end
    end
    if raw ~= nil and type(raw) ~= "userdata" then
        return tostring(raw)
    end
    local n = tonumber(tostring(raw ~= nil and raw or value))
    if n ~= nil then
        return tostring(n)
    end
    if kind == "string" then
        local s = nil
        pcall(function()
            s = value:call("ToString")
        end)
        if type(s) == "string" then
            return s
        end
    end
    return tostring(value)
end

local function item_text(elem)
    if elem == nil then
        return "nil"
    end
    local kind = primitive_kind(elem)
    if kind then
        return unbox_text(elem, kind)
    end
    if Core.is_managed(elem) then
        return Core.object_caption(elem)
    end
    local t = type(elem)
    if t == "boolean" then
        if elem then
            return "true"
        end
        return "false"
    end
    return tostring(elem)
end

--- Count only. Does not walk elements — use before expanding an accordion.
function Core.collection_info(value)
    local out = { collection = false, total = 0 }
    if value == nil then
        return out
    end
    local size = read_count(value)
    if type(size) ~= "number" or size < 0 or size >= 20000 then
        return out
    end
    out.collection = true
    out.total = size
    return out
end

--- Unpack a List / array / SystemArray into rows.
--- cap nil/0 = every item (still rejected at 20000).
function Core.unpack_items(value, cap)
    if type(cap) ~= "number" or cap <= 0 then
        cap = 20000
    end
    local out = { items = {}, total = 0, collection = false }
    if value == nil then
        return out
    end

    local function add(elem, index)
        local kind = primitive_kind(elem)
        local goable = kind == nil and Core.is_managed(elem)
        if goable then
            Core.remember_object(elem, "[" .. tostring(index) .. "]")
        end
        out.items[#out.items + 1] = {
            index = index,
            value = elem,
            text = item_text(elem),
            object = goable and elem or nil,
        }
    end

    local elems = nil
    pcall(function()
        if value.get_elements then
            elems = value:get_elements()
        end
    end)
    if type(elems) == "table" and #elems > 0 then
        out.collection = true
        out.total = #elems
        local n = math.min(#elems, cap)
        for i = 1, n do
            add(elems[i], i - 1)
        end
        return out
    end

    local size, kind = read_count(value)
    if type(size) ~= "number" or size < 0 or size >= 20000 then
        return out
    end
    out.collection = true
    out.total = size
    local n = math.min(size, cap)
    for i = 0, n - 1 do
        add(read_index(value, i, kind), i)
    end
    return out
end

--- Walk list/array items. Prefer SystemArray bindings over TDB :call.
function Core.each_item(value, visit)
    if value == nil then
        return 0
    end
    local elems = nil
    pcall(function()
        if value.get_elements then
            elems = value:get_elements()
        end
    end)
    if type(elems) == "table" and #elems > 0 then
        for i = 1, #elems do
            visit(elems[i], i - 1)
        end
        return #elems
    end
    local size, kind = read_count(value)
    if type(size) ~= "number" or size <= 0 or size >= 512 then
        return 0
    end
    local n = 0
    for i = 0, size - 1 do
        visit(read_index(value, i, kind), i)
        n = n + 1
    end
    return n
end

function Core.find_type(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    local td = nil
    pcall(function()
        td = sdk.find_type_definition(name)
    end)
    return td
end

function Core.current_scene()
    local sm, smt, scene = nil, nil, nil
    pcall(function()
        sm = sdk.get_native_singleton("via.SceneManager")
        smt = sdk.find_type_definition("via.SceneManager")
        if sm and smt then
            scene = sdk.call_native_func(sm, smt, "get_CurrentScene")
        end
    end)
    return scene
end

function Core.foreach_managed(value, visit, depth)
    depth = depth or 0
    if depth > 2 or value == nil then
        return
    end
    if Core.is_managed(value) then
        visit(value)
        if depth >= 2 then
            return
        end
        local elems = nil
        pcall(function()
            if value.get_elements then
                elems = value:get_elements()
            end
        end)
        if type(elems) == "table" then
            for i = 1, #elems do
                Core.foreach_managed(elems[i], visit, depth + 1)
            end
            return
        end
        local n = nil
        pcall(function()
            n = value:get_size()
        end)
        if type(n) == "number" and n > 0 and n < 256 then
            for i = 0, n - 1 do
                local elem = nil
                pcall(function()
                    elem = value[i]
                end)
                Core.foreach_managed(elem, visit, depth + 1)
            end
        end
        return
    end
    if type(value) == "table" then
        for _, item in pairs(value) do
            Core.foreach_managed(item, visit, depth + 1)
        end
    end
end

local function current_type_full()
    return Core.type_full_td(state.pinned_td)
end

local function clear_editors(keep_call)
    state.field_name = ""
    state.field_value = ""
    state.field_edits = {}
    if keep_call then
        return
    end
    state.method_name = ""
    state.method_sig = ""
    state.method_args = ""
    state.method_args_hint = nil
    state.call_slots = {}
    state.method_picked = ""
    state.last_call = nil
end

function Core.push_history()
    if state.pinned == nil and state.pinned_td == nil then
        return
    end
    state.history[#state.history + 1] = {
        object = state.pinned,
        name = state.pinned_name,
        kind = state.pinned_kind,
        type_name = state.pinned_kind == "type" and state.pinned_name or nil,
    }
    if #state.history > 40 then
        table.remove(state.history, 1)
    end
end

function Core.can_back()
    return #state.history > 0
end

function Core.clear_history()
    state.history = {}
end

local function apply_refresh()
    if refresh_members_fn then
        refresh_members_fn()
    end
end

function Core.pin(obj, name, kind, opts)
    opts = opts or {}
    if not Core.is_managed(obj) then
        Log.not_found(SOURCE, "pin " .. tostring(name))
        return false
    end
    local next_kind = kind or "object"
    local next_td = nil
    pcall(function()
        next_td = obj:get_type_definition()
    end)
    local keep_call = state.pinned_kind == next_kind
        and current_type_full() ~= nil
        and current_type_full() == Core.type_full_td(next_td)
    if not opts.replace then
        Core.push_history()
    end
    clear_editors(keep_call)
    state.pinned = obj
    state.pinned_td = next_td
    state.pinned_name = name or (Core.type_name_of(obj) or "?")
    state.pinned_kind = next_kind
    Core.remember_object(obj, name)
    apply_refresh()
    if keep_call then
        require("liveview.invoke").rebind_object_slots()
    end
    Log.found(SOURCE, "pinned " .. state.pinned_name)
    Log.info(SOURCE, string.format("methods %d  fields %d", #state.methods, #state.fields))
    return true
end

function Core.inspect_type(type_name, opts)
    opts = opts or {}
    local td = Core.find_type(type_name)
    if not td then
        Log.not_found(SOURCE, tostring(type_name))
        return false
    end
    local keep_call = state.pinned_kind == "type"
        and current_type_full() ~= nil
        and current_type_full() == Core.type_full_td(td)
    if not opts.replace then
        Core.push_history()
    end
    clear_editors(keep_call)
    state.pinned = nil
    state.pinned_td = td
    state.pinned_name = type_name
    state.pinned_kind = "type"
    apply_refresh()
    Log.info(SOURCE, "inspect type " .. tostring(type_name) .. " — statics only until you Go to a live object")
    return true
end

function Core.go_to(obj, name, kind)
    return Core.pin(obj, name, kind or "object")
end

function Core.back()
    while #state.history > 0 do
        local prev = table.remove(state.history)
        if prev.object and Core.is_managed(prev.object) then
            return Core.pin(prev.object, prev.name, prev.kind, { replace = true })
        end
        if prev.kind == "type" and prev.type_name then
            return Core.inspect_type(prev.type_name, { replace = true })
        end
    end
    Log.skipped_reason(SOURCE, "nothing to go back to")
    return false
end

function Core.note_result(value, via)
    if not Core.is_managed(value) then
        state.last_result = nil
        return false
    end
    local name = Core.type_name_of(value) or Core.object_caption(value, via)
    state.last_result = {
        object = value,
        name = name,
        via = via or "call",
    }
    Core.remember_object(value, via)
    return true
end

function Core.resolve_live(row)
    if type(row) ~= "table" then
        return nil
    end
    if Core.is_managed(row.object) then
        return row.object
    end
    if row.kind == "native" then
        return nil
    end
    if row.kind == "managed" or row.kind == "singleton" or row.kind == "type" then
        local obj = nil
        pcall(function()
            obj = sdk.get_managed_singleton(row.name)
        end)
        if Core.is_managed(obj) then
            return obj
        end
        return nil
    end
    if row.address then
        local obj = nil
        pcall(function()
            obj = sdk.to_managed_object(row.address)
        end)
        if Core.is_managed(obj) then
            return obj
        end
    end
    return nil
end

function Core.decorate_row(row)
    if type(row) ~= "table" then
        return nil
    end
    local obj = Core.resolve_live(row)
    if obj then
        row.object = obj
        row.usable = true
        if row.kind == "type" then
            row.kind = "singleton"
        end
        if not row.label then
            row.label = tostring(row.name or Core.type_name_of(obj) or "?") .. "  (" .. tostring(row.kind or "live") .. ")"
        end
        return row
    end
    row.usable = false
    if not row.label then
        row.label = tostring(row.name or "?") .. "  (type)"
    end
    return row
end

function Core.set_results(rows, heading, keep_types, opts)
    opts = opts or {}
    local out = {}
    for i = 1, #(rows or {}) do
        local row = Core.decorate_row(rows[i])
        if row then
            if row.usable or keep_types then
                out[#out + 1] = row
            end
        end
    end
    state.results = out
    state.selected = 0
    if not opts.keep_filter then
        state.results_filter = ""
    end
    if not opts.quiet then
        if #out == 0 then
            Log.not_found(SOURCE, heading)
        else
            Log.found(SOURCE, string.format("%s — %d (list in Live)", heading, #out))
        end
        Log.done(SOURCE, #out)
    end
end

function Core.open_row(row)
    if type(row) ~= "table" then
        return false
    end
    local obj = row.object
    if not Core.is_managed(obj) then
        obj = Core.resolve_live(row)
    end
    Core.clear_history()
    if Core.is_managed(obj) then
        return Core.pin(obj, row.name, row.kind or "managed", { replace = true })
    end
    if row.name then
        return Core.inspect_type(row.name, { replace = true })
    end
    return false
end

return Core
