# Shared by the Azure Local scripts that generate, apply and rotate the site's own credentials: the
# database passwords and the object store's S3 keys. They are generated on site and kept only in the
# cluster, so setting them up and changing them needs no link to Azure.

. (Join-Path $PSScriptRoot 'secrets.ps1')

# The Secret with the database passwords, and its keys. The deploy script creates it once; only the
# database setup job and the database servers' own Secrets get these values, and each service gets
# only its own password, in <service>-db-credentials.
$script:OmsDatabasePasswordKeys = @('sql-admin-password', 'postgres-admin-password', 'sql-api-password', 'sql-processor-password', 'postgres-inventory-password')

# Meets SQL Server's and PostgreSQL's complexity rules, and has no character that needs quoting in a
# connection string.
function New-OmsPassword {
    $bytes = [byte[]]::new(24)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    'Oms1-' + [Convert]::ToBase64String($bytes).Replace('+', 'A').Replace('/', 'b').TrimEnd('=')
}

# Letters and digits only, which every S3 client accepts.
function New-OmsAccessKey([int]$Length) {
    $buffer = [byte[]]::new($Length)
    [Security.Cryptography.RandomNumberGenerator]::Fill($buffer)
    -join ($buffer | ForEach-Object { 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'[$_ % 62] })
}

# Reads the database passwords, generating the ones that are missing. Existing values are kept, so
# running this again changes nothing.
function Initialize-OmsDatabasePasswords([string]$KubeContext, [string]$Namespace, [string]$SecretName) {
    $passwords = Get-OmsSecretData $KubeContext $Namespace $SecretName
    $missing = @($script:OmsDatabasePasswordKeys | Where-Object { -not $passwords[$_] })
    if ($missing) {
        foreach ($key in $missing) { $passwords[$key] = New-OmsPassword }
        Set-OmsSecret $KubeContext $Namespace $SecretName $passwords
        Write-Host "    generated $($missing -join ', ') in Secret '$Namespace/$SecretName'" -ForegroundColor DarkGray
    }
    $passwords
}

# SQL Server reads its administrator password only when it first creates its data, so a changed one
# is set in the running server, signing in with the one it has, which $AppliedSecretName records.
# The password goes over stdin, never on a command line.
function Set-OmsSqlAdminPassword {
    param(
        [Parameter(Mandatory = $true)][string]$KubeContext,
        [Parameter(Mandatory = $true)][string]$Namespace,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$AppliedSecretName
    )

    # Passwords are case-sensitive, hence -cne.
    $previous = Get-OmsSecretValue $KubeContext $Namespace $AppliedSecretName 'sql-admin-password'
    if ($previous -and $Password -cne $previous) {
        $podNames = kubectl get pods --context $KubeContext --namespace $Namespace --selector 'app=mssql' `
            --field-selector status.phase=Running --output jsonpath='{.items[*].metadata.name}'
        if ($LASTEXITCODE -ne 0) { throw 'Listing the SQL Server pods failed.' }
        $pods = @($podNames -split ' ' | Where-Object { $_ })
        if (-not $pods) { throw 'The SQL administrator password changed, but no SQL Server is running to change it in. Start SQL Server, then run this again.' }
        foreach ($pod in $pods) {
            Write-Host "==> Changing the SQL administrator password in $pod" -ForegroundColor Cyan
            "$previous`nALTER LOGIN sa WITH PASSWORD = N'$($Password.Replace("'", "''"))';`nGO" |
                kubectl exec --stdin $pod --container mssql --context $KubeContext --namespace $Namespace -- `
                    bash -c 'IFS= read -r P; export SQLCMDPASSWORD="${P%$''\r''}"; /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -b' |
                Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Changing the SQL administrator password in $pod failed." }
        }
    }
    Set-OmsSecret $KubeContext $Namespace $AppliedSecretName @{ 'sql-admin-password' = $Password }
}

# Restarts the Deployments whose containers read the Secret, and waits for them: a container reads
# environment variables from a Secret only when it starts.
function Restart-OmsSecretConsumers([string]$KubeContext, [string]$Namespace, [string]$SecretName, [int]$TimeoutSeconds = 600) {
    $deployments = kubectl get deployments --namespace $Namespace --context $KubeContext --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw "Listing the Deployments in '$Namespace' failed." }
    $consumers = @($deployments.items | Where-Object {
            $containers = @($_.spec.template.spec.containers) + @($_.spec.template.spec.initContainers | Where-Object { $_ })
            $containers | Where-Object {
                ($_.envFrom.secretRef.name -contains $SecretName) -or ($_.env.valueFrom.secretKeyRef.name -contains $SecretName)
            }
        } | ForEach-Object { $_.metadata.name })
    foreach ($name in $consumers) {
        Write-Host "==> Restarting $Namespace/$name for the new credentials in '$SecretName'" -ForegroundColor Cyan
        kubectl rollout restart "deployment/$name" --namespace $Namespace --context $KubeContext | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Restarting deployment '$Namespace/$name' failed." }
    }
    foreach ($name in $consumers) {
        kubectl rollout status "deployment/$name" --namespace $Namespace --context $KubeContext --timeout="${TimeoutSeconds}s" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Deployment '$Namespace/$name' did not roll out within $TimeoutSeconds seconds." }
    }
}

# The object store's identities are a JSON document (SeaweedFS's S3 config). An identity may have
# several keys, all valid at once, which is what lets a key change without downtime: add the new one,
# move the clients to it, then keep only it.
function Add-OmsS3Credential([string]$Config, [string]$Identity, [string]$AccessKey, [string]$SecretKey) {
    $document = $Config | ConvertFrom-Json -AsHashtable
    $entry = $document.identities | Where-Object { $_.name -eq $Identity }
    if (-not $entry) { throw "The object store has no identity '$Identity'. Run scripts/infra/azurelocal/provision-object-store.ps1 first." }
    if (-not ($entry.credentials | Where-Object { $_.accessKey -eq $AccessKey })) {
        $entry.credentials = @($entry.credentials) + @(@{ accessKey = $AccessKey; secretKey = $SecretKey })
    }
    $document | ConvertTo-Json -Depth 10 -Compress
}

function Select-OmsS3Credential([string]$Config, [string]$Identity, [string]$AccessKey) {
    $document = $Config | ConvertFrom-Json -AsHashtable
    $entry = $document.identities | Where-Object { $_.name -eq $Identity }
    if (-not $entry) { throw "The object store has no identity '$Identity'." }
    $kept = @($entry.credentials | Where-Object { $_.accessKey -eq $AccessKey })
    if (-not $kept) { throw "Identity '$Identity' has no key '$AccessKey' to keep." }
    $entry.credentials = $kept
    $document | ConvertTo-Json -Depth 10 -Compress
}

# The S3 gateways read their config when they start, not when the Secret changes.
function Restart-OmsObjectStoreGateways([string]$KubeContext, [string]$Namespace = 'object-store', [string]$Deployment = 'seaweedfs-s3', [int]$TimeoutSeconds = 600) {
    Write-Host '==> Restarting the S3 gateways for the new identities' -ForegroundColor Cyan
    kubectl rollout restart "deployment/$Deployment" --namespace $Namespace --context $KubeContext | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Restarting deployment '$Namespace/$Deployment' failed." }
    kubectl rollout status "deployment/$Deployment" --namespace $Namespace --context $KubeContext --timeout="${TimeoutSeconds}s" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "The S3 gateways did not roll out within $TimeoutSeconds seconds." }
}
