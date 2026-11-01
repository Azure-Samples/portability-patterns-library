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

    What gets deployed is in infra/azurelocal/keycloak: keycloak.yaml (Keycloak and PostgreSQL)
    and realm.json (the 'oms' realm: AD federation, app roles, the sign-in and workload clients).
    This script does the per-site parts around those files: it creates the Secrets, writes the
    site values into the keycloak-realm-settings ConfigMap, applies the folder with kustomize, and
    prepares the app's namespace. The folder's README.md describes the same steps by hand.

    Keycloak trusts the cluster's ServiceAccount token issuer. It fetches the cluster's signing keys
    from the API server inside the cluster (kubernetes.default.svc), never from the issuer's own
    address: with Arc workload identity on, the issuer is a public Azure URL, and keys fetched
    from there would stop loading when the site loses its link to Azure. On a cluster that still
    uses the default in-cluster issuer, pass -AllowInClusterIssuer.

.PARAMETER AdServer
    Host name of the site's domain controller. Under LDAPS this must
    be the name in the controller's certificate, not its address, or the handshake fails.

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
    registry. Omit to read it from the image pull secret in -ImagePullSecretSourceNamespace; with no
    such secret, the images come from the public registries, which only works where the cluster has
    internet.

.PARAMETER UseLdaps
    Bind to the directory over LDAPS on 636, which is the default. The certificate comes from the
    directory's enterprise CA, handed over in the 'oms-ad-ca' Secret. Pass -UseLdaps:$false to fall back to plain LDAP on
    389, which sends the bind password and every user password across the network in the clear.

.PARAMETER ReimportRealm
    Delete the 'oms' realm and import realm.json again. Keycloak imports a realm only when it does
    not exist, so this is how a changed realm.json reaches a running Keycloak. The new realm has new
    signing keys, so restart the app's pods afterwards or they reject tokens until their key cache
    refreshes.

.PARAMETER CertificateIssuer
    cert-manager ClusterIssuer that issues and renews Keycloak's certificate, 'site-ca' from
    provision-ingress.ps1 by default. Pass '' to supply Secret identity/keycloak-tls yourself, which
    then isn't renewed.

.EXAMPLE
    ./scripts/infra/azurelocal/keycloak.ps1 -AdServer dc01.contoso.local -AdDomain contoso.local -AllowInClusterIssuer
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$AdServer,
    [string]$AdDomain = 'azurelocal.lab',
    [string]$AdOuName = 'OMS',
    [switch]$UseLdaps = $true,
    [string]$SpaOrigin,
    [string]$GrafanaOrigin,

    [string]$KubeContext = 'bcd-aksarc',

    [string]$Registry,
    [string]$ImagePullSecretSourceNamespace = 'oms-azurelocal',

    [string]$WorkloadNamespace = 'oms-azurelocal',
    [string]$WorkloadCaSecretName = 'oms-identity-ca',

    # ClusterIssuer for Keycloak's certificate, which provision-ingress.ps1 creates. Empty to supply
    # Secret identity/keycloak-tls yourself.
    [string]$CertificateIssuer = 'site-ca',

    [switch]$ReimportRealm,
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
$NodePort = 30443
$ImagePullSecretName = 'azurelocal-registry'
$BindSecretName = 'oms-ad-bind'
$CaSecretName = 'oms-ad-ca'
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

function New-RandomSecret {
    $bytes = [byte[]]::new(24)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    # Base64url, so the value survives being pasted into a URL or a header without escaping.
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
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
        $Registry = Get-OmsPullRegistry $KubeContext $ImagePullSecretSourceNamespace $ImagePullSecretName
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

    # Keycloak opens the JWKS endpoint itself, over TLS the API server terminates with its own CA.
    # That CA is already in the kubeconfig, so there is no need to go back to the node for it.
    $caData = kubectl --context $KubeContext config view --raw --minify `
        --output 'jsonpath={.clusters[0].cluster.certificate-authority-data}'
    if ([string]::IsNullOrWhiteSpace($caData)) {
        throw 'The kubeconfig carries no cluster CA, so Keycloak could not verify the JWKS endpoint.'
    }
    $clusterCaPem = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($caData))

    # ------------------------------------------------------------------------------------------
    # Credentials. Generated once and kept in the cluster, so re-running does not churn them.
    # ------------------------------------------------------------------------------------------
    $bindDn = Get-SecretValue -Name $BindSecretName -Key 'bind-upn'
    $bindPassword = Get-SecretValue -Name $BindSecretName -Key 'bind-password'
    if (-not $bindDn -or -not $bindPassword) {
        throw @"
No usable '$BindSecretName' Secret in namespace '$Namespace'.
Create it with the directory bind account (keys bind-upn, bind-password), or run
scripts/infra/azurelocal/ad-setup.ps1.
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
            throw "Secret '$CaSecretName' is missing from namespace '$Namespace', so the directory's certificate cannot be trusted. Create it with the directory's CA certificate (key ca.crt; scripts/infra/azurelocal/ad-setup.ps1 does this), or pass -UseLdaps:`$false."
        }
    }
    else {
        Write-Warning 'Binding over plain LDAP. The bind password and every user password cross the site network in the clear.'
    }

    $realmSettings = [ordered]@{
        LDAP_URL          = "${ldapScheme}://${AdServer}:${ldapPort}"
        LDAP_USERS_DN     = $usersDn
        KUBERNETES_ISSUER = $issuer
        # Signing keys come from the API server inside the cluster, never the issuer's address.
        KUBERNETES_ISSUER_DISCOVERY_URL = 'https://kubernetes.default.svc'
        WORKLOAD_NAMESPACE = $WorkloadNamespace
        SPA_ORIGIN        = $SpaOrigin.TrimEnd('/')
        GRAFANA_ORIGIN    = $GrafanaOrigin.TrimEnd('/')
    }
    $literals = $realmSettings.GetEnumerator() | ForEach-Object { "--from-literal=$($_.Key)=$($_.Value)" }
    kubectl --context $KubeContext -n $Namespace create configmap keycloak-realm-settings $literals `
        --dry-run=client --output yaml | kubectl --context $KubeContext apply -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not write the keycloak-realm-settings ConfigMap.' }

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
    }

    # Keycloak refuses to start 'start' mode over plain HTTP, so it needs a certificate before the
    # Deployment is applied. cert-manager issues it from the site CA and renews it 30 days before it
    # expires; Keycloak re-reads the files every 10 minutes (keycloak.yaml), so no restart is needed.
    if ($CertificateIssuer) {
        if (-not (kubectl --context $KubeContext get clusterissuer $CertificateIssuer --ignore-not-found --output name)) {
            throw "No ClusterIssuer '$CertificateIssuer'. Run ./scripts/infra/azurelocal/provision-ingress.ps1 first, or pass -CertificateIssuer '' and create Secret $Namespace/keycloak-tls yourself."
        }
        Write-Host "==> Certificate for Keycloak from ClusterIssuer '$CertificateIssuer'" -ForegroundColor Cyan

        $nodeIp = kubectl --context $KubeContext get nodes `
            --output 'jsonpath={.items[0].status.addresses[?(@.type=="InternalIP")].address}'
        # The node address goes in as a real iPAddress entry: browsers reject an address listed as a
        # DNS name when the URL is an address.
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
    - $nodeIp
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
    }
    Write-Host "==> Deploying PostgreSQL and Keycloak from infra/azurelocal/keycloak" -ForegroundColor Cyan
    $rendered = kubectl kustomize (Join-Path $repoRoot 'infra/azurelocal/keycloak')
    if ($LASTEXITCODE -ne 0) { throw 'Could not render infra/azurelocal/keycloak.' }
    if ($Registry) {
        # The manifests name the public images; the site pulls the same images from its own registry.
        $rendered = $rendered -replace 'image: (quay\.io|docker\.io/library)/', "image: $Registry/"
    }
    $rendered | kubectl --context $KubeContext apply -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not apply infra/azurelocal/keycloak.' }

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

    # Workloads need the certificate authority they check Keycloak against in their own namespace.
    # Each service's identity is its own service account there, which the container Recipe creates
    # and the realm's workload-<service> clients trust.
    Write-Host "==> Preparing namespace $WorkloadNamespace for workloads" -ForegroundColor Cyan

    kubectl --context $KubeContext create namespace $WorkloadNamespace `
        --dry-run=client --output yaml | kubectl --context $KubeContext apply -f - | Out-Null

    # Keycloak serves a certificate issued by a CA the cluster does not know, so the workload and
    # RabbitMQ both need that CA. Publishing the issuer rather than the serving certificate is what
    # lets a strict TLS client, such as the Erlang one RabbitMQ uses, build a valid path.
    # cert-manager writes the issuing CA next to the certificate, as ca.crt.
    $keycloakCert = Get-SecretValue -Name 'keycloak-tls' -Key 'ca.crt'
    if (-not $keycloakCert) {
        # A certificate supplied by hand may have no ca.crt; fall back to what Keycloak serves.
        $keycloakCert = Get-SecretValue -Name 'keycloak-tls' -Key 'tls.crt'
    }
    if (-not $keycloakCert) {
        throw "Secret 'keycloak-tls' in namespace '$Namespace' yields no certificate, so nothing can be published to '$WorkloadNamespace'."
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

    # Sign-in sends the browser to Keycloak, so browsers have to trust the CA behind its certificate.
    $identityCaFile = Join-Path $repoRoot 'oms-identity-ca.crt'
    [IO.File]::WriteAllText($identityCaFile, $keycloakCert)

    Write-Host "`n================ Identity ready ================" -ForegroundColor Green
    Write-Host "Keycloak realm   : $issuerUrl"
    Write-Host "Directory        : ${ldapScheme}://${AdServer}:${ldapPort} ($usersDn)"
    Write-Host "Cluster issuer   : $issuer"
    Write-Host "Workload clients : workload-<service>, for service accounts ${WorkloadNamespace}:<service>"
    Write-Host "Issuer CA secret : $WorkloadCaSecretName (namespace $WorkloadNamespace)"
    Write-Host "Grafana client   : grafana, for $GrafanaOrigin (secret $Namespace/grafana-oauth)"
    Write-Host ''
    Write-Host 'A workload authenticates with its ServiceAccount token and no secret:' -ForegroundColor Yellow
    Write-Host '  curl -sk "$ISSUER/protocol/openid-connect/token" \'
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
