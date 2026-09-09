"""
Stream a chat turn. Tools talk to Live View over the file bridge.

SSE event shapes:
  {"type": "token", "text": "..."}
  {"type": "tool", "name": "...", "args": {}}
  {"type": "done"}
  {"type": "error", "message": "..."}
"""

import asyncio
import json
from collections.abc import AsyncIterator
from typing import Any

from langchain_core.messages import AIMessage, HumanMessage, SystemMessage, ToolMessage

from backend.tools.liveview import LIVE_TOOLS
from backend.tools.llm_client import get_chat_llm

SYSTEM = """You are the Live View assistant for RE Engine reverse engineering.
You sit on a sidecar next to REFramework Live View. The user is usually in the DevTools Chat tab.
The game process never sees the API key.

Each turn includes a session snapshot: Finder search box, visible results, selected row, and the opened object.
"Opened" is whatever they last clicked. It may not be the object they asked about.

You drive Finder. You do not give the user homework.
- To look at a type or hop path: call open_object with that name (e.g. cHealthManager). That is a click. It returns live fields.
- cache_search / search_types only list names. They do not return field values. After a hit, you must open_object in the same turn.
- inspect_opened only reads the current opened object. If they asked about something else, open_object that instead.
- Never say pin, pinned, or "click that row". Never ask them to open it and come back. That is a failed turn.
- Do not invent hop paths, addresses, or field values. If open_object fails, say so.
- When the user asks to set, change, or test a value: open_object if needed, then set_opened_field for each named field, then inspect_opened to confirm. Do not refuse and do not tell them to type it in inspect.
- set_opened_field is the same Set button in Live View. Bool/number/string only, opened object only. No method calls, no VFX, no requestOniSenseStartEffect.
Onimusha stamina is Rikido. Purple souls fill OniChangeEnergy on cPlayerContextParam.
"""

MAX_ROUNDS = 6


def _session_message(session: dict[str, Any] | None) -> SystemMessage | None:
    if not session:
        return None
    return SystemMessage(
        content=(
            "Current Live View session (live, do not invent). "
            "session.opened is the last click, not necessarily the target. "
            "If you need another object, call open_object. Never ask the user to pin.\n"
            + json.dumps(session, ensure_ascii=False)
        )
    )


def _history_to_lc(messages: list[dict[str, Any]], session: dict[str, Any] | None = None) -> list:
    out: list = [SystemMessage(content=SYSTEM)]
    note = _session_message(session)
    if note:
        out.append(note)
    for item in messages:
        role = item.get("role")
        text = item.get("content") or ""
        if role == "user":
            out.append(HumanMessage(content=text))
        elif role == "assistant":
            out.append(AIMessage(content=text))
    return out


def _run_tool(name: str, args: dict[str, Any]) -> str:
    for fn in LIVE_TOOLS:
        if fn.name == name:
            return str(fn.invoke(args or {}))
    return f"Unknown tool: {name}"


async def stream_turn(
    messages: list[dict[str, Any]],
    session: dict[str, Any] | None = None,
) -> AsyncIterator[dict[str, Any]]:
    llm = get_chat_llm().bind_tools(LIVE_TOOLS)
    history = _history_to_lc(messages, session)
    try:
        for _ in range(MAX_ROUNDS):
            gathered = None
            async for chunk in llm.astream(history):
                if chunk.content:
                    yield {"type": "token", "text": chunk.content}
                gathered = chunk if gathered is None else gathered + chunk
            if gathered is None:
                break
            history.append(gathered)
            calls = getattr(gathered, "tool_calls", None) or []
            if not calls:
                break
            for call in calls:
                name = call.get("name") or ""
                args = call.get("args") or {}
                yield {"type": "tool", "name": name, "args": args}
                result = await asyncio.to_thread(_run_tool, name, args)
                history.append(
                    ToolMessage(content=result, tool_call_id=call.get("id") or name)
                )
        yield {"type": "done"}
    except Exception as exc:
        yield {"type": "error", "message": str(exc)}
