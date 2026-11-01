<#
.SYNOPSIS
    Keeps the Azure Local site's database passwords in Azure Key Vault and syncs them into the
    cluster, so they keep working when the site loses its link to Azure.

.DESCRIPTION
    Each service signs in to its database as its own least-privilege user; the database setup job
    and the database containers use the administrator accounts. All of their passwords live in Key
    Vault, which operations own: they change a password there, and the Key Vault Secret Store
    extension copies the new version into the cluster while the site is connected. With the link
    down, the last copies keep working.

    The Azure resources are declared in infra/azurelocal/key-vault.bicep: Key Vault, the identity
    the extension reads it with (federated with the cluster's OIDC issuer, so the cluster must have
    been created with workload identity), and the Secret Store extension, which needs the
    Certificate Management extension the cluster gets when it's created. The sync itself is
    infra/azurelocal/key-vault-sync.yaml.

    The script deploys the template, sets each password that isn't in Key Vault yet to a generated
    value, applies the sync and waits until the passwords are in the cluster.

    To change a password, set a new version in Key Vault. Once the extension has synced it into
    Secret oms-db-passwords, ./scripts/deploy.ps1 sets it in the database and hands it to the
    service. No service reads oms-db-passwords itself.

.EXAMPLE
    ./scripts/infra/azurelocal/key-vault.ps1 -ClusterName bcd-aksarc -KubeContext bcd-aksarc
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup = 'bcd-azurelocal',
    [string]$ClusterName = 'bcd-aksarc',
    [string]$KubeContext = 'bcd-aksarc',

    # Globally unique; empty derives one from the subscription and resource group.
    [string]$KeyVaultName,
    [string]$Location,
    [string]$ApplicationNamespace = 'oms-azurelocal',
    [string]$ServiceAccountName = 'secret-sync',

    # Object IDs allowed to set the secrets, besides whoever runs this script.
    [string[]]$SecretsOfficerObjectIds = @(),
    [int]$RotationPollIntervalInSeconds = 3600,

    # The Secret the sync writes, which this script waits for.
    [string]$SyncedSecretName = 'oms-db-passwords',
    [int]$SyncTimeoutMinutes = 10
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path

# The passwords this sample keeps in Key Vault.
$secretNames = @('sql-admin-password', 'postgres-admin-password', 'sql-api-password', 'sql-processor-password', 'postgres-inventory-password')

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

# Meets SQL Server's and PostgreSQL's complexity rules, and has no character that needs quoting
# in a connection string.
function New-DatabasePassword {
    $bytes = [byte[]]::new(24)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    'Oms1-' + [Convert]::ToBase64String($bytes).Replace('+', 'A').Replace('/', 'b').TrimEnd('=')
}

if (-not $KeyVaultName) {
    $subscriptionId = az account show --query id --output tsv
    $KeyVaultName = 'kv-oms-' + ([BitConverter]::ToString([Security.Cryptography.SHA256]::HashData(
                [Text.Encoding]::UTF8.GetBytes("$subscriptionId/$ResourceGroup"))).Replace('-', '').Substring(0, 12).ToLowerInvariant())
}
if (-not $Location) { $Location = az group show --name $ResourceGroup --query location --output tsv }

$oidcIssuer = az resource show --resource-group $ResourceGroup --resource-type Microsoft.Kubernetes/connectedClusters `
    --name $ClusterName --query properties.oidcIssuerProfile.issuerUrl --output tsv 2>$null
if (-not $oidcIssuer) {
    throw "Cluster '$ClusterName' has no OIDC issuer, so it can't read Key Vault. Workload identity can only be turned on when the cluster is created (EnableWorkloadIdentity in the Cluster settings)."
}

$me = az ad signed-in-user show --query id --output tsv 2>$null
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
$parametersFile = Join-Path ([IO.Path]::GetTempPath()) "oms-key-vault-$([guid]::NewGuid().ToString('N')).json"
try {
    [IO.File]::WriteAllText($parametersFile, ($document | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    Write-Host "==> Deploying Key Vault '$KeyVaultName' and the Secret Store extension on '$ClusterName'" -ForegroundColor Cyan
    $outputs = az deployment group create --resource-group $ResourceGroup --name 'oms-key-vault' `
        --template-file (Join-Path $repoRoot 'infra/azurelocal/key-vault.bicep') --parameters "@$parametersFile" `
        --query properties.outputs --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or -not $outputs) { throw 'Deploying infra/azurelocal/key-vault.bicep failed.' }
}
finally { Remove-Item $parametersFile -ErrorAction SilentlyContinue }

# Role assignments take a few minutes to apply, so the first writes may be refused.
Write-Host "==> Setting the passwords that aren't in Key Vault yet" -ForegroundColor Cyan
foreach ($name in $secretNames) {
    $exists = $false
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        az keyvault secret show --vault-name $KeyVaultName --name $name --query id --output tsv 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $exists = $true; break }
        $errorText = az keyvault secret show --vault-name $KeyVaultName --name $name 2>&1 | Out-String
        if ($errorText -match 'SecretNotFound|was not found') { break }
        Start-Sleep -Seconds 15
    }
    if ($exists) { Write-Host "    $name (kept)" -ForegroundColor DarkGray; continue }

    $valueFile = Join-Path ([IO.Path]::GetTempPath()) "oms-secret-$([guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllText($valueFile, (New-DatabasePassword), [Text.UTF8Encoding]::new($false))
        Invoke-Checked "az keyvault secret set $name" {
            az keyvault secret set --vault-name $KeyVaultName --name $name --file $valueFile --encoding utf-8 --output none
        }
    }
    finally { Remove-Item $valueFile -ErrorAction SilentlyContinue }
    Write-Host "    $name (generated)" -ForegroundColor DarkGray
}

Write-Host "==> Syncing passwords from Key Vault '$($outputs.keyVaultName.value)' into '$ApplicationNamespace'" -ForegroundColor Cyan
kubectl create namespace $ApplicationNamespace --context $KubeContext --dry-run=client -o yaml |
    kubectl apply --context $KubeContext -f - | Out-Null
$manifest = (Get-Content (Join-Path $repoRoot 'infra/azurelocal/key-vault-sync.yaml') -Raw).
    Replace('${NAMESPACE}', $ApplicationNamespace).
    Replace('${SERVICE_ACCOUNT}', $ServiceAccountName).
    Replace('${KEYVAULT_NAME}', $outputs.keyVaultName.value).
    Replace('${CLIENT_ID}', $outputs.syncClientId.value).
    Replace('${TENANT_ID}', $outputs.tenantId.value)
$manifest | kubectl apply --context $KubeContext -f - | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Applying infra/azurelocal/key-vault-sync.yaml failed. Is the Secret Store extension running?' }

$deadline = (Get-Date).AddMinutes($SyncTimeoutMinutes)
while (-not (kubectl get secret $SyncedSecretName --namespace $ApplicationNamespace --context $KubeContext --ignore-not-found -o name)) {
    if ((Get-Date) -gt $deadline) {
        $status = kubectl get secretsync --namespace $ApplicationNamespace --context $KubeContext -o json | ConvertFrom-Json
        $reasons = $status.items | ForEach-Object { "$($_.metadata.name): $(($_.status.conditions | Select-Object -Last 1).message)" }
        throw "Secret '$SyncedSecretName' not synced within $SyncTimeoutMinutes minutes.`n$($reasons -join "`n")"
    }
    Start-Sleep -Seconds 10
}
Write-Host "    synced into Secret '$SyncedSecretName'" -ForegroundColor DarkGray
Write-Host "`nKey Vault ready: $($outputs.keyVaultUri.value)" -ForegroundColor Green
