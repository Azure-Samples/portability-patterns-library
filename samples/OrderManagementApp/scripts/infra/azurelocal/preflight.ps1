#Requires -Version 7.3
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
      Cluster      if it already exists: reachable, nodes ready, the connected registry's storage
                   class and ClusterIP, the AD Secrets Keycloak needs, a storage class for the
                   observability volumes

    Values come from the AzureLocal section of scripts/settings.json, the same values
    setup-platform.ps1 passes to the setup scripts. Each check prints PASS, WARN or FAIL; the script
    exits with 1 on any FAIL.


.EXAMPLE
    ./scripts/infra/azurelocal/preflight.ps1
#>
[CmdletBinding()]
param(
    # Empty: scripts/settings.json.
    [string]$SettingsPath,
    [string]$RadiusVersion = '0.60',
    # Setup steps that won't run, as for setup-platform.ps1 -Skip; their checks are left out.
    [string[]]$Skip = @()
)

$ErrorActionPreference = 'Stop'

$results = [System.Collections.Generic.List[object]]::new()
. (Join-Path $PSScriptRoot '../../lib/settings.ps1')
. (Join-Path $PSScriptRoot '../../lib/azure.ps1')

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

# Runs a check that reads Azure and reports a failed read, which isn't the same as a missing resource.
function Invoke-AzureCheck([string]$Check, [scriptblock]$Read) {
    try { & $Read }
    catch { Add-Result Azure $Check FAIL $_.Exception.Message }
}

# --- Settings -----------------------------------------------------------------------------------
# The sections whose values the checks use, merged as setup-platform.ps1 merges 'Common' into each step.
$site = Read-OmsSettings 'AzureLocal' $SettingsPath
$s = @{}
foreach ($section in 'Common', 'Cluster', 'Registry', 'Keycloak', 'Ingress') {
    if ($site[$section]) { foreach ($key in $site[$section].Keys) { $s[$key] = $site[$section][$key] } }
}
$missingShared = @('SubscriptionId', 'ResourceGroup', 'ClusterName', 'KubeContext', 'RegistryName') |
    Where-Object { -not $s[$_] -or $s[$_] -like '<*' }

# --- Tools --------------------------------------------------------------------------------------
Write-Host "`nTools" -ForegroundColor Cyan
if ($PSVersionTable.PSVersion -ge [version]'7.3') { Add-Result Tools 'PowerShell 7.3+' PASS "$($PSVersionTable.PSVersion)" }
else { Add-Result Tools 'PowerShell 7.3+' FAIL "running $($PSVersionTable.PSVersion); install PowerShell 7.3 or later and use pwsh" }

foreach ($tool in 'az', 'kubectl', 'helm', 'rad') {
    if (Get-Command $tool -ErrorAction SilentlyContinue) { Add-Result Tools $tool PASS }
    else { Add-Result Tools $tool FAIL 'not on PATH' }
}
# The setup scripts wait for objects to appear with 'kubectl wait --for=create'.
if (Get-Command kubectl -ErrorAction SilentlyContinue) {
    $kubectlVersion = (kubectl version --client --output json | ConvertFrom-Json).clientVersion
    if ($LASTEXITCODE -eq 0 -and [int]$kubectlVersion.major -eq 1 -and [int]($kubectlVersion.minor -replace '\D') -ge 31) {
        Add-Result Tools 'kubectl 1.31+' PASS $kubectlVersion.gitVersion
    }
    else { Add-Result Tools 'kubectl 1.31+' FAIL "found '$($kubectlVersion.gitVersion)'; install kubectl 1.31 or later" }
}

if (Get-Command rad -ErrorAction SilentlyContinue) {
    # rad version also asks the cluster for its control plane, so it runs with a timeout.
    $job = Start-Job { rad version --output json 2>$null }
    $radVersion = if (Wait-Job $job -Timeout 60) { ((Receive-Job $job) -join "`n" | ConvertFrom-Json).cli.release }
    Remove-Job $job -Force
    if ($radVersion -like "$RadiusVersion*") { Add-Result Tools "rad $RadiusVersion" PASS $radVersion }
    else { Add-Result Tools "rad $RadiusVersion" WARN "found '$radVersion'; the mirrored Radius images are $RadiusVersion" }
}

if ($missingShared) {
    Write-Host "`nSettings" -ForegroundColor Cyan
    Add-Result Settings 'Common' FAIL "set $($missingShared -join ', ') in the Common section of the AzureLocal settings"
}

# --- Azure --------------------------------------------------------------------------------------
$signedIn = $false
Write-Host "`nAzure" -ForegroundColor Cyan
if ((Get-Command az -ErrorAction SilentlyContinue) -and $s.SubscriptionId -and $s.SubscriptionId -notlike '<*') {
    Invoke-AzureCheck 'Subscription' {
        $account = Invoke-OmsAzShow @('account', 'show', '--subscription', $s.SubscriptionId, '--output', 'json') | ConvertFrom-Json
        if ($account) { $script:account = $account; $script:signedIn = $true; Add-Result Azure 'Subscription' PASS "$($account.name) as $($account.user.name)" }
        else { Add-Result Azure 'Subscription' FAIL "'$($s.SubscriptionId)' not found; run az login and check SubscriptionId" }
    }
}

if ($signedIn) {
    $sub = @('--subscription', $s.SubscriptionId)
    foreach ($provider in 'Microsoft.ExtendedLocation', 'Microsoft.HybridContainerService', 'Microsoft.AzureStackHCI',
        'Microsoft.Kubernetes', 'Microsoft.KubernetesConfiguration', 'Microsoft.KubernetesRuntime', 'Microsoft.ContainerRegistry') {
        Invoke-AzureCheck $provider {
            $state = Invoke-OmsAzShow (@('provider', 'show', '--namespace', $provider, '--query', 'registrationState', '--output', 'tsv') + $sub)
            if ($state -eq 'Registered') { Add-Result Azure $provider PASS }
            else { Add-Result Azure $provider WARN "$state; setup registers it, which needs Contributor on the subscription" }
        }
    }

    Invoke-AzureCheck 'Custom location' {
        $customLocation = Invoke-OmsAzShow (@('resource', 'show', '--resource-group', $s.AzureLocalResourceGroup, '--name', $s.CustomLocationName,
                '--resource-type', 'Microsoft.ExtendedLocation/customLocations', '--output', 'json') + $sub) | ConvertFrom-Json
        if (-not $customLocation) {
            Add-Result Azure 'Custom location' FAIL "'$($s.CustomLocationName)' not found in '$($s.AzureLocalResourceGroup)'"
        }
        elseif ($customLocation.properties.provisioningState -ne 'Succeeded') {
            Add-Result Azure 'Custom location' FAIL "$($customLocation.name) is $($customLocation.properties.provisioningState)"
        }
        else {
            Add-Result Azure 'Custom location' PASS $customLocation.name
            $bridge = Invoke-OmsAzShow (@('resource', 'show', '--ids', $customLocation.properties.hostResourceId, '--output', 'json') + $sub) | ConvertFrom-Json
            if ($bridge.properties.status -eq 'Running') { Add-Result Azure 'Arc resource bridge' PASS $bridge.name }
            else { Add-Result Azure 'Arc resource bridge' FAIL "'$($customLocation.properties.hostResourceId)' is '$($bridge.properties.status)'; the instance must be connected to deploy" }
        }
    }

    if ($s.VmSwitchName -and $s.VmSwitchName -notlike '<*') {
        Add-Result Azure 'Virtual switch' PASS "$($s.VmSwitchName) (from settings; not verified)"
    }
    elseif ($s.SwitchSourceLogicalNetworkName) {
        Invoke-AzureCheck 'Virtual switch' {
            $lnet = Invoke-OmsAzShow (@('resource', 'show', '--resource-group', $s.AzureLocalResourceGroup, '--name', $s.SwitchSourceLogicalNetworkName,
                    '--resource-type', 'Microsoft.AzureStackHCI/logicalNetworks', '--output', 'json') + $sub) | ConvertFrom-Json
            if ($lnet.properties.vmSwitchName) { Add-Result Azure 'Virtual switch' PASS "$($lnet.properties.vmSwitchName), from $($lnet.name)" }
            else { Add-Result Azure 'Virtual switch' FAIL "logical network '$($s.SwitchSourceLogicalNetworkName)' not found in '$($s.AzureLocalResourceGroup)', or it has no switch" }
        }
    }
    else { Add-Result Azure 'Virtual switch' FAIL 'set VmSwitchName, or SwitchSourceLogicalNetworkName to an existing logical network, in the Cluster settings' }

    Invoke-AzureCheck 'Registry' {
        $registry = Invoke-OmsAzShow (@('acr', 'show', '--name', $s.RegistryName, '--output', 'json') + $sub) | ConvertFrom-Json
        if ($registry -and $registry.sku.name -ne 'Premium') { Add-Result Azure 'Registry' FAIL "$($s.RegistryName) is $($registry.sku.name); a connected registry needs Premium" }
        elseif ($registry) { Add-Result Azure 'Registry' PASS "$($s.RegistryName) (exists, Premium)" }
        else {
            $available = Invoke-OmsAzShow (@('acr', 'check-name', '--name', $s.RegistryName, '--query', 'nameAvailable', '--output', 'tsv') + $sub)
            if ($available -eq 'true') { Add-Result Azure 'Registry' PASS "$($s.RegistryName) (available, setup creates it)" }
            else { Add-Result Azure 'Registry' FAIL "'$($s.RegistryName)' is taken; pick another RegistryName" }
        }
    }

    # The KeyVault step grants the extension's identity, and you, access to the vault's secrets,
    # which takes the right to create role assignments; Contributor doesn't have it. Roles held
    # through a group count; a PIM-eligible role counts only once activated.
    if ('KeyVault' -notin $Skip) {
        Invoke-AzureCheck 'Can create role assignments' {
            $assignee = if ($account.user.type -eq 'servicePrincipal') { $account.user.name } else { Invoke-OmsAzShow @('ad', 'signed-in-user', 'show', '--query', 'id', '--output', 'tsv') }
            $subscriptionScope = "/subscriptions/$($account.id)"
            $scopes = @('/', $subscriptionScope, "$subscriptionScope/resourceGroups/$($s.ResourceGroup)")
            $assignments = Invoke-OmsAzShow (@('role', 'assignment', 'list', '--assignee', $assignee, '--all', '--include-inherited', '--include-groups', '--output', 'json') + $sub)
            $canAssign = @($assignments | ConvertFrom-Json |
                    Where-Object { $_.roleDefinitionName -in 'Owner', 'User Access Administrator', 'Role Based Access Control Administrator' -and
                        ($_.scope -in $scopes -or $_.scope -like '/providers/Microsoft.Management/managementGroups/*') }) | Select-Object -First 1
            if ($canAssign) { Add-Result Azure 'Can create role assignments' PASS "$($canAssign.roleDefinitionName) on $($canAssign.scope)" }
            else { Add-Result Azure 'Can create role assignments' FAIL "needs Owner, User Access Administrator or Role Based Access Control Administrator on the subscription or resource group '$($s.ResourceGroup)', for the KeyVault step (or skip it: -Skip KeyVault)" }
        }
    }
}
# --- Network ------------------------------------------------------------------------------------
# The cluster's addresses come from the site's network plan.
Write-Host "`nNetwork" -ForegroundColor Cyan
$plan = 'AddressPrefix', 'Gateway', 'DnsServers', 'IpPoolStart', 'IpPoolEnd', 'ControlPlaneIp', 'LoadBalancerAddresses'
$missing = @($plan | Where-Object { $value = @($s[$_]) -join ','; -not $value -or $value -like '<*' })
if ($missing) {
    Add-Result Network 'Network plan' FAIL "set $($missing -join ', ') in the Cluster settings, from your site's network plan"
}
else {
    try {
        $prefix = $s.AddressPrefix
        $lbFirst, $lbLast = $s.LoadBalancerAddresses.Split('-')

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

        if (-not $s.IngressIp) { Add-Result Network 'Ingress address' PASS "the first free address of $($s.LoadBalancerAddresses)" }
        elseif (Test-InRange $s.IngressIp $lbFirst $lbLast) { Add-Result Network 'Ingress address in load balancer range' PASS $s.IngressIp }
        else { Add-Result Network 'Ingress address in load balancer range' FAIL "$($s.IngressIp) is outside $($s.LoadBalancerAddresses)" }

        # The ingress and Keycloak each take an address from the range.
        $lbSize = (ConvertTo-UInt32 $lbLast) - (ConvertTo-UInt32 $lbFirst) + 1
        if ($lbSize -ge 2) { Add-Result Network 'Load balancer addresses' PASS "$lbSize (the ingress and Keycloak take one each)" }
        else { Add-Result Network 'Load balancer addresses' FAIL "$($s.LoadBalancerAddresses) has $lbSize; the ingress and Keycloak need one each" }
        if ($s.KeycloakIp) {
            if (-not (Test-InRange $s.KeycloakIp $lbFirst $lbLast)) { Add-Result Network 'Keycloak address in load balancer range' FAIL "$($s.KeycloakIp) is outside $($s.LoadBalancerAddresses)" }
            elseif ($s.KeycloakIp -eq $s.IngressIp) { Add-Result Network 'Keycloak address' FAIL "$($s.KeycloakIp) is also the ingress address" }
            else { Add-Result Network 'Keycloak address in load balancer range' PASS $s.KeycloakIp }
        }
    }
    catch {
        Add-Result Network 'Addresses' FAIL "can't parse the address settings: $($_.Exception.Message)"
    }
}

# The registry's certificate is issued for this address when the Registry step installs it.
if (-not $s.ServiceClusterIp -or $s.ServiceClusterIp -like '<*') {
    Add-Result Network 'Registry ClusterIP' FAIL "set ServiceClusterIp in the Registry settings: an unused address in the cluster's service range"
}
else { Add-Result Network 'Registry ClusterIP' PASS $s.ServiceClusterIp }

# --- Directory ----------------------------------------------------------------------------------
$dns = @($s.DnsServers)[0]
if (-not $s.AdServer -or $s.AdServer -like '<*') {
    Write-Host "`nDirectory" -ForegroundColor Cyan
    Add-Result Directory 'Domain controller' FAIL 'set AdServer in the Keycloak settings to the DC FQDN'
}
else {
    Write-Host "`nDirectory" -ForegroundColor Cyan
    # Through the DNS server the cluster nodes use when the settings name it, else this machine's.
    $resolved = $null
    $through = if ($dns) { $dns } else { "this machine's DNS" }
    if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
        $server = if ($dns) { @{ Server = $dns } } else { @{} }
        $resolved = Resolve-DnsName -Name $s.AdServer @server -Type A -DnsOnly -QuickTimeout -ErrorAction SilentlyContinue |
            Where-Object IPAddress | Select-Object -First 1
    }
    if ($resolved) { Add-Result Directory "Resolves through $through" PASS "$($s.AdServer) -> $($resolved.IPAddress)" }
    else { Add-Result Directory "Resolves through $through" WARN "$($s.AdServer) didn't resolve from here; the cluster nodes must resolve it through the DNS servers of their logical network" }

    # The address the site's DNS returned, which is what the cluster nodes will use; this machine's
    # own resolver may not know the site's domain.
    $ldapsTarget = if ($resolved) { $resolved.IPAddress } else { $s.AdServer }
    $ldaps = Test-TcpPort $ldapsTarget 636
    if ($ldaps) { Add-Result Directory 'LDAPS (636)' PASS }
    else { Add-Result Directory 'LDAPS (636)' WARN "no answer from this machine; Keycloak in the cluster needs it" }
}

# Keycloak takes the directory's CA from this file the first time, so a wrong path only shows there.
if ($s.AdCaCertificatePath -and $s.AdCaCertificatePath -notlike '<*') {
    if ((Test-Path $s.AdCaCertificatePath) -and ((Get-Content $s.AdCaCertificatePath -Raw) -match '-----BEGIN CERTIFICATE-----')) {
        Add-Result Directory 'Directory CA certificate' PASS $s.AdCaCertificatePath
    }
    else { Add-Result Directory 'Directory CA certificate' FAIL "'$($s.AdCaCertificatePath)' is not a PEM certificate file" }
}
else { Add-Result Directory 'Directory CA certificate' WARN 'set AdCaCertificatePath in the Keycloak settings, unless Secret identity/oms-ad-ca already exists' }

# --- Cluster ------------------------------------------------------------------------------------
# Reads the cluster with kubectl; a failed read throws rather than passing for an empty answer.
function Invoke-Kubectl {
    $output = kubectl --context $s.KubeContext @args
    if ($LASTEXITCODE -ne 0) { throw "kubectl $($args -join ' ') failed." }
    $output
}

Write-Host "`nCluster" -ForegroundColor Cyan
$contexts = @(kubectl config get-contexts --output name)
if ($LASTEXITCODE -ne 0) {
    Add-Result Cluster 'Kube context' FAIL "kubectl can't read its kubeconfig"
}
elseif (-not $s.KubeContext) {
    Add-Result Cluster 'Kube context' FAIL 'set KubeContext in the Common settings'
}
elseif ($s.KubeContext -notin $contexts) {
    Add-Result Cluster 'Kube context' PASS "'$($s.KubeContext)' not created yet; setup creates the cluster"
}
else {
    $nodes = kubectl --context $s.KubeContext get nodes --request-timeout=20s --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or -not $nodes) {
        Add-Result Cluster 'API server' FAIL "context '$($s.KubeContext)' doesn't answer"
    }
    else {
        try {
            $notReady = @($nodes.items | Where-Object { ($_.status.conditions | Where-Object type -eq 'Ready').status -ne 'True' })
            if ($notReady) { Add-Result Cluster 'Nodes ready' FAIL "$($notReady.Count) of $($nodes.items.Count) not ready" }
            else { Add-Result Cluster 'Nodes ready' PASS "$($nodes.items.Count) nodes" }

            # The RabbitMQ nodes and the PostgreSQL instances spread one per worker, so losing a worker
            # loses one replica, not the service.
            $workers = @($nodes.items | Where-Object { -not $_.metadata.labels.'node-role.kubernetes.io/control-plane' })
            if ($workers.Count -ge 3) { Add-Result Cluster 'Workers' PASS "$($workers.Count)" }
            else { Add-Result Cluster 'Workers' WARN "$($workers.Count); with fewer than 3, replicas share a worker and losing it takes the queue or a database down" }

            # The connected registry is installed from Azure, which can't check these; a wrong value
            # only fails once the extension is half installed.
            if (-not $s.StorageClassName) {
                Add-Result Cluster 'Registry storage class' WARN 'not checked: set StorageClassName in the Registry settings'
            }
            elseif (Invoke-Kubectl get storageclass $s.StorageClassName --ignore-not-found --output name) {
                Add-Result Cluster 'Registry storage class' PASS $s.StorageClassName
            }
            else { Add-Result Cluster 'Registry storage class' FAIL "'$($s.StorageClassName)' not found; set StorageClassName in the Registry settings (kubectl get storageclass)" }

            # The address the Registry settings give the connected registry: in the service range, and
            # free or already the registry's.
            if ($s.ServiceClusterIp -and $s.ServiceClusterIp -notlike '<*') {
                $registryIp = $s.ServiceClusterIp
                $kubernetesServiceIp = Invoke-Kubectl get service kubernetes --namespace default --output 'jsonpath={.spec.clusterIP}'
                $taken = (Invoke-Kubectl get services --all-namespaces --output json | ConvertFrom-Json).items |
                    Where-Object { $_.spec.clusterIP -eq $registryIp } | Select-Object -First 1
                if (-not $registryIp.StartsWith((($kubernetesServiceIp -split '\.')[0..1] -join '.') + '.')) {
                    Add-Result Cluster 'Registry ClusterIP' FAIL "$registryIp doesn't look like it is in the service range (the 'kubernetes' service is '$kubernetesServiceIp')"
                }
                elseif ($taken -and $taken.metadata.namespace -ne 'connected-registry') {
                    Add-Result Cluster 'Registry ClusterIP' FAIL "$registryIp is taken by $($taken.metadata.namespace)/$($taken.metadata.name)"
                }
                else { Add-Result Cluster 'Registry ClusterIP' PASS $registryIp }
            }

            foreach ($secret in 'oms-ad-bind', 'oms-ad-ca') {
                if (Invoke-Kubectl --namespace identity get secret $secret --ignore-not-found --output name) {
                    Add-Result Cluster "Secret identity/$secret" PASS
                }
                else {
                    $how = if ($secret -eq 'oms-ad-bind') { "the Keycloak step asks for the bind account's password" } else { 'the Keycloak step reads AdCaCertificatePath' }
                    Add-Result Cluster "Secret identity/$secret" PASS "not there yet; $how"
                }
            }

            # The Observability step's volumes use the class in its settings, else the cluster's default.
            $observabilityClass = if ($site['Observability']) { $site['Observability']['StorageClassName'] }
            if ($observabilityClass) {
                if (Invoke-Kubectl get storageclass $observabilityClass --ignore-not-found --output name) {
                    Add-Result Cluster 'Observability storage class' PASS $observabilityClass
                }
                else { Add-Result Cluster 'Observability storage class' FAIL "'$observabilityClass' not found; fix StorageClassName in the Observability settings (kubectl get storageclass)" }
            }
            else {
                $defaultClass = (Invoke-Kubectl get storageclass --output json | ConvertFrom-Json).items |
                    Where-Object { $_.metadata.annotations.'storageclass.kubernetes.io/is-default-class' -eq 'true' } | Select-Object -First 1
                if ($defaultClass) { Add-Result Cluster 'Observability storage class' PASS "$($defaultClass.metadata.name) (the cluster's default)" }
                else { Add-Result Cluster 'Observability storage class' FAIL 'the cluster has no default storage class; set StorageClassName in the Observability settings' }
            }
        }
        catch {
            Add-Result Cluster 'Reading the cluster' FAIL $_.Exception.Message
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
exit 0
