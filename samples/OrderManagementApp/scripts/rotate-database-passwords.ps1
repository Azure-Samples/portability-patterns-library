#Requires -Version 7.0
<#
.SYNOPSIS
    Applies Azure Local database password changes explicitly, without building or deploying images.
.DESCRIPTION
    Run after updating Key Vault and waiting for synchronization. Common and relevant Deploy
    settings provide defaults; Rotation overrides them. Azure uses password-free Entra credentials.
.EXAMPLE
    ./scripts/rotate-database-passwords.ps1
#>
[CmdletBinding()]
param([string]$SettingsPath)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/lib/settings.ps1"
$settings = Read-OmsSettings 'AzureLocal' $SettingsPath
$script = Join-Path $PSScriptRoot 'infra/azurelocal/rotate-database-passwords.ps1'
$arguments = Get-OmsEnvironmentArguments $settings $script 'Rotation'
& $script @arguments
