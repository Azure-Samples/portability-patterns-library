<#
.SYNOPSIS
    Provisions the connected Azure Local platform for the sample: Premium container registry, AKS
    logical network, AKS enabled by Arc cluster with its Entra admin group, and the Arc load balancer.

.DESCRIPTION
    Targets an Azure Local instance that is connected to public Azure. Everything is declared in
    infra/azurelocal/platform.bicep; this script prepares what a template can't (CLI extension,
    resource providers, SSH key, adopting an existing admin group), deploys it, and fetches the
    cluster credentials.

    Everything the application owns lives in one resource group, 'bcd-azurelocal' by default,
    separate from the resource group that holds the Azure Local instance and its custom location.

    Cluster credentials are fetched with --admin: they authenticate with a client certificate
    directly against the API server, which keeps working with no Azure connectivity.

    -WhatIf runs an Azure what-if of the template instead of deploying it, and changes nothing.
    What-if doesn't cover the Entra group; it reports it as not supported.

.EXAMPLE
    ./scripts/infra/azurelocal/provision-infra.ps1 -RegistryName <acr-name>

.EXAMPLE
    # Preview what the template would change on an existing site.
    ./scripts/infra/azurelocal/provision-infra.ps1 -RegistryName <acr-name> -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$SubscriptionId = '<subscription-id>',

    [ValidatePattern('^[a-z0-9]{5,50}$')]
    [string]$RegistryName = '<acr-name>',

    # Holds every resource this script creates. The Azure Local instance lives elsewhere.
    [string]$ResourceGroup = 'bcd-azurelocal',
    [string]$Location = 'eastus',

    # Resource group and custom location of the Azure Local instance.
    [string]$AzureLocalResourceGroup = 'azurelocal-lab-rg',
    [string]$CustomLocationName = 'azlocal-lab-cl',

    # Virtual switch for the AKS nodes: given directly, or copied from an existing logical network.
    [string]$VmSwitchName = '',
    [string]$SwitchSourceLogicalNetworkName = 'azlocal-lab-InfraLNET',

    # Logical network for the AKS nodes. Shares the infrastructure subnet but uses its own pool.
    [string]$LogicalNetworkName = 'bcd-aks-lnet',
    [string]$AddressPrefix = '192.168.44.0/24',
    [string]$Gateway = '192.168.44.1',
    [string[]]$DnsServers = @('192.168.44.10'),
    [string]$IpPoolStart = '192.168.44.121',
    [string]$IpPoolEnd = '192.168.44.180',
    [int]$Vlan = 0,

    [string]$ClusterName = 'bcd-aksarc',

    # Must be in the subnet and OUTSIDE the logical network pool.
    [string]$ControlPlaneIp = '192.168.44.120',
    [int]$ControlPlaneCount = 1,
    [string]$ControlPlaneVmSize = 'Standard_A4_v2',
    [int]$NodeCount = 2,

    # List valid sizes with: az aksarc vmsize list --custom-location <custom-location-id>
    [string]$NodeVmSize = 'Standard_A4_v2',
    [string]$KubernetesVersion = '1.33.5',

    [string]$AdminGroupName = 'azurelocal-aks-admins',

    # Addresses the Arc load balancer hands out on the site network, outside the node pool.
    [string]$LoadBalancerName = 'bcd-lb',
    [string]$LoadBalancerAddresses = '192.168.44.200-192.168.44.210',

    # Public key installed on the nodes. Generated when missing.
    [string]$SshPublicKeyPath = (Join-Path $HOME '.ssh/id_rsa.pub'),

    [string]$KubeContext = 'bcd-aksarc'
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
Push-Location $repoRoot

# $ErrorActionPreference does not apply to native commands, so every external call is checked.
function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$What,
        [Parameter(Mandatory = $true)][scriptblock]$Command
    )

    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$What failed with exit code $LASTEXITCODE."
    }
}

$parametersFile = $null
try {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw "The az CLI is not on PATH."
    }

    Write-Host "==> Selecting subscription $SubscriptionId" -ForegroundColor Cyan
    Invoke-Checked 'az account set' { az account set --subscription $SubscriptionId }

    # Only for fetching the cluster credentials; the template needs no CLI extension.
    if (-not (az extension list --query "[?name=='aksarc'].version" --output tsv)) {
        Write-Host "==> Installing the 'aksarc' az CLI extension" -ForegroundColor Cyan
        Invoke-Checked 'az extension add aksarc' { az extension add --name aksarc --only-show-errors }
    }

    Write-Host "==> Ensuring resource providers are registered" -ForegroundColor Cyan
    $providers = @(
        'Microsoft.ExtendedLocation'
        'Microsoft.HybridContainerService'
        'Microsoft.AzureStackHCI'
        'Microsoft.Kubernetes'
        'Microsoft.KubernetesConfiguration'
        'Microsoft.KubernetesRuntime'
        'Microsoft.ContainerRegistry'
    )
    foreach ($provider in $providers) {
        $state = az provider show --namespace $provider --query registrationState --output tsv 2>$null
        if ($state -eq 'Registered') { continue }
        if ($PSCmdlet.ShouldProcess($provider, 'Register resource provider')) {
            Write-Host "    registering $provider ($state)" -ForegroundColor DarkGray
            Invoke-Checked "az provider register $provider" {
                az provider register --namespace $provider --wait --output none
            }
        }
    }

    # The template finds the admin group by its uniqueName. A group created outside Bicep has none,
    # so it is given one once; uniqueName can't be changed afterwards.
    # Query parameters go through --url-parameters: az.cmd hands the URL to cmd.exe, which splits it at '&'.
    $group = @((az rest --method get --url 'https://graph.microsoft.com/v1.0/groups' `
                --url-parameters "`$filter=displayName eq '$AdminGroupName'" '$select=id,uniqueName' `
                --query value --output json | ConvertFrom-Json)) | Select-Object -First 1
    if ($group -and -not $group.uniqueName -and $PSCmdlet.ShouldProcess($AdminGroupName, 'Set uniqueName so Bicep manages the group')) {
        Write-Host "==> Adopting existing Entra group '$AdminGroupName'" -ForegroundColor Cyan
        $bodyFile = Join-Path ([IO.Path]::GetTempPath()) "oms-group-$PID.json"
        try {
            Set-Content -Path $bodyFile -Value (@{ uniqueName = $AdminGroupName } | ConvertTo-Json -Compress) -Encoding ascii
            Invoke-Checked 'az rest PATCH group uniqueName' {
                az rest --method patch --url "https://graph.microsoft.com/v1.0/groups/$($group.id)" `
                    --headers 'Content-Type=application/json' --body "@$bodyFile" --output none
            }
        }
        finally { Remove-Item $bodyFile -ErrorAction SilentlyContinue }
    }
    if (-not (Test-Path $SshPublicKeyPath)) {
        if (-not $SshPublicKeyPath.EndsWith('.pub')) { throw "-SshPublicKeyPath must point to a .pub file." }
        if ($PSCmdlet.ShouldProcess($SshPublicKeyPath, 'Generate SSH key pair')) {
            Write-Host "==> Generating SSH key pair $SshPublicKeyPath" -ForegroundColor Cyan
            New-Item -ItemType Directory -Force -Path (Split-Path $SshPublicKeyPath) | Out-Null
            Invoke-Checked 'ssh-keygen' { ssh-keygen -t rsa -b 4096 -N '""' -q -f ($SshPublicKeyPath -replace '\.pub$', '') }
        }
    }
    $sshPublicKey = if (Test-Path $SshPublicKeyPath) { (Get-Content $SshPublicKeyPath -Raw).Trim() } else { '<generated>' }
    $signedInUserId = az ad signed-in-user show --query id --output tsv

    # A parameters file keeps az.cmd and cmd.exe away from values such as switch names with
    # parentheses, and carries the arrays.
    $parameters = [ordered]@{
        location                       = $Location
        resourceGroupName              = $ResourceGroup
        registryName                   = $RegistryName
        azureLocalResourceGroup        = $AzureLocalResourceGroup
        customLocationName             = $CustomLocationName
        vmSwitchName                   = $VmSwitchName
        switchSourceLogicalNetworkName = $SwitchSourceLogicalNetworkName
        logicalNetworkName             = $LogicalNetworkName
        addressPrefix                  = $AddressPrefix
        gateway                        = $Gateway
        dnsServers                     = @($DnsServers)
        ipPoolStart                    = $IpPoolStart
        ipPoolEnd                      = $IpPoolEnd
        vlan                           = $Vlan
        clusterName                    = $ClusterName
        controlPlaneIp                 = $ControlPlaneIp
        controlPlaneCount              = $ControlPlaneCount
        controlPlaneVmSize             = $ControlPlaneVmSize
        nodeCount                      = $NodeCount
        nodeVmSize                     = $NodeVmSize
        kubernetesVersion              = $KubernetesVersion
        sshPublicKey                   = $sshPublicKey
        adminGroupName                 = $AdminGroupName
        adminGroupMemberIds            = @($signedInUserId | Where-Object { $_ })
        loadBalancerName               = $LoadBalancerName
        loadBalancerAddresses          = $LoadBalancerAddresses
    }
    $parametersDocument = [ordered]@{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = [ordered]@{}
    }
    foreach ($key in $parameters.Keys) { $parametersDocument.parameters[$key] = @{ value = $parameters[$key] } }
    $parametersFile = Join-Path ([IO.Path]::GetTempPath()) "oms-azurelocal-platform-$PID.json"
    # A temporary input, written even under -WhatIf so the what-if can read it.
    $parametersDocument | ConvertTo-Json -Depth 10 | Set-Content -Path $parametersFile -Encoding utf8 -WhatIf:$false

    $template = 'infra/azurelocal/platform.bicep'
    $deploymentName = 'oms-azurelocal-platform'

    if (-not $PSCmdlet.ShouldProcess("$ResourceGroup ($template)", 'Deploy the Azure Local platform')) {
        Write-Host "==> What-if of $template" -ForegroundColor Cyan
        Invoke-Checked 'az deployment sub what-if' {
            az deployment sub what-if --name $deploymentName --location $Location `
                --template-file $template --parameters "@$parametersFile" --result-format FullResourcePayloads
        }
        return
    }

    Write-Host "==> Deploying $template (a new cluster takes 20-40 minutes)" -ForegroundColor Cyan
    $outputsJson = az deployment sub create --name $deploymentName --location $Location `
        --template-file $template --parameters "@$parametersFile" --query properties.outputs --output json
    if ($LASTEXITCODE -ne 0) { throw 'az deployment sub create failed.' }
    $registryLoginServer = ($outputsJson | ConvertFrom-Json).registryLoginServer.value

    Write-Host "==> Fetching admin credentials as context '$KubeContext'" -ForegroundColor Cyan
    Invoke-Checked 'az aksarc get-credentials' {
        az aksarc get-credentials --name $ClusterName --resource-group $ResourceGroup `
            --admin --context $KubeContext --overwrite-existing
    }
    Invoke-Checked 'kubectl cluster-info' {
        kubectl cluster-info --context $KubeContext --request-timeout=30s | Out-Null
    }

    # The connected registry Service needs a ClusterIP inside the service CIDR; report it.
    $kubernetesServiceIp = kubectl get service kubernetes --namespace default --context $KubeContext -o jsonpath='{.spec.clusterIP}'

    Write-Host "`n================ Platform ready ================" -ForegroundColor Green
    Write-Host "Resource group   : $ResourceGroup"
    Write-Host "Registry         : $registryLoginServer (Premium, data endpoint enabled)"
    Write-Host "Cluster          : $ClusterName (API $ControlPlaneIp)"
    Write-Host "Load balancer    : $LoadBalancerAddresses"
    Write-Host "kubectl context  : $KubeContext (admin certificate, works offline)"
    Write-Host "Service CIDR hint: kubernetes service is $kubernetesServiceIp"

    Write-Host "`nNext steps:" -ForegroundColor Yellow
    Write-Host "  1. ./scripts/infra/azurelocal/import-images.ps1 -Mode Mirror -Registry $registryLoginServer"
    Write-Host "  2. ./scripts/infra/azurelocal/connected-registry.ps1 -RegistryName $RegistryName -KubeContext $KubeContext"
}
finally {
    if ($parametersFile) { Remove-Item $parametersFile -Force -ErrorAction SilentlyContinue -WhatIf:$false }
    Pop-Location
}