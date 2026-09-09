"""
Chat tools. Same ops as MCP, plus Set / set_finder.
"""

from langchain_core.tools import tool

from backend.tools import ops

ui_state = tool(ops.ui_state)
set_finder = tool(ops.set_finder)
open_object = tool(ops.open_object)
cache_search = tool(ops.cache_search)
cache_stats = tool(ops.cache_stats)
search_types = tool(ops.search_types)
inspect_opened = tool(ops.inspect_opened)
set_opened_field = tool(ops.set_opened_field)

LIVE_TOOLS = [
    ui_state,
    set_finder,
    open_object,
    cache_search,
    cache_stats,
    search_types,
    inspect_opened,
    set_opened_field,
]
