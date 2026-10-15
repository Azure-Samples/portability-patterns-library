<#
.SYNOPSIS
    Removes everything the local Business Continuity Demo App deployment created.

.DESCRIPTION
    Deletes, in order:
      1. The kind cluster, which takes every deployed resource with it (application pods, RabbitMQ,
         Azurite, SQL Server, the in-cluster registry, and the Radius control plane).
      2. The orphaned kubectl context, if kind left one behind.
      3. The Radius workspace entry in ~/.rad/config.yaml.
      4. The locally built worker images.
      5. The generated Bicep extension for the custom Resource Type.

    Only artifacts belonging to this project are touched. Other kind clusters, kubectl contexts,
    Radius workspaces and Docker images are left alone.

    Nothing is created in Azure by the local path, so there is nothing to clean up there. To remove
    an Azure deployment instead, delete the resource group that deploy/infra/main.bicep created:
      az group delete --name bcd-infra --yes

.EXAMPLE
    ./lab/local/teardown.ps1

.EXAMPLE
    ./lab/local/teardown.ps1 -KeepImages
#>
[CmdletBinding()]
param(
    [string]$ClusterName = 'bcd',
    [string]$WorkspaceName = 'bcd',
    [string]$ImageTag = 'local',
    [switch]$KeepImages
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Push-Location $repoRoot

try {
    $kubeContext = "kind-$ClusterName"

    Write-Host "==> Deleting kind cluster '$ClusterName'" -ForegroundColor Cyan
    $clusters = kind get clusters 2>$null
    if ($clusters -contains $ClusterName) {
        kind delete cluster --name $ClusterName
    }
    else {
        Write-Host "    Cluster not present; skipping" -ForegroundColor DarkGray
    }

    # kind normally removes its own context, but an interrupted delete can leave one behind.
    Write-Host "==> Removing kubectl context '$kubeContext' if orphaned" -ForegroundColor Cyan
    $contexts = kubectl config get-contexts -o name 2>$null
    if ($contexts -contains $kubeContext) {
        kubectl config delete-context $kubeContext 2>&1 | Out-Null
        kubectl config delete-cluster $kubeContext 2>&1 | Out-Null
        kubectl config delete-user $kubeContext 2>&1 | Out-Null
        Write-Host "    Removed" -ForegroundColor DarkGray
    }
    else {
        Write-Host "    Not present; skipping" -ForegroundColor DarkGray
    }

    # The workspace lives in the local rad config, so deleting the cluster does not remove it.
    Write-Host "==> Removing Radius workspace '$WorkspaceName'" -ForegroundColor Cyan
    $workspaces = rad workspace list -o json 2>$null | ConvertFrom-Json
    if ($workspaces -and ($workspaces.name -contains $WorkspaceName)) {
        rad workspace delete $WorkspaceName --yes
    }
    else {
        Write-Host "    Not present; skipping" -ForegroundColor DarkGray
    }

    if (-not $KeepImages) {
        Write-Host "==> Removing locally built worker images" -ForegroundColor Cyan
        foreach ($image in @("bcd/publisher:$ImageTag", "bcd/consumer:$ImageTag")) {
            docker image rm $image 2>&1 | Out-Null
        }
        Write-Host "    Removed" -ForegroundColor DarkGray
    }

    Write-Host "==> Removing the generated Bicep extension" -ForegroundColor Cyan
    Remove-Item 'deploy/types/businessContinuity.tgz' -Force -ErrorAction SilentlyContinue

    Write-Host "`nTeardown complete." -ForegroundColor Green
    Write-Host "Recreate everything with: ./lab/local/deploy.ps1"
}
finally {
    Pop-Location
}
