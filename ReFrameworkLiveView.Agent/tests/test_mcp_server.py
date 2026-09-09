from backend.mcp_server import build_http_app, build_server
from backend.tools import ops


def test_read_ops_exclude_writes() -> None:
    names = {fn.__name__ for fn in ops.READ_FNS}
    assert "set_opened_field" not in names
    assert "set_finder" not in names
    assert "ui_state" in names
    assert "open_object" in names


def test_bridge_status_uses_status(monkeypatch) -> None:
    monkeypatch.setattr(ops.bridge, "status", lambda: {"state": "connected", "dir": "x"})
    payload = ops.bridge_status()
    assert '"state": "connected"' in payload


def test_cache_search_forwards_needle(monkeypatch) -> None:
    seen = {}

    def fake_call(op, **args):
        seen["op"] = op
        seen.update(args)
        return {"ok": True, "op": op, "needle": args.get("needle"), "rows": []}

    monkeypatch.setattr(ops.bridge, "call", fake_call)
    payload = ops.cache_search("Health")
    assert seen["op"] == "cache_search"
    assert seen["needle"] == "Health"
    assert "Health" in payload


def test_build_server_registers_read_tools() -> None:
    server = build_server()
    names = {tool.name for tool in server._tool_manager.list_tools()}
    assert names == {fn.__name__ for fn in ops.READ_FNS}
    assert "set_opened_field" not in names


def test_inspect_opened_uses_inspect_pinned(monkeypatch) -> None:
    seen = {}

    def fake_call(op, **args):
        seen["op"] = op
        return {"ok": True, "op": op, "fields": []}

    monkeypatch.setattr(ops.bridge, "call", fake_call)
    ops.inspect_opened()
    assert seen["op"] == "inspect_pinned"


def test_http_app_has_session_manager() -> None:
    http, manager = build_http_app()
    assert manager is not None
    assert http is not None
