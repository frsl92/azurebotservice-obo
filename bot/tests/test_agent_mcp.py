"""End-to-end test of the agent <-> MCP path with a scripted model and a real in-process MCP server."""

import socket
import threading
import time

import jwt
import pytest
import uvicorn
from cryptography.hazmat.primitives.asymmetric import rsa
from langchain_core.language_models.chat_models import BaseChatModel
from langchain_core.messages import AIMessage
from langchain_core.outputs import ChatGeneration, ChatResult

from bot.agent import call_whoami, run_agent
from bot.config import Settings
from mcp_server.auth import AuthSettings, TokenValidator
from mcp_server.server import create_app

TENANT = "11111111-1111-1111-1111-111111111111"
MCP_ID = "22222222-2222-2222-2222-222222222222"
_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


class _Key:
    key = _KEY.public_key()


class _JwkClient:
    def get_signing_key_from_jwt(self, _token):
        return _Key()


def token_for(oid: str) -> str:
    now = int(time.time())
    claims = {
        "iss": f"https://login.microsoftonline.com/{TENANT}/v2.0", "aud": MCP_ID, "iat": now, "exp": now + 600,
        "oid": oid, "tid": TENANT, "preferred_username": f"{oid}@contoso.com", "name": oid, "scp": "access_as_user",
    }
    return jwt.encode(claims, _KEY, algorithm="RS256")


class ScriptedModel(BaseChatModel):
    """Calls the `whoami` tool once, then answers with whatever the tool returned."""

    @property
    def _llm_type(self) -> str:
        return "scripted"

    def bind_tools(self, tools, **_kwargs):
        return self

    def _generate(self, messages, stop=None, run_manager=None, **kwargs):
        last = messages[-1]
        if last.type == "tool":
            msg = AIMessage(content=f"Backend says: {last.content}")
        else:
            msg = AIMessage(content="", tool_calls=[{"name": "whoami", "args": {}, "id": "call_1"}])
        return ChatResult(generations=[ChatGeneration(message=msg)])


@pytest.fixture(scope="module")
def mcp_url():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    validator = TokenValidator(AuthSettings(TENANT, MCP_ID), jwk_client=_JwkClient())
    server = uvicorn.Server(uvicorn.Config(create_app(validator), host="127.0.0.1", port=port, log_level="warning"))
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()
    while not server.started:
        time.sleep(0.05)
    yield f"http://127.0.0.1:{port}/mcp"
    server.should_exit = True
    thread.join(timeout=5)


def settings_for(url: str) -> Settings:
    return Settings(url, f"api://{MCP_ID}/access_as_user", "https://unused", "unused", "2024-10-21", None)


@pytest.mark.parametrize("oid", ["oid-alice", "oid-bob"])
async def test_agent_reaches_mcp_as_the_token_user(mcp_url, oid):
    answer, results = await run_agent(ScriptedModel(), settings_for(mcp_url), "who am I?", token_for(oid))
    assert [r["oid"] for r in results] == [oid]
    assert oid in answer


async def test_direct_whoami(mcp_url):
    result = await call_whoami(settings_for(mcp_url), token_for("oid-carol"))
    assert result["oid"] == "oid-carol"


async def test_invalid_token_is_refused(mcp_url):
    with pytest.raises(BaseException):
        await call_whoami(settings_for(mcp_url), "not-a-jwt")
