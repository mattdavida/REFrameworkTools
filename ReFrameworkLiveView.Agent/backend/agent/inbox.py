"""
Watch liveview_bridge/chat_req.json and stream answers to chat_out.json.

The Chat tab cannot HTTP. Same file drop as cache tools.
"""

from __future__ import annotations

import asyncio
import logging
import time
from collections.abc import AsyncIterator, Callable
from pathlib import Path
from typing import Any

from backend.agent.loop import stream_turn
from backend.tools import bridge

logger = logging.getLogger(__name__)

CHAT_REQ = "chat_req.json"
CHAT_OUT = "chat_out.json"
SIDECAR = "sidecar.json"

StreamFn = Callable[..., AsyncIterator[dict[str, Any]]]

_busy = False


def write_sidecar(folder: Path | None = None, busy: bool | None = None) -> None:
    dest = bridge.resolve_dir(folder)
    flag = _busy if busy is None else busy
    bridge._atomic_write(
        dest / SIDECAR,
        {"ok": True, "ts": int(time.time()), "busy": flag},
    )


def apply_event(acc: dict[str, Any], event: dict[str, Any]) -> dict[str, Any]:
    kind = event.get("type")
    if kind == "token":
        acc["text"] = (acc.get("text") or "") + (event.get("text") or "")
        acc["status"] = "streaming"
    elif kind == "tool":
        tools = list(acc.get("tools") or [])
        tools.append({"name": event.get("name") or "", "args": event.get("args") or {}})
        acc["tools"] = tools
        acc["status"] = "streaming"
    elif kind == "done":
        acc["status"] = "done"
    elif kind == "error":
        acc["status"] = "error"
        acc["error"] = event.get("message") or "error"
    return acc


async def handle_chat_req(
    req: dict[str, Any],
    folder: Path,
    stream: StreamFn = stream_turn,
) -> None:
    chat_id = str(req.get("id") or "")
    messages = req.get("messages") or []
    if not isinstance(messages, list):
        messages = []
    session = req.get("session")
    if not isinstance(session, dict):
        session = None
    acc: dict[str, Any] = {
        "id": chat_id,
        "status": "streaming",
        "text": "",
        "tools": [],
        "error": "",
    }
    bridge._atomic_write(folder / CHAT_OUT, acc)
    last = 0.0
    async for event in stream(messages, session):
        apply_event(acc, event)
        now = time.time()
        if event.get("type") != "token" or now - last >= 0.08:
            bridge._atomic_write(folder / CHAT_OUT, acc)
            last = now
    if acc.get("status") == "streaming":
        acc["status"] = "done"
    bridge._atomic_write(folder / CHAT_OUT, acc)


async def watch_sidecar() -> None:
    while True:
        try:
            write_sidecar()
        except Exception:
            logger.exception("sidecar heartbeat")
        await asyncio.sleep(1.0)


async def watch_inbox() -> None:
    global _busy
    last_id = ""
    while True:
        try:
            folder = bridge.resolve_dir()
            req = bridge._read_json(folder / CHAT_REQ)
            req_id = str((req or {}).get("id") or "")
            if req and req_id and req_id != last_id:
                last_id = req_id
                _busy = True
                write_sidecar(folder, busy=True)
                try:
                    await handle_chat_req(req, folder)
                finally:
                    _busy = False
                    write_sidecar(folder, busy=False)
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("chat inbox")
            _busy = False
        await asyncio.sleep(0.1)
