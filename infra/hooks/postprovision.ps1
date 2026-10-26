#requires -Version 7
<#
Runs after the infrastructure exists. Sets the bot app's final App ID URI (api://<bot-fqdn>/<appId>),
which Teams SSO requires and which must equal the Token Exchange URL on the Azure Bot OAuth connection,
then builds the Teams app package.
#>
$ErrorActionPreference = 'Stop'

function Get-AzdValue([string]$Name) {
    $value = azd env get-value $Name 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $value) { throw "azd env value '$Name' is not set" }
    return $value.Trim()
}

$botAppId = Get-AzdValue 'BOT_APP_ID'
$botFqdn = Get-AzdValue 'BOT_FQDN'

$objectId = az ad app show --id $botAppId --query id -o tsv
$file = New-TemporaryFile
try {
    @{ identifierUris = @("api://$botFqdn/$botAppId") } | ConvertTo-Json | Set-Content -Path $file -Encoding utf8
    az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/$objectId" `
        --headers 'Content-Type=application/json' --body "@$file" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to set the bot App ID URI' }
}
finally { Remove-Item $file -ErrorAction SilentlyContinue }

$env:BOT_APP_ID = $botAppId
$env:BOT_FQDN = $botFqdn
uv run python scripts/make_teams_package.py
if ($LASTEXITCODE -ne 0) { throw 'Teams package generation failed' }
