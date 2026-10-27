"""Teams bot host: Microsoft 365 Agents SDK + Azure Bot Service OAuth/OBO + LangGraph agent."""

from __future__ import annotations

import logging
import re
from os import environ

from aiohttp.web import Application, Request, Response, json_response, middleware, run_app
from dotenv import load_dotenv
from microsoft_agents.activity import load_configuration_from_env
from microsoft_agents.authentication.msal import MsalConnectionManager
from microsoft_agents.hosting.aiohttp import CloudAdapter, jwt_authorization_middleware, start_agent_process
from microsoft_agents.hosting.core import (
    AgentApplication,
    Authorization,
    MemoryStorage,
    TurnContext,
    TurnState,
)

from .agent import build_llm, call_whoami, run_agent
from .config import Settings
from .identity import decode_claims_unverified, same_oid

load_dotenv()
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("bot")

HANDLER = "MCP"  # matches AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__MCP__...

sdk_config = load_configuration_from_env(environ)
settings = Settings.from_env()
llm = build_llm(settings)

STORAGE = MemoryStorage()
CONNECTION_MANAGER = MsalConnectionManager(**sdk_config)
ADAPTER = CloudAdapter(connection_manager=CONNECTION_MANAGER)
AUTHORIZATION = Authorization(STORAGE, CONNECTION_MANAGER, **sdk_config)
AGENT_APP = AgentApplication[TurnState](
    storage=STORAGE, adapter=ADAPTER, authorization=AUTHORIZATION, **sdk_config
)

HELP = (
    "I'm a demo agent. Ask me anything, e.g. **who am I?** and I'll use a backend MCP tool "
    "that sees *your* identity through an on-behalf-of token.\n\n"
    "- `/whoami` - deterministic proof: Teams identity vs. token vs. what the backend authenticated\n"
    "- `/signout` - forget your sign-in"
)


async def _mcp_token(context: TurnContext) -> str | None:
    """OBO exchange: Bot Service user token (aud=bot app) -> token for the MCP API (aud=MCP app)."""
    response = await AGENT_APP.auth.exchange_token(context, [settings.mcp_scope], HANDLER)
    return response.token or None


def _teams_identity(context: TurnContext) -> tuple[str | None, str | None]:
    sender = context.activity.from_property
    return (getattr(sender, "aad_object_id", None), getattr(sender, "name", None))


@AGENT_APP.conversation_update("membersAdded")
async def on_members_added(context: TurnContext, _state: TurnState) -> None:
    await context.send_activity(f"Hi! {HELP}")


@AGENT_APP.message(re.compile(r"^/signout$", re.IGNORECASE))
async def on_signout(context: TurnContext, _state: TurnState) -> None:
    await AGENT_APP.auth.sign_out(context, HANDLER)
    await context.send_activity("Signed out. Send another message to sign in again.")


@AGENT_APP.message(re.compile(r"^/(help|\?)$", re.IGNORECASE))
async def on_help(context: TurnContext, _state: TurnState) -> None:
    await context.send_activity(HELP)


@AGENT_APP.message(re.compile(r"^/whoami$", re.IGNORECASE), auth_handlers=[HANDLER])
async def on_whoami(context: TurnContext, _state: TurnState) -> None:
    token = await _mcp_token(context)
    if not token:
        await context.send_activity("I couldn't get a token for the backend. Please try signing in again.")
        return

    teams_oid, teams_name = _teams_identity(context)
    claims = decode_claims_unverified(token)
    backend = await call_whoami(settings, token)

    matches = same_oid(teams_oid, claims.get("oid")) and same_oid(teams_oid, backend.get("oid"))
    verdict = "✅ **Match** - the backend authenticated the same user who is chatting in Teams." if matches else (
        "❌ **Mismatch** - the identities differ."
    )
    await context.send_activity(
        "**1. Teams says the sender is**\n\n"
        f"- name: {teams_name}\n- aadObjectId: `{teams_oid}`\n\n"
        "**2. Token the bot sent to the backend (decoded, not verified here)**\n\n"
        f"- aud: `{claims.get('aud')}`\n- scp: `{claims.get('scp')}`\n- azp: `{claims.get('azp')}`\n"
        f"- oid: `{claims.get('oid')}`\n\n"
        "**3. Backend (MCP server) validated the token and says**\n\n"
        f"- name: {backend.get('name')}\n- upn: {backend.get('preferred_username')}\n"
        f"- oid: `{backend.get('oid')}`\n\n"
        f"{verdict}"
    )


@AGENT_APP.message(re.compile(r".+", re.DOTALL), auth_handlers=[HANDLER])
async def on_message(context: TurnContext, _state: TurnState) -> None:
    token = await _mcp_token(context)
    if not token:
        await context.send_activity("I couldn't get a token for the backend. Please try signing in again.")
        return

    answer, tool_results = await run_agent(llm, settings, context.activity.text or "", token)

    note = ""
    teams_oid, _ = _teams_identity(context)
    for result in tool_results:
        if "oid" in result:
            ok = same_oid(teams_oid, result["oid"])
            note = (
                f"\n\n---\n*Backend authenticated oid `{result['oid']}` - "
                f"{'matches' if ok else 'DOES NOT match'} your Teams identity.*"
            )
    await context.send_activity(answer + note)


@AGENT_APP.error
async def on_error(context: TurnContext, error: Exception) -> None:
    logger.exception("turn failed: %s", error)
    await context.send_activity("Sorry, something went wrong handling that message.")


async def entry_point(request: Request) -> Response:
    try:
        body = await request.json()
        if body.get("type") == "invoke":
            name = body.get("name")
            # Only sign-in failures carry non-secret details; tokenExchange values hold the SSO token.
            detail = body.get("value") if name == "signin/failure" else None
            logger.info("invoke activity: name=%s detail=%s", name, detail)
    except Exception:  # logging must never break the turn
        pass
    return await start_agent_process(request, request.app["agent_app"], request.app["adapter"])


async def health(_request: Request) -> Response:
    return json_response({"status": "ok"})


@middleware
async def auth_except_health(request: Request, handler):
    if request.path == "/healthz":
        return await handler(request)
    return await jwt_authorization_middleware(request, handler)


def create_app() -> Application:
    app = Application(middlewares=[auth_except_health])
    app.router.add_post("/api/messages", entry_point)
    app.router.add_get("/healthz", health)
    app["agent_configuration"] = CONNECTION_MANAGER.get_default_connection_configuration()
    app["agent_app"] = AGENT_APP
    app["adapter"] = ADAPTER
    return app


def main() -> None:
    run_app(create_app(), host="0.0.0.0", port=int(environ.get("PORT", "3978")))


if __name__ == "__main__":
    main()
