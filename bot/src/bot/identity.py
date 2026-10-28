"""Helpers for showing and comparing identities (display/diagnostics only, no trust decisions)."""

from __future__ import annotations

import base64
import json


def decode_claims_unverified(token: str) -> dict:
    """Decode a JWT payload without verifying it. The MCP server does the real validation."""
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload))
    except (IndexError, ValueError):
        return {}


def same_oid(a: str | None, b: str | None) -> bool:
    return bool(a) and bool(b) and a.lower() == b.lower()
