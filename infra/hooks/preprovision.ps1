#requires -Version 7
<#
Creates (idempotently) the two Entra app registrations the demo needs and stores their IDs in the azd env:

  MCP API app  - exposes  api://<mcp-id>/access_as_user, pre-authorizes the bot app
  Bot app      - Azure Bot identity + OAuth connection client + OBO confidential client;
                 exposes access_as_user (Teams SSO), pre-authorizes the Teams clients,
                 is allowed to call the MCP API on behalf of users

The bot's App ID URI (api://botid-<appId>, the format Teams requires for bot SSO) is set here, because it must equal
the Token Exchange URL on the Azure Bot OAuth connection and webApplicationInfo.resource in the Teams manifest.
Re-running is safe; the client secret is only created once.
#>
$ErrorActionPreference = 'Stop'

# Stable IDs so the script is re-runnable.
$McpScopeId = '6c1b9d2e-3f4a-4c55-9a0e-2f7b8d1a5e01'
$BotScopeId = '0d7a5c3b-8e21-4f6a-b4c9-1a2e3f4d5b02'
# Teams desktop/mobile, Teams web, Microsoft 365 web, Microsoft 365 desktop, Microsoft 365 mobile/Office desktop, Outlook web, Outlook mobile
$TeamsClients = @(
    '1fec8e78-bce4-4aaf-ab1b-5451cc387264', '5e3ce6c0-2b1f-4285-8d4b-75ee78787346',
    '4765445b-32c6-49b0-83e6-1d93765276ca', '0ec893e0-5785-4de6-99da-4ed124e5296c',
    'd3590ed6-52b3-4102-aeff-aad2292ab01c', 'bc59ab01-8403-45c6-8796-ac3ef710b3e3',
    '27922004-5251-4030-b22d-91ecd9a37ea4'
)

function Get-AzdValue([string]$Name) {
    $value = azd env get-value $Name 2>$null
    if ($LASTEXITCODE -eq 0 -and $value) { return $value.Trim() }
    return $null
}

function Set-AzdValue([string]$Name, [string]$Value) {
    azd env set $Name $Value | Out-Null
}

function Invoke-GraphPatch([string]$AppId, [hashtable]$Body) {
    $objectId = az ad app show --id $AppId --query id -o tsv
    $file = New-TemporaryFile
    try {
        $Body | ConvertTo-Json -Depth 10 | Set-Content -Path $file -Encoding utf8
        az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/$objectId" `
            --headers 'Content-Type=application/json' --body "@$file" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Graph PATCH failed for app $AppId" }
    }
    finally { Remove-Item $file -ErrorAction SilentlyContinue }
}

function Ensure-App([string]$DisplayName) {
    $appId = az ad app list --display-name $DisplayName --query '[0].appId' -o tsv
    if (-not $appId) {
        $appId = az ad app create --display-name $DisplayName --sign-in-audience AzureADMyOrg --query appId -o tsv
        Write-Host "Created app registration '$DisplayName' ($appId)"
    }
    else { Write-Host "Using existing app registration '$DisplayName' ($appId)" }
    if (-not (az ad sp show --id $appId --query id -o tsv 2>$null)) {
        az ad sp create --id $appId | Out-Null
    }
    return $appId
}

function New-Scope([string]$Id, [string]$What) {
    @{
        id = $Id; value = 'access_as_user'; type = 'User'; isEnabled = $true
        adminConsentDisplayName = "Access $What as the signed-in user"
        adminConsentDescription = "Allows the application to access $What on behalf of the signed-in user."
        userConsentDisplayName  = "Access $What as you"
        userConsentDescription  = "Allows the application to access $What on your behalf."
    }
}

# --- required inputs for the existing model deployment -------------------------------------------------
$missing = 'OPENAI_ENDPOINT', 'OPENAI_DEPLOYMENT', 'OPENAI_ACCOUNT_NAME', 'OPENAI_RESOURCE_GROUP' | Where-Object { -not (Get-AzdValue $_) }
if ($missing) {
    Write-Error ("Missing azd env values: $($missing -join ', ').`n" +
        "Set them first, e.g.:`n  azd env set OPENAI_ENDPOINT https://<account>.openai.azure.com`n" +
        "  azd env set OPENAI_DEPLOYMENT <chat-deployment-name>`n  azd env set OPENAI_ACCOUNT_NAME <account>`n" +
        "  azd env set OPENAI_RESOURCE_GROUP <resource-group>")
}

$tenantId = az account show --query tenantId -o tsv
$envName = $env:AZURE_ENV_NAME

# --- app registrations ---------------------------------------------------------------------------------
$botAppId = Ensure-App "obo-demo-bot-$envName"
$mcpAppId = Ensure-App "obo-demo-mcp-$envName"

Invoke-GraphPatch $mcpAppId @{
    identifierUris = @("api://$mcpAppId")
    api = @{
        requestedAccessTokenVersion = 2
        oauth2PermissionScopes      = @(New-Scope $McpScopeId 'the OBO demo MCP server')
    }
}
Invoke-GraphPatch $mcpAppId @{
    api = @{
        requestedAccessTokenVersion = 2
        oauth2PermissionScopes      = @(New-Scope $McpScopeId 'the OBO demo MCP server')
        preAuthorizedApplications   = @(@{ appId = $botAppId; delegatedPermissionIds = @($McpScopeId) })
    }
}

Invoke-GraphPatch $botAppId @{
    identifierUris = @("api://botid-$botAppId")   # Teams bot SSO requires the botid- format
    web = @{ redirectUris = @('https://token.botframework.com/.auth/web/redirect', 'https://token.botframework.com/.auth/callback') }
    api = @{
        requestedAccessTokenVersion = 2
        oauth2PermissionScopes      = @(New-Scope $BotScopeId 'the OBO demo bot')
    }
    requiredResourceAccess = @(@{
        resourceAppId = $mcpAppId
        resourceAccess = @(@{ id = $McpScopeId; type = 'Scope' })
    })
}
# Pre-authorization can only reference scopes that already exist, hence a separate PATCH.
Invoke-GraphPatch $botAppId @{
    api = @{
        requestedAccessTokenVersion = 2
        oauth2PermissionScopes      = @(New-Scope $BotScopeId 'the OBO demo bot')
        preAuthorizedApplications   = @($TeamsClients | ForEach-Object { @{ appId = $_; delegatedPermissionIds = @($BotScopeId) } })
    }
}

try { az ad app permission grant --id $botAppId --api $mcpAppId --scope access_as_user | Out-Null }
catch { Write-Warning "Could not grant admin consent (pre-authorization normally suffices): $_" }

# --- bot client secret (needed by the Bot Service OAuth connection and the OBO exchange) -----------------
if (-not (Get-AzdValue 'BOT_CLIENT_SECRET')) {
    $secret = az ad app credential reset --id $botAppId --append --display-name "azd-$envName" --years 1 --query password -o tsv
    Set-AzdValue 'BOT_CLIENT_SECRET' $secret
}

Set-AzdValue 'TENANT_ID' $tenantId
Set-AzdValue 'BOT_APP_ID' $botAppId
Set-AzdValue 'MCP_APP_ID' $mcpAppId
Write-Host "Entra apps ready. bot=$botAppId mcp=$mcpAppId tenant=$tenantId"
