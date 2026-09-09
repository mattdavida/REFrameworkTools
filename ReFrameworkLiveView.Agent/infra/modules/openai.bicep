/*
  Azure OpenAI — Live View Agent (post-working goal).
  Same module as execution_agent. Chat only, no embeddings.
*/

param name string
param location string
param chatDeploymentName string

@allowed(['dev', 'prod'])
param environment string

var chatCapacity = environment == 'prod' ? 80 : 30

resource openAIAccount 'Microsoft.CognitiveServices/accounts@2026-03-15-preview' = {
  name: name
  location: location
  kind: 'OpenAI'
  sku: {
    name: 'S0'
  }
  properties: {
    customSubDomainName: name
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: false
  }
}

resource chatDeployment 'Microsoft.CognitiveServices/accounts/deployments@2026-03-15-preview' = {
  parent: openAIAccount
  name: chatDeploymentName
  sku: {
    name: 'GlobalStandard'
    capacity: chatCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-5.4'
      version: '2026-03-05'
    }
    versionUpgradeOption: 'OnceCurrentVersionExpired'
  }
}

output endpoint string = openAIAccount.properties.endpoint
output accountName string = openAIAccount.name
output accountId string = openAIAccount.id
