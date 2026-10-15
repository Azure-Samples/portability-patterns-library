<#
.SYNOPSIS
    Provisions the Azure Local platform infrastructure: resource group, container registry and an
    AKS enabled by Arc cluster.

.DESCRIPTION
    The Azure equivalent of this script (scripts/azure/provision-infra.ps1) is Bicep driven. This
    one is CLI driven on purpose:

      * AKS on Azure Local is Microsoft.HybridContainerService/provisionedClusterInstances, an
        EXTENSION resource on a Microsoft.Kubernetes/connectedClusters resource, always named
        'default'. Creating one in Bicep means orchestrating the connected cluster, the custom
        location and the logical network by hand. `az aksarc create` does that orchestration.

      * Azure Local with disconnected operations implements a SUBSET of ARM API versions, and which
        subset depends on the build. Pinned Bicep API versions that work against public Azure fail
        there. The CLI negotiates a version the local control plane actually serves.

    No managed identity is created. Disconnected operations support only system-assigned managed
    identity, so there is no user-assigned identity and no federated identity credential: the
    Workload Identity design used on AKS does not apply. See deploy/recipe-packs/aldo.bicep.

.PARAMETER CustomLocation
    Name or resource ID of the custom location produced by the Azure Local instance deployment.
    Discovered automatically when exactly one exists. Connectivity to public Azure is not required,
    but a custom location is: `az aksarc create` has no other way to place the cluster.

.PARAMETER LogicalNetworkId
    Resource ID of the logical network the cluster nodes attach to. Discovered automatically when
    exactly one exists. Disconnected operations does not create one for you; see
    `az stack-hci-vm network lnet create`.

.PARAMETER AllowPublicCloud
    Permit running against public Azure. Refused by default: this script is for Azure Local, and
    silently provisioning into public Azure is expensive and hard to notice.

.EXAMPLE
    ./lab/aldo/provision-infra.ps1 -SubscriptionId <sub-id> -RegistryName bcdaldoacr

.EXAMPLE
    # Explicit placement when the environment has several custom locations or networks.
    ./lab/aldo/provision-infra.ps1 `
        -SubscriptionId <sub-id> `
        -RegistryName bcdaldoacr `
        -CustomLocation my-custom-location `
        -LogicalNetworkId /subscriptions/.../logicalNetworks/my-lnet
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]{5,50}$')]
    [string]$RegistryName,

    [string]$ResourceGroup = 'bcd-infra',
    [string]$ClusterName = 'bcd-aks-arc',
    [string]$Location,

    [string]$CustomLocation,
    [string]$LogicalNetworkId,

    [int]$ControlPlaneCount = 1,
    [int]$NodeCount = 2,

    # Valid sizes are environment specific. List them with:
    #   az aksarc vmsize list --custom-location <custom-location>
    [string]$NodeVmSize = 'Standard_A4_v2',

    [string]$KubernetesVersion,

    # APIServer IP address. Must be routable from the Azure Resource Bridge appliance VM and belong
    # to the referenced logical network subnet; cluster creation fails or times out otherwise. Many
    # Azure Local deployments require it, so supply it if creation hangs.
    [string]$ControlPlaneIp,

    # Fetch cluster administrator credentials instead of identity-based ones. Try this if
    # `az aksarc get-credentials` produces a kubeconfig that cannot authenticate.
    [switch]$UseAdminCredentials,

    # Folder holding pre-downloaded .whl files for the required az CLI extensions. Needed on an
    # air-gapped machine, where `az extension add --name <x>` cannot reach the public extension
    # index. Download the wheels on a connected machine with:
    #   az extension list-available --show-details --query "<name>[-1].downloadUrl" -o tsv
    [string]$ExtensionSource,

    [ValidateSet('Basic', 'Standard', 'Premium')][string]$RegistrySku = 'Standard',

    [switch]$AllowPublicCloud,
    [switch]$SkipClusterCreate
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
# PowerShell turns redirected native stderr into a terminating error while $ErrorActionPreference
# is 'Stop', which would abort the script before a probe can report 'not found'.
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
    # ------------------------------------------------------------------------------------------
    # Guard against provisioning into public Azure by mistake.
    #
    # Azure Local with disconnected operations is reached by registering its local control plane as
    # an az CLI cloud and switching to it. If that has not been done, every command below would
    # silently target public Azure instead.
    # ------------------------------------------------------------------------------------------
    $cloudName = Invoke-AzProbe @('cloud', 'show', '--query', 'name', '--output', 'tsv')
    if (-not $cloudName) { throw "Could not read the active az CLI cloud. Run 'az login' first." }

    Write-Host "==> Active az CLI cloud: $cloudName" -ForegroundColor Cyan
    if ($cloudName -eq 'AzureCloud' -and -not $AllowPublicCloud) {
        throw @"
The az CLI is pointed at public Azure ('AzureCloud'), not an Azure Local control plane.

Register and select the local cloud first, for example:
  az cloud register --name AzureLocal --endpoint-resource-manager <local-arm-endpoint> ...
  az cloud set --name AzureLocal
  az login

Pass -AllowPublicCloud to override, only if you are deliberately rehearsing against public Azure.
"@
    }

    Write-Host "==> Checking required az CLI extensions" -ForegroundColor Cyan

    # The extensions below depend on 'cryptography', which publishes no 32-bit Windows wheels.
    $azPath = (Get-Command az -ErrorAction SilentlyContinue).Source
    if ($azPath -like '*Program Files (x86)*') {
        throw "The installed az CLI is 32-bit ('$azPath'). Extension installs will fail to build 'cryptography'. Reinstall the x64 build from https://aka.ms/installazurecliwindowsx64."
    }

    # Minimum versions documented for disconnected operations, treated as floors rather than pins:
    # the documented builds import 'msrestazure', which current az CLI releases no longer ship.
    # 'connectedk8s' is deliberately absent, since the cluster is Arc-enabled by the local control
    # plane rather than by connecting it to public Azure. 'stack-hci-vm' owns the lnet commands.
    $minimumExtensionVersions = [ordered]@{
        aksarc         = '1.2.23'
        customlocation = '0.1.4'
        'stack-hci-vm' = '1.11.1'
    }

    # All three exist only to create the cluster, so a registry-only run does not need them.
    if ($SkipClusterCreate) {
        $minimumExtensionVersions = [ordered]@{}
        Write-Host "    none required with -SkipClusterCreate" -ForegroundColor DarkGray
    }

    foreach ($extension in $minimumExtensionVersions.Keys) {
        $minimum = [version]$minimumExtensionVersions[$extension]

        # 'az extension show' writes to stderr when missing, which PowerShell surfaces as an error.
        $installed = az extension list --query "[?name=='$extension'].version" --output tsv
        if (-not [string]::IsNullOrWhiteSpace($installed)) {
            $installedVersion = $null
            [void][version]::TryParse($installed, [ref]$installedVersion)
            if ($installedVersion -and $installedVersion -ge $minimum) {
                Write-Host "    '$extension' present ($installed)" -ForegroundColor DarkGray
                continue
            }

            Write-Host "    updating '$extension' ($installed is below $minimum)" -ForegroundColor DarkGray
            Invoke-Checked "az extension update $extension" {
                az extension update --name $extension --only-show-errors
            }
            continue
        }

        # A folder with no readable version means a half-written install the CLI cannot load.
        $extensionRoot = if ($env:AZURE_EXTENSION_DIR) { $env:AZURE_EXTENSION_DIR } else { Join-Path $HOME '.azure/cliextensions' }
        $extensionPath = Join-Path $extensionRoot $extension
        if (Test-Path $extensionPath) {
            throw "The '$extension' extension at '$extensionPath' has no readable version and will fail to load. Remove the folder, or point AZURE_EXTENSION_DIR at a clean directory, then re-run."
        }

        if ($ExtensionSource) {
            # Air-gapped: install from a pre-downloaded wheel rather than the public index.
            $wheel = Get-ChildItem -Path $ExtensionSource -Filter "$extension-*.whl" -ErrorAction SilentlyContinue |
                Sort-Object Name | Select-Object -Last 1
            if (-not $wheel) {
                throw "No '$extension-*.whl' found in '$ExtensionSource'."
            }

            Write-Host "    installing '$extension' from $($wheel.Name)" -ForegroundColor DarkGray
            Invoke-Checked "az extension add $extension" {
                az extension add --source $wheel.FullName --only-show-errors
            }
            continue
        }

        $version = $minimumExtensionVersions[$extension]
        Write-Host "    installing '$extension' (minimum $version)" -ForegroundColor DarkGray
        az extension add --name $extension --only-show-errors
        if ($LASTEXITCODE -ne 0) {
            throw @"
Could not install the '$extension' az CLI extension.

On an air-gapped machine this is expected: `az extension add --name` fetches from the public
extension index, which is unreachable. Download the wheels on a connected machine...

  az extension list-available --show-details --query "$extension[-1].downloadUrl" -o tsv
  # then download that URL, repeating for aksarc, customlocation and stack-hci-vm

...copy them across, and re-run this script with -ExtensionSource <folder>.
"@
        }
    }

    if ($cloudName -ne 'AzureCloud') {
        # There is no Entra instance discovery endpoint to reach on a local control plane.
        az config set core.instance_discovery=false --only-show-errors | Out-Null
    }

    Invoke-Checked 'az account set' { az account set --subscription $SubscriptionId }

    # An unregistered provider is not an error: ARM simply returns nothing for its resource types,
    # so a missing registration looks identical to 'Azure Local has not been deployed yet'.
    Write-Host "==> Ensuring resource providers are registered" -ForegroundColor Cyan
    $providers = @(
        'Microsoft.ExtendedLocation'       # custom locations
        'Microsoft.HybridContainerService' # provisionedClusterInstances, used by az aksarc
        'Microsoft.AzureStackHCI'          # logical networks, used by az stack-hci-vm
        'Microsoft.ResourceConnector'      # Arc resource bridge appliance
        'Microsoft.HybridCompute'
        'Microsoft.HybridConnectivity'
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

    # Azure Local location names are environment specific, not Azure regions like 'eastus2'.
    if (-not $Location) {
        $Location = Invoke-AzProbe @('account', 'list-locations', '--query', '[0].name', '--output', 'tsv')
        if (-not $Location) {
            throw 'Could not determine a location. Pass -Location explicitly.'
        }
        Write-Host "==> Using location '$Location'" -ForegroundColor Cyan
    }

    Write-Host "==> Ensuring resource group '$ResourceGroup'" -ForegroundColor Cyan
    Invoke-Checked 'az group create' {
        az group create --name $ResourceGroup --location $Location --output none
    }

    Write-Host "==> Ensuring container registry '$RegistryName'" -ForegroundColor Cyan
    $registryLoginServer = Invoke-AzProbe @('acr', 'show', '--name', $RegistryName, '--resource-group', $ResourceGroup, '--query', 'loginServer', '--output', 'tsv')
    if (-not $registryLoginServer) {
        Invoke-Checked 'az acr create' {
            az acr create --name $RegistryName --resource-group $ResourceGroup `
                --sku $RegistrySku --location $Location --output none
        }
        $registryLoginServer = az acr show --name $RegistryName --resource-group $ResourceGroup --query loginServer --output tsv
    }
    # Read the login server rather than assuming '.azurecr.io': Azure Local serves its own domain.
    Write-Host "    $registryLoginServer" -ForegroundColor DarkGray

    if (-not $SkipClusterCreate) {
        # The custom location comes from the Azure Local instance deployment and the logical network
        # is created with 'az stack-hci-vm network lnet create'; this script creates neither.
        if ($CustomLocation -notlike '/subscriptions/*') {
            Write-Host "==> Discovering custom location" -ForegroundColor Cyan

            $customLocationsJson = Invoke-AzProbe @('customlocation', 'list', '--query', '[].{name:name, id:id}', '--output', 'json')
            if (-not $customLocationsJson) {
                # The extension calls an API version the local control plane may not serve.
                $customLocationsJson = Invoke-AzProbe @('resource', 'list', '--resource-type', 'Microsoft.ExtendedLocation/customLocations', '--query', '[].{name:name, id:id}', '--output', 'json')
            }

            # A JMESPath projection over an empty result yields literal 'null', and @($null) has a
            # count of one, so discard entries that carry no id.
            $customLocations = @()
            if ($customLocationsJson) {
                $customLocations = @($customLocationsJson | ConvertFrom-Json | Where-Object { $_.id })
            }

            if ($CustomLocation) {
                $customLocations = @($customLocations | Where-Object { $_.name -eq $CustomLocation })
            }

            if ($customLocations.Count -eq 0) {
                throw @"
No custom location found in subscription '$SubscriptionId'.

Connectivity to public Azure is NOT required for disconnected operations, but a custom location is:
it is the only way 'az aksarc create' can place the cluster. The custom location is produced by the
Azure Local instance deployment (Arc resource bridge plus the AKS extension) against the local
control plane, so this script cannot create it.

Check whether the appliance can provision clusters at all:
  Get-ChildItem C:\azurelocal\PlatformExtensionPacks

If that lists an 'arcenabledkubernetesagents' pack but nothing for HybridContainerService, then this
appliance only supports attaching an existing cluster. Use lab/aldo/arc-k3s.ps1 instead,
and re-run this script with -SkipClusterCreate for the resource group and registry.

Otherwise the custom location may live outside the Starter subscription:
  az account list --query "[].name" --output tsv
  az resource list --subscription "<name>" --resource-type Microsoft.ExtendedLocation/customLocations --output table
"@
            }
            if ($customLocations.Count -gt 1) {
                $names = ($customLocations | ForEach-Object { $_.name }) -join ', '
                throw "Several custom locations exist ($names). Pass -CustomLocation explicitly."
            }
            $CustomLocation = $customLocations[0].id
            Write-Host "    $($customLocations[0].name)" -ForegroundColor DarkGray
        }

        if (-not $LogicalNetworkId) {
            Write-Host "==> Discovering logical network" -ForegroundColor Cyan
            $networksJson = Invoke-AzProbe @('stack-hci-vm', 'network', 'lnet', 'list', '--query', '[].{name:name, id:id}', '--output', 'json')
            $networks = @()
            if ($networksJson) {
                $networks = @($networksJson | ConvertFrom-Json | Where-Object { $_.id })
            }

            if ($networks.Count -eq 0) {
                throw @"
No logical network found in subscription '$SubscriptionId'.

Disconnected operations does not create one for you. Create it against the custom location, using
values from the host's network configuration, then re-run with -LogicalNetworkId:

  az stack-hci-vm network lnet create --resource-group $ResourceGroup --location $Location --name aksarc-lnet-static --custom-location "$CustomLocation" --vm-switch-name <switch> --ip-allocation-method Static --address-prefixes <cidr> --gateway <gateway> --dns-servers <dns> --ip-pool-start <start> --ip-pool-end <end>

Keep the pool range clear of the address passed as -ControlPlaneIp.
"@
            }
            if ($networks.Count -gt 1) {
                $names = ($networks | ForEach-Object { $_.name }) -join ', '
                throw "Several logical networks exist ($names). Pass -LogicalNetworkId explicitly."
            }
            $LogicalNetworkId = $networks[0].id
            Write-Host "    $($networks[0].name)" -ForegroundColor DarkGray
        }

        $existingCluster = Invoke-AzProbe @('aksarc', 'show', '--name', $ClusterName, '--resource-group', $ResourceGroup, '--query', 'name', '--output', 'tsv')
        if (-not $existingCluster) {
            Write-Host "==> Creating AKS Arc cluster '$ClusterName' (this takes a while)" -ForegroundColor Cyan

            $createArgs = @(
                'aksarc', 'create',
                '--name', $ClusterName,
                '--resource-group', $ResourceGroup,
                '--custom-location', $CustomLocation,
                '--vnet-ids', $LogicalNetworkId,
                '--control-plane-count', $ControlPlaneCount,
                '--node-count', $NodeCount,
                '--node-vm-size', $NodeVmSize,
                '--generate-ssh-keys'
            )
            if ($KubernetesVersion) { $createArgs += @('--kubernetes-version', $KubernetesVersion) }
            if ($ControlPlaneIp) { $createArgs += @('--control-plane-ip', $ControlPlaneIp) }

            # Note for CONNECTED Azure Local: az aksarc create also accepts --enable-oidc-issuer
            # and --enable-workload-identity, so the Entra Workload Identity design used on AKS is
            # available there. They are deliberately not set here: disconnected operations have no
            # Entra tenant to federate against.
            Invoke-Checked 'az aksarc create' { az @createArgs --output none }
        }
        else {
            Write-Host "==> Cluster '$ClusterName' already exists" -ForegroundColor DarkGray
        }
    }

    # Set the context name explicitly rather than relying on the default, so the value handed to
    # deploy.ps1 below is known to be correct.
    $kubeContext = $ClusterName

    if (-not $SkipClusterCreate) {
        Write-Host "==> Fetching cluster credentials" -ForegroundColor Cyan
        $credentialArgs = @(
            'aksarc', 'get-credentials',
            '--name', $ClusterName,
            '--resource-group', $ResourceGroup,
            '--context', $kubeContext,
            '--overwrite-existing'
        )
        if ($UseAdminCredentials) { $credentialArgs += '--admin' }

        Invoke-Checked 'az aksarc get-credentials' { az @credentialArgs }

        Invoke-Checked 'kubectl cluster-info' {
            kubectl cluster-info --context $kubeContext --request-timeout=30s | Out-Null
        }
    }

    Write-Host "`n================ Platform ready ================" -ForegroundColor Green
    Write-Host "Cloud            : $cloudName"
    Write-Host "Resource group   : $ResourceGroup"
    Write-Host "Location         : $Location"
    Write-Host "Registry         : $registryLoginServer"
    if ($SkipClusterCreate) {
        Write-Host "Cluster          : not created (-SkipClusterCreate)"
        $kubeContext = '<your-cluster-context>'
    }
    else {
        Write-Host "Cluster          : $ClusterName"
        Write-Host "kubectl context  : $kubeContext"
    }
    Write-Host ""
    Write-Host "No managed identity was created: disconnected operations support only system-assigned"
    Write-Host "managed identity, so the workers use credentials issued by the Recipes."

    Write-Host "`nNext steps:" -ForegroundColor Yellow
    Write-Host "  1. Move every image into the registry. Public registries are unreachable, so this"
    Write-Host "     includes the Radius control plane itself:"
    Write-Host "     ./scripts/azurelocal/import-images.ps1 -Mode Mirror -Registry $registryLoginServer"
    Write-Host "     (air-gapped: -Mode Export on a connected machine, then -Mode Import here)"
    Write-Host "  2. Deploy:"
    Write-Host "     ./lab/aldo/deploy.ps1 ``"
    Write-Host "         -Registry $registryLoginServer ``"
    Write-Host "         -KubeContext $kubeContext"
}
finally {
    Pop-Location
}
