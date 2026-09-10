-- Live attach: finder on the left, workspace on the right.
-- Kernel: liveview.core  Cache: liveview.cache  UI: liveview.ui.*

local Log = require("refshell.log")
local Core = require("liveview.core")
local Tdb = require("liveview.tdb")
local Inspect = require("liveview.ui.inspect")
local Call = require("liveview.ui.call")
local Workspace = require("liveview.ui.workspace")
local Finder = require("liveview.ui.finder")

local LiveView = {}

LiveView.draw_inspector = Inspect.draw
LiveView.draw_functions_window = Call.draw_window
LiveView.draw_workspace = Workspace.draw

function LiveView.attach(menu)
    Core = require("liveview.core")
    Tdb = require("liveview.tdb")
    Inspect = require("liveview.ui.inspect")
    Call = require("liveview.ui.call")
    Workspace = require("liveview.ui.workspace")
    Finder = require("liveview.ui.finder")

    LiveView.draw_inspector = Inspect.draw
    LiveView.draw_functions_window = Call.draw_window
    LiveView.draw_workspace = Workspace.draw
    menu._draw_workspace = Workspace.draw
    Core.on_refresh(Tdb.refresh_members)
    Finder.attach(menu)

    if not menu._live_cache_bound then
        menu._live_cache_bound = true
        re.on_frame(function()
            local Cache = require("liveview.cache")
            -- Disable only stops the walk. Bridge/Chat must keep pulsing
            -- or inspect still works in-game while MCP/Chat report stale.
            if Cache.enabled() then
                local ok, err = pcall(Cache.tick)
                if not ok then
                    Log.error(Core.SOURCE, "cache tick — " .. tostring(err))
                end
            end
            require("liveview.bridge").tick()
            require("liveview.ui.chat").tick()
        end)
    end

    if menu._liveview then
        return menu
    end
    menu._liveview = true

    Log.info(Core.SOURCE, Core.plugin_ok() and "ready — live cache + ref_live.dll" or "ready — live cache; ref_live.dll missing")
    return menu
end

return LiveView
