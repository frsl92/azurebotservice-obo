# Deployment guide

Deploys the Teams bot, the MCP server, the Azure Bot and the Entra apps into **your** tenant and subscription with
the Azure Developer CLI (`azd`). Architecture and resource list: [ARCHITECTURE.md](ARCHITECTURE.md).

## 1. Prerequisites

| Need | Why |
|---|---|
| Azure subscription with **Owner** (or Contributor + User Access Administrator) | Bicep creates role assignments |
| Entra permission to **create app registrations**, ideally also to grant admin consent | `preprovision` creates two apps |
| An existing **Azure OpenAI chat deployment** and permission to assign roles on that account | The agent's LLM |
| A Microsoft 365 tenant where you can **sideload custom Teams apps** (Teams admin center -> Setup policies -> *Upload custom apps*) | To install the bot |
| Azure CLI, `azd`, **PowerShell 7 (`pwsh`)**, **uv**, Git | Hooks and builds |

Docker is **not** needed locally; images are built remotely in ACR.

> Package index: the root `pyproject.toml` sets `msiopypi` as the default uv index. Outside that network, change the
> `[[tool.uv.index]]` URL, the two `pip install uv --index-url` lines in `bot/Dockerfile` and
> `mcp_server/Dockerfile`, then run `uv lock`.

## 2. Sign in

```powershell
az login --tenant <tenant-id>
az account set --subscription <subscription-id>
azd auth login --tenant-id <tenant-id>
```

## 3. Create the environment and set the LLM inputs

```powershell
git clone https://github.com/frsl92/azurebotservice-obo.git
cd azurebotservice-obo
azd env new obo-demo
azd env set AZURE_SUBSCRIPTION_ID <subscription-id>
azd env set AZURE_LOCATION <region, e.g. swedencentral>

azd env set OPENAI_ENDPOINT        https://<account>.openai.azure.com/openai/v1   # the v1 form (or the plain account URL)
azd env set OPENAI_DEPLOYMENT      <chat deployment name>
azd env set OPENAI_ACCOUNT_NAME    <account name>
azd env set OPENAI_RESOURCE_GROUP  <resource group of the account>
```

## 4. Deploy

azd reads the Bicep parameters before it runs hooks, so create the Entra apps first. This sets `TENANT_ID`,
`BOT_APP_ID`, `MCP_APP_ID` and `BOT_CLIENT_SECRET`; otherwise `azd up` prompts for `botAppId`. It is safe to re-run.

```powershell
azd hooks run preprovision
azd up
```

In order:

1. **preprovision** creates/updates `obo-demo-bot-<env>` and `obo-demo-mcp-<env>`, exposes the scopes,
   pre-authorizes clients, tries admin consent, creates a bot client secret (kept in the azd env) and records
   `TENANT_ID`, `BOT_APP_ID`, `MCP_APP_ID`.
2. **provision** creates the Azure resources.
3. **deploy** remote-builds the `bot` and `mcp` images in ACR and updates both Container Apps.
4. **postprovision** writes `dist\teams-app.zip` (the bot App ID URI `api://botid-<bot-app-id>` was already set by preprovision).

## 5. Check the backend before Teams

```powershell
$mcp = azd env get-value MCP_FQDN
$bot = azd env get-value BOT_FQDN
curl.exe -s -o NUL -w "%{http_code}`n" https://$mcp/healthz      # 200
curl.exe -s -o NUL -w "%{http_code}`n" -X POST https://$mcp/mcp -d "{}" -H "Content-Type: application/json"   # 401
curl.exe -s -o NUL -w "%{http_code}`n" https://$bot/healthz      # 200
```

## 6. Install in Teams

Teams -> **Apps** -> **Manage your apps** -> **Upload an app** -> **Upload a custom app** -> `dist\teams-app.zip`, then
open the app and chat.

The same package also works in other surfaces:

- **Group chats**: the manifest enables the `groupChat` scope. Add the app to a group chat and `@mention` it. Each sender signs in
  separately, and the consent card is shown only to the person who mentions the bot first. Bot SSO is not supported in channels,
  so the `team` scope is intentionally omitted. `/whoami` prints claims, so use it only in chats you are happy to share them with.
- **Microsoft 365 Copilot**: the manifest declares the bot as a custom engine agent (`copilotAgents.customEngineAgents`, manifest
  1.22). After installing, open Microsoft 365 Copilot (Teams or m365.cloud.microsoft) and pick the agent from the agent list. The
  Microsoft 365 and Outlook client IDs are pre-authorized on the bot app by preprovision. Allow a few minutes for it to appear.

## 7. Run the demo

1. Send `/whoami`. Expect your Teams name and `aadObjectId`, the claims of the OBO token (`aud`, `scp`, `azp`, `oid`),
   what the MCP server reported, and **Match**.
2. Ask "Who am I according to the backend?" to see the LangGraph agent call the `whoami` tool.
3. Have a second user install the app and repeat: each sees their own `oid`.
4. Portal -> Container App `ca-mcp-*` -> Log stream shows `whoami called by oid=...`.
5. `/signout` clears the stored token; the next message signs in again.

## 8. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `preprovision` fails with insufficient privileges | You cannot create apps. Ask an admin to create apps named `obo-demo-bot-<env>` / `obo-demo-mcp-<env>` (the script reuses apps by display name) and re-run, or run `azd up` as an admin once |
| `azd up` asks for the `botAppId` parameter | The Entra apps do not exist yet. Cancel and run `azd hooks run preprovision`, then `azd up` |
| Sign-in card instead of silent SSO | Bot App ID URI differs from the connection's Token Exchange URL, or the Teams client IDs are not pre-authorized. Re-run `azd provision`; check the bot app's *Expose an API* blade |
| Setting the identifier URI fails | Tenant app-management policy restricts `api://` URIs; adjust the policy |
| AADSTS65001 (consent) during OBO | `az ad app permission grant --id <BOT_APP_ID> --api <MCP_APP_ID> --scope access_as_user` |
| MCP returns 401 with a token | Check `aud` (`<MCP_APP_ID>` or `api://<MCP_APP_ID>`), `scp`, token v2, `TENANT_ID` |
| Bot returns 401 on `/api/messages` | Bot app id / secret / tenant env vars mismatch on the Container App |
| LLM 401/403 | The bot Container App's system-assigned identity lacks *Cognitive Services OpenAI User* on the account, or the account restricts network access. Role assignments can take a few minutes to propagate |
| Container App revision fails to pull the image right after `azd up` | AcrPull for the system-assigned identity may still be propagating; run `azd deploy` again |
| After `azd provision` the apps show the hello-world image | Provisioning resets the placeholder image; run `azd deploy` |
| Azure Bot connection deployment error | The OAuth connection parameter keys / `scopes` format are the least verified part of the Bicep; compare with `az bot authsetting list-providers --service Aadv2` and adjust `infra/resources.bicep` |
| uv `404` while resolving packages | The feed warms its cache on first request; retry |
| `/whoami` gets no reply; bot log shows `signin/failure` with `resourcematchfailed` | Teams silent SSO failed. Set `teamsSilentSso` to `false` (Bicep parameter, default `true`) or run `az containerapp update --set-env-vars TEAMS_SILENT_SSO=false`. The bot then removes the card's `tokenExchangeResource`, so Teams shows a plain **Sign in** button (interactive flow) |
| Interactive **Sign in** button fails | The bot Entra app needs the web redirect URIs `https://token.botframework.com/.auth/web/redirect` and `https://token.botframework.com/.auth/callback` (added by `preprovision`) |
| Bot ignores messages after a failed sign-in | The SDK keeps a pending sign-in flow in memory and treats the next message as a magic code. Restart the revision to clear it |
| `azd deploy` does not change Container App env vars | Also run `az containerapp update --set-env-vars NAME=value` |

## 9. Update and clean up

```powershell
azd deploy            # code-only changes
azd provision         # infra / Entra changes
azd down --purge      # deletes Azure resources (the Entra apps remain)
az ad app delete --id <BOT_APP_ID>; az ad app delete --id <MCP_APP_ID>
```

The bot client secret expires after one year; rotate it with `az ad app credential reset` and update the azd env.
