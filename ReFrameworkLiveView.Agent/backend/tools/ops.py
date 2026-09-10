"""
Plain Live View ops. Chat and MCP both call these.

No Azure. No ImGui. File-drop only.
"""

from __future__ import annotations

import json

from backend.tools import bridge


def _dump(payload: dict) -> str:
    return json.dumps(payload, ensure_ascii=False)


def bridge_status() -> str:
    """Heartbeat only. Does not write req.json. Use this first if the game looks down."""
    return _dump(bridge.status())


def ui_state() -> str:
    """Finder session: search box, opened object, selected row, visible results."""
    return _dump(bridge.call("ui_state"))


def cache_stats() -> str:
    """Live cache counts: total, hops, singletons, scene."""
    return _dump(bridge.call("cache_stats"))


def cache_search(needle: str, cap: int = 40) -> str:
    """List matching live-cache rows (up to cap, default 40). Names only — no field values. Then open_object."""
    return _dump(bridge.call("cache_search", needle=needle, cap=cap))


def search_types(needle: str, cap: int = 40) -> str:
    """Search TDB type names via ref_live.dll (same as Include types, up to cap results)."""
    return _dump(bridge.call("search_types", needle=needle, cap=cap))


def inspect_opened() -> str:
    """Live fields on the opened object. If you need a different type, open_object first."""
    return _dump(bridge.call("inspect_pinned"))


def open_object(needle: str) -> str:
    """Open a cache row the same way a Finder click does, then return its fields."""
    return _dump(bridge.call("open_object", needle=needle))


def set_finder(needle: str) -> str:
    """Type into the Finder Search box and list matching live-cache rows."""
    return _dump(bridge.call("set_finder", needle=needle))


def set_opened_field(name: str, value: str) -> str:
    """Set a bool/number/string field on the opened object. Same as inspect Set."""
    return _dump(bridge.call("set_opened_field", name=name, value=value))


READ_FNS = (
    bridge_status,
    ui_state,
    cache_stats,
    cache_search,
    search_types,
    inspect_opened,
    open_object,
)
