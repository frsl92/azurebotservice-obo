"""Environment-driven settings for the bot."""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    mcp_url: str
    mcp_scope: str
    azure_openai_endpoint: str
    azure_openai_deployment: str
    azure_openai_api_version: str
    azure_openai_api_key: str | None

    @classmethod
    def from_env(cls) -> "Settings":
        return cls(
            mcp_url=os.environ["MCP_URL"],
            mcp_scope=os.environ["MCP_SCOPE"],
            azure_openai_endpoint=os.environ["AZURE_OPENAI_ENDPOINT"],
            azure_openai_deployment=os.environ["AZURE_OPENAI_DEPLOYMENT"],
            azure_openai_api_version=os.environ.get("AZURE_OPENAI_API_VERSION", "2024-10-21"),
            # Optional for local dev; in Azure the container's managed identity is used.
            azure_openai_api_key=os.environ.get("AZURE_OPENAI_API_KEY") or None,
        )
