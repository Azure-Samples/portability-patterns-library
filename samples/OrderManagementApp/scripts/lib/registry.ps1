# Connected registry inputs and readiness checks shared by setup and application deployment.

function Get-OmsConnectedRegistry {
    param(
        [string]$KubeContext,
        [string]$Namespace,
        [string]$PullRegistry,
        [string]$ImagePullSecretName,
        [string]$RegistryCaConfigMapName
    )

    if (-not $PullRegistry) { $PullRegistry = Get-OmsPullRegistry $KubeContext $Namespace $ImagePullSecretName }
    $encoded = kubectl get secret $ImagePullSecretName --context $KubeContext --namespace $Namespace `
        --ignore-not-found --output 'jsonpath={.data.\.dockerconfigjson}'
    if ($LASTEXITCODE -ne 0 -or -not $PullRegistry -or [string]::IsNullOrWhiteSpace($encoded)) {
        throw "Cannot read pull secret '$Namespace/$ImagePullSecretName'. Run the Registry setup step."
    }
    $auth = ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | ConvertFrom-Json).auths.$PullRegistry
    if (-not $auth.username -or -not $auth.password) {
        throw "Pull secret '$ImagePullSecretName' holds no credentials for '$PullRegistry'."
    }
    $ca = (kubectl get configmap $RegistryCaConfigMapName --context $KubeContext --namespace $Namespace `
        --ignore-not-found --output 'jsonpath={.data.ca\.crt}') -join "`n"
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($ca)) {
        throw "Cannot read CA ConfigMap '$Namespace/$RegistryCaConfigMapName'. Run the Registry setup step."
    }
    @{ Host = $PullRegistry; Auth = $auth; Ca = $ca }
}

function Wait-OmsRegistrySync {
    param(
        [string]$KubeContext,
        [hashtable]$Registry,
        [string[]]$Artifacts,
        [hashtable]$ExpectedDigests = @{},
        [int]$TimeoutMinutes = 20
    )

    $services = kubectl get services --all-namespaces --context $KubeContext -o json
    if ($LASTEXITCODE -ne 0) { throw 'Could not list Services for the connected registry.' }
    $service = ($services | ConvertFrom-Json).items |
        Where-Object { $_.spec.clusterIP -eq $Registry.Host } | Select-Object -First 1
    if (-not $service) { throw "No Service with ClusterIP $($Registry.Host). Run the Registry setup step." }
    $port = ($service.spec.ports | Select-Object -First 1).port
    $localPort = Get-Random -Minimum 20000 -Maximum 30000
    $forward = $null
    try {
        $startArguments = @{
            FilePath = 'kubectl'
            PassThru = $true
            ArgumentList = @('--context', $KubeContext, '--namespace', $service.metadata.namespace,
                'port-forward', "service/$($service.metadata.name)", "${localPort}:$port")
        }
        if ($IsWindows) { $startArguments.WindowStyle = 'Hidden' }
        $forward = Start-Process @startArguments
        Start-Sleep -Seconds 3
        $forward.Refresh()
        if ($forward.HasExited) { throw 'The connected registry port-forward exited before becoming ready.' }

        $basicAuth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($Registry.Auth.username):$($Registry.Auth.password)"))
        $accept = 'application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'
        $pending = [Collections.Generic.List[string]]::new([string[]]$Artifacts)
        $errors = @{}
        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
        Write-Host "==> Waiting for connected registry artifacts ($($Registry.Host))" -ForegroundColor Cyan
        while ($pending.Count -gt 0) {
            foreach ($artifact in @($pending)) {
                $repository, $tag = $artifact -split ':', 2
                try {
                    $tokenUri = "https://localhost:$localPort/acr/oauth2/token?service=localhost:$localPort&scope=repository:${repository}:pull"
                    $token = (Invoke-RestMethod -Uri $tokenUri -Headers @{ Authorization = "Basic $basicAuth" } `
                        -SkipCertificateCheck -TimeoutSec 15).access_token
                    # The certificate names the ClusterIP, not this local port-forward.
                    $response = Invoke-WebRequest -Uri "https://localhost:$localPort/v2/$repository/manifests/$tag" -Method Head `
                        -Headers @{ Authorization = "Bearer $token"; Accept = $accept } -SkipCertificateCheck -TimeoutSec 15
                    $digest = $response.Headers['Docker-Content-Digest'] | Select-Object -First 1
                    if ($digest -and (-not $ExpectedDigests[$artifact] -or $digest -eq $ExpectedDigests[$artifact])) {
                        [void]$pending.Remove($artifact)
                        $errors.Remove($artifact)
                    }
                    else { $errors[$artifact] = 'The expected manifest digest is not present yet.' }
                }
                catch { $errors[$artifact] = $_.Exception.Message }
            }
            if ($pending.Count -eq 0) { break }
            if ((Get-Date) -gt $deadline) {
                foreach ($artifact in $pending) { Write-Warning "${artifact}: $($errors[$artifact])" }
                throw "Connected registry is still missing after $TimeoutMinutes minutes: $($pending -join ', ')"
            }
            $forward.Refresh()
            if ($forward.HasExited) { throw 'The connected registry port-forward exited while waiting for artifacts.' }
            Write-Host "    waiting on $($pending.Count): $($pending -join ', ')" -ForegroundColor DarkGray
            Start-Sleep -Seconds 20
        }
    }
    finally {
        if ($forward -and -not $forward.HasExited) { Stop-Process -Id $forward.Id -Force }
    }
}
