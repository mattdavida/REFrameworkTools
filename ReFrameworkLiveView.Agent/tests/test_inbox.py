import asyncio
import json
from pathlib import Path

from backend.agent import inbox


def test_handle_chat_req_writes_out(tmp_path: Path) -> None:
    seen = {}

    async def fake_stream(_messages, session=None):
        seen["session"] = session
        yield {"type": "token", "text": "Hello"}
        yield {"type": "tool", "name": "cache_stats", "args": {}}
        yield {"type": "token", "text": " world"}
        yield {"type": "done"}

    asyncio.run(
        inbox.handle_chat_req(
            {
                "id": "t1",
                "messages": [{"role": "user", "content": "hi"}],
                "session": {"filter": "health", "opened": {"path": "app.cHealthManager"}},
            },
            tmp_path,
            stream=fake_stream,
        )
    )
    assert seen["session"]["filter"] == "health"
    out = json.loads((tmp_path / "chat_out.json").read_text(encoding="utf-8"))
    assert out["id"] == "t1"
    assert out["status"] == "done"
    assert out["text"] == "Hello world"
    assert out["tools"][0]["name"] == "cache_stats"


def test_apply_event_error() -> None:
    acc = {"text": "", "status": "streaming", "tools": []}
    inbox.apply_event(acc, {"type": "error", "message": "boom"})
    assert acc["status"] == "error"
    assert acc["error"] == "boom"
