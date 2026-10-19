<#
.SYNOPSIS
    Deploys Keycloak onto the cluster as the token issuer that fronts Active Directory, replacing
    the role Entra plays in a connected Azure deployment.

.DESCRIPTION
    On AKS a pod obtains a token by presenting its ServiceAccount token to Entra, which trusts the
    cluster's OIDC issuer and returns a credential for a federated managed identity. Every part of
    that exchange happens outside the site, so it stops working the moment the link does.

    This rebuilds the same shape with nothing outside the site in the path:

      the cluster issues a ServiceAccount token  ->  Keycloak verifies it against the cluster JWKS and
      exchanges it for an access token   ->  the workload presents that token to a backing service

    Keycloak gets its users and groups from the domain controller over LDAP, so the directory
    stays the single source of truth and the same accounts work for the API calls added later.
    The 'kubernetes' identity provider below is the trust statement that corresponds to a
    federated identity credential on a managed identity.

    Keycloak trusts the cluster's ServiceAccount token issuer. On AKS enabled by Arc that is the
    default in-cluster issuer, which Keycloak can resolve because it runs in the same cluster: pass
    -AllowInClusterIssuer. A cluster configured with an externally reachable issuer needs no switch.

.PARAMETER AdServer
    Host name of the site's domain controller (prepared in the lab by lab/azurelocal/ad-setup.ps1). Under LDAPS this must
    be the name in the controller's certificate, not its address, or the handshake fails.

.PARAMETER Registry
    Registry holding the mirrored Keycloak and PostgreSQL images, normally the in-cluster connected registry.
    Omit to pull from the public registries, which only works where the cluster has internet.

.PARAMETER UseLdaps
    Bind to the directory over LDAPS on 636, which is the default. The certificate comes from the
    directory's enterprise CA, handed over in the '' Secret. Pass -UseLdaps:$false to fall back to plain LDAP on
    389, which sends the bind password and every user password across the network in the clear.

.EXAMPLE
    ./scripts/azurelocal/keycloak.ps1 -AdServer dc01.azurelocal.lab -AdDomain azurelocal.lab `
        -Registry 10.96.0.50 -AllowInClusterIssuer
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$AdServer,
    [string]$AdDomain = 'azurelocal.lab',
    [string]$AdOuName = 'OMS',
    [switch]$UseLdaps = $true,

    [string]$KubeContext = 'bcd-aksarc',
    [string]$Namespace = 'identity',
    [string]$ReleaseName = 'keycloak',

    [string]$Registry,
    [string]$ImagePullSecretName = 'azurelocal-registry',
    [string]$ImagePullSecretSourceNamespace = 'oms-azurelocal',
    [string]$KeycloakImage = 'keycloak/keycloak:26.8',
    [string]$PostgresImage = 'postgres:17-alpine',

    [string]$RealmName = 'oms',
    [string]$WorkloadClientId = 'oms-workloads',

    [string]$BindSecretName = 'oms-ad-bind',
    [string]$CaSecretName = 'oms-ad-ca',
    [string]$WorkloadNamespace = 'oms-azurelocal',
    [string]$WorkloadServiceAccount = 'oms-workload',
    [string]$WorkloadCaSecretName = 'oms-identity-ca',
    [string]$IssuerCaSecretName = 'keycloak-ca',
    [string]$IssuerDiscoveryBinding = 'keycloak-issuer-discovery',
    [int]$NodePort = 30443,

    [switch]$ReimportRealm,
    [switch]$SkipVerify,

    # Accept the cluster's default issuer, https://kubernetes.default.svc.cluster.local. Keycloak
    # runs inside the same cluster, so that name resolves for it, and it fetches the signing keys
    # with its own ServiceAccount token. Used on AKS enabled by Arc, which has no external issuer.
    [switch]$AllowInClusterIssuer
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Push-Location $repoRoot

# Windows PowerShell does not load this assembly by default.
Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$What,
        [Parameter(Mandatory = $true)][scriptblock]$Command
    )

    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$What failed with exit code $LASTEXITCODE."
    }
}

function Get-SecretValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Key
    )

    # jsonpath reads a dot as a path separator, so a key such as 'ca.crt' has to be escaped or it
    # is searched for as data.ca.crt and silently returns nothing.
    $jsonPathKey = $Key -replace '\.', '\.'
    $encoded = kubectl --context $KubeContext -n $Namespace get secret $Name `
        --output "jsonpath={.data.$jsonPathKey}" 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($encoded)) { return $null }

    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
}

function ConvertTo-Pem {
    param([Parameter(Mandatory = $true)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)

    return "-----BEGIN CERTIFICATE-----`n" +
        [Convert]::ToBase64String($Certificate.RawData, 'InsertLineBreaks') +
        "`n-----END CERTIFICATE-----"
}

function New-RandomSecret {
    $bytes = [byte[]]::new(24)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    # Base64url, so the value survives being pasted into a URL or a header without escaping.
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Resolve-Image {
    param([Parameter(Mandatory = $true)][string]$Image, [Parameter(Mandatory = $true)][string]$PublicHost)

    if ($Registry) { return "$Registry/$Image" }
    return "$PublicHost/$Image"
}

# Keycloak presents a certificate nothing here trusts yet, and -SkipCertificateCheck exists only
# on PowerShell 7. Going through HttpClient directly works on both editions.
function Invoke-InsecureGet {
    param([Parameter(Mandatory = $true)][string]$Uri)

    $handler = [System.Net.Http.HttpClientHandler]::new()
    # A scriptblock cannot be used here: .NET invokes the validator on a thread with no runspace,
    # which surfaces as an opaque 'SSL connection could not be established'.
    $handler.ServerCertificateCustomValidationCallback =
        [System.Net.Http.HttpClientHandler]::DangerousAcceptAnyServerCertificateValidator

    $client = [System.Net.Http.HttpClient]::new($handler)
    try {
        $client.Timeout = [TimeSpan]::FromSeconds(30)
        $response = $client.GetAsync($Uri).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) { return $null }
        return $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    }
    catch { return $null }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

# Keycloak imports a realm only when one does not already exist, so a changed realm document is
# ignored until the old realm is removed.
function Remove-KeycloakRealm {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$Realm
    )

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.ServerCertificateCustomValidationCallback =
        [System.Net.Http.HttpClientHandler]::DangerousAcceptAnyServerCertificateValidator
    $client = [System.Net.Http.HttpClient]::new($handler)
    try {
        $client.Timeout = [TimeSpan]::FromSeconds(60)

        $fields = [System.Collections.Generic.Dictionary[string, string]]::new()
        $fields.Add('client_id', 'admin-cli')
        $fields.Add('grant_type', 'password')
        $fields.Add('username', 'admin')
        $fields.Add('password', $Password)

        $tokenResponse = $client.PostAsync("$BaseUrl/realms/master/protocol/openid-connect/token",
            [System.Net.Http.FormUrlEncodedContent]::new($fields)).GetAwaiter().GetResult()
        if (-not $tokenResponse.IsSuccessStatusCode) {
            throw "Could not obtain an admin token ($([int]$tokenResponse.StatusCode))."
        }
        $token = ($tokenResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult() |
                ConvertFrom-Json).access_token

        $client.DefaultRequestHeaders.Authorization =
            [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)

        $delete = $client.DeleteAsync("$BaseUrl/admin/realms/$Realm").GetAwaiter().GetResult()
        if (-not $delete.IsSuccessStatusCode -and [int]$delete.StatusCode -ne 404) {
            throw "Deleting realm '$Realm' returned $([int]$delete.StatusCode)."
        }
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

try {
    foreach ($tool in @('kubectl')) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "'$tool' is not on PATH."
        }
    }

    Invoke-Checked 'kubectl cluster-info' {
        kubectl cluster-info --context $KubeContext --request-timeout=30s | Out-Null
    }

    kubectl --context $KubeContext create namespace $Namespace `
        --dry-run=client --output yaml | kubectl --context $KubeContext apply -f - | Out-Null

    # ------------------------------------------------------------------------------------------
    # What the cluster signs tokens with, read from the live API server rather than assumed.
    # ------------------------------------------------------------------------------------------
    Write-Host "==> Reading the cluster token issuer" -ForegroundColor Cyan
    $discoveryRaw = kubectl --context $KubeContext get --raw /.well-known/openid-configuration 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "The API server served no OIDC discovery document, so its token issuer cannot be trusted."
    }

    $discovery = $discoveryRaw | ConvertFrom-Json
    $issuer = $discovery.issuer

    if ($issuer -eq 'https://kubernetes.default.svc.cluster.local' -and -not $AllowInClusterIssuer) {
        throw @"
The cluster still uses its default, internal-only token issuer, which Keycloak cannot resolve.
Pass -AllowInClusterIssuer when Keycloak runs in this same cluster, or configure the cluster with an
externally reachable service-account issuer.
"@
    }
    Write-Host "    issuer $issuer" -ForegroundColor DarkGray

    # Keycloak opens the JWKS endpoint itself, over TLS the API server terminates with its own CA.
    # That CA is already in the kubeconfig, so there is no need to go back to the node for it.
    $caData = kubectl --context $KubeContext config view --raw --minify `
        --output 'jsonpath={.clusters[0].cluster.certificate-authority-data}'
    if ([string]::IsNullOrWhiteSpace($caData)) {
        throw 'The kubeconfig carries no cluster CA, so Keycloak could not verify the JWKS endpoint.'
    }
    $clusterCaPem = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($caData))

    # Keycloak fetches the cluster's signing keys itself, authenticating with its own
    # ServiceAccount token. The API server refuses anonymous callers, so that account needs
    # permission to read the discovery and JWKS endpoints.
    Write-Host "==> Granting Keycloak access to the cluster signing keys" -ForegroundColor Cyan
    kubectl --context $KubeContext create clusterrolebinding $IssuerDiscoveryBinding `
        --clusterrole=system:service-account-issuer-discovery `
        --serviceaccount="${Namespace}:default" `
        --dry-run=client --output yaml | kubectl --context $KubeContext apply -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not grant Keycloak issuer discovery access.' }

    # ------------------------------------------------------------------------------------------
    # Credentials. Generated once and kept in the cluster, so re-running does not churn them.
    # ------------------------------------------------------------------------------------------
    $bindDn = Get-SecretValue -Name $BindSecretName -Key 'bind-upn'
    $bindPassword = Get-SecretValue -Name $BindSecretName -Key 'bind-password'
    if (-not $bindDn -or -not $bindPassword) {
        throw @"
No usable '$BindSecretName' Secret in namespace '$Namespace'.
Create it with the directory bind account (keys bind-upn, bind-password); in the lab,
lab/azurelocal/ad-setup.ps1 does this.
"@
    }

    $adminPassword = Get-SecretValue -Name 'keycloak-admin' -Key 'password'
    $dbPassword = Get-SecretValue -Name 'keycloak-db' -Key 'password'

    if (-not $adminPassword) { $adminPassword = New-RandomSecret }
    if (-not $dbPassword) { $dbPassword = New-RandomSecret }

    foreach ($pair in @(
            @{ Name = 'keycloak-admin'; Args = @("--from-literal=username=admin", "--from-literal=password=$adminPassword") },
            @{ Name = 'keycloak-db'; Args = @("--from-literal=username=keycloak", "--from-literal=password=$dbPassword") }
        )) {
        # Property access has to be wrapped, or PowerShell passes '$pair' and '.Name' literally.
        kubectl --context $KubeContext -n $Namespace create secret generic $($pair.Name) `
            $($pair.Args) --dry-run=client --output yaml |
            kubectl --context $KubeContext apply -f - | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not write the '$($pair.Name)' Secret." }
    }

    # ------------------------------------------------------------------------------------------
    # The realm. Imported at startup rather than configured afterwards, so the whole trust
    # relationship is one reviewable document instead of a sequence of admin API calls.
    # ------------------------------------------------------------------------------------------
    Write-Host "==> Building the '$RealmName' realm" -ForegroundColor Cyan

    $ldapPort = if ($UseLdaps) { 636 } else { 389 }
    $ldapScheme = if ($UseLdaps) { 'ldaps' } else { 'ldap' }
    $baseDn = ($AdDomain.Split('.') | ForEach-Object { "DC=$_" }) -join ','
    $usersDn = "OU=$AdOuName,$baseDn"

    $adCaPem = $null
    if ($UseLdaps) {
        # The controller's certificate carries its host name, so an address here fails hostname
        # verification no matter how the trust is set up.
        if ($AdServer -match '^\d{1,3}(\.\d{1,3}){3}$') {
            throw "-AdServer is the address '$AdServer'. LDAPS validates the controller's host name, so pass its FQDN instead, or pass -UseLdaps:`$false to use plain LDAP."
        }

        $adCaPem = Get-SecretValue -Name $CaSecretName -Key 'ca.crt'
        if (-not $adCaPem) {
            throw "Secret '$CaSecretName' is missing from namespace '$Namespace', so the directory's certificate cannot be trusted. Create it with the directory's CA certificate (key ca.crt; lab/azurelocal/ad-setup.ps1 does this in the lab), or pass -UseLdaps:`$false."
        }
    }
    else {
        Write-Warning 'Binding over plain LDAP. The bind password and every user password cross the site network in the clear.'
    }

    $realm = [ordered]@{
        realm                 = $RealmName
        enabled               = $true
        # Short lifetimes are affordable because the pod can always mint a fresh ServiceAccount
        # token and exchange it again without talking to anything outside the site.
        accessTokenLifespan   = 900
        ssoSessionIdleTimeout = 1800

        components            = [ordered]@{
            # The key is the provider type; repeating it inside the entry is rejected on import.
            'org.keycloak.storage.UserStorageProvider' = @(
                [ordered]@{
                    name           = 'active-directory'
                    providerId     = 'ldap'
                    config         = [ordered]@{
                        enabled                 = @('true')
                        vendor                  = @('ad')
                        connectionUrl           = @("${ldapScheme}://${AdServer}:${ldapPort}")
                        bindDn                  = @($bindDn)
                        bindCredential          = @($bindPassword)
                        authType                = @('simple')
                        usersDn                 = @($usersDn)
                        userObjectClasses       = @('person, organizationalPerson, user')
                        usernameLDAPAttribute   = @('sAMAccountName')
                        rdnLDAPAttribute        = @('cn')
                        uuidLDAPAttribute       = @('objectGUID')
                        searchScope             = @('2')
                        # Read only: the directory is authoritative, and Keycloak holding write
                        # access to it would be a far larger blast radius than this sample needs.
                        editMode                = @('READ_ONLY')
                        importEnabled           = @('true')
                        syncRegistrations       = @('false')
                        trustEmail              = @('true')
                        pagination              = @('true')
                    }
                    subComponents  = [ordered]@{
                        # Creating a provider through the console adds these automatically, but a
                        # realm import does not, and without them every user arrives with a null
                        # username and the sync fails.
                        'org.keycloak.storage.ldap.mappers.LDAPStorageMapper' = @(
                            [ordered]@{
                                name       = 'username'
                                providerId = 'user-attribute-ldap-mapper'
                                config     = [ordered]@{
                                    'user.model.attribute'        = @('username')
                                    'ldap.attribute'              = @('sAMAccountName')
                                    'read.only'                   = @('true')
                                    'always.read.value.from.ldap' = @('false')
                                    'is.mandatory.in.ldap'        = @('true')
                                }
                            }
                            [ordered]@{
                                name       = 'first name'
                                providerId = 'user-attribute-ldap-mapper'
                                config     = [ordered]@{
                                    'user.model.attribute'        = @('firstName')
                                    'ldap.attribute'              = @('givenName')
                                    'read.only'                   = @('true')
                                    'always.read.value.from.ldap' = @('true')
                                    # Accounts created without a given name would otherwise fail
                                    # the whole sync rather than import without one.
                                    'is.mandatory.in.ldap'        = @('false')
                                }
                            }
                            [ordered]@{
                                name       = 'last name'
                                providerId = 'user-attribute-ldap-mapper'
                                config     = [ordered]@{
                                    'user.model.attribute'        = @('lastName')
                                    'ldap.attribute'              = @('sn')
                                    'read.only'                   = @('true')
                                    'always.read.value.from.ldap' = @('true')
                                    'is.mandatory.in.ldap'        = @('false')
                                }
                            }
                            [ordered]@{
                                name       = 'email'
                                providerId = 'user-attribute-ldap-mapper'
                                config     = [ordered]@{
                                    'user.model.attribute'        = @('email')
                                    'ldap.attribute'              = @('mail')
                                    'read.only'                   = @('true')
                                    'always.read.value.from.ldap' = @('true')
                                    'is.mandatory.in.ldap'        = @('false')
                                }
                            }
                            [ordered]@{
                                name       = 'creation date'
                                providerId = 'user-attribute-ldap-mapper'
                                config     = [ordered]@{
                                    'user.model.attribute'        = @('createTimestamp')
                                    'ldap.attribute'              = @('whenCreated')
                                    'read.only'                   = @('true')
                                    'always.read.value.from.ldap' = @('true')
                                    'is.mandatory.in.ldap'        = @('false')
                                }
                            }
                            [ordered]@{
                                name       = 'modify date'
                                providerId = 'user-attribute-ldap-mapper'
                                config     = [ordered]@{
                                    'user.model.attribute'        = @('modifyTimestamp')
                                    'ldap.attribute'              = @('whenChanged')
                                    'read.only'                   = @('true')
                                    'always.read.value.from.ldap' = @('true')
                                    'is.mandatory.in.ldap'        = @('false')
                                }
                            }
                            [ordered]@{
                                # Translates userAccountControl, so a disabled or locked directory
                                # account cannot sign in through Keycloak.
                                name       = 'msad-account-controls'
                                providerId = 'msad-user-account-control-mapper'
                                config     = [ordered]@{}
                            }
                            [ordered]@{
                                name         = 'group-mapper'
                                providerId   = 'group-ldap-mapper'
                                config       = [ordered]@{
                                    'groups.dn'                 = @($usersDn)
                                    'group.name.ldap.attribute' = @('cn')
                                    'group.object.classes'      = @('group')
                                    'membership.ldap.attribute' = @('member')
                                    'membership.attribute.type' = @('DN')
                                    'mode'                      = @('READ_ONLY')
                                    'user.roles.retrieve.strategy' = @('LOAD_GROUPS_BY_MEMBER_ATTRIBUTE')
                                }
                            }
                        )
                    }
                }
            )
        }

        identityProviders     = @(
            # The federated identity credential equivalent. Entra matches a credential on issuer
            # plus subject and returns a token for the managed identity; this provider is the
            # issuer half of that statement, and the client below is the subject half.
            [ordered]@{
                alias       = 'kubernetes'
                displayName = 'Kubernetes ServiceAccount tokens'
                providerId  = 'kubernetes'
                enabled     = $true
                storeToken  = $false
                config      = [ordered]@{
                    issuer               = $issuer
                    allowedClockSkew     = '30'
                    # Kubernetes assertions carry no replay protection, so Keycloak's guidance is
                    # to keep them short lived rather than attempt to detect reuse.
                    maxAssertionLifespan = '600'
                }
            }
        )

        clients               = @(
            # The managed identity equivalent. It holds no secret: the cluster's ServiceAccount
            # token authenticates it, matched on the issuer and subject below.
            [ordered]@{
                clientId                  = $WorkloadClientId
                enabled                   = $true
                protocol                  = 'openid-connect'
                publicClient              = $false
                clientAuthenticatorType   = 'federated-jwt'
                standardFlowEnabled       = $false
                directAccessGrantsEnabled = $false
                serviceAccountsEnabled    = $true
                attributes                = [ordered]@{
                    'jwt.credential.issuer' = 'kubernetes'
                    'jwt.credential.sub'    = "system:serviceaccount:${WorkloadNamespace}:${WorkloadServiceAccount}"
                    'access.token.lifespan' = '900'
                }
                protocolMappers           = @(
                    # Backing services reject a token that is not addressed to them, so each one
                    # has to appear in the audience.
                    [ordered]@{
                        name           = 'rabbitmq-audience'
                        protocol       = 'openid-connect'
                        protocolMapper = 'oidc-audience-mapper'
                        config         = [ordered]@{
                            'included.custom.audience' = 'rabbitmq'
                            'access.token.claim'       = 'true'
                        }
                    }
                    # RabbitMQ reads its permissions from this claim rather than 'scope', which
                    # Keycloak derives from client scope names and cannot express as these verbs.
                    [ordered]@{
                        name           = 'rabbitmq-permissions'
                        protocol       = 'openid-connect'
                        protocolMapper = 'oidc-hardcoded-claim-mapper'
                        config         = [ordered]@{
                            'claim.name'         = 'rabbitmq_scopes'
                            'claim.value'        = 'rabbitmq.configure:*/* rabbitmq.write:*/* rabbitmq.read:*/*'
                            'jsonType.label'     = 'String'
                            'access.token.claim' = 'true'
                        }
                    }
                )
            }
        )

        groups                = @(
            [ordered]@{ name = 'oms-app-readers' }
            [ordered]@{ name = 'oms-app-writers' }
        )
    }

    $realmJson = $realm | ConvertTo-Json -Depth 20

    # The realm carries the LDAP bind password and the client secret, so it is a Secret rather
    # than a ConfigMap.
    $realmSecretManifest = @"
apiVersion: v1
kind: Secret
metadata:
  name: keycloak-realm
  namespace: $Namespace
type: Opaque
stringData:
  oms-realm.json: |
$(($realmJson -split "`n" | ForEach-Object { '    ' + $_ }) -join "`n")
"@
    $realmSecretManifest | kubectl --context $KubeContext apply -f - | Out-Null

    $clusterCaManifest = @"
apiVersion: v1
kind: Secret
metadata:
  name: cluster-ca
  namespace: $Namespace
type: Opaque
stringData:
  cluster-ca.pem: |
$(($clusterCaPem -split "`n" | ForEach-Object { '    ' + $_.TrimEnd() }) -join "`n")
"@
    $clusterCaManifest | kubectl --context $KubeContext apply -f - | Out-Null

    # Both certificates land in one directory because KC_TRUSTSTORE_PATHS takes a path, not a
    # list; the directory CA is only present when binding over LDAPS.
    $truststoreSources = @('              - secret:', '                  name: cluster-ca')
    if ($adCaPem) {
        $truststoreSources += @('              - secret:', "                  name: $CaSecretName")
    }
    $truststoreSources = $truststoreSources -join "`n"

    # ------------------------------------------------------------------------------------------
    # Workloads.
    # ------------------------------------------------------------------------------------------
    Write-Host "==> Deploying PostgreSQL and Keycloak into '$Namespace'" -ForegroundColor Cyan

    $keycloakRef = Resolve-Image -Image $KeycloakImage -PublicHost 'quay.io'
    $postgresRef = Resolve-Image -Image $PostgresImage -PublicHost 'docker.io/library'

    $pullSecretBlock = ''
    if ($Registry -and $ImagePullSecretName) {
        # Pull secrets do not cross namespaces, so the one the rest of the deployment uses has to
        # be copied here or the kubelet falls back to an anonymous token and the registry refuses.
        $existing = kubectl --context $KubeContext -n $Namespace get secret $ImagePullSecretName `
            --ignore-not-found --output name
        if (-not $existing) {
            $source = $ImagePullSecretSourceNamespace
            $encoded = kubectl --context $KubeContext -n $source get secret $ImagePullSecretName `
                --output 'jsonpath={.data.\.dockerconfigjson}' 2>$null
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($encoded)) {
                throw @"
No '$ImagePullSecretName' Secret in namespace '$Namespace', and none to copy from '$source'.
Create one, or point -ImagePullSecretSourceNamespace at a namespace that has it:
  kubectl --context $KubeContext -n $Namespace create secret docker-registry $ImagePullSecretName ``
    --docker-server $Registry --docker-username <user> --docker-password <password>
"@
            }

            Write-Host "==> Copying the registry credential from '$source'" -ForegroundColor Cyan
            @"
apiVersion: v1
kind: Secret
metadata:
  name: $ImagePullSecretName
  namespace: $Namespace
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: $encoded
"@ | kubectl --context $KubeContext apply -f - | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Could not copy the registry credential.' }
        }

        $pullSecretBlock = @"
      imagePullSecrets:
        - name: $ImagePullSecretName
"@
    }

    $manifest = @"
apiVersion: v1
kind: Service
metadata:
  name: keycloak-db
  namespace: $Namespace
spec:
  selector:
    app: keycloak-db
  ports:
    - port: 5432
      targetPort: 5432
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: keycloak-db
  namespace: $Namespace
spec:
  serviceName: keycloak-db
  replicas: 1
  selector:
    matchLabels:
      app: keycloak-db
  template:
    metadata:
      labels:
        app: keycloak-db
    spec:
$pullSecretBlock
      containers:
        - name: postgres
          image: $postgresRef
          env:
            - name: POSTGRES_DB
              value: keycloak
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef: { name: keycloak-db, key: username }
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef: { name: keycloak-db, key: password }
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          ports:
            - containerPort: 5432
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "keycloak", "-d", "keycloak"]
            initialDelaySeconds: 10
            periodSeconds: 10
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 8Gi
---
apiVersion: v1
kind: Service
metadata:
  name: $ReleaseName
  namespace: $Namespace
spec:
  type: NodePort
  selector:
    app: $ReleaseName
  ports:
    - name: https
      port: 8443
      targetPort: 8443
      nodePort: $NodePort
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $ReleaseName
  namespace: $Namespace
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $ReleaseName
  template:
    metadata:
      labels:
        app: $ReleaseName
    spec:
$pullSecretBlock
      containers:
        - name: keycloak
          image: $keycloakRef
          args: ["start", "--import-realm", "--optimized=false"]
          env:
            - name: KC_BOOTSTRAP_ADMIN_USERNAME
              valueFrom:
                secretKeyRef: { name: keycloak-admin, key: username }
            - name: KC_BOOTSTRAP_ADMIN_PASSWORD
              valueFrom:
                secretKeyRef: { name: keycloak-admin, key: password }
            - name: KC_DB
              value: postgres
            - name: KC_DB_URL
              value: jdbc:postgresql://keycloak-db:5432/keycloak
            - name: KC_DB_USERNAME
              valueFrom:
                secretKeyRef: { name: keycloak-db, key: username }
            - name: KC_DB_PASSWORD
              valueFrom:
                secretKeyRef: { name: keycloak-db, key: password }
            # Self-signed is acceptable here only because every caller is inside the site and
            # pins this certificate explicitly. Replace it with one the domain CA issues.
            - name: KC_HTTPS_CERTIFICATE_FILE
              value: /opt/keycloak/conf/tls/tls.crt
            - name: KC_HTTPS_CERTIFICATE_KEY_FILE
              value: /opt/keycloak/conf/tls/tls.key
            - name: KC_HOSTNAME_STRICT
              value: "false"
            - name: KC_HEALTH_ENABLED
              value: "true"
            # One replica, so skip Infinispan clustering. Otherwise a restarted pod tries to join
            # the membership row its predecessor left in the database and never finishes starting.
            - name: KC_CACHE
              value: local
            # Versions are explicit: unversioned 'admin-fine-grained-authz' resolves to v2, and
            # external-to-internal token exchange is only authorised by v1.
            - name: KC_FEATURES
              value: kubernetes-service-accounts:v1
            # Lets Keycloak open the API server's JWKS endpoint, which is signed by the cluster CA
            # and would otherwise fail validation.
            - name: KC_TRUSTSTORE_PATHS
              value: /opt/keycloak/conf/truststores
          ports:
            - containerPort: 8443
          readinessProbe:
            httpGet:
              path: /health/ready
              port: 9000
              # The management interface inherits the server's HTTPS settings, so a plain HTTP
              # probe is answered with a TLS handshake and never succeeds.
              scheme: HTTPS
            initialDelaySeconds: 30
            periodSeconds: 10
            failureThreshold: 30
          volumeMounts:
            - name: realm
              mountPath: /opt/keycloak/data/import
              readOnly: true
            - name: truststore
              mountPath: /opt/keycloak/conf/truststores
              readOnly: true
            - name: tls
              mountPath: /opt/keycloak/conf/tls
              readOnly: true
      volumes:
        - name: realm
          secret:
            secretName: keycloak-realm
        - name: truststore
          projected:
            sources:
$truststoreSources
        - name: tls
          secret:
            secretName: keycloak-tls
"@

    # Keycloak refuses to start 'start' mode over plain HTTP, so it needs a certificate before the
    # Deployment is applied.
    if (-not (kubectl --context $KubeContext -n $Namespace get secret keycloak-tls --ignore-not-found --output name)) {
        Write-Host "==> Issuing a certificate for Keycloak" -ForegroundColor Cyan

        # ExportPkcs8PrivateKey arrived with .NET Core, so Windows PowerShell cannot write the key.
        if ($PSVersionTable.PSEdition -ne 'Core') {
            throw @"
Generating the Keycloak certificate needs PowerShell 7. Either re-run this script under 'pwsh',
or create the Secret yourself and re-run:
  kubectl --context $KubeContext -n $Namespace create secret tls keycloak-tls --cert <crt> --key <key>
"@
        }

        $nodeIp = kubectl --context $KubeContext get nodes `
            --output 'jsonpath={.items[0].status.addresses[?(@.type=="InternalIP")].address}'

        # -DnsName records an address as a DNS entry, which browsers reject when the URL is an
        # address, so the SAN is written out explicitly to get a real iPAddress entry.
        $san = @(
            "DNS=$ReleaseName",
            "DNS=$ReleaseName.$Namespace",
            "DNS=$ReleaseName.$Namespace.svc",
            "DNS=$ReleaseName.$Namespace.svc.cluster.local",
            "IPAddress=$nodeIp"
        ) -join '&'

        # A small CA signs the serving certificate rather than the certificate signing itself.
        # Erlang's TLS client, which RabbitMQ uses to fetch the signing keys, rejects a self-signed
        # peer outright ('Bad Certificate - selfsigned_peer') because a trust anchor has to be a CA.
        # Clients therefore trust this CA, not the certificate Keycloak presents.
        $ca = New-SelfSignedCertificate -Subject 'CN=BCD Identity Issuing CA' `
            -CertStoreLocation 'Cert:\CurrentUser\My' -KeyExportPolicy Exportable `
            -KeyUsage CertSign, CRLSign, DigitalSignature -KeyUsageProperty All `
            -TextExtension @('2.5.29.19={critical}{text}CA=true&pathlength=0') `
            -NotAfter (Get-Date).AddYears(5) -KeyAlgorithm RSA -KeyLength 2048

        $cert = New-SelfSignedCertificate -Subject "CN=$ReleaseName.$Namespace.svc" `
            -Signer $ca `
            -TextExtension @("2.5.29.17={text}$san", '2.5.29.37={text}1.3.6.1.5.5.7.3.1') `
            -CertStoreLocation 'Cert:\CurrentUser\My' -KeyExportPolicy Exportable `
            -NotAfter (Get-Date).AddYears(2) -KeyAlgorithm RSA -KeyLength 2048

        try {
            $certPem = ConvertTo-Pem -Certificate $cert
            $caPem = ConvertTo-Pem -Certificate $ca

            $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
            $keyPem = "-----BEGIN PRIVATE KEY-----`n" +
                [Convert]::ToBase64String($rsa.ExportPkcs8PrivateKey(), 'InsertLineBreaks') +
                "`n-----END PRIVATE KEY-----"

            # Keycloak serves the issuer alongside the leaf so a client that holds only the CA can
            # still build the path.
            $chainPem = "$certPem`n$caPem"

            $tlsManifest = @"
apiVersion: v1
kind: Secret
metadata:
  name: keycloak-tls
  namespace: $Namespace
type: kubernetes.io/tls
data:
  tls.crt: $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($chainPem)))
  tls.key: $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($keyPem)))
---
apiVersion: v1
kind: Secret
metadata:
  name: $IssuerCaSecretName
  namespace: $Namespace
data:
  ca.crt: $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($caPem)))
"@
            $tlsManifest | kubectl --context $KubeContext apply -f - | Out-Null
        }
        finally {
            Remove-Item "Cert:\CurrentUser\My\$($cert.Thumbprint)" -Force -ErrorAction SilentlyContinue
            Remove-Item "Cert:\CurrentUser\My\$($ca.Thumbprint)" -Force -ErrorAction SilentlyContinue
        }
    }

    $manifest | kubectl --context $KubeContext apply -f - | Out-Null

    Write-Host "==> Waiting for Keycloak to become ready" -ForegroundColor Cyan
    Invoke-Checked 'keycloak rollout' {
        kubectl --context $KubeContext -n $Namespace rollout status deployment $ReleaseName --timeout=600s | Out-Null
    }

    $nodeIp = kubectl --context $KubeContext get nodes `
        --output 'jsonpath={.items[0].status.addresses[?(@.type=="InternalIP")].address}'
    $issuerUrl = "https://${nodeIp}:$NodePort/realms/$RealmName"

    if ($ReimportRealm) {
        Write-Host "==> Replacing the existing '$RealmName' realm" -ForegroundColor Cyan
        Remove-KeycloakRealm -BaseUrl "https://${nodeIp}:$NodePort" -Password $adminPassword `
            -Realm $RealmName

        kubectl --context $KubeContext -n $Namespace rollout restart deployment $ReleaseName | Out-Null
        Invoke-Checked 'keycloak restart' {
            kubectl --context $KubeContext -n $Namespace rollout status deployment $ReleaseName --timeout=600s | Out-Null
        }
    }

    if (-not $SkipVerify) {
        Write-Host "==> Checking that the realm imported and the directory answered" -ForegroundColor Cyan

        $discoveryUrl = "$issuerUrl/.well-known/openid-configuration"
        $realmDoc = $null
        $deadline = (Get-Date).AddMinutes(3)
        while ((Get-Date) -lt $deadline) {
            $realmDoc = Invoke-InsecureGet -Uri $discoveryUrl
            if ($realmDoc) { break }
            Start-Sleep -Seconds 10
        }

        if (-not $realmDoc) {
            throw "Realm '$RealmName' did not answer at $discoveryUrl. Check: kubectl --context $KubeContext -n $Namespace logs deploy/$ReleaseName"
        }
        Write-Host "    realm '$RealmName' is serving discovery" -ForegroundColor DarkGray

        # An LDAP misconfiguration shows up as a federation provider that loads but never returns
        # a user, which the discovery check above would not catch.
        $ldapError = kubectl --context $KubeContext -n $Namespace logs "deploy/$ReleaseName" --tail=200 |
            Select-String -Pattern 'ERROR|WARN' |
            Select-String -Pattern 'ldap|NamingException|federation'
        if ($ldapError) {
            Write-Warning "Keycloak logged a directory problem:`n$($ldapError -join "`n")"
        }
    }

    # Everything a workload needs lives in its own namespace: the identity it presents, and the
    # certificate authority it checks Keycloak against. Both are created here rather than in the
    # application deployment, because the client registration above already names this account and
    # the two have to agree.
    Write-Host "==> Preparing namespace $WorkloadNamespace for workloads" -ForegroundColor Cyan

    kubectl --context $KubeContext create namespace $WorkloadNamespace `
        --dry-run=client --output yaml | kubectl --context $KubeContext apply -f - | Out-Null

    kubectl --context $KubeContext -n $WorkloadNamespace create serviceaccount $WorkloadServiceAccount `
        --dry-run=client --output yaml | kubectl --context $KubeContext apply -f - | Out-Null
    Write-Host "    serviceaccount/$WorkloadServiceAccount" -ForegroundColor DarkGray

    # Keycloak serves a certificate issued by a CA the cluster does not know, so the workload and
    # RabbitMQ both need that CA. Publishing the issuer rather than the serving certificate is what
    # lets a strict TLS client, such as the Erlang one RabbitMQ uses, build a valid path.
    $keycloakCert = Get-SecretValue -Name $IssuerCaSecretName -Key 'ca.crt'
    if (-not $keycloakCert) {
        # An externally supplied certificate has no separate CA secret; fall back to what it serves.
        $keycloakCert = Get-SecretValue -Name 'keycloak-tls' -Key 'tls.crt'
    }
    if (-not $keycloakCert) {
        throw "Neither '$IssuerCaSecretName' nor 'keycloak-tls' in namespace '$Namespace' yields a certificate, so nothing can be published to '$WorkloadNamespace'."
    }

    $caFile = Join-Path ([IO.Path]::GetTempPath()) "keycloak-ca-$([guid]::NewGuid().ToString('N')).crt"
    try {
        Set-Content -Path $caFile -Value $keycloakCert -Encoding ascii -NoNewline

        kubectl --context $KubeContext -n $WorkloadNamespace delete secret $WorkloadCaSecretName `
            --ignore-not-found | Out-Null
        kubectl --context $KubeContext -n $WorkloadNamespace create secret generic $WorkloadCaSecretName `
            --from-file="ca.crt=$caFile" | Out-Null
    }
    finally {
        Remove-Item -Path $caFile -Force -ErrorAction SilentlyContinue
    }
    Write-Host "    secret/$WorkloadCaSecretName" -ForegroundColor DarkGray

    Write-Host "`n================ Identity ready ================" -ForegroundColor Green
    Write-Host "Keycloak realm   : $issuerUrl"
    Write-Host "Directory        : ${ldapScheme}://${AdServer}:${ldapPort} ($usersDn)"
    Write-Host "Cluster issuer   : $issuer"
    Write-Host "Workload client  : $WorkloadClientId"
    Write-Host "Workload identity: ${WorkloadNamespace}:$WorkloadServiceAccount"
    Write-Host "Issuer CA secret : $WorkloadCaSecretName (namespace $WorkloadNamespace)"
    Write-Host ''
    Write-Host 'A workload authenticates with its ServiceAccount token and no secret:' -ForegroundColor Yellow
    Write-Host '  curl -sk "$ISSUER/protocol/openid-connect/token" \'
    Write-Host '    -d grant_type=client_credentials \'
    Write-Host "    -d client_id=$WorkloadClientId \"
    Write-Host '    -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer \'
    Write-Host '    -d client_assertion=$(cat /var/run/secrets/identity/token)'
    Write-Host ''
    Write-Host 'The pod gets that assertion from a projected volume, not from a stored secret:' -ForegroundColor DarkGray
    Write-Host "  serviceAccountToken: { audience: '$issuerUrl', path: token, expirationSeconds: 600 }"
}
finally {
    Pop-Location
}
