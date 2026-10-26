"""Entra ID access-token validation for the MCP server."""

from __future__ import annotations

import asyncio
import os
from dataclasses import dataclass

import jwt
from jwt import PyJWKClient


class AuthError(Exception):
    pass


@dataclass(frozen=True)
class AuthSettings:
    tenant_id: str
    client_id: str
    required_scope: str = "access_as_user"

    @classmethod
    def from_env(cls) -> "AuthSettings":
        return cls(
            tenant_id=os.environ["TENANT_ID"],
            client_id=os.environ["MCP_CLIENT_ID"],
            required_scope=os.environ.get("REQUIRED_SCOPE", "access_as_user"),
        )

    @property
    def issuer(self) -> str:
        return f"https://login.microsoftonline.com/{self.tenant_id}/v2.0"

    @property
    def jwks_uri(self) -> str:
        return f"https://login.microsoftonline.com/{self.tenant_id}/discovery/v2.0/keys"

    @property
    def audiences(self) -> list[str]:
        # v2 tokens carry the bare client id; v1 tokens carry the App ID URI.
        return [self.client_id, f"api://{self.client_id}"]


class TokenValidator:
    def __init__(self, settings: AuthSettings, jwk_client: PyJWKClient | None = None):
        self._settings = settings
        self._jwk_client = jwk_client or PyJWKClient(settings.jwks_uri, cache_keys=True)

    def _validate_sync(self, token: str) -> dict:
        s = self._settings
        try:
            signing_key = self._jwk_client.get_signing_key_from_jwt(token)
            claims = jwt.decode(
                token,
                signing_key.key,
                algorithms=["RS256"],
                audience=s.audiences,
                issuer=s.issuer,
                options={"require": ["exp", "iss", "aud"]},
            )
        except jwt.PyJWTError as exc:
            raise AuthError(f"invalid token: {exc}") from exc

        scopes = str(claims.get("scp", "")).split()
        if s.required_scope not in scopes:
            raise AuthError(f"missing required scope '{s.required_scope}'")
        if not claims.get("oid"):
            raise AuthError("token has no 'oid' claim (not a user token)")
        return claims

    async def validate(self, token: str) -> dict:
        return await asyncio.to_thread(self._validate_sync, token)
