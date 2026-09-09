"""Azure OpenAI factory — same shape as execution_agent."""

from langchain_openai import AzureChatOpenAI

from backend.config import (
    AZURE_OPENAI_API_KEY,
    AZURE_OPENAI_ENDPOINT,
    AZURE_OPENAI_API_VERSION,
    AZURE_OPENAI_CHAT_DEPLOYMENT,
)


def get_chat_llm(temperature: float = 0.2) -> AzureChatOpenAI:
    return AzureChatOpenAI(
        azure_endpoint=AZURE_OPENAI_ENDPOINT,
        azure_deployment=AZURE_OPENAI_CHAT_DEPLOYMENT,
        api_key=AZURE_OPENAI_API_KEY,
        api_version=AZURE_OPENAI_API_VERSION,
        temperature=temperature,
    )
