<#
.SYNOPSIS
    Dedicated Azure OpenAI for Live View Agent. Post-working goal.

    Today: copy execution_agent/.env and run the sidecar locally.
    Later: .\infra\deploy.ps1 -SkipWhatIf  then replace .env from the printed block.
#>

param(
    [ValidateSet('dev', 'prod')]
    [string]$Environment = 'dev',

    [switch]$SkipWhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectName = 'lva'
$ResourceGroup = "rg-$ProjectName-$Environment"
$Location = 'eastus'
$DeploymentName = "$ProjectName-$Environment-$(Get-Date -Format 'yyyyMMdd-HHmm')"
$TemplateFile = Join-Path $PSScriptRoot 'main.bicep'
$ParamsFile = Join-Path $PSScriptRoot "params\$Environment.bicepparam"

Write-Host ''
Write-Host '=== Live View Agent — Bicep Deploy ===' -ForegroundColor Cyan
Write-Host "Environment  : $Environment"
Write-Host "Resource Grp : $ResourceGroup"
Write-Host ''

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI not found. Install from https://aka.ms/installazurecliwindows'
}

$accountJson = az account show 2>$null
if (-not $accountJson) {
    Write-Host 'Not logged in. Running az login...' -ForegroundColor Yellow
    az login | Out-Null
}

$rgExists = az group exists --name $ResourceGroup
if ($rgExists -eq 'false') {
    az group create --name $ResourceGroup --location $Location | Out-Null
}

$deployArgs = @(
    '--resource-group', $ResourceGroup,
    '--template-file', $TemplateFile,
    '--parameters', $ParamsFile
)

if (-not $SkipWhatIf) {
    az deployment group what-if @deployArgs
    $confirm = Read-Host 'Proceed with deployment? (y/N)'
    if ($confirm -ne 'y' -and $confirm -ne 'Y') {
        Write-Host 'Cancelled.' -ForegroundColor Yellow
        exit 0
    }
}

$resultJson = az deployment group create @deployArgs --name $DeploymentName --output json
if ($LASTEXITCODE -ne 0) {
    throw 'Deployment failed.'
}

$result = $resultJson | ConvertFrom-Json
$outputs = $result.properties.outputs

$openaiAccountName = az resource list `
    --resource-group $ResourceGroup `
    --resource-type 'Microsoft.CognitiveServices/accounts' `
    --query '[0].name' --output tsv

$openaiKey = az cognitiveservices account keys list `
    --name $openaiAccountName `
    --resource-group $ResourceGroup `
    --query 'key1' --output tsv

$openaiEndpoint = $outputs.openaiEndpoint.value
$chatDeployment = $outputs.chatDeploymentName.value

Write-Host ''
Write-Host 'Copy into .env:' -ForegroundColor Yellow
Write-Host "AZURE_OPENAI_API_KEY=$openaiKey"
Write-Host "AZURE_OPENAI_ENDPOINT=$openaiEndpoint"
Write-Host 'AZURE_OPENAI_API_VERSION=2024-02-01'
Write-Host "AZURE_OPENAI_CHAT_DEPLOYMENT=$chatDeployment"
Write-Host 'API_PORT=3002'
