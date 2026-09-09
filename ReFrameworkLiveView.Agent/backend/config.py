"""
Fail-fast environment. Same Azure vars as execution_agent.
Copy .env from that repo until this project has its own deploy.
"""

import os
from dotenv import load_dotenv

load_dotenv()


def _require(key: str) -> str:
    value = os.getenv(key)
    if not value:
        raise RuntimeError(
            f"Missing required environment variable: {key}\n"
            "Copy execution_agent/.env here, or fill .env.example."
        )
    return value


AZURE_OPENAI_API_KEY = _require("AZURE_OPENAI_API_KEY")
AZURE_OPENAI_ENDPOINT = _require("AZURE_OPENAI_ENDPOINT")
AZURE_OPENAI_API_VERSION = os.getenv("AZURE_OPENAI_API_VERSION", "2024-02-01")
AZURE_OPENAI_CHAT_DEPLOYMENT = _require("AZURE_OPENAI_CHAT_DEPLOYMENT")

API_PORT = int(os.getenv("API_PORT", "3002"))
ALLOWED_ORIGINS = os.getenv("ALLOWED_ORIGINS", "http://localhost:3000").split(",")

# Game install. Override with GAME_DIR or LIVEVIEW_BRIDGE_DIR.
GAME_DIR = os.getenv("GAME_DIR", r"D:\SteamLibrary\steamapps\common\OnimushaWotS")
BRIDGE_DIR = os.getenv(
    "LIVEVIEW_BRIDGE_DIR",
    os.path.join(GAME_DIR, "reframework", "data", "liveview_bridge"),
)
