<#
.SYNOPSIS
    Registers the orders app with Microsoft Entra ID: the Entra counterpart of
    scripts/azurelocal/configure-app-identity.ps1, producing the same names and claims.

.DESCRIPTION
    Creates or updates, through Microsoft Graph:

      oms-api   API app registration: identifier URI api://<appId>, delegated scope
                       'access_as_user', app roles Orders.Read and Orders.Create, v2 tokens
      oms-spa   SPA app registration: redirect URIs -SpaOrigins, permission to the API scope
      assignments      Orders.Create (and Orders.Read) for the signed-in user, plus any groups in
                       -ReaderGroupIds / -WriterGroupIds

    Idempotent. App registrations are directory objects, not Azure resources, so they cannot live in
    a resource group or be created by a Radius Recipe without granting the Radius identity Graph
    permissions; this is the one-time platform step that does it instead.

    Security baseline applied to both registrations on every run:
      * single tenant (AzureADMyOrg), optional service management reference, purpose notes, the
        signed-in user as owner
      * no credentials at all: the SPA is a public client using auth code + PKCE, the API only
        validates tokens
      * implicit grant off, public-client fallback off, HTTPS redirect URIs only, no wildcards
      * identifier URI api://<appId>, v2 access tokens
      * app instance property lock, so no other tenant can add credentials to the service principals
      * user assignment required on the API: only users or groups granted an app role get tokens

.PARAMETER ServiceManagementReference
    Some tenants require new app registrations to reference a service record. Supply it if creation
    fails with a policy error.

.EXAMPLE
    ./scripts/azure/configure-app-identity.ps1 -SpaOrigins https://bcd-orders.eastus2.cloudapp.azure.com
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
    [string]$Notes = 'Order Management sample: one app definition deployed to Azure and Azure Local. https://github.com/Azure-Samples/portability-patterns-library/tree/main/samples/OrderManagementApp'
)

$ErrorActionPreference = 'Stop'
$graph = 'https://graph.microsoft.com/v1.0'

# HTTPS only. Plain http is allowed for localhost alone, as Entra itself permits.
foreach ($origin in $SpaOrigins) {
    $uri = [uri]$origin
    if ($origin -match '\*' -or -not ($uri.Scheme -eq 'https' -or ($uri.Scheme -eq 'http' -and $uri.Host -eq 'localhost'))) {
        throw "Redirect origin '$origin' is not allowed: use https (http only for localhost), without wildcards."
    }
}

function Invoke-Graph {
    param([string]$Method, [string]$Path, $Body)

    $arguments = @('rest', '--method', $Method, '--url', "$graph$Path", '--headers', 'Content-Type=application/json', '--only-show-errors')
    $bodyFile = $null
    if ($null -ne $Body) {
        # Passed through a file: inline JSON does not survive az.cmd's argument parsing on Windows.
        $bodyFile = New-TemporaryFile
        [IO.File]::WriteAllText($bodyFile, (ConvertTo-Json -InputObject $Body -Depth 10), [Text.UTF8Encoding]::new($false))
        $arguments += @('--body', "@$bodyFile")
    }
    try {
        $output = az @arguments
        if ($LASTEXITCODE -ne 0) { throw "Graph $Method $Path failed." }
        if ($output) { return ($output | Out-String | ConvertFrom-Json) }
    }
    finally {
        if ($bodyFile) { Remove-Item $bodyFile -ErrorAction SilentlyContinue }
    }
}

function Get-Application([string]$DisplayName) {
    $filter = [uri]::EscapeDataString("displayName eq '$DisplayName'")
    @((Invoke-Graph GET "/applications?`$filter=$filter").value) | Select-Object -First 1
}

function New-Application([string]$DisplayName) {
    $body = @{ displayName = $DisplayName; signInAudience = 'AzureADMyOrg' }
    if ($ServiceManagementReference) { $body.serviceManagementReference = $ServiceManagementReference }
    Invoke-Graph POST '/applications' $body
}

# Re-applied on every run so drift (a portal edit, an older registration) is corrected.
function Set-SfiBaseline($Application) {
    $body = @{
        signInAudience                    = 'AzureADMyOrg'
        notes                             = $Notes
        isFallbackPublicClient            = $false
        web                               = @{ implicitGrantSettings = @{ enableAccessTokenIssuance = $false; enableIdTokenIssuance = $false } }
        servicePrincipalLockConfiguration = @{ isEnabled = $true; allProperties = $true }
    }
    if ($ServiceManagementReference) { $body.serviceManagementReference = $ServiceManagementReference }
    Invoke-Graph PATCH "/applications/$($Application.id)" $body | Out-Null

    $credentials = Invoke-Graph GET "/applications/$($Application.id)?`$select=passwordCredentials,keyCredentials"
    if (@($credentials.passwordCredentials).Count -or @($credentials.keyCredentials).Count) {
        throw "'$($Application.displayName)' holds secrets or certificates; this app needs none. Remove them first."
    }

    $owners = @((Invoke-Graph GET "/applications/$($Application.id)/owners?`$select=id").value.id)
    if ($owners -notcontains $script:me.id) {
        Invoke-Graph POST "/applications/$($Application.id)/owners/`$ref" @{ '@odata.id' = "$graph/directoryObjects/$($script:me.id)" } | Out-Null
    }
}

function Get-ServicePrincipal([string]$AppId) {
    $filter = [uri]::EscapeDataString("appId eq '$AppId'")
    $sp = @((Invoke-Graph GET "/servicePrincipals?`$filter=$filter").value) | Select-Object -First 1
    if (-not $sp) { $sp = Invoke-Graph POST '/servicePrincipals' @{ appId = $AppId } }
    return $sp
}

# Stable IDs keep re-runs from replacing the scope and roles, which would break existing assignments.
function Get-StableId([string]$Seed) {
    $hash = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Seed))
    [guid]::new([byte[]]$hash[0..15]).ToString()
}

$tenantId = az account show --query tenantId -o tsv
$script:me = Invoke-Graph GET '/me?$select=id,userPrincipalName'
Write-Host "==> Tenant $tenantId (owner $($script:me.userPrincipalName))" -ForegroundColor Cyan

Write-Host "==> API app registration '$ApiAppName'" -ForegroundColor Cyan
$api = Get-Application $ApiAppName
if (-not $api) { $api = New-Application $ApiAppName }
Set-SfiBaseline $api

$scopeId = Get-StableId "$($api.appId)/scope/$ApiScopeName"
$roles = @(
    @{ value = 'Orders.Read'; displayName = 'Read orders'; description = 'View own orders' }
    @{ value = 'Orders.Create'; displayName = 'Create orders'; description = 'Place orders' }
) | ForEach-Object {
    @{
        id                 = Get-StableId "$($api.appId)/role/$($_.value)"
        value              = $_.value
        displayName        = $_.displayName
        description        = $_.description
        allowedMemberTypes = @('User')
        isEnabled          = $true
    }
}

# A scope must exist before anything can be pre-authorized for it, so the API is updated in two passes.
Invoke-Graph PATCH "/applications/$($api.id)" @{
    identifierUris = @("api://$($api.appId)")
    appRoles       = $roles
    api            = @{
        requestedAccessTokenVersion = 2
        oauth2PermissionScopes      = @(@{
                id                      = $scopeId
                value                   = $ApiScopeName
                type                    = 'User'
                isEnabled               = $true
                adminConsentDisplayName = 'Access the orders API'
                adminConsentDescription = 'Lets the app call the orders API as the signed-in user.'
                userConsentDisplayName  = 'Access the orders API'
                userConsentDescription  = 'Lets the app call the orders API on your behalf.'
            })
    }
} | Out-Null
$apiSp = Get-ServicePrincipal $api.appId
# Only users or groups holding an app role can obtain tokens for the API.
Invoke-Graph PATCH "/servicePrincipals/$($apiSp.id)" @{ appRoleAssignmentRequired = $true; notes = $Notes } | Out-Null
Write-Host "    appId $($api.appId), scope api://$($api.appId)/$ApiScopeName" -ForegroundColor DarkGray

Write-Host "==> SPA app registration '$SpaAppName' ($($SpaOrigins -join ', '))" -ForegroundColor Cyan
$spa = Get-Application $SpaAppName
if (-not $spa) { $spa = New-Application $SpaAppName }
Set-SfiBaseline $spa
Invoke-Graph PATCH "/applications/$($spa.id)" @{
    spa                    = @{ redirectUris = @($SpaOrigins | ForEach-Object { "$_/" }) }
    requiredResourceAccess = @(@{
            resourceAppId  = $api.appId
            resourceAccess = @(@{ id = $scopeId; type = 'Scope' })
        })
} | Out-Null
Get-ServicePrincipal $spa.appId | Out-Null
Write-Host "    appId $($spa.appId)" -ForegroundColor DarkGray

# Pre-authorizing the SPA spares users a consent prompt, as an admin-consented Entra app would.
$preAuthorized = @(@{ appId = $spa.appId; delegatedPermissionIds = @($scopeId) })
Invoke-Graph PATCH "/applications/$($api.id)" @{
    api = @{ preAuthorizedApplications = $preAuthorized }
} | Out-Null

Write-Host "==> App role assignments" -ForegroundColor Cyan
$existing = @((Invoke-Graph GET "/servicePrincipals/$($apiSp.id)/appRoleAssignedTo").value)
function Grant-Role([string]$PrincipalId, [string]$RoleValue, [string]$Label) {
    $roleId = ($roles | Where-Object value -eq $RoleValue).id
    if (-not ($existing | Where-Object { $_.principalId -eq $PrincipalId -and $_.appRoleId -eq $roleId })) {
        Invoke-Graph POST "/servicePrincipals/$($apiSp.id)/appRoleAssignedTo" @{
            principalId = $PrincipalId; resourceId = $apiSp.id; appRoleId = $roleId
        } | Out-Null
    }
    Write-Host "    $Label -> $RoleValue" -ForegroundColor DarkGray
}

if (-not $SkipSignedInUserAssignment) {
    Grant-Role $script:me.id 'Orders.Read' $script:me.userPrincipalName
    Grant-Role $script:me.id 'Orders.Create' $script:me.userPrincipalName
}
foreach ($group in $ReaderGroupIds) { Grant-Role $group 'Orders.Read' "group $group" }
foreach ($group in $WriterGroupIds) { Grant-Role $group 'Orders.Create' "group $group" }

Write-Host "`nAuthority     : https://login.microsoftonline.com/$tenantId" -ForegroundColor Green
Write-Host "API appId     : $($api.appId)"
Write-Host "SPA appId     : $($spa.appId)"
Write-Host "API scope     : api://$($api.appId)/$ApiScopeName"
