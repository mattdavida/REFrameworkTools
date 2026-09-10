# Live View Agent

Local Azure OpenAI sidecar for [REFramework Live View](../REFrameworkLiveView). The game never holds the key. One process on **3002** serves Chat, the file bridge, and MCP.

Live View is the explorer. Chat and MCP are accelerators: find an object in-game, verify the live name and fields here, then write a mod from that graph.

## Contract

| | Chat (in-game) | MCP (Cursor) |
| --- | --- | --- |
| Search the live cache | yes | yes |
| Open a row (same as a Finder click) | yes | yes |
| Read fields on the opened object | yes | yes |
| Set bool / number / string on the opened object | yes | **no** |
| Call methods | no | no |
| See objects outside the live cache (cap 8000) | no | no |

MCP is read-only on purpose. Writes stay in the overlay, on an object you can see.

Both share one `req.json`. Do not run Chat tools and Cursor tools at the same time.

Health: `GET http://127.0.0.1:3002/api/health`.

## Ready when

1. `liveview-agent isup` → `up` and `bridge=connected`
2. In-game Chat says **Agent ready** (Start on that tab if it does not)
3. Cursor **liveview** MCP is green
4. F8 is open and the cache toggle is **Enabled**

The header **Bridge** chip is the AND of the game heartbeat and the sidecar pulse.

## What it does

- Health: `GET http://127.0.0.1:3002/api/health` → `bridge: connected` when Live View is writing `hb.json`.
- Chat tab (DevTools) and `POST /api/chat` (SSE: `token` / `tool` / `done` / `error`).
- File drop only. Stock REF Lua has no HTTP.
- Each Chat send includes a **session** (Finder box, visible rows, last opened object).
- Chat tools: `set_finder`, `open_object`, `inspect_opened`, `set_opened_field`, `cache_search`, `cache_stats`, `search_types`, `ui_state`.
- MCP tools: the read set above, plus `bridge_status`. No Set.

## Limits

- No method calls. Fields only.
- No non-primitive writes (objects, lists, enums).
- No Apply / Reject row — Chat ask is the confirmation.
- Same live cache as Finder (cap 8000). Nested objects can be open in inspect and still miss `open_object`.
- `uvicorn --reload` does not pick up new tools. `liveview-agent stop` then `start`.
- Hop allowlists live in Live View `cache.lua`. A new game looks empty until that list is retargeted.

## Quick start

Once, from this folder. **pipx** puts `liveview-agent` on PATH. Do not add `.venv\Scripts` to PATH.

```powershell
cd ReFrameworkLiveView.Agent
python -m backend install
```

Then, any terminal:

```powershell
liveview-agent start -game MonsterHunterWilds
```

Re-run `python -m backend install` (or `liveview-agent install`) after pulling CLI changes. Azure settings stay in `.env` in this folder (gitignored).

Dev checkout (tests only — not how the command gets on PATH):

```powershell
python -m venv .venv
.venv\Scripts\Activate.ps1
pip install -e .[dev]
```

`-game` is optional. Omit it to use `GAME_DIR` from `.env`. Steam folders resolve from the registry, `libraryfolders.vdf`, and `appmanifest_*.acf`.

```powershell
liveview-agent start -game MonsterHunterWilds
liveview-agent start -game dmc5
liveview-agent start -game "D:\SteamLibrary\steamapps\common\OnimushaWotS"
liveview-agent isup
liveview-agent stop
```

Slugs: `monsterhunterwilds` (`mhwilds`), `monsterhunterrise` (`mhrise`, `rise`), `onimushawots` (`onimusha`), `dmc5`. Also accepts a Steam app id or the `steamapps\common` folder name.

After a Live View Lua deploy: overlay **Reset scripts**, F8, Chat. Status **Agent ready**.

## Layout

```
.env                         Azure settings — not committed
backend/cli.py               liveview-agent start | stop | isup | install
backend/steam.py             Steam libraries + -game slugs
backend/config.py            fail-fast Azure vars + GAME_DIR
backend/tools/llm_client.py  AzureChatOpenAI
backend/tools/bridge.py      file-drop client (hb / req / res / chat)
backend/tools/ops.py         shared Chat + MCP ops
backend/tools/liveview.py    Chat tools (includes Set)
backend/mcp_server.py        MCP registration — mounted on uvicorn
backend/agent/loop.py        stream + tool rounds
backend/agent/inbox.py       Chat tab watcher (chat_req → chat_out)
backend/main.py              /api/health  /api/chat  /mcp + inbox
infra/                       dedicated Azure (optional, not required to run)
tests/                       bridge + inbox + cli / steam
```

Port **3002**.

## MCP

`liveview-agent start` is Chat, the file bridge, and `http://127.0.0.1:3002/mcp`. Do not start `mcp_server.py` or a second port.

**Cursor (once):** Command Palette → `View: Open MCP Settings` (not Ctrl+,). That UI reads `%USERPROFILE%\.cursor\mcp.json`:

```json
{
  "mcpServers": {
    "liveview": {
      "url": "http://127.0.0.1:3002/mcp"
    }
  }
}
```

Green means this chat can call tools. Red almost always means the sidecar is down — Start from Chat or `liveview-agent start`, then toggle liveview off and on.

Cursor green ≠ live data. Tools need the game writing `hb.json`. If the sidecar is up and the game is not, `bridge` is `waiting` and tools say so.

Read tools: `bridge_status`, `ui_state`, `cache_stats`, `cache_search`, `search_types`, `open_object`, `inspect_opened`.

Another game: `liveview-agent stop` then `liveview-agent start -game <folder>` (or Start from Chat in that session). Empty Finder means empty MCP.
