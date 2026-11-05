<#
.SYNOPSIS
    Runs an ACR connected registry inside the AKS Arc cluster so images and Recipes stay pullable
    when Azure Local loses its link to Azure.

.DESCRIPTION
    The cloud registry (Premium, created by provision-infra.ps1) stays the place images and Recipes
    are pushed to. A ReadOnly connected registry, deployed as the
    Microsoft.ContainerRegistry.ConnectedRegistry Arc extension, continuously syncs the listed
    repositories into the cluster and serves them on a fixed ClusterIP. Kubelet and the Radius
    control plane pull from that address, so a pod restarted while Azure is unreachable still finds
    its image.

    The Azure resources are declared in infra/azurelocal/connected-registry.bicep: the client and sync
    scope maps and tokens, the connected registry and its Arc extension. This script:
      1. Deploys the template. Tokens are only created when missing: redeploying one would delete
         its passwords.
      2. On first install, generates the sync password and deploys the template again with the
         connection string, which installs the Arc extension. The extension takes its certificate
         from the cluster's cert-manager and distributes the registry's CA to every node so kubelet
         trusts it.
      3. Stores the client token as image pull secret '<PullSecretName>' in every namespace that
         pulls from the registry, and the registry CA as ConfigMap '<CaConfigMapName>' in the
         application namespace for deploy.ps1 to hand to the Radius control plane.

    -Repositories, plus every Azure Local Recipe under recipes/, is the complete list the connected
    registry syncs: repositories left out are removed from its scope.
    Idempotent. Token passwords and the sync connection string are only generated when they are not
    already in place, since regenerating them breaks whatever is using the old value. Only a token
    Azure reports as not found counts as missing; any other failure stops the script. The pull
    credential goes from Azure straight into the cluster's Secrets, never to a file or a command
    line.

.PARAMETER NewPullCredential
    Issue a new pull credential even though the client token already exists, for example because
    the cluster lost its pull secrets. Running pods keep working; new pulls use the new credential.

.EXAMPLE
    # Usually run by setup-platform.ps1 with the Common and Registry sections of scripts/settings.json. On its own:
    ./scripts/infra/azurelocal/connected-registry.ps1 -RegistryName <acr-name> -ResourceGroup <resource-group> `
        -ClusterName <cluster> -KubeContext <context> -ServiceClusterIp <address>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RegistryName,
    # Holds the registry and the Arc connected cluster.
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [Parameter(Mandatory = $true)][string]$ClusterName,
    [Parameter(Mandatory = $true)][string]$KubeContext,

    [ValidatePattern('^[a-zA-Z][a-zA-Z0-9]{4,39}$')]
    [string]$ConnectedRegistryName = 'bcdazlocalcr',
    [string]$ExtensionName = 'bcd-connected-registry',

    # The registry's address inside the cluster: an unused address in the cluster's service range
    # (10.96.0.0/12 on AKS enabled by Arc). The registry's certificate is issued for it.
    # preflight.ps1 checks it.
    [string]$ServiceClusterIp,
    [string]$StorageRequest = '25Gi',
    # Storage class for the registry's volume: the one AKS enabled by Arc creates.
    [string]$StorageClassName = 'default',
    # How long a failed extension may take to delete before it is reinstalled.
    [int]$DeleteTimeoutMinutes = 20,

    [switch]$NewPullCredential,

    [string]$ClientTokenName = 'bcd-azurelocal-pull',
    [string]$PullSecretName = 'azurelocal-registry',
    [string]$CaConfigMapName = 'azurelocal-registry-ca',
    [string]$ApplicationNamespace = 'oms-azurelocal',
    # Namespaces that pull from the connected registry, besides the application's: the platform's.
    # With -Availability high, the operators' namespaces too.
    [string[]]$PullSecretNamespaces = @('identity', 'radius-system', 'ingress-nginx', 'observability', 'object-store'),
    [ValidateSet('high', 'standard')]
    [string]$Availability = 'high',

    # Repositories synced into the cluster, besides the Recipes: only what runs on site. oras is what
    # deploy/azurelocal.ps1 checks the sync with.
    [string[]]$Repositories = @(
        'ucpd', 'controller', 'applications-rp', 'dynamic-rp', 'deployment-engine', 'bicep', 'pre-upgrade',
        'rabbitmq', 'mssql/server', 'postgres',
        'keycloak/keycloak', 'adorsys/keycloak-config-cli',
        'cloudnative-pg/cloudnative-pg', 'cloudnative-pg/postgresql',
        'cloudnative-pg/plugin-barman-cloud', 'cloudnative-pg/plugin-barman-cloud-sidecar',
        'rabbitmq/cluster-operator', 'rabbitmq/messaging-topology-operator', 'chrislusf/seaweedfs',
        'jetstack/cert-manager-csi-driver', 'jetstack/csi-node-driver-registrar', 'jetstack/livenessprobe',
        'ingress-nginx/controller', 'ingress-nginx/kube-webhook-certgen',
        'otel/opentelemetry-collector-contrib', 'grafana/loki', 'grafana/tempo', 'grafana/grafana', 'kiwigrid/k8s-sidecar',
        'prometheus/prometheus', 'prometheus/alertmanager', 'prometheus/node-exporter',
        'prometheus-operator/prometheus-operator', 'prometheus-operator/prometheus-config-reloader',
        'kube-state-metrics/kube-state-metrics',
        'oras-project/oras',
        'oms/api', 'oms/processor', 'oms/inventory', 'oms/dbsetup',
        'radius-project/kube-recipes/secrets'
    )
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
. (Join-Path $repoRoot 'scripts/lib/cluster.ps1')
. (Join-Path $repoRoot 'scripts/lib/recipes.ps1')
. (Join-Path $repoRoot 'scripts/lib/azure.ps1')
if ($Availability -eq 'high') { $PullSecretNamespaces += @('cnpg-system', 'rabbitmq-system', 'cert-manager-csi-driver') }
$PullSecretNamespaces = @($ApplicationNamespace) + @($PullSecretNamespaces | Where-Object { $_ -ne $ApplicationNamespace } | Select-Object -Unique)
$Repositories = @(@($Repositories) + @(Get-LibraryRecipe -Platform azure-local | ForEach-Object { Get-LibraryRecipeRepository $_ }) | Select-Object -Unique)

# Fixed by infra/azurelocal/connected-registry.bicep (the extension's release namespace) and by the
# extension, which keeps the registry's CA in Secret <extension name>-ca-cert there.
$ExtensionNamespace = 'connected-registry'
$CaSecretName = "$ExtensionName-ca-cert"
$ExtensionApiVersion = '2023-05-01'

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

function Test-Token([string]$Name) {
    [bool](Invoke-OmsAzShow @('acr', 'token', 'show', '--name', $Name, '--registry', $RegistryName, '--query', 'name', '--output', 'tsv'))
}

if (-not $ServiceClusterIp -or $ServiceClusterIp -like '<*') {
    throw "Set ServiceClusterIp in the Registry settings: an unused address in the cluster's service range (10.96.0.0/12 on AKS enabled by Arc)."
}
Write-Host "==> Checking the cluster is reachable" -ForegroundColor Cyan
Invoke-Checked 'kubectl cluster-info' { kubectl cluster-info --context $KubeContext --request-timeout=20s | Out-Null }

$registryLoginServer = Invoke-OmsAzShow @('acr', 'show', '--name', $RegistryName, '--resource-group', $ResourceGroup, '--query', 'loginServer', '--output', 'tsv')
if (-not $registryLoginServer) { throw "Registry '$RegistryName' not found in '$ResourceGroup'. Run scripts/infra/azurelocal/provision-infra.ps1 first." }
$clusterId = Invoke-OmsAzShow @('resource', 'show', '--resource-group', $ResourceGroup, '--name', $ClusterName,
    '--resource-type', 'Microsoft.Kubernetes/connectedClusters', '--query', 'id', '--output', 'tsv')
if (-not $clusterId) { throw "Arc connected cluster '$ClusterName' not found in '$ResourceGroup'." }

$template = Join-Path $repoRoot 'infra/azurelocal/connected-registry.bicep'
$clientTokenIsNew = -not (Test-Token $ClientTokenName)

# Parameters go through a file: it carries the repository list and, on first install, the
# connection string, which must not appear on a command line.
function Deploy-ConnectedRegistry([string]$ConnectionString) {
    $parameters = [ordered]@{
        registryName          = $RegistryName
        connectedRegistryName = $ConnectedRegistryName
        clusterName           = $ClusterName
        repositories          = @($Repositories)
        clientTokenName       = $ClientTokenName
        createClientToken     = -not (Test-Token $ClientTokenName)
        createSyncToken       = -not (Test-Token $ConnectedRegistryName)
        syncConnectionString  = $ConnectionString
        extensionName         = $ExtensionName
        serviceClusterIp      = $ServiceClusterIp
        storageClassName      = $StorageClassName
        storageRequest        = $StorageRequest
    }
    $document = [ordered]@{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = [ordered]@{}
    }
    foreach ($key in $parameters.Keys) { $document.parameters[$key] = @{ value = $parameters[$key] } }
    # Owner-only, as New-TemporaryFile creates it.
    $file = New-TemporaryFile
    try {
        [System.IO.File]::WriteAllText($file, ($document | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
        Invoke-Checked 'az deployment group create' {
            az deployment group create --resource-group $ResourceGroup --name 'oms-connected-registry' `
                --template-file $template --parameters "@$file" --output none
        }
    }
    finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
}

Write-Host "==> Deploying the connected registry '$ConnectedRegistryName' ($($Repositories.Count) repositories)" -ForegroundColor Cyan
Deploy-ConnectedRegistry ''

# ------------------------------------------------------------------------------------------------
# Arc extension. The sync password is only generated on first install: doing it again would
# disconnect a running instance until the extension is updated with the new value.
# ------------------------------------------------------------------------------------------------
Write-Host "==> Ensuring Arc extension '$ExtensionName' on '$ClusterName'" -ForegroundColor Cyan
$extensionId = "$clusterId/providers/Microsoft.KubernetesConfiguration/extensions/$ExtensionName"
$extensionState = Invoke-OmsAzShow @('resource', 'show', '--ids', $extensionId, '--api-version', $ExtensionApiVersion,
    '--query', 'properties.provisioningState', '--output', 'tsv')

if ($extensionState -ne 'Succeeded') {
    if ($extensionState) {
        Write-Host "    existing extension is '$extensionState'; reinstalling" -ForegroundColor Yellow
        Invoke-Checked 'delete Arc extension' {
            az resource delete --ids $extensionId --api-version $ExtensionApiVersion --no-wait --output none
        }
        Invoke-Checked "waiting up to $DeleteTimeoutMinutes minutes for the extension to be deleted" {
            az resource wait --deleted --ids $extensionId --api-version $ExtensionApiVersion --interval 15 --timeout ($DeleteTimeoutMinutes * 60)
        }
    }

    $connectionString = az acr connected-registry get-settings --name $ConnectedRegistryName --registry $RegistryName `
        --parent-protocol https --generate-password 1 --query ACR_REGISTRY_CONNECTION_STRING --output tsv --yes
    if ($LASTEXITCODE -ne 0 -or -not $connectionString) { throw 'Could not generate the connected registry connection string.' }
    Write-Host "    installing (storage class $StorageClassName, ClusterIP $ServiceClusterIp)" -ForegroundColor DarkGray
    Deploy-ConnectedRegistry $connectionString.Trim()
    $connectionString = $null
}
else {
    Write-Host "    already installed" -ForegroundColor DarkGray
}
Write-Host "==> Waiting for the connected registry to come online" -ForegroundColor Cyan
$deadline = (Get-Date).AddMinutes(15)
do {
    $state = Invoke-Checked 'az acr connected-registry show' {
        az acr connected-registry show --name $ConnectedRegistryName --registry $RegistryName --query connectionState --output tsv
    }
    Write-Host "    $state" -ForegroundColor DarkGray
    if ($state -eq 'Online') { break }
    Start-Sleep -Seconds 20
} while ((Get-Date) -lt $deadline)
if ($state -ne 'Online') { throw "Connected registry is '$state' after 15 minutes. Check the pods in namespace '$ExtensionNamespace'." }

# ------------------------------------------------------------------------------------------------
# Pull secrets. The client token password lives only in the cluster, never in the repository, a
# file or a command line. It is only issued for a new client token or on request, since a new one
# replaces the password pods use; otherwise the one already in the cluster stays.
# ------------------------------------------------------------------------------------------------
Write-Host "==> Ensuring image pull secret '$PullSecretName'" -ForegroundColor Cyan
$clientPassword = $null
if ($clientTokenIsNew -or $NewPullCredential) {
    Write-Host "    issuing a new pull credential" -ForegroundColor DarkGray
    $clientPassword = az acr token credential generate --name $ClientTokenName --registry $RegistryName `
        --password1 --query 'passwords[0].value' --output tsv
    if ($LASTEXITCODE -ne 0 -or -not $clientPassword) { throw 'Generating the client token password failed.' }
}
else {
    $dockerConfig = Get-OmsSecretValue -KubeContext $KubeContext -Namespace $ApplicationNamespace -Name $PullSecretName -Key '.dockerconfigjson'
    if ($dockerConfig) {
        $auth = ($dockerConfig | ConvertFrom-Json).auths.$ServiceClusterIp
        if ($auth -and $auth.username -eq $ClientTokenName) { $clientPassword = $auth.password }
    }
    if (-not $clientPassword) {
        throw "The client token exists but the cluster has no '$PullSecretName' for it. Run this again with -NewPullCredential."
    }
}

$pullConfig = @{
    auths = @{
        $ServiceClusterIp = @{
            username = $ClientTokenName
            password = $clientPassword
            auth     = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${ClientTokenName}:$clientPassword"))
        }
    }
} | ConvertTo-Json -Depth 5 -Compress
$clientPassword = $null
foreach ($namespace in $PullSecretNamespaces) {
    Set-OmsNamespace $KubeContext $namespace
    Set-OmsSecret -KubeContext $KubeContext -Namespace $namespace -Name $PullSecretName -Type 'kubernetes.io/dockerconfigjson' `
        -Data @{ '.dockerconfigjson' = $pullConfig }
    Write-Host "    $namespace/$PullSecretName" -ForegroundColor DarkGray
}
$pullConfig = $null

# ------------------------------------------------------------------------------------------------
# Registry CA. Nodes get it from the extension's trust distribution, but the Radius control
# plane pulls Recipes itself and needs it explicitly.
# ------------------------------------------------------------------------------------------------
Write-Host "==> Exporting the connected registry CA from $ExtensionNamespace/$CaSecretName" -ForegroundColor Cyan
$caPem = Get-OmsSecretValue -KubeContext $KubeContext -Namespace $ExtensionNamespace -Name $CaSecretName -Key 'ca.crt'
if (-not $caPem) { throw "No CA in Secret '$ExtensionNamespace/$CaSecretName'. Check the extension's pods in '$ExtensionNamespace'." }
@{
    apiVersion = 'v1'
    kind       = 'ConfigMap'
    metadata   = @{ name = $CaConfigMapName; namespace = $ApplicationNamespace }
    data       = @{ 'ca.crt' = $caPem }
} | ConvertTo-Json -Depth 5 | kubectl apply --context $KubeContext -f - | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Writing ConfigMap '$CaConfigMapName' failed." }

Write-Host "`n================ Connected registry ready ================" -ForegroundColor Green
Write-Host "Cloud registry   : $registryLoginServer (push here)"
Write-Host "In-cluster pulls : $ServiceClusterIp (secret '$PullSecretName', CA ConfigMap '$ApplicationNamespace/$CaConfigMapName')"
Write-Host "Synced repos     : $($Repositories.Count)"
