<#
.SYNOPSIS
    Read-only health check of the Azure Local (AKS Arc) deployment, layer by layer.

.DESCRIPTION
    Collects, in one run, the checks that are otherwise done by hand when something is slow or
    broken. Nothing is created, changed or restarted; every finding comes with the script or
    switch that fixes it.

      1. Cluster     ARM provisioning state, node pool, Kubernetes nodes
      2. Bootstrap   (-IncludeNodeBootstrap) SSH into node VMs that have not joined yet and report
                     how far their first-boot image import has got
      3. Registry    connected registry state, extension pods, and whether the artifacts this
                     deployment pulls are actually present in the cluster
      4. Radius      that the CA mounted into the control plane is well formed and matches the CA
                     that signs the connected registry's certificate
      5. Identity    Keycloak rollout and that the realm answers on the node port
      6. App         pod status and recent warning events in the application namespace

    Secrets are only ever used in memory (registry token) and are never printed.

.PARAMETER IncludeNodeBootstrap
    Also SSH into node VMs on the AKS logical network to read their bootstrap progress. Useful
    while 'az aksarc create' is still running and nodes have not joined. Uses the key that
    'az aksarc create --generate-ssh-keys' wrote to ~/.ssh/id_rsa.

.EXAMPLE
    ./scripts/azurelocal/diagnose.ps1

.EXAMPLE
    # While the cluster is still being created.
    ./scripts/azurelocal/diagnose.ps1 -IncludeNodeBootstrap
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup = 'bcd-azurelocal',
    [string]$ClusterName = 'bcd-aksarc',
    [string]$KubeContext = 'bcd-aksarc',

    [string]$RegistryName = '<acr-name>',
    [string]$ConnectedRegistryName = 'bcdazlocalcr',
    [string]$ExtensionName = 'bcd-connected-registry',
    [string]$PullRegistry = '10.96.0.50',
    [string]$ImagePullSecretName = 'azurelocal-registry',
    [string]$RadiusVersion = '0.60',
    [string]$ImageTag = 'latest',

    [string]$Namespace = 'oms-azurelocal',
    [string]$IdentityNamespace = 'identity',
    [string]$KeycloakRealm = 'oms',
    [int]$KeycloakNodePort = 30443,

    [switch]$IncludeNodeBootstrap,
    # Node addresses come from the AKS logical network pool (provision-infra.ps1 defaults).
    [string]$NodeAddressPrefix = '192.168.44.',
    [int]$NodeAddressStart = 121,
    [int]$NodeAddressEnd = 180,
    [string]$NodeSshUser = 'clouduser'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Push-Location $repoRoot

$script:failures = 0
$script:warnings = 0
$portForward = $null

function Write-Check {
    param(
        [ValidateSet('PASS', 'WARN', 'FAIL', 'INFO')][string]$Status,
        [string]$What,
        [string]$Detail = ''
    )

    $color = @{ PASS = 'Green'; WARN = 'Yellow'; FAIL = 'Red'; INFO = 'DarkGray' }[$Status]
    if ($Status -eq 'FAIL') { $script:failures++ }
    if ($Status -eq 'WARN') { $script:warnings++ }
    Write-Host ("  [{0}] {1}" -f $Status, $What) -ForegroundColor $color -NoNewline
    if ($Detail) { Write-Host " - $Detail" -ForegroundColor DarkGray } else { Write-Host '' }
}

# Native commands that are allowed to fail; returns trimmed stdout or $null.
function Invoke-Probe {
    param([Parameter(Mandatory = $true)][scriptblock]$Command)

    $ErrorActionPreference = 'Continue'
    $output = & $Command 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $text = ($output | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text
}

# PowerShell cannot bind a string to X509Certificate2.CreateFromPem(ReadOnlySpan<char>).
function ConvertFrom-PemCertificate {
    param([string]$Pem)

    $base64 = ($Pem -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '-----' }) -join ''
    return [System.Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($base64))
}

function Test-TcpPort {
    param([string]$Address, [int]$Port, [int]$TimeoutMs = 700)

    $client = [System.Net.Sockets.TcpClient]::new()
    try { return $client.ConnectAsync($Address, $Port).Wait($TimeoutMs) -and $client.Connected }
    catch { return $false }
    finally { $client.Dispose() }
}

try {
    # ------------------------------------------------------------------------------------------
    Write-Host "`n==> 1. Cluster" -ForegroundColor Cyan
    # ------------------------------------------------------------------------------------------
    $clusterState = Invoke-Probe { az aksarc show -g $ResourceGroup -n $ClusterName --query properties.provisioningState -o tsv }
    switch ($clusterState) {
        'Succeeded' { Write-Check PASS "AKS Arc '$ClusterName'" $clusterState }
        $null { Write-Check FAIL "AKS Arc '$ClusterName'" 'not found or az not signed in; run scripts/azurelocal/provision-infra.ps1' }
        default { Write-Check WARN "AKS Arc '$ClusterName'" "$clusterState (re-run with -IncludeNodeBootstrap while it is creating)" }
    }

    $pools = Invoke-Probe { az aksarc nodepool list -g $ResourceGroup --cluster-name $ClusterName --query "[].{n:name, c:count, s:status.currentState, e:status.errorMessage}" -o json }
    foreach ($pool in @(if ($pools) { $pools | ConvertFrom-Json })) {
        if ($pool.e) { Write-Check FAIL "node pool '$($pool.n)'" $pool.e }
        else { Write-Check INFO "node pool '$($pool.n)'" "count $($pool.c), state $(if ($pool.s) { $pool.s } else { 'Ready' })" }
    }

    # The admin kubeconfig is only issued once creation succeeds, so a missing context is expected
    # while the cluster is still being created.
    $nodesJson = Invoke-Probe { kubectl get nodes --context $KubeContext --request-timeout=20s -o json }
    $joinedAddresses = @()
    if (-not $nodesJson) {
        Write-Check WARN "kubectl context '$KubeContext'" 'API unreachable or context missing; provision-infra.ps1 fetches it when creation completes'
    }
    else {
        foreach ($node in ($nodesJson | ConvertFrom-Json).items) {
            $ready = ($node.status.conditions | Where-Object type -eq 'Ready').status
            $address = ($node.status.addresses | Where-Object type -eq 'InternalIP').address
            $joinedAddresses += $address
            $role = if ($node.metadata.labels.PSObject.Properties.Name -contains 'node-role.kubernetes.io/control-plane') { 'control-plane' } else { 'worker' }
            if ($ready -eq 'True') { Write-Check PASS "node $($node.metadata.name)" "$role, $address" }
            else { Write-Check FAIL "node $($node.metadata.name)" "$role, $address, Ready=$ready" }
        }
    }

    # ------------------------------------------------------------------------------------------
    if ($IncludeNodeBootstrap) {
        Write-Host "`n==> 2. Node bootstrap (SSH)" -ForegroundColor Cyan
        # ------------------------------------------------------------------------------------------
        $sshKey = Join-Path $HOME '.ssh/id_rsa'
        if (-not (Test-Path $sshKey)) {
            Write-Check WARN 'SSH key' "no $sshKey; 'az aksarc create --generate-ssh-keys' writes it"
        }
        else {
            $candidates = $NodeAddressStart..$NodeAddressEnd | ForEach-Object { "$NodeAddressPrefix$_" } |
                Where-Object { Test-TcpPort -Address $_ -Port 22 }
            if (-not $candidates) { Write-Check WARN 'node VMs' "none answer on SSH in $NodeAddressPrefix$NodeAddressStart-$NodeAddressEnd yet" }

            # The first-boot script imports every bundled image from local disk before kubelet starts;
            # on nested virtualization that import is the slow part of node creation.
            $remote = 'echo "$(hostname)|$(sudo grep -c ''Importing container image'' /var/log/cloud-init-output.log 2>/dev/null)|$(ls /opt/container-images/extracted/*.tar 2>/dev/null | wc -l)|$(systemctl is-active kubelet)|$(sudo tail -n 1 /var/log/cloud-init-output.log 2>/dev/null | cut -c1-120)"'
            foreach ($address in $candidates) {
                $line = Invoke-Probe { ssh -i $sshKey -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o ConnectTimeout=8 -o BatchMode=yes -o LogLevel=ERROR "$NodeSshUser@$address" $remote }
                if (-not $line) { Write-Check WARN "VM at $address" 'SSH reachable but login failed'; continue }
                $hostName, $imported, $total, $kubelet, $last = $line -split '\|', 5
                $joined = $joinedAddresses -contains $address
                $status = if ($joined) { 'PASS' } elseif ($kubelet -eq 'active') { 'INFO' } else { 'WARN' }
                Write-Check $status "VM $hostName ($address)" "joined=$joined, images $imported/$total, kubelet $kubelet, last: $last"
            }
        }
    }

    if (-not $nodesJson) {
        Write-Host "`nCluster API not reachable; skipping in-cluster checks." -ForegroundColor Yellow
        return
    }

    # ------------------------------------------------------------------------------------------
    Write-Host "`n==> 3. Connected registry ($PullRegistry)" -ForegroundColor Cyan
    # ------------------------------------------------------------------------------------------
    $crState = Invoke-Probe { az acr connected-registry show -r $RegistryName -n $ConnectedRegistryName --query connectionState -o tsv }
    if ($crState -eq 'Online') { Write-Check PASS "connected registry '$ConnectedRegistryName'" 'Online' }
    else { Write-Check FAIL "connected registry '$ConnectedRegistryName'" "$crState; run scripts/azurelocal/connected-registry.ps1" }

    $extState = Invoke-Probe { az k8s-extension show -n $ExtensionName -c $ClusterName -g $ResourceGroup -t connectedClusters --query provisioningState -o tsv }
    if ($extState -eq 'Succeeded') { Write-Check PASS "Arc extension '$ExtensionName'" $extState }
    else { Write-Check FAIL "Arc extension '$ExtensionName'" "$extState; run scripts/azurelocal/connected-registry.ps1" }

    $services = kubectl get services --all-namespaces --context $KubeContext -o json | ConvertFrom-Json
    $registryService = $services.items | Where-Object { $_.spec.clusterIP -eq $PullRegistry } | Select-Object -First 1
    if (-not $registryService) {
        Write-Check FAIL "Service on $PullRegistry" 'missing; run scripts/azurelocal/connected-registry.ps1'
    }
    else {
        $crNamespace = $registryService.metadata.namespace
        $notRunning = kubectl get pods -n $crNamespace --context $KubeContext --no-headers 2>$null | Where-Object { $_ -notmatch '\sRunning\s' }
        if ($notRunning) { Write-Check WARN "pods in '$crNamespace'" (($notRunning | ForEach-Object { ($_ -split '\s+')[0..2] -join ' ' }) -join '; ') }
        else { Write-Check PASS "pods in '$crNamespace'" 'all Running' }

        # Same token flow kubelet uses: the connected registry rejects Basic auth on /v2.
        $encoded = Invoke-Probe { kubectl get secret $ImagePullSecretName -n $Namespace --context $KubeContext -o 'jsonpath={.data.\.dockerconfigjson}' }
        $auth = if ($encoded) { ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | ConvertFrom-Json).auths.$PullRegistry }
        if (-not $auth) {
            Write-Check FAIL "pull secret '$ImagePullSecretName'" "missing in '$Namespace'; run scripts/azurelocal/connected-registry.ps1"
        }
        else {
            $localPort = Get-Random -Minimum 20000 -Maximum 30000
            $portForward = Start-Process -FilePath kubectl -PassThru -WindowStyle Hidden -ArgumentList @(
                '--context', $KubeContext, '--namespace', $crNamespace, 'port-forward',
                "service/$($registryService.metadata.name)", "${localPort}:$(($registryService.spec.ports | Select-Object -First 1).port)")
            Start-Sleep -Seconds 3

            $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($auth.username):$($auth.password)"))
            $auth = $null
            $accept = 'application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'
            $artifacts = @("ucpd:$RadiusVersion", "applications-rp:$RadiusVersion", "dynamic-rp:$RadiusVersion",
                "oms/api:$ImageTag", "oms/processor:$ImageTag", 'keycloak/keycloak:26.8', 'mssql/server:2022-latest') +
            (Get-ChildItem deploy/recipes/azurelocal, deploy/recipes/kubernetes -Filter *.bicep | ForEach-Object { "oms/recipes/$($_.BaseName):$ImageTag" })

            $missing = foreach ($artifact in $artifacts) {
                $repository, $tag = $artifact -split ':', 2
                try {
                    # Certificate validation is skipped only because this probe goes through localhost.
                    $token = (Invoke-RestMethod "https://localhost:$localPort/acr/oauth2/token?service=localhost:$localPort&scope=repository:${repository}:pull" `
                            -Headers @{ Authorization = "Basic $basic" } -SkipCertificateCheck -TimeoutSec 15).access_token
                    $null = Invoke-WebRequest "https://localhost:$localPort/v2/$repository/manifests/$tag" -Method Head `
                        -Headers @{ Authorization = "Bearer $token"; Accept = $accept } -SkipCertificateCheck -TimeoutSec 15
                }
                catch { $artifact }
            }
            $basic = $null
            if ($missing) { Write-Check FAIL 'synced artifacts' "missing: $($missing -join ', ')" }
            else { Write-Check PASS 'synced artifacts' "$($artifacts.Count) present" }

            Stop-Process -Id $portForward.Id -Force -ErrorAction SilentlyContinue
            $portForward = $null
        }
    }

    # ------------------------------------------------------------------------------------------
    Write-Host "`n==> 4. Radius trust of the registry" -ForegroundColor Cyan
    # ------------------------------------------------------------------------------------------
    $mountedPem = Invoke-Probe { kubectl exec deploy/dynamic-rp -c dynamic-rp -n radius-system --context $KubeContext -- cat /tmp/sslcerts/ca.crt }
    $tlsSecret = $null
    $crSecrets = if ($registryService) { Invoke-Probe { kubectl get secrets -n $registryService.metadata.namespace --context $KubeContext -o json } }
    if ($crSecrets) {
        $tlsSecret = ($crSecrets | ConvertFrom-Json).items |
            Where-Object { $_.type -eq 'kubernetes.io/tls' -and $_.data.'ca.crt' -and $_.metadata.name -notlike '*webhook*' } |
            Select-Object -First 1
    }

    if (-not $mountedPem) {
        Write-Check FAIL 'CA mounted in Radius' 'none at /tmp/sslcerts/ca.crt; run deploy.ps1 -ReinstallRadius'
    }
    else {
        try {
            # A single-line PEM is the symptom of kubectl output joined with spaces.
            $mounted = ConvertFrom-PemCertificate -Pem $mountedPem
            if (($mountedPem -split "`n").Count -lt 3) { throw 'PEM is on one line' }
            if ($tlsSecret) {
                $registryCa = ConvertFrom-PemCertificate -Pem ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($tlsSecret.data.'ca.crt')))
                if ($mounted.Thumbprint -eq $registryCa.Thumbprint) { Write-Check PASS 'CA mounted in Radius' "matches $($registryCa.Subject)" }
                else { Write-Check FAIL 'CA mounted in Radius' "does not match $($registryCa.Subject); run connected-registry.ps1 then deploy.ps1 -ReinstallRadius" }
            }
            else { Write-Check INFO 'CA mounted in Radius' "$($mounted.Subject) (registry CA secret not found to compare)" }
        }
        catch {
            Write-Check FAIL 'CA mounted in Radius' "malformed ($($_.Exception.Message)); run deploy.ps1 -ReinstallRadius"
        }
    }
    Write-Check INFO 'note' 'Radius loads the CA at startup; deploy.ps1 -ReinstallRadius restarts it after a CA change'

    # ------------------------------------------------------------------------------------------
    Write-Host "`n==> 5. Identity (Keycloak)" -ForegroundColor Cyan
    # ------------------------------------------------------------------------------------------
    $available = Invoke-Probe { kubectl get deploy keycloak -n $IdentityNamespace --context $KubeContext -o 'jsonpath={.status.availableReplicas}' }
    if ($available -ge 1) { Write-Check PASS 'Keycloak deployment' "$available available" }
    else { Write-Check FAIL 'Keycloak deployment' 'not available; run scripts/azurelocal/keycloak.ps1 ... -AllowInClusterIssuer' }

    # Same derivation deploy.ps1 uses for the issuer the workers trust.
    $nodeIp = kubectl get nodes --context $KubeContext -o 'jsonpath={.items[0].status.addresses[?(@.type=="InternalIP")].address}'
    $issuer = "https://${nodeIp}:$KeycloakNodePort/realms/$KeycloakRealm"
    try {
        $discovery = Invoke-RestMethod "$issuer/.well-known/openid-configuration" -SkipCertificateCheck -TimeoutSec 15
        if ($discovery.issuer -eq $issuer) { Write-Check PASS 'realm discovery' $issuer }
        else { Write-Check WARN 'realm discovery' "issuer '$($discovery.issuer)' differs from '$issuer'; re-run keycloak.ps1 and deploy.ps1" }
    }
    catch { Write-Check FAIL 'realm discovery' "$issuer unreachable" }

    foreach ($secret in 'oms-ad-bind', 'oms-ad-ca') {
        if (Invoke-Probe { kubectl get secret $secret -n $IdentityNamespace --context $KubeContext -o name }) { Write-Check PASS "secret $IdentityNamespace/$secret" }
        else { Write-Check FAIL "secret $IdentityNamespace/$secret" 'missing; create it for your directory or run scripts/azurelocal/ad-setup.ps1' }
    }

    # ------------------------------------------------------------------------------------------
    Write-Host "`n==> 6. Application ($Namespace)" -ForegroundColor Cyan
    # ------------------------------------------------------------------------------------------
    $pods = Invoke-Probe { kubectl get pods -n $Namespace --context $KubeContext -o json }
    $podItems = if ($pods) { ($pods | ConvertFrom-Json).items } else { @() }
    if (-not $podItems) { Write-Check WARN 'pods' 'none; run scripts/azurelocal/deploy.ps1' }
    foreach ($pod in $podItems) {
        $container = $pod.status.containerStatuses | Select-Object -First 1
        $reason = if ($container.state.waiting) { $container.state.waiting.reason } else { $pod.status.phase }
        if ($container.ready) { Write-Check PASS "pod $($pod.metadata.name)" "restarts $($container.restartCount)" }
        else { Write-Check FAIL "pod $($pod.metadata.name)" $reason }
    }

    $events = kubectl get events -n $Namespace --context $KubeContext --field-selector type=Warning `
        --sort-by=.lastTimestamp -o 'custom-columns=WHEN:.lastTimestamp,OBJECT:.involvedObject.name,MSG:.message' --no-headers 2>$null |
        Select-Object -Last 5
    foreach ($event in $events) { Write-Check INFO 'warning event' ($event.Substring(0, [Math]::Min(180, $event.Length))) }

    Write-Host ''
    $summaryColor = if ($script:failures) { 'Red' } elseif ($script:warnings) { 'Yellow' } else { 'Green' }
    Write-Host ("==> {0} failure(s), {1} warning(s)" -f $script:failures, $script:warnings) -ForegroundColor $summaryColor
}
finally {
    if ($portForward) { Stop-Process -Id $portForward.Id -Force -ErrorAction SilentlyContinue }
    Pop-Location
}
