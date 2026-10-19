<#
.SYNOPSIS
    Layer 0: provisions the Azure platform infrastructure for the Order Management sample.

.DESCRIPTION
    Creates the resource group, container registry, AKS cluster (OIDC issuer + workload identity),
    the AcrPull role assignment for the kubelet, and the user-assigned managed identity with its
    federated identity credential -- all declaratively, through deploy/infra/main.bicep.

    It then performs the imperative follow-up that has no declarative equivalent:
      * fetches cluster credentials
      * creates the application namespace and the annotated Kubernetes service account
      * installs the Radius control plane

    Run this once per environment. It is idempotent, so re-running it is safe, and it takes no
    interactive input, so an Azure DevOps AzureCLI@2 task can call it unchanged.

    Requires Owner or User Access Administrator on the subscription, because it creates role
    assignments. That is why it is separate from the per-commit application deployment.

.PARAMETER WhatIf
    Runs `az deployment sub what-if` and stops, without changing anything.

.EXAMPLE
    ./scripts/azure/provision-infra.ps1 -SubscriptionId <sub-id> -RegistryName bcdacr042

.EXAMPLE
    ./scripts/azure/provision-infra.ps1 -SubscriptionId <sub-id> -RegistryName bcdacr042 -WhatIf
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
    [string]$ResourceGroup = 'bcd-infra',
    [string]$ClusterName = 'bcd-aks',
    [string]$IdentityName = 'bcd-workload-identity',
    [string]$RadiusIdentityName = 'bcd-radius-identity',
    [string]$AppNamespace = 'oms-azure',
    [string]$ServiceAccountName = 'oms-workload-identity',
    # Radius workspace bound to the AKS cluster. Radius CLI commands target the workspace's
    # Kubernetes context, which is NOT necessarily the current kubectl context, so this must exist
    # before any `rad` command that talks to the control plane.
    [string]$WorkspaceName = 'oms-azure',
    [int]$NodeCount = 2,
    [string]$NodeVmSize = 'Standard_D4s_v7',
    [ValidateSet('Basic', 'Standard', 'Premium')][string]$RegistrySku = 'Standard',

    # Entra ID object IDs granted cluster-admin. Defaults to the signed-in user, which is required
    # because local accounts are disabled and nobody could otherwise reach the API server.
    [string[]]$ClusterAdminObjectIds,

    # Disabling this reverts to certificate-based local accounts, which most org policies prohibit.
    [bool]$UseEntraAuthentication = $true,

    # ServiceAccount the Radius CLI authenticates as. Needed because an Entra user token carries
    # too many group headers for the Kubernetes aggregated API proxy (HTTP 431).
    [string]$RadiusCliServiceAccount = 'radius-admin',

    # Lifetime of that ServiceAccount token. Re-run this script to mint a fresh one.
    [int]$RadiusCliTokenHours = 24,

    [switch]$SkipRadiusInstall,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Push-Location $repoRoot

<#
    Azure CLI has a defect where a failed ARM deployment can surface as:

        ERROR: The content for this response was already consumed

    which hides the real reason. It happens while the CLI is formatting the error response, so the
    genuine message (quota, policy, an unavailable VM size, and so on) is lost. Re-running the same
    template through `validate --debug` reproduces the failure and exposes the underlying text,
    which this function extracts.
#>
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

function Get-DeploymentError {
    param([Parameter(Mandatory = $true)][string]$DeploymentName)

    $messages = [System.Collections.Generic.List[string]]::new()

    function Add-ErrorTree {
        param($Json)

        if ([string]::IsNullOrWhiteSpace($Json) -or $Json -eq 'null') { return }

        $queue = [System.Collections.Generic.Queue[object]]::new()
        $queue.Enqueue(($Json | ConvertFrom-Json))

        while ($queue.Count -gt 0) {
            $node = $queue.Dequeue()
            if ($null -eq $node) { continue }

            if ($node.code -or $node.message) {
                $text = "[$($node.code)] $($node.message)"
                if (-not $messages.Contains($text)) { $messages.Add($text) }
            }

            foreach ($child in @($node.details)) {
                if ($null -ne $child) { $queue.Enqueue($child) }
            }
        }
    }

    Add-ErrorTree -Json (az deployment sub show --name $DeploymentName --query properties.error --output json 2>$null)

    # A subscription-scoped deployment only records the first couple of levels; the actual cause
    # lives in the nested resource-group deployment it launched, so read that too.
    $nested = az deployment operation sub list --name $DeploymentName `
        --query "[?properties.targetResource.resourceType=='Microsoft.Resources/deployments'].{name:properties.targetResource.resourceName, group:properties.targetResource.id}" `
        --output json 2>$null

    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($nested) -and $nested -ne 'null') {
        foreach ($item in ($nested | ConvertFrom-Json)) {
            # Resource IDs look like /subscriptions/<id>/resourceGroups/<rg>/providers/...
            $segments = $item.group -split '/'
            $rgIndex = [array]::IndexOf($segments, 'resourceGroups')
            if ($rgIndex -lt 0 -or $rgIndex + 1 -ge $segments.Length) { continue }
            $resourceGroup = $segments[$rgIndex + 1]

            Add-ErrorTree -Json (az deployment group show `
                --resource-group $resourceGroup `
                --name $item.name `
                --query properties.error --output json 2>$null)
        }
    }

    return $messages
}

function Get-PreflightError {
    param(
        [Parameter(Mandatory = $true)][string]$TemplateFile,
        [Parameter(Mandatory = $true)][string]$Location,
        [Parameter(Mandatory = $true)][string]$ParameterFile
    )

    $output = az deployment sub validate `
        --location $Location `
        --template-file $TemplateFile `
        --parameters "@$ParameterFile" `
        --debug 2>&1

    return $output |
        Select-String -Pattern '^\s*(Message|Code|Exception Details):' |
        ForEach-Object { $_.Line.Trim() } |
        Select-Object -Unique
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

    $path = Join-Path ([System.IO.Path]::GetTempPath()) "bcd-infra-params-$([guid]::NewGuid().ToString('N')).json"
    # Windows PowerShell's 'utf8' encoding emits a BOM, which the JSON parsers behind the az and
    # rad CLIs both reject.
    [System.IO.File]::WriteAllText($path, ($document | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
    return $path
}

try {
    $template = 'deploy/infra/main.bicep'
    $deploymentName = "bcd-infra-$(Get-Date -Format 'yyyyMMddHHmmss')"
    $parameterFile = $null
    # Entra users hit HTTP 431 on the aggregated API, so the CLI uses a ServiceAccount context.
    $radiusContext = if ($UseEntraAuthentication) { "$ClusterName-radius" } else { $ClusterName }

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
    $parameterFile = New-ParameterFile @{
        location                = $Location
        resourceGroupName       = $ResourceGroup
        clusterName             = $ClusterName
        registryName            = $RegistryName
        identityName            = $IdentityName
        radiusIdentityName      = $RadiusIdentityName
        appNamespace            = $AppNamespace
        serviceAccountName      = $ServiceAccountName
        nodeCount               = $NodeCount
        nodeVmSize              = $NodeVmSize
        registrySku             = $RegistrySku
        clusterAdminObjectIds   = @($ClusterAdminObjectIds)
        useEntraAuthentication  = $UseEntraAuthentication
    }

    if ($WhatIf) {
        Write-Host "==> Previewing changes (what-if). Nothing is created." -ForegroundColor Cyan
        az deployment sub what-if `
            --location $Location `
            --template-file $template `
            --parameters "@$parameterFile"

        if ($LASTEXITCODE -ne 0) {
            Write-Host "==> Preview failed. Extracting the underlying error..." -ForegroundColor Yellow
            $details = Get-PreflightError -TemplateFile $template -Location $Location -ParameterFile $parameterFile
            if ($details) {
                Write-Host "`nUnderlying error reported by Azure:" -ForegroundColor Red
                $details | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
            }
            throw 'Preview failed.'
        }

        return
    }

    Write-Host "==> Deploying platform infrastructure (this typically takes 5-10 minutes)" -ForegroundColor Cyan
    az deployment sub create `
        --name $deploymentName `
        --location $Location `
        --template-file $template `
        --parameters "@$parameterFile" `
        --output none
    if ($LASTEXITCODE -ne 0) {
        # Two different failure modes, so try both sources. A deployment that reached ARM records
        # its error tree; one rejected at preflight never does, and must be reproduced via validate.
        Write-Host "==> Deployment failed. Extracting the underlying error..." -ForegroundColor Yellow

        $details = Get-DeploymentError -DeploymentName $deploymentName
        if (-not $details) {
            $details = Get-PreflightError -TemplateFile $template -Location $Location -ParameterFile $parameterFile
        }

        if ($details) {
            Write-Host "`nUnderlying error reported by Azure:" -ForegroundColor Red
            $details | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        }
        else {
            Write-Host "  Could not extract further detail. Re-run with:" -ForegroundColor DarkGray
            Write-Host "    az deployment sub validate --location $Location --template-file $template --parameters @$parameterFile --debug" -ForegroundColor DarkGray
        }

        throw 'Infrastructure deployment failed.'
    }

    Write-Host "==> Reading deployment outputs" -ForegroundColor Cyan
    $outputsJson = az deployment sub show --name $deploymentName --query properties.outputs --output json
    if ($LASTEXITCODE -ne 0) { throw 'Could not read deployment outputs.' }
    $outputs = $outputsJson | ConvertFrom-Json

    $registryLoginServer = $outputs.registryLoginServer.value
    $clientId = $outputs.workloadIdentityClientId.value
    $principalId = $outputs.workloadIdentityPrincipalId.value
    $identity = $outputs.workloadIdentityName.value
    $radiusClientId = $outputs.radiusIdentityClientId.value
    $oidcIssuer = $outputs.oidcIssuerUrl.value
    $tenantId = az account show --query tenantId --output tsv

    Write-Host "==> Fetching cluster credentials" -ForegroundColor Cyan
    az aks get-credentials --resource-group $ResourceGroup --name $ClusterName --overwrite-existing

    if ($UseEntraAuthentication) {
        # With Entra authentication the kubeconfig uses an exec plugin. Converting it to the
        # azurecli login mode reuses the existing `az login` token instead of prompting for a device
        # code on every kubectl call.
        Write-Host "==> Converting kubeconfig for Entra ID authentication" -ForegroundColor Cyan
        Invoke-Checked 'kubelogin convert-kubeconfig' {
            kubelogin convert-kubeconfig -l azurecli --context $ClusterName
        }
    }

    # The service account is a Kubernetes object, so it cannot come from the ARM deployment. Its
    # name and namespace must match the federated credential subject exactly.
    Write-Host "==> Creating namespace and annotated service account" -ForegroundColor Cyan
    kubectl create namespace $AppNamespace --dry-run=client -o yaml | kubectl apply -f -

    $serviceAccountManifest = @"
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $ServiceAccountName
  namespace: $AppNamespace
  annotations:
    azure.workload.identity/client-id: $clientId
    azure.workload.identity/tenant-id: $tenantId
  labels:
    azure.workload.identity/use: "true"
"@
    $serviceAccountManifest | kubectl apply -f -

    if (-not $SkipRadiusInstall) {
        # The Radius CLI needs an identity with no Entra groups, or the Kubernetes aggregated API
        # proxy rejects its requests with HTTP 431, including the readiness check at the end of
        # `rad install`. So the ServiceAccount context is minted first and the install uses it.
        # See ensure-radius-context.ps1 for the detail.
        $installContext = $ClusterName
        if ($UseEntraAuthentication) {
            kubectl create namespace radius-system --context $ClusterName --dry-run=client -o yaml |
                kubectl apply --context $ClusterName -f - | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Creating the radius-system namespace failed.' }
            $radiusContext = ./scripts/azure/ensure-radius-context.ps1 `
                -ClusterName $ClusterName `
                -ServiceAccountName $RadiusCliServiceAccount `
                -TokenHours $RadiusCliTokenHours
            $installContext = $radiusContext
        }

        # Workload identity must be enabled at install time so the control-plane pods start with a
        # projected service account token mounted. Enabling it later requires `rad upgrade`.
        # --kubecontext is explicit: relying on the current kubectl context is how installs end up
        # on the wrong cluster.
        Write-Host "==> Installing the Radius control plane with workload identity enabled" -ForegroundColor Cyan
        Invoke-Checked 'rad install' {
            rad install kubernetes --kubecontext $installContext --set global.azureWorkloadIdentity.enabled=true
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
    Write-Host "Cluster          : $ClusterName"
    Write-Host "Registry         : $registryLoginServer"
    Write-Host "OIDC issuer      : $oidcIssuer"
    Write-Host "Namespace        : $AppNamespace"
    Write-Host "ServiceAccount   : $ServiceAccountName"
    Write-Host ""
    Write-Host "Application identity (workers -> Azure data planes):"
    Write-Host "  Name           : $identity"
    Write-Host "  Client ID      : $clientId"
    Write-Host "  Principal ID   : $principalId"
    Write-Host ""
    Write-Host "Radius control-plane identity (Recipes -> Azure ARM):"
    Write-Host "  Name           : $RadiusIdentityName"
    Write-Host "  Client ID      : $radiusClientId"
    Write-Host "  Registered     : $(if ($SkipRadiusInstall) { 'no - run rad credential register azure wi yourself' } else { 'yes' })"

    Write-Host "`nNext step - deploy the application." -ForegroundColor Yellow
    Write-Host "-AppInfraResourceGroup is where Recipes provision Service Bus, Storage and Azure SQL;"
    Write-Host "reusing '$ResourceGroup' keeps everything in one group, so cleanup is one 'az group delete'."
    Write-Host "     ./scripts/azure/deploy.ps1 ``"
    Write-Host "         -Registry $registryLoginServer ``"
    Write-Host "         -SubscriptionId $SubscriptionId ``"
    Write-Host "         -AppInfraResourceGroup $ResourceGroup ``"
    Write-Host "         -WorkloadIdentityPrincipalId $principalId"
    Write-Host ""
    Write-Host "Azure SQL uses Entra-only authentication, so no -SqlAdminPassword is needed."
}
finally {
    if ($parameterFile -and (Test-Path $parameterFile)) {
        Remove-Item $parameterFile -Force -ErrorAction SilentlyContinue
    }
    Pop-Location
}
