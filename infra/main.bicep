targetScope = 'subscription'

@minLength(1)
@maxLength(20)
@description('azd environment name; used to derive resource names.')
param environmentName string

param location string = deployment().location

@description('Entra tenant ID (set by the preprovision hook).')
param tenantId string

@description('Client ID of the bot app registration (set by the preprovision hook).')
param botAppId string

@description('Client ID of the MCP API app registration (set by the preprovision hook).')
param mcpAppId string

@secure()
@description('Client secret of the bot app registration (set by the preprovision hook).')
param botClientSecret string

@description('Endpoint of an existing Azure OpenAI / Foundry model resource, e.g. https://xyz.openai.azure.com')
param openAiEndpoint string

@description('Chat model deployment name on that resource.')
param openAiDeployment string

@description('Name of the existing Azure OpenAI account; used to grant the bot identity data-plane access.')
param openAiAccountName string

@description('Resource group of the existing Azure OpenAI account.')
param openAiResourceGroup string

var tags = { 'azd-env-name': environmentName }

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${environmentName}'
  location: location
  tags: tags
}

module resources 'resources.bicep' = {
  name: 'resources'
  scope: rg
  params: {
    environmentName: environmentName
    location: location
    tags: tags
    tenantId: tenantId
    botAppId: botAppId
    mcpAppId: mcpAppId
    botClientSecret: botClientSecret
    openAiEndpoint: openAiEndpoint
    openAiDeployment: openAiDeployment
  }
}

module openAiAccess 'openai-role.bicep' = {
  name: 'openai-access'
  scope: resourceGroup(openAiResourceGroup)
  params: {
    openAiAccountName: openAiAccountName
    principalId: resources.outputs.botIdentityPrincipalId
  }
}

output AZURE_LOCATION string = location
output AZURE_TENANT_ID string = tenantId
output AZURE_RESOURCE_GROUP string = rg.name
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = resources.outputs.registryEndpoint
output BOT_FQDN string = resources.outputs.botFqdn
output MCP_FQDN string = resources.outputs.mcpFqdn
output BOT_NAME string = resources.outputs.botServiceName
