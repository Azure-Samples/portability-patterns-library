#Requires -Version 7.0
<#
.SYNOPSIS
    Deploys the Order Management sample to an AKS cluster backed by Azure PaaS.

.DESCRIPTION
    Assumes ./scripts/infra/azure/provision-infra.ps1 has already created the services' managed
    identities and configured the Radius Azure credential, and configure-app-identity.ps1 the app
    registrations. Run scripts/infra/azure/configure-environment.ps1 once before deploying the
    application; this script only publishes artifacts and deploys into that existing environment.

    After `rad deploy` it runs the database setup job as the database administrator, which creates
    each service's least-privilege database user, and applies the network policies.

    Three different things are called a "resource group" here. They are not interchangeable:

      * -AppInfraResourceGroup  An AZURE resource group. Radius Recipes provision Service Bus,
                                the Storage account and Azure SQL into it. May be the same group
                                that holds the cluster, or a separate one, but it must already
                                exist because Radius does not create it.
      * -ResourceGroup          A RADIUS resource group: a control-plane scope holding the Radius
                                Environment, Recipe Pack and application resources. It is not an
                                Azure resource group and never appears in the Azure portal.
      * The platform group      The AZURE resource group created by provision-infra.ps1, holding
                                ACR, AKS and the managed identity. AKS additionally creates its own
                                MC_<group>_<cluster>_<region> node resource group automatically.

.EXAMPLE
    # Single resource group: application infrastructure alongside the cluster. Simplest to clean up.
    # No SQL password: Azure SQL is created with Entra-only authentication.
    ./scripts/deploy/azure.ps1 `
        -Registry mycr.azurecr.io `
        -SubscriptionId 00000000-0000-0000-0000-000000000000 `
        -AppInfraResourceGroup bcd-infra

#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Registry,
    [Parameter(Mandatory = $true)][string]$SubscriptionId,

    # The Azure resource group that Radius Recipes provision application infrastructure into
    # (Service Bus, Storage account, Azure SQL, PostgreSQL). It may be the same group that holds the
    # platform infrastructure created by provision-infra.ps1, or a separate one. Either way it must
    # already exist: Radius does not create it.
    [Parameter(Mandatory = $true)][string]$AppInfraResourceGroup,

    # Optional. Azure SQL and PostgreSQL are created with Entra-only authentication, so no
    # administrator login exists and these values never reach Azure. The Radius Resource Types still
    # require them, so when omitted random values are generated to satisfy the schema.
    [securestring]$SqlAdminPassword,
    [securestring]$PostgresAdminPassword,

    # The managed identities provision-infra.ps1 created in -PlatformResourceGroup: <prefix>-<service>
    # for each service and <prefix>-db-admin for the database setup job.
    [string]$PlatformResourceGroup,
    [string]$IdentityPrefix = 'id-oms',
    [string[]]$WorkloadNames = @('api', 'processor', 'inventory'),
    [string]$DatabaseAdminServiceAccountName = 'dbsetup',

    # A RADIUS resource group, not an Azure one. Holds the Radius Environment, Recipe Pack and
    # application resources within the Radius control plane.
    [string]$ResourceGroup = 'oms',

    [string]$WorkspaceName = 'oms-azure',
    # Kubernetes context the Radius CLI uses. Recreated with a fresh ServiceAccount token at the
    # start of every run, because an Entra user token carries too many group headers for the
    # Kubernetes aggregated API proxy and returns HTTP 431.
    [string]$KubeContext = 'bcd-aks-radius',

    # Name of the AKS cluster, used to mint that token and as the kubeconfig cluster entry.
    [string]$ClusterName = 'bcd-aks',

    # Set false only if the cluster still allows local accounts, where the CLI can use the
    # certificate-based context directly.
    [bool]$UseEntraAuthentication = $true,

    # Lifetime of the Radius CLI ServiceAccount token minted for this run.
    [int]$RadiusCliTokenHours = 24,
    [string]$EnvironmentName = 'oms-azure',
    [string]$AppNamespace = 'oms-azure',
    [string]$Location = 'eastus2',

    # Entra app registrations for user sign-in, as created by scripts/infra/azure/configure-app-identity.ps1.
    [string]$OrdersApiAppName = 'oms-api',
    [string]$OrdersSpaAppName = 'oms-spa',
    [string]$InventoryAppName = 'oms-inventory',
    [int]$UiLocalPort = 5090,

    # Managed ingress from scripts/infra/azure/provision-ingress.ps1.
    [string]$IngressNamespace = 'app-routing-system',

    [switch]$SkipImageBuild
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repoRoot 'scripts/lib/recipes.ps1')
. (Join-Path $repoRoot 'scripts/lib/database.ps1')
. (Join-Path $repoRoot 'scripts/lib/deployment.ps1')
if (-not $PlatformResourceGroup) { $PlatformResourceGroup = $AppInfraResourceGroup }
Push-Location $repoRoot

$temporaryFiles = @()

try {
    Invoke-OmsChecked 'az account set' { az account set --subscription $SubscriptionId }
    # Mint a fresh ServiceAccount token before anything else. Without this the deployment depends on
    # a token minted by provision-infra.ps1, which expires (24h by default) and does not exist at
    # all on a machine that never ran it, such as a CI agent. See ensure-radius-context.ps1.
    if ($UseEntraAuthentication) {
        $KubeContext = ./scripts/lib/ensure-radius-context.ps1 `
            -ClusterName $ClusterName `
            -TokenHours $RadiusCliTokenHours `
            -ContextName $KubeContext
    }

    $environment = rad env show $EnvironmentName --group $ResourceGroup --workspace $WorkspaceName --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($environment) -or $environment -eq 'null') {
        throw "Radius environment '$EnvironmentName' in group '$ResourceGroup' and workspace '$WorkspaceName' is not available. Run ./scripts/configure-environment.ps1 -Target Azure with matching platform settings first."
    }
    # This extension is a local compiler artifact, not control-plane Resource Type registration.
    Invoke-OmsChecked 'rad bicep publish-extension' {
        rad bicep publish-extension -f $QueueTypeFile --target $QueueTypeExtension
    }

    $containerTool = if (Get-Command podman -ErrorAction SilentlyContinue) { 'podman' }
    elseif (Get-Command docker -ErrorAction SilentlyContinue) { 'docker' }
    else { $null }

    # 'rad bicep publish' reads registry credentials from the Docker-compatible config, so the login
    # is written there too, and is needed even when no images are built.
    $acrName = $Registry.Split('.')[0]
    $acrToken = az acr login --name $acrName --expose-token --query accessToken --output tsv
    if ($LASTEXITCODE -ne 0 -or -not $acrToken) { throw 'az acr login --expose-token failed.' }
    $acrUser = '00000000-0000-0000-0000-000000000000'
    $dockerConfigFile = Join-Path $HOME '.docker/config.json'
    New-Item -ItemType Directory -Force -Path (Split-Path $dockerConfigFile) | Out-Null
    if ($containerTool -eq 'podman') {
        $acrToken | podman login $Registry --username $acrUser --password-stdin | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'podman login failed.' }
        $acrToken | podman login $Registry --username $acrUser --password-stdin --compat-auth-file $dockerConfigFile | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'podman login (Docker-compatible config) failed.' }
    }
    elseif ($containerTool -eq 'docker') {
        $acrToken | docker login $Registry --username $acrUser --password-stdin | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'docker login failed.' }
    }
    $acrToken = $null

    $images = @('api', 'processor', 'inventory', 'dbsetup')
    if (-not $SkipImageBuild) {
        if (-not $containerTool) { throw 'Neither podman nor docker is on PATH. Install one, or pass -SkipImageBuild.' }

        Write-Host "==> Building and pushing images to $Registry with $containerTool" -ForegroundColor Cyan
        foreach ($worker in $images) {
            Invoke-OmsChecked "$containerTool build $worker" {
                & $containerTool build -f "docker/Dockerfile.$worker" -t "$Registry/oms/${worker}:latest" .
            }
            Invoke-OmsChecked "$containerTool push $worker" { & $containerTool push "$Registry/oms/${worker}:latest" }
        }
    }

    # Pinned by digest: with a bare ':latest' the pod spec never changes, so a rebuild never rolls out.
    $imageDigests = @{}
    foreach ($worker in $images) {
        $imageDigests[$worker] = az acr manifest show-metadata "$Registry/oms/${worker}:latest" --query digest --output tsv 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $imageDigests[$worker]) { throw "Could not read the digest of oms/${worker}:latest in $Registry." }
    }

    # Each service's own managed identity, and the database administrator's.
    Write-Host "==> Reading the services' managed identities from '$PlatformResourceGroup'" -ForegroundColor Cyan
    $identities = @{}
    foreach ($name in @($WorkloadNames) + 'db-admin') {
        $identityJson = az identity show --resource-group $PlatformResourceGroup --name "$IdentityPrefix-$name" --output json 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $identityJson) { throw "Managed identity '$IdentityPrefix-$name' not found in '$PlatformResourceGroup'. Run scripts/infra/azure/provision-infra.ps1." }
        $identities[$name] = $identityJson | ConvertFrom-Json
    }
    Write-Host "==> Publishing Azure Recipes" -ForegroundColor Cyan
    ./scripts/deploy/publish-recipes.ps1 -Registry $Registry -Platform azure

    # Published through the managed ingress when scripts/infra/azure/provision-ingress.ps1 has set it up.
    $dnsLabel = kubectl get service nginx -n $IngressNamespace --context $KubeContext --ignore-not-found `
        -o 'jsonpath={.metadata.annotations.service\.beta\.kubernetes\.io/azure-dns-label-name}' 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Could not discover the managed ingress host.' }
    $ingressHost = if ($dnsLabel) { "$dnsLabel.$Location.cloudapp.azure.com" } else { '' }
    if ($ingressHost) { Write-Host "    publishing through the managed ingress at https://$ingressHost" -ForegroundColor DarkGray }
    # Azure SQL and PostgreSQL are created with Entra-only authentication, so neither administrator
    # password is sent to Azure. The Radius Resource Types still mark `password` as required, so
    # generate values that satisfy the schema and are then discarded.
    function New-UnusedPassword {
        $randomBytes = [byte[]]::new(24)
        [System.Security.Cryptography.RandomNumberGenerator]::Fill($randomBytes)
        'Oms1!' + [Convert]::ToBase64String($randomBytes)
    }
    $plainPassword = if ($SqlAdminPassword) { [System.Net.NetworkCredential]::new('', $SqlAdminPassword).Password } else { New-UnusedPassword }
    $plainPostgresPassword = if ($PostgresAdminPassword) { [System.Net.NetworkCredential]::new('', $PostgresAdminPassword).Password } else { New-UnusedPassword }

    # User sign-in through Entra ID. Same app code as Azure Local; only these values differ.
    $tenantId = az account show --query tenantId --output tsv
    if ($LASTEXITCODE -ne 0 -or -not $tenantId) { throw 'Could not read the Azure tenant ID.' }
    $apiAppId = az ad app list --display-name $OrdersApiAppName --query '[0].appId' --output tsv
    if ($LASTEXITCODE -ne 0) { throw "Could not read app registration '$OrdersApiAppName'." }
    $spaAppId = az ad app list --display-name $OrdersSpaAppName --query '[0].appId' --output tsv
    if ($LASTEXITCODE -ne 0) { throw "Could not read app registration '$OrdersSpaAppName'." }
    $apiAuthentication = @{}
    $spaSettings = @{}
    if ($apiAppId -and $spaAppId) {
        $apiAuthentication = @{
            Instance = 'https://login.microsoftonline.com/'
            TenantId = $tenantId
            ClientId = $apiAppId
        }
        $spaSettings = @{
            Authority        = "https://login.microsoftonline.com/$tenantId"
            ClientId         = $spaAppId
            ProtocolMode     = 'AAD'
            ApiScope         = "api://$apiAppId/access_as_user"
            IdentityProvider = 'Microsoft Entra ID'
            Environment      = 'Azure'
        }
        Write-Host "==> User sign-in through Entra ID (API $apiAppId, SPA $spaAppId)" -ForegroundColor Cyan
    }
    else {
        Write-Warning "App registrations '$OrdersApiAppName'/'$OrdersSpaAppName' not found; the orders app will have no sign-in. Run scripts/infra/azure/configure-app-identity.ps1."
    }

    # The inventory service accepts only tokens Entra issued for its own app registration, to the
    # managed identities granted one of its roles.
    $inventoryAppId = az ad app list --display-name $InventoryAppName --query '[0].appId' --output tsv
    if ($LASTEXITCODE -ne 0 -or -not $inventoryAppId) { throw "App registration '$InventoryAppName' not found. Run scripts/infra/azure/configure-app-identity.ps1." }
    $inventoryAuthentication = @{
        Authority = "https://login.microsoftonline.com/$tenantId/v2.0"
        Audience  = $inventoryAppId
    }

    # The same parameters as on Azure Local: everything platform-specific is in the Recipe Pack.
    $applicationParameters = New-OmsParameterFile @{
        apiImage                = "$Registry/oms/api@$($imageDigests['api'])"
        processorImage          = "$Registry/oms/processor@$($imageDigests['processor'])"
        inventoryImage          = "$Registry/oms/inventory@$($imageDigests['inventory'])"
        apiAuthentication       = $apiAuthentication
        spaSettings             = $spaSettings
        inventoryAuthentication = $inventoryAuthentication
        inventoryScope          = "api://$inventoryAppId/.default"
        sqlAdminPassword        = $plainPassword
        postgresAdminPassword   = $plainPostgresPassword
    }
    Write-Host "==> Deploying application" -ForegroundColor Cyan
    Invoke-OmsChecked 'rad deploy application' {
        rad deploy deploy/app.bicep `
            --workspace $WorkspaceName `
            --group $ResourceGroup `
            --environment $EnvironmentName `
            --parameters "@$applicationParameters"
    }
    $plainPassword = $null; $plainPostgresPassword = $null

    # As the database administrator (Entra), create the schemas and a database user for each
    # service's managed identity, with only the rights it needs.
    $sql = Get-OmsRadiusResourceProperties -Type 'Radius.Data/sqlServerDatabases' -Name 'ordersdb' -Workspace $WorkspaceName -Group $ResourceGroup
    $postgres = Get-OmsRadiusResourceProperties -Type 'Radius.Data/postgreSqlDatabases' -Name 'inventorydb' -Workspace $WorkspaceName -Group $ResourceGroup
    Invoke-OmsDatabaseSetup -KubeContext $KubeContext -Namespace $AppNamespace `
        -Image "$Registry/oms/dbsetup@$($imageDigests['dbsetup'])" `
        -ServiceAccountName $DatabaseAdminServiceAccountName `
        -PodLabels @{ 'azure.workload.identity/use' = 'true' } `
        -Environment @{
            CONNECTION_SQL_HOST         = $sql.host
            CONNECTION_SQL_PORT         = $sql.port
            CONNECTION_SQL_DATABASE     = $sql.database
            SQL_API_CLIENT_ID           = $identities['api'].clientId
            SQL_PROCESSOR_CLIENT_ID     = $identities['processor'].clientId
            CONNECTION_INVENTORYDB_HOST     = $postgres.host
            CONNECTION_INVENTORYDB_PORT     = $postgres.port
            CONNECTION_INVENTORYDB_DATABASE = $postgres.database
            CONNECTION_INVENTORYDB_TLS      = 'required'
            POSTGRES_ADMIN_USERNAME     = $identities['db-admin'].name
            INVENTORY_OBJECT_ID         = $identities['inventory'].principalId
        }

    Set-OmsNetworkPolicy -KubeContext $KubeContext -Namespace $AppNamespace -IngressNamespace $IngressNamespace `
        -ManifestPath (Join-Path $repoRoot 'deploy/network-policies.yaml')

    # The services may have started before their database users existed; restart them so they
    # connect straight away rather than on their next retry.
    Write-Host "==> Waiting for the application to roll out" -ForegroundColor Cyan
    foreach ($name in $WorkloadNames) {
        Invoke-OmsChecked "kubectl rollout restart $name" {
            kubectl rollout restart deployment $name --namespace $AppNamespace --context $KubeContext | Out-Null
        }
    }
    Invoke-OmsChecked 'kubectl rollout status' {
        kubectl rollout status deployment --namespace $AppNamespace --context $KubeContext --timeout=600s | Out-Null
    }

    Write-Host "`nDeployed to Azure." -ForegroundColor Green
    if ($ingressHost) {
        Write-Host "Open the orders app: https://$ingressHost"
    }
    else {
        Write-Host "Open the orders app (MSAL needs a secure context, so it is served on localhost):"
        Write-Host "  kubectl port-forward -n $AppNamespace service/api-api ${UiLocalPort}:8080 --context $KubeContext"
        Write-Host "  http://localhost:$UiLocalPort"
    }
    Write-Host "  kubectl logs -n $AppNamespace -l radapp.io/resource=processor -f"
}
finally {
    foreach ($file in $temporaryFiles) {
        Remove-Item $file -Force -ErrorAction SilentlyContinue
    }
    Pop-Location
}
