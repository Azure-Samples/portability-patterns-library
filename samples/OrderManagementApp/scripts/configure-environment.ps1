#Requires -Version 7.0
<#
.SYNOPSIS
    Configures the sample's Radius Recipe Pack and Environment on an existing platform.
.DESCRIPTION
    Run after platform setup, or on a platform prepared by your platform team. Uses Common and
    relevant Deploy settings for compatibility; Environment settings override those values.
    This step owns Radius configuration, not application images or database credentials.
.EXAMPLE
    ./scripts/configure-environment.ps1 -Target AzureLocal
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Azure', 'AzureLocal')]
    [string]$Target,
    [string]$SettingsPath
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/lib/settings.ps1"
$script = Join-Path $PSScriptRoot "infra/$($Target.ToLowerInvariant())/configure-environment.ps1"
$settings = Read-OmsSettings $Target $SettingsPath
$arguments = Get-OmsEnvironmentArguments $settings $script
$previousSubscription = Select-OmsSubscription $settings
try { & $script @arguments }
finally { Restore-OmsSubscription $previousSubscription }
