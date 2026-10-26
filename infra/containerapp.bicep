// One Container App with a system-assigned managed identity.
// Deployed twice per app by resources.bicep: first without a registry (public placeholder image), then, after
// the identity has been granted AcrPull, with the registry configured to pull using that identity.
param name string
param location string
param tags object
param environmentId string
param containerName string
param targetPort int
param image string
param cpu string
param memory string
param env array
@secure()
param clientSecret string = ''
param registryServer string = ''

var secrets = empty(clientSecret) ? [] : [{ name: 'bot-client-secret', value: clientSecret }]

resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: name
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    managedEnvironmentId: environmentId
    configuration: {
      ingress: { external: true, targetPort: targetPort, transport: 'http' }
      registries: empty(registryServer) ? [] : [{ server: registryServer, identity: 'system' }]
      secrets: secrets
    }
    template: {
      containers: [
        {
          name: containerName
          image: image
          resources: { cpu: json(cpu), memory: memory }
          env: env
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
}

output principalId string = app.identity.principalId
output id string = app.id
