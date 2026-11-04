#Requires -Version 7.3
<#
.SYNOPSIS
    Runs S3-compatible object storage (SeaweedFS) inside the Azure Local cluster, for the
    applications' object storage and the PostgreSQL clusters' backups.

.DESCRIPTION
    Platform layer, like provision-operators.ps1. On Azure Local the object store has to be on
    site, so applications keep writing objects, and the databases keep archiving their write-ahead
    log, while the link to Azure is down.

    Installs SeaweedFS from its Helm chart into namespace 'object-store', replicated and encrypted as
    infra/azurelocal/object-store/values.yaml describes. With -Availability standard it runs one of
    each component and keeps one copy of every object instead, and no database backs up to it.
    Clients reach it over HTTPS, with a certificate from the site CA (-CertificateIssuer). The key
    the store signs its write tokens with is generated once and kept, in Secret
    seaweedfs-jwt-signing-key. It creates S3 identities, each limited to its own buckets, with their
    keys generated once and kept:

      - for each namespace in -ObjectStorageNamespaces, an identity for the applications there, which
        may create and use buckets named '<namespace>.*' (the object storage Recipe's names). Its
        keys go in Secret object-store-credentials in the namespace, which the Recipe Pack gives only
        to containers connected to object storage;
      - for each namespace in -BackupNamespaces, a bucket postgres-<namespace> and an identity for
        the databases there, its keys and the CA to verify the store against in Secret
        backup-object-store.

    A network policy, infra/azurelocal/object-store/network-policy.yaml, lets in only those clients:
    it admits the namespaces this script labels object-store/objects and object-store/backups.
    Idempotent. To change a namespace's keys, run rotate-credentials.ps1.

    The store is in the same cluster as what it holds: it covers a failed node or pod, a bad change
    or a deleted table, not losing the cluster. infra/azurelocal/object-store/README.md says how to
    copy data off site.

    Prerequisites: connected-registry.ps1 (the SeaweedFS image), provision-ingress.ps1 (cert-manager
    and the site CA) and provision-operators.ps1.

.EXAMPLE
    ./scripts/infra/azurelocal/provision-object-store.ps1 -KubeContext <context>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$KubeContext,
    # The connected registry's address. Empty reads it from the pull secret connected-registry.ps1 wrote.
    [string]$PullRegistry,
    [string]$PullSecretName = 'azurelocal-registry',
    [string]$ApplicationNamespace = 'oms-azurelocal',
    # Keycloak's namespace (keycloak.ps1), whose database backs up here too.
    [string]$IdentityNamespace = 'identity',
    # 'high': every component replicated, every object on two servers, the databases backed up here.
    # 'standard': one of each, one copy, no backups. Set it once, as Common.Availability.
    [ValidateSet('high', 'standard')]
    [string]$Availability = 'high',

    # Namespaces whose applications use object storage. Empty: the application's.
    [string[]]$ObjectStorageNamespaces = @(),
    # Namespaces whose PostgreSQL clusters back up. Empty: with high availability, the application's
    # and Keycloak's; otherwise none.
    [string[]]$BackupNamespaces = @(),

    # cert-manager ClusterIssuer from provision-ingress.ps1, which issues the store's HTTPS certificate.
    [ValidateNotNullOrEmpty()]
    [string]$CertificateIssuer = 'site-ca',

    [string]$ChartVersion = '4.51.0',
    # Per volume server. Every object is on two of the three.
    [string]$StorageSize = '20Gi',
    # Empty uses the cluster's default storage class.
    [string]$StorageClassName
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
. (Join-Path $repoRoot 'scripts/lib/cluster.ps1')
. (Join-Path $repoRoot 'scripts/lib/credentials.ps1')

if (-not $ObjectStorageNamespaces) { $ObjectStorageNamespaces = @($ApplicationNamespace) }
$highAvailability = $Availability -eq 'high'
if (-not $BackupNamespaces -and $highAvailability) { $BackupNamespaces = @($ApplicationNamespace, $IdentityNamespace) }

# Names fixed by the files in infra/azurelocal/object-store, and by the Recipe Pack's settings.
$Namespace = 'object-store'
$ConfigSecretName = 'object-store-s3-config'
$ObjectStorageSecretName = 'object-store-credentials'
$TlsSecretName = 'seaweedfs-s3-tls'
$JwtSigningSecretName = 'seaweedfs-jwt-signing-key'
$S3Service = 'seaweedfs-s3'
$S3Port = 8443
$BackupSecretName = 'backup-object-store'
$assetsDir = Join-Path $repoRoot 'infra/azurelocal/object-store'

# Reads a namespace's keys from its Secret, or generates them the first time. Labels the namespace
# so the network policy lets its clients in.
function Get-Keys([string]$TargetNamespace, [string]$SecretName, [string]$IdKey, [string]$SecretKey, [string]$ClientLabel) {
    Set-OmsNamespace $KubeContext $TargetNamespace @{ $ClientLabel = 'true' }
    $keys = Get-OmsSecretData $KubeContext $TargetNamespace $SecretName
    if (-not $keys[$IdKey] -or -not $keys[$SecretKey]) {
        Write-Host "    generated keys for $TargetNamespace/$SecretName" -ForegroundColor DarkGray
        return @{ $IdKey = (New-OmsAccessKey 20); $SecretKey = (New-OmsAccessKey 40) }
    }
    $keys
}

if (-not $PullRegistry) {
    $PullRegistry = Get-OmsPullRegistry $KubeContext $ApplicationNamespace $PullSecretName
    if (-not $PullRegistry) {
        throw "No pull secret '$PullSecretName' in '$ApplicationNamespace' to read the connected registry's address from. Run scripts/infra/azurelocal/connected-registry.ps1 first, or pass -PullRegistry."
    }
}
Copy-OmsPullSecret -KubeContext $KubeContext -Namespace $Namespace -SourceNamespace $ApplicationNamespace -SecretName $PullSecretName

# ------------------------------------------------------------------------------------------------
# The gateways' HTTPS certificate, from the site CA, for every name of their Service. cert-manager
# renews it; the gateways read the renewed files without a restart.
# ------------------------------------------------------------------------------------------------
Write-Host "==> HTTPS certificate for the object store from ClusterIssuer '$CertificateIssuer'" -ForegroundColor Cyan
if (-not (Test-OmsResource $KubeContext '' 'clusterissuer' $CertificateIssuer)) {
    throw "No ClusterIssuer '$CertificateIssuer'. Run scripts/infra/azurelocal/provision-ingress.ps1 first."
}
@{
    apiVersion = 'cert-manager.io/v1'
    kind       = 'Certificate'
    metadata   = @{ name = $TlsSecretName; namespace = $Namespace }
    spec       = @{
        secretName  = $TlsSecretName
        issuerRef   = @{ kind = 'ClusterIssuer'; name = $CertificateIssuer }
        dnsNames    = @($S3Service, "$S3Service.$Namespace", "$S3Service.$Namespace.svc", "$S3Service.$Namespace.svc.cluster.local")
        duration    = '2160h'
        renewBefore = '720h'
        privateKey  = @{ algorithm = 'ECDSA'; size = 256; rotationPolicy = 'Always' }
    }
} | ConvertTo-Json -Depth 5 | kubectl apply --context $KubeContext -f - | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Requesting certificate $Namespace/$TlsSecretName failed." }
Wait-OmsCertificate $KubeContext $Namespace $TlsSecretName
# Clients outside this namespace verify the store against the CA that issued its certificate.
$caPem = Get-OmsSecretValue -KubeContext $KubeContext -Namespace $Namespace -Name $TlsSecretName -Key 'ca.crt'
if (-not $caPem) { throw "Certificate $Namespace/$TlsSecretName has no ca.crt." }

# ------------------------------------------------------------------------------------------------
# Identities. Each namespace's keys live in a Secret there; the store gets every identity in its
# config Secret.
# ------------------------------------------------------------------------------------------------
Write-Host "==> Object storage identities for $($ObjectStorageNamespaces -join ', ')" -ForegroundColor Cyan
$identities = [Collections.Generic.List[object]]::new()
foreach ($appNamespace in $ObjectStorageNamespaces) {
    $keys = Get-Keys $appNamespace $ObjectStorageSecretName 'ACCESSKEYID' 'SECRETACCESSKEY' 'object-store/objects'
    Set-OmsSecret $KubeContext $appNamespace $ObjectStorageSecretName @{
        ACCESSKEYID     = $keys['ACCESSKEYID']
        SECRETACCESSKEY = $keys['SECRETACCESSKEY']
    }
    # Admin on its own buckets lets the application create them, and nothing else.
    $identities.Add([ordered]@{
            name        = "objects-$appNamespace"
            credentials = @(@{ accessKey = $keys['ACCESSKEYID']; secretKey = $keys['SECRETACCESSKEY'] })
            actions     = @("Admin:$appNamespace.*")
        })
}

if ($BackupNamespaces) { Write-Host "==> Backup identities for $($BackupNamespaces -join ', ')" -ForegroundColor Cyan }
foreach ($backupNamespace in $BackupNamespaces) {
    $bucket = "postgres-$backupNamespace"
    $keys = Get-Keys $backupNamespace $BackupSecretName 'ACCESS_KEY_ID' 'ACCESS_SECRET_KEY' 'object-store/backups'
    # ca.crt is what the databases verify the store's certificate against. With the cnpg.io/reload
    # label, the PostgreSQL clusters pick up changed keys without a restart.
    Set-OmsSecret $KubeContext $backupNamespace $BackupSecretName @{
        ACCESS_KEY_ID     = $keys['ACCESS_KEY_ID']
        ACCESS_SECRET_KEY = $keys['ACCESS_SECRET_KEY']
        BUCKET            = $bucket
        'ca.crt'          = $caPem
    } -Labels @{ 'cnpg.io/reload' = 'true' }
    $identities.Add([ordered]@{
            name        = $bucket
            credentials = @(@{ accessKey = $keys['ACCESS_KEY_ID']; secretKey = $keys['ACCESS_SECRET_KEY'] })
            actions     = @('Read', 'Write', 'List', 'Tagging') | ForEach-Object { "${_}:$bucket" }
        })
}
$keys = $null
# The chart restarts the S3 gateways when this Secret changes.
Set-OmsSecret $KubeContext $Namespace $ConfigSecretName @{
    seaweedfs_s3_config = (@{ identities = @($identities) } | ConvertTo-Json -Depth 10 -Compress)
}
$identities = $null

# The key the masters sign volume write tokens with: 32 random bytes, generated once and kept, since
# a new one invalidates the tokens in use. values.yaml gives it to the store from this Secret.
if (-not (Get-OmsSecretValue $KubeContext $Namespace $JwtSigningSecretName 'signing-key')) {
    $signingKey = [byte[]]::new(32)
    [Security.Cryptography.RandomNumberGenerator]::Fill($signingKey)
    Set-OmsSecret $KubeContext $Namespace $JwtSigningSecretName @{ 'signing-key' = [Convert]::ToBase64String($signingKey) }
    $signingKey = $null
    Write-Host "    generated the write token signing key in Secret '$Namespace/$JwtSigningSecretName'" -ForegroundColor DarkGray
}

# ------------------------------------------------------------------------------------------------
# SeaweedFS. The site values go in as a values document on stdin.
# ------------------------------------------------------------------------------------------------
Write-Host "==> Installing SeaweedFS (chart $ChartVersion) from $PullRegistry" -ForegroundColor Cyan
$storageClass = if ($StorageClassName) { $StorageClassName } else { $null }
$siteValues = @{
    global = @{ imageRegistry = $PullRegistry; imagePullSecrets = $PullSecretName }
    master = @{ data = @{ storageClass = $storageClass } }
    volume = @{
        dataDirs = @(@{ name = 'data1'; type = 'persistentVolumeClaim'; size = $StorageSize; storageClass = $storageClass; maxVolumes = 0 })
    }
    filer  = @{
        data = @{ storageClass = $storageClass }
    }
    s3     = @{ createBuckets = @($BackupNamespaces | ForEach-Object { @{ name = "postgres-$_" } }) }
}
if (-not $highAvailability) {
    # One of each component, and one copy of every object ('000').
    $siteValues.global.seaweedfs = @{ replicationPlacement = '000' }
    foreach ($component in 'master', 'volume', 'filer') { $siteValues[$component].replicas = 1 }
    $siteValues.s3.replicas = 1
}
$siteValues = $siteValues | ConvertTo-Json -Depth 10
$siteValues | helm upgrade --install seaweedfs seaweedfs --repo https://seaweedfs.github.io/seaweedfs/helm `
    --version $ChartVersion --namespace $Namespace --kube-context $KubeContext --wait --timeout 15m `
    --values (Join-Path $assetsDir 'values.yaml') --values -
if ($LASTEXITCODE -ne 0) { throw 'helm upgrade --install seaweedfs failed.' }

kubectl apply --context $KubeContext -f (Join-Path $assetsDir 'network-policy.yaml') | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Applying the object store network policy failed.' }
# A node drain or upgrade takes at most one pod of each component at a time.
kubectl apply --context $KubeContext -f (Join-Path $assetsDir 'pod-disruption-budgets.yaml') | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Applying the object store disruption budgets failed.' }

$endpoint = "https://$S3Service.$Namespace.svc.cluster.local:$S3Port"
Write-Host "`nObject store ready: $endpoint" -ForegroundColor Green
