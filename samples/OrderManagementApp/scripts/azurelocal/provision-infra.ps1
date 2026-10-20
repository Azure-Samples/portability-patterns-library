<#
.SYNOPSIS
    Provisions the connected Azure Local platform for the sample: resource group, Premium container
    registry, AKS admin group, AKS logical network and an AKS enabled by Arc cluster.

.DESCRIPTION
    Targets an Azure Local instance that is connected to public Azure. The Azure resources are
    declared in infra/azurelocal/platform.bicep; this script resolves the values the template needs
    from the existing Azure Local instance, deploys it, and fetches the cluster credentials.

    Everything the application owns lives in one resource group, 'bcd-azurelocal' by default,
    separate from the resource group that holds the Azure Local instance and its custom location.

    The registry is Premium because scripts/azurelocal/connected-registry.ps1 runs an ACR connected
    registry inside the cluster, so images and Recipes stay pullable when the Azure link drops.

    Cluster credentials are fetched with --admin: they authenticate with a client certificate
    directly against the API server, which keeps working with no Azure connectivity. Entra admin
    access through the 'azurelocal-aks-admins' group is configured for the connected case.

    Workload Identity / OIDC issuer are deliberately NOT enabled. Workloads authenticate to the
    in-cluster Keycloak with tokens from the cluster's own ServiceAccount issuer, which needs no
    Azure round trip.

    -WhatIf runs an Azure what-if of the template instead of deploying it, and changes nothing.

.EXAMPLE
    ./scripts/azurelocal/provision-infra.ps1 -RegistryName <acr-name>

.EXAMPLE
    # Preview what the template would change on an existing site.
    ./scripts/azurelocal/provision-infra.ps1 -RegistryName <acr-name> -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$SubscriptionId = '<subscription-id>',

    [ValidatePattern('^[a-z0-9]{5,50}$')]
    [string]$RegistryName = '<acr-name>',

    # Holds every resource this script creates. The Azure Local instance lives elsewhere.
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

    # Public key installed on the nodes. Generated when missing.
    [string]$SshPublicKeyPath = (Join-Path $HOME '.ssh/id_rsa.pub'),

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

$parametersFile = $null
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
        if ($PSCmdlet.ShouldProcess($provider, 'Register resource provider')) {
            Write-Host "    registering $provider ($state)" -ForegroundColor DarkGray
            Invoke-Checked "az provider register $provider" {
                az provider register --namespace $provider --wait --output none
            }
        }
    }

    # ------------------------------------------------------------------------------------------
    # Entra group granted cluster-admin through AKS Arc. Not needed offline (admin kubeconfig is).
    # Entra objects are outside ARM, so the group is created here rather than in the template.
    # ------------------------------------------------------------------------------------------
    Write-Host "==> Ensuring Entra group '$AdminGroupName'" -ForegroundColor Cyan
    $adminGroupId = Invoke-AzProbe @('ad', 'group', 'list', '--display-name', $AdminGroupName, '--query', '[0].id', '--output', 'tsv')
    if (-not $adminGroupId -and $PSCmdlet.ShouldProcess($AdminGroupName, 'Create Entra group')) {
        $adminGroupId = az ad group create --display-name $AdminGroupName --mail-nickname $AdminGroupName --query id --output tsv
        if ($LASTEXITCODE -ne 0 -or -not $adminGroupId) {
            throw "Could not create Entra group '$AdminGroupName'. Create it (or ask a tenant admin) and re-run."
        }
    }
    Write-Host "    $adminGroupId" -ForegroundColor DarkGray

    $userId = az ad signed-in-user show --query id --output tsv
    if ($adminGroupId -and $LASTEXITCODE -eq 0 -and $userId) {
        $isMember = Invoke-AzProbe @('ad', 'group', 'member', 'check', '--group', $adminGroupId, '--member-id', $userId, '--query', 'value', '--output', 'tsv')
        if ($isMember -ne 'true' -and $PSCmdlet.ShouldProcess($AdminGroupName, 'Add the signed-in user')) {
            Write-Host "    adding signed-in user to the group" -ForegroundColor DarkGray
            Invoke-Checked 'az ad group member add' {
                az ad group member add --group $adminGroupId --member-id $userId --output none
            }
        }
    }

    # ------------------------------------------------------------------------------------------
    # Values the template needs from the existing Azure Local instance.
    # ------------------------------------------------------------------------------------------
    Write-Host "==> Resolving custom location '$CustomLocationName'" -ForegroundColor Cyan
    $customLocationId = Invoke-AzProbe @('customlocation', 'show', '--resource-group', $PlatformResourceGroup, '--name', $CustomLocationName, '--query', 'id', '--output', 'tsv')
    if (-not $customLocationId) {
        throw "Custom location '$CustomLocationName' not found in '$PlatformResourceGroup'."
    }
    Write-Host "    $customLocationId" -ForegroundColor DarkGray

    Write-Host "==> Reading the VM switch from logical network '$InfraLogicalNetworkName'" -ForegroundColor Cyan
    $vmSwitchName = Invoke-AzProbe @('stack-hci-vm', 'network', 'lnet', 'show', '--resource-group', $PlatformResourceGroup, '--name', $InfraLogicalNetworkName, '--query', 'properties.vmSwitchName', '--output', 'tsv')
    if (-not $vmSwitchName) {
        throw "Could not read the VM switch name from logical network '$InfraLogicalNetworkName'."
    }
    Write-Host "    $vmSwitchName" -ForegroundColor DarkGray

    if (-not (Test-Path $SshPublicKeyPath)) {
        if (-not $SshPublicKeyPath.EndsWith('.pub')) { throw "-SshPublicKeyPath must point to a .pub file." }
        if ($PSCmdlet.ShouldProcess($SshPublicKeyPath, 'Generate SSH key pair')) {
            Write-Host "==> Generating SSH key pair $SshPublicKeyPath" -ForegroundColor Cyan
            New-Item -ItemType Directory -Force -Path (Split-Path $SshPublicKeyPath) | Out-Null
            Invoke-Checked 'ssh-keygen' { ssh-keygen -t rsa -b 4096 -N '""' -q -f ($SshPublicKeyPath -replace '\.pub$', '') }
        }
    }
    $sshPublicKey = if (Test-Path $SshPublicKeyPath) { (Get-Content $SshPublicKeyPath -Raw).Trim() } else { '<generated>' }

    # A parameters file keeps az.cmd and cmd.exe away from values such as switch names with
    # parentheses, and carries the arrays.
    $parameters = [ordered]@{
        location           = $Location
        resourceGroupName  = $ResourceGroup
        registryName       = $RegistryName
        customLocationId   = $customLocationId
        vmSwitchName       = $vmSwitchName
        logicalNetworkName = $LogicalNetworkName
        addressPrefix      = $AddressPrefix
        gateway            = $Gateway
        dnsServers         = @($DnsServers)
        ipPoolStart        = $IpPoolStart
        ipPoolEnd          = $IpPoolEnd
        vlan               = $Vlan
        clusterName        = $ClusterName
        controlPlaneIp     = $ControlPlaneIp
        controlPlaneCount  = $ControlPlaneCount
        controlPlaneVmSize = $ControlPlaneVmSize
        nodeCount          = $NodeCount
        nodeVmSize         = $NodeVmSize
        kubernetesVersion  = $KubernetesVersion
        sshPublicKey       = $sshPublicKey
        adminGroupObjectIds = @($adminGroupId | Where-Object { $_ })
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
    $outputs = $outputsJson | ConvertFrom-Json
    $registryLoginServer = $outputs.registryLoginServer.value

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
    if ($parametersFile) { Remove-Item $parametersFile -Force -ErrorAction SilentlyContinue -WhatIf:$false }
    Pop-Location
}