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
    balancer address) and realm.json (the 'oms' realm: AD federation, app roles, the sign-in and
    workload clients). This script does the per-site parts
    around those files: it creates the Secrets, gives Keycloak its address and a certificate for it,
    writes the site values into the keycloak-realm-settings ConfigMap, applies the folder with
    kustomize, and prepares the app's namespace. The folder's README.md describes the same steps by
    hand.

    Keycloak's address is one from the Arc load balancer, kept on later runs, so its issuer URL,
    https://<address>/realms/oms, doesn't depend on any one node.

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
    Registry holding the mirrored Keycloak and PostgreSQL images, normally the in-cluster connected
    registry. Omit to read it from the image pull secret in -ApplicationNamespace; with no
    such secret, the images come from the public registries, which only works where the cluster has
    internet.

.PARAMETER UseLdaps
    Bind to the directory over LDAPS on 636, which is the default. The certificate comes from the
    directory's enterprise CA, handed over in the 'oms-ad-ca' Secret. Pass -UseLdaps:$false to fall back to plain LDAP on
    389, which sends the bind password and every user password across the network in the clear.

.PARAMETER CertificateIssuer
    cert-manager ClusterIssuer that issues and renews Keycloak's certificate, and with -Availability
    standard its database's, 'site-ca' from provision-ingress.ps1 by default. Pass '' to supply
    Secrets identity/keycloak-tls (and keycloak-db-tls) yourself, which then aren't renewed.

.EXAMPLE
    ./scripts/infra/azurelocal/keycloak.ps1 -AdServer dc01.contoso.local -AdDomain contoso.local -AllowInClusterIssuer
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$AdServer,
    [string]$AdDomain = 'azurelocal.lab',
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
    # ClusterIssuer for Keycloak's certificate, which provision-ingress.ps1 creates. Empty to supply
    # Secret identity/keycloak-tls yourself.
    [string]$CertificateIssuer = 'site-ca',

    [switch]$SkipVerify,

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
$ImagePullSecretName = 'azurelocal-registry'
$BindSecretName = 'oms-ad-bind'
$CaSecretName = 'oms-ad-ca'
$BackupSecretName = 'backup-object-store'
$DatabaseTlsSecretName = 'keycloak-db-tls'
$keycloakDir = Join-Path $repoRoot 'infra/azurelocal/keycloak'
$highAvailability = $Availability -eq 'high'
$databaseManifest = Join-Path $keycloakDir "database/$(if ($highAvailability) { 'cloudnative-pg' } else { 'postgres' }).yaml"
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

# The CA behind Keycloak's certificate, which workloads and browsers check Keycloak against.
function Get-KeycloakCa {
    # cert-manager writes the issuing CA next to the certificate as ca.crt. A self-signed certificate
    # supplied by hand has none; then the certificate itself is what's trusted.
    $ca = Get-SecretValue -Name 'keycloak-tls' -Key 'ca.crt'
    if (-not $ca) { $ca = Get-SecretValue -Name 'keycloak-tls' -Key 'tls.crt' }
    if (-not $ca) { throw "Secret '$Namespace/keycloak-tls' holds no certificate to check Keycloak's against." }
    $ca
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

    $adminPassword = Get-SecretValue -Name 'keycloak-admin' -Key 'password'
    $dbPassword = Get-SecretValue -Name 'keycloak-db' -Key 'password'

    if (-not $adminPassword) { $adminPassword = New-RandomSecret }
    if (-not $dbPassword) { $dbPassword = New-RandomSecret }

    foreach ($pair in @(
            @{ Name = 'keycloak-admin'; Type = 'Opaque'; Username = 'admin'; Password = $adminPassword },
            # CloudNativePG reads the database login in the basic-auth form.
            @{ Name = 'keycloak-db'; Type = 'kubernetes.io/basic-auth'; Username = 'keycloak'; Password = $dbPassword }
        )) {
        # Values go to kubectl on stdin, never on a command line.
        @{
            apiVersion = 'v1'
            kind       = 'Secret'
            type       = $pair.Type
            metadata   = @{ name = $pair.Name; namespace = $Namespace }
            stringData = @{ username = $pair.Username; password = $pair.Password }
        } | ConvertTo-Json -Depth 5 | kubectl --context $KubeContext apply -f - | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not write the '$($pair.Name)' Secret." }
    }

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

    # The 'grafana' client's secret, generated once. Keycloak reads it from this Secret, and
    # provision-observability.ps1 gives Grafana the same value. It goes to kubectl on stdin, never
    # on a command line.
    if (-not (Get-SecretValue -Name 'grafana-oauth' -Key 'client-secret')) {
        @{
            apiVersion = 'v1'
            kind       = 'Secret'
            type       = 'Opaque'
            metadata   = @{ name = 'grafana-oauth'; namespace = $Namespace }
            stringData = @{ 'client-id' = 'grafana'; 'client-secret' = (New-RandomSecret) }
        } | ConvertTo-Json -Depth 5 | kubectl --context $KubeContext apply -f - | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not write the 'grafana-oauth' Secret." }
    }

    # ------------------------------------------------------------------------------------------
    # Keycloak's address: the Service first, so its load balancer address is known before the
    # certificate and the realm settings that name it.
    # ------------------------------------------------------------------------------------------
    Write-Host "==> Keycloak's address on the site network" -ForegroundColor Cyan
    if (-not $KeycloakIp) { $KeycloakIp = Get-OmsIngressAddress $KubeContext $Namespace $ReleaseName }
    kubectl --context $KubeContext apply -f (Join-Path $keycloakDir 'service.yaml') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not apply infra/azurelocal/keycloak/service.yaml.' }
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
    # differs per site goes into the keycloak-realm-settings ConfigMap, and Keycloak fills the
    # ${...} placeholders in realm.json from it when it imports the realm.
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
    $previousSettings = kubectl --context $KubeContext -n $Namespace get configmap keycloak-realm-settings `
        --ignore-not-found --output 'jsonpath={.data}'
    $literals = $realmSettings.GetEnumerator() | ForEach-Object { "--from-literal=$($_.Key)=$($_.Value)" }
    kubectl --context $KubeContext -n $Namespace create configmap keycloak-realm-settings $literals `
        --dry-run=client --output yaml | kubectl --context $KubeContext apply -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not write the keycloak-realm-settings ConfigMap.' }
    # Keycloak reads these when it starts, so a running Keycloak restarts to pick up a change.
    $currentSettings = kubectl --context $KubeContext -n $Namespace get configmap keycloak-realm-settings --output 'jsonpath={.data}'
    $settingsChanged = $previousSettings -and ($previousSettings -ne $currentSettings)

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

    if ($Registry) {
        # Pull secrets do not cross namespaces, so the one the rest of the deployment uses has to
        # be copied here or the kubelet falls back to an anonymous token and the registry refuses.
        Copy-OmsPullSecret -KubeContext $KubeContext -Namespace $Namespace -SourceNamespace $ApplicationNamespace -SecretName $ImagePullSecretName
    }

    # Keycloak refuses to start 'start' mode over plain HTTP, so it needs a certificate before the
    # Deployment is applied. cert-manager issues it from the site CA and renews it 30 days before it
    # expires; Keycloak re-reads the files every 10 minutes (keycloak.yaml), so no restart is needed.
    if ($CertificateIssuer) {
        if (-not (kubectl --context $KubeContext get clusterissuer $CertificateIssuer --ignore-not-found --output name)) {
            throw "No ClusterIssuer '$CertificateIssuer'. Run ./scripts/infra/azurelocal/provision-ingress.ps1 first, or pass -CertificateIssuer '' and create Secret $Namespace/keycloak-tls yourself."
        }
        Write-Host "==> Certificate for Keycloak from ClusterIssuer '$CertificateIssuer'" -ForegroundColor Cyan

        # The load balancer address goes in as a real iPAddress entry: browsers reject an address
        # listed as a DNS name when the URL is an address.
        @"
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: keycloak-tls
  namespace: $Namespace
spec:
  secretName: keycloak-tls
  commonName: $ReleaseName.$Namespace.svc
  dnsNames:
    - $ReleaseName
    - $ReleaseName.$Namespace
    - $ReleaseName.$Namespace.svc
    - $ReleaseName.$Namespace.svc.cluster.local
  ipAddresses:
    - $keycloakAddress
  duration: 2160h
  renewBefore: 720h
  privateKey:
    algorithm: RSA
    size: 2048
    rotationPolicy: Always
  issuerRef:
    kind: ClusterIssuer
    name: $CertificateIssuer
"@ | kubectl --context $KubeContext apply -f - | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Creating the Keycloak Certificate failed.' }
        Wait-OmsCertificate $KubeContext $Namespace 'keycloak-tls'

        # CloudNativePG gives its own database a certificate; the StatefulSet's comes from the same
        # issuer as Keycloak's.
        if (-not $highAvailability) {
            @{
                apiVersion = 'cert-manager.io/v1'
                kind       = 'Certificate'
                metadata   = @{ name = $DatabaseTlsSecretName; namespace = $Namespace }
                spec       = @{
                    secretName  = $DatabaseTlsSecretName
                    issuerRef   = @{ kind = 'ClusterIssuer'; name = $CertificateIssuer }
                    commonName  = "keycloak-db-rw.$Namespace.svc"
                    dnsNames    = @('keycloak-db-rw', "keycloak-db-rw.$Namespace", "keycloak-db-rw.$Namespace.svc", "keycloak-db-rw.$Namespace.svc.cluster.local")
                    usages      = @('server auth')
                    duration    = '2160h'
                    renewBefore = '720h'
                    privateKey  = @{ algorithm = 'RSA'; size = 2048; rotationPolicy = 'Always' }
                }
            } | ConvertTo-Json -Depth 5 | kubectl --context $KubeContext apply -f - | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Creating the Certificate for Keycloak's database failed." }
            Wait-OmsCertificate $KubeContext $Namespace $DatabaseTlsSecretName
        }
    }
    else {
        # cert-manager would keep overwriting a certificate supplied by hand.
        if (kubectl --context $KubeContext -n $Namespace get certificate keycloak-tls --ignore-not-found --output name) {
            throw @"
cert-manager manages Secret $Namespace/keycloak-tls, so it would replace your certificate. Remove its
Certificate first, then create the Secret (deleting the Certificate may delete the Secret with it):
  kubectl --context $KubeContext -n $Namespace delete certificate keycloak-tls
  kubectl --context $KubeContext -n $Namespace create secret tls keycloak-tls --cert <crt> --key <key>
"@
        }
        if (-not (kubectl --context $KubeContext -n $Namespace get secret keycloak-tls --ignore-not-found --output name)) {
            throw "With -CertificateIssuer '', create the Keycloak certificate yourself: kubectl --context $KubeContext -n $Namespace create secret tls keycloak-tls --cert <crt> --key <key>"
        }
        if (-not $highAvailability -and -not (kubectl --context $KubeContext -n $Namespace get secret $DatabaseTlsSecretName --ignore-not-found --output name)) {
            throw "With -CertificateIssuer '', create the database's certificate yourself, for keycloak-db-rw.$Namespace.svc: kubectl --context $KubeContext -n $Namespace create secret tls $DatabaseTlsSecretName --cert <crt> --key <key>"
        }
    }
    Write-Host "==> Deploying Keycloak and its database from infra/azurelocal/keycloak" -ForegroundColor Cyan
    $rendered = kubectl kustomize $keycloakDir
    if ($LASTEXITCODE -ne 0) { throw 'Could not render infra/azurelocal/keycloak.' }
    $rendered = @($rendered) + '---' + (Get-Content $databaseManifest)
    if ($Registry) {
        # The manifests name the public images; the site pulls the same images from its own registry.
        $rendered = $rendered -replace '(image|imageName): (quay\.io|ghcr\.io|docker\.io/library)/', "`${1}: $Registry/"
    }
    $rendered | kubectl --context $KubeContext -n $Namespace apply -f - | Out-Null
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
    if ($settingsChanged) {
        kubectl --context $KubeContext -n $Namespace rollout restart deployment $ReleaseName | Out-Null
    }
    Invoke-Checked 'keycloak rollout' {
        kubectl --context $KubeContext -n $Namespace rollout status deployment $ReleaseName --timeout=900s | Out-Null
    }

    # Keycloak imports the realm on start and only becomes ready once it has, so the rollout above
    # covers the realm. An LDAP misconfiguration shows up as a federation provider that loads but
    # never returns a user, which only Keycloak's log shows.
    if (-not $SkipVerify) {
        $ldapError = kubectl --context $KubeContext -n $Namespace logs "deploy/$ReleaseName" --tail=200 |
            Select-String -Pattern 'ERROR|WARN' |
            Select-String -Pattern 'ldap|NamingException|federation'
        if ($ldapError) {
            Write-Warning "Keycloak logged a directory problem:`n$($ldapError -join "`n")"
        }
    }

    # Workloads need the certificate authority they check Keycloak against in their own namespace.
    # Each service's identity is its own service account there, which the container Recipe creates
    # and the realm's workload-<service> clients trust.
    Write-Host "==> Preparing namespace $ApplicationNamespace for workloads" -ForegroundColor Cyan

    kubectl --context $KubeContext create namespace $ApplicationNamespace `
        --dry-run=client --output yaml | kubectl --context $KubeContext apply -f - | Out-Null

    # Keycloak serves a certificate issued by a CA the cluster does not know, so the workload and
    # RabbitMQ both need that CA. Publishing the issuer rather than the serving certificate is what
    # lets a strict TLS client, such as the Erlang one RabbitMQ uses, build a valid path.
    $keycloakCert = Get-KeycloakCa

    $caFile = New-TemporaryFile
    try {
        Set-Content -Path $caFile -Value $keycloakCert -Encoding ascii -NoNewline

        kubectl --context $KubeContext -n $ApplicationNamespace delete secret $WorkloadCaSecretName `
            --ignore-not-found | Out-Null
        kubectl --context $KubeContext -n $ApplicationNamespace create secret generic $WorkloadCaSecretName `
            --from-file="ca.crt=$caFile" | Out-Null
    }
    finally {
        Remove-Item -Path $caFile -Force -ErrorAction SilentlyContinue
    }
    Write-Host "    secret/$WorkloadCaSecretName" -ForegroundColor DarkGray

    # Sign-in sends the browser to Keycloak, so browsers have to trust the CA behind its certificate.
    $identityCaFile = Join-Path $repoRoot 'oms-identity-ca.crt'
    [IO.File]::WriteAllText($identityCaFile, $keycloakCert)

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
    Write-Host 'Trust the CA behind Keycloak''s certificate on a machine outside the domain (once; it shows a confirmation prompt). With the site CA, this is the same CA the ingress uses:'
    Write-Host "  Import-Certificate -FilePath $identityCaFile -CertStoreLocation Cert:\CurrentUser\Root"
}
finally {
    Pop-Location
}
