<#
.SYNOPSIS
    Registers the orders app with Microsoft Entra ID: the Entra counterpart of the Keycloak
    realm in infra/azurelocal/keycloak/realm.json, producing the same names and claims.

.DESCRIPTION
    The registrations are declared in infra/azure/app-identity.bicep (Microsoft Graph Bicep):

      oms-api      API app registration: identifier URI api://<appId>, delegated scope
                   'access_as_user', app roles Orders.Read and Orders.Create, v2 tokens
      oms-spa      SPA app registration: redirect URIs -SpaOrigins, permission to the API scope
      assignments  Orders.Create and Orders.Read for the signed-in user, plus any groups in
                   -ReaderGroupIds / -WriterGroupIds

    This script checks the inputs, adopts registrations created before (by setting their
    uniqueName once and keeping their scope and role IDs, which Entra won't let change), and
    deploys the template. Idempotent.

.PARAMETER ServiceManagementReference
    Some tenants require new app registrations to reference a service record. Supply it if creation
    fails with a policy error.

.EXAMPLE
    ./scripts/infra/azure/configure-app-identity.ps1 -SpaOrigins https://bcd-orders.eastus2.cloudapp.azure.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$SpaOrigins,

    [string]$ApiAppName = 'oms-api',
    [string]$SpaAppName = 'oms-spa',
    [string]$ApiScopeName = 'access_as_user',
    [string[]]$ReaderGroupIds = @(),
    [string[]]$WriterGroupIds = @(),
    [switch]$SkipSignedInUserAssignment,
    [string]$ServiceManagementReference,

    # Region recorded for the deployment; the registrations themselves are tenant-wide.
    [string]$Location = 'eastus2'
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$graph = 'https://graph.microsoft.com/v1.0'

# HTTPS only. Plain http is allowed for localhost alone, as Entra itself permits.
foreach ($origin in $SpaOrigins) {
    $uri = [uri]$origin
    if ($origin -match '\*' -or -not ($uri.Scheme -eq 'https' -or ($uri.Scheme -eq 'http' -and $uri.Host -eq 'localhost'))) {
        throw "Redirect origin '$origin' is not allowed: use https (http only for localhost), without wildcards."
    }
}

# Query parameters go through --url-parameters: az.cmd hands the URL to cmd.exe, which splits it at '&'.
function Get-Application([string]$DisplayName) {
    $apps = az rest --method get --url "$graph/applications" `
        --url-parameters "`$filter=displayName eq '$DisplayName'" '$select=id,uniqueName,displayName,api,appRoles,passwordCredentials,keyCredentials' `
        --query value --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw "Looking up application '$DisplayName' failed." }
    @($apps) | Select-Object -First 1
}

$temporaryFiles = @()
try {
    $me = az ad signed-in-user show --query id --output tsv
    if ($LASTEXITCODE -ne 0 -or -not $me) { throw 'Sign in with az login as a user first.' }

    $ids = @{}
    foreach ($name in $ApiAppName, $SpaAppName) {
        $app = Get-Application $name
        if (-not $app) { continue }

        if (@($app.passwordCredentials).Count -or @($app.keyCredentials).Count) {
            throw "'$name' holds secrets or certificates; this app needs none. Remove them first."
        }

        # The template finds a registration by its uniqueName, which can be set once and never changed.
        if (-not $app.uniqueName) {
            Write-Host "==> Adopting existing app registration '$name'" -ForegroundColor Cyan
            $body = New-TemporaryFile; $temporaryFiles += $body
            Set-Content -Path $body -Value (@{ uniqueName = $name } | ConvertTo-Json -Compress) -Encoding ascii
            az rest --method patch --url "$graph/applications/$($app.id)" --headers 'Content-Type=application/json' --body "@$body" --output none
            if ($LASTEXITCODE -ne 0) { throw "Setting uniqueName on '$name' failed." }
        }

        if ($name -eq $ApiAppName) {
            $scope = @($app.api.oauth2PermissionScopes | Where-Object value -eq $ApiScopeName) | Select-Object -First 1
            if ($scope) { $ids.scopeId = $scope.id }
            $read = @($app.appRoles | Where-Object value -eq 'Orders.Read') | Select-Object -First 1
            if ($read) { $ids.readRoleId = $read.id }
            $create = @($app.appRoles | Where-Object value -eq 'Orders.Create') | Select-Object -First 1
            if ($create) { $ids.createRoleId = $create.id }
        }
    }

    $assignments = @()
    if (-not $SkipSignedInUserAssignment) {
        $assignments += @{ principalId = $me; role = 'Orders.Read' }, @{ principalId = $me; role = 'Orders.Create' }
    }
    $assignments += @($ReaderGroupIds | ForEach-Object { @{ principalId = $_; role = 'Orders.Read' } })
    $assignments += @($WriterGroupIds | ForEach-Object { @{ principalId = $_; role = 'Orders.Create' } })

    $parameters = [ordered]@{
        apiAppName                 = $ApiAppName
        spaAppName                 = $SpaAppName
        apiScopeName               = $ApiScopeName
        spaOrigins                 = @($SpaOrigins)
        ownerObjectIds             = @($me)
        roleAssignments            = @($assignments)
        serviceManagementReference = [string]$ServiceManagementReference
    }
    foreach ($key in $ids.Keys) { $parameters[$key] = $ids[$key] }
    $document = [ordered]@{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = [ordered]@{}
    }
    foreach ($key in $parameters.Keys) { $document.parameters[$key] = @{ value = $parameters[$key] } }
    $parametersFile = New-TemporaryFile; $temporaryFiles += $parametersFile
    [IO.File]::WriteAllText($parametersFile, ($document | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))

    Write-Host "==> Deploying the app registrations '$ApiAppName' and '$SpaAppName' ($($SpaOrigins -join ', '))" -ForegroundColor Cyan
    $outputsJson = az deployment sub create --name "oms-app-identity-$ApiAppName" --location $Location `
        --template-file (Join-Path $repoRoot 'infra/azure/app-identity.bicep') --parameters "@$parametersFile" `
        --query properties.outputs --output json
    if ($LASTEXITCODE -ne 0) { throw 'az deployment sub create failed.' }
    $outputs = $outputsJson | ConvertFrom-Json

    Write-Host "`nAuthority     : https://login.microsoftonline.com/$($outputs.tenantId.value)" -ForegroundColor Green
    Write-Host "API appId     : $($outputs.apiAppId.value)"
    Write-Host "SPA appId     : $($outputs.spaAppId.value)"
    Write-Host "API scope     : $($outputs.apiScope.value)"
}
finally {
    foreach ($file in $temporaryFiles) { Remove-Item $file -ErrorAction SilentlyContinue }
}