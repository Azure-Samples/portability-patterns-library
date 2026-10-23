<#
.SYNOPSIS
    Prepares a site for the Order Management sample, once: cluster, HTTPS ingress, user sign-in
    and, on Azure Local, what keeps the app running when the link to Azure is down.

.DESCRIPTION
    Platform-team step. Application teams then only run ./scripts/deploy.ps1. Every step is
    idempotent, so the whole script can be re-run; -Skip leaves steps out, for example Cluster when
    the cluster already exists.

    Azure
      Cluster   infra/azure/provision-infra.ps1              AKS, ACR, workload identity, Radius
      Ingress   infra/azure/provision-ingress.ps1            managed NGINX, DNS name, certificate issuer
      Identity  infra/azure/configure-app-identity.ps1       Entra app registrations and roles

    AzureLocal
      Cluster   infra/azurelocal/provision-infra.ps1         AKS Arc cluster, ACR, load balancer
      Images    infra/azurelocal/import-images.ps1           third-party images mirrored into the ACR
      Registry  infra/azurelocal/connected-registry.ps1      in-cluster registry that keeps serving offline
      Keycloak  infra/azurelocal/keycloak.ps1                on-site sign-in and token issuer, federated to Active Directory
      Ingress   infra/azurelocal/provision-ingress.ps1       NGINX ingress, site CA certificate
    Values come from the target's section of scripts/settings.json (see settings.example.json):
    'Common' goes to every step that takes the parameter, a section named after the step to that
    step only. Keep secrets out of it; the scripts read those from Kubernetes Secrets.

    Azure Local expects a Keycloak bind account for the site's Active Directory in the Secret
    identity/oms-ad-bind and the directory's CA in identity/oms-ad-ca. Create them by hand (see
    the sample README) or with infra/azurelocal/ad-setup.ps1.

    Azure Local steps need Azure (Cluster, Images), the cluster's network (Keycloak, Ingress) or
    both (Registry). Run everything from one machine that has both, or use -Stage when none does:
      -Stage Azure  on a machine with Azure access: Cluster, Images and the Azure part of Registry
      -Stage Site   on a machine on the site network: the site part of Registry, Keycloak, Ingress
    The Azure stage leaves what the site needs in scripts/.handover; copy that folder to the site
    machine before the Site stage.

.EXAMPLE
    ./scripts/setup-platform.ps1 -Target AzureLocal

.EXAMPLE
    # The site's management machine has no Azure access.
    ./scripts/setup-platform.ps1 -Target AzureLocal -Stage Azure   # where Azure is reachable
    ./scripts/setup-platform.ps1 -Target AzureLocal -Stage Site    # on the site network

.EXAMPLE
    # Existing cluster: show what would run, then run it.
    ./scripts/setup-platform.ps1 -Target Azure -Skip Cluster -WhatIf
    ./scripts/setup-platform.ps1 -Target Azure -Skip Cluster
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Azure', 'AzureLocal')]
    [string]$Target,
    [ValidateSet('Cluster', 'Images', 'Registry', 'Keycloak', 'Ingress', 'Identity')]
    [string[]]$Skip = @(),
    [string]$SettingsPath,
    [ValidateSet('All', 'Azure', 'Site')]
    [string]$Stage = 'All'
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/lib/settings.ps1"
if ($Target -eq 'Azure' -and $Stage -ne 'All') { throw '-Stage applies to -Target AzureLocal only.' }

$steps = if ($Target -eq 'Azure') {
    [ordered]@{
        Cluster  = 'infra/azure/provision-infra.ps1'
        Ingress  = 'infra/azure/provision-ingress.ps1'
        Identity = 'infra/azure/configure-app-identity.ps1'
    }
}
else {
    [ordered]@{
        Cluster  = 'infra/azurelocal/provision-infra.ps1'
        Images   = 'infra/azurelocal/import-images.ps1'
        Registry = 'infra/azurelocal/connected-registry.ps1'
        Keycloak = 'infra/azurelocal/keycloak.ps1'
        Ingress  = 'infra/azurelocal/provision-ingress.ps1'
    }
}

$settings = Read-OmsSettings $Target $SettingsPath
$previousSubscription = $null
# Which steps each stage runs; Registry runs in both, each doing its own part.
$stageSteps = @{ Azure = @('Cluster', 'Images', 'Registry'); Site = @('Registry', 'Keycloak', 'Ingress') }
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
    # The site machine may have no Azure sign-in at all.
    if (-not $WhatIfPreference -and $Stage -ne 'Site') { $previousSubscription = Select-OmsSubscription $settings }

    # Cluster credentials the Azure stage fetched for this machine: merge them in, then remove the
    # file, since it holds the cluster's admin certificate.
    $handoverKubeconfig = Join-Path $PSScriptRoot '.handover/kubeconfig'
    if ($Stage -eq 'Site' -and -not $WhatIfPreference -and (Test-Path $handoverKubeconfig)) {
        $kubeHome = Join-Path $HOME '.kube/config'
        New-Item -ItemType Directory -Force -Path (Split-Path $kubeHome) | Out-Null
        $previousKubeconfig = $env:KUBECONFIG
        $env:KUBECONFIG = (@($handoverKubeconfig) + @($kubeHome | Where-Object { Test-Path $_ })) -join [IO.Path]::PathSeparator
        $merged = kubectl config view --flatten --raw
        $env:KUBECONFIG = $previousKubeconfig
        if ($LASTEXITCODE -ne 0 -or -not $merged) { throw "Could not read $handoverKubeconfig." }
        [IO.File]::WriteAllText($kubeHome, ($merged -join "`n"), [Text.UTF8Encoding]::new($false))
        Remove-Item $handoverKubeconfig -Force
        Write-Host "==> Took over the cluster credentials from scripts/.handover/kubeconfig" -ForegroundColor Cyan
    }

    foreach ($step in $steps.Keys) {
        if ($step -in $Skip -or ($Stage -ne 'All' -and $step -notin $stageSteps[$Stage])) {
            Write-Host "==> [$Target] $step skipped" -ForegroundColor DarkGray
            continue
        }
        $script = Join-Path $PSScriptRoot $steps[$step]
        $arguments = Get-OmsStepArguments $settings $step $script
        if ($Stage -ne 'All' -and (Get-Command $script).Parameters.ContainsKey('Stage')) { $arguments['Stage'] = $Stage }
        $shown = ($arguments.GetEnumerator() | Sort-Object Key | ForEach-Object { "-$($_.Key) $(@($_.Value) -join ',')" }) -join ' '
        if ($PSCmdlet.ShouldProcess("scripts/$($steps[$step]) $shown", "$Target $step")) {
            Write-Host "`n==> [$Target] $step : scripts/$($steps[$step])" -ForegroundColor Magenta
            & $script @arguments
        }
    }
    if (-not $WhatIfPreference) {
        if ($Stage -eq 'Azure') {
            Write-Host "`nAzure part done. Copy scripts/.handover to the site machine and run: ./scripts/setup-platform.ps1 -Target $Target -Stage Site" -ForegroundColor Green
        }
        else {
            $deployHint = if ($Stage -eq 'Site') { "./scripts/deploy.ps1 -Target $Target -Stage Azure (on the Azure machine), then -Stage Site here" } else { "./scripts/deploy.ps1 -Target $Target" }
            Write-Host "`nPlatform ready for $Target. Deploy the app with: $deployHint" -ForegroundColor Green
        }
    }
}
finally {
    Restore-OmsSubscription $previousSubscription
    Pop-Location
}
