-- Standalone Live View. F8 toggles. RefShell is window chrome only.

local RefShell = _G.RefShell
if not RefShell then
    local ok, mod = pcall(require, "refshell")
    if ok then
        RefShell = mod
    end
end

if not RefShell then
    log.error("[liveview] refshell missing — run npm run bundle (inlines REFrameworkMods/REFrameworkRefShell)")
    return
end

local LiveView = require("liveview")

local menu = RefShell.create({
    id = "liveview",
    title = "LIVE VIEW",
    toggle_vk = 0x77,
    dock = "left",
    width = 520,
    height = 720,
    start_open = false,
    persist = {},
    host = true,
    lock_camera = true,
    lock_cursor = true,
})

LiveView.attach(menu)
menu:bind()
