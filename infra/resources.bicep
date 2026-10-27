param environmentName string
param location string
param tags object
param tenantId string
param botAppId string
param mcpAppId string
@secure()
param botClientSecret string
param openAiEndpoint string
param openAiDeployment string

var token = toLower(uniqueString(subscription().id, environmentName))
var botAppName = 'ca-bot-${token}'
var mcpAppName = 'ca-mcp-${token}'
var placeholderImage = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
var acrPullRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')

// The OAuth connection name registered on the Azure Bot; the agent handler refers to it.
var oauthConnectionName = 'mcp_sso'

resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${token}'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: 'cr${token}'
  location: location
  tags: tags
  sku: { name: 'Basic' }
  properties: { adminUserEnabled: false }
}

resource env 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'cae-${token}'
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logs.properties.customerId
        sharedKey: logs.listKeys().primarySharedKey
      }
    }
  }
}

// External ingress FQDNs are deterministic, which avoids a circular dependency with the bot endpoint.
var botFqdn = '${botAppName}.${env.properties.defaultDomain}'
var mcpFqdn = '${mcpAppName}.${env.properties.defaultDomain}'
var botIdentifierUri = 'api://${botFqdn}/${botAppId}'

var mcpEnv = [
  { name: 'TENANT_ID', value: tenantId }
  { name: 'MCP_CLIENT_ID', value: mcpAppId }
  { name: 'PORT', value: '8000' }
]

var botEnv = [
  { name: 'PORT', value: '3978' }
  // Bot identity (Entra app), used for channel auth and as the confidential client for the OBO exchange
  { name: 'CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTID', value: botAppId }
  { name: 'CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTSECRET', secretRef: 'bot-client-secret' }
  { name: 'CONNECTIONS__SERVICE_CONNECTION__SETTINGS__TENANTID', value: tenantId }
  { name: 'CONNECTIONSMAP__0__SERVICEURL', value: '*' }
  { name: 'CONNECTIONSMAP__0__CONNECTION', value: 'SERVICE_CONNECTION' }
  // Agents SDK handler "MCP" <-> Azure Bot OAuth connection, OBO via the service connection
  { name: 'AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__MCP__SETTINGS__AZUREBOTOAUTHCONNECTIONNAME', value: oauthConnectionName }
  { name: 'AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__MCP__SETTINGS__OBOCONNECTIONNAME', value: 'SERVICE_CONNECTION' }
  { name: 'MCP_URL', value: 'https://${mcpFqdn}/mcp' }
  { name: 'MCP_SCOPE', value: 'api://${mcpAppId}/access_as_user' }
  // Teams silent SSO failed with resourcematchfailed in the test tenant; use the interactive "Sign in" button.
  { name: 'TEAMS_SILENT_SSO', value: 'false' }
  { name: 'AZURE_OPENAI_ENDPOINT', value: openAiEndpoint }
  { name: 'AZURE_OPENAI_DEPLOYMENT', value: openAiDeployment }
]

// Pass 1: create each app (system-assigned identity, public placeholder image, no registry).
module mcpBase 'containerapp.bicep' = {
  name: 'mcp-base'
  params: {
    name: mcpAppName
    location: location
    tags: union(tags, { 'azd-service-name': 'mcp' })
    environmentId: env.id
    containerName: 'mcp'
    targetPort: 8000
    image: placeholderImage
    cpu: '0.25'
    memory: '0.5Gi'
    env: mcpEnv
  }
}

module botBase 'containerapp.bicep' = {
  name: 'bot-base'
  params: {
    name: botAppName
    location: location
    tags: union(tags, { 'azd-service-name': 'bot' })
    environmentId: env.id
    containerName: 'bot'
    targetPort: 3978
    image: placeholderImage
    cpu: '0.5'
    memory: '1Gi'
    env: botEnv
    clientSecret: botClientSecret
  }
}

// Each app's own identity may pull from the registry (and nothing else here).
resource mcpAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, mcpAppName, 'acrpull')
  scope: registry
  properties: {
    roleDefinitionId: acrPullRoleId
    principalId: mcpBase.outputs.principalId
    principalType: 'ServicePrincipal'
  }
}

resource botAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, botAppName, 'acrpull')
  scope: registry
  properties: {
    roleDefinitionId: acrPullRoleId
    principalId: botBase.outputs.principalId
    principalType: 'ServicePrincipal'
  }
}

// Pass 2: same apps, now with the registry configured to use the system-assigned identity.
module mcpRegistry 'containerapp.bicep' = {
  name: 'mcp-registry'
  params: {
    name: mcpAppName
    location: location
    tags: union(tags, { 'azd-service-name': 'mcp' })
    environmentId: env.id
    containerName: 'mcp'
    targetPort: 8000
    image: placeholderImage
    cpu: '0.25'
    memory: '0.5Gi'
    env: mcpEnv
    registryServer: registry.properties.loginServer
  }
  dependsOn: [mcpAcrPull]
}

module botRegistry 'containerapp.bicep' = {
  name: 'bot-registry'
  params: {
    name: botAppName
    location: location
    tags: union(tags, { 'azd-service-name': 'bot' })
    environmentId: env.id
    containerName: 'bot'
    targetPort: 3978
    image: placeholderImage
    cpu: '0.5'
    memory: '1Gi'
    env: botEnv
    clientSecret: botClientSecret
    registryServer: registry.properties.loginServer
  }
  dependsOn: [botAcrPull]
}

resource bot 'Microsoft.BotService/botServices@2022-09-15' = {
  name: 'bot-${token}'
  location: 'global'
  tags: tags
  kind: 'azurebot'
  sku: { name: 'F0' }
  properties: {
    displayName: 'OBO Demo Agent'
    endpoint: 'https://${botFqdn}/api/messages'
    msaAppId: botAppId
    msaAppTenantId: tenantId
    msaAppType: 'SingleTenant'
  }
}

resource teamsChannel 'Microsoft.BotService/botServices/channels@2022-09-15' = {
  parent: bot
  name: 'MsTeamsChannel'
  location: 'global'
  properties: {
    channelName: 'MsTeamsChannel'
    properties: { isEnabled: true }
  }
}

// Entra ID v2 OAuth connection. Teams SSO hands Bot Service a token for the bot's own API
// (token exchange URL = the bot's App ID URI); the agent then does the OBO exchange for the MCP API.
resource oauthConnection 'Microsoft.BotService/botServices/connections@2022-09-15' = {
  parent: bot
  name: oauthConnectionName
  location: 'global'
  properties: {
    serviceProviderId: '30dd229c-58e3-4a48-bdfd-91ec48eb906c'
    serviceProviderDisplayName: 'Azure Active Directory v2'
    clientId: botAppId
    clientSecret: botClientSecret
    scopes: '${botIdentifierUri}/access_as_user'
    parameters: [
      { key: 'ClientId', value: botAppId }
      { key: 'ClientSecret', value: botClientSecret }
      { key: 'TenantId', value: tenantId }
      { key: 'TokenExchangeUrl', value: botIdentifierUri }
    ]
  }
}

output registryEndpoint string = registry.properties.loginServer
output botFqdn string = botFqdn
output mcpFqdn string = mcpFqdn
output botServiceName string = bot.name
// Only the bot's own identity is granted access to the LLM account.
output botPrincipalId string = botBase.outputs.principalId
