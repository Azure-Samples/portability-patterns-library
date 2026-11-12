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
    stays the single source of truth. The 'kubernetes' identity provider in the realm is the trust
    statement that corresponds to a federated identity credential on a managed identity.

    What gets deployed is in infra/azurelocal/keycloak: keycloak.yaml (two Keycloak replicas),
    database/ (their PostgreSQL database: with -Availability high a CloudNativePG cluster backed up
    to the site's object store, with standard one StatefulSet), service.yaml (Keycloak's load
    balancer address), realm.json (the 'oms' realm: AD federation, app roles, the sign-in and
    workload clients) and realm-config.yaml (a Job that applies realm.json with keycloak-config-cli).
    This script does the per-site parts around those files: it creates the Secrets, gives Keycloak
    its address and certificates, writes the site values into the keycloak-realm-settings ConfigMap,
    applies the folder with kustomize, waits for the realm to be applied, and prepares the app's
    namespace. The folder's README.md describes the same steps by hand.

    Every run applies realm.json and the site values again, so changing the app's address, the
    directory, the bind password or realm.json and re-running is all a change takes.

    Keycloak's address is one from the Arc load balancer, kept on later runs, so its issuer URL,
    https://<address>/realms/oms, doesn't depend on any one node. The admin console is not served
    on that address; see "Admin access" in the folder's README.md.

    Keycloak trusts the cluster's ServiceAccount token issuer. It fetches the cluster's signing keys
    from the API server inside the cluster (kubernetes.default.svc), never from the issuer's own
    address: with Arc workload identity on, the issuer is a public Azure URL, and keys fetched
    from there would stop loading when the site loses its link to Azure. On a cluster that still
    uses the default in-cluster issuer, pass -AllowInClusterIssuer.

    Prerequisites: provision-ingress.ps1 (the site CA's ClusterIssuer), and with -Availability high
    provision-operators.ps1 (CloudNativePG) and provision-object-store.ps1 (where the database backs
    up).

.PARAMETER Availability
    How Keycloak's database runs: 'high' (the default), a CloudNativePG cluster that fails over and
    backs up; 'standard', one PostgreSQL StatefulSet with no backups. Set it once, as
    Common.Availability in the settings file.

.PARAMETER AdServer
    Host name of the site's domain controller. Under LDAPS this must
    be the name in the controller's certificate, not its address, or the handshake fails.

.PARAMETER AdDomain
    The Active Directory domain, such as contoso.local. Keycloak reads the OU -AdOuName under it.

.PARAMETER KeycloakIp
    Address for Keycloak from the load balancer's range. Empty keeps the one it has, or takes the
    first free one.

.PARAMETER SpaOrigin
    Address users open the app at, such as https://orders.contoso.local. Sign-in redirects back to it.
    Omit to use https://<ingress address>, read from the ingress controller provision-ingress.ps1
    installed.

.PARAMETER GrafanaOrigin
    Address of the site's Grafana, with its path, such as https://orders.contoso.local/grafana.
    Grafana sign-in redirects back to it. Omit to use <SpaOrigin>/grafana, where
    provision-observability.ps1 serves Grafana.

.PARAMETER Registry
    Registry holding the mirrored Keycloak, keycloak-config-cli and PostgreSQL images, normally the
    in-cluster connected registry. Omit to read it from the image pull secret in
    -ApplicationNamespace; with no such secret, the images come from the public registries, which
    only works where the cluster has internet.

.PARAMETER UseLdaps
    Bind to the directory over LDAPS on 636, which is the default. The certificate comes from the
    directory's enterprise CA, handed over in the 'oms-ad-ca' Secret. Pass -UseLdaps:$false to fall back to plain LDAP on
    389, which sends the bind password and every user password across the network in the clear.

.PARAMETER CertificateIssuer
    cert-manager ClusterIssuer that issues and renews the certificates of Keycloak and of its
    database, 'site-ca' from provision-ingress.ps1 by default. Pass '' to supply Secrets
    identity/keycloak-tls and keycloak-db-tls yourself, which then aren't renewed.

.EXAMPLE
    ./scripts/infra/azurelocal/keycloak.ps1 -AdServer dc01.contoso.local -AdDomain contoso.local -AllowInClusterIssuer
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$AdServer,
    [Parameter(Mandatory = $true)][string]$AdDomain,
    [string]$AdOuName = 'OMS',
    # The read-only account Keycloak binds to the directory with. Empty: svc-keycloak@<AdDomain>.
    # Its password is asked for once, when Secret identity/oms-ad-bind doesn't exist yet.
    [string]$AdBindUpn,
    # The directory CA's certificate (PEM), for LDAPS. Used when Secret identity/oms-ad-ca doesn't
    # exist yet.
    [string]$AdCaCertificatePath,
    [switch]$UseLdaps = $true,
    [string]$SpaOrigin,
    [string]$GrafanaOrigin,
    [string]$KeycloakIp,

    [string]$KubeContext = 'bcd-aksarc',

    [string]$Registry,
    # The application's namespace: its pull secret is copied from there, and its workloads get the
    # CA they check Keycloak against there.
    [string]$ApplicationNamespace = 'oms-azurelocal',
    [string]$WorkloadCaSecretName = 'oms-identity-ca',

    [ValidateSet('high', 'standard')]
    [string]$Availability = 'high',
    # ClusterIssuer for the certificates of Keycloak and its database, which provision-ingress.ps1
    # creates. Empty to supply Secrets identity/keycloak-tls and keycloak-db-tls yourself.
    [string]$CertificateIssuer = 'site-ca',

    # Accept the cluster's default issuer, https://kubernetes.default.svc.cluster.local, on a cluster
    # created without workload identity. Keycloak gets the signing keys from the API server either way.
    [switch]$AllowInClusterIssuer
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
. (Join-Path $repoRoot 'scripts/lib/cluster.ps1')

# Names fixed by the files in infra/azurelocal/keycloak.
$Namespace = 'identity'
$ReleaseName = 'keycloak'
$RealmName = 'oms'
$RealmJobName = 'keycloak-realm-config'
$ImagePullSecretName = 'azurelocal-registry'
$AdminClientSecretName = 'keycloak-admin-client'
$BindSecretName = 'oms-ad-bind'
$CaSecretName = 'oms-ad-ca'
$BackupSecretName = 'backup-object-store'
$TlsSecretName = 'keycloak-tls'
$DatabaseTlsSecretName = 'keycloak-db-tls'
$keycloakDir = Join-Path $repoRoot 'infra/azurelocal/keycloak'
$highAvailability = $Availability -eq 'high'
$databaseFile = "database/$(if ($highAvailability) { 'cloudnative-pg' } else { 'postgres' }).yaml"
# The public images the manifests name; a site with its own registry pulls the same paths from it.
$images = @(
    'quay.io/keycloak/keycloak',
    'docker.io/adorsys/keycloak-config-cli',
    $(if ($highAvailability) { 'ghcr.io/cloudnative-pg/postgresql' } else { 'docker.io/library/postgres' })
)
Push-Location $repoRoot

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

function Get-SecretValue([string]$Name, [string]$Key) {
    Get-OmsSecretValue -KubeContext $KubeContext -Namespace $Namespace -Name $Name -Key $Key
}

function New-RandomSecret {
    $bytes = [byte[]]::new(24)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    # Base64url, so the value survives being pasted into a URL or a header without escaping.
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

# Renders infra/azurelocal/keycloak and the database file for -Availability through a kustomize
# overlay, in a copy of the folder: the overlay points the images at -Registry, and records
# Keycloak's address on its pods, so a changed address rolls them (Keycloak reads it only at start).
function Get-KeycloakManifest([string]$KeycloakUrl) {
    $workDir = Join-Path ([IO.Path]::GetTempPath()) "oms-keycloak-$([guid]::NewGuid().ToString('n'))"
    New-Item -ItemType Directory -Path $workDir | Out-Null
    try {
        Copy-Item -Path $keycloakDir -Destination (Join-Path $workDir 'keycloak') -Recurse

        $overlay = [ordered]@{
            apiVersion = 'kustomize.config.k8s.io/v1beta1'
            kind       = 'Kustomization'
            namespace  = $Namespace
            resources  = @('keycloak', "keycloak/$databaseFile")
            patches    = @(@{
                    target = @{ kind = 'Deployment'; name = $ReleaseName }
                    patch  = (ConvertTo-Json -Depth 5 -InputObject @(@{
                                op    = 'add'
                                path  = '/spec/template/metadata/annotations'
                                value = @{ 'oms/keycloak-hostname' = $KeycloakUrl }
                            }))
                })
        }
        if ($Registry) {
            # CloudNativePG names its image in spec.imageName, which kustomize's image setting
            # doesn't cover unless told to.
            @{ images = @(@{ path = 'spec/imageName'; kind = 'Cluster' }) } | ConvertTo-Json -Depth 5 |
                Set-Content -Path (Join-Path $workDir 'image-fields.yaml') -Encoding utf8
            $overlay.configurations = @('image-fields.yaml')
            # quay.io/keycloak/keycloak -> <registry>/keycloak/keycloak, docker.io/library/postgres
            # -> <registry>/postgres: the paths images.txt mirrors them to.
            $overlay.images = @($images | ForEach-Object { @{ name = $_; newName = "$Registry/$($_ -replace '^[^/]+/(library/)?', '')" } })
        }
        # JSON is YAML, so kustomize reads this as it is.
        $overlay | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $workDir 'kustomization.yaml') -Encoding utf8

        $rendered = kubectl kustomize $workDir
        if ($LASTEXITCODE -ne 0) { throw 'Could not render infra/azurelocal/keycloak.' }
        $rendered
    }
    finally {
        Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Waits for the realm Job to finish, and shows its log when it fails.
function Wait-RealmJob([int]$TimeoutSeconds = 1800) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        $job = kubectl --context $KubeContext -n $Namespace get job $RealmJobName --output json | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) { throw "Could not read Job $Namespace/$RealmJobName." }
        $finished = @($job.status.conditions | Where-Object { $_.status -eq 'True' } | ForEach-Object { $_.type })
        if ($finished -contains 'Complete') { return }
        if ($finished -contains 'Failed' -or (Get-Date) -gt $deadline) {
            Write-Host (kubectl --context $KubeContext -n $Namespace logs "job/$RealmJobName" --tail=40 2>&1 | Out-String)
            throw "Applying realm.json failed (Job $Namespace/$RealmJobName). Its log is above."
        }
        Start-Sleep -Seconds 10
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

    # Addresses the cluster already knows, unless given.
    if (-not $SpaOrigin) {
        $ingressAddress = Get-OmsIngressAddress $KubeContext
        if (-not $ingressAddress) {
            throw 'No -SpaOrigin, and no ingress address to derive it from. Run scripts/infra/azurelocal/provision-ingress.ps1 first, or pass -SpaOrigin.'
        }
        $SpaOrigin = "https://$ingressAddress"
        Write-Host "==> App origin $SpaOrigin (the ingress address)" -ForegroundColor DarkGray
    }
    if (-not $GrafanaOrigin) { $GrafanaOrigin = "$($SpaOrigin.TrimEnd('/'))/grafana" }
    if (-not $Registry) {
        $Registry = Get-OmsPullRegistry $KubeContext $ApplicationNamespace $ImagePullSecretName
        if ($Registry) { Write-Host "==> Images from the connected registry $Registry" -ForegroundColor DarkGray }
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

    # Keycloak opens the JWKS endpoint itself, inside the cluster, over TLS the API server terminates
    # with the cluster's CA. The cluster publishes that CA in every namespace as kube-root-ca.crt; the
    # kubeconfig's CA can be another one, such as a proxy's.
    $clusterCaPem = (kubectl --context $KubeContext get configmap kube-root-ca.crt --namespace default `
            --output 'jsonpath={.data.ca\.crt}') -join "`n"
    if ($LASTEXITCODE -ne 0 -or $clusterCaPem -notmatch '-----BEGIN CERTIFICATE-----') {
        throw 'Could not read the cluster CA from ConfigMap default/kube-root-ca.crt, so Keycloak could not verify the JWKS endpoint.'
    }

    # ------------------------------------------------------------------------------------------
    # Credentials. Generated once and kept in the cluster, so re-running does not churn them.
    # ------------------------------------------------------------------------------------------
    $bindDn = Get-SecretValue -Name $BindSecretName -Key 'bind-upn'
    $bindPassword = Get-SecretValue -Name $BindSecretName -Key 'bind-password'
    if (-not $bindDn -or -not $bindPassword) {
        # The bind account's password exists only in the directory, so it is asked for once and kept
        # in the cluster. It never goes on a command line or into the settings file.
        if (-not $AdBindUpn) { $AdBindUpn = "svc-keycloak@$AdDomain" }
        if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
            throw @"
No '$BindSecretName' Secret in namespace '$Namespace', and no console to ask for the password of
'$AdBindUpn' on. Run this interactively once, or create the Secret (keys bind-upn, bind-password) or
run scripts/infra/azurelocal/ad-setup.ps1.
"@
        }
        $secure = Read-Host -AsSecureString "Password of the directory bind account '$AdBindUpn'"
        $plain = [Net.NetworkCredential]::new('', $secure).Password
        if (-not $plain) { throw "No password given for '$AdBindUpn'." }
        Set-OmsSecret -KubeContext $KubeContext -Namespace $Namespace -Name $BindSecretName -Data @{ 'bind-upn' = $AdBindUpn; 'bind-password' = $plain }
        $plain = $null
        Write-Host "    secret/$BindSecretName for $AdBindUpn" -ForegroundColor DarkGray
    }

    # The admin service account the realm Job signs in with. Keycloak creates it, as a temporary
    # admin, only on its first start against an empty database, so the secret is never changed.
    if (-not (Get-SecretValue -Name $AdminClientSecretName -Key 'client-secret')) {
        Set-OmsSecret -KubeContext $KubeContext -Namespace $Namespace -Name $AdminClientSecretName `
            -Data @{ 'client-id' = 'realm-config'; 'client-secret' = (New-RandomSecret) }
    }

    # CloudNativePG reads the database login in the basic-auth form. The value goes to kubectl on
    # stdin, never on a command line.
    $dbPassword = Get-SecretValue -Name 'keycloak-db' -Key 'password'
    if (-not $dbPassword) { $dbPassword = New-RandomSecret }
    @{
        apiVersion = 'v1'
        kind       = 'Secret'
        type       = 'kubernetes.io/basic-auth'
        metadata   = @{ name = 'keycloak-db'; namespace = $Namespace }
        stringData = @{ username = 'keycloak'; password = $dbPassword }
    } | ConvertTo-Json -Depth 5 | kubectl --context $KubeContext apply -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not write the 'keycloak-db' Secret." }

    # With high availability the database is a CloudNativePG cluster that backs up to the site's
    # object store with this namespace's credentials.
    if ($highAvailability) {
        if (-not (Get-SecretValue -Name $BackupSecretName -Key 'ACCESS_KEY_ID')) {
            throw "No Secret '$BackupSecretName' in '$Namespace' for Keycloak's database backups. Run scripts/infra/azurelocal/provision-object-store.ps1 first."
        }
        if (-not (kubectl --context $KubeContext get crd clusters.postgresql.cnpg.io --ignore-not-found --output name)) {
            throw 'CloudNativePG, which runs Keycloak''s database, is not installed. Run scripts/infra/azurelocal/provision-operators.ps1 first, or use -Availability standard.'
        }
    }

    # The 'grafana' client's secret, generated once. The realm Job reads it from this Secret, and
    # provision-observability.ps1 gives Grafana the same value.
    if (-not (Get-SecretValue -Name 'grafana-oauth' -Key 'client-secret')) {
        Set-OmsSecret -KubeContext $KubeContext -Namespace $Namespace -Name 'grafana-oauth' `
            -Data @{ 'client-id' = 'grafana'; 'client-secret' = (New-RandomSecret) }
    }

    # ------------------------------------------------------------------------------------------
    # Keycloak's address: the Service first, so its load balancer address is known before the
    # certificate and the realm settings that name it.
    # ------------------------------------------------------------------------------------------
    Write-Host "==> Keycloak's address on the site network" -ForegroundColor Cyan
    kubectl --context $KubeContext apply -f (Join-Path $keycloakDir 'service.yaml') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not apply infra/azurelocal/keycloak/service.yaml.' }
    # Only Keycloak's own clients reach its pods and its database.
    kubectl --context $KubeContext apply -f (Join-Path $repoRoot 'infra/azurelocal/keycloak-network-policy.yaml') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not apply infra/azurelocal/keycloak-network-policy.yaml.' }
    if ($KeycloakIp) {
        # Pins the address, so it survives the Service being recreated.
        kubectl --context $KubeContext -n $Namespace annotate service $ReleaseName --overwrite `
            "metallb.io/loadBalancerIPs=$KeycloakIp" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not pin Keycloak's address to $KeycloakIp." }
    }
    $keycloakAddress = $null
    $deadline = (Get-Date).AddMinutes(3)
    while (-not $keycloakAddress -and (Get-Date) -lt $deadline) {
        $keycloakAddress = Get-OmsIngressAddress $KubeContext $Namespace $ReleaseName
        if (-not $keycloakAddress) { Start-Sleep -Seconds 5 }
    }
    if (-not $keycloakAddress) { throw "Keycloak's Service got no load balancer address. Check that the cluster's load balancer has a free address." }
    if ($KeycloakIp -and $keycloakAddress -ne $KeycloakIp) { throw "Keycloak's Service got address '$keycloakAddress', expected $KeycloakIp." }
    if (-not $KeycloakIp) {
        kubectl --context $KubeContext -n $Namespace annotate service $ReleaseName --overwrite `
            "metallb.io/loadBalancerIPs=$keycloakAddress" | Out-Null
    }
    $keycloakUrl = "https://$keycloakAddress"
    $issuerUrl = "$keycloakUrl/realms/$RealmName"
    Write-Host "    $keycloakUrl" -ForegroundColor DarkGray

    # ------------------------------------------------------------------------------------------
    # Site values. The realm and the manifests are files in infra/azurelocal/keycloak; what
    # differs per site goes into the keycloak-realm-settings ConfigMap, and the realm Job fills the
    # ${...} placeholders in realm.json from it on every run.
    # ------------------------------------------------------------------------------------------
    Write-Host "==> Writing the site settings for the '$RealmName' realm" -ForegroundColor Cyan

    $ldapPort = if ($UseLdaps) { 636 } else { 389 }
    $ldapScheme = if ($UseLdaps) { 'ldaps' } else { 'ldap' }
    $baseDn = ($AdDomain.Split('.') | ForEach-Object { "DC=$_" }) -join ','
    $usersDn = "OU=$AdOuName,$baseDn"

    if ($UseLdaps) {
        # The controller's certificate carries its host name, so an address here fails hostname
        # verification no matter how the trust is set up.
        if ($AdServer -match '^\d{1,3}(\.\d{1,3}){3}$') {
            throw "-AdServer is the address '$AdServer'. LDAPS validates the controller's host name, so pass its FQDN instead, or pass -UseLdaps:`$false to use plain LDAP."
        }

        if (-not (Get-SecretValue -Name $CaSecretName -Key 'ca.crt')) {
            # The CA certificate is public, so it comes from a file the settings point at.
            if (-not $AdCaCertificatePath -or -not (Test-Path $AdCaCertificatePath)) {
                throw "Secret '$CaSecretName' is missing from namespace '$Namespace', so the directory's certificate cannot be trusted. Set AdCaCertificatePath in the Keycloak settings to the directory CA's certificate (PEM), or pass -UseLdaps:`$false."
            }
            $adCa = (Get-Content $AdCaCertificatePath -Raw).Trim()
            if ($adCa -notmatch '-----BEGIN CERTIFICATE-----') { throw "'$AdCaCertificatePath' is not a PEM certificate." }
            Set-OmsSecret -KubeContext $KubeContext -Namespace $Namespace -Name $CaSecretName -Data @{ 'ca.crt' = $adCa }
            Write-Host "    secret/$CaSecretName from $AdCaCertificatePath" -ForegroundColor DarkGray
        }
    }
    else {
        Write-Warning 'Binding over plain LDAP. The bind password and every user password cross the site network in the clear.'
    }

    $realmSettings = [ordered]@{
        # Keycloak's own address, which tokens name as their issuer.
        KC_HOSTNAME       = $keycloakUrl
        LDAP_URL          = "${ldapScheme}://${AdServer}:${ldapPort}"
        LDAP_USERS_DN     = $usersDn
        KUBERNETES_ISSUER = $issuer
        # Signing keys come from the API server inside the cluster, never the issuer's address.
        KUBERNETES_ISSUER_DISCOVERY_URL = 'https://kubernetes.default.svc'
        WORKLOAD_NAMESPACE = $ApplicationNamespace
        SPA_ORIGIN        = $SpaOrigin.TrimEnd('/')
        GRAFANA_ORIGIN    = $GrafanaOrigin.TrimEnd('/')
    }
    # None of these is secret, so they can go on the command line.
    $literals = $realmSettings.GetEnumerator() | ForEach-Object { "--from-literal=$($_.Key)=$($_.Value)" }
    kubectl --context $KubeContext -n $Namespace create configmap keycloak-realm-settings $literals `
        --dry-run=client --output yaml | kubectl --context $KubeContext apply -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not write the keycloak-realm-settings ConfigMap.' }

    Set-OmsSecret -KubeContext $KubeContext -Namespace $Namespace -Name 'cluster-ca' -Data @{ 'cluster-ca.pem' = $clusterCaPem }

    if ($Registry) {
        # Pull secrets do not cross namespaces, so the one the rest of the deployment uses has to
        # be copied here or the kubelet falls back to an anonymous token and the registry refuses.
        Copy-OmsPullSecret -KubeContext $KubeContext -Namespace $Namespace -SourceNamespace $ApplicationNamespace -SecretName $ImagePullSecretName
    }

    # Keycloak refuses to start 'start' mode over plain HTTP, so it needs a certificate before the
    # Deployment is applied. cert-manager issues it from the site CA and renews it 30 days before it
    # expires; Keycloak re-reads the files every 10 minutes (keycloak.yaml), so no restart is needed.
    # The database's certificate comes from the same CA, which Keycloak checks it against.
    if ($CertificateIssuer) {
        if (-not (kubectl --context $KubeContext get clusterissuer $CertificateIssuer --ignore-not-found --output name)) {
            throw "No ClusterIssuer '$CertificateIssuer'. Run ./scripts/infra/azurelocal/provision-ingress.ps1 first, or pass -CertificateIssuer '' and create Secrets $Namespace/$TlsSecretName and $DatabaseTlsSecretName yourself."
        }
        Write-Host "==> Certificates for Keycloak and its database from ClusterIssuer '$CertificateIssuer'" -ForegroundColor Cyan

        # The load balancer address goes in as a real iPAddress entry: browsers reject an address
        # listed as a DNS name when the URL is an address. 'localhost' is for the admin console,
        # which administrators reach through a port-forward (KC_HOSTNAME_ADMIN in keycloak.yaml).
        @{
            apiVersion = 'cert-manager.io/v1'
            kind       = 'Certificate'
            metadata   = @{ name = $TlsSecretName; namespace = $Namespace }
            spec       = @{
                secretName  = $TlsSecretName
                issuerRef   = @{ kind = 'ClusterIssuer'; name = $CertificateIssuer }
                commonName  = "$ReleaseName.$Namespace.svc"
                dnsNames    = @($ReleaseName, "$ReleaseName.$Namespace", "$ReleaseName.$Namespace.svc", "$ReleaseName.$Namespace.svc.cluster.local", 'localhost')
                ipAddresses = @($keycloakAddress)
                duration    = '2160h'
                renewBefore = '720h'
                privateKey  = @{ algorithm = 'RSA'; size = 2048; rotationPolicy = 'Always' }
            }
        } | ConvertTo-Json -Depth 5 | kubectl --context $KubeContext apply -f - | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Creating the Keycloak Certificate failed.' }

        # CloudNativePG reloads the server certificate when a Secret with this label changes.
        @{
            apiVersion = 'cert-manager.io/v1'
            kind       = 'Certificate'
            metadata   = @{ name = $DatabaseTlsSecretName; namespace = $Namespace }
            spec       = @{
                secretName     = $DatabaseTlsSecretName
                secretTemplate = @{ labels = @{ 'cnpg.io/reload' = '' } }
                issuerRef      = @{ kind = 'ClusterIssuer'; name = $CertificateIssuer }
                commonName     = "keycloak-db-rw.$Namespace.svc"
                dnsNames       = @('keycloak-db-rw', "keycloak-db-rw.$Namespace", "keycloak-db-rw.$Namespace.svc", "keycloak-db-rw.$Namespace.svc.cluster.local")
                usages         = @('server auth')
                duration       = '2160h'
                renewBefore    = '720h'
                privateKey     = @{ algorithm = 'RSA'; size = 2048; rotationPolicy = 'Always' }
            }
        } | ConvertTo-Json -Depth 5 | kubectl --context $KubeContext apply -f - | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Creating the Certificate for Keycloak's database failed." }

        Wait-OmsCertificate $KubeContext $Namespace $TlsSecretName
        Wait-OmsCertificate $KubeContext $Namespace $DatabaseTlsSecretName
    }
    else {
        # cert-manager would keep overwriting a certificate supplied by hand.
        foreach ($name in @($TlsSecretName, $DatabaseTlsSecretName)) {
            if (kubectl --context $KubeContext -n $Namespace get certificate $name --ignore-not-found --output name) {
                throw @"
cert-manager manages Secret $Namespace/$name, so it would replace your certificate. Remove its
Certificate first, then create the Secret (deleting the Certificate may delete the Secret with it):
  kubectl --context $KubeContext -n $Namespace delete certificate $name
"@
            }
        }
    }
    # Keycloak's pods and the realm Job check Keycloak and the database against ca.crt, which
    # cert-manager writes next to the certificate.
    foreach ($name in @($TlsSecretName, $DatabaseTlsSecretName)) {
        if (-not (Get-SecretValue -Name $name -Key 'ca.crt')) {
            throw @"
Secret $Namespace/$name needs tls.crt, tls.key and ca.crt, the CA that issued the certificate.
With -CertificateIssuer '', create it yourself:
  kubectl --context $KubeContext -n $Namespace create secret generic $name --type=kubernetes.io/tls --from-file=tls.crt=<crt> --from-file=tls.key=<key> --from-file=ca.crt=<ca>
The certificate names $(if ($name -eq $TlsSecretName) { "Keycloak's address $keycloakAddress, $ReleaseName.$Namespace.svc and localhost" } else { "keycloak-db-rw and keycloak-db-rw.$Namespace.svc" }).
"@
        }
    }

    # ------------------------------------------------------------------------------------------
    # Keycloak, its database and the realm Job. A Job runs once, so the previous run's goes first.
    # ------------------------------------------------------------------------------------------
    Write-Host "==> Deploying Keycloak and its database from infra/azurelocal/keycloak" -ForegroundColor Cyan
    Invoke-Checked "Removing the previous $RealmJobName Job" {
        kubectl --context $KubeContext -n $Namespace delete job $RealmJobName --ignore-not-found | Out-Null
    }
    Get-KeycloakManifest $keycloakUrl | kubectl --context $KubeContext -n $Namespace apply -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not apply infra/azurelocal/keycloak.' }

    Write-Host "==> Waiting for Keycloak's database" -ForegroundColor Cyan
    Invoke-Checked 'keycloak-db' {
        if ($highAvailability) {
            kubectl --context $KubeContext -n $Namespace wait cluster.postgresql.cnpg.io/keycloak-db `
                --for=condition=Ready --timeout=900s | Out-Null
        }
        else {
            kubectl --context $KubeContext -n $Namespace rollout status statefulset keycloak-db --timeout=900s | Out-Null
        }
    }

    Write-Host "==> Waiting for Keycloak to become ready" -ForegroundColor Cyan
    Invoke-Checked 'keycloak rollout' {
        kubectl --context $KubeContext -n $Namespace rollout status deployment $ReleaseName --timeout=900s | Out-Null
    }

    Write-Host "==> Applying realm.json to the '$RealmName' realm" -ForegroundColor Cyan
    Wait-RealmJob

    # Workloads need the certificate authority they check Keycloak against in their own namespace.
    # Each service's identity is its own service account there, which the container Recipe creates
    # and the realm's workload-<service> clients trust.
    Write-Host "==> Preparing namespace $ApplicationNamespace for workloads" -ForegroundColor Cyan

    kubectl --context $KubeContext create namespace $ApplicationNamespace `
        --dry-run=client --output yaml | kubectl --context $KubeContext apply -f - | Out-Null

    # Keycloak serves a certificate issued by a CA the cluster does not know, so the workload and
    # RabbitMQ both need that CA. Publishing the issuer rather than the serving certificate is what
    # lets a strict TLS client, such as the Erlang one RabbitMQ uses, build a valid path.
    $keycloakCa = Get-SecretValue -Name $TlsSecretName -Key 'ca.crt'
    Set-OmsSecret -KubeContext $KubeContext -Namespace $ApplicationNamespace -Name $WorkloadCaSecretName -Data @{ 'ca.crt' = $keycloakCa }
    Write-Host "    secret/$WorkloadCaSecretName" -ForegroundColor DarkGray

    # Sign-in sends the browser to Keycloak, so browsers have to trust the CA behind its certificate.
    $identityCaFile = Join-Path $repoRoot 'oms-identity-ca.crt'
    [IO.File]::WriteAllText($identityCaFile, $keycloakCa)

    Write-Host "`n================ Identity ready ================" -ForegroundColor Green
    Write-Host "Keycloak realm   : $issuerUrl"
    Write-Host "Directory        : ${ldapScheme}://${AdServer}:${ldapPort} ($usersDn)"
    Write-Host "Cluster issuer   : $issuer"
    Write-Host "Workload clients : workload-<service>, for service accounts ${ApplicationNamespace}:<service>"
    Write-Host "Issuer CA secret : $WorkloadCaSecretName (namespace $ApplicationNamespace)"
    Write-Host "Grafana client   : grafana, for $GrafanaOrigin (secret $Namespace/grafana-oauth)"
    Write-Host ''
    Write-Host 'A workload authenticates with its ServiceAccount token and no secret:' -ForegroundColor Yellow
    Write-Host '  curl --cacert /etc/identity-ca/ca.crt "$ISSUER/protocol/openid-connect/token" \'
    Write-Host '    -d grant_type=client_credentials \'
    Write-Host "    -d client_id=workload-<service> \"
    Write-Host '    -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer \'
    Write-Host '    -d client_assertion=$(cat /var/run/secrets/identity/token)'
    Write-Host ''
    Write-Host 'The pod gets that assertion from a projected volume, not from a stored secret:' -ForegroundColor DarkGray
    Write-Host "  serviceAccountToken: { audience: '$issuerUrl', path: token, expirationSeconds: 600 }"
    Write-Host ''
    Write-Host "The admin console isn't on the site network. Members of the directory group oms-identity-admins reach it with:" -ForegroundColor Yellow
    Write-Host "  kubectl --context $KubeContext -n $Namespace port-forward service/$ReleaseName 8443:443"
    Write-Host "  https://localhost:8443/admin/$RealmName/console/"
    Write-Host ''
    Write-Host 'Trust the CA behind Keycloak''s certificate on a machine outside the domain (once; it shows a confirmation prompt). With the site CA, this is the same CA the ingress uses:'
    Write-Host "  Import-Certificate -FilePath $identityCaFile -CertStoreLocation Cert:\CurrentUser\Root"
}
finally {
    Pop-Location
}
