"""
Read-only MCP tools for Live View.

Mounted on the existing uvicorn app at /mcp.
Do not run this file as its own process.
"""

from __future__ import annotations

from contextlib import asynccontextmanager

from mcp.server.mcpserver import MCPServer

from backend.tools import ops

MCP_URL = "http://127.0.0.1:3002/mcp"


@asynccontextmanager
async def _idle_lifespan(_app):
    yield


def build_server() -> MCPServer:
    mcp = MCPServer("liveview")
    for fn in ops.READ_FNS:
        mcp.tool()(fn)
    return mcp


def build_http_app():
    """ASGI app + session manager. Parent lifespan must `async with manager.run()`."""
    mcp = build_server()
    http = mcp.streamable_http_app(
        streamable_http_path="/",
        stateless_http=True,
        json_response=True,
        host="127.0.0.1",
    )
    http.router.lifespan_context = _idle_lifespan
    manager = mcp._lowlevel_server._session_manager
    if manager is None:
        raise RuntimeError("MCP session manager was not created")
    return http, manager
