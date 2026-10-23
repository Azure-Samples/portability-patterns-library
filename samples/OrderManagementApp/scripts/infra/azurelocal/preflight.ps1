<#
.SYNOPSIS
    Checks that a site is ready for the Order Management sample on Azure Local, without changing anything.

.DESCRIPTION
    Run it before scripts/setup-platform.ps1 -Target AzureLocal, or after anything fails. It checks
    the assumptions listed under "Before you start" in the sample README:

      Tools        PowerShell 7, az, kubectl, helm, rad
      Azure        signed in, the subscription, resource providers, the Azure Local instance's
                   custom location and Arc resource bridge, the virtual switch
      Network      addresses for the control plane, node pool and load balancer fit together
      Directory    the domain controller resolves through the site DNS and answers on LDAPS
      Cluster      if it already exists: reachable, nodes ready, the AD Secrets Keycloak needs

    Values come from the AzureLocal section of scripts/settings.json, with the same defaults the
    setup scripts use. Each check prints PASS, WARN or FAIL; the script exits with 1 on any FAIL.

.EXAMPLE
    ./scripts/infra/azurelocal/preflight.ps1
#>
[CmdletBinding()]
param(
    [string]$SettingsPath = (Join-Path $PSScriptRoot '../../settings.json'),
    [string]$RadiusVersion = '0.60'
)

$ErrorActionPreference = 'Stop'
$results = [System.Collections.Generic.List[object]]::new()
. (Join-Path $PSScriptRoot '../../lib/settings.ps1')

function Add-Result([string]$Area, [string]$Check, [ValidateSet('PASS', 'WARN', 'FAIL')][string]$Status, [string]$Detail = '') {
    $results.Add([pscustomobject]@{ Area = $Area; Check = $Check; Status = $Status; Detail = $Detail })
    $color = @{ PASS = 'Green'; WARN = 'Yellow'; FAIL = 'Red' }[$Status]
    Write-Host ("  {0,-4}  {1,-10} {2}{3}" -f $Status, $Area, $Check, $(if ($Detail) { " - $Detail" })) -ForegroundColor $color
}

function ConvertTo-UInt32([string]$Address) {
    $bytes = [Net.IPAddress]::Parse($Address).GetAddressBytes()
    [Array]::Reverse($bytes)
    [BitConverter]::ToUInt32($bytes, 0)
}

function Test-InSubnet([string]$Address, [string]$Prefix) {
    $network, $length = $Prefix.Split('/')
    $mask = if ([int]$length -eq 0) { [uint32]0 } else { [uint32]::MaxValue -shl (32 - [int]$length) }
    ((ConvertTo-UInt32 $Address) -band $mask) -eq ((ConvertTo-UInt32 $network) -band $mask)
}

function Test-InRange([string]$Address, [string]$First, [string]$Last) {
    $value = ConvertTo-UInt32 $Address
    $value -ge (ConvertTo-UInt32 $First) -and $value -le (ConvertTo-UInt32 $Last)
}

# Plain TCP connect, so it works on any OS (Test-NetConnection is Windows-only).
function Test-TcpPort([string]$HostName, [int]$Port, [int]$TimeoutMs = 3000) {
    $client = [Net.Sockets.TcpClient]::new()
    try { $client.ConnectAsync($HostName, $Port).Wait($TimeoutMs) -and $client.Connected }
    catch { $false }
    finally { $client.Dispose() }
}

# --- Settings -----------------------------------------------------------------------------------
$infra = Join-Path $PSScriptRoot '.'
$s = @{}
foreach ($script in 'provision-infra.ps1', 'connected-registry.ps1', 'keycloak.ps1', 'provision-ingress.ps1') {
    (Get-OmsScriptDefaults (Join-Path $infra $script)).GetEnumerator() | ForEach-Object { if (-not $s.ContainsKey($_.Key)) { $s[$_.Key] = $_.Value } }
}
if (Test-Path $SettingsPath) {
    $site = (Get-Content $SettingsPath -Raw | ConvertFrom-Json -AsHashtable).AzureLocal
    foreach ($section in 'Common', 'Cluster', 'Registry', 'Keycloak', 'Ingress') {
        if ($site -and $site[$section]) { foreach ($key in $site[$section].Keys) { $s[$key] = $site[$section][$key] } }
    }
    Write-Host "Settings: $((Resolve-Path $SettingsPath).Path)" -ForegroundColor DarkGray
}
else {
    Write-Host "No settings file at $SettingsPath; using the scripts' defaults." -ForegroundColor Yellow
}

# --- Tools --------------------------------------------------------------------------------------
Write-Host "`nTools" -ForegroundColor Cyan
if ($PSVersionTable.PSVersion.Major -ge 7) { Add-Result Tools 'PowerShell 7' PASS "$($PSVersionTable.PSVersion)" }
else { Add-Result Tools 'PowerShell 7' FAIL "running $($PSVersionTable.PSVersion); install PowerShell 7 and use pwsh" }

foreach ($tool in 'az', 'kubectl', 'helm', 'rad') {
    if (Get-Command $tool -ErrorAction SilentlyContinue) { Add-Result Tools $tool PASS }
    else { Add-Result Tools $tool FAIL 'not on PATH' }
}
if (Get-Command rad -ErrorAction SilentlyContinue) {
    # rad version also asks the cluster for its control plane, so it runs with a timeout.
    $job = Start-Job { rad version --output json 2>$null }
    $radVersion = if (Wait-Job $job -Timeout 60) { ((Receive-Job $job) -join "`n" | ConvertFrom-Json).cli.release }
    Remove-Job $job -Force
    if ($radVersion -like "$RadiusVersion*") { Add-Result Tools "rad $RadiusVersion" PASS $radVersion }
    else { Add-Result Tools "rad $RadiusVersion" WARN "found '$radVersion'; the mirrored Radius images are $RadiusVersion" }
}

# --- Azure --------------------------------------------------------------------------------------
Write-Host "`nAzure" -ForegroundColor Cyan
$signedIn = $false
if (Get-Command az -ErrorAction SilentlyContinue) {
    $account = az account show --subscription $s.SubscriptionId --output json 2>$null | ConvertFrom-Json
    if ($account) { $signedIn = $true; Add-Result Azure 'Subscription' PASS "$($account.name) as $($account.user.name)" }
    else { Add-Result Azure 'Subscription' FAIL "can't read '$($s.SubscriptionId)'; run az login and check SubscriptionId" }
}

if ($signedIn) {
    $sub = @('--subscription', $s.SubscriptionId)
    foreach ($provider in 'Microsoft.ExtendedLocation', 'Microsoft.HybridContainerService', 'Microsoft.AzureStackHCI',
        'Microsoft.Kubernetes', 'Microsoft.KubernetesConfiguration', 'Microsoft.KubernetesRuntime', 'Microsoft.ContainerRegistry') {
        $state = az provider show --namespace $provider --query registrationState --output tsv @sub 2>$null
        if ($state -eq 'Registered') { Add-Result Azure $provider PASS }
        else { Add-Result Azure $provider WARN "$state; setup registers it, which needs Contributor on the subscription" }
    }

    $customLocation = az resource show --resource-group $s.AzureLocalResourceGroup --name $s.CustomLocationName `
        --resource-type Microsoft.ExtendedLocation/customLocations --output json @sub 2>$null | ConvertFrom-Json
    if (-not $customLocation) {
        Add-Result Azure 'Custom location' FAIL "'$($s.CustomLocationName)' not found in '$($s.AzureLocalResourceGroup)'"
    }
    elseif ($customLocation.properties.provisioningState -ne 'Succeeded') {
        Add-Result Azure 'Custom location' FAIL "$($customLocation.name) is $($customLocation.properties.provisioningState)"
    }
    else {
        Add-Result Azure 'Custom location' PASS $customLocation.name
        $bridge = az resource show --ids $customLocation.properties.hostResourceId --output json @sub 2>$null | ConvertFrom-Json
        if ($bridge.properties.status -eq 'Running') { Add-Result Azure 'Arc resource bridge' PASS $bridge.name }
        else { Add-Result Azure 'Arc resource bridge' FAIL "$($bridge.name) is '$($bridge.properties.status)'; the instance must be connected to deploy" }
    }

    if ($s.VmSwitchName) {
        Add-Result Azure 'Virtual switch' PASS "$($s.VmSwitchName) (from settings; not verified)"
    }
    else {
        $lnet = az resource show --resource-group $s.AzureLocalResourceGroup --name $s.SwitchSourceLogicalNetworkName `
            --resource-type Microsoft.AzureStackHCI/logicalNetworks --output json @sub 2>$null | ConvertFrom-Json
        if ($lnet.properties.vmSwitchName) { Add-Result Azure 'Virtual switch' PASS "$($lnet.properties.vmSwitchName), from $($lnet.name)" }
        else { Add-Result Azure 'Virtual switch' FAIL "set VmSwitchName, or SwitchSourceLogicalNetworkName to an existing logical network" }
    }

    $registry = az acr show --name $s.RegistryName --output json @sub 2>$null | ConvertFrom-Json
    if ($registry -and $registry.sku.name -ne 'Premium') { Add-Result Azure 'Registry' FAIL "$($s.RegistryName) is $($registry.sku.name); a connected registry needs Premium" }
    elseif ($registry) { Add-Result Azure 'Registry' PASS "$($s.RegistryName) (exists, Premium)" }
    else {
        $available = az acr check-name --name $s.RegistryName --query nameAvailable --output tsv 2>$null
        if ($available -eq 'true') { Add-Result Azure 'Registry' PASS "$($s.RegistryName) (available, setup creates it)" }
        else { Add-Result Azure 'Registry' FAIL "'$($s.RegistryName)' is taken; pick another RegistryName" }
    }
}

# --- Network ------------------------------------------------------------------------------------
Write-Host "`nNetwork" -ForegroundColor Cyan
try {
    $prefix = $s.AddressPrefix
    $lbFirst, $lbLast = $s.LoadBalancerAddresses.Split('-')
    $ingressIp = if ($s.IngressIp) { $s.IngressIp } else { $lbFirst }

    foreach ($pair in @(@('Gateway', $s.Gateway), @('Node pool start', $s.IpPoolStart), @('Node pool end', $s.IpPoolEnd),
            @('Control plane', $s.ControlPlaneIp), @('Load balancer range', $lbFirst), @('Load balancer range', $lbLast))) {
        if (Test-InSubnet $pair[1] $prefix) { continue }
        Add-Result Network "$($pair[0]) in $prefix" FAIL "$($pair[1]) is outside the subnet"
    }

    if (Test-InRange $s.ControlPlaneIp $s.IpPoolStart $s.IpPoolEnd) { Add-Result Network 'Control plane outside node pool' FAIL "$($s.ControlPlaneIp) is inside $($s.IpPoolStart)-$($s.IpPoolEnd)" }
    else { Add-Result Network 'Control plane outside node pool' PASS $s.ControlPlaneIp }

    if ((Test-InRange $lbFirst $s.IpPoolStart $s.IpPoolEnd) -or (Test-InRange $lbLast $s.IpPoolStart $s.IpPoolEnd) -or
        (Test-InRange $s.IpPoolStart $lbFirst $lbLast)) { Add-Result Network 'Load balancer outside node pool' FAIL "$($s.LoadBalancerAddresses) overlaps the node pool" }
    else { Add-Result Network 'Load balancer outside node pool' PASS $s.LoadBalancerAddresses }

    if (Test-InRange $ingressIp $lbFirst $lbLast) { Add-Result Network 'Ingress address in load balancer range' PASS $ingressIp }
    else { Add-Result Network 'Ingress address in load balancer range' FAIL "$ingressIp is outside $($s.LoadBalancerAddresses)" }
}
catch {
    Add-Result Network 'Addresses' FAIL "can't parse the address settings: $($_.Exception.Message)"
}

# --- Directory ----------------------------------------------------------------------------------
Write-Host "`nDirectory" -ForegroundColor Cyan
$dns = @($s.DnsServers)[0]
if (-not $s.AdServer -or $s.AdServer -like '<*') {
    Add-Result Directory 'Domain controller' FAIL 'set AdServer in the Keycloak settings to the DC FQDN'
}
else {
    $resolved = $null
    if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
        $resolved = Resolve-DnsName -Name $s.AdServer -Server $dns -Type A -DnsOnly -QuickTimeout -ErrorAction SilentlyContinue |
            Where-Object IPAddress | Select-Object -First 1
    }
    if ($resolved) { Add-Result Directory "Resolves through $dns" PASS "$($s.AdServer) -> $($resolved.IPAddress)" }
    else { Add-Result Directory "Resolves through $dns" WARN "$($s.AdServer) didn't resolve from here; the cluster nodes use $dns and must resolve it" }

    # The address the site's DNS returned, which is what the cluster nodes will use; this machine's
    # own resolver may not know the site's domain.
    $ldapsTarget = if ($resolved) { $resolved.IPAddress } else { $s.AdServer }
    $ldaps = Test-TcpPort $ldapsTarget 636
    if ($ldaps) { Add-Result Directory 'LDAPS (636)' PASS }
    else { Add-Result Directory 'LDAPS (636)' WARN "no answer from this machine; Keycloak in the cluster needs it" }
}

# --- Cluster ------------------------------------------------------------------------------------
Write-Host "`nCluster" -ForegroundColor Cyan
$contexts = @(kubectl config get-contexts --output name 2>$null)
if ($s.KubeContext -notin $contexts) {
    Add-Result Cluster 'Kube context' PASS "'$($s.KubeContext)' not created yet; setup creates the cluster"
}
else {
    $nodes = kubectl --context $s.KubeContext get nodes --request-timeout=20s --output json 2>$null | ConvertFrom-Json
    if (-not $nodes) {
        Add-Result Cluster 'API server' FAIL "context '$($s.KubeContext)' doesn't answer"
    }
    else {
        $notReady = @($nodes.items | Where-Object { ($_.status.conditions | Where-Object type -eq 'Ready').status -ne 'True' })
        if ($notReady) { Add-Result Cluster 'Nodes ready' FAIL "$($notReady.Count) of $($nodes.items.Count) not ready" }
        else { Add-Result Cluster 'Nodes ready' PASS "$($nodes.items.Count) nodes" }

        foreach ($secret in 'oms-ad-bind', 'oms-ad-ca') {
            if (kubectl --context $s.KubeContext -n identity get secret $secret --ignore-not-found --output name 2>$null) {
                Add-Result Cluster "Secret identity/$secret" PASS
            }
            else {
                Add-Result Cluster "Secret identity/$secret" WARN 'needed before the Keycloak step; see "Connect your Active Directory" in docs/authentication.md'
            }
        }
    }
}

# --- Summary ------------------------------------------------------------------------------------
$failed = @($results | Where-Object Status -eq 'FAIL').Count
$warned = @($results | Where-Object Status -eq 'WARN').Count
Write-Host ''
if ($failed) {
    Write-Host "$failed check(s) failed, $warned warning(s). Fix the failures before running setup." -ForegroundColor Red
    exit 1
}
Write-Host "Ready: $($results.Count) checks, $warned warning(s)." -ForegroundColor Green
