/*
  Key Vault — Live View Agent.
  Optional. Local .env is enough to run.
*/

param name string
param location string

@allowed(['dev', 'prod'])
param environment string

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: name
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: environment == 'prod' ? 90 : 7
    enabledForDeployment: false
    enabledForTemplateDeployment: true
    publicNetworkAccess: 'Enabled'
  }
}

resource secretOpenAIKey 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'AZURE-OPENAI-API-KEY'
  properties: {
    value: 'REPLACE-AFTER-DEPLOY'
    contentType: 'text/plain'
    attributes: { enabled: true }
  }
}

output vaultName string = keyVault.name
output uri string = keyVault.properties.vaultUri
output id string = keyVault.id
