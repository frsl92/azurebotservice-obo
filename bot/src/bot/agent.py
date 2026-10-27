"""LangGraph agent whose tools are served by the MCP server, called with the user's OBO token."""

from __future__ import annotations

import json
from typing import Annotated, Any, TypedDict

import httpx
from langchain_core.messages import AnyMessage, HumanMessage, SystemMessage, ToolMessage
from langchain_core.language_models.chat_models import BaseChatModel
from langchain_mcp_adapters.client import MultiServerMCPClient
from langgraph.graph import END, START, StateGraph
from langgraph.graph.message import add_messages
from langgraph.prebuilt import ToolNode, tools_condition
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client

from .config import Settings

SYSTEM_PROMPT = (
    "You are a demo assistant inside Microsoft Teams. You have a tool that reveals which "
    "user the backend service has authenticated for this conversation. Use it whenever the "
    "user asks who they are, who you are acting as, or anything about their identity. "
    "Report exactly what the tool returned; never guess identity details."
)


class AgentState(TypedDict):
    messages: Annotated[list[AnyMessage], add_messages]


def build_graph(llm: BaseChatModel, tools: list):
    llm_with_tools = llm.bind_tools(tools)

    async def call_model(state: AgentState) -> dict:
        response = await llm_with_tools.ainvoke([SystemMessage(SYSTEM_PROMPT), *state["messages"]])
        return {"messages": [response]}

    graph = StateGraph(AgentState)
    graph.add_node("agent", call_model)
    graph.add_node("tools", ToolNode(tools))
    graph.add_edge(START, "agent")
    graph.add_conditional_edges("agent", tools_condition, {"tools": "tools", END: END})
    graph.add_edge("tools", "agent")
    return graph.compile()


def _headers(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _is_v1_endpoint(endpoint: str) -> bool:
    return endpoint.rstrip("/").endswith("/openai/v1")


def build_llm(settings: Settings) -> BaseChatModel:
    if _is_v1_endpoint(settings.azure_openai_endpoint):
        # Azure OpenAI v1 API: plain OpenAI client, deployment name as the model, Entra token as the key.
        from langchain_openai import ChatOpenAI

        base_url = settings.azure_openai_endpoint.rstrip("/") + "/"
        if settings.azure_openai_api_key:
            return ChatOpenAI(base_url=base_url, model=settings.azure_openai_deployment, api_key=settings.azure_openai_api_key)

        from azure.identity.aio import DefaultAzureCredential, get_bearer_token_provider

        provider = get_bearer_token_provider(DefaultAzureCredential(), "https://cognitiveservices.azure.com/.default")
        return ChatOpenAI(base_url=base_url, model=settings.azure_openai_deployment, api_key=provider)

    from langchain_openai import AzureChatOpenAI

    common = dict(
        azure_endpoint=settings.azure_openai_endpoint,
        azure_deployment=settings.azure_openai_deployment,
        api_version=settings.azure_openai_api_version,
    )
    if settings.azure_openai_api_key:
        return AzureChatOpenAI(api_key=settings.azure_openai_api_key, **common)

    from azure.identity.aio import DefaultAzureCredential, get_bearer_token_provider

    provider = get_bearer_token_provider(DefaultAzureCredential(), "https://cognitiveservices.azure.com/.default")
    return AzureChatOpenAI(azure_ad_async_token_provider=provider, **common)


def _text(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(p.get("text", "") if isinstance(p, dict) else str(p) for p in content)
    return str(content)


async def run_agent(llm: BaseChatModel, settings: Settings, user_text: str, mcp_token: str) -> tuple[str, list[dict]]:
    """Run one turn. Returns the answer and the parsed JSON results of any MCP tool calls.

    The token is attached to the MCP transport only; the model never sees it.
    """
    client = MultiServerMCPClient(
        {"obo": {"transport": "streamable_http", "url": settings.mcp_url, "headers": _headers(mcp_token)}}
    )
    tools = await client.get_tools()
    result = await build_graph(llm, tools).ainvoke({"messages": [HumanMessage(user_text)]})

    tool_results: list[dict] = []
    for msg in result["messages"]:
        if isinstance(msg, ToolMessage):
            try:
                tool_results.append(json.loads(_text(msg.content)))
            except json.JSONDecodeError:
                pass
    return _text(result["messages"][-1].content), tool_results


async def call_whoami(settings: Settings, mcp_token: str) -> dict:
    """Call the MCP `whoami` tool directly (no LLM) so the proof is deterministic."""
    async with httpx.AsyncClient(headers=_headers(mcp_token), follow_redirects=True) as http_client:
        async with streamable_http_client(settings.mcp_url, http_client=http_client) as (read, write, _):
            async with ClientSession(read, write) as session:
                await session.initialize()
                result = await session.call_tool("whoami", {})
                return json.loads(result.content[0].text)
