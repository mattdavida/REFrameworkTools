"""
Environment config. Non-Azure values are read at import time (safe for CLI / MCP).
Azure credentials are read lazily via require_azure() — only when the LLM is called.
This means  liveview-agent start / stop / isup  work without a .env set.
"""

import os
from dotenv import load_dotenv

load_dotenv()

# ── Safe at import time (no Azure keys needed) ────────────────────────────────

AZURE_OPENAI_API_VERSION = os.getenv("AZURE_OPENAI_API_VERSION", "2024-02-01")
API_PORT = int(os.getenv("API_PORT", "3002"))
ALLOWED_ORIGINS = os.getenv("ALLOWED_ORIGINS", "http://localhost:3000").split(",")

# Game install. Override with GAME_DIR or LIVEVIEW_BRIDGE_DIR.
# These are empty strings when unset so bridge.resolve_dir() handles the missing-config case.
GAME_DIR = os.getenv("GAME_DIR", "")
BRIDGE_DIR = os.getenv("LIVEVIEW_BRIDGE_DIR", "")


# ── Lazy Azure credentials (call only when the LLM is needed) ─────────────────

def _require(key: str) -> str:
    value = os.getenv(key)
    if not value:
        raise RuntimeError(
            f"Missing required environment variable: {key}\n"
            "Copy .env.example to .env and fill in your Azure OpenAI credentials."
        )
    return value


def require_azure() -> dict[str, str]:
    """Return Azure OpenAI credentials. Raises RuntimeError if any var is missing."""
    return {
        "api_key": _require("AZURE_OPENAI_API_KEY"),
        "endpoint": _require("AZURE_OPENAI_ENDPOINT"),
        "deployment": _require("AZURE_OPENAI_CHAT_DEPLOYMENT"),
        "api_version": AZURE_OPENAI_API_VERSION,
    }
