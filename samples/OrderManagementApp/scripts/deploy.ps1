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

.EXAMPLE
    ./scripts/deploy.ps1 -Target Azure

.EXAMPLE
    ./scripts/deploy.ps1 -Target AzureLocal -SkipImageBuild -SkipRadiusInstall
#>
# Not [CmdletBinding()]: an advanced script cannot forward unknown parameters through $args.
param(
    [ValidateSet('Azure', 'AzureLocal')]
    [string]$Target,
    [string]$SettingsPath
)

$ErrorActionPreference = 'Stop'
if (-not $Target) { throw 'Specify -Target Azure or -Target AzureLocal.' }
. "$PSScriptRoot/lib/settings.ps1"

$script = Join-Path $PSScriptRoot "deploy/$($Target.ToLowerInvariant()).ps1"
$arguments = Get-OmsStepArguments (Read-OmsSettings $Target $SettingsPath) 'Deploy' $script
foreach ($argument in $args) {
    if ($argument -is [string] -and $argument -match '^-([A-Za-z]\w*):?$') { $arguments.Remove($Matches[1]) }
}

Push-Location (Split-Path -Parent $PSScriptRoot)
try {
    & $script @arguments @args
}
finally {
    Pop-Location
}
