<#
.SYNOPSIS
    Verifies the Order Management sample pipeline end to end on Azure Local.

.DESCRIPTION
    Confirms that orders are flowing API -> queue -> processor -> blob + SQL by showing pod
    status, recent processor output, and the orders recorded in SQL Server.

.EXAMPLE
    # The SQL password is read from the 'oms-sql-admin' Secret.
    ./lab/azurelocal/verify.ps1
#>
[CmdletBinding()]
param(
    [string]$KubeContext = 'bcd-aksarc',
    [string]$Namespace = 'oms-azurelocal',

    # Omit to read it from the Secret below.
    [string]$SqlPassword,
    [string]$SqlPasswordSecretName = 'oms-sql-admin',
    [string]$Database = 'omsdb'
)

$ErrorActionPreference = 'Stop'
$kubeContext = $KubeContext

# scripts/azurelocal/deploy.ps1 generates the password and keeps it in this Secret.
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

Write-Host "`n==> Recent processor activity" -ForegroundColor Cyan
$processor = kubectl get pods -n $Namespace --context $kubeContext -l radapp.io/resource=processor -o jsonpath='{.items[0].metadata.name}'
if ([string]::IsNullOrWhiteSpace($processor)) {
    Write-Warning 'No processor pod found.'
}
else {
    kubectl logs -n $Namespace --context $kubeContext $processor --tail=5
}

Write-Host "`n==> Orders recorded in SQL Server" -ForegroundColor Cyan
$sqlPod = kubectl get pods -n $Namespace --context $kubeContext -l app=mssql -o jsonpath='{.items[0].metadata.name}'
if ([string]::IsNullOrWhiteSpace($sqlPod)) {
    Write-Warning 'No SQL Server pod found.'
}
else {
    kubectl exec -n $Namespace --context $kubeContext $sqlPod -- /opt/mssql-tools18/bin/sqlcmd `
        -S localhost -U sa -P $SqlPassword -C -d $Database `
        -Q "SELECT COUNT(*) AS OrdersRecorded FROM dbo.Orders; SELECT TOP 5 OrderId, CustomerName, LineCount, Total, Currency, ProcessedAt FROM dbo.Orders ORDER BY ProcessedAt DESC;"
}
