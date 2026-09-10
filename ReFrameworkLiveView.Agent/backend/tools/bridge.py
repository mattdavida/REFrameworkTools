"""
File-drop client for Live View.

The game writes reframework/data/liveview_bridge/hb.json each ~30 frames.
The sidecar writes req.json; Lua answers res.json with the same id.

No HTTP in the game. Getters only.
"""

from __future__ import annotations

import json
import os
import time
import threading
import uuid
from pathlib import Path
from typing import Any

_write_locks: dict[str, threading.Lock] = {}
_write_locks_guard = threading.Lock()


def _lock_for(path: Path) -> threading.Lock:
    key = str(path)
    with _write_locks_guard:
        lock = _write_locks.get(key)
        if lock is None:
            lock = threading.Lock()
            _write_locks[key] = lock
        return lock

HB_STALE_S = 3.0
CALL_TIMEOUT_S = 4.0
POLL_S = 0.05

# Sentinel returned when no game dir is configured. Callers that read files will
# find nothing and report state "waiting" — a clear signal, not a wrong path.
_UNCONFIGURED = Path("liveview_bridge_not_configured")


def resolve_dir(explicit: str | Path | None = None) -> Path:
    if explicit:
        return Path(explicit)
    override = os.getenv("LIVEVIEW_BRIDGE_DIR")
    if override:
        return Path(override)
    game = os.getenv("GAME_DIR")
    if game:
        return Path(game) / "reframework" / "data" / "liveview_bridge"
    # Not configured: return a dead path so status() reports "waiting" cleanly.
    # Fix: set GAME_DIR in .env or run  liveview-agent start -game <slug>
    return _UNCONFIGURED


def _atomic_write(path: Path, payload: dict[str, Any]) -> None:
    """Write JSON. On Windows Lua may have the dest open; replace then retry / overwrite."""
    path.parent.mkdir(parents=True, exist_ok=True)
    data = json.dumps(payload, separators=(",", ":"))
    tmp = path.with_name(path.name + ".tmp")
    last_err: OSError | None = None
    with _lock_for(path):
        for attempt in range(8):
            try:
                tmp.write_text(data, encoding="utf-8")
                try:
                    tmp.replace(path)
                except PermissionError:
                    path.write_text(data, encoding="utf-8")
                    try:
                        tmp.unlink(missing_ok=True)
                    except OSError:
                        pass
                return
            except OSError as exc:
                last_err = exc
                time.sleep(0.02 * (attempt + 1))
        if last_err:
            raise last_err


def _read_json(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if isinstance(data, dict):
        return data
    return None


def read_heartbeat(bridge_dir: str | Path | None = None) -> dict[str, Any] | None:
    return _read_json(resolve_dir(bridge_dir) / "hb.json")


def heartbeat_age_s(bridge_dir: str | Path | None = None) -> float | None:
    path = resolve_dir(bridge_dir) / "hb.json"
    if not path.exists():
        return None
    age = time.time() - path.stat().st_mtime
    hb = _read_json(path)
    ts = hb.get("ts") if hb else None
    if isinstance(ts, (int, float)) and ts > 0:
        age = min(age, max(0.0, time.time() - float(ts)))
    return age


def status(bridge_dir: str | Path | None = None) -> dict[str, Any]:
    folder = resolve_dir(bridge_dir)
    age = heartbeat_age_s(folder)
    hb = read_heartbeat(folder)
    if age is None:
        state = "waiting"
    elif age <= HB_STALE_S:
        state = "connected"
    else:
        state = "stale"
    return {
        "state": state,
        "dir": str(folder),
        "age_s": None if age is None else round(age, 2),
        "stats": (hb or {}).get("stats"),
        "plugin": (hb or {}).get("plugin"),
        "pinned": (hb or {}).get("pinned") or "",
        "pinned_type": (hb or {}).get("pinned_type") or "",
    }


def _down_message(info: dict[str, Any]) -> str:
    state = info["state"]
    if state == "waiting":
        return (
            "Live View is not writing a heartbeat. Start the game, open Live View (F8), "
            "and Reset scripts after a Lua deploy."
        )
    return (
        "Live View heartbeat is stale. The game may be paused or the script reset. "
        "Alt-tab back in, or Reset scripts."
    )


def call(op: str, bridge_dir: str | Path | None = None, timeout_s: float = CALL_TIMEOUT_S, **args: Any) -> dict[str, Any]:
    folder = resolve_dir(bridge_dir)
    info = status(folder)
    if info["state"] != "connected":
        return {"ok": False, "op": op, "error": _down_message(info), "bridge": info}

    req_id = uuid.uuid4().hex
    req_path = folder / "req.json"
    res_path = folder / "res.json"
    payload = {"id": req_id, "op": op}
    payload.update(args)
    if res_path.exists():
        try:
            res_path.unlink()
        except OSError:
            pass
    _atomic_write(req_path, payload)

    deadline = time.time() + timeout_s
    while time.time() < deadline:
        res = _read_json(res_path)
        if res and res.get("id") == req_id:
            return res
        time.sleep(POLL_S)
    return {
        "ok": False,
        "op": op,
        "error": "Live View did not answer in time. Is the game in a loading screen?",
        "id": req_id,
    }
