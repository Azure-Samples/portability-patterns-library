#Requires -Version 7.3
<#
.SYNOPSIS
    Brings the Order Management sample up in one command: checks the site, sets up the platform
    and deploys the app.

.DESCRIPTION
    Runs, in order:
      1. scripts/infra/azurelocal/preflight.ps1   (Azure Local only; stops on any FAIL)
      2. scripts/setup-platform.ps1               cluster, registry, Key Vault, sign-in, ingress, monitoring
      3. scripts/deploy.ps1                       images, Recipes, rad deploy
    Every step is idempotent, so re-running it updates what is there. Values come from
    scripts/settings.json, as for the scripts it runs.

    On Azure Local, run it from a management machine that can sign in to Azure and reach the site
    network.

    Before the first run on Azure Local, the site's Active Directory needs the app's groups and a
    bind account for Keycloak; see "Connect your Active Directory" in docs/authentication.md.

.EXAMPLE
    ./scripts/up.ps1 -Target AzureLocal

.EXAMPLE
    # The cluster already exists.
    ./scripts/up.ps1 -Target AzureLocal -Skip Cluster
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Azure', 'AzureLocal')]
    [string]$Target,
    # Platform steps to leave out, as for setup-platform.ps1.
    [ValidateSet('Cluster', 'Images', 'Registry', 'KeyVault', 'Operators', 'ObjectStore', 'Keycloak', 'Ingress', 'Identity', 'Observability')]
    [string[]]$Skip = @(),
    [string]$SettingsPath,
    [switch]$SkipPreflight
)

$ErrorActionPreference = 'Stop'

$common = @{ Target = $Target }
if ($SettingsPath) { $common.SettingsPath = $SettingsPath }

if ($Target -eq 'AzureLocal' -and -not $SkipPreflight) {
    Write-Host "`n######## Preflight ########" -ForegroundColor Magenta
    $preflightArgs = @{ Skip = $Skip }
    if ($SettingsPath) { $preflightArgs.SettingsPath = $SettingsPath }
    & (Join-Path $PSScriptRoot 'infra/azurelocal/preflight.ps1') @preflightArgs
    if ($LASTEXITCODE -ne 0) { throw 'Preflight failed. Fix the FAIL lines above and run this again.' }
}

Write-Host "`n######## Platform ########" -ForegroundColor Magenta
& (Join-Path $PSScriptRoot 'setup-platform.ps1') @common -Skip $Skip

Write-Host "`n######## App ########" -ForegroundColor Magenta
& (Join-Path $PSScriptRoot 'deploy.ps1') @common

Write-Host "`nThe app is up. Its address is printed above." -ForegroundColor Green