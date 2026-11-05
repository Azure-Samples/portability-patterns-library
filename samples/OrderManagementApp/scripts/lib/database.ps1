# Shared by the deploy scripts of both targets: steps that run against the cluster after `rad deploy`.

. (Join-Path $PSScriptRoot 'secrets.ps1')

# Runs the database setup job (src/OrderManagement.DbSetup) to completion: it creates the schemas
# and each service's least-privilege database user, as the database administrator. It runs outside
# the Radius application because only it may hold administrator rights. $Environment holds plain
# values; $SecretEnvironment maps variable names to @{ Secret = ...; Key = ... } in the namespace.
#
# The job's definition is kept in the cluster as a suspended CronJob, which never runs on its own:
# Start-OmsDatabaseSetup runs it again from there, with nothing but the cluster, as
# scripts/infra/azurelocal/rotate-credentials.ps1 does to set a changed password.
function Invoke-OmsDatabaseSetup {
    param(
        [Parameter(Mandatory = $true)][string]$KubeContext,
        [Parameter(Mandatory = $true)][string]$Namespace,
        [Parameter(Mandatory = $true)][string]$Image,
        [string]$ServiceAccountName = '',
        [hashtable]$PodLabels = @{},
        [hashtable]$Environment = @{},
        [hashtable]$SecretEnvironment = @{},
        [string]$ImagePullSecretName = '',
        # Secret with the CA (key ca.crt) that issued the databases' certificates, so the job verifies
        # them, as the Recipe Pack does for the services: SqlClient reads SSL_CERT_FILE, PostgreSQL
        # clients PGSSLROOTCERT.
        [string]$CaSecretName = '',
        [int]$TimeoutSeconds = 900
    )

    $name = 'dbsetup'
    $env = @($Environment.GetEnumerator() | Sort-Object Name | ForEach-Object {
            @{ name = $_.Name; value = [string]$_.Value }
        }) + @($SecretEnvironment.GetEnumerator() | Sort-Object Name | ForEach-Object {
            @{ name = $_.Name; valueFrom = @{ secretKeyRef = @{ name = $_.Value.Secret; key = $_.Value.Key } } }
        })
    $container = [ordered]@{
        name            = $name
        image           = $Image
        env             = $env
        securityContext = @{
            allowPrivilegeEscalation = $false
            runAsNonRoot             = $true
            readOnlyRootFilesystem   = $true
            capabilities             = @{ drop = @('ALL') }
            seccompProfile           = @{ type = 'RuntimeDefault' }
        }
        # The only writable path, for the .NET runtime's temporary files.
        volumeMounts    = @(@{ name = 'tmp'; mountPath = '/tmp' })
    }
    $podSpec = [ordered]@{
        restartPolicy = 'Never'
        containers    = @($container)
        volumes       = @(@{ name = 'tmp'; emptyDir = @{} })
    }
    if ($CaSecretName) {
        $container.env += @{ name = 'SSL_CERT_FILE'; value = '/etc/database-ca/ca.crt' }
        $container.env += @{ name = 'PGSSLROOTCERT'; value = '/etc/database-ca/ca.crt' }
        $container.volumeMounts += @{ name = 'database-ca'; mountPath = '/etc/database-ca'; readOnly = $true }
        $podSpec.volumes += @{ name = 'database-ca'; secret = @{ secretName = $CaSecretName } }
    }
    if ($ServiceAccountName) { $podSpec.serviceAccountName = $ServiceAccountName }
    if ($ImagePullSecretName) { $podSpec.imagePullSecrets = @(@{ name = $ImagePullSecretName }) }
    $template = [ordered]@{
        apiVersion = 'batch/v1'
        kind       = 'CronJob'
        metadata   = @{ name = $name; namespace = $Namespace; labels = @{ 'app.kubernetes.io/name' = $name } }
        spec       = @{
            suspend     = $true
            schedule    = '0 0 1 1 *'
            jobTemplate = @{
                metadata = @{ labels = @{ 'app.kubernetes.io/name' = $name } }
                spec     = @{
                    backoffLimit            = 2
                    ttlSecondsAfterFinished = 86400
                    template                = @{
                        metadata = @{ labels = (@{ 'app.kubernetes.io/name' = $name } + $PodLabels) }
                        spec     = $podSpec
                    }
                }
            }
        }
    }
    $template | ConvertTo-Json -Depth 20 | kubectl apply --context $KubeContext -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Writing the database setup job failed.' }

    Start-OmsDatabaseSetup -KubeContext $KubeContext -Namespace $Namespace -TimeoutSeconds $TimeoutSeconds
}

# Runs the database setup job Invoke-OmsDatabaseSetup defined, with the values its Secrets hold now,
# and waits for it.
function Start-OmsDatabaseSetup {
    param(
        [Parameter(Mandatory = $true)][string]$KubeContext,
        [Parameter(Mandatory = $true)][string]$Namespace,
        [int]$TimeoutSeconds = 900
    )

    if (-not (kubectl get cronjob dbsetup --namespace $Namespace --context $KubeContext --ignore-not-found --output name)) {
        if ($LASTEXITCODE -ne 0) { throw "Reading the database setup job in '$Namespace' failed." }
        throw "No database setup job in '$Namespace'. Deploy the application first."
    }
    $name = 'dbsetup-' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Write-Host "==> Creating database schemas and each service's database user (job '$name')" -ForegroundColor Cyan
    kubectl create job $name --from=cronjob/dbsetup --namespace $Namespace --context $KubeContext | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Creating the database setup job failed.' }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        $status = kubectl get job $name --namespace $Namespace --context $KubeContext -o json | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) { throw "Reading the database setup job failed." }
        if ($status.status.succeeded -ge 1) { break }
        $failed = $status.status.conditions | Where-Object { $_.type -eq 'Failed' -and $_.status -eq 'True' }
        if ($failed -or (Get-Date) -gt $deadline) {
            kubectl logs "job/$name" --namespace $Namespace --context $KubeContext --tail=40 2>&1 | Write-Host
            throw "The database setup job did not complete: $(if ($failed) { $failed.message } else { "timed out after $TimeoutSeconds seconds" })"
        }
        Start-Sleep -Seconds 5
    }
    Write-Host '    databases ready' -ForegroundColor DarkGray
}

# Applies the sample's network policies: deny all traffic into the application's pods except what
# each service needs. $IngressNamespace is where the ingress controller runs; $MonitoringNamespace,
# when given, may scrape the backing services' metrics.
function Set-OmsNetworkPolicy {
    param(
        [Parameter(Mandatory = $true)][string]$KubeContext,
        [Parameter(Mandatory = $true)][string]$Namespace,
        [Parameter(Mandatory = $true)][string]$IngressNamespace,
        [string]$MonitoringNamespace = '',
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )

    Write-Host "==> Applying network policies to '$Namespace'" -ForegroundColor Cyan
    $manifest = (Get-Content $ManifestPath -Raw).
        Replace('${NAMESPACE}', $Namespace).
        Replace('${INGRESS_NAMESPACE}', $IngressNamespace).
        Replace('${MONITORING_NAMESPACE}', $(if ($MonitoringNamespace) { $MonitoringNamespace } else { 'kube-system' }))
    $manifest | kubectl apply --context $KubeContext -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Applying the network policies failed.' }
}

# Reads a Radius resource: its ID, and properties such as the host a database Recipe reported. With
# -AllowMissing, returns $null when Radius reports that the resource doesn't exist; any other
# failure throws.
function Get-OmsRadiusResource {
    param(
        [Parameter(Mandatory = $true)][string]$Type,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Group,
        [switch]$AllowMissing
    )

    $output = rad resource show $Type $Name --workspace $Workspace --group $Group --output json 2>&1
    $text = @($output | ForEach-Object { "$_" }) -join ' '
    if ($LASTEXITCODE -ne 0) {
        if ($AllowMissing -and $text -match '\bNotFound\b|was not found') { return $null }
        throw "Reading Radius resource $Type/$Name failed: $text"
    }
    @($output | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] }) -join "`n" | ConvertFrom-Json
}