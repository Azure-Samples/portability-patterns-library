<#
.SYNOPSIS
    Sets up Azure Key Vault and the Key Vault Secret Store extension, and brings the order archive's
    signing key from the vault to the Azure Local site.

.DESCRIPTION
    The order processor signs every order it archives with a key kept in Key Vault, secret
    archive-signing-key; this script creates it once with a random value. The Secret Store extension
    copies it into Kubernetes Secret archive-signing while the site is connected, and the Recipe Pack
    mounts that Secret into the processor. With the link down, the last copy keeps working. Rotate the
    key by setting a new version in the vault; the extension brings it within the poll interval.
    Database passwords and object store keys don't go through the vault: they are generated on site.

    The Azure resources are declared in infra/azurelocal/key-vault.bicep: Key Vault, the identity
    the extension reads it with (federated with the cluster's OIDC issuer, so the cluster must have
    been created with workload identity), and the Secret Store extension, which needs the
    Certificate Management extension the cluster gets when it's created. Assigning their roles needs
    Owner or User Access Administrator. infra/azurelocal/key-vault-sync.yaml declares what is synced.

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
. (Join-Path $repoRoot 'scripts/lib/common.ps1')
. (Join-Path $repoRoot 'scripts/lib/cluster.ps1')
. (Join-Path $repoRoot 'scripts/lib/azure.ps1')

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

# Whoever runs this, a user or a pipeline's service principal, sets the signing key below, so it
# gets Secrets Officer too.
$officers = @($SecretsOfficerObjectIds) + @(Get-OmsCallerObjectId) | Where-Object { $_ } | Select-Object -Unique

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
$vault = $outputs.keyVaultName.value
Initialize-OmsArchiveSigningKey -KeyVaultName $vault

Write-Host "==> Syncing 'archive-signing-key' to Secret 'archive-signing' in '$ApplicationNamespace'" -ForegroundColor Cyan
Set-OmsNamespace $KubeContext $ApplicationNamespace
$manifest = (Get-Content (Join-Path $repoRoot 'infra/azurelocal/key-vault-sync.yaml') -Raw).
    Replace('${NAMESPACE}', $ApplicationNamespace).
    Replace('${SERVICE_ACCOUNT}', $ServiceAccountName).
    Replace('${KEYVAULT_NAME}', $vault).
    Replace('${CLIENT_ID}', $outputs.syncClientId.value).
    Replace('${TENANT_ID}', $outputs.tenantId.value)
$manifest | kubectl apply --context $KubeContext -f - | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Applying infra/azurelocal/key-vault-sync.yaml failed.' }

# The federated credential can also take a minute to apply before the extension's first read works.
$deadline = (Get-Date).AddMinutes(10)
while (-not (kubectl get secret archive-signing --context $KubeContext --namespace $ApplicationNamespace --ignore-not-found --output name)) {
    if ((Get-Date) -gt $deadline) {
        $status = kubectl get secretsync archive-signing --context $KubeContext --namespace $ApplicationNamespace --output jsonpath='{.status.conditions}'
        throw "Secret 'archive-signing' wasn't synced from Key Vault within 10 minutes. SecretSync status: $status"
    }
    Write-Host '    Waiting for the Secret Store extension to sync it...'
    Start-Sleep -Seconds 15
}
Write-Host "`nKey Vault ready: $($outputs.keyVaultUri.value); signing key synced to Secret 'archive-signing'." -ForegroundColor Green
