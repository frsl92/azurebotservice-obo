import json
import time

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from starlette.testclient import TestClient

from mcp_server.auth import AuthSettings, TokenValidator
from mcp_server.server import create_app

TENANT = "11111111-1111-1111-1111-111111111111"
CLIENT = "22222222-2222-2222-2222-222222222222"
ISSUER = f"https://login.microsoftonline.com/{TENANT}/v2.0"

_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
_OTHER_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


class _FakeSigningKey:
    def __init__(self, key):
        self.key = key


class _FakeJwkClient:
    def get_signing_key_from_jwt(self, _token):
        return _FakeSigningKey(_KEY.public_key())


def make_token(*, oid="aaaa-user-1", upn="alice@contoso.com", aud=CLIENT, scp="access_as_user", key=_KEY, **extra):
    now = int(time.time())
    claims = {
        "iss": ISSUER, "aud": aud, "iat": now, "exp": now + 600,
        "oid": oid, "tid": TENANT, "preferred_username": upn, "name": "Alice", "scp": scp,
        "azp": "bot-app-id", **extra,
    }
    return jwt.encode(claims, key, algorithm="RS256", headers={"kid": "test"})


@pytest.fixture()
def client():
    validator = TokenValidator(AuthSettings(TENANT, CLIENT), jwk_client=_FakeJwkClient())
    with TestClient(create_app(validator)) as c:
        yield c


def call_whoami(client, token=None):
    headers = {"Accept": "application/json, text/event-stream", "Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    body = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "whoami", "arguments": {}}}
    return client.post("/mcp", json=body, headers=headers)


def test_health_is_open(client):
    assert client.get("/healthz").text == "ok"


def test_no_token_rejected(client):
    assert call_whoami(client).status_code == 401


def test_bad_signature_rejected(client):
    assert call_whoami(client, make_token(key=_OTHER_KEY)).status_code == 401


def test_wrong_audience_rejected(client):
    assert call_whoami(client, make_token(aud="someone-else")).status_code == 401


def test_missing_scope_rejected(client):
    assert call_whoami(client, make_token(scp="other")).status_code == 401


@pytest.mark.parametrize("oid,upn", [("oid-alice", "alice@contoso.com"), ("oid-bob", "bob@contoso.com")])
def test_whoami_returns_token_identity(client, oid, upn):
    resp = call_whoami(client, make_token(oid=oid, upn=upn))
    assert resp.status_code == 200, resp.text
    result = json.loads(resp.json()["result"]["content"][0]["text"])
    assert result["oid"] == oid
    assert result["preferred_username"] == upn
    assert result["aud"] == CLIENT
