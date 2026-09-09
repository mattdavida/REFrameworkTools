# Live View Agent

Local Azure OpenAI sidecar for [REFramework Live View](../REFrameworkLiveView). The game never holds the key. This process must be running on **3002**.

**First pass (2026-09-05) is real.** Chat in DevTools can search the live cache, open a Finder row (same as a click), read fields, and Set bool/number/string on the opened object. Proven in-session: open `cHealthManager`, read `MaxHealth` / `DefaultMaxHealth` / `Health` at 2000, Set them to 9999.

That is the whole first pass. Do not pretend it is full automation.

## What works

- Health: `GET http://127.0.0.1:3002/api/health` → `bridge: connected` when Live View is writing `hb.json`.
- Chat tab (DevTools) and `POST /api/chat` (SSE: `token` / `tool` / `done` / `error`).
- File drop only. Stock REF Lua has no HTTP. Key stays in this process.
- Each Chat send includes a **session** (Finder box, visible rows, last opened object).
- Tools:
  - `set_finder` — types the Search box
  - `open_object` — same as clicking a result, then returns fields
  - `inspect_opened` — live fields on whatever is open
  - `set_opened_field` — same as inspect **Set** (bool / number / string)
  - `cache_search` / `cache_stats` / `search_types` / `ui_state`
- Azure is still the copied `execution_agent` `.env`. Own Bicep is not used yet.

## What it cannot do yet (next session)

Canonical list. MCP first pass is done — do not rediscover this.

- **Method calls** (`get_MaxHealth()`, Find functions). Fields only.
- **Non-primitive writes** — objects, lists, enums inspect would not Set as a bool/number/string.
- **Apply / Reject** — Chat ask is the only confirmation. No HITL row.
- **Follow a clamp** (`_HealthGaugeList`, other managers) without you asking.
- **Cache horizon** — same 3000-cap hop seed as Finder. Not an object iterator. Nested save objects (`cUserSystemParam`) may be open in Live and still miss `open_object`.
- **`--reload` hang** — Chat/MCP ignore new tools; restart uvicorn, do not only `--reload`.
- **MCP is read-only** — no `set_opened_field` / `set_finder` from Cursor. Chat still Sets.
- **One `req.json`** — do not run Chat tools and Cursor MCP in the same moment.
- **Own Azure** — still the copied `execution_agent` `.env`. `infra/deploy.ps1` stays parked.
- **Next-game seed** — hop allowlist in Live View `cache.lua` is Onimusha-shaped. Agent/MCP will look empty until that port.

## Quick start

Once, from this repo. Same idea as `npm i -g`: **pipx** builds one `liveview-agent` shim and puts **that file** on PATH. Do not add `.venv\Scripts` to PATH.

```powershell
cd C:\Users\mattd\development\REFrameworkTools\ReFrameworkLiveView.Agent
# copy an existing .env here if you do not already have one
python -m backend install
```

After that, any terminal:

```powershell
liveview-agent start -game MonsterHunterWilds
```

Re-run `python -m backend install` (or `liveview-agent install`) after pulling CLI changes. `.env` still lives in this repo.

Dev checkout (tests only — not how you get the command on PATH):

```powershell
python -m venv .venv
.venv\Scripts\Activate.ps1
pip install -e .[dev]
```

`-game` is optional. Omit it to use `GAME_DIR` from `.env`. Steam install folders are resolved the same way as UE4SSInstaller (registry + `libraryfolders.vdf` + `appmanifest_*.acf`).

```powershell
liveview-agent start -game MonsterHunterWilds
liveview-agent start -game dmc5
liveview-agent start -game "D:\SteamLibrary\steamapps\common\OnimushaWotS"
liveview-agent isup
liveview-agent stop
```

Slugs: `monsterhunterwilds` (`mhwilds`), `onimushawots` (`onimusha`), `dmc5`. Also accepts a Steam app id or the `steamapps\common` folder name.

Do not use `uvicorn --reload`. Chat/MCP ignore new tools until a real restart — `stop` then `start`.

After a Live View Lua deploy: overlay **Reset scripts**, F8, Chat. Status **Agent ready**.

```
GET http://127.0.0.1:3002/api/health
```

## Layout

```
.env                         copied from execution_agent — not committed
backend/cli.py               liveview-agent start | stop | isup | install
backend/steam.py             Steam libraries + -game slugs
backend/config.py            fail-fast Azure vars + GAME_DIR
backend/tools/llm_client.py  AzureChatOpenAI
backend/tools/bridge.py      file-drop client (hb / req / res / chat)
backend/tools/ops.py         shared Chat + MCP ops
backend/tools/liveview.py    Chat tools (includes Set)
backend/mcp_server.py        MCP registration — mounted on uvicorn, not a second process
backend/agent/loop.py        stream + tool rounds
backend/agent/inbox.py       Chat tab watcher (chat_req → chat_out)
backend/main.py              /api/health  /api/chat  /mcp + inbox
infra/                       dedicated Azure — post-working, do not run yet
tests/                       bridge + inbox + cli / steam
```

Port **3002** so execution_agent can stay on 3001.

## Rules

- Do not put this inside `ref_liveview.lua` or Onimusha.
- Tools must use Finder's cache path (`Cache.filter`).
- `set_opened_field` = inspect Set. No method calls, no VFX, no `requestOniSenseStartEffect`.
- "Opened" is a Finder click. Do not tell the user to pin.
- Own Bicep is a post-working goal. Do not run `infra/deploy.ps1` until you want keys isolated.

## MCP — how this is supposed to feel

There is **one** process. The uvicorn you already run **is** MCP.

```
liveview-agent start
```

That serves Chat, the file-bridge inbox, and `http://127.0.0.1:3002/mcp`. Do not start `mcp_server.py`. Do not start a second port.

**Cursor (once):** do not use Ctrl+, (that is VS Code settings). Open **Cursor Settings** with Ctrl+Shift+J, or Command Palette → `View: Open MCP Settings`. That UI reads `%USERPROFILE%\.cursor\mcp.json`. `liveview` is in that file. Turn it on. Green means this chat can call tools. Red almost always means uvicorn is not running — start it, then toggle liveview off and on.

**How you know it is ready**

1. Terminal shows `MCP at http://127.0.0.1:3002/mcp` on startup.
2. `GET http://127.0.0.1:3002/api/health` includes `"mcp": "http://127.0.0.1:3002/mcp"`.
3. Cursor liveview is green.

Cursor connecting ≠ game data. Tools need Live View writing `hb.json` (game open, F8, Reset scripts after a Lua deploy). If the server is up and the game is not, `bridge` is `waiting` and tools say so.

Read tools only: `bridge_status`, `ui_state`, `cache_stats`, `cache_search`, `search_types`, `open_object`, `inspect_opened`. No Set from Cursor.

Do not run in-game Chat tools and Cursor MCP at the same moment. One `req.json`.

Another game: `liveview-agent stop` then `liveview-agent start -game MonsterHunterWilds` (or set `GAME_DIR` in `.env`). Hop allowlists in Live View `cache.lua` are still Onimusha-shaped.

## Next session

Work **What it cannot do yet** above. Start with one getter/method call or Apply / Reject — not another MCP transport. New game = Live View hop allowlist first, then the same uvicorn.
