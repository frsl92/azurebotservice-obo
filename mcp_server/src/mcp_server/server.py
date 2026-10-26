"""MCP server whose tools reveal which Entra user is calling.

Every request must carry an Entra access token whose audience is this API. The
validated claims are what the tools return, so the answer is provably derived
from the token the caller presented, not from anything the caller claims.
"""

from __future__ import annotations

import logging
import os
from datetime import datetime, timezone

import uvicorn
from mcp.server.fastmcp import Context, FastMCP
from starlette.responses import JSONResponse, PlainTextResponse

from .auth import AuthError, AuthSettings, TokenValidator

logger = logging.getLogger("mcp_server")

# Claims surfaced to the caller. Chosen so a human can compare them to the Teams user.
_EXPOSED_CLAIMS = ("oid", "tid", "name", "preferred_username", "upn", "aud", "azp", "scp", "iat", "exp")

def _claims_from(ctx: Context) -> dict:
    request = ctx.request_context.request
    claims = request.scope.get("auth_claims") if request is not None else None
    if not claims:
        raise RuntimeError("no authenticated caller on this request")
    return claims


def whoami(ctx: Context) -> dict:
    """Return the identity of the user this request was authenticated as.

    The values come from the validated access token that was sent to this server.
    """
    claims = _claims_from(ctx)
    result = {k: claims[k] for k in _EXPOSED_CLAIMS if k in claims}
    result["server_time_utc"] = datetime.now(timezone.utc).isoformat()
    logger.info("whoami called by oid=%s upn=%s", result.get("oid"), result.get("preferred_username"))
    return result


def build_mcp() -> FastMCP:
    mcp = FastMCP("obo-demo-mcp", host="0.0.0.0", stateless_http=True, json_response=True)
    mcp.tool()(whoami)
    return mcp


class JwtAuthMiddleware:
    """Pure ASGI middleware: 401s anything without a valid bearer token."""

    def __init__(self, app, validator: TokenValidator):
        self.app = app
        self.validator = validator

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)

        if scope["path"] == "/healthz":
            return await PlainTextResponse("ok")(scope, receive, send)

        headers = dict(scope["headers"])
        auth = headers.get(b"authorization", b"").decode()
        scheme, _, token = auth.partition(" ")
        if scheme.lower() != "bearer" or not token:
            return await self._deny(scope, receive, send, "missing bearer token")

        try:
            scope["auth_claims"] = await self.validator.validate(token)
        except AuthError as exc:
            logger.warning("rejected request: %s", exc)
            return await self._deny(scope, receive, send, str(exc))

        return await self.app(scope, receive, send)

    @staticmethod
    async def _deny(scope, receive, send, detail: str):
        response = JSONResponse(
            {"error": "unauthorized", "detail": detail},
            status_code=401,
            headers={"WWW-Authenticate": 'Bearer realm="obo-demo-mcp"'},
        )
        await response(scope, receive, send)


def create_app(validator: TokenValidator | None = None):
    validator = validator or TokenValidator(AuthSettings.from_env())
    return JwtAuthMiddleware(build_mcp().streamable_http_app(), validator)


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
    port = int(os.environ.get("PORT", "8000"))
    uvicorn.run(create_app(), host="0.0.0.0", port=port)


if __name__ == "__main__":
    main()
