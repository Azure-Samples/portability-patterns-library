# Shared by the deploy scripts of both targets: steps that run against the cluster after `rad deploy`.

. (Join-Path $PSScriptRoot 'secrets.ps1')

# Runs the database setup job (src/OrderManagement.DbSetup) to completion: it creates the schemas
# and each service's least-privilege database user, as the database administrator. It runs outside
# the Radius application because only it may hold administrator rights. $Environment holds plain
# values; $SecretEnvironment maps variable names to @{ Secret = ...; Key = ... } in the namespace.
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
        # them. PostgreSQL clients read PGSSLROOTCERT.
        [string]$CaSecretName = '',
        [int]$TimeoutSeconds = 900
    )

    $name = 'dbsetup'
    kubectl delete job $name --namespace $Namespace --context $KubeContext --ignore-not-found --wait=true | Out-Null

    $env = @($Environment.GetEnumerator() | Sort-Object Name | ForEach-Object {
            @{ name = $_.Name; value = [string]$_.Value }
        }) + @($SecretEnvironment.GetEnumerator() | Sort-Object Name | ForEach-Object {
            @{ name = $_.Name; valueFrom = @{ secretKeyRef = @{ name = $_.Value.Secret; key = $_.Value.Key } } }
        })
    $container = [ordered]@{
        name            = $name
        image           = $Image
        env             = $env
        securityContext = @{ allowPrivilegeEscalation = $false; runAsNonRoot = $true }
    }
    $podSpec = [ordered]@{
        restartPolicy = 'Never'
        containers    = @($container)
    }
    if ($CaSecretName) {
        $container.env += @{ name = 'PGSSLROOTCERT'; value = '/etc/database-ca/ca.crt' }
        $container.volumeMounts = @(@{ name = 'database-ca'; mountPath = '/etc/database-ca'; readOnly = $true })
        $podSpec.volumes = @(@{ name = 'database-ca'; secret = @{ secretName = $CaSecretName } })
    }
    if ($ServiceAccountName) { $podSpec.serviceAccountName = $ServiceAccountName }
    if ($ImagePullSecretName) { $podSpec.imagePullSecrets = @(@{ name = $ImagePullSecretName }) }
    $job = [ordered]@{
        apiVersion = 'batch/v1'
        kind       = 'Job'
        metadata   = @{ name = $name; namespace = $Namespace; labels = @{ 'app.kubernetes.io/name' = $name } }
        spec       = @{
            backoffLimit            = 2
            ttlSecondsAfterFinished = 86400
            template                = @{
                metadata = @{ labels = (@{ 'app.kubernetes.io/name' = $name } + $PodLabels) }
                spec     = $podSpec
            }
        }
    }

    Write-Host "==> Creating database schemas and each service's database user (job '$name')" -ForegroundColor Cyan
    $job | ConvertTo-Json -Depth 20 | kubectl apply --context $KubeContext -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Creating the database setup job failed.' }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        $status = kubectl get job $name --namespace $Namespace --context $KubeContext -o json | ConvertFrom-Json
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

# Reads a Radius resource's properties, for example the host a database Recipe reported.
function Get-OmsRadiusResourceProperties {
    param(
        [Parameter(Mandatory = $true)][string]$Type,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Group
    )

    $resource = rad resource show $Type $Name --workspace $Workspace --group $Group --output json 2>$null | ConvertFrom-Json
    if (-not $resource) { throw "Radius resource $Type/$Name not found." }
    return $resource.properties
}
