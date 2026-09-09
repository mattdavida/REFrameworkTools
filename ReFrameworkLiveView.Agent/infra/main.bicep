/*
  Live View Agent — Azure OpenAI + Key Vault only.
  Sidecar stays on the local machine. Do not deploy until chat works
  on the copied execution_agent .env.

    .\infra\deploy.ps1 -SkipWhatIf
*/

@description('Environment name.')
@allowed(['dev', 'prod'])
param environment string

@description('Azure region.')
param location string = resourceGroup().location

@description('Short name in resource names. Max 8 chars.')
@maxLength(8)
param projectName string = 'lva'

@description('Azure OpenAI chat deployment name.')
param chatModelName string = 'gpt-4o'

var suffix = uniqueString(resourceGroup().id)
var shortSuffix = take(suffix, 6)

var names = {
  openai: 'oai-${projectName}-${environment}-${shortSuffix}'
  keyVault: 'kv-${projectName}-${environment}-${shortSuffix}'
}

module openai 'modules/openai.bicep' = {
  name: 'openai-deploy'
  params: {
    name: names.openai
    location: location
    chatDeploymentName: chatModelName
    environment: environment
  }
}

module keyVault 'modules/keyvault.bicep' = {
  name: 'keyvault-deploy'
  params: {
    name: names.keyVault
    location: location
    environment: environment
  }
}

output openaiEndpoint string = openai.outputs.endpoint
output chatDeploymentName string = chatModelName
output keyVaultUri string = keyVault.outputs.uri
