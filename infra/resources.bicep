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

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-bot-${token}'
  location: location
  tags: tags
}

// AcrPull so both apps can pull images with the managed identity
resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, identity.id, 'acrpull')
  scope: registry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
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

resource mcpApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: mcpAppName
  location: location
  tags: union(tags, { 'azd-service-name': 'mcp' })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identity.id}': {} }
  }
  properties: {
    managedEnvironmentId: env.id
    configuration: {
      ingress: { external: true, targetPort: 8000, transport: 'http' }
      registries: [{ server: registry.properties.loginServer, identity: identity.id }]
    }
    template: {
      containers: [
        {
          name: 'mcp'
          image: placeholderImage
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          env: [
            { name: 'TENANT_ID', value: tenantId }
            { name: 'MCP_CLIENT_ID', value: mcpAppId }
            { name: 'PORT', value: '8000' }
          ]
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
  dependsOn: [acrPull]
}

resource botApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: botAppName
  location: location
  tags: union(tags, { 'azd-service-name': 'bot' })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identity.id}': {} }
  }
  properties: {
    managedEnvironmentId: env.id
    configuration: {
      ingress: { external: true, targetPort: 3978, transport: 'http' }
      registries: [{ server: registry.properties.loginServer, identity: identity.id }]
      secrets: [{ name: 'bot-client-secret', value: botClientSecret }]
    }
    template: {
      containers: [
        {
          name: 'bot'
          image: placeholderImage
          resources: { cpu: json('0.5'), memory: '1Gi' }
          env: [
            { name: 'PORT', value: '3978' }
            // Bot identity, used for channel auth and as the confidential client for the OBO exchange
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
            { name: 'AZURE_OPENAI_ENDPOINT', value: openAiEndpoint }
            { name: 'AZURE_OPENAI_DEPLOYMENT', value: openAiDeployment }
            // Selects the user-assigned identity for DefaultAzureCredential
            { name: 'AZURE_CLIENT_ID', value: identity.properties.clientId }
          ]
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
  dependsOn: [acrPull]
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
output botIdentityPrincipalId string = identity.properties.principalId
