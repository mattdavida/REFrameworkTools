# REFramework Live View

Standalone object explorer for RE Engine games via [REFramework](https://github.com/praydog/REFramework). Hero and shot walkthrough: [README](../README.md) · [DEMO](../DEMO.md).

This folder is the product: finder, inspect, call, field edit, Chat, and `ref_live.dll`. Window chrome comes from [REFrameworkMods/REFrameworkRefShell](../../REFrameworkMods/REFrameworkRefShell). You do not need to adopt RefShell in your own mods.

Onimusha QoL is a separate menu (`~`). This overlay does not include cheats.

## What it does

- **F8** toggles the window (rebind on Settings). Look input pauses while it is open.
- Finder on the **left**. DevTools on the **right**: Console | Live View | Chat.
- Live open = fullscreen **40% finder / 60% DevTools**, full height (`theme.live_split`).
- Search the rolling live cache. Empty query = the rolling set. **Include types** is off by default.
- Row labels are hop paths (`PlayerManager.getControllingPlayer().get_Context()` …).
- `member_index` puts TDB field/method names in `row.hay`, so search is not type-name-only.
- Click a result to **open** it. Inspect fields (Set / Go). Call methods in Find functions. Chat cannot call methods.
- Finder is Search + Results only.

## Ship

One Lua bundle. No loose `lua/` tree, no second copy in `data/`.

```
<game>/reframework/autorun/ref_liveview.lua
<game>/reframework/plugins/ref_cursor.dll
<game>/reframework/plugins/ref_live.dll
```

From this folder, with `../../REFrameworkMods/REFrameworkRefShell` (or `REFSHELL_DIR`):

```
npm run bundle
npm run deploy
```

`deploy` writes those files, then removes old copies if they are still present:

- autorun: `main.lua`, `refshell.lua`, `liveview.lua`, `refshell/`
- data: `liveview_reload.lua`, `refshell_live_reload.lua`

It does not touch `onimusha_qol.lua`, `dinput8.dll`, REF config, or type dumps.

Set `GAME_DIR` to any REFramework game folder, or `npm run deploy -- -game MonsterHunterWilds`.

**Refresh** in DevTools rebuilds the live cache (`Cache.rebuild()`). After a Lua deploy, use the overlay **Reset scripts** once (or restart) to load the new bundle. After a new DLL, close the game first.

Edits copied into `reframework/data` are not loaded. This product does not ship a reload file there.

## How search works

`Finder.draw` → `live_rows()` → **`Cache.filter` on the same module as the cache counter**.

A second results pipeline in front of that (`set_results` → another `Core.state`) desyncs the list from the counter.

Cache (`liveview.cache`) seeds in the background from:

1. Player hops (allowlist only)
2. Singletons
3. Scene walk (cap **900**)

Total cap **8000**. Player hops are not evicted to make room. Field crawl indexes catalog / userdata children (so `_StatusParam` is searchable by `health`) without walking every component graph. Status line: hops / singletons / scene.

Caps in `cache.lua`: `MAX 8000`, `SCENE_CAP 900`, empty list `SHOW_EMPTY 220`, scene `70`/frame, crawl `18`, hop `12` (boost `40`).

The hop allowlist is per-game. Another title needs that list retargeted or Finder (and MCP) stay empty.

## Layout

```
lua/liveview.lua                 require("liveview") — attach
lua/liveview/core.lua            state, open, go-to, member_index
lua/liveview/cache.lua           background object cache
lua/liveview/bridge.lua          sidecar file drop (data/liveview_bridge)
lua/liveview/tdb.lua             field/method classify (no ImGui)
lua/liveview/invoke.lua          calls (no ImGui)
lua/liveview/ui/finder.lua       left list
lua/liveview/ui/inspect.lua      fields
lua/liveview/ui/call.lua         Find functions window
lua/liveview/ui/chat.lua         DevTools Chat tab
lua/liveview/ui/workspace.lua    Console | Live View | Chat
lua/liveview/ui/widgets.lua
reframework/autorun/main.lua     thin host: create + attach + bind
reframework/plugins/             ref_live.dll + ref_cursor.dll
tools/bundle.mjs                 inline sibling RefShell + this lua/
tools/deploy.mjs                 copy bundle + both DLLs
tools/steam.mjs                  GAME_DIR / -game (catalog: ../../steam-games.json)
tools/sync-reflive.ps1           copy built ref_live.dll into this repo
```

Host: `require("liveview").attach(menu)` then `menu:bind()`. Modules are `liveview.*`.

C++ source of truth: `REFramework/examples/ref_live/plugin.cpp` and `ref_cursor/plugin.cpp`.

## Rebuild the live plugin

```
cmake --build build64_all --target ref_live --config Release
powershell -File tools/sync-reflive.ps1
```

Then close the game and `npm run deploy`.

## Agent sidecar

Sibling [ReFrameworkLiveView.Agent](../ReFrameworkLiveView.Agent). Chat **Start** / **Stop** run `liveview-agent`. The game never holds the key. MCP is the same process and is read-only — contract is in that README and the [root README](../README.md).

```
<game>/reframework/data/liveview_bridge/hb.json         Live View heartbeat
<game>/reframework/data/liveview_bridge/req.json        sidecar tool request
<game>/reframework/data/liveview_bridge/res.json        Live View tool answer
<game>/reframework/data/liveview_bridge/sidecar.json    agent heartbeat
<game>/reframework/data/liveview_bridge/chat_req.json   Chat tab → sidecar
<game>/reframework/data/liveview_bridge/chat_out.json   streaming reply
```

Runtime JSON in `data/` is expected. Do not ship Lua there.

## Limits

- Cache rebuilds on scene change and when a controlling player appears.
- Scene count can read 0 when hops fill the cap. Hops evict scene on purpose.
- Refresh rebuilds the cache. It does not reload Lua from disk.
- There is no object iterator in Lua. The cache is a seeded walk. Unseen objects are absent until hopped or seen in scene.
- Chat can Set bool / number / string on the opened object. It cannot call methods or Set non-primitives.
- Chat and MCP see the same cache as Finder.

## Constraints

- No all-singleton `get*` crawls. Hop allowlist only. Field crawl one hop, budgeted.
- After Lua deploy: Reset scripts. New DLLs: close the game.
- Ship is the three files above. No `liveview_reload.lua`, no custom `dinput8` for script reset, no Live View tab on the Onimusha menu.
