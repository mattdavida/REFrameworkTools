-- Background live-object cache. UE4SS uses GUObjectArray + bUseObjectArrayCache.
-- RE Engine has no object iterator in Lua, so we seed singletons, the known
-- player hops, the scene, and one field hop — spread across frames.

local Core = require("liveview.core")

local Cache = {}

local MAX = 3000
local SCENE_CAP = 900
local SHOW_EMPTY = 220
local SCENE_BUDGET = 70
local CRAWL_BUDGET = 18
local HOP_BUDGET = 12
local HOP_BOOST = 40

-- No-arg getters only. Onimusha / Wilds use app.PlayerManager + getControllingPlayer.
-- Rise uses snow.player.PlayerManager + findMasterPlayer / get_PlayerData.
local HOPS = {
    "getControllingPlayer",
    "getControllingPlayerInfo",
    "getMasterPlayer",
    "get_MasterPlayer",
    "findMasterPlayer",
    "get_CurrentPlayer",
    "get_manualPlayer",
    "get_Context",
    "get_ContextParam",
    "get_ContextHolder",
    "get_Player",
    "get_PlayerData",
    "get_Contexts",
    "get_Param",
    "get_Character",
    "get_Object",
    "get_GameObject",
    "get_RefAttack",
    "get_RefVital",
}

local PLAYER_SINGLETONS = {
    "snow.player.PlayerManager",
    "app.PlayerManager",
}

local PLAYER_READY = {
    "getControllingPlayer",
    "findMasterPlayer",
    "getMasterPlayer",
    "get_MasterPlayer",
    "get_CurrentPlayer",
    "get_manualPlayer",
}

local entries = {}
local by_key = {}
local crawl_q = {}
local hop_q = {}
local scene_t = nil
local scene_wraps = 0
local scene_key = nil
local had_player = false
local frame = 0
local gen = 0
local enabled = true
local kind_n = {
    scene = 0,
    singleton = 0,
    get = 0,
    field = 0,
    element = 0,
    cache = 0,
}

function Cache.clear()
    entries = {}
    by_key = {}
    crawl_q = {}
    hop_q = {}
    scene_t = nil
    scene_wraps = 0
    had_player = false
    kind_n = {
        scene = 0,
        singleton = 0,
        get = 0,
        field = 0,
        element = 0,
        cache = 0,
    }
    gen = gen + 1
end

local function kind_of(kind)
    if kind_n[kind] ~= nil then
        return kind
    end
    return "cache"
end

local function bump_kind(kind, delta)
    kind = kind_of(kind)
    kind_n[kind] = (kind_n[kind] or 0) + delta
    if kind_n[kind] < 0 then
        kind_n[kind] = 0
    end
end

local function evict_scene()
    for i = 1, #entries do
        local row = entries[i]
        if row.kind == "scene" then
            by_key[Core.object_key(row.object)] = nil
            table.remove(entries, i)
            bump_kind("scene", -1)
            gen = gen + 1
            return true
        end
    end
    return false
end

local function call_named(obj, name)
    local result = nil
    pcall(function()
        result = obj:call(name)
    end)
    return result
end

function Cache.size()
    return #entries
end

function Cache.gen()
    return gen
end

function Cache.stats()
    return {
        total = #entries,
        scene = kind_n.scene or 0,
        singleton = kind_n.singleton or 0,
        hops = (kind_n.get or 0) + (kind_n.field or 0) + (kind_n.element or 0),
    }
end

function Cache.add(obj, path, kind)
    if not Core.is_managed(obj) then
        return false
    end
    kind = kind_of(kind)
    if kind == "scene" and (kind_n.scene or 0) >= SCENE_CAP then
        return false
    end
    if #entries >= MAX then
        if kind == "scene" then
            return false
        end
        if not evict_scene() then
            return false
        end
    end
    local key = Core.object_key(obj)
    if by_key[key] then
        return false
    end
    local tn = Core.type_name_of(obj) or "?"
    local name = nil
    pcall(function()
        name = obj:call("get_Name")
    end)
    if type(name) ~= "string" or name == "" then
        name = tn
    end
    local members = Core.member_index(obj)
    local hay = tostring(path or "") .. " " .. tostring(name) .. " " .. tn .. " " .. members.hay
    local row = {
        object = obj,
        path = path or tn,
        name = name,
        type = tn,
        kind = kind or "cache",
        hay = hay,
        label = string.format("%s  [%s]", path or name, tn),
        usable = true,
    }
    entries[#entries + 1] = row
    by_key[key] = row
    bump_kind(kind, 1)
    crawl_q[#crawl_q + 1] = { obj = obj, path = row.path }
    hop_q[#hop_q + 1] = { obj = obj, path = row.path }
    gen = gen + 1
    Core.remember_object(obj, row.path)
    return true
end

local function try_singleton(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    local pm = nil
    pcall(function()
        pm = sdk.get_managed_singleton(name)
    end)
    if Core.is_managed(pm) then
        return pm
    end
    return nil
end

local function player_manager()
    for i = 1, #PLAYER_SINGLETONS do
        local name = PLAYER_SINGLETONS[i]
        local pm = try_singleton(name)
        if pm then
            return pm, name
        end
    end
    if sdk.game_namespace then
        local names = {}
        pcall(function()
            names[#names + 1] = sdk.game_namespace("player.PlayerManager")
            names[#names + 1] = sdk.game_namespace("PlayerManager")
        end)
        for i = 1, #names do
            local name = names[i]
            local pm = try_singleton(name)
            if pm then
                return pm, name
            end
        end
    end
    return nil
end

local function controlling_player(pm)
    if not Core.is_managed(pm) then
        return nil
    end
    for i = 1, #PLAYER_READY do
        local player = call_named(pm, PLAYER_READY[i])
        if Core.is_managed(player) then
            return player
        end
    end
    return nil
end

-- Add PlayerManager, and re-queue hops even when it is already cached.
-- Title screens seed PlayerManager before a player exists; hops run again when one appears.
local function seed_player()
    local pm, name = player_manager()
    if not pm then
        return nil
    end
    Cache.add(pm, name or "PlayerManager", "singleton")
    local row = by_key[Core.object_key(pm)]
    if row then
        hop_q[#hop_q + 1] = { obj = pm, path = row.path }
        crawl_q[#crawl_q + 1] = { obj = pm, path = row.path }
    end
    return pm
end

local function scene_identity()
    local scene = Core.current_scene()
    if scene == nil then
        return nil
    end
    local addr = nil
    pcall(function()
        addr = scene:get_address()
    end)
    if addr ~= nil and addr ~= 0 then
        return tostring(addr)
    end
    if Core.is_managed(scene) then
        return Core.object_key(scene)
    end
    return nil
end

-- Title / load screens fill the cache, then hops never retry. A new scene
-- (or the player appearing) is the rebuild Reset scripts was doing by hand.
local function rebuild_if_needed()
    local key = scene_identity()
    if key and key ~= scene_key then
        scene_key = key
        Cache.clear()
        seed_player()
        return true
    end
    local pm = player_manager()
    local ready = controlling_player(pm) ~= nil
    if ready and not had_player then
        had_player = true
        seed_player()
        return true
    end
    if not ready then
        had_player = false
    end
    return false
end

-- Same rebuild the overlay Reset was doing for search, without destroying Lua.
function Cache.enabled()
    return enabled
end

function Cache.set_enabled(want)
    want = want and true or false
    if enabled == want then
        return
    end
    enabled = want
    if want then
        Cache.rebuild()
    end
end

function Cache.rebuild()
    Cache.clear()
    seed_player()
end

local function seed_singletons()
    if type(reflive) ~= "table" or type(reflive.search_singletons) ~= "function" then
        return
    end
    local rows = nil
    pcall(function()
        rows = reflive.search_singletons("")
    end)
    if type(rows) ~= "table" then
        return
    end
    for i = 1, #rows do
        local row = rows[i]
        if row and row.kind ~= "native" then
            local obj = row.object
            if not Core.is_managed(obj) and row.address then
                pcall(function()
                    obj = sdk.to_managed_object(row.address)
                end)
            end
            if not Core.is_managed(obj) and row.name then
                pcall(function()
                    obj = sdk.get_managed_singleton(row.name)
                end)
            end
            if Core.is_managed(obj) then
                Cache.add(obj, row.name or Core.type_name_of(obj), "singleton")
            end
        end
    end
end

local function walk_scene(budget)
    if not scene_t then
        local scene = Core.current_scene()
        if not scene then
            return
        end
        pcall(function()
            scene_t = scene:call("get_FirstTransform")
        end)
        if not scene_t then
            return
        end
    end
    local n = 0
    while scene_t and n < budget do
        n = n + 1
        local go = nil
        pcall(function()
            go = scene_t:call("get_GameObject")
        end)
        if Core.is_managed(go) then
            local name = nil
            pcall(function()
                name = go:call("get_Name")
            end)
            Cache.add(go, tostring(name or "GameObject"), "scene")
        end
        local nxt = nil
        pcall(function()
            nxt = scene_t:call("get_Next")
        end)
        scene_t = nxt
    end
    if not scene_t then
        scene_wraps = scene_wraps + 1
    end
end

local function hop_one(item)
    if not item or not Core.is_managed(item.obj) then
        return
    end
    for i = 1, #HOPS do
        local name = HOPS[i]
        local result = call_named(item.obj, name)
        if Core.is_managed(result) then
            local path = item.path .. "." .. name .. "()"
            Cache.add(result, path, "get")
            Core.each_item(result, function(child, index)
                Cache.add(child, path .. "[" .. tostring(index) .. "]", "element")
            end)
        end
    end
end

local function crawl_one(item)
    if not item or not Core.is_managed(item.obj) then
        return
    end
    local td = nil
    pcall(function()
        td = item.obj:get_type_definition()
    end)
    if not td then
        return
    end
    local fields = Core.collect_list(function()
        return td:get_fields()
    end)
    local limit = math.min(#fields, 48)
    for i = 1, limit do
        local fname = nil
        pcall(function()
            fname = fields[i]:get_name()
        end)
        local value = nil
        pcall(function()
            value = item.obj:get_field(fname)
        end)
        local path = item.path .. "." .. tostring(fname)
        if Core.is_managed(value) then
            Cache.add(value, path, "field")
            Core.each_item(value, function(child, index)
                Cache.add(child, path .. "[" .. tostring(index) .. "]", "element")
            end)
        end
    end
end

local function drain_hops(budget)
    local hops = 0
    while hops < budget and #hop_q > 0 do
        hop_one(table.remove(hop_q, 1))
        hops = hops + 1
    end
    local crawls = 0
    local crawl_budget = math.min(CRAWL_BUDGET, budget)
    while crawls < crawl_budget and #crawl_q > 0 do
        crawl_one(table.remove(crawl_q, 1))
        crawls = crawls + 1
    end
end

function Cache.boost_hops()
    seed_player()
    drain_hops(HOP_BOOST)
end

function Cache.tick()
    if not enabled then
        return
    end
    frame = frame + 1
    rebuild_if_needed()
    if frame == 1 or frame % 45 == 0 then
        seed_player()
    end
    if frame == 2 or frame % 180 == 0 then
        seed_singletons()
    end
    -- Player hops before scene so context instances are not crowded out.
    drain_hops(HOP_BUDGET)
    if scene_t or frame % 90 == 3 then
        walk_scene(SCENE_BUDGET)
    end
end

local function row_hits(row, needle)
    if needle == "" then
        return true
    end
    local hay = table.concat({
        tostring(row.hay or ""),
        tostring(row.path or ""),
        tostring(row.name or ""),
        tostring(row.type or ""),
        tostring(row.label or ""),
    }, " ")
    if Core.contains_all(hay, needle) then
        return true
    end
    return Core.type_hits(row.type, needle)
end

function Cache.filter(needle, cap)
    needle = Core.trim(needle)
    cap = cap or (needle == "" and SHOW_EMPTY or 400)
    local rows = {}
    for i = 1, #entries do
        local row = entries[i]
        if row and row_hits(row, needle) then
            rows[#rows + 1] = row
            if #rows >= cap then
                break
            end
        end
    end
    return rows
end

return Cache
