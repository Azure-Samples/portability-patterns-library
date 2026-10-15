<#
.SYNOPSIS
    Prepares a site for the Business Continuity Demo App, once: cluster, HTTPS ingress, user sign-in
    and, on Azure Local, what keeps the app running when the link to Azure is down.

.DESCRIPTION
    Platform-team step. Application teams then only run ./scripts/deploy.ps1. Every step is
    idempotent, so the whole script can be re-run; -Skip leaves steps out, for example Cluster when
    the cluster already exists.

    Azure
      Cluster   azure/provision-infra.ps1             AKS, ACR, workload identity, Radius
      Ingress   azure/provision-ingress.ps1           managed NGINX, DNS name, certificate issuer
      Identity  azure/configure-app-identity.ps1      Entra app registrations and roles

    AzureLocal
      Cluster   azurelocal/provision-infra.ps1        AKS Arc cluster, ACR
      Images    azurelocal/import-images.ps1          third-party images mirrored into the ACR
      Registry  azurelocal/connected-registry.ps1     in-cluster registry that keeps serving offline
      Keycloak  azurelocal/keycloak.ps1               on-site token issuer federated to Active Directory
      Ingress   azurelocal/provision-ingress.ps1      load balancer, NGINX, site CA certificate
      Identity  azurelocal/configure-app-identity.ps1 Keycloak clients, AD group -> role mapping

    Values come from the target's section of scripts/settings.json (see settings.example.json):
    'Common' goes to every step that takes the parameter, a section named after the step to that
    step only. Keep secrets out of it; the scripts read those from Kubernetes Secrets.

    Azure Local expects a Keycloak bind account for the site's Active Directory in the Secret
    identity/bcd-ad-bind. In the lab, lab/aldo/addc-vm.ps1 -ExistingDomainController creates it.

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
        Cluster  = 'azure/provision-infra.ps1'
        Ingress  = 'azure/provision-ingress.ps1'
        Identity = 'azure/configure-app-identity.ps1'
    }
}
else {
    [ordered]@{
        Cluster  = 'azurelocal/provision-infra.ps1'
        Images   = 'azurelocal/import-images.ps1'
        Registry = 'azurelocal/connected-registry.ps1'
        Keycloak = 'azurelocal/keycloak.ps1'
        Ingress  = 'azurelocal/provision-ingress.ps1'
        Identity = 'azurelocal/configure-app-identity.ps1'
    }
}

$settings = Read-BcdSettings $Target $SettingsPath
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
    foreach ($step in $steps.Keys) {
        if ($step -in $Skip) {
            Write-Host "==> [$Target] $step skipped" -ForegroundColor DarkGray
            continue
        }
        $script = Join-Path $PSScriptRoot $steps[$step]
        $arguments = Get-BcdStepArguments $settings $step $script
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
