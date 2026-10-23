<#
.SYNOPSIS
    Deploys the Order Management sample: the same deploy/app.bicep and images to Azure or to
    Azure Local.

.DESCRIPTION
    Application-team step, after ./scripts/setup-platform.ps1. Builds and pushes the images,
    publishes the Recipes and runs 'rad deploy'. The target's Recipe Pack, not the application,
    decides what backs the queue, object storage and database.

    Values come from the 'Common' and 'Deploy' sections of the target in scripts/settings.json. Any
    other argument goes to scripts/deploy/<target>.ps1 and wins over the settings file.

    Azure Local, when no machine reaches both Azure and the site: run -Stage Azure where Azure is
    reachable (build, push, publish Recipes), copy scripts/.handover to a machine on the site
    network, and run -Stage Site there (rad install, rad deploy).

.EXAMPLE
    ./scripts/deploy.ps1 -Target Azure

.EXAMPLE
    ./scripts/deploy.ps1 -Target AzureLocal -SkipImageBuild -SkipRadiusInstall

.EXAMPLE
    ./scripts/deploy.ps1 -Target AzureLocal -Stage Azure   # where Azure is reachable
    ./scripts/deploy.ps1 -Target AzureLocal -Stage Site    # on the site network
#>
# Not [CmdletBinding()]: an advanced script cannot forward unknown parameters through $args.
param(
    [ValidateSet('Azure', 'AzureLocal')]
    [string]$Target,
    [string]$SettingsPath,
    [ValidateSet('All', 'Azure', 'Site')]
    [string]$Stage = 'All'
)

$ErrorActionPreference = 'Stop'
if (-not $Target) { throw 'Specify -Target Azure or -Target AzureLocal.' }
if ($Target -eq 'Azure' -and $Stage -ne 'All') { throw '-Stage applies to -Target AzureLocal only.' }
. "$PSScriptRoot/lib/settings.ps1"

$script = Join-Path $PSScriptRoot "deploy/$($Target.ToLowerInvariant()).ps1"
$settings = Read-OmsSettings $Target $SettingsPath
$arguments = Get-OmsStepArguments $settings 'Deploy' $script
foreach ($argument in $args) {
    if ($argument -is [string] -and $argument -match '^-([A-Za-z]\w*):?$') { $arguments.Remove($Matches[1]) }
}
if ($Stage -ne 'All') { $arguments['Stage'] = $Stage }

$previousSubscription = $null
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
    # The site machine may have no Azure sign-in at all.
    if ($Stage -ne 'Site') { $previousSubscription = Select-OmsSubscription $settings }
    & $script @arguments @args
}
finally {
    Restore-OmsSubscription $previousSubscription
    Pop-Location
}
