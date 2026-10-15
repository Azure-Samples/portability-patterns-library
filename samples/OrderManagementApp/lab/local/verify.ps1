<#
.SYNOPSIS
    Verifies the Business Continuity Demo App pipeline end to end in the local cluster.

.DESCRIPTION
    Confirms that events are flowing publisher -> queue -> consumer -> blob + SQL by showing pod
    status, recent consumer output, and the row count in SQL Server.

.EXAMPLE
    ./lab/local/verify.ps1

.EXAMPLE
    # Azure Local / ALDO: the SQL password is read from the 'bcd-sql-admin' Secret.
    ./lab/local/verify.ps1 -KubeContext bcd-aksarc -Namespace bcd-azurelocal
#>
[CmdletBinding()]
param(
    [string]$ClusterName = 'bcd',
    [string]$Namespace = 'bcd-local',

    # Omit to read it from the Secret below, falling back to the fixed local-environment password.
    [string]$SqlPassword,
    [string]$SqlPasswordSecretName = 'bcd-sql-admin',
    [string]$Database = 'bcddb',

    # Explicit kubectl context. Defaults to the kind naming convention, which only applies to the
    # local environment; pass the context name directly for Azure Local or any other cluster.
    [string]$KubeContext
)

$ErrorActionPreference = 'Stop'
if (-not $KubeContext) { $KubeContext = "kind-$ClusterName" }
$kubeContext = $KubeContext

# Environments that generate the password (Azure Local, ALDO) keep it in a Secret.
if (-not $SqlPassword) {
    $encoded = kubectl get secret $SqlPasswordSecretName -n $Namespace --context $kubeContext `
        --ignore-not-found -o jsonpath='{.data.password}'
    $SqlPassword = if ($encoded) {
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
    }
    else { $env:MSSQL_SA_PASSWORD }
}

Write-Host '==> Pods' -ForegroundColor Cyan
kubectl get pods -n $Namespace --context $kubeContext

Write-Host "`n==> Recent consumer activity" -ForegroundColor Cyan
$consumer = kubectl get pods -n $Namespace --context $kubeContext -l radapp.io/resource=consumer -o jsonpath='{.items[0].metadata.name}'
if ([string]::IsNullOrWhiteSpace($consumer)) {
    Write-Warning 'No consumer pod found.'
}
else {
    kubectl logs -n $Namespace --context $kubeContext $consumer --tail=5
}

Write-Host "`n==> Rows recorded in SQL Server" -ForegroundColor Cyan
$sqlPod = kubectl get pods -n $Namespace --context $kubeContext -l app=mssql -o jsonpath='{.items[0].metadata.name}'
if ([string]::IsNullOrWhiteSpace($sqlPod)) {
    Write-Warning 'No SQL Server pod found.'
}
else {
    kubectl exec -n $Namespace --context $kubeContext $sqlPod -- /opt/mssql-tools18/bin/sqlcmd `
        -S localhost -U sa -P $SqlPassword -C -d $Database `
        -Q "SELECT COUNT(*) AS EventsRecorded FROM dbo.BusinessEvents; SELECT TOP 5 EventType, Region, Severity, ProcessedAt FROM dbo.BusinessEvents ORDER BY ProcessedAt DESC;"
}
