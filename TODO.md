# Pre-ship TODO

Gaps found in a post-week-one review. Everything here is **known and intentional debt**, not
surprise — the same week this repo was built, the sibling
[REFrameworkMods](../REFrameworkMods) delivered RefShell, MHWildsMod (1 747 lines), MHRiseMod
(2 117 lines), onimushaMod (1 557 + appearance + give), and DMC5CheatMenu. That context
explains every rough edge below.

Priority order: **P1 = blocks community use**, **P2 = friction for contributors**, **P3 = nice to have**.

---

## Agent sidecar (`ReFrameworkLiveView.Agent`)

### P1

- [ ] **`config.py` fails at import time** — `_require()` raises if Azure vars are missing and
  runs at module level. Any accidental import in the chain (including tests) blows up for users
  who haven't set `.env` yet. Move the require check inside `llm_client.py` (lazy, only when
  the LLM is actually called). The CLI and MCP tools should start without an API key set.

- [ ] **`_DEFAULT_GAMES` hardcodes personal Onimusha paths** — `resolve_dir` falls back to
  `D:\SteamLibrary\steamapps\common\OnimushaWotS`. For any community user without that path,
  every missing-config error message points at a folder that doesn't exist on their machine.
  Replace the fallback with a clear `RuntimeError("Set GAME_DIR in .env or pass -game <slug>")`.

### P2

- [ ] **Game-specific lore hardcoded in `loop.py` system prompt** — "Onimusha stamina is
  Rikido. Purple souls fill OniChangeEnergy on cPlayerContextParam." This is a personal decoder
  ring. Contributors and users on other games will be confused. Move it to a `GAME_NOTES`
  section in `.env` or a per-game prompt fragment file, injected at agent start. Keep the rest
  of the prompt as-is — it's good.

- [ ] **`mcp_server.py` reaches into MCP SDK internals** — `http.router.lifespan_context` and
  `mcp._lowlevel_server._session_manager` are private attributes. Pin the MCP SDK version in
  `requirements.txt` to prevent a silent breakage on the next SDK release. Add a comment
  explaining what each line works around and what SDK version it was tested against.

- [ ] **`_busy` global in `inbox.py` is not thread-safe** — The `finally` block unconditionally
  sets `_busy = False`. If an edge case ever fires two inbox events (rapid re-id, race on
  startup), the finally from the first clears the flag for the second. Replace the module
  global with an `asyncio.Lock` so the intent is explicit and the pattern is safe if the
  watcher is ever made concurrent.

### P3

- [ ] **`cap` parameter not exposed to LLM tools** — `cache_search` and `search_types` accept
  a `cap` argument in the bridge, but the `ops.py` wrappers don't expose it. The LLM can't
  ask for more or fewer results. Add `cap: int = 40` to both functions so tools can be called
  with a wider net when the first search comes back thin.

- [ ] **`test_bridge.py` roundtrip test is integration-level in a unit file** — The
  `test_call_roundtrip` test spins a real thread and writes real temp files. That's fine as a
  test, but it belongs in `tests/integration/` (or at minimum a clearly named file) so a fast
  `pytest -m unit` sweep doesn't have to run it. The unit tests (`test_status_waiting`,
  `test_status_connected`) are correctly scoped alongside it today.

---

## Live View Lua (`REFrameworkLiveView`)

### P1

- [ ] **`SHOW_EMPTY = 220` vs bridge `ROW_CAP = 40` mismatch** — Empty-query Finder shows 220
  rows; the same empty query over the bridge (MCP / Chat) returns 40. An agent trying to census
  the cache gets a 5× smaller sample than the user sees. Align the defaults: either raise
  `ROW_CAP` to 100–150 for empty queries, or document the intentional difference in a comment
  so future callers don't assume parity.

### P2

- [ ] **Redundant `require` calls inside closures** — `finder.lua` opens with
  `local Core = require("liveview.core")` at file scope, then re-declares it inside
  `live_rows()`, `filtered_results()`, and `Finder.draw()`. Lua's `require` is cached (same
  table returned), so it's functionally harmless, but it reads like a draft that was never
  cleaned up and confuses contributors reading the module. Remove the inner re-declarations.

- [ ] **`state.results` double-assignment** — `live_rows()` assigns `state.results = rows`
  (the pre-narrow list), then `filtered_results()` narrows it for display without updating
  `state.results`. Anything that reads `state.results` expecting the display list gets the
  un-narrowed version. Either: (a) don't assign to `state.results` in `live_rows()` and let
  `Finder.draw` own that write, or (b) assign after narrowing. Currently harmless but is
  latent confusion for the bridge snapshot code.

- [ ] **`crawl_one` iterates all fields including primitives** — For types like
  `PlayerGlobalParam` with many float fields before the first managed object, each crawl tick
  iterates every field to find managed ones. The comment notes the problem; the fix (break at
  80 added objects) doesn't help when there are 200 fields before the first one. Add a cheap
  guard: check the field's type definition for `is_primitive()` before calling `get_field`,
  skipping the allocation.

- [ ] **Silent `pcall` swallows errors with no debug path** — `call_named`, `hop_one`, and
  `crawl_one` swallow every error silently. After a game update that renames a method, you
  get an empty cache with no indication why. Add a single `Log.warn(SOURCE, ...)` call in the
  catch block of `hop_one` (not `crawl_one` — that would be too noisy) so hop failures surface
  without spamming the log on every tick.

### P3

- [ ] **`member_cache` grows forever** — `Core.member_index` caches TDB field/method names
  per type in a module-local table with no size bound. After a long session with many types
  opened, this accumulates. Add a `MAX_MEMBER_CACHE = 400` guard and drop the oldest entry
  when the limit is hit (or just clear on `Cache.rebuild()`).

- [ ] **No guard against shipping a debug DLL** — `tools/sync-reflive.ps1` copies whatever
  DLL is in the build output without checking the build config. Add a check for the filename
  or a size sanity guard so a debug build (typically 3–5× larger) isn't accidentally deployed
  to a game folder.

---

## Tooling / repo shape

### P2

- [ ] **DMC5 still vendors RefShell inline** — Noted in `REFrameworkMods/README.md` "Later"
  section. Before shipping the community zip, point `DMC5CheatMenu` at the shared
  `../../REFrameworkRefShell` folder (same pattern as Rise / Wilds / Onimusha) so there is
  one copy of RefShell to update. This lives in REFrameworkMods but gates the tidy story here
  because Live View's README references the shared RefShell as a design point.

- [ ] **Game folder naming is inconsistent** — `DMC5CheatMenu`, `MHRiseMod`, `MHWildsMod`,
  `onimushaMod`. Three PascalCase, one camelCase. Also noted in REFrameworkMods README.
  Settle on a convention (`dmc5`, `rise`, `wilds`, `onimusha`) and rename once rather than
  carrying the inconsistency forward.

### P3

- [ ] **No `.env.example` is committed for Tools** — `ReFrameworkLiveView.Agent/.env.example`
  exists but the root repo has no matching doc for what keys are needed. First-run experience
  for a community user is: clone → `python -m backend install` → agent start → immediate
  crash with "Missing AZURE_OPENAI_API_KEY". A top-level `SETUP.md` or a richer `--help`
  message from `liveview-agent start` would close this gap cheaply.

- [ ] **`nexus.txt` files exist but no packaging script** — Each game has a `nexus.txt`
  describing the Nexus Mods release but there's no `npm run zip` or similar that assembles the
  deploy output into the correct archive layout. Manual packaging is error-prone. Even a
  trivial script that zips `dist/` + `plugins/` into the right folder shape would help.

---

## Not on the list (intentional)

- Method calls from MCP — deliberately out of scope. Writes stay in the overlay.
- All-singleton crawls — deliberately excluded (no allowlist, no bounds).
- The `known_objects` 200-entry cap in `core.lua` — works fine, not worth touching.
- The `Onimusha QoL` menu is a separate `~` menu by design. No coupling needed.
