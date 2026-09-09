"""
Live View sidecar. One process on 3002: Chat, inbox, and Cursor MCP.

    uvicorn backend.main:app --reload --port 3002

GET  /api/health
POST /api/chat
     /mcp          — Cursor MCP (same process)
"""

from __future__ import annotations

import asyncio
import json
import logging
from contextlib import asynccontextmanager, suppress
from typing import Literal

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from backend.agent.inbox import watch_inbox, watch_sidecar
from backend.agent.loop import stream_turn
from backend.config import ALLOWED_ORIGINS
from backend.mcp_server import MCP_URL, build_http_app
from backend.tools import bridge

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


class ChatMessage(BaseModel):
    role: Literal["user", "assistant"]
    content: str


class ChatBody(BaseModel):
    messages: list[ChatMessage] = Field(min_length=1)


def create_app() -> FastAPI:
    mcp_http, mcp_sessions = build_http_app()

    @asynccontextmanager
    async def lifespan(_app: FastAPI):
        inbox = asyncio.create_task(watch_inbox())
        pulse = asyncio.create_task(watch_sidecar())
        async with mcp_sessions.run():
            logger.info("MCP at %s", MCP_URL)
            try:
                yield
            finally:
                inbox.cancel()
                pulse.cancel()
                with suppress(asyncio.CancelledError):
                    await inbox
                with suppress(asyncio.CancelledError):
                    await pulse

    application = FastAPI(
        title="Live View Agent",
        description="Local sidecar for REFramework Live View. Chat + MCP on one port.",
        version="0.1.0",
        lifespan=lifespan,
    )
    application.add_middleware(
        CORSMiddleware,
        allow_origins=list(
            {
                *ALLOWED_ORIGINS,
                "http://127.0.0.1:3002",
                "http://localhost:3002",
            }
        ),
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )
    application.mount("/mcp", mcp_http)

    @application.get("/api/health")
    async def health() -> dict:
        info = bridge.status()
        return {
            "status": "ok",
            "bridge": info["state"],
            "bridge_dir": info["dir"],
            "age_s": info["age_s"],
            "stats": info["stats"],
            "plugin": info["plugin"],
            "pinned": info["pinned"],
            "product": "liveview-agent",
            "mcp": MCP_URL,
        }

    @application.post("/api/chat")
    async def chat(body: ChatBody) -> StreamingResponse:
        payload = [m.model_dump() for m in body.messages]

        async def events():
            hb = bridge.read_heartbeat()
            async for event in stream_turn(payload, session=hb):
                yield f"data: {json.dumps(event)}\n\n"

        return StreamingResponse(events(), media_type="text/event-stream")

    return application


app = create_app()
