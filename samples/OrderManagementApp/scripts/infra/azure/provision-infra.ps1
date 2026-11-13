<#
.SYNOPSIS
    Layer 0: provisions the Azure platform infrastructure for the Order Management sample.

.DESCRIPTION
    Creates the resource group, container registry, AKS cluster (OIDC issuer + workload identity),
    the AcrPull role assignment for the kubelet, a user-assigned managed identity per service with its
    federated identity credential, the database-administrator identity, and Application Insights
    with alert rules -- all declaratively, through infra/azure/platform.bicep.

    It then performs the imperative follow-up that has no declarative equivalent:
      * fetches cluster credentials as context -KubeContext
      * creates the application namespace and the annotated service account of the database setup
        job (the services' own service accounts come from the container Recipe)
      * installs the Radius control plane

    Run this once per environment. It is idempotent, so re-running it is safe, and it takes no
    interactive input, so an Azure DevOps AzureCLI@2 task can call it unchanged.

    Requires Owner or User Access Administrator on the subscription, because it creates role
    assignments. That is why it is separate from the per-commit application deployment.

.PARAMETER WhatIf
    Runs `az deployment sub what-if` and stops, without changing anything.

.EXAMPLE
    # Usually run by setup-platform.ps1 with the Common and Cluster sections of scripts/settings.json. On its own:
    ./scripts/infra/azure/provision-infra.ps1 -SubscriptionId <sub-id> -ResourceGroup <resource-group> `
        -ClusterName <cluster> -KubeContext <cluster> -RegistryName <acr-name>

.EXAMPLE
    ./scripts/infra/azure/provision-infra.ps1 <the same parameters> -WhatIf
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]{5,50}$')]
    [string]$RegistryName,

    # Region and VM size are related: the sizes a subscription may use differ per region. This
    # pairing is verified to pass AKS preflight; re-run with -WhatIf after changing either.
    [string]$Location = 'eastus2',
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [Parameter(Mandatory = $true)][string]$ClusterName,
    # The kubeconfig context the cluster's credentials are written to.
    [Parameter(Mandatory = $true)][string]$KubeContext,
    [string]$IdentityPrefix = 'id-oms',
    [string[]]$WorkloadNames = @('api', 'processor', 'inventory'),
    [string]$DatabaseAdminServiceAccountName = 'dbsetup',
    [string]$AlertEmail = '',
    [string]$RadiusIdentityName = 'bcd-radius-identity',
    [string]$AppNamespace = 'oms-azure',
    # Radius workspace bound to the AKS cluster. Radius CLI commands target the workspace's
    # Kubernetes context, which is NOT necessarily the current kubectl context, so this must exist
    # before any `rad` command that talks to the control plane.
    [string]$WorkspaceName = 'oms-azure',
    [int]$NodeCount = 2,
    [string]$NodeVmSize = 'Standard_D4s_v7',
    [ValidateSet('Basic', 'Standard', 'Premium')][string]$RegistrySku = 'Standard',

    # Private endpoints for Blob Storage, Azure SQL and PostgreSQL: private DNS zones here, the
    # endpoints from the Recipes. Takes effect, both ways, on the next deploy.ps1 run.
    [bool]$UsePrivateEndpoints = $false,

    # Resource ID of a hub virtual network in the same subscription to peer the cluster's with.
    [string]$HubVirtualNetworkId = '',

    # Address ranges, fixed for the life of the cluster. None may overlap another, the hub, or a
    # network reached over VPN or ExpressRoute; this script checks them against each other and the
    # hub. The node and private endpoint subnets are the first two /24s of the virtual network, and
    # the DNS service address the tenth of the service range, unless given.
    [string]$VirtualNetworkAddressPrefix = '10.224.0.0/16',
    [string]$PodCidr = '10.244.0.0/16',
    [string]$ServiceCidr = '10.0.0.0/16',
    [string]$DnsServiceIP = '',

    # Entra ID object IDs granted cluster-admin. Defaults to the signed-in user, which is required
    # because local accounts are disabled and nobody could otherwise reach the API server.
    [string[]]$ClusterAdminObjectIds,

    # Disabling this reverts to certificate-based local accounts, which most org policies prohibit.
    [bool]$UseEntraAuthentication = $true,

    # ServiceAccount the Radius CLI authenticates as. Needed because an Entra user token carries
    # too many group headers for the Kubernetes aggregated API proxy (HTTP 431).
    [string]$RadiusCliServiceAccount = 'radius-cli',

    [switch]$SkipRadiusInstall,

    # The platform template is already deployed (for example by azd up). Skips the deployment and
    # does only the steps inside the cluster.
    [switch]$SkipTemplate,
    [switch]$WhatIf
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

<#
    Writes an ARM-format parameter file. Required because `--parameters key=value` only handles
    scalars: arrays and booleans passed that way are rejected or coerced to strings.
#>
function New-ParameterFile {
    param([Parameter(Mandatory = $true)][hashtable]$Values)

    $parameters = @{}
    foreach ($key in $Values.Keys) {
        $parameters[$key] = @{ value = $Values[$key] }
    }

    $document = @{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = $parameters
    }

    $file = New-TemporaryFile
    $path = "$($file.FullName).json"
    Move-Item $file $path
    # Windows PowerShell's 'utf8' encoding emits a BOM, which the JSON parsers behind the az and
    # rad CLIs both reject.
    [System.IO.File]::WriteAllText($path, ($document | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
    return $path
}

try {
    $template = 'infra/azure/platform.bicep'
    $deploymentName = "bcd-infra-$(Get-Date -Format 'yyyyMMddHHmmss')"
    $parameterFile = $null

    Write-Host "==> Selecting subscription $SubscriptionId" -ForegroundColor Cyan
    az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) { throw "Could not select subscription $SubscriptionId. Run 'az login' first." }

    if ($UseEntraAuthentication) {
        # Local accounts are disabled, so the API server only accepts Entra ID tokens. kubectl needs
        # kubelogin to obtain them; without it every kubectl call fails after the cluster is created.
        if (-not (Get-Command kubelogin -ErrorAction SilentlyContinue)) {
            throw "kubelogin is required when local accounts are disabled. Install it with 'az aks install-cli', or re-run with -UseEntraAuthentication `$false."
        }

        if (-not $ClusterAdminObjectIds -or $ClusterAdminObjectIds.Count -eq 0) {
            Write-Host "==> Resolving the signed-in user for cluster admin access" -ForegroundColor Cyan
            $signedInUserId = az ad signed-in-user show --query id --output tsv
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($signedInUserId)) {
                throw 'Could not resolve the signed-in user. Pass -ClusterAdminObjectIds explicitly.'
            }
            $ClusterAdminObjectIds = @($signedInUserId)
            Write-Host "    $signedInUserId" -ForegroundColor DarkGray
        }
    }

    # Arrays cannot be passed as key=value, so every parameter goes through a file.
    if ($SkipTemplate) {
        # The template was deployed by someone else, for example azd. Read what the rest of this
        # script needs from the resources themselves.
        Write-Host "==> Reading the platform resources in '$ResourceGroup'" -ForegroundColor Cyan
        $registryLoginServer = Invoke-Checked "az acr show $RegistryName" {
            az acr show --name $RegistryName --query loginServer --output tsv
        }
        $databaseAdminClientId = Invoke-Checked "az identity show $IdentityPrefix-db-admin" {
            az identity show --resource-group $ResourceGroup --name "$IdentityPrefix-db-admin" --query clientId --output tsv
        }
        $radiusClientId = Invoke-Checked "az identity show $RadiusIdentityName" {
            az identity show --resource-group $ResourceGroup --name $RadiusIdentityName --query clientId --output tsv
        }
        $oidcIssuer = Invoke-Checked "az aks show $ClusterName" {
            az aks show --resource-group $ResourceGroup --name $ClusterName --query oidcIssuerProfile.issuerUrl --output tsv
        }
    }
    else {
        . (Join-Path $repoRoot 'scripts/lib/network.ps1')
        Assert-OmsAddressRanges -VirtualNetworkAddressPrefix $VirtualNetworkAddressPrefix -PodCidr $PodCidr `
            -ServiceCidr $ServiceCidr -HubVirtualNetworkId $HubVirtualNetworkId

        $parameterFile = New-ParameterFile @{
            location                        = $Location
            resourceGroupName               = $ResourceGroup
            clusterName                     = $ClusterName
            registryName                    = $RegistryName
            identityPrefix                  = $IdentityPrefix
            workloadNames                   = @($WorkloadNames)
            databaseAdminServiceAccountName = $DatabaseAdminServiceAccountName
            alertEmail                      = $AlertEmail
            radiusIdentityName              = $RadiusIdentityName
            appNamespace                    = $AppNamespace
            nodeCount                       = $NodeCount
            nodeVmSize                      = $NodeVmSize
            registrySku                     = $RegistrySku
            clusterAdminObjectIds           = @($ClusterAdminObjectIds)
            useEntraAuthentication          = $UseEntraAuthentication
            usePrivateEndpoints             = $UsePrivateEndpoints
            hubVirtualNetworkId             = $HubVirtualNetworkId
            virtualNetworkAddressPrefix     = $VirtualNetworkAddressPrefix
            podCidr                         = $PodCidr
            serviceCidr                     = $ServiceCidr
            dnsServiceIP                    = $DnsServiceIP
        }

        if ($WhatIf) {
            Write-Host "==> Previewing changes (what-if). Nothing is created." -ForegroundColor Cyan
            Invoke-Checked 'az deployment sub what-if' {
                az deployment sub what-if --location $Location --template-file $template --parameters "@$parameterFile"
            }
            return
        }

        Write-Host "==> Deploying platform infrastructure (this typically takes 5-10 minutes)" -ForegroundColor Cyan
        $outputsJson = az deployment sub create `
            --name $deploymentName `
            --location $Location `
            --template-file $template `
            --parameters "@$parameterFile" `
            --query properties.outputs --output json
        if ($LASTEXITCODE -ne 0) {
            # A deployment's failed operations carry the errors of the resources that failed, nested
            # deployments included. A template rejected before deploying has none; az printed why.
            Write-Host "==> Deployment '$deploymentName' failed. Its failed operations:" -ForegroundColor Yellow
            az deployment operation sub list --name $deploymentName --output json `
                --query "[?properties.provisioningState=='Failed'].{resource: properties.targetResource.id, error: properties.statusMessage.error}"
            if ($LASTEXITCODE -ne 0) { Write-Host '    none: Azure rejected the template before deploying it, for the reason above.' -ForegroundColor Yellow }
            throw 'Infrastructure deployment failed.'
        }
        $outputs = $outputsJson | ConvertFrom-Json

        $registryLoginServer = $outputs.registryLoginServer.value
        $databaseAdminClientId = $outputs.databaseAdminClientId.value
        $radiusClientId = $outputs.radiusIdentityClientId.value
        $oidcIssuer = $outputs.oidcIssuerUrl.value
    }
    $tenantId = Invoke-Checked 'az account show' { az account show --query tenantId --output tsv }

    Write-Host "==> Fetching cluster credentials as context '$KubeContext'" -ForegroundColor Cyan
    Invoke-Checked 'az aks get-credentials' {
        az aks get-credentials --resource-group $ResourceGroup --name $ClusterName --context $KubeContext --overwrite-existing
    }

    if ($UseEntraAuthentication) {
        # With Entra authentication the kubeconfig uses an exec plugin. Converting it to the
        # azurecli login mode reuses the existing `az login` token instead of prompting for a device
        # code on every kubectl call.
        Write-Host "==> Converting kubeconfig for Entra ID authentication" -ForegroundColor Cyan
        Invoke-Checked 'kubelogin convert-kubeconfig' {
            kubelogin convert-kubeconfig -l azurecli --context $KubeContext
        }
    }

    # The database setup job runs outside the Radius application, so its service account is created
    # here. Its name and namespace must match the federated credential subject exactly. The services'
    # own service accounts are created by the container Recipe, from the client IDs in the Recipe Pack.
    Write-Host "==> Creating namespace and the database setup job's service account" -ForegroundColor Cyan
    @"
apiVersion: v1
kind: Namespace
metadata:
  name: $AppNamespace
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $DatabaseAdminServiceAccountName
  namespace: $AppNamespace
  annotations:
    azure.workload.identity/client-id: $databaseAdminClientId
    azure.workload.identity/tenant-id: $tenantId
  labels:
    azure.workload.identity/use: "true"
"@ | kubectl apply --context $KubeContext -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Creating namespace '$AppNamespace' and its database setup service account failed." }

    if (-not $SkipRadiusInstall) {
        # The Radius CLI needs an identity with no Entra groups, or the Kubernetes aggregated API
        # proxy rejects its requests with HTTP 431, including the readiness check at the end of
        # `rad install`. See ensure-radius-context.ps1 for the detail.
        $radiusContext = $KubeContext
        $installBinding = $null
        if ($UseEntraAuthentication) {
            $radiusContext = ./scripts/lib/ensure-radius-context.ps1 -KubeContext $KubeContext -ServiceAccountName $RadiusCliServiceAccount
            # 'rad install' creates cluster-wide objects, so the CLI's ServiceAccount is cluster-admin
            # only while it runs.
            $installBinding = "$RadiusCliServiceAccount-install"
            Invoke-Checked 'grant cluster-admin for rad install' {
                kubectl create clusterrolebinding $installBinding --clusterrole=cluster-admin `
                    --serviceaccount="radius-system:$RadiusCliServiceAccount" --context $KubeContext --dry-run=client -o yaml |
                    kubectl apply --context $KubeContext -f - | Out-Null
            }
        }

        # Workload identity must be enabled at install time so the control-plane pods start with a
        # projected service account token mounted. Enabling it later requires `rad upgrade`.
        # --kubecontext is explicit: relying on the current kubectl context is how installs end up
        # on the wrong cluster.
        Write-Host "==> Installing the Radius control plane with workload identity enabled" -ForegroundColor Cyan
        try {
            Invoke-Checked 'rad install' {
                # The sample doesn't use the Radius dashboard; not running it removes a Node.js runtime to patch.
                rad install kubernetes --kubecontext $radiusContext --set global.azureWorkloadIdentity.enabled=true --set dashboard.enabled=false
            }
        }
        finally {
            if ($installBinding) {
                kubectl delete clusterrolebinding $installBinding --context $KubeContext --ignore-not-found | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "Could not remove ClusterRoleBinding '$installBinding', which makes the Radius CLI's ServiceAccount cluster-admin. Remove it: kubectl delete clusterrolebinding $installBinding --context $KubeContext"
                }
            }
        }

        # `rad credential register` targets the WORKSPACE's cluster, not the current kubectl
        # context, so the workspace must be bound first. Without this the credential silently lands
        # on whichever cluster the default workspace points at.
        Write-Host "==> Binding Radius workspace '$WorkspaceName' to context '$radiusContext'" -ForegroundColor Cyan
        Invoke-Checked 'rad workspace create' {
            rad workspace create kubernetes $WorkspaceName --context $radiusContext --force
        }

        # Replaces `rad credential register azure sp`, which would store a client secret in the
        # cluster. The control plane federates the four radius-system service accounts against the
        # identity created by the Bicep template instead.
        Write-Host "==> Registering the Azure credential using workload identity" -ForegroundColor Cyan
        Invoke-Checked 'rad credential register azure wi' {
            rad credential register azure wi --client-id $radiusClientId --tenant-id $tenantId --workspace $WorkspaceName
        }
    }

    Write-Host "`n================ Platform ready ================" -ForegroundColor Green
    Write-Host "Resource group   : $ResourceGroup   (also holds MC_${ResourceGroup}_${ClusterName}_${Location}, created by AKS)"
    Write-Host "Cluster          : $ClusterName (context $KubeContext)"
    Write-Host "Registry         : $registryLoginServer"
    Write-Host "OIDC issuer      : $oidcIssuer"
    Write-Host "Namespace        : $AppNamespace"
    Write-Host "Identities       : $(($WorkloadNames | ForEach-Object { "$IdentityPrefix-$_" }) -join ', '), $IdentityPrefix-db-admin"
    Write-Host ""
    Write-Host "Radius control-plane identity (Recipes -> Azure ARM):"
    Write-Host "  Name           : $RadiusIdentityName"
    Write-Host "  Client ID      : $radiusClientId"
    Write-Host "  Registered     : $(if ($SkipRadiusInstall) { 'no - run rad credential register azure wi yourself' } else { 'yes' })"

    Write-Host "`nNext step - deploy the application: ./scripts/deploy.ps1 -Target Azure" -ForegroundColor Yellow
    Write-Host "Azure SQL and PostgreSQL use Entra-only authentication, so no database password is needed."
}
finally {
    if ($parameterFile -and (Test-Path $parameterFile)) {
        Remove-Item $parameterFile -Force -ErrorAction SilentlyContinue
    }
    Pop-Location
}
