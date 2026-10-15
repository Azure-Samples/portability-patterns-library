<#
.SYNOPSIS
    Registers the orders app with the in-cluster Keycloak so the unchanged MSAL.js browser app and
    Microsoft.Identity.Web API run against it exactly as they would against Entra ID.

.DESCRIPTION
    Everything here is platform configuration; the application keeps its Entra assumptions and
    Keycloak is made to issue tokens of the same shape:

      bcd-orders-api    the API's identity; access tokens carry it in 'aud', like an Entra API app
      bcd-orders-spa    public SPA client: authorization code + PKCE, redirect to -SpaOrigins
      client scope      'api://bcd-orders-api/access_as_user', the name an Entra app requests; adds
                        aud, scp=access_as_user, a flat 'roles' claim (Entra app roles) and 'oid'
      realm roles       Orders.Read   <- AD group bcd-app-readers
                        Orders.Create <- AD group bcd-app-writers

    The Entra equivalent is an API app registration exposing 'access_as_user' with app roles
    Orders.Read and Orders.Create assigned to groups, plus a SPA app registration.

    Idempotent. Uses the Keycloak admin REST API with the generated 'keycloak-admin' secret, which
    is never printed.

.PARAMETER SpaOrigins
    Origins the browser app is served from. MSAL needs a secure context, so either HTTPS or
    http://localhost (kubectl port-forward).

.EXAMPLE
    ./scripts/azurelocal/configure-app-identity.ps1
#>
[CmdletBinding()]
param(
    [string]$KubeContext = 'bcd-aksarc',
    [string]$IdentityNamespace = 'identity',
    [string]$Realm = 'bcd',
    [int]$NodePort = 30443,
    [string[]]$SpaOrigins = @('http://localhost:5090'),
    [string]$ApiClientId = 'bcd-orders-api',
    [string]$SpaClientId = 'bcd-orders-spa',
    [string]$ApiScopeName = 'access_as_user',
    [string]$ReaderGroup = 'bcd-app-readers',
    [string]$WriterGroup = 'bcd-app-writers'
)

$ErrorActionPreference = 'Stop'

$nodeIp = kubectl get nodes --context $KubeContext -o 'jsonpath={.items[0].status.addresses[?(@.type=="InternalIP")].address}'
if ($LASTEXITCODE -ne 0 -or -not $nodeIp) { throw "Could not read a node address from context '$KubeContext'." }
$base = "https://${nodeIp}:$NodePort"

$adminPassword = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(
        (kubectl get secret keycloak-admin -n $IdentityNamespace --context $KubeContext -o 'jsonpath={.data.password}')))
# Keycloak's certificate is from the site's private CA, which this machine does not trust.
$adminToken = (Invoke-RestMethod -Method Post -Uri "$base/realms/master/protocol/openid-connect/token" -SkipCertificateCheck `
        -Body @{ client_id = 'admin-cli'; grant_type = 'password'; username = 'admin'; password = $adminPassword }).access_token
$adminPassword = $null
$headers = @{ Authorization = "Bearer $adminToken" }

function Invoke-Kc {
    param([string]$Method, [string]$Path, $Body)

    $arguments = @{
        Method               = $Method
        Uri                  = "$base/admin/realms/$Realm$Path"
        Headers              = $headers
        SkipCertificateCheck = $true
        ContentType          = 'application/json'
    }
    if ($null -ne $Body) { $arguments.Body = ConvertTo-Json -InputObject $Body -Depth 10 }
    Invoke-RestMethod @arguments
}

function Get-ClientUuid([string]$ClientId) {
    (Invoke-Kc GET "/clients?clientId=$([uri]::EscapeDataString($ClientId))") | Select-Object -First 1 -ExpandProperty id
}

function Set-Client([hashtable]$Definition) {
    $uuid = Get-ClientUuid $Definition.clientId
    if (-not $uuid) {
        Invoke-Kc POST '/clients' $Definition | Out-Null
        return Get-ClientUuid $Definition.clientId
    }
    $Definition.id = $uuid
    Invoke-Kc PUT "/clients/$uuid" $Definition | Out-Null
    return $uuid
}

function Get-RealmRole([string]$Name) {
    Invoke-Kc GET "/roles/$([uri]::EscapeDataString($Name))"
}

Write-Host "==> Realm roles" -ForegroundColor Cyan
$existingRoles = @((Invoke-Kc GET '/roles').name)
$roleDescriptions = @{ 'Orders.Read' = 'View own orders'; 'Orders.Create' = 'Place orders' }
foreach ($role in $roleDescriptions.Keys) {
    if ($existingRoles -notcontains $role) {
        Invoke-Kc POST '/roles' @{ name = $role; description = $roleDescriptions[$role] } | Out-Null
    }
    Write-Host "    $role" -ForegroundColor DarkGray
}

Write-Host "==> API client '$ApiClientId'" -ForegroundColor Cyan
# Exists only to be the token audience, like an Entra API app registration with no flows.
Set-Client @{
    clientId                  = $ApiClientId
    name                      = 'Orders API'
    enabled                   = $true
    publicClient              = $false
    bearerOnly                = $false
    standardFlowEnabled       = $false
    directAccessGrantsEnabled = $false
    serviceAccountsEnabled    = $false
    implicitFlowEnabled       = $false
} | Out-Null

$scopeName = "api://$ApiClientId/$ApiScopeName"
Write-Host "==> Client scope '$scopeName'" -ForegroundColor Cyan
$scope = (Invoke-Kc GET '/client-scopes') | Where-Object name -eq $scopeName
if (-not $scope) {
    Invoke-Kc POST '/client-scopes' @{
        name        = $scopeName
        description = 'Access the orders API as the signed-in user'
        protocol    = 'openid-connect'
        attributes  = @{ 'include.in.token.scope' = 'true'; 'display.on.consent.screen' = 'false' }
    } | Out-Null
    $scope = (Invoke-Kc GET '/client-scopes') | Where-Object name -eq $scopeName
}

# Shapes the access token like Entra's, so Microsoft.Identity.Web needs no Keycloak awareness.
$mappers = @(
    @{
        name           = 'audience'
        protocol       = 'openid-connect'
        protocolMapper = 'oidc-audience-mapper'
        config         = @{ 'included.client.audience' = $ApiClientId; 'access.token.claim' = 'true'; 'id.token.claim' = 'false' }
    }
    @{
        # Entra puts the bare scope name in 'scp'; RequireScope reads it.
        name           = 'scp'
        protocol       = 'openid-connect'
        protocolMapper = 'oidc-hardcoded-claim-mapper'
        config         = @{ 'claim.name' = 'scp'; 'claim.value' = $ApiScopeName; 'jsonType.label' = 'String'; 'access.token.claim' = 'true' }
    }
    @{
        # Entra app roles arrive as a flat 'roles' array; Keycloak nests realm roles otherwise.
        name           = 'roles'
        protocol       = 'openid-connect'
        protocolMapper = 'oidc-usermodel-realm-role-mapper'
        config         = @{ 'claim.name' = 'roles'; 'multivalued' = 'true'; 'jsonType.label' = 'String'; 'access.token.claim' = 'true'; 'id.token.claim' = 'false' }
    }
    @{
        name           = 'oid'
        protocol       = 'openid-connect'
        protocolMapper = 'oidc-usermodel-property-mapper'
        config         = @{ 'user.attribute' = 'id'; 'claim.name' = 'oid'; 'jsonType.label' = 'String'; 'access.token.claim' = 'true'; 'id.token.claim' = 'false' }
    }
)
$existingMappers = @((Invoke-Kc GET "/client-scopes/$($scope.id)/protocol-mappers/models").name)
foreach ($mapper in $mappers) {
    if ($existingMappers -notcontains $mapper.name) {
        Invoke-Kc POST "/client-scopes/$($scope.id)/protocol-mappers/models" $mapper | Out-Null
    }
    Write-Host "    mapper $($mapper.name)" -ForegroundColor DarkGray
}

Write-Host "==> SPA client '$SpaClientId' ($($SpaOrigins -join ', '))" -ForegroundColor Cyan
$spaUuid = Set-Client @{
    clientId                  = $SpaClientId
    name                      = 'Orders web app'
    enabled                   = $true
    publicClient              = $true
    standardFlowEnabled       = $true
    directAccessGrantsEnabled = $false
    implicitFlowEnabled       = $false
    redirectUris              = @($SpaOrigins | ForEach-Object { "$_/*" })
    webOrigins                = @($SpaOrigins)
    attributes                = @{
        'pkce.code.challenge.method' = 'S256'
        'post.logout.redirect.uris'  = (@($SpaOrigins | ForEach-Object { "$_/*" }) -join '##')
    }
}
Invoke-Kc PUT "/clients/$spaUuid/optional-client-scopes/$($scope.id)" | Out-Null

Write-Host "==> Mapping AD groups to roles" -ForegroundColor Cyan
$provider = (Invoke-Kc GET '/components?type=org.keycloak.storage.UserStorageProvider') | Where-Object name -eq 'active-directory'
if (-not $provider) { throw "No 'active-directory' user federation in realm '$Realm'. Run scripts/azurelocal/keycloak.ps1 first." }
$groupMapper = (Invoke-Kc GET "/components?parent=$($provider.id)") | Where-Object name -eq 'group-mapper'
# LDAP groups only appear in Keycloak after a sync or a member's login; sync so they can be mapped.
Invoke-Kc POST "/user-storage/$($provider.id)/mappers/$($groupMapper.id)/sync?direction=fedToKeycloak" | Out-Null

foreach ($pair in @(@{ Group = $ReaderGroup; Role = 'Orders.Read' }, @{ Group = $WriterGroup; Role = 'Orders.Create' })) {
    $group = (Invoke-Kc GET "/groups?search=$($pair.Group)&exact=true") | Select-Object -First 1
    if (-not $group) { throw "Group '$($pair.Group)' was not synchronised from the directory." }
    $role = Get-RealmRole $pair.Role
    Invoke-Kc POST "/groups/$($group.id)/role-mappings/realm" @(@{ id = $role.id; name = $role.name }) | Out-Null
    Write-Host "    $($pair.Group) -> $($pair.Role)" -ForegroundColor DarkGray
}

Write-Host "`nIssuer        : $base/realms/$Realm" -ForegroundColor Green
Write-Host "SPA client    : $SpaClientId"
Write-Host "API audience  : $ApiClientId"
Write-Host "API scope     : $scopeName"
