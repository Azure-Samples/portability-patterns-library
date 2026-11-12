#Requires -Version 7.3
<#
.SYNOPSIS
    Changes the Azure Local site's database passwords and object store keys, with nothing but the
    cluster: no link to Azure, no image build, no Radius deployment.

.DESCRIPTION
    The site's credentials are generated on site and kept only in the cluster (see the README's
    production list). This script changes one or more of them:

      sql-api-password, sql-processor-password, postgres-inventory-password
          A service's database password. Sets the new value in Secret oms-db-passwords, runs the
          database setup job again, which sets it in the database (ALTER LOGIN / ALTER ROLE), copies
          it into <service>-db-credentials and restarts the service. Until the service's new pods are
          up, its old ones can't open new database connections: expect a few failed requests.

      sql-admin-password
          SQL Server's administrator. Sets it in the running server (ALTER LOGIN sa), in
          oms-db-passwords and in the server's own Secret.

      postgres-admin-password
          PostgreSQL's administrator. Sets it in oms-db-passwords and in the server's own Secret,
          which the server applies itself, and waits until it works.

      object-store, backup-object-store
          The S3 keys of -Namespace's applications, or of its PostgreSQL backups. Adds a new key next
          to the old one, restarts the S3 gateways, moves the clients to the new key, then removes the
          old one and restarts the gateways again. The applications restart; the PostgreSQL clusters
          reload their keys without a restart, and the script checks they still archive.

    Nothing rotates on a schedule; run this when a credential should change. A run that stops part
    way can be run again.

.EXAMPLE
    ./scripts/infra/azurelocal/rotate-credentials.ps1 -KubeContext <context> -Credential sql-api-password

.EXAMPLE
    # Keycloak's database backups, in namespace identity.
    ./scripts/infra/azurelocal/rotate-credentials.ps1 -KubeContext <context> -Credential backup-object-store -Namespace identity
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$KubeContext,

    [Parameter(Mandatory = $true)]
    [ValidateSet('sql-api-password', 'sql-processor-password', 'postgres-inventory-password', 'sql-admin-password',
        'postgres-admin-password', 'object-store', 'backup-object-store')]
    [string[]]$Credential,

    # The application's namespace: the databases and their passwords are there.
    [string]$ApplicationNamespace = 'oms-azurelocal',
    # For the object store keys: the namespace whose keys change. Empty: the application's.
    [string]$Namespace,

    [string]$PasswordsSecretName = 'oms-db-passwords',
    [string]$AppliedAdminSecretName = 'oms-db-admin',
    [string]$ObjectStoreNamespace = 'object-store',
    [int]$TimeoutSeconds = 600
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
. (Join-Path $repoRoot 'scripts/lib/cluster.ps1')
. (Join-Path $repoRoot 'scripts/lib/database.ps1')
. (Join-Path $repoRoot 'scripts/lib/credentials.ps1')

if (-not $Namespace) { $Namespace = $ApplicationNamespace }

function Get-Json([string[]]$Arguments) {
    $output = kubectl @Arguments --context $KubeContext --output json
    if ($LASTEXITCODE -ne 0) { throw "kubectl $($Arguments -join ' ') failed." }
    $output | ConvertFrom-Json
}

# Changes one key of a Secret another component owns (a Recipe's), keeping its type, labels and owner.
# The object goes to kubectl on stdin.
function Set-SecretKey([string]$SecretNamespace, [string]$Name, [string]$Key, [string]$Value) {
    $secret = Get-Json @('get', 'secret', $Name, '--namespace', $SecretNamespace)
    $secret.data.$Key = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value))
    $secret | ConvertTo-Json -Depth 10 | kubectl replace --context $KubeContext -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Updating Secret '$SecretNamespace/$Name' failed." }
}

# The Secret a database server reads its administrator password from, as its Recipe wrote it.
function Get-ServerAdminSecret([string]$Engine) {
    if ($Engine -eq 'postgres' -and (Test-OmsResource $KubeContext '' 'crd' 'clusters.postgresql.cnpg.io')) {
        $clusters = @((Get-Json @('get', 'clusters.postgresql.cnpg.io', '--namespace', $ApplicationNamespace)).items)
        if ($clusters) { return $clusters[0].spec.bootstrap.initdb.secret.name }
    }
    foreach ($set in (Get-Json @('get', 'statefulsets', '--namespace', $ApplicationNamespace)).items) {
        $pod = $set.spec.template.spec
        if ($Engine -eq 'sql') {
            $reference = ($pod.containers.env | Where-Object { $_.name -eq 'MSSQL_SA_PASSWORD' }).valueFrom.secretKeyRef.name
            if ($reference) { return $reference }
        }
        elseif ($pod.containers.env | Where-Object { $_.name -eq 'POSTGRES_PASSWORD_FILE' }) {
            return ($pod.volumes | Where-Object { $_.name -eq 'admin' }).secret.secretName
        }
    }
    throw "No $Engine server in '$ApplicationNamespace'."
}

# Whether PostgreSQL accepts the administrator credentials in the server's Secret, signing in from
# inside a server pod. The password goes over stdin.
function Test-PostgresAdmin([string]$AdminSecretName) {
    $admin = Get-OmsSecretData $KubeContext $ApplicationNamespace $AdminSecretName
    $pod = kubectl get pods --namespace $ApplicationNamespace --context $KubeContext --selector 'app=postgres' `
        --field-selector status.phase=Running --output 'jsonpath={.items[0].metadata.name}'
    if ($LASTEXITCODE -ne 0 -or -not $pod) { throw "No running PostgreSQL server in '$ApplicationNamespace'." }
    $admin['password'] | kubectl exec --stdin $pod --container postgres --namespace $ApplicationNamespace --context $KubeContext -- `
        sh -c 'IFS= read -r P; PGPASSWORD="$(printf %s "$P" | tr -d "\r")" psql "host=localhost dbname=postgres user=$1 sslmode=require" -tAc "select 1"' _ $admin['username'] 2>&1 |
        Out-Null
    $LASTEXITCODE -eq 0
}

# Has every PostgreSQL cluster in the namespace that backs up archive a new write-ahead log segment.
# Throws if one can't, which with the old key gone means it is still using it.
function Assert-PostgresArchiving([string]$ClusterNamespace) {
    if (-not (Test-OmsResource $KubeContext '' 'crd' 'clusters.postgresql.cnpg.io')) { return }
    $clusters = @((Get-Json @('get', 'clusters.postgresql.cnpg.io', '--namespace', $ClusterNamespace)).items | Where-Object { $_.spec.plugins })
    foreach ($cluster in $clusters) {
        $name = $cluster.metadata.name
        $before = $cluster.status
        Write-Host "==> Checking that $ClusterNamespace/$name archives with the new key" -ForegroundColor Cyan
        # Separate transactions: the first writes to the log, so the switch closes a segment with
        # something in it.
        kubectl exec $cluster.status.currentPrimary --container postgres --namespace $ClusterNamespace --context $KubeContext -- `
            psql -v ON_ERROR_STOP=1 -tA -c 'select txid_current()' -c 'select pg_switch_wal()' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Switching the write-ahead log on $ClusterNamespace/$name failed." }
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ($true) {
            $status = (Get-Json @('get', 'clusters.postgresql.cnpg.io', $name, '--namespace', $ClusterNamespace)).status
            if ($status.lastArchivedWALTime -ne $before.lastArchivedWALTime) { break }
            if ($status.lastFailedArchiveTime -ne $before.lastFailedArchiveTime -or (Get-Date) -gt $deadline) {
                throw "$ClusterNamespace/$name could not archive with the new key. PostgreSQL keeps the log and retries; restart the cluster (kubectl cnpg restart $name -n $ClusterNamespace) so it reads the new key."
            }
            Start-Sleep -Seconds 5
        }
    }
}

$services = @{
    'sql-api-password'            = @{ Service = 'api'; Key = 'SQL_PASSWORD' }
    'sql-processor-password'      = @{ Service = 'processor'; Key = 'SQL_PASSWORD' }
    'postgres-inventory-password' = @{ Service = 'inventory'; Key = 'POSTGRES_PASSWORD' }
}

# ------------------------------------------------------------------------------------------------
# Database passwords
# ------------------------------------------------------------------------------------------------
$databaseCredentials = @($Credential | Where-Object { $_ -like '*-password' })
if ($databaseCredentials) {
    $passwords = Get-OmsSecretData $KubeContext $ApplicationNamespace $PasswordsSecretName
    if (-not $passwords.Count) { throw "No Secret '$ApplicationNamespace/$PasswordsSecretName'. Deploy the application first." }

    foreach ($name in $databaseCredentials) { $passwords[$name] = New-OmsPassword }
    Set-OmsSecret $KubeContext $ApplicationNamespace $PasswordsSecretName $passwords
    Write-Host "==> New values for $($databaseCredentials -join ', ') in Secret '$PasswordsSecretName'" -ForegroundColor Cyan

    if ($databaseCredentials -contains 'sql-admin-password') {
        Set-OmsSqlAdminPassword -KubeContext $KubeContext -Namespace $ApplicationNamespace `
            -Password $passwords['sql-admin-password'] -AppliedSecretName $AppliedAdminSecretName
        Set-SecretKey $ApplicationNamespace (Get-ServerAdminSecret 'sql') 'password' $passwords['sql-admin-password']
    }

    if ($databaseCredentials -contains 'postgres-admin-password') {
        $adminSecret = Get-ServerAdminSecret 'postgres'
        Set-SecretKey $ApplicationNamespace $adminSecret 'password' $passwords['postgres-admin-password']
        # The operator, or the standard server's sidecar once the kubelet has updated the mounted
        # Secret, sets it in the database.
        Write-Host '==> Waiting for PostgreSQL to apply the administrator password' -ForegroundColor Cyan
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while (-not (Test-PostgresAdmin $adminSecret)) {
            if ((Get-Date) -gt $deadline) { throw "PostgreSQL did not apply the new administrator password within $TimeoutSeconds seconds." }
            Start-Sleep -Seconds 10
        }
    }

    # The setup job signs in as the administrators and sets every service's password from the Secret.
    $changedServices = @($databaseCredentials | Where-Object { $services[$_] })
    if ($changedServices) {
        Start-OmsDatabaseSetup -KubeContext $KubeContext -Namespace $ApplicationNamespace -TimeoutSeconds $TimeoutSeconds
        foreach ($name in $changedServices) {
            $secretName = "$($services[$name].Service)-db-credentials"
            Set-OmsSecret $KubeContext $ApplicationNamespace $secretName @{ $services[$name].Key = $passwords[$name] }
            Restart-OmsSecretConsumers $KubeContext $ApplicationNamespace $secretName $TimeoutSeconds
        }
    }
    $passwords = $null
}

# ------------------------------------------------------------------------------------------------
# Object store keys
# ------------------------------------------------------------------------------------------------
foreach ($name in @($Credential | Where-Object { $_ -notlike '*-password' })) {
    $backup = $name -eq 'backup-object-store'
    $secretName = if ($backup) { 'backup-object-store' } else { 'object-store-credentials' }
    $idKey, $secretKey = if ($backup) { 'ACCESS_KEY_ID', 'ACCESS_SECRET_KEY' } else { 'ACCESSKEYID', 'SECRETACCESSKEY' }
    $identity = if ($backup) { "postgres-$Namespace" } else { "objects-$Namespace" }
    $labels = if ($backup) { @{ 'cnpg.io/reload' = 'true' } } else { @{} }

    $keys = Get-OmsSecretData $KubeContext $Namespace $secretName
    if (-not $keys[$idKey]) { throw "No Secret '$Namespace/$secretName'. Run scripts/infra/azurelocal/provision-object-store.ps1 first." }
    $keys[$idKey] = New-OmsAccessKey 20
    $keys[$secretKey] = New-OmsAccessKey 40

    Write-Host "==> Adding a new key for $identity next to the old one" -ForegroundColor Cyan
    $config = Get-OmsSecretValue $KubeContext $ObjectStoreNamespace 'object-store-s3-config' 'seaweedfs_s3_config'
    $config = Add-OmsS3Credential $config $identity $keys[$idKey] $keys[$secretKey]
    Set-OmsSecret $KubeContext $ObjectStoreNamespace 'object-store-s3-config' @{ seaweedfs_s3_config = $config }
    Restart-OmsObjectStoreGateways $KubeContext $ObjectStoreNamespace -TimeoutSeconds $TimeoutSeconds

    Set-OmsSecret $KubeContext $Namespace $secretName $keys -Labels $labels
    if (-not $backup) { Restart-OmsSecretConsumers $KubeContext $Namespace $secretName $TimeoutSeconds }

    # Every other key goes, including one a stopped earlier run added.
    Write-Host "==> Removing the old key for $identity" -ForegroundColor Cyan
    $config = Select-OmsS3Credential $config $identity $keys[$idKey]
    Set-OmsSecret $KubeContext $ObjectStoreNamespace 'object-store-s3-config' @{ seaweedfs_s3_config = $config }
    Restart-OmsObjectStoreGateways $KubeContext $ObjectStoreNamespace -TimeoutSeconds $TimeoutSeconds
    if ($backup) { Assert-PostgresArchiving $Namespace }
    $keys = $null; $config = $null
}

Write-Host "`nChanged: $($Credential -join ', ')." -ForegroundColor Green
