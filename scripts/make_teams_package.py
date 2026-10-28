"""Builds dist/teams-app.zip (manifest + icons) for sideloading the bot into Teams.

Inputs (env): BOT_APP_ID, BOT_FQDN
"""

import json
import os
import struct
import zipfile
import zlib
from pathlib import Path


def _png(width: int, height: int, rgba: tuple[int, int, int, int]) -> bytes:
    row = b"\x00" + bytes(rgba) * width
    raw = row * height

    def chunk(tag: bytes, data: bytes) -> bytes:
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


def build(bot_app_id: str, bot_fqdn: str, out_dir: Path) -> Path:
    app_name = os.environ.get("TEAMS_APP_NAME", "OBO Demo Agent")[:30]  # Teams limits the short name to 30 chars
    manifest = {
        "$schema": "https://developer.microsoft.com/json-schemas/teams/v1.22/MicrosoftTeams.schema.json",
        "manifestVersion": "1.22",
        "version": os.environ.get("TEAMS_APP_VERSION", "1.1.0"),
        "id": os.environ.get("TEAMS_MANIFEST_ID", bot_app_id),  # any GUID; a new one gives Teams a fresh app identity
        "developer": {
            "name": "OBO Demo",
            "websiteUrl": f"https://{bot_fqdn}",
            "privacyUrl": f"https://{bot_fqdn}",
            "termsOfUseUrl": f"https://{bot_fqdn}",
        },
        "name": {"short": app_name, "full": app_name},
        "description": {
            "short": "Shows Teams user identity flowing to a backend via on-behalf-of.",
            "full": "A LangGraph agent that calls an MCP server using an on-behalf-of token for the signed-in Teams user.",
        },
        "icons": {"color": "color.png", "outline": "outline.png"},
        "accentColor": "#0078D4",
        "bots": [
            {
                "botId": bot_app_id,
                # personal is required by M365 Copilot; bot SSO works in 1:1 and group chats but not in channels
                "scopes": ["personal", "groupChat"],
                "supportsFiles": False,
                "isNotificationOnly": False,
                "commandLists": [
                    {
                        "scopes": ["personal", "groupChat"],
                        "commands": [
                            {"title": "/whoami", "description": "Prove who the backend authenticated"},
                            {"title": "/signout", "description": "Forget my sign-in"},
                        ],
                    }
                ],
            }
        ],
        "copilotAgents": {"customEngineAgents": [{"type": "bot", "id": bot_app_id}]},
        "permissions": ["identity", "messageTeamMembers"],
        "validDomains": [bot_fqdn, "token.botframework.com"],
        "webApplicationInfo": {"id": bot_app_id, "resource": f"api://botid-{bot_app_id}"},
    }

    out_dir.mkdir(parents=True, exist_ok=True)
    target = out_dir / "teams-app.zip"
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("manifest.json", json.dumps(manifest, indent=2))
        z.writestr("color.png", _png(192, 192, (0, 120, 212, 255)))
        z.writestr("outline.png", _png(32, 32, (255, 255, 255, 255)))
    return target


if __name__ == "__main__":
    path = build(os.environ["BOT_APP_ID"], os.environ["BOT_FQDN"], Path("dist"))
    print(f"Teams app package written to {path.resolve()}")
