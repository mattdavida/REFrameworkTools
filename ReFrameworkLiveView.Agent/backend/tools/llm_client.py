"""Azure OpenAI factory — credentials loaded lazily so the CLI works without .env."""

from langchain_openai import AzureChatOpenAI

from backend.config import require_azure


def get_chat_llm(temperature: float = 0.2) -> AzureChatOpenAI:
    cfg = require_azure()
    return AzureChatOpenAI(
        azure_endpoint=cfg["endpoint"],
        azure_deployment=cfg["deployment"],
        api_key=cfg["api_key"],
        api_version=cfg["api_version"],
        temperature=temperature,
    )
