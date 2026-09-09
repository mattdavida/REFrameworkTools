param(
    [Parameter(Mandatory)][ValidateSet('dev', 'prod')]
    [string]$Environment
)

$ProjectName = 'lva'
$ResourceGroup = "rg-$ProjectName-$Environment"

if ($Environment -eq 'prod') {
    $confirm = Read-Host "Type 'delete prod' to confirm"
    if ($confirm -ne 'delete prod') {
        exit 0
    }
}

$ok = Read-Host "Delete $ResourceGroup ? (y/N)"
if ($ok -ne 'y' -and $ok -ne 'Y') {
    exit 0
}

$kvName = az keyvault list --resource-group $ResourceGroup --query '[0].name' -o tsv 2>$null
$kvLocation = az keyvault list --resource-group $ResourceGroup --query '[0].location' -o tsv 2>$null
$oaiName = az cognitiveservices account list --resource-group $ResourceGroup --query '[0].name' -o tsv 2>$null
$oaiLocation = az cognitiveservices account list --resource-group $ResourceGroup --query '[0].location' -o tsv 2>$null

az group delete --name $ResourceGroup --yes --no-wait

if ($kvName) {
    az keyvault purge --name $kvName --location $kvLocation 2>$null
}
if ($oaiName) {
    az cognitiveservices account purge --name $oaiName --resource-group $ResourceGroup --location $oaiLocation 2>$null
}
