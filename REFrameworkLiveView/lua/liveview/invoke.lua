-- Method invoke + object-arg candidate fill. No ImGui.

local Log = require("refshell.log")
local Core = require("liveview.core")
local Tdb = require("liveview.tdb")

local Invoke = {}

local SOURCE = Core.SOURCE
local state = Core.state

local BROAD_OBJECT = {
    ["System.Object"] = true,
    ["via.Object"] = true,
    ["System.ValueType"] = true,
}

local function collect_from_pinned(type_full, add)
    if not Core.is_managed(state.pinned) then
        return
    end
    if Core.object_is_a(state.pinned, type_full) then
        add(state.pinned, "Pinned")
    end
    for i = 1, #state.fields do
        local fname = state.fields[i].name
        local value = nil
        pcall(function()
            value = state.pinned:get_field(fname)
        end)
        Core.foreach_managed(value, function(obj)
            if Core.object_is_a(obj, type_full) then
                add(obj, fname)
            end
        end, 0)
    end
end

local function scan_scene_typed(type_full, add)
    if BROAD_OBJECT[type_full] then
        return 0
    end
    local scene = Core.current_scene()
    if not scene then
        return 0
    end
    local rtt = nil
    pcall(function()
        rtt = sdk.typeof(type_full)
    end)
    local t = nil
    pcall(function()
        t = scene:call("get_FirstTransform")
    end)
    local found = 0
    while t do
        local go = nil
        pcall(function()
            go = t:call("get_GameObject")
        end)
        if Core.is_managed(go) then
            if Core.object_is_a(go, type_full) then
                add(go, "Scene")
                found = found + 1
            end
            if rtt then
                local comp = nil
                pcall(function()
                    comp = go:call("getComponent(System.Type)", rtt)
                end)
                if Core.is_managed(comp) and Core.object_is_a(comp, type_full) then
                    add(comp, "Scene")
                    found = found + 1
                end
            end
        end
        local nxt = nil
        pcall(function()
            nxt = t:call("get_Next")
        end)
        t = nxt
    end
    return found
end

function Invoke.refresh_object_candidates(slot, include_scene)
    local type_full = slot.type_full
    local seen = {}
    local candidates = {
        { object = nil, label = "(nil)" },
    }
    local function add(obj, hint)
        if obj == nil then
            return
        end
        local key = Core.object_key(obj)
        if seen[key] then
            return
        end
        seen[key] = true
        Core.remember_object(obj, hint)
        candidates[#candidates + 1] = {
            object = obj,
            label = Core.object_caption(obj, hint),
        }
    end
    collect_from_pinned(type_full, add)
    local singleton = nil
    pcall(function()
        singleton = sdk.get_managed_singleton(type_full)
    end)
    if Core.is_managed(singleton) then
        add(singleton, "Singleton")
    end
    for _, row in pairs(state.known_objects) do
        if row.object and Core.object_is_a(row.object, type_full) then
            add(row.object, "Known")
        end
    end
    if include_scene then
        local n = scan_scene_typed(type_full, add)
        Log.info(SOURCE, string.format("live %s scene hits %d  total %d", tostring(type_full), n, #candidates - 1))
    end
    local prev = nil
    if slot.candidates and slot.selected and slot.candidates[slot.selected] then
        prev = slot.candidates[slot.selected].object
    end
    slot.candidates = candidates
    slot.selected = 1
    if prev ~= nil then
        for i = 1, #candidates do
            if candidates[i].object == prev then
                slot.selected = i
                break
            end
        end
    end
end

local function parse_arg(token)
    token = Core.trim(token)
    if token == "" then
        return nil
    end
    if token == "true" then
        return true
    end
    if token == "false" then
        return false
    end
    if token == "nil" then
        return nil
    end
    local q = token:match("^['\"](.*)['\"]$")
    if q then
        return q
    end
    local n = tonumber(token)
    if n ~= nil then
        return n
    end
    return token
end

function Invoke.parse_args(text)
    text = Core.trim(text)
    if text == "" then
        return {}
    end
    local args = {}
    for part in (text .. ","):gmatch("(.-),") do
        args[#args + 1] = parse_arg(part)
    end
    return args
end

local function resolve_slot(slot)
    if not slot then
        return nil
    end
    if slot.kind == "bool" then
        return slot.bool_value and true or false
    end
    if slot.kind == "enum" then
        local item = slot.enum_items and slot.enum_items[slot.selected]
        if item then
            return item.value
        end
        return nil
    end
    if slot.kind == "object" then
        local cand = slot.candidates and slot.candidates[slot.selected]
        if cand then
            return cand.object
        end
        return nil
    end
    if slot.kind == "number" or slot.kind == "string" or slot.kind == "valuetype" then
        return Tdb.coerce_value(slot.text)
    end
    return parse_arg(slot.text)
end

function Invoke.rebind_object_slots()
    for i = 1, #(state.call_slots or {}) do
        local slot = state.call_slots[i]
        if slot and slot.kind == "object" then
            Invoke.refresh_object_candidates(slot, false)
        end
    end
end

local function guess_enum_index(slot)
    local type_full = slot.type_full
    if type(type_full) ~= "string" or type_full == "" then
        return 0
    end
    if not Core.is_managed(state.pinned) then
        return 0
    end
    local found = nil
    local hits = 0
    for i = 1, #state.fields do
        local f = state.fields[i]
        if f.type_full == type_full then
            local live = nil
            pcall(function()
                live = state.pinned:get_field(f.name)
            end)
            local n = Tdb.enum_numeric(live)
            if type(n) == "number" then
                hits = hits + 1
                found = n
            end
        end
    end
    if hits ~= 1 or found == nil then
        return 0
    end
    for i = 1, #slot.enum_items do
        if slot.enum_items[i].value == found then
            return i
        end
    end
    return 0
end

function Invoke.select_method(row)
    local key = row.label or row.name
    if state.method_picked == key and type(state.call_slots) == "table" and #state.call_slots > 0 then
        Invoke.rebind_object_slots()
        return
    end
    state.method_name = row.name
    state.method_picked = key
    state.method_sig = row.label or ""
    state.method_args_hint = row.params
    state.method_args = ""
    state.call_slots = {}
    state.last_call = nil
    state.call_items_filter = ""
    for i = 1, #(row.args or {}) do
        local p = row.args[i]
        local slot = {
            kind = p.kind,
            type_name = p.type_name,
            type_full = p.type_full,
            param_name = p.name,
            selected = 0,
            text = "",
            bool_value = false,
            dropdown = { open = false, filter = "" },
            candidates = {},
            enum_items = {},
        }
        if p.kind == "enum" then
            slot.enum_items = Tdb.enum_members(p.type_full)
            if #slot.enum_items == 0 then
                slot.kind = "number"
            else
                slot.selected = guess_enum_index(slot)
            end
        elseif p.kind == "object" then
            Invoke.refresh_object_candidates(slot, false)
        end
        state.call_slots[i] = slot
    end
end

local function invoke_named(target, name, args)
    if #args == 0 then
        return target:call(name)
    end
    if #args == 1 then
        return target:call(name, args[1])
    end
    if #args == 2 then
        return target:call(name, args[1], args[2])
    end
    if #args == 3 then
        return target:call(name, args[1], args[2], args[3])
    end
    return target:call(name, args[1], args[2], args[3], args[4])
end

local function invoke_static(td, name, args)
    local method = nil
    pcall(function()
        method = td:get_method(name)
    end)
    if not method then
        error("no method " .. tostring(name))
    end
    if #args == 0 then
        return method:call(nil)
    end
    if #args == 1 then
        return method:call(nil, args[1])
    end
    if #args == 2 then
        return method:call(nil, args[1], args[2])
    end
    if #args == 3 then
        return method:call(nil, args[1], args[2], args[3])
    end
    return method:call(nil, args[1], args[2], args[3], args[4])
end

function Invoke.run_call()
    local name = Core.trim(state.method_name)
    if name == "" then
        Log.skipped_reason(SOURCE, "method name is empty")
        return
    end
    local args = {}
    if #state.call_slots > 0 then
        for i = 1, #state.call_slots do
            local slot = state.call_slots[i]
            if slot.kind == "enum" and (not slot.selected or slot.selected < 1) then
                Log.skipped_reason(SOURCE, "pick an enum for " .. tostring(slot.param_name or ("arg" .. i)))
                return
            end
            args[i] = resolve_slot(slot)
        end
    else
        args = Invoke.parse_args(state.method_args)
    end
    local ok, result
    if Core.is_managed(state.pinned) then
        ok, result = pcall(function()
            return invoke_named(state.pinned, name, args)
        end)
    elseif state.pinned_kind == "type" and state.pinned_td then
        ok, result = pcall(function()
            return invoke_static(state.pinned_td, name, args)
        end)
    else
        Log.skipped_reason(SOURCE, "nothing pinned")
        return
    end
    if ok then
        local managed = Core.note_result(result, name)
        local info = Core.collection_info(result)
        local text = managed and state.last_result.name or tostring(result)
        if result == nil then
            text = "nil"
        elseif info.collection then
            text = string.format("%s  (%d items)", text, info.total)
        end
        state.last_call = {
            ok = true,
            via = name,
            text = text,
            object = result,
            can_go = managed or info.collection,
            is_collection = info.collection,
            items = nil,
            item_n = info.collection and info.total or 0,
        }
        if info.collection then
            Log.found(SOURCE, string.format("call %s -> %s", name, text))
        elseif managed then
            Log.found(SOURCE, string.format("call %s -> %s  (Go to object)", name, text))
        else
            Log.found(SOURCE, string.format("call %s -> %s", name, text))
        end
    else
        state.last_call = {
            ok = false,
            via = name,
            text = tostring(result),
            object = nil,
        }
        Log.error(SOURCE, "call " .. name .. " failed — " .. tostring(result))
    end
end

return Invoke
