#Requires -Version 7.0
<#
.SYNOPSIS
    Brings the Order Management sample up in one command: checks the site, sets up the platform
    and deploys the app.

.DESCRIPTION
    Runs, in order:
      1. scripts/infra/azurelocal/preflight.ps1   (Azure Local only; stops on any FAIL)
      2. scripts/setup-platform.ps1               cluster, registry, sign-in, ingress
      3. scripts/deploy.ps1                       images, Recipes, rad deploy
    Every step is idempotent, so re-running it updates what is there. Values come from
    scripts/settings.json, as for the scripts it runs.

    Azure Local runs in two stages (see setup-platform.ps1). By default both run on this machine.
    When the machine that can sign in to Azure can't reach the site network, run -Stage Azure there,
    copy scripts/.handover to the same place in a checkout on a machine on the site network, and run
    -Stage Site on that one. The Site stage needs no Azure sign-in.

    Before the first run on Azure Local, the site's Active Directory needs the app's groups and a
    bind account for Keycloak; see "Connect your Active Directory" in docs/authentication.md.

.EXAMPLE
    ./scripts/up.ps1 -Target AzureLocal

.EXAMPLE
    # No machine reaches both Azure and the site network.
    ./scripts/up.ps1 -Target AzureLocal -Stage Azure   # where Azure is reachable
    ./scripts/up.ps1 -Target AzureLocal -Stage Site    # on the site network, after copying scripts/.handover

.EXAMPLE
    # The cluster already exists.
    ./scripts/up.ps1 -Target AzureLocal -Skip Cluster
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Azure', 'AzureLocal')]
    [string]$Target,
    [ValidateSet('All', 'Azure', 'Site')]
    [string]$Stage = 'All',
    # Platform steps to leave out, as for setup-platform.ps1.
    [ValidateSet('Cluster', 'Images', 'Registry', 'Keycloak', 'Ingress', 'Identity')]
    [string[]]$Skip = @(),
    [string]$SettingsPath,
    [switch]$SkipPreflight
)

$ErrorActionPreference = 'Stop'
if ($Target -eq 'Azure' -and $Stage -ne 'All') { throw '-Stage applies to -Target AzureLocal only.' }
. "$PSScriptRoot/lib/settings.ps1"

$common = @{ Target = $Target }
if ($SettingsPath) { $common.SettingsPath = $SettingsPath }
if ($Target -eq 'AzureLocal') { $common.Stage = $Stage }

if ($Target -eq 'AzureLocal' -and -not $SkipPreflight) {
    # Preflight checks the cluster with the credentials the Azure stage handed over.
    if ($Stage -eq 'Site') { Import-OmsHandoverKubeconfig (Join-Path $PSScriptRoot '.handover') }

    Write-Host "`n######## Preflight ########" -ForegroundColor Magenta
    $preflightArgs = @{ Stage = $Stage }
    if ($SettingsPath) { $preflightArgs.SettingsPath = $SettingsPath }
    & (Join-Path $PSScriptRoot 'infra/azurelocal/preflight.ps1') @preflightArgs
    if ($LASTEXITCODE -ne 0) { throw 'Preflight failed. Fix the FAIL lines above and run this again.' }
}

Write-Host "`n######## Platform ########" -ForegroundColor Magenta
& (Join-Path $PSScriptRoot 'setup-platform.ps1') @common -Skip $Skip

Write-Host "`n######## App ########" -ForegroundColor Magenta
& (Join-Path $PSScriptRoot 'deploy.ps1') @common

if ($Stage -eq 'Azure') {
    Write-Host "`nAzure stage done. Copy scripts/.handover to the same place in a checkout on a machine on the site network, then run there: ./scripts/up.ps1 -Target AzureLocal -Stage Site" -ForegroundColor Green
}
else {
    Write-Host "`nThe app is up. Its address is printed above." -ForegroundColor Green
}
