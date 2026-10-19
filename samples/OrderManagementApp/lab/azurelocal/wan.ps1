<#
.SYNOPSIS
    Lab only: cuts or restores the lab site's link to the internet, and so to Azure, to rehearse
    Azure Local running disconnected.

.DESCRIPTION
    DC01, AZLNODE01 and the AKS Arc cluster reach the internet only through the Windows NAT on this
    host. Down removes it, as if the site's WAN line were cut; Up recreates it. This machine still
    reaches 192.168.44.0/24 directly, so kubectl, the app and Keycloak stay reachable from here.

    Needs an elevated shell. Bring the link Up before anything that needs Azure, such as
    scripts/deploy.ps1 or scripts/setup-platform.ps1.

    Every run ends with proof from inside the cluster: a pod tries to open connections to Azure
    (by name, and by IP so it is not just DNS) and to the site's own services.

.EXAMPLE
    ./lab/azurelocal/wan.ps1 -State Down
    # sign in at https://192.168.44.200 and place an order
    ./lab/azurelocal/wan.ps1 -State Up
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Down', 'Up', 'Status')]
    [string]$State,
    [string]$NatName = 'AzureLocalLabNAT',
    [string]$InternalPrefix = '192.168.44.0/24',
    [string]$KubeContext = 'bcd-aksarc',
    [string]$Namespace = 'oms-azurelocal',
    [string]$ProbePodSelector = 'app=rabbitmq',
    [string]$CloudRegistry = '<acr-name>.azurecr.io'
)

$ErrorActionPreference = 'Stop'

if ($State -ne 'Status') {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Changing the NAT needs an elevated PowerShell.'
    }
}

$nat = Get-NetNat -Name $NatName -ErrorAction SilentlyContinue
if ($State -eq 'Down' -and $nat -and $PSCmdlet.ShouldProcess($NatName, 'Remove the NAT; the lab site loses the internet and Azure')) {
    Remove-NetNat -Name $NatName -Confirm:$false
}
if ($State -eq 'Up' -and -not $nat -and $PSCmdlet.ShouldProcess($NatName, "Create the NAT for $InternalPrefix")) {
    New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix $InternalPrefix | Out-Null
}

$up = [bool](Get-NetNat -Name $NatName -ErrorAction SilentlyContinue)
Write-Host ("Lab site link to the internet and Azure: {0}" -f $(if ($up) { 'UP' } else { 'DOWN' })) `
    -ForegroundColor $(if ($up) { 'Green' } else { 'Yellow' })

# This machine keeps its own internet, so it can look up an Azure address for the by-IP probe.
$armIp = (Resolve-DnsName management.azure.com -Type A -ErrorAction SilentlyContinue | Where-Object IPAddress | Select-Object -First 1).IPAddress
$targets = @(
    @{ Group = 'Azure'; Name = 'Azure Resource Manager'; Address = 'management.azure.com:443' }
    @{ Group = 'Azure'; Name = 'Entra ID sign-in'; Address = 'login.microsoftonline.com:443' }
    @{ Group = 'Azure'; Name = 'Cloud container registry'; Address = "${CloudRegistry}:443" }
    @{ Group = 'Azure'; Name = 'Azure by IP (not DNS)'; Address = "${armIp}:443" }
    @{ Group = 'Site'; Name = 'Keycloak sign-in'; Address = '192.168.44.121:30443' }
    @{ Group = 'Site'; Name = 'On-site registry'; Address = '10.96.0.50:443' }
    @{ Group = 'Site'; Name = 'Active Directory (LDAPS)'; Address = '192.168.44.10:636' }
    @{ Group = 'Site'; Name = 'Orders app'; Address = '192.168.44.200:443' }
) | Where-Object { $_.Address -notmatch '^:' }

$pod = kubectl get pod -n $Namespace --context $KubeContext -l $ProbePodSelector -o 'jsonpath={.items[0].metadata.name}' 2>$null
if (-not $pod) { Write-Warning "No pod matching '$ProbePodSelector' in '$Namespace' to probe from."; return }

Write-Host "`nSeen from inside the cluster (pod $Namespace/$pod):" -ForegroundColor Cyan
foreach ($t in $targets) {
    $hostName, $port = $t.Address -split ':'
    $open = (kubectl exec -n $Namespace --context $KubeContext $pod -- sh -c "nc -z -w 5 $hostName $port >/dev/null 2>&1 && echo open || echo closed" 2>$null) -eq 'open'
    $expectedOpen = $t.Group -eq 'Site' -or $up
    $label = if ($open) { 'reachable' } else { 'BLOCKED' }
    $color = if ($open -eq $expectedOpen) { 'Green' } else { 'Red' }
    Write-Host ("  {0,-6} {1,-26} {2,-34} {3}" -f $t.Group, $t.Name, $t.Address, $label) -ForegroundColor $color
}
