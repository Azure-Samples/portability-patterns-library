<#
.SYNOPSIS
    Sets up Azure Key Vault and the Key Vault Secret Store extension, the path for secrets and
    certificates that already live in Azure and must reach the Azure Local site.

.DESCRIPTION
    For example an existing certificate or a partner's API key: it is kept in Key Vault, and the
    Secret Store extension copies it into a Kubernetes Secret while the site is connected. With the
    link down, the last copy keeps working. Nothing in the sample goes through it by default: its
    database passwords and object store keys are generated on site.

    The Azure resources are declared in infra/azurelocal/key-vault.bicep: Key Vault, the identity
    the extension reads it with (federated with the cluster's OIDC issuer, so the cluster must have
    been created with workload identity), and the Secret Store extension, which needs the
    Certificate Management extension the cluster gets when it's created. This script deploys the
    template and creates the service account the extension reads the vault as.
    infra/azurelocal/key-vault-sync.yaml shows how to sync a secret.

.EXAMPLE
    # Usually run by setup-platform.ps1 with the Common and KeyVault sections of scripts/settings.json. On its own:
    ./scripts/infra/azurelocal/key-vault.ps1 -ResourceGroup <resource-group> -ClusterName <cluster> -KubeContext <context>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [Parameter(Mandatory = $true)][string]$ClusterName,
    [Parameter(Mandatory = $true)][string]$KubeContext,

    # Globally unique; empty derives one from the subscription and resource group.
    [string]$KeyVaultName,
    [string]$Location,
    # The namespace synced secrets go to, and the service account the extension reads the vault as there.
    [string]$ApplicationNamespace = 'oms-azurelocal',
    [string]$ServiceAccountName = 'secret-sync',

    # Object IDs allowed to set the secrets, besides whoever runs this script.
    [string[]]$SecretsOfficerObjectIds = @(),
    [int]$RotationPollIntervalInSeconds = 3600
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
. (Join-Path $repoRoot 'scripts/lib/cluster.ps1')
. (Join-Path $repoRoot 'scripts/lib/azure.ps1')

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$What,
        [Parameter(Mandatory = $true)][scriptblock]$Command
    )

    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$What failed with exit code $LASTEXITCODE."
    }
}

$account = Invoke-Checked 'az account show' { az account show --output json } | ConvertFrom-Json
if (-not $KeyVaultName) {
    $KeyVaultName = 'kv-oms-' + ([BitConverter]::ToString([Security.Cryptography.SHA256]::HashData(
                [Text.Encoding]::UTF8.GetBytes("$($account.id)/$ResourceGroup"))).Replace('-', '').Substring(0, 12).ToLowerInvariant())
}
if (-not $Location) { $Location = Invoke-Checked "az group show $ResourceGroup" { az group show --name $ResourceGroup --query location --output tsv } }

$cluster = Invoke-OmsAzShow @('resource', 'show', '--resource-group', $ResourceGroup, '--resource-type', 'Microsoft.Kubernetes/connectedClusters',
    '--name', $ClusterName, '--output', 'json')
if (-not $cluster) { throw "Arc connected cluster '$ClusterName' not found in '$ResourceGroup'. Run scripts/infra/azurelocal/provision-infra.ps1 first." }
if (-not ($cluster | ConvertFrom-Json).properties.oidcIssuerProfile.issuerUrl) {
    throw "Cluster '$ClusterName' has no OIDC issuer, so it can't read Key Vault. Workload identity can only be turned on when the cluster is created; infra/azurelocal/platform.bicep turns it on (enableWorkloadIdentity), so recreate the cluster with it."
}

# Whoever runs this may set the secrets too; a service principal is named in SecretsOfficerObjectIds.
$me = if ($account.user.type -eq 'user') { Invoke-Checked 'az ad signed-in-user show' { az ad signed-in-user show --query id --output tsv } }
$officers = @($SecretsOfficerObjectIds) + @($me | Where-Object { $_ }) | Select-Object -Unique

$document = [ordered]@{
    '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters     = [ordered]@{
        location                      = @{ value = $Location }
        keyVaultName                  = @{ value = $KeyVaultName }
        clusterName                   = @{ value = $ClusterName }
        syncNamespace                 = @{ value = $ApplicationNamespace }
        syncServiceAccountName        = @{ value = $ServiceAccountName }
        secretsOfficerObjectIds       = @{ value = @($officers) }
        rotationPollIntervalInSeconds = @{ value = $RotationPollIntervalInSeconds }
    }
}
$parametersFile = New-TemporaryFile
try {
    [IO.File]::WriteAllText($parametersFile, ($document | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    Write-Host "==> Deploying Key Vault '$KeyVaultName' and the Secret Store extension on '$ClusterName'" -ForegroundColor Cyan
    $outputs = az deployment group create --resource-group $ResourceGroup --name 'oms-key-vault' `
        --template-file (Join-Path $repoRoot 'infra/azurelocal/key-vault.bicep') --parameters "@$parametersFile" `
        --query properties.outputs --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Deploying infra/azurelocal/key-vault.bicep failed.' }
}
finally { Remove-Item $parametersFile -ErrorAction SilentlyContinue }

Write-Host "==> Service account '$ServiceAccountName' in '$ApplicationNamespace' for the Secret Store extension" -ForegroundColor Cyan
Set-OmsNamespace $KubeContext $ApplicationNamespace
$manifest = (Get-Content (Join-Path $repoRoot 'infra/azurelocal/key-vault-sync.yaml') -Raw).
    Replace('${NAMESPACE}', $ApplicationNamespace).
    Replace('${SERVICE_ACCOUNT}', $ServiceAccountName).
    Replace('${KEYVAULT_NAME}', $outputs.keyVaultName.value).
    Replace('${CLIENT_ID}', $outputs.syncClientId.value).
    Replace('${TENANT_ID}', $outputs.tenantId.value)
$manifest | kubectl apply --context $KubeContext -f - | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Applying infra/azurelocal/key-vault-sync.yaml failed.' }
Write-Host "`nKey Vault ready: $($outputs.keyVaultUri.value)" -ForegroundColor Green
Write-Host "To sync a secret from it, see infra/azurelocal/key-vault-sync.yaml (clientID $($outputs.syncClientId.value), tenantID $($outputs.tenantId.value))."
