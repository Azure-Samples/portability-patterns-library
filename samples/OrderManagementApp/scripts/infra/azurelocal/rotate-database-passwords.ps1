#Requires -Version 7.0
<#
.SYNOPSIS
    Rotates existing Azure Local database passwords and restarts their application consumers.
.DESCRIPTION
    This is maintenance, not application deployment. It reads the desired synchronized passwords
    and the last applied administrator passwords. Successful administrator changes are recorded
    immediately so a failed rotation can be retried. Run after the first successful app deployment.
#>
[CmdletBinding()]
param(
    [string]$KubeContext = 'bcd-aksarc',
    [string]$Namespace = 'oms-azurelocal',
    [string]$WorkspaceName = 'oms-azurelocal',
    [string]$ResourceGroup = 'oms',
    [string]$PasswordsSecretName = 'oms-db-passwords',
    [string]$AppliedAdminSecretName = 'oms-db-admin',
    [string]$DatabaseSetupConfigMapName = 'oms-db-setup',
    [string]$DatabaseSetupImage,
    [string]$ImagePullSecretName = 'azurelocal-registry',
    [int]$RolloutTimeoutSeconds = 900
)
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
. "$repoRoot/scripts/lib/database.ps1"
. "$repoRoot/scripts/lib/database-passwords.ps1"
. "$repoRoot/scripts/lib/deployment.ps1"

$passwords = Get-OmsDatabasePasswords $KubeContext $Namespace $PasswordsSecretName
$applied = Get-OmsSecretData $KubeContext $Namespace $AppliedAdminSecretName
if (-not $applied['sql-admin-password'] -or -not $applied['postgres-admin-password']) {
    throw 'No applied database administrator credentials. Deploy the application once before rotating passwords.'
}
if (-not $DatabaseSetupImage) {
    $DatabaseSetupImage = kubectl get configmap $DatabaseSetupConfigMapName -n $Namespace --context $KubeContext `
        --ignore-not-found -o 'jsonpath={.data.image}'
    if ($LASTEXITCODE -ne 0 -or -not $DatabaseSetupImage) {
        throw 'No database setup image recorded. Set Rotation.DatabaseSetupImage to a published dbsetup image digest.'
    }
    $snapshotSecretName = "$AppliedAdminSecretName-rotation"
    Set-OmsSecret $KubeContext $Namespace $snapshotSecretName $passwords
}
foreach ($app in 'mssql', 'postgres') {
    $pods = kubectl get pods --context $KubeContext -n $Namespace --selector "app=$app" `
        --field-selector status.phase=Running -o json
    if ($LASTEXITCODE -ne 0) { throw "Could not find the running $app database." }
    $podNames = @(($pods | ConvertFrom-Json).items.metadata.name)
    if ($podNames.Count -ne 1 -or -not $podNames[0]) { throw "Expected one running $app database before rotating passwords." }
    $key = if ($app -eq 'mssql') { 'sql-admin-password' } else { 'postgres-admin-password' }
    $previous = $applied[$key]
    if ($previous -ceq $passwords[$key]) { continue }
    $pod = $podNames[0]
    Write-Host "==> Rotating the $app administrator password" -ForegroundColor Cyan
    if ($app -eq 'mssql') {
        "$previous`nALTER LOGIN sa WITH PASSWORD = N'$($passwords[$key].Replace("'", "''"))';`nGO" |
            kubectl exec --stdin $pod --container mssql --context $KubeContext -n $Namespace -- `
                bash -c 'IFS= read -r P; export SQLCMDPASSWORD="${P%$''\r''}"; /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -b' | Out-Null
    }
    else {
        "$previous`nALTER ROLE CURRENT_USER PASSWORD '$($passwords[$key].Replace("'", "''"))';" |
            kubectl exec --stdin $pod --container postgres --context $KubeContext -n $Namespace -- `
                sh -c 'IFS= read -r P; export PGPASSWORD="${P%$(printf ''\r'')}"; psql -h /var/run/postgresql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -q' | Out-Null
    }
    if ($LASTEXITCODE -ne 0) { throw "Changing the $app administrator password failed." }
    $applied[$key] = $passwords[$key]
    Set-OmsSecret $KubeContext $Namespace $AppliedAdminSecretName $applied
}
Invoke-OmsLocalDatabaseSetup -KubeContext $KubeContext -Namespace $Namespace -WorkspaceName $WorkspaceName `
    -ResourceGroup $ResourceGroup -Image $DatabaseSetupImage -ImagePullSecretName $ImagePullSecretName `
    -PasswordsSecretName $snapshotSecretName
Set-OmsServiceDatabasePasswords $KubeContext $Namespace $passwords
foreach ($service in 'api', 'processor', 'inventory') {
    Invoke-OmsChecked "restart $service" { kubectl rollout restart deployment $service -n $Namespace --context $KubeContext | Out-Null }
}
Invoke-OmsChecked 'wait for application' {
    kubectl rollout status deployment -n $Namespace --context $KubeContext --timeout="${RolloutTimeoutSeconds}s" | Out-Null
}
Invoke-OmsChecked 'remove rotation snapshot' {
    kubectl delete secret $snapshotSecretName -n $Namespace --context $KubeContext --ignore-not-found | Out-Null
}
Write-Host 'Database passwords rotated. No application images were built or deployed.' -ForegroundColor Green
