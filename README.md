# REFramework Tools

Live View and the agent. Not a Nexus zip. Game QoL menus live in sibling [REFrameworkMods](../REFrameworkMods).

```
REFrameworkLiveView/          finder / inspect / call (Lua + ref_live.dll)
ReFrameworkLiveView.Agent/    Azure sidecar + MCP on 3002
ref_cursor/                   docs for the cursor-lock plugin
ref_live/                     docs for the live-object plugin
```

The C++ for `ref_cursor` and `ref_live` still builds in the **REFramework** fork. Folders here are the Lua product and the READMEs.

## Live View

Needs sibling Mods for window chrome:

```
cd REFrameworkLiveView
npm run bundle
npm run deploy
```

Bundle reads `../../REFrameworkMods/REFrameworkRefShell` (or `REFSHELL_DIR`). Deploy writes:

```
<game>/reframework/autorun/ref_liveview.lua
<game>/reframework/plugins/ref_cursor.dll
<game>/reframework/plugins/ref_live.dll
```

**F8** toggles Live View. Game QoL stays on **~**.

## Agent

Local process. The game never holds the API key. `.env` stays on disk and is gitignored.

```
cd ReFrameworkLiveView.Agent
python -m backend install
liveview-agent
```

See that folder's README. Do not commit `.venv/` or `.env`.

## Do not

- Ship this repo to Nexus players.
- `git add .` without the root `.gitignore` (the Agent venv is huge).
- Put cheats back into Live View.
