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

1. **preprovision** creates/updates `obo-demo-bot-<env>` and `obo-demo-mcp-<env>` (settings in
   [ARCHITECTURE.md](ARCHITECTURE.md#2-entra-app-registrations)), tries admin consent, creates a bot client secret
   (kept in the azd env) and records `TENANT_ID`, `BOT_APP_ID`, `MCP_APP_ID`.
2. **provision** creates the Azure resources, including the Azure Bot, Teams channel and `mcp_sso` connection.
3. **deploy** remote-builds the `bot` and `mcp` images in ACR and updates both Container Apps.
4. **postprovision** writes `dist\teams-app.zip`. The bot's name in Teams is `OBO Demo (<azd env name>)`.

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

- **Group chats**: the manifest enables the `groupChat` scope. Add the app to a group chat (Apps -> Manage your apps -> Add to a chat,
  or add it from the chat's **+** button) and `@mention` it. Each sender signs in separately. Bot SSO is not supported in
  channels, so the `team` scope is intentionally omitted. `/whoami` prints claims, so use it only in chats you are happy to share
  them with.
- **Microsoft 365 Copilot**: the manifest declares the bot as a custom engine agent (`copilotAgents.customEngineAgents`, manifest
  1.22). After installing, open Microsoft 365 Copilot (Teams or m365.cloud.microsoft) and pick the agent from the agent list.
  The Microsoft 365 and Outlook client IDs are pre-authorized on the bot app by preprovision. Allow a few minutes for it to
  appear. If Copilot shows a sign-in card, it falls back to the interactive flow.

After changing the manifest, bump `TEAMS_APP_VERSION` (`azd env set TEAMS_APP_VERSION 1.1.2`), run
`azd hooks run postprovision`, and upload the new zip as an update. Teams keeps one chat history per bot, so a re-installed
app shows the earlier conversation.

## 7. Run the demo

1. Send `/whoami` (or click the **Who am I?** prompt). Expect your Teams name and `aadObjectId`, the claims of the OBO token
   (`aud`, `scp`, `azp`, `oid`), what the MCP server reported, and **Match**.
2. Ask "Who am I? Use the backend tool to check which user it sees." to see the LangGraph agent call the `whoami` tool.
3. Have a second user install the app and repeat: each sees their own `oid`.
4. Portal -> Container App `ca-mcp-*` -> Log stream shows `whoami called by oid=...`.
5. `/signout` clears the stored token; the next message signs in again.

## 8. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `preprovision` fails with insufficient privileges | You cannot create apps. Ask an admin to create apps named `obo-demo-bot-<env>` / `obo-demo-mcp-<env>` (the script reuses apps by display name) and re-run |
| Setting the identifier URI fails | A tenant app-management policy restricts `api://` URIs; adjust the policy |
| `azd up` asks for the `botAppId` parameter | The Entra apps do not exist yet. Cancel, run `azd hooks run preprovision`, then `azd up` |
| After `azd provision` the apps show the hello-world image | Provisioning resets the placeholder image; run `azd deploy` |
| `azd deploy` does not change Container App env vars | It only updates the image. Run `azd provision`, or `az containerapp update --set-env-vars NAME=value` |
| Container App revision fails to pull the image right after `azd up` | AcrPull may still be propagating; run `azd deploy` again |
| LLM 401/403 | The bot's managed identity lacks *Cognitive Services OpenAI User* on the account, the role is still propagating, or the account restricts network access |
| uv `404` while resolving packages | The feed warms its cache on first request; retry |
| Bot log shows `signin/failure` with `resourcematchfailed` | Silent SSO resource mismatch. The bot app's Application ID URI, the connection's `TokenExchangeUrl` and the manifest `webApplicationInfo.resource` must all be `api://botid-<BOT_APP_ID>` ([ARCHITECTURE.md](ARCHITECTURE.md#3-azure-bot-service)). Re-run `azd provision` and `azd hooks run postprovision`, then reinstall the app |
| A sign-in card is shown instead of silent SSO | The Teams / M365 client is not pre-authorized on the bot app's `access_as_user` scope (the bot log prints the client's `azp` on every `tokenExchange`), or the pre-authorization was just added and is still propagating (a few minutes). Fallback: `TEAMS_SILENT_SSO=false` (Bicep `teamsSilentSso`) always shows a plain **Sign in** button |
| Interactive **Sign in** fails | The bot app is missing the redirect URIs `https://token.botframework.com/.auth/web/redirect` and `.../.auth/callback` (set by `preprovision`) |
| AADSTS65001 (consent) during OBO | `az ad app permission grant --id <BOT_APP_ID> --api <MCP_APP_ID> --scope access_as_user` |
| "I couldn't get a token for the backend" | Transient: Bot Service can answer 404 right after silent SSO. The bot already retries; send the message again |
| Bot ignores messages or says "Sign-in failed. Max retries reached" | A stale pending sign-in flow in memory treats your message as a magic code. Send `/signout`, or restart the revision (`az containerapp revision restart`). Reinstalling the app also clears it |
| MCP returns 401 with a token | Check `aud` (`<MCP_APP_ID>` or `api://<MCP_APP_ID>`), `scp`, token v2 and `TENANT_ID` |
| Bot returns 401 on `/api/messages` | Bot app id / secret / tenant mismatch in the Container App's `CONNECTIONS__SERVICE_CONNECTION__*` settings or the Azure Bot |
| Prompts insert the wrong text or the app does not update | Teams caches manifests. Bump `TEAMS_APP_VERSION`, rebuild and upload again |

## 9. Update and clean up

```powershell
azd deploy            # code-only changes
azd provision         # infra / Entra changes
azd down --purge      # deletes Azure resources (the Entra apps remain)
az ad app delete --id <BOT_APP_ID>; az ad app delete --id <MCP_APP_ID>
```

The bot client secret expires after one year; rotate it with `az ad app credential reset` and update the azd env.
