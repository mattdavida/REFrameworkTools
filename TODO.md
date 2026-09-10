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

- [x] **`config.py` fails at import time** — fixed: Azure vars moved to `require_azure()`
  called lazily inside `llm_client.get_chat_llm()`. CLI, MCP, and health endpoint all work
  without a `.env` set.

- [x] **`_DEFAULT_GAMES` hardcodes personal Onimusha paths** — fixed: `resolve_dir` now
  returns a `_UNCONFIGURED` sentinel path when `GAME_DIR`/`LIVEVIEW_BRIDGE_DIR` are absent.
  `status()` reports `"waiting"` cleanly instead of pointing at a wrong game folder.

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

- [x] **`_busy` global in `inbox.py` is not thread-safe** — fixed: replaced with
  `asyncio.Lock` (`_inbox_lock`). `write_sidecar` derives the busy flag from
  `_inbox_lock.locked()` so the bool is always consistent with the lock state.

### P3

- [x] **`cap` parameter not exposed to LLM tools** — fixed: `cache_search(needle, cap=40)`
  and `search_types(needle, cap=40)` now accept a cap argument that flows through to the
  bridge call. LLMs can request a wider net.

- [ ] **`test_bridge.py` roundtrip test is integration-level in a unit file** — The
  `test_call_roundtrip` test spins a real thread and writes real temp files. That's fine as a
  test, but it belongs in `tests/integration/` (or at minimum a clearly named file) so a fast
  `pytest -m unit` sweep doesn't have to run it. The unit tests (`test_status_waiting`,
  `test_status_connected`) are correctly scoped alongside it today.

---

## Live View Lua (`REFrameworkLiveView`)

### P1

- [x] **`SHOW_EMPTY = 220` vs bridge `ROW_CAP = 40` mismatch** — fixed: `bridge.lua` now
  uses `ROW_CAP_EMPTY = 150` as the default cap for empty-needle queries, and raises the
  max-cap ceiling to match. Non-empty queries keep `ROW_CAP = 40`.

### P2

- [x] **Redundant `require` calls inside closures** — fixed: removed inner `local Core =
  require(...)` and `local Cache = require(...)` re-declarations from `live_rows()`,
  `filtered_results()`, and `Finder.draw()` in `finder.lua`. File-scope locals are used
  throughout.

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

- [x] **Silent `pcall` swallows errors with no debug path** — fixed: `hop_one` now wraps its
  hop loop in `pcall` and calls `Log.warn("Cache", ...)` on failure. `crawl_one` left
  silent intentionally (one warn per method name would be too noisy).

### P3

- [x] **`member_cache` grows forever** — fixed: `core.lua` now checks the cache size before
  inserting; when it hits `MEMBER_CACHE_MAX = 400` entries the whole cache is cleared.
  Eviction is coarse (clear-all vs LRU) but avoids the complexity of a linked eviction list
  in Lua.

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
