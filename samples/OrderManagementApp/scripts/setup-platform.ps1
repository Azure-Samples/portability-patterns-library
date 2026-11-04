#Requires -Version 7.3
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
      KeyVault  infra/azurelocal/key-vault.ps1               database passwords in Key Vault, synced into the cluster
      Ingress   infra/azurelocal/provision-ingress.ps1       NGINX ingress, site CA, renewed certificates
      Operators infra/azurelocal/provision-operators.ps1     CloudNativePG and RabbitMQ operators: replicas, failover, backups
                                                             (only with Availability 'high')
      ObjectStore infra/azurelocal/provision-object-store.ps1  S3 storage in the cluster for the app's objects and the database backups
      Keycloak  infra/azurelocal/keycloak.ps1                on-site sign-in and token issuer, federated to Active Directory
      Observability infra/azurelocal/provision-observability.ps1  metrics, logs, traces, alerts and Grafana, in the cluster
    Values come from the target's section of scripts/settings.json (see settings.example.json):
    'Common' goes to every step that takes the parameter, a section named after the step to that
    step only. Keep secrets out of it; the scripts read those from Kubernetes Secrets.

    On Azure Local, 'Common' Availability sets how the backing services run, for the platform and
    the app alike: 'high' (the default) replicates them across nodes and backs the databases up,
    with operators; 'standard' runs one copy of each, with no operators and no backups.

    Azure Local needs a read-only bind account in the site's Active Directory for Keycloak: set
    Keycloak.AdBindUpn and Keycloak.AdCaCertificatePath, and the Keycloak step asks for the
    account's password the first time. infra/azurelocal/ad-setup.ps1 can create the account.

    On Azure Local, run it from a management machine that can sign in to Azure and reach the site
    network: some steps use both.

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
    [ValidateSet('Cluster', 'Images', 'Registry', 'KeyVault', 'Operators', 'ObjectStore', 'Keycloak', 'Ingress', 'Identity', 'Observability')]
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
        KeyVault = 'infra/azurelocal/key-vault.ps1'
        # Before Keycloak, which takes the app's address from the ingress.
        Ingress  = 'infra/azurelocal/provision-ingress.ps1'
        # Before Keycloak, whose database is a CloudNativePG cluster that backs up to the object store.
        Operators   = 'infra/azurelocal/provision-operators.ps1'
        ObjectStore = 'infra/azurelocal/provision-object-store.ps1'
        Keycloak = 'infra/azurelocal/keycloak.ps1'
        # After Keycloak, which registers Grafana's sign-in client and its secret.
        Observability = 'infra/azurelocal/provision-observability.ps1'
    }
}

$settings = Read-OmsSettings $Target $SettingsPath
# Only highly available backing services need the operators.
$availability = if ($settings.ContainsKey('Common')) { $settings['Common']['Availability'] }
if ($Target -eq 'AzureLocal' -and $availability -eq 'standard') {
    $steps.Remove('Operators')
}
Push-Location (Split-Path -Parent $PSScriptRoot)
$previousSubscription = if ($WhatIfPreference) { $null } else { Select-OmsSubscription $settings }
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
    Restore-OmsSubscription $previousSubscription
    Pop-Location
}