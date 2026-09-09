-- TDB member metadata: method/field labels, param kinds, enums, live refresh.
-- No ImGui. Inspect and Call require this.

local Core = require("liveview.core")

local Tdb = {}

local state = Core.state

local NUMBER_TYPES = {
    byte = true,
    sbyte = true,
    short = true,
    ushort = true,
    int = true,
    uint = true,
    long = true,
    ulong = true,
    float = true,
    double = true,
    nint = true,
}

local enum_cache = {}

function Tdb.field_kind(type_name)
    if type_name == "bool" then
        return "bool"
    end
    if type_name == "string" then
        return "string"
    end
    if NUMBER_TYPES[type_name] then
        return "number"
    end
    return "other"
end

function Tdb.classify_param(td)
    local type_name = Core.type_name_td(td)
    local type_full = Core.type_full_td(td) or type_name
    if not td then
        return "other", type_name, type_full
    end
    local is_enum = false
    pcall(function()
        is_enum = td:is_enum() == true
    end)
    if is_enum then
        return "enum", type_name, type_full
    end
    if type_name == "bool" then
        return "bool", type_name, type_full
    end
    if type_name == "string" then
        return "string", type_name, type_full
    end
    if NUMBER_TYPES[type_name] then
        return "number", type_name, type_full
    end
    local is_prim, is_vt, is_arr = false, false, false
    pcall(function()
        is_prim = td:is_primitive() == true
    end)
    pcall(function()
        is_vt = td:is_value_type() == true
    end)
    pcall(function()
        is_arr = td:is_array() == true
    end)
    if is_arr then
        return "other", type_name, type_full
    end
    if is_prim or is_vt then
        return "valuetype", type_name, type_full
    end
    return "object", type_name, type_full
end

function Tdb.method_label(method)
    if not method then
        return { name = "?", label = "?", params = "" }
    end
    local name = "?"
    pcall(function()
        name = method:get_name()
    end)
    local prefix = ""
    pcall(function()
        if method:is_static() then
            prefix = "static "
        end
    end)
    local types = Core.collect_list(function()
        return method:get_param_types()
    end)
    local names = Core.collect_list(function()
        return method:get_param_names()
    end)
    local n = #types
    if n == 0 then
        pcall(function()
            n = method:get_num_params() or 0
        end)
    end
    if #names > n then
        n = #names
    end
    local parts = {}
    for i = 1, n do
        local tn = Core.type_name_td(types[i])
        local pn = names[i]
        if type(pn) == "string" and pn ~= "" then
            parts[#parts + 1] = tn .. " " .. pn
        else
            parts[#parts + 1] = tn
        end
    end
    local ret = "?"
    pcall(function()
        ret = Core.type_name_td(method:get_return_type())
    end)
    return {
        name = tostring(name),
        label = string.format("%s%s(%s) : %s", prefix, name, table.concat(parts, ", "), ret),
        params = table.concat(parts, ", "),
    }
end

function Tdb.method_args(method)
    local types = Core.collect_list(function()
        return method:get_param_types()
    end)
    local names = Core.collect_list(function()
        return method:get_param_names()
    end)
    local n = #types
    if n == 0 then
        pcall(function()
            n = method:get_num_params() or 0
        end)
    end
    if #names > n then
        n = #names
    end
    local args = {}
    for i = 1, n do
        local kind, type_name, type_full = Tdb.classify_param(types[i])
        local pn = names[i]
        if type(pn) ~= "string" or pn == "" then
            pn = "arg" .. tostring(i)
        end
        args[i] = {
            name = pn,
            kind = kind,
            type_name = type_name,
            type_full = type_full,
        }
    end
    return args
end

local function enum_is_sentinel(name)
    local upper = string.upper(tostring(name or ""))
    return upper == "INVALID" or upper == "NONE" or upper == "UNKNOWN"
end

local function enum_numeric(value)
    if type(value) == "number" then
        return value
    end
    if value == nil then
        return nil
    end
    local n = nil
    pcall(function()
        n = value:get_field("value__")
    end)
    if type(n) == "number" then
        return n
    end
    return nil
end

local function enum_field_value(field)
    local value = nil
    pcall(function()
        value = field:get_data(nil)
    end)
    if value == nil then
        pcall(function()
            value = field:get_data()
        end)
    end
    return enum_numeric(value)
end

local function enum_field_belongs(field, type_full)
    local fname = nil
    pcall(function()
        fname = field:get_name()
    end)
    if type(fname) ~= "string" or fname == "" or fname == "value__" then
        return false
    end
    local static, literal = false, false
    pcall(function()
        static = field:is_static() == true
    end)
    pcall(function()
        literal = field:is_literal() == true
    end)
    if not static and not literal then
        return false
    end
    local owner = nil
    pcall(function()
        owner = field:get_declaring_type()
    end)
    if owner then
        local owner_name = Core.type_full_td(owner)
        if owner_name and owner_name ~= type_full then
            return false
        end
    end
    return true
end

function Tdb.enum_members(type_full)
    if type(type_full) ~= "string" or type_full == "" then
        return {}
    end
    if enum_cache[type_full] then
        return enum_cache[type_full]
    end
    local td = nil
    pcall(function()
        td = sdk.find_type_definition(type_full)
    end)
    local members = {}
    if td then
        local fields = Core.collect_list(function()
            return td:get_fields()
        end)
        for i = 1, #fields do
            local field = fields[i]
            if enum_field_belongs(field, type_full) then
                local fname = field:get_name()
                local value = enum_field_value(field)
                if type(value) == "number" then
                    members[#members + 1] = {
                        name = fname,
                        value = value,
                        label = fname .. " = " .. tostring(value),
                    }
                end
            end
        end
        table.sort(members, function(a, b)
            local a_bad = enum_is_sentinel(a.name)
            local b_bad = enum_is_sentinel(b.name)
            if a_bad ~= b_bad then
                return not a_bad
            end
            return a.name < b.name
        end)
    end
    enum_cache[type_full] = members
    return members
end

Tdb.enum_numeric = enum_numeric

function Tdb.format_value(value)
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
    if t == "userdata" then
        local tn = Core.type_name_of(value)
        if tn then
            return tn
        end
    end
    return tostring(value)
end

function Tdb.value_editable(kind, value)
    if kind == "bool" or kind == "number" or kind == "string" then
        return true
    end
    local t = type(value)
    return t == "boolean" or t == "number" or t == "string"
end

function Tdb.field_label(field)
    if not field then
        return "?"
    end
    local name = "?"
    pcall(function()
        name = field:get_name()
    end)
    local tn = nil
    pcall(function()
        tn = Core.type_name_td(field:get_type())
    end)
    if tn and tn ~= "?" then
        return name .. " : " .. tn
    end
    return tostring(name)
end

function Tdb.coerce_value(text)
    text = Core.trim(text)
    if text == "true" then
        return true
    end
    if text == "false" then
        return false
    end
    local n = tonumber(text)
    if n ~= nil then
        return n
    end
    return text
end

function Tdb.refresh_members()
    state.methods = {}
    state.fields = {}
    local td = state.pinned_td
    if Core.is_managed(state.pinned) then
        pcall(function()
            td = state.pinned:get_type_definition()
        end)
        state.pinned_td = td
    end
    if not td then
        return
    end
    local methods = Core.collect_list(function()
        return td:get_methods()
    end)
    for i = 1, #methods do
        local row = Tdb.method_label(methods[i])
        row.args = Tdb.method_args(methods[i])
        state.methods[#state.methods + 1] = row
    end
    local fields = Core.collect_list(function()
        return td:get_fields()
    end)
    for i = 1, #fields do
        local fname = "?"
        pcall(function()
            fname = fields[i]:get_name()
        end)
        local ftd = nil
        pcall(function()
            ftd = fields[i]:get_type()
        end)
        local tn = Core.type_name_td(ftd)
        local type_full = Core.type_full_td(ftd) or tn
        local kind, _, _ = Tdb.classify_param(ftd)
        if kind == "other" then
            kind = Tdb.field_kind(tn)
        end
        state.fields[#state.fields + 1] = {
            label = Tdb.field_label(fields[i]),
            name = fname,
            type_name = tn,
            type_full = type_full,
            kind = kind,
        }
    end
end

return Tdb
