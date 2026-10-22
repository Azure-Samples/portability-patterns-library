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

.EXAMPLE
    ./scripts/setup-platform.ps1 -Target AzureLocal

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
    [string]$SettingsPath
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/lib/settings.ps1"

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
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
    foreach ($step in $steps.Keys) {
        if ($step -in $Skip) {
            Write-Host "==> [$Target] $step skipped" -ForegroundColor DarkGray
            continue
        }
        $script = Join-Path $PSScriptRoot $steps[$step]
        $arguments = Get-OmsStepArguments $settings $step $script
        $shown = ($arguments.GetEnumerator() | Sort-Object Key | ForEach-Object { "-$($_.Key) $(@($_.Value) -join ',')" }) -join ' '
        if ($PSCmdlet.ShouldProcess("scripts/$($steps[$step]) $shown", "$Target $step")) {
            Write-Host "`n==> [$Target] $step : scripts/$($steps[$step])" -ForegroundColor Magenta
            & $script @arguments
        }
    }
    if (-not $WhatIfPreference) {
        Write-Host "`nPlatform ready for $Target. Deploy the app with: ./scripts/deploy.ps1 -Target $Target" -ForegroundColor Green
    }
}
finally {
    Pop-Location
}
