<#
.SYNOPSIS
    Provisions the connected Azure Local platform for the demo: resource group, Premium container
    registry, AKS admin group, AKS logical network and an AKS enabled by Arc cluster.

.DESCRIPTION
    Targets an Azure Local instance that is connected to public Azure. Everything the application
    owns lives in one resource group,
    'bcd-azurelocal' by default, separate from the resource group that holds the Azure Local
    instance and its custom location.

    CLI driven because AKS Arc is an extension resource on a connected cluster, and
    'az aksarc create' orchestrates that.

    The registry is Premium because scripts/azurelocal/connected-registry.ps1 runs an ACR connected
    registry inside the cluster, so images and Recipes stay pullable when the Azure link drops.

    Cluster credentials are fetched with --admin: they authenticate with a client certificate
    directly against the API server, which keeps working with no Azure connectivity. Entra admin
    access through the 'azurelocal-aks-admins' group is configured for the connected case.

    Workload Identity / OIDC issuer are deliberately NOT enabled. Workloads authenticate to the
    in-cluster Keycloak with tokens from the cluster's own ServiceAccount issuer, which needs no
    Azure round trip.

.EXAMPLE
    ./scripts/azurelocal/provision-infra.ps1 -RegistryName <acr-name>
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId = '<subscription-id>',

    [ValidatePattern('^[a-z0-9]{5,50}$')]
    [string]$RegistryName = '<acr-name>',

    # Holds every resource this demo creates. The Azure Local instance lives elsewhere.
    [string]$ResourceGroup = 'bcd-azurelocal',
    [string]$Location = 'eastus',

    # Resource group and name of the custom location created with the Azure Local instance.
    [string]$PlatformResourceGroup = 'azurelocal-lab-rg',
    [string]$CustomLocationName = 'azlocal-lab-cl',

    # Existing logical network the VM switch name is copied from.
    [string]$InfraLogicalNetworkName = 'azlocal-lab-InfraLNET',

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

    [string]$KubeContext = 'bcd-aksarc'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
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

# Runs an 'az' command that is allowed to fail and returns its output, or $null.
function Invoke-AzProbe {
    param([Parameter(Mandatory = $true)][string[]]$AzArgs)

    $ErrorActionPreference = 'Continue'

    $output = az @AzArgs 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }

    $text = ($output | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text
}

try {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw "The az CLI is not on PATH."
    }

    Write-Host "==> Selecting subscription $SubscriptionId" -ForegroundColor Cyan
    Invoke-Checked 'az account set' { az account set --subscription $SubscriptionId }

    Write-Host "==> Checking required az CLI extensions" -ForegroundColor Cyan
    foreach ($extension in @('aksarc', 'stack-hci-vm', 'customlocation', 'k8s-extension', 'connectedk8s')) {
        $installed = az extension list --query "[?name=='$extension'].version" --output tsv
        if ([string]::IsNullOrWhiteSpace($installed)) {
            Write-Host "    installing '$extension'" -ForegroundColor DarkGray
            Invoke-Checked "az extension add $extension" { az extension add --name $extension --only-show-errors }
        }
        else {
            Write-Host "    '$extension' present ($installed)" -ForegroundColor DarkGray
        }
    }

    Write-Host "==> Ensuring resource providers are registered" -ForegroundColor Cyan
    $providers = @(
        'Microsoft.ExtendedLocation'
        'Microsoft.HybridContainerService'
        'Microsoft.AzureStackHCI'
        'Microsoft.Kubernetes'
        'Microsoft.KubernetesConfiguration'
        'Microsoft.ContainerRegistry'
    )
    foreach ($provider in $providers) {
        $state = Invoke-AzProbe @('provider', 'show', '--namespace', $provider, '--query', 'registrationState', '--output', 'tsv')
        if ($state -eq 'Registered') {
            Write-Host "    $provider registered" -ForegroundColor DarkGray
            continue
        }
        Write-Host "    registering $provider ($state)" -ForegroundColor DarkGray
        Invoke-Checked "az provider register $provider" {
            az provider register --namespace $provider --wait --output none
        }
    }

    Write-Host "==> Ensuring resource group '$ResourceGroup'" -ForegroundColor Cyan
    Invoke-Checked 'az group create' {
        az group create --name $ResourceGroup --location $Location --output none
    }

    # ------------------------------------------------------------------------------------------
    # Premium registry with a dedicated data endpoint: both are prerequisites of connected registry.
    # ------------------------------------------------------------------------------------------
    Write-Host "==> Ensuring container registry '$RegistryName' (Premium)" -ForegroundColor Cyan
    $registryLoginServer = Invoke-AzProbe @('acr', 'show', '--name', $RegistryName, '--resource-group', $ResourceGroup, '--query', 'loginServer', '--output', 'tsv')
    if (-not $registryLoginServer) {
        $available = Invoke-AzProbe @('acr', 'check-name', '--name', $RegistryName, '--query', 'nameAvailable', '--output', 'tsv')
        if ($available -ne 'true') {
            throw "Registry name '$RegistryName' is not available. Pass a different -RegistryName."
        }
        Invoke-Checked 'az acr create' {
            az acr create --name $RegistryName --resource-group $ResourceGroup `
                --sku Premium --location $Location --output none
        }
        $registryLoginServer = az acr show --name $RegistryName --resource-group $ResourceGroup --query loginServer --output tsv
    }
    else {
        $sku = az acr show --name $RegistryName --resource-group $ResourceGroup --query sku.name --output tsv
        if ($sku -ne 'Premium') {
            Write-Host "    upgrading SKU $sku -> Premium" -ForegroundColor DarkGray
            Invoke-Checked 'az acr update --sku' { az acr update --name $RegistryName --sku Premium --output none }
        }
    }
    Write-Host "    $registryLoginServer" -ForegroundColor DarkGray

    $dataEndpoint = az acr show --name $RegistryName --query dataEndpointEnabled --output tsv
    if ($dataEndpoint -ne 'true') {
        Write-Host "    enabling dedicated data endpoint" -ForegroundColor DarkGray
        Invoke-Checked 'az acr update --data-endpoint-enabled' {
            az acr update --name $RegistryName --data-endpoint-enabled true --output none
        }
    }

    # ------------------------------------------------------------------------------------------
    # Entra group granted cluster-admin through AKS Arc. Not needed offline (admin kubeconfig is).
    # ------------------------------------------------------------------------------------------
    Write-Host "==> Ensuring Entra group '$AdminGroupName'" -ForegroundColor Cyan
    $adminGroupId = Invoke-AzProbe @('ad', 'group', 'list', '--display-name', $AdminGroupName, '--query', '[0].id', '--output', 'tsv')
    if (-not $adminGroupId) {
        $adminGroupId = az ad group create --display-name $AdminGroupName --mail-nickname $AdminGroupName --query id --output tsv
        if ($LASTEXITCODE -ne 0 -or -not $adminGroupId) {
            throw "Could not create Entra group '$AdminGroupName'. Create it (or ask a tenant admin) and re-run."
        }
    }
    Write-Host "    $adminGroupId" -ForegroundColor DarkGray

    $userId = az ad signed-in-user show --query id --output tsv
    if ($LASTEXITCODE -eq 0 -and $userId) {
        $isMember = Invoke-AzProbe @('ad', 'group', 'member', 'check', '--group', $adminGroupId, '--member-id', $userId, '--query', 'value', '--output', 'tsv')
        if ($isMember -ne 'true') {
            Write-Host "    adding signed-in user to the group" -ForegroundColor DarkGray
            Invoke-Checked 'az ad group member add' {
                az ad group member add --group $adminGroupId --member-id $userId --output none
            }
        }
    }

    # ------------------------------------------------------------------------------------------
    # AKS logical network on the same VM switch as the infrastructure network.
    # ------------------------------------------------------------------------------------------
    Write-Host "==> Resolving custom location '$CustomLocationName'" -ForegroundColor Cyan
    $customLocationId = Invoke-AzProbe @('customlocation', 'show', '--resource-group', $PlatformResourceGroup, '--name', $CustomLocationName, '--query', 'id', '--output', 'tsv')
    if (-not $customLocationId) {
        throw "Custom location '$CustomLocationName' not found in '$PlatformResourceGroup'."
    }
    Write-Host "    $customLocationId" -ForegroundColor DarkGray

    Write-Host "==> Ensuring logical network '$LogicalNetworkName'" -ForegroundColor Cyan
    $logicalNetworkId = Invoke-AzProbe @('stack-hci-vm', 'network', 'lnet', 'show', '--resource-group', $ResourceGroup, '--name', $LogicalNetworkName, '--query', 'id', '--output', 'tsv')
    if (-not $logicalNetworkId) {
        $vmSwitchName = Invoke-AzProbe @('stack-hci-vm', 'network', 'lnet', 'show', '--resource-group', $PlatformResourceGroup, '--name', $InfraLogicalNetworkName, '--query', 'properties.vmSwitchName', '--output', 'tsv')
        if (-not $vmSwitchName) {
            throw "Could not read the VM switch name from logical network '$InfraLogicalNetworkName'."
        }
        Write-Host "    VM switch: $vmSwitchName" -ForegroundColor DarkGray

        $lnetArgs = @(
            'stack-hci-vm', 'network', 'lnet', 'create',
            '--resource-group', $ResourceGroup,
            '--location', $Location,
            '--custom-location', $customLocationId,
            '--name', $LogicalNetworkName,
            # az.cmd routes arguments through cmd.exe, which chokes on the parentheses in names like
            # 'ConvergedSwitch(compute_management_storage)' unless they are quoted.
            '--vm-switch-name', ('"{0}"' -f $vmSwitchName),
            '--ip-allocation-method', 'Static',
            '--address-prefixes', $AddressPrefix,
            '--gateway', $Gateway,
            '--ip-pool-start', $IpPoolStart,
            '--ip-pool-end', $IpPoolEnd,
            '--vlan', $Vlan,
            '--dns-servers'
        ) + $DnsServers
        Invoke-Checked 'az stack-hci-vm network lnet create' { az @lnetArgs --output none }
        $logicalNetworkId = az stack-hci-vm network lnet show --resource-group $ResourceGroup --name $LogicalNetworkName --query id --output tsv
    }
    Write-Host "    $logicalNetworkId" -ForegroundColor DarkGray

    # ------------------------------------------------------------------------------------------
    # AKS enabled by Arc cluster.
    # ------------------------------------------------------------------------------------------
    $existingCluster = Invoke-AzProbe @('aksarc', 'show', '--name', $ClusterName, '--resource-group', $ResourceGroup, '--query', 'properties.provisioningState', '--output', 'tsv')
    if (-not $existingCluster) {
        Write-Host "==> Creating AKS Arc cluster '$ClusterName' (this takes 20-40 minutes)" -ForegroundColor Cyan
        $createArgs = @(
            'aksarc', 'create',
            '--name', $ClusterName,
            '--resource-group', $ResourceGroup,
            '--location', $Location,
            '--custom-location', $customLocationId,
            '--vnet-ids', $logicalNetworkId,
            '--control-plane-ip', $ControlPlaneIp,
            '--control-plane-count', $ControlPlaneCount,
            '--control-plane-vm-size', $ControlPlaneVmSize,
            '--node-count', $NodeCount,
            '--node-vm-size', $NodeVmSize,
            '--kubernetes-version', $KubernetesVersion,
            '--aad-admin-group-object-ids', $adminGroupId,
            '--generate-ssh-keys'
        )
        Invoke-Checked 'az aksarc create' { az @createArgs --output none }
    }
    else {
        Write-Host "==> Cluster '$ClusterName' already exists ($existingCluster)" -ForegroundColor DarkGray
        if ($existingCluster -ne 'Succeeded') {
            throw "Cluster '$ClusterName' is in state '$existingCluster'. Resolve that before continuing."
        }
    }

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
    Write-Host "Logical network  : $LogicalNetworkName"
    Write-Host "Cluster          : $ClusterName (API $ControlPlaneIp)"
    Write-Host "kubectl context  : $KubeContext (admin certificate, works offline)"
    Write-Host "Service CIDR hint: kubernetes service is $kubernetesServiceIp"

    Write-Host "`nNext steps:" -ForegroundColor Yellow
    Write-Host "  1. ./scripts/azurelocal/import-images.ps1 -Mode Mirror -Registry $registryLoginServer"
    Write-Host "  2. ./scripts/azurelocal/connected-registry.ps1 -RegistryName $RegistryName -KubeContext $KubeContext"
}
finally {
    Pop-Location
}
