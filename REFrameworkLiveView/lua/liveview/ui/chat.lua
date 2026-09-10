-- DevTools Chat tab. File-drop to the sidecar — no HTTP / no key in the game.

local Core = require("liveview.core")
local Bridge = require("liveview.bridge")
local Widgets = require("liveview.ui.widgets")

local Chat = {}

local MUTED = 0xFFA0A3AD
local YOU = 0xFFE8D4FF
local LIVE = 0xFFE8E8EE
local ERR = 0xFF5A5AE6
local HIST = 12
local DRAFT_MAX = 1000

local chat = {
    draft = "",
    messages = {},
    pending_id = nil,
    sent_at = 0,
    seq = 0,
    starting_at = 0,
    last_cmd = "",
}

local function wrap_lines(text, max_w)
    text = tostring(text or "")
    if text == "" then
        return { "" }
    end
    local out = {}
    for para in (text .. "\n"):gmatch("(.-)\n") do
        if para == "" then
            out[#out + 1] = ""
        else
            local line = ""
            for word in para:gmatch("%S+") do
                local trial = (line == "") and word or (line .. " " .. word)
                local w = #trial * 7
                pcall(function()
                    local sz = imgui.calc_text_size(trial)
                    if sz then
                        w = sz.x or sz[1] or w
                    end
                end)
                if line ~= "" and w > max_w then
                    out[#out + 1] = line
                    line = word
                else
                    line = trial
                end
            end
            if line ~= "" then
                out[#out + 1] = line
            end
        end
    end
    if #out == 0 then
        return { text }
    end
    return out
end

local function sidecar_state()
    return Bridge.sidecar_state()
end

local function history_payload()
    local out = {}
    for i = 1, #chat.messages do
        local row = chat.messages[i]
        if row and (row.role == "user" or row.role == "assistant") and not row.pending then
            out[#out + 1] = { role = row.role, content = tostring(row.content or "") }
        end
    end
    if #out > HIST then
        local trimmed = {}
        for i = #out - HIST + 1, #out do
            trimmed[#trimmed + 1] = out[i]
        end
        out = trimmed
    end
    return out
end

local function send()
    local text = Core.trim(chat.draft)
    if text == "" or chat.pending_id then
        return
    end
    if #text > DRAFT_MAX then
        text = string.sub(text, 1, DRAFT_MAX)
    end
    chat.seq = chat.seq + 1
    local id = tostring(os.time()) .. "-" .. tostring(chat.seq)
    chat.messages[#chat.messages + 1] = { role = "user", content = text }
    local payload = history_payload()
    chat.messages[#chat.messages + 1] = { role = "assistant", content = "", pending = true, tools = {} }
    if not Bridge.send_chat(id, payload) then
        local last = chat.messages[#chat.messages]
        last.pending = false
        last.content = "Could not write chat_req.json."
        last.error = true
        return
    end
    chat.draft = ""
    chat.pending_id = id
    chat.sent_at = os.time()
end

function Chat.tick()
    local id = chat.pending_id
    if not id then
        return
    end
    local out = Bridge.read_chat_out()
    if type(out) ~= "table" or tostring(out.id or "") ~= id then
        return
    end
    local last = chat.messages[#chat.messages]
    if not last or last.role ~= "assistant" then
        return
    end
    last.content = tostring(out.text or "")
    last.tools = out.tools
    local status = tostring(out.status or "")
    if status == "done" then
        last.pending = false
        chat.pending_id = nil
    elseif status == "error" then
        last.pending = false
        last.error = true
        if last.content == "" then
            last.content = tostring(out.error or "sidecar error")
        end
        chat.pending_id = nil
    end
end

function Chat.clear()
    chat.draft = ""
    chat.messages = {}
    chat.pending_id = nil
    chat.sent_at = 0
end

local function current_game()
    local name = "mhwilds"
    pcall(function()
        local got = reframework:get_game_name()
        if type(got) == "string" and got ~= "" and got ~= "unknown" then
            name = got
        end
    end)
    return name
end

local function can_spawn_agent()
    return type(reflive) == "table" and type(reflive.agent_start) == "function"
end

local function run_agent(verb, menu)
    if not can_spawn_agent() then
        if menu and menu.toast then
            menu:toast("Update ref_live.dll to start the agent from Chat", "warning", 2400)
        end
        return
    end
    local ok, msg
    if verb == "stop" then
        ok, msg = reflive.agent_stop()
    else
        ok, msg = reflive.agent_start(current_game())
    end
    chat.last_cmd = tostring(msg or "")
    if ok then
        chat.starting_at = verb == "start" and os.time() or 0
        if menu and menu.toast then
            menu:toast(chat.last_cmd, "info", 1800)
        end
    else
        chat.starting_at = 0
        if menu and menu.toast then
            menu:toast(chat.last_cmd, "danger", 2800)
        end
    end
end

function Chat.recover(menu)
    local pulsed = Bridge.nudge()
    local side = select(1, Bridge.sidecar_state())
    if side == "connected" then
        if menu and menu.toast then
            menu:toast(pulsed and "Bridge pulsed" or "Bridge write failed", pulsed and "info" or "warning", 1600)
        end
        return
    end
    local starting = (chat.starting_at or 0) > 0 and (os.time() - chat.starting_at) < 20
    if starting then
        if menu and menu.toast then
            menu:toast("Agent starting…", "info", 1400)
        end
        return
    end
    run_agent("start", menu)
end

local BTN_H = 28

local function text_size(s)
    local ok, sz = pcall(imgui.calc_text_size, s)
    if ok and sz then
        return sz.x or (#s * 7), sz.y or 13
    end
    return #s * 7, 13
end

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

local function draw_status(ui, menu)
    local state, busy = sidecar_state()
    if state == "connected" then
        chat.starting_at = 0
    end
    local starting = (chat.starting_at or 0) > 0 and (os.time() - chat.starting_at) < 20
    local game = current_game()
    local label
    if state == "connected" and busy then
        label = "Agent thinking…"
    elseif state == "connected" then
        label = "Agent ready"
    elseif starting then
        label = "Agent starting for " .. game .. "…"
    elseif state == "stale" then
        label = "Agent stale — restart for " .. game
    else
        label = "Agent waiting"
    end
    if chat.pending_id and state ~= "connected" and (os.time() - (chat.sent_at or 0)) >= 8 then
        label = "No reply yet. Start the agent."
    end

    local origin = imgui.get_cursor_pos()
    local row_x = (origin and origin.x) or 0
    local row_y = (origin and origin.y) or 0
    local tw, th = text_size(label)
    set_pos(row_x, row_y + (BTN_H - th) * 0.5)
    imgui.text_colored(label, MUTED)
    local x = row_x + tw + 8
    set_pos(x, row_y)
    if state == "connected" then
        if imgui.button("Stop##live_chat_agent", { pill_w("Stop", 64), BTN_H }) then
            run_agent("stop", menu)
        end
        imgui.same_line()
    elseif not starting then
        if imgui.button("Start##live_chat_agent", { pill_w("Start", 64), BTN_H }) then
            run_agent("start", menu)
        end
        imgui.same_line()
    end
    if imgui.button("Clear##live_chat_clear", { pill_w("Clear", 64), BTN_H }) then
        Chat.clear()
    end
    local opened = Core.state.pinned_name
    if type(opened) == "string" and opened ~= "" then
        ui.muted("Opened " .. opened)
    else
        ui.muted("Click a Finder result or ask me to open one.")
    end
end

local function draw_message(row, max_w)
    if not row then
        return
    end
    local color = LIVE
    local who = "Live"
    if row.role == "user" then
        color = YOU
        who = "You"
    elseif row.error then
        color = ERR
        who = "Live"
    end
    imgui.text_colored(who, MUTED)
    local body = row.content or ""
    if row.pending and body == "" then
        body = "…"
    end
    local lines = wrap_lines(body, max_w)
    for i = 1, #lines do
        imgui.text_colored(lines[i], color)
    end
    local tools = row.tools
    if type(tools) == "table" then
        for i = 1, #tools do
            local tool = tools[i]
            if type(tool) == "table" then
                local name = tostring(tool.name or "tool")
                local extra = ""
                local args = tool.args
                if type(args) == "table" then
                    if args.name and args.value ~= nil then
                        extra = " " .. tostring(args.name) .. "=" .. tostring(args.value)
                    elseif args.needle then
                        extra = " " .. tostring(args.needle)
                    end
                end
                imgui.text_colored("  " .. name .. extra, MUTED)
            end
        end
    end
    imgui.spacing()
end

local function enter_pressed()
    local hit = false
    pcall(function()
        if imgui.is_item_active and imgui.is_item_active() and imgui.is_key_pressed then
            local key = imgui.ImGuiKey and imgui.ImGuiKey.Key_Enter
            if key and imgui.is_key_pressed(key) then
                hit = true
            end
        end
    end)
    return hit
end

function Chat.draw(menu)
    local ui = menu and menu.ui
    if not ui then
        return
    end

    draw_status(ui, menu)
    imgui.separator()

    local list_h = Widgets.remaining_height(52)
    local width = 360
    pcall(function()
        local avail = imgui.get_content_region_avail()
        if avail and avail.x then
            width = avail.x - 16
        end
    end)
    if width < 160 then
        width = 160
    end

    imgui.begin_child_window("##live_chat_log", { 0, list_h }, true)
    if #chat.messages == 0 then
        imgui.text_colored("I see your Finder search and whatever you have opened.", MUTED)
        imgui.text_colored("Ask me to search, open a row, or read its fields.", MUTED)
    else
        for i = 1, #chat.messages do
            draw_message(chat.messages[i], width)
        end
        if chat.pending_id then
            pcall(function()
                imgui.set_scroll_here_y(1.0)
            end)
        end
    end
    imgui.end_child_window()

    local send_w = 72
    local typed, text = ui.input_text("live_chat_draft", chat.draft, {
        placeholder = chat.pending_id and "Waiting…" or "Ask Live View…",
        width = -send_w - 10,
    })
    if typed and type(text) == "string" and not chat.pending_id then
        chat.draft = text
    end
    local submit = enter_pressed()
    imgui.same_line()
    local can_send = Core.trim(chat.draft) ~= "" and not chat.pending_id
    if imgui.button("Send##live_chat_send", { send_w, 0 }) then
        submit = true
    end
    if submit and can_send then
        send()
    end
end

return Chat
