import json
import threading
import time
from pathlib import Path

from backend.tools import bridge


def _write(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload), encoding="utf-8")


def test_atomic_write_overwrites(tmp_path: Path) -> None:
    path = tmp_path / "sidecar.json"
    bridge._atomic_write(path, {"n": 1})
    bridge._atomic_write(path, {"n": 2})
    assert json.loads(path.read_text(encoding="utf-8"))["n"] == 2


def test_status_waiting(tmp_path: Path) -> None:
    info = bridge.status(tmp_path)
    assert info["state"] == "waiting"
    assert info["stats"] is None


def test_status_connected(tmp_path: Path) -> None:
    _write(
        tmp_path / "hb.json",
        {"ok": True, "ts": time.time(), "plugin": True, "stats": {"total": 12}},
    )
    info = bridge.status(tmp_path)
    assert info["state"] == "connected"
    assert info["stats"]["total"] == 12


def test_call_without_heartbeat(tmp_path: Path) -> None:
    result = bridge.call("cache_stats", bridge_dir=tmp_path, timeout_s=0.2)
    assert result["ok"] is False
    assert "heartbeat" in result["error"]


def test_call_roundtrip(tmp_path: Path) -> None:
    _write(
        tmp_path / "hb.json",
        {"ok": True, "ts": time.time(), "plugin": True, "stats": {"total": 3}},
    )

    def lua() -> None:
        deadline = time.time() + 2
        req = None
        while time.time() < deadline:
            req = bridge._read_json(tmp_path / "req.json")
            if req and req.get("id"):
                break
            time.sleep(0.02)
        assert req is not None
        _write(
            tmp_path / "res.json",
            {
                "id": req["id"],
                "ok": True,
                "op": "cache_search",
                "needle": req.get("needle"),
                "count": 1,
                "rows": [{"path": "app.PlayerManager", "type": "app.PlayerManager", "kind": "singleton"}],
            },
        )

    worker = threading.Thread(target=lua, daemon=True)
    worker.start()
    result = bridge.call("cache_search", bridge_dir=tmp_path, needle="player", timeout_s=2)
    worker.join(timeout=2)
    assert result["ok"] is True
    assert result["count"] == 1
    assert result["rows"][0]["path"] == "app.PlayerManager"
