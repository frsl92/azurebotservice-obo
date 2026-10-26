# Teams bot + LangGraph agent + On-Behalf-Of (OBO) demo

A minimal demo showing that a **LangGraph agent running behind a Teams bot** can call a
backend **MCP server as the signed-in Teams user**, using Azure Bot Service OAuth/SSO and the
Microsoft 365 Agents SDK OBO exchange. No Foundry features are used (only an existing Azure
OpenAI chat deployment).

```
Teams user ──SSO──► Azure Bot Service ──► Bot (Container App)            MCP server (Container App)
                    OAuth connection      Agents SDK + LangGraph  ─OBO─►  validates JWT, `whoami` tool
                    (Entra v2)            token aud = bot API           token aud = api://<mcp app id>
```

## How the identity proof works

1. In Teams, the user is signed in with SSO. The Bot Service OAuth connection (`mcp_sso`)
   hands the bot a token for the **bot's own API** (`api://<bot-fqdn>/<bot app id>`).
2. The Agents SDK performs the MSAL **OBO exchange** with the bot app's credential to get a
   token for the **MCP API** (`api://<mcp app id>/access_as_user`).
3. The agent calls the MCP server with that token as `Authorization: Bearer`. The token never
   reaches the LLM.
4. The MCP server validates signature, issuer, audience and scope; its `whoami` tool returns
   the `oid`, user name and `tid` from the token.
5. `/whoami` in the bot compares the Teams `aadObjectId` (from the activity) with the `oid`
   the MCP server saw, and prints **MATCH** or **MISMATCH**.

## Layout

| Path | Purpose |
|---|---|
| `bot/` | Teams bot (Agents SDK, aiohttp) + LangGraph agent |
| `mcp_server/` | MCP server (FastMCP) with JWT validation and `whoami` |
| `infra/` | Bicep: Container Apps, ACR, Azure Bot, Teams channel, OAuth connection, RBAC |
| `infra/hooks/` | azd hooks that create the Entra apps and the Teams package |
| `scripts/make_teams_package.py` | Builds `dist/teams-app.zip` |

Python is managed with **uv** (workspace); `pyproject.toml` sets the `msiopypi` index as default.

## Prerequisites

- Azure CLI, Azure Developer CLI (`azd`), PowerShell 7 (`pwsh`), uv.
- Permission to create Entra app registrations (and grant admin consent) and
  Contributor/Owner on the subscription.
- An existing Azure OpenAI chat deployment.

## Deploy

```powershell
azd env new obo-demo
azd env set OPENAI_ENDPOINT https://<account>.openai.azure.com
azd env set OPENAI_DEPLOYMENT <chat deployment name>
azd env set OPENAI_ACCOUNT_NAME <account name>
azd env set OPENAI_RESOURCE_GROUP <account resource group>
azd up
```

- `preprovision` creates/updates the two Entra apps (MCP API and bot), exposes the
  `access_as_user` scopes, pre-authorizes the Teams clients and the bot, and stores a bot client
  secret in the azd environment.
- Bicep deploys the infra; `postprovision` sets the bot identifier URI to
  `api://<bot-fqdn>/<bot app id>` and writes `dist/teams-app.zip`.
- Sideload `dist/teams-app.zip` in Teams (Apps → Manage your apps → Upload a custom app).

## Demo script

1. Open the bot in Teams; the first message may trigger a one-time consent/sign-in.
2. Send `/whoami`. Expect the Teams identity, the identity the MCP server saw, and **MATCH**.
3. Ask "Who am I according to the backend?" — the LangGraph agent calls the MCP `whoami` tool
   with your OBO token.
4. Repeat with a second user: each sees their own identity. `/signout` clears the cached token.

## Run locally

```powershell
uv sync --all-packages
uv run --all-packages pytest -q
# MCP server
$env:TENANT_ID='<tenant>'; $env:MCP_CLIENT_ID='<mcp app id>'; uv run --package obo-mcp-server python -m mcp_server.server
# Bot: copy bot/.env.example to bot/.env, fill it in, expose port 3978 with a dev tunnel
uv run --package obo-bot python -m bot
```

If uv reports 404 for package metadata from the feed, retry; the feed warms its cache on first request.

## Notes and limitations

- Single tenant; public ingress on both apps; the MCP server is protected by JWT validation only.
- The bot uses a client secret for the OBO exchange; a federated credential with the managed
  identity would be the production upgrade.
- The LLM is reached with the bot's managed identity (Cognitive Services OpenAI User) or, locally,
  `AZURE_OPENAI_API_KEY`.
- Infra, hooks and Docker images were only compile/syntax-checked and exercised locally (Docker
  daemon wasn't running); validate against your tenant before relying on them.