#Requires -Version 7.0
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
      Ingress   infra/azurelocal/provision-ingress.ps1       NGINX ingress, site CA certificate
      Keycloak  infra/azurelocal/keycloak.ps1                on-site sign-in and token issuer, federated to Active Directory
    Values come from the target's section of scripts/settings.json (see settings.example.json):
    'Common' goes to every step that takes the parameter, a section named after the step to that
    step only. Keep secrets out of it; the scripts read those from Kubernetes Secrets.

    Azure Local expects a Keycloak bind account for the site's Active Directory in the Secret
    identity/oms-ad-bind and the directory's CA in identity/oms-ad-ca. Create them by hand (see
    the sample README) or with infra/azurelocal/ad-setup.ps1.

    Azure Local steps need Azure (Cluster, Images), the cluster's network (Ingress, Keycloak) or
    both (Registry), so they run in two stages, the way a site whose management machine can't reach
    Azure has to:
      -Stage Azure  where Azure is reachable: Cluster, Images and the Azure part of Registry
      -Stage Site   on the site network, with no Azure sign-in: the site part of Registry, Ingress,
                    Keycloak
    The Azure stage leaves what the site needs in scripts/.handover (cluster credentials, a registry
    pull token); the Site stage takes it over and deletes the secrets. On two machines, copy that
    folder across in between. The default, -Stage All, runs both stages in a row on this machine,
    through the same folder.

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
        # Before Keycloak, which takes the app's address from the ingress.
        Ingress  = 'infra/azurelocal/provision-ingress.ps1'
        Keycloak = 'infra/azurelocal/keycloak.ps1'
    }
}

$settings = Read-OmsSettings $Target $SettingsPath
$handoverPath = Join-Path $PSScriptRoot '.handover'
# Which steps each stage runs; Registry runs in both, each doing its own part.
$stageSteps = @{ All = @($steps.Keys); Azure = @('Cluster', 'Images', 'Registry'); Site = @('Registry', 'Ingress', 'Keycloak') }
$stages = Get-OmsStages $Target $Stage
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
    foreach ($currentStage in $stages) {
        if ($stages.Count -gt 1) { Write-Host "`n======== $Target, $currentStage stage ========" -ForegroundColor Magenta }
        $previousSubscription = $null
        try {
            if (-not $WhatIfPreference) {
                # The Site stage must work with no Azure sign-in at all, so it never touches az.
                if ($currentStage -eq 'Site') { Import-OmsHandoverKubeconfig $handoverPath }
                else { $previousSubscription = Select-OmsSubscription $settings }
            }

            foreach ($step in $steps.Keys) {
                if ($step -in $Skip -or $step -notin $stageSteps[$currentStage]) {
                    Write-Host "==> [$Target] $step skipped" -ForegroundColor DarkGray
                    continue
                }
                $script = Join-Path $PSScriptRoot $steps[$step]
                $arguments = Get-OmsStepArguments $settings $step $script
                if ($currentStage -ne 'All' -and (Get-Command $script).Parameters.ContainsKey('Stage')) { $arguments['Stage'] = $currentStage }
                $shown = ($arguments.GetEnumerator() | Sort-Object Key | ForEach-Object { "-$($_.Key) $(@($_.Value) -join ',')" }) -join ' '
                if ($PSCmdlet.ShouldProcess("scripts/$($steps[$step]) $shown", "$Target $step")) {
                    Write-Host "`n==> [$Target] $step : scripts/$($steps[$step])" -ForegroundColor Magenta
                    & $script @arguments
                }
            }
        }
        finally {
            Restore-OmsSubscription $previousSubscription
        }
    }
    if (-not $WhatIfPreference) {
        if ($Stage -eq 'Azure') {
            Write-Host "`nAzure stage done. Copy scripts/.handover to the site machine and run: ./scripts/setup-platform.ps1 -Target $Target -Stage Site" -ForegroundColor Green
        }
        else {
            $deployHint = if ($Stage -eq 'Site') { "./scripts/deploy.ps1 -Target $Target -Stage Azure (where Azure is reachable), then -Stage Site here" } else { "./scripts/deploy.ps1 -Target $Target" }
            Write-Host "`nPlatform ready for $Target. Deploy the app with: $deployHint" -ForegroundColor Green
        }
    }
}
finally {
    Pop-Location
}
