# REFramework Live View

Standalone object explorer for RE Engine games via [REFramework](https://github.com/praydog/REFramework).

This folder is the product: finder, inspect, call, field edit, and `ref_live.dll`. Window chrome comes from [REFrameworkMods/REFrameworkRefShell](../../REFrameworkMods/REFrameworkRefShell). You do not need to adopt RefShell in your own mods.

Onimusha QoL is a separate menu (`~`). This one does not include cheats. Do not put Live View back on the Onimusha menu.

**Last session (2026-09-05):** Agent first pass works. Chat can open a cache row and Set primitives on it (e.g. `cHealthManager` MaxHealth 2000 → 9999). Search / bundle / no `data/` reload from earlier in the day still stand.

## What works

- **F8** toggles the window (rebind on Settings). Look input pauses while it is open. Onimusha stays on `~` so both can run.
- Finder on the **left**. When Live is active, the menu docks left (not persisted as the user's dock).
- **DevTools** on the right: **Console | Live View | Chat** (violet on the workspace only). Chat file-drops to the sidecar — no key in the game.
- Live open = fullscreen **40% finder / 60% DevTools**, full height, 8px gap (`theme.live_split`). Not saved as dock/width.
- Search the rolling live cache. Empty query = rolling set. **Include types** is off by default.
- Row labels are hop paths (`PlayerManager.getControllingPlayer().get_Context()` …). That list is the one that works.
- `member_index` puts TDB field/method names in `row.hay`. Search is not type-name-only. Onimusha stamina is **Rikido** — search `rikido`.
- Click a result to **open** it (inspect + Chat both see that object). Inspect fields (Set / Go). Call methods in the Find functions window — Chat cannot call methods yet.
- Finder is Search + Results only. Types / Singletons / Scene / Diff / Has buttons are gone.

## Ship

One Lua file. No loose `lua/` tree, no second copy in `data/`.

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

`deploy` writes the files above, then deletes leftovers if they still exist:

- autorun: `main.lua`, `refshell.lua`, `liveview.lua`, `refshell/`
- data: `liveview_reload.lua`, `refshell_live_reload.lua`

It does not touch `onimusha_qol.lua`, `dinput8.dll`, REF config, or type dumps.

Set `GAME_DIR` to any REFramework game folder. Onimusha Way of the Sword is detected automatically when present.

**Refresh** in DevTools rebuilds the live cache (`Cache.rebuild()`). Stock REF has no script-reset API for Lua; we do not ship a custom `dinput8` to add one. After a Lua deploy, use the overlay **Reset scripts** once (or restart) to load the new bundle. After a new DLL: close the game first.

Do not expect edits to appear by copying Lua into `reframework/data`. Stock REF `fs.read` sees `data/`, but this product does not ship a reload file there on purpose.

## How search works (do not regress)

The list that works:

`Finder.draw` → `live_rows()` → **`Cache.filter` on the same module as the 3000 counter**.

Do not put another pipeline in front of that (`set_results` → another `Core.state`). That is how Results showed **0 / 0** while the counter said 3000 after the split.

Cache (`liveview.cache`) seeds in the background from:

1. Player hops (allowlist only)
2. Singletons
3. Scene walk (cap **900**)

Total cap **3000**. Hops run before scene; hops can evict scene. Field crawl is one hop, budgeted. Status line: hops / singletons / scene.

Caps / budgets in `cache.lua`: `MAX 3000`, `SCENE_CAP 900`, empty list `SHOW_EMPTY 220`, scene `70`/frame, crawl `18`, hop `12` (boost `40`).

## Repo

```
lua/liveview.lua                 require("liveview") — attach
lua/liveview/core.lua            state, pin, go-to, member_index
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
reframework/plugins/             ref_live.dll
tools/bundle.mjs                 inline sibling RefShell + this lua/
tools/deploy.mjs                 copy bundle + both DLLs
tools/sync-reflive.ps1           copy built ref_live.dll into this repo
```

Host: `require("liveview").attach(menu)` then `menu:bind()`. Modules are `liveview.*`, not `refshell.live.*`.

C++ source of truth for the plugin: `REFramework/examples/ref_live/plugin.cpp`.

## Rebuild the live plugin

```
cmake --build build64_all --target ref_live --config Release
powershell -File tools/sync-reflive.ps1
```

Then close the game and `npm run deploy`.

## Agent sidecar

Sibling [ReFrameworkLiveView.Agent](../ReFrameworkLiveView.Agent) is a first pass, not full automation. Chat is the third DevTools tab. The game never holds the key.

```
<game>/reframework/data/liveview_bridge/hb.json         Live View heartbeat (~30 frames)
<game>/reframework/data/liveview_bridge/req.json        sidecar tool request
<game>/reframework/data/liveview_bridge/res.json        Live View tool answer
<game>/reframework/data/liveview_bridge/sidecar.json    agent heartbeat
<game>/reframework/data/liveview_bridge/chat_req.json   Chat tab → sidecar (includes session)
<game>/reframework/data/liveview_bridge/chat_out.json   streaming reply
```

Proven: `open_object` (Finder click) + `inspect_opened` + `set_opened_field` (inspect Set). Also `set_finder`, `cache_search`, `search_types`, `ui_state`. Chat ask = write confirm. Bool/number/string on the **opened** object only. No method/VFX calls.

Runtime JSON in `data/` is fine. Do not ship Lua there.

After Lua deploy: overlay **Reset scripts**. Sidecar: `uvicorn` on **3002**. Health `bridge: connected`.

## Sibling repos

| Location | Role |
| --- | --- |
| This folder | Live View product |
| `../ReFrameworkLiveView.Agent` | Local Azure sidecar + DevTools Chat |
| `../../REFrameworkMods/REFrameworkRefShell` | Window chrome only |
| `../../REFrameworkMods/games/` | Game QoL menus (Rise, Wilds, Onimusha, DMC5) |
| `../../REFramework` | REF fork + `ref_live` / `ref_cursor` C++ |

Onimusha deploy still writes `onimusha_qol.lua` + `ref_cursor.dll` only.

## Known gaps

- **Cache rebuilds on scene change and when a controlling player appears.** Boot used to hop `PlayerManager` once at the title (no player), then never retry — search stayed empty until you hit Reset scripts. The window can also come back open from `refshell_liveview.json`; that is persist, not the rebuild bug.
- **Scene counter can read 0** when hops fill the 3000 cap. Hops evict scene on purpose so player context stays visible. Not a ship blocker; the rolling list is still the search source.
- **Workspace Refresh rebuilds the live cache.** It does not reload Lua from disk. After `npm run deploy`, use the overlay Reset scripts once (or restart).
- **No object iterator in Lua.** Cache is a seeded walk, not UE4SS `GUObjectArray`. Objects you have not hopped to or seen in scene will not appear until they do.
- Finder filters `Cache` directly. Do not add a second results pipeline.
- **`core.lua` is large** (~940 lines). House limit: 800 = consider split, 1000 max.
- **No first git commit** in this repo, RefShell, or Onimusha.
- **Not packaged for Nexus.** Onimusha `nexus.txt` still describes the old trainer zip (no Live View). Live is a separate product if/when it ships.
- Scene / Diff / Has buttons and `search.lua` are gone. Finder is Search + Results only.
- **Agent cannot call methods** or Set non-primitives. No Apply/Reject row yet.
- **Agent only sees the 3000-cap cache.** Same hop seed as Finder. Not an object iterator.
- **"Pin" is gone from the UI** (it now says Opened). The model can still say pin if the sidecar is on an old prompt — restart uvicorn, do not only `--reload`.

## Cleanup (next session candidates)

**This repo**

- Split `core.lua` if you touch it again (pin/history vs type/collection helpers).
- `Finder.draw` re-requires `Core` / `Cache` every frame; fine, but noisy.
- Workspace Refresh is cache-only; do not add a custom `dinput8` just to expose script reset.

**RefShell (chrome still knows about Live)**

- `_liveview`, `sync_live_layout`, `is_live_tab`, left-split, and "Hide Workspace" live in `refshell.lua` because `LiveView.attach` sets `menu._liveview`. That coupling is leftover from the split. Long-term: Live-only layout should live here, not in the reusable shell.
- Log filter imgui ids still say `devtools_log_*`.

**Do not reintroduce**

- `lua/liveview/reload.lua` or `reframework/data/liveview_reload.lua`
- `ref_reset.dll` or a custom `dinput8` for script reset
- Loose `autorun/refshell/` or `autorun/liveview.lua` next to the bundle
- LuaRocks
- A second ImGui context / EMV rebuild
- Vendoring RefShell into this repo
- Live as an Onimusha tab

## Constraints (keep)

- Do not freeze the game: no all-singleton `get*` crawls. Hop allowlist only. Field crawl one hop, budgeted.
- Do not call `requestOniSenseStartEffect` blindly (Onimusha research; parents Gm100 letter VFX to the player). Notes stay in `onimushaMod/docs/oni-sense.md`.
- After Lua deploy: Reset scripts. New DLLs: close the game.

## Next session start

MCP first pass is done (same uvicorn, `http://127.0.0.1:3002/mcp`). Do not rebuild transport.

Agent cannots (method call, non-primitive Set, Apply / Reject, cache horizon, `--reload`, MCP read-only, one `req.json`, own Azure, next-game hop seed): `../ReFrameworkLiveView.Agent/README.md` → **What it cannot do yet**.

Then:

1. Confirm game install is still only the three ship files (no `data/liveview_reload.lua`). Runtime `data/liveview_bridge/*.json` is expected.
2. If search looks empty, the list must still come from `Cache.filter` in `live_rows()`.
3. Do not reopen the reload-file design. Do not run Agent `infra/deploy.ps1` until you want a separate Azure key.
4. Another game: `npm run deploy` with `GAME_DIR` set. Retarget the hop allowlist in `cache.lua` or Finder/MCP stay empty. Same uvicorn; `GAME_DIR` in Agent `.env`.
