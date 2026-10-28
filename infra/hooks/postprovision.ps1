#requires -Version 7
<#
Runs after the infrastructure exists and builds the Teams app package. The bot app's App ID URI
(api://botid-<appId>, the format Teams requires for bot SSO) is set in preprovision and must equal the
Token Exchange URL on the Azure Bot OAuth connection and webApplicationInfo.resource in the manifest.
#>
$ErrorActionPreference = 'Stop'

function Get-AzdValue([string]$Name) {
    $value = azd env get-value $Name 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $value) { throw "azd env value '$Name' is not set" }
    return $value.Trim()
}

$botAppId = Get-AzdValue 'BOT_APP_ID'
$botFqdn = Get-AzdValue 'BOT_FQDN'

$env:BOT_APP_ID = $botAppId
$env:BOT_FQDN = $botFqdn
$env:TEAMS_APP_NAME = "OBO Demo ($env:AZURE_ENV_NAME)"   # the bot's name in Teams follows the azd environment
uv run python scripts/make_teams_package.py
if ($LASTEXITCODE -ne 0) { throw 'Teams package generation failed' }
