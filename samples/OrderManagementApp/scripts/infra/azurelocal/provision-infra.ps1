#Requires -Version 7.3
<#
.SYNOPSIS
    Provisions the connected Azure Local platform for the sample: Premium container registry, AKS
    logical network, AKS enabled by Arc cluster with its Entra admin group, and the Arc load balancer.

.DESCRIPTION
    Targets an Azure Local instance that is connected to public Azure. Everything is declared in
    infra/azurelocal/platform.bicep; this script prepares what a template can't (CLI extension,
    resource providers, SSH key, adopting an existing admin group), deploys it, and fetches the
    cluster credentials.

    Everything the application owns lives in one resource group, -ResourceGroup, separate from the
    resource group that holds the Azure Local instance and its custom location.

    Cluster credentials are fetched with --admin into ~/.kube/config: they authenticate with a
    client certificate directly against the API server, which keeps working with no Azure
    connectivity.

    -WhatIf runs an Azure what-if of the template instead of deploying it, and changes nothing.
    What-if doesn't cover the Entra group; it reports it as not supported.

.EXAMPLE
    # Usually run by setup-platform.ps1 with the Common and Cluster sections of scripts/settings.json. On its own:
    ./scripts/infra/azurelocal/provision-infra.ps1 -SubscriptionId <sub-id> -RegistryName <acr-name> `
        -ResourceGroup <resource-group> -ClusterName <cluster> -KubeContext <context> -Location <region> `
        -AzureLocalResourceGroup <instance-resource-group> -CustomLocationName <custom-location> `
        -VmSwitchName <switch> -AddressPrefix <subnet> -Gateway <gateway> -DnsServers <ad-dns> `
        -IpPoolStart <first-node-ip> -IpPoolEnd <last-node-ip> -ControlPlaneIp <free-ip> `
        -LoadBalancerAddresses <first-ip>-<last-ip>

.EXAMPLE
    # Preview what the template would change on an existing site: the same parameters, plus -WhatIf.
    ./scripts/infra/azurelocal/provision-infra.ps1 <the parameters above> -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)][string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]{5,50}$')]
    [string]$RegistryName,

    # Holds every resource this script creates. The Azure Local instance lives elsewhere.
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    # The Azure Local instance's region.
    [Parameter(Mandatory = $true)][string]$Location,

    # Resource group and custom location of the Azure Local instance.
    [Parameter(Mandatory = $true)][string]$AzureLocalResourceGroup,
    [Parameter(Mandatory = $true)][string]$CustomLocationName,

    # Virtual switch for the AKS nodes: given directly, or copied from an existing logical network
    # in -AzureLocalResourceGroup. Set one of the two.
    [string]$VmSwitchName,
    [string]$SwitchSourceLogicalNetworkName,

    # Logical network for the AKS nodes, on the site network. Every address comes from your network
    # plan, so none has a default: the subnet, its gateway and DNS servers (the site's Active
    # Directory DNS, so the cluster can find the domain controller), and a free pool for the nodes.
    [string]$LogicalNetworkName = 'bcd-aks-lnet',
    [string]$AddressPrefix,
    [string]$Gateway,
    [string[]]$DnsServers,
    [string]$IpPoolStart,
    [string]$IpPoolEnd,
    [int]$Vlan = 0,

    [Parameter(Mandatory = $true)][string]$ClusterName,

    # A free address in the subnet, OUTSIDE the node pool.
    [string]$ControlPlaneIp,
    # Address range for pods, inside the cluster only. Empty keeps the template's AKS Arc default.
    [string]$PodCidr,
    [int]$ControlPlaneCount = 1,
    [string]$ControlPlaneVmSize = 'Standard_A4_v2',
    # Three workers, so each replica of RabbitMQ and the databases runs on its own node.
    [int]$NodeCount = 3,

    # 4 vCPUs and 16 GB. List valid sizes with: az aksarc vmsize list --custom-location <custom-location-id>
    [string]$NodeVmSize = 'Standard_D4s_v3',
    [string]$KubernetesVersion = '1.33.5',

    [string]$AdminGroupName = 'azurelocal-aks-admins',

    # Free addresses the Arc load balancer hands out on the site network, outside the node pool,
    # as <first>-<last>. The app's ingress takes the first.
    [string]$LoadBalancerName = 'bcd-lb',
    [string]$LoadBalancerAddresses,

    # Public key installed on the nodes. Generated when missing.
    [string]$SshPublicKeyPath = (Join-Path $HOME '.ssh/id_rsa.pub'),

    # The kubeconfig context the cluster's admin credentials are written to.
    [Parameter(Mandatory = $true)][string]$KubeContext
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
Push-Location $repoRoot

# $ErrorActionPreference does not apply to native commands, so every external call is checked.
# Returns what the command printed.
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
    $networkPlan = [ordered]@{
        AddressPrefix = $AddressPrefix; Gateway = $Gateway; DnsServers = @($DnsServers) -join ','
        IpPoolStart = $IpPoolStart; IpPoolEnd = $IpPoolEnd; ControlPlaneIp = $ControlPlaneIp
        LoadBalancerAddresses = $LoadBalancerAddresses
    }
    $missing = @($networkPlan.Keys | Where-Object { [string]::IsNullOrWhiteSpace($networkPlan[$_]) -or $networkPlan[$_] -like '<*' })
    if ($missing) {
        throw "Set these in the Cluster section of scripts/settings.json, from your site's network plan: $($missing -join ', ')."
    }
    if (-not $VmSwitchName -and -not $SwitchSourceLogicalNetworkName) {
        throw 'Set VmSwitchName, or SwitchSourceLogicalNetworkName to a logical network whose switch the nodes share, in the Cluster section of scripts/settings.json.'
    }

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw "The az CLI is not on PATH."
    }

    Write-Host "==> Selecting subscription $SubscriptionId" -ForegroundColor Cyan
    Invoke-Checked 'az account set' { az account set --subscription $SubscriptionId }

    # Only for fetching the cluster credentials; the template needs no CLI extension.
    if (-not (Invoke-Checked 'az extension list' { az extension list --query "[?name=='aksarc'].version" --output tsv })) {
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
        $state = Invoke-Checked "az provider show $provider" { az provider show --namespace $provider --query registrationState --output tsv }
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
    $group = @((Invoke-Checked "looking up Entra group '$AdminGroupName'" {
                az rest --method get --url 'https://graph.microsoft.com/v1.0/groups' `
                    --url-parameters "`$filter=displayName eq '$AdminGroupName'" '$select=id,uniqueName' `
                    --query value --output json
            }) | ConvertFrom-Json) | Select-Object -First 1
    if ($group -and -not $group.uniqueName -and $PSCmdlet.ShouldProcess($AdminGroupName, 'Set uniqueName so Bicep manages the group')) {
        Write-Host "==> Adopting existing Entra group '$AdminGroupName'" -ForegroundColor Cyan
        $bodyFile = New-TemporaryFile
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
            Invoke-Checked 'ssh-keygen' { ssh-keygen -t rsa -b 4096 -N '' -q -f ($SshPublicKeyPath -replace '\.pub$', '') }
        }
    }
    $sshPublicKey = if (Test-Path $SshPublicKeyPath) { (Get-Content $SshPublicKeyPath -Raw).Trim() } else { '<generated>' }
    # The signed-in user joins the cluster's admin group; a service principal is added to it by hand.
    $accountType = Invoke-Checked 'az account show' { az account show --query user.type --output tsv }
    $signedInUserId = if ($accountType -eq 'user') { Invoke-Checked 'az ad signed-in-user show' { az ad signed-in-user show --query id --output tsv } }

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
    if ($PodCidr) { $parameters['podCidr'] = $PodCidr }
    $parametersDocument = [ordered]@{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = [ordered]@{}
    }
    foreach ($key in $parameters.Keys) { $parametersDocument.parameters[$key] = @{ value = $parameters[$key] } }
    # A temporary input, written even under -WhatIf so the what-if can read it.
    $parametersFile = New-TemporaryFile -WhatIf:$false
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
    $kubeconfigFile = Join-Path $HOME '.kube/config'
    Invoke-Checked 'az aksarc get-credentials' {
        az aksarc get-credentials --name $ClusterName --resource-group $ResourceGroup `
            --admin --context $KubeContext --file $kubeconfigFile --overwrite-existing
    }
    # The admin certificate's key: owner-only.
    if ($IsLinux -or $IsMacOS) { [IO.File]::SetUnixFileMode($kubeconfigFile, 'UserRead, UserWrite') }

    Write-Host "`n================ Platform ready ================" -ForegroundColor Green
    Write-Host "Resource group   : $ResourceGroup"
    Write-Host "Registry         : $registryLoginServer (Premium, data endpoint enabled)"
    Write-Host "Cluster          : $ClusterName (API $ControlPlaneIp)"
    Write-Host "Load balancer    : $LoadBalancerAddresses"
    Write-Host "Credentials      : $kubeconfigFile, context $KubeContext (admin certificate, works offline)"

    Write-Host "`nNext steps:" -ForegroundColor Yellow
    Write-Host "  1. ./scripts/infra/azurelocal/import-images.ps1 -Mode Mirror -Registry $registryLoginServer"
    Write-Host "  2. ./scripts/infra/azurelocal/connected-registry.ps1 -RegistryName $RegistryName -ResourceGroup $ResourceGroup -ClusterName $ClusterName -KubeContext $KubeContext -ServiceClusterIp <address>"
    Write-Host "  3. The remaining steps: ./scripts/setup-platform.ps1 -Target AzureLocal -Skip Cluster, Images, Registry"
}
finally {
    if ($parametersFile) { Remove-Item $parametersFile -Force -ErrorAction SilentlyContinue -WhatIf:$false }
    Pop-Location
}