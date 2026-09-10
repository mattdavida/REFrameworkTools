-- File-drop IPC for the Live View sidecar. Stock REF Lua has no HTTP.
-- Agent writes data/liveview_bridge/req.json; we write hb.json + res.json.
-- Getters + Finder drive + set_field on the opened object (same as inspect Set).
-- Opening a result does not switch the workspace tab.

local Log = require("refshell.log")
local Core = require("liveview.core")
local Cache = require("liveview.cache")
local Tdb = require("liveview.tdb")

local Bridge = {}

local SOURCE = Core.SOURCE
local REQ = "liveview_bridge/req.json"
local RES = "liveview_bridge/res.json"
local HB = "liveview_bridge/hb.json"
local CHAT_REQ = "liveview_bridge/chat_req.json"
local CHAT_OUT = "liveview_bridge/chat_out.json"
local SIDECAR = "liveview_bridge/sidecar.json"

local ROW_CAP = 40
local FIELD_CAP = 80
local METHOD_CAP = 80
local HB_EVERY = 30
local STALE_S = 3

local frame = 0
local last_id = ""
local ready_logged = false
local hb_written_at = 0

local function json_ok()
    return type(json) == "table" and type(json.load_file) == "function" and type(json.dump_file) == "function"
end

local function public_row(row)
    if type(row) ~= "table" then
        return nil
    end
    return {
        path = tostring(row.path or row.name or ""),
        name = tostring(row.name or ""),
        type = tostring(row.type or ""),
        kind = tostring(row.kind or ""),
        label = tostring(row.label or row.name or ""),
    }
end

local function write_json(path, payload)
    if not json_ok() then
        return false
    end
    local ok = false
    pcall(function()
        ok = json.dump_file(path, payload, 0) == true
    end)
    return ok
end

local function cache_stats()
    local stats = Cache.stats()
    return {
        total = stats.total or 0,
        scene = stats.scene or 0,
        singleton = stats.singleton or 0,
        hops = stats.hops or 0,
    }
end

local function results_hit(row, needle)
    if needle == "" then
        return true
    end
    local hay = table.concat({
        tostring(row.path or ""),
        tostring(row.name or ""),
        tostring(row.kind or ""),
        tostring(row.type or ""),
        tostring(row.label or ""),
    }, " ")
    return Core.contains_all(hay, needle)
end

local function finder_shown(cap)
    cap = cap or ROW_CAP
    local needle = Core.trim(Core.state.filter)
    local narrow = Core.trim(Core.state.results_filter)
    local rows = Cache.filter(needle, cap)
    if narrow == "" then
        return rows, needle, narrow
    end
    local shown = {}
    for i = 1, #rows do
        if results_hit(rows[i], narrow) then
            shown[#shown + 1] = rows[i]
            if #shown >= cap then
                break
            end
        end
    end
    return shown, needle, narrow
end

local function opened_info()
    local st = Core.state
    local name = tostring(st.pinned_name or "")
    if name == "" and not Core.is_managed(st.pinned) then
        return nil
    end
    return {
        path = name,
        type = tostring(Core.type_name_of(st.pinned) or ""),
        kind = tostring(st.pinned_kind or ""),
        live = Core.is_managed(st.pinned) == true,
    }
end

local function session_snapshot()
    local shown, needle, narrow = finder_shown(16)
    local results = {}
    for i = 1, #shown do
        local row = public_row(shown[i])
        if row then
            results[#results + 1] = row
        end
    end
    local selected = nil
    local idx = tonumber(Core.state.selected) or 0
    if idx > 0 and idx <= #results then
        selected = results[idx]
    end
    return {
        filter = needle,
        results_filter = narrow,
        list_mode = "live",
        stats = cache_stats(),
        opened = opened_info(),
        selected = selected,
        results = results,
    }
end

local function write_hb()
    local opened = opened_info()
    local ok = write_json(HB, {
        ok = true,
        ts = os.time(),
        plugin = Core.plugin_ok(),
        stats = cache_stats(),
        filter = Core.trim(Core.state.filter),
        pinned = opened and opened.path or "",
        pinned_type = opened and opened.type or "",
        opened = opened,
    })
    if ok then
        hb_written_at = os.time()
        if not ready_logged then
            ready_logged = true
            Log.info(SOURCE, "agent bridge ready — data/liveview_bridge")
        end
    end
    return ok
end

local function op_cache_search(req)
    local needle = Core.trim(req.needle)
    local cap = tonumber(req.cap) or ROW_CAP
    if cap < 1 then
        cap = 1
    end
    if cap > 80 then
        cap = 80
    end
    local rows = Cache.filter(needle, cap)
    local out = {}
    for i = 1, #rows do
        local row = public_row(rows[i])
        if row then
            out[#out + 1] = row
        end
    end
    return {
        ok = true,
        op = "cache_search",
        needle = needle,
        stats = cache_stats(),
        count = #out,
        rows = out,
    }
end

local function op_search_types(req)
    local needle = Core.trim(req.needle)
    if needle == "" then
        return { ok = false, op = "search_types", error = "search_types needs a filter" }
    end
    if not Core.plugin_ok() then
        return { ok = false, op = "search_types", error = "ref_live.dll not loaded" }
    end
    local cap = tonumber(req.cap) or ROW_CAP
    if cap < 1 then
        cap = 1
    end
    if cap > 80 then
        cap = 80
    end
    local rows = {}
    local ok, result = pcall(function()
        return reflive.search_types(needle, cap)
    end)
    if not ok then
        return { ok = false, op = "search_types", error = tostring(result) }
    end
    if type(result) == "table" then
        local n = #result
        if n > cap then
            n = cap
        end
        for i = 1, n do
            local row = public_row(result[i])
            if row then
                rows[#rows + 1] = row
            end
        end
    end
    return {
        ok = true,
        op = "search_types",
        needle = needle,
        count = #rows,
        rows = rows,
    }
end

local function op_inspect_pinned()
    if not Core.is_managed(Core.state.pinned) then
        return { ok = false, op = "inspect_pinned", error = "nothing opened — click a Finder result or call open_object" }
    end
    if #(Core.state.fields or {}) == 0 then
        Tdb.refresh_members()
    end
    local fields = {}
    local src = Core.state.fields or {}
    local nfields = #src
    if nfields > FIELD_CAP then
        nfields = FIELD_CAP
    end
    for i = 1, nfields do
        local row = src[i]
        if row and row.name then
            local live = nil
            local readable = false
            pcall(function()
                live = Core.state.pinned:get_field(row.name)
                readable = true
            end)
            fields[#fields + 1] = {
                name = tostring(row.name),
                type = tostring(row.type_name or ""),
                kind = tostring(row.kind or ""),
                value = readable and Tdb.format_value(live) or "?",
            }
        end
    end
    local methods = {}
    local msrc = Core.state.methods or {}
    local nmethods = #msrc
    if nmethods > METHOD_CAP then
        nmethods = METHOD_CAP
    end
    for i = 1, nmethods do
        local row = msrc[i]
        if row then
            methods[#methods + 1] = {
                name = tostring(row.name or ""),
                label = tostring(row.label or row.name or ""),
            }
        end
    end
    return {
        ok = true,
        op = "inspect_pinned",
        name = tostring(Core.state.pinned_name or ""),
        type = tostring(Core.type_name_of(Core.state.pinned) or ""),
        field_count = #(Core.state.fields or {}),
        method_count = #(Core.state.methods or {}),
        fields = fields,
        methods = methods,
    }
end

local function pick_row(rows, needle)
    needle = Core.trim(needle):lower()
    if #rows == 0 then
        return nil
    end
    local best = rows[1]
    for i = 1, #rows do
        local row = rows[i]
        local tn = tostring(row.type or ""):lower()
        local name = tostring(row.name or ""):lower()
        local path = tostring(row.path or ""):lower()
        if tn == needle or name == needle or path == needle then
            return row
        end
        if tn:sub(-#needle) == needle or path:sub(-#needle) == needle then
            best = row
        end
    end
    return best
end

local function op_set_finder(req)
    local needle = Core.trim(req.needle)
    Core.state.filter = needle
    if req.results_filter ~= nil then
        Core.state.results_filter = Core.trim(req.results_filter)
    end
    Core.state.selected = 0
    local search = op_cache_search({ needle = needle, cap = req.cap })
    search.op = "set_finder"
    search.session = session_snapshot()
    return search
end

local function op_open_object(req)
    local needle = Core.trim(req.needle)
    if needle == "" then
        return { ok = false, op = "open_object", error = "open_object needs a type, path, or name" }
    end
    Core.state.filter = needle
    local rows = Cache.filter(needle, 40)
    if #rows == 0 then
        Cache.boost_hops()
        rows = Cache.filter(needle, 40)
    end
    local row = pick_row(rows, needle)
    if not row then
        return {
            ok = false,
            op = "open_object",
            error = "no cache row matched " .. needle,
            session = session_snapshot(),
        }
    end
    local ok = Core.open_row(row)
    if not ok then
        return {
            ok = false,
            op = "open_object",
            error = "could not open " .. tostring(row.path or row.name or needle),
            row = public_row(row),
            session = session_snapshot(),
        }
    end
    for i = 1, #rows do
        if rows[i] == row then
            Core.state.selected = i
            break
        end
    end
    local inspect = op_inspect_pinned()
    inspect.op = "open_object"
    inspect.ok = true
    inspect.row = public_row(row)
    inspect.session = session_snapshot()
    return inspect
end

local function op_ui_state()
    return { ok = true, op = "ui_state", session = session_snapshot() }
end

local function field_row(name)
    local src = Core.state.fields or {}
    for i = 1, #src do
        local row = src[i]
        if row and row.name == name then
            return row
        end
    end
    return nil
end

local function coerce_write(raw)
    local t = type(raw)
    if t == "boolean" or t == "number" then
        return raw
    end
    return Tdb.coerce_value(tostring(raw or ""))
end

local function op_set_opened_field(req)
    local name = Core.trim(req.name)
    if name == "" then
        return { ok = false, op = "set_opened_field", error = "set_opened_field needs a field name" }
    end
    if not Core.is_managed(Core.state.pinned) then
        return { ok = false, op = "set_opened_field", error = "nothing opened — open_object first" }
    end
    if #(Core.state.fields or {}) == 0 then
        Tdb.refresh_members()
    end
    local meta = field_row(name)
    if not meta then
        return {
            ok = false,
            op = "set_opened_field",
            error = "no field " .. name .. " on " .. tostring(Core.state.pinned_name or "?"),
        }
    end
    local before = nil
    local readable = false
    pcall(function()
        before = Core.state.pinned:get_field(name)
        readable = true
    end)
    if readable and not Tdb.value_editable(meta.kind, before) then
        return {
            ok = false,
            op = "set_opened_field",
            name = name,
            error = "field is not a bool/number/string — Live View Set would refuse it too",
            kind = meta.kind,
            before = Tdb.format_value(before),
        }
    end
    local value = coerce_write(req.value)
    if not Tdb.value_editable(meta.kind, value) then
        return { ok = false, op = "set_opened_field", name = name, error = "value is not bool/number/string" }
    end
    local ok, err = pcall(function()
        Core.state.pinned:set_field(name, value)
    end)
    if not ok then
        return { ok = false, op = "set_opened_field", name = name, error = tostring(err) }
    end
    local after = nil
    pcall(function()
        after = Core.state.pinned:get_field(name)
    end)
    local shown = Tdb.format_value(after)
    local slot = Core.state.field_edits[name]
    if type(slot) == "table" then
        slot.text = shown
        slot.dirty = false
        slot.last_live = shown
    end
    Log.found(SOURCE, string.format("agent set %s = %s", name, shown))
    return {
        ok = true,
        op = "set_opened_field",
        name = name,
        before = readable and Tdb.format_value(before) or "?",
        after = shown,
        opened = opened_info(),
    }
end

local function dispatch(req)
    local op = tostring(req.op or "")
    if op == "cache_stats" then
        return { ok = true, op = op, stats = cache_stats() }
    end
    if op == "cache_search" then
        return op_cache_search(req)
    end
    if op == "search_types" then
        return op_search_types(req)
    end
    if op == "inspect_pinned" then
        return op_inspect_pinned()
    end
    if op == "ui_state" then
        return op_ui_state()
    end
    if op == "set_finder" then
        return op_set_finder(req)
    end
    if op == "open_object" then
        return op_open_object(req)
    end
    if op == "set_opened_field" then
        return op_set_opened_field(req)
    end
    return { ok = false, op = op, error = "unknown op" }
end

local function handle_req()
    if not json_ok() then
        return
    end
    local req = nil
    pcall(function()
        req = json.load_file(REQ)
    end)
    if type(req) ~= "table" then
        return
    end
    local id = tostring(req.id or "")
    if id == "" or id == last_id then
        return
    end
    last_id = id
    local res = dispatch(req)
    res.id = id
    write_json(RES, res)
    local extra = ""
    if res.count ~= nil then
        extra = " — " .. tostring(res.count) .. " rows"
    elseif res.error then
        extra = " — " .. tostring(res.error)
    end
    Log.info(SOURCE, "agent " .. tostring(res.op or req.op or "?") .. extra)
end

local function read_json(path)
    if not json_ok() then
        return nil
    end
    local data = nil
    pcall(function()
        data = json.load_file(path)
    end)
    if type(data) == "table" then
        return data
    end
    return nil
end

function Bridge.send_chat(id, messages)
    if id == nil or id == "" or type(messages) ~= "table" then
        return false
    end
    return write_json(CHAT_REQ, {
        id = tostring(id),
        messages = messages,
        session = session_snapshot(),
    })
end

function Bridge.read_chat_out()
    return read_json(CHAT_OUT)
end

function Bridge.read_sidecar()
    return read_json(SIDECAR)
end

function Bridge.nudge()
    return write_hb()
end

function Bridge.hb_ok()
    if hb_written_at <= 0 then
        return false
    end
    local age = os.time() - hb_written_at
    if age < 0 then
        age = 0
    end
    return age <= STALE_S
end

function Bridge.sidecar_state()
    local side = Bridge.read_sidecar()
    if type(side) ~= "table" then
        return "waiting", false
    end
    local ts = tonumber(side.ts)
    if not ts then
        return "waiting", false
    end
    local age = os.time() - ts
    if age < 0 then
        age = 0
    end
    if age <= STALE_S then
        return "connected", side.busy == true
    end
    return "stale", false
end

-- Tools need both pulses. live = game hb + sidecar.
function Bridge.link_state()
    local side, busy = Bridge.sidecar_state()
    if Bridge.hb_ok() and side == "connected" then
        return "live", busy
    end
    if side == "waiting" then
        return "waiting", false
    end
    return "stale", false
end

function Bridge.tick()
    frame = frame + 1
    if frame == 1 or frame % HB_EVERY == 0 then
        write_hb()
    end
    local ok, err = pcall(handle_req)
    if not ok then
        Log.error(SOURCE, "agent bridge — " .. tostring(err))
    end
end

return Bridge
