#Requires -Version 7.0
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

    Azure Local deploys in two stages, the way a site whose management machine can't reach Azure
    has to: -Stage Azure where Azure is reachable (build, push, publish Recipes, record the image
    and Recipe digests in scripts/.handover/release.json), then -Stage Site on the site network with
    no Azure sign-in (rad install, rad deploy). On two machines, copy scripts/.handover across in
    between.
    The default, -Stage All, runs both in a row on this machine, through the same folder.

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

Push-Location (Split-Path -Parent $PSScriptRoot)
try {
    foreach ($currentStage in (Get-OmsStages $Target $Stage)) {
        if ($currentStage -ne 'All') { $arguments['Stage'] = $currentStage }
        $previousSubscription = $null
        try {
            if ($currentStage -eq 'Site') {
                # The Site stage must work with no Azure sign-in at all, so it never touches az.
                Import-OmsHandoverKubeconfig (Join-Path $PSScriptRoot '.handover')
            }
            else { $previousSubscription = Select-OmsSubscription $settings }
            & $script @arguments @args
        }
        finally {
            Restore-OmsSubscription $previousSubscription
        }
    }
    if ($Stage -eq 'Azure') {
        Write-Host "Next, copy scripts/.handover to a machine on the site network and run: ./scripts/deploy.ps1 -Target $Target -Stage Site" -ForegroundColor Green
    }
}
finally {
    Pop-Location
}
