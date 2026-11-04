#Requires -Version 7.3
<#
.SYNOPSIS
    Deploys the Order Management sample to an AKS cluster backed by Azure PaaS.

.DESCRIPTION
    Assumes ./scripts/infra/azure/provision-infra.ps1 has already created the services' managed
    identities and configured the Radius Azure credential, and configure-app-identity.ps1 the app
    registrations.

    After `rad deploy` it runs the database setup job as the database administrator, which creates
    each service's least-privilege database user, and applies the network policies.

    Three different things are called a "resource group" here. They are not interchangeable:

      * -ResourceGroup          The AZURE resource group created by provision-infra.ps1, holding
                                ACR, AKS and the managed identities. AKS additionally creates its
                                own MC_<group>_<cluster>_<region> node resource group automatically.
      * -AppInfraResourceGroup  An AZURE resource group. Radius Recipes provision Service Bus,
                                the Storage account and Azure SQL into it. -ResourceGroup unless
                                given, but it must already exist because Radius does not create it.
      * -RadiusGroup            A RADIUS resource group: a control-plane scope holding the Radius
                                Environment, Recipe Pack and application resources. It is not an
                                Azure resource group and never appears in the Azure portal.

.EXAMPLE
    # Usually run through ./scripts/deploy.ps1 -Target Azure, which supplies the settings. On its own:
    # no SQL password, since Azure SQL is created with Entra-only authentication.
    ./scripts/deploy/azure.ps1 `
        -Registry mycr.azurecr.io `
        -SubscriptionId 00000000-0000-0000-0000-000000000000 `
        -ResourceGroup <platform-resource-group> `
        -KubeContext <cluster-context>

.EXAMPLE
    # Private registry: supply a scoped ACR token so the Radius control plane can pull Recipes.
    #   az acr token create --registry mycr --name bcd-recipe-puller `
    #       --repository recipes/kubernetes/kubernetes-containers content/read --expiration-in-days 30
    ./scripts/deploy/azure.ps1 `
        -Registry mycr.azurecr.io `
        -SubscriptionId <sub-id> `
        -ResourceGroup <platform-resource-group> `
        -KubeContext <cluster-context> `
        -RegistryUsername bcd-recipe-puller `
        -RegistryPassword (Read-Host -AsSecureString)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Registry,
    [Parameter(Mandatory = $true)][string]$SubscriptionId,

    # The AZURE resource group provision-infra.ps1 created: the cluster, the registry, and the
    # managed identities (<IdentityPrefix>-<service> for each service, <IdentityPrefix>-db-admin for
    # the database setup job).
    [Parameter(Mandatory = $true)][string]$ResourceGroup,

    # The Azure resource group that Radius Recipes provision application infrastructure into
    # (Service Bus, Storage account, Azure SQL, PostgreSQL). Empty uses -ResourceGroup. It must
    # already exist: Radius does not create it.
    [string]$AppInfraResourceGroup,

    # Optional. Azure SQL and PostgreSQL are created with Entra-only authentication, so no
    # administrator login exists and these values never reach Azure. The Radius Resource Types still
    # require them, so when omitted random values are generated to satisfy the schema.
    [securestring]$SqlAdminPassword,
    [securestring]$PostgresAdminPassword,

    # Supply these when the registry hosting the Recipes requires authentication. The Radius control
    # plane pulls Recipes itself, so `az aks update --attach-acr` does not cover it.
    [string]$RegistryUsername,
    [securestring]$RegistryPassword,

    [string]$IdentityPrefix = 'id-oms',
    [string[]]$WorkloadNames = @('api', 'processor', 'inventory'),
    [string]$DatabaseAdminServiceAccountName = 'dbsetup',

    # A RADIUS resource group, not an Azure one. Holds the Radius Environment, Recipe Pack and
    # application resources within the Radius control plane.
    [string]$RadiusGroup = 'oms',

    [string]$WorkspaceName = 'oms-azure',
    # The cluster's kubeconfig context, as provision-infra.ps1 wrote it. kubectl uses it directly.
    [Parameter(Mandatory = $true)][string]$KubeContext,

    # With Entra ID sign-in, the Radius CLI uses a context of its own, which signs in as a
    # ServiceAccount: an Entra user token carries too many group headers for the Kubernetes
    # aggregated API proxy and returns HTTP 431. See scripts/lib/ensure-radius-context.ps1. Set
    # false only if the cluster still allows local accounts, where the CLI can use -KubeContext.
    [bool]$UseEntraAuthentication = $true,
    [string]$EnvironmentName = 'oms-azure',
    [string]$AppNamespace = 'oms-azure',
    [string]$Location = 'eastus2',

    # Region for the Azure SQL logical server. Defaults to $Location. Override when the primary
    # region refuses new SQL servers (RegionDoesNotAllowProvisioning); Azure SQL is reached over its
    # public FQDN, so a different region works at the cost of latency and cross-region egress.
    [string]$SqlLocation,

    # Region for the PostgreSQL flexible server. Defaults to $Location. Override when the primary
    # region offers no PostgreSQL versions to the subscription (ParameterOutOfRange on 'Version').
    [string]$PostgresLocation,

    # Entra app registrations for user sign-in, as created by scripts/infra/azure/configure-app-identity.ps1.
    [string]$OrdersApiAppName = 'oms-api',
    [string]$OrdersSpaAppName = 'oms-spa',
    [string]$InventoryAppName = 'oms-inventory',
    [int]$UiLocalPort = 5090,

    # Managed ingress from scripts/infra/azure/provision-ingress.ps1.
    [string]$IngressClassName = 'webapprouting.kubernetes.azure.com',
    [string]$IngressCertIssuer = 'letsencrypt',
    [string]$IngressNamespace = 'app-routing-system',

    # Lifetime of the read-only registry token minted for Recipe pulls when no -RegistryUsername is given.
    [int]$RecipeTokenDays = 7,
    # The tag the images are built and the Recipes published with. Images are deployed by digest.
    # Empty: the current git commit.
    [string]$ImageTag,
    [switch]$SkipImageBuild
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
# Images and Recipes are tagged with the commit they're built from, so every deployment names exactly
# what it runs, and a site never pulls a moving tag.
if (-not $ImageTag) {
    $ImageTag = git -C $repoRoot rev-parse --short=12 HEAD 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $ImageTag) { throw 'Pass -ImageTag: this folder is not a git checkout to take the commit from.' }
}
. (Join-Path $repoRoot 'scripts/lib/recipes.ps1')
. (Join-Path $repoRoot 'scripts/lib/database.ps1')
. (Join-Path $repoRoot 'scripts/lib/azure.ps1')
if (-not $AppInfraResourceGroup) { $AppInfraResourceGroup = $ResourceGroup }
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

# `rad deploy --parameters key=value` only supports strings. Booleans and integers must come from
# an ARM-format parameter file, so non-string values are written to a temporary file instead.
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

    # Owner-only, as New-TemporaryFile creates it, since it can carry passwords; kept as .json.
    $file = New-TemporaryFile
    $path = "$($file.FullName).json"
    Move-Item $file $path
    # Windows PowerShell's 'utf8' encoding emits a BOM, which the rad CLI rejects with
    # "invalid character 'ï' looking for beginning of value".
    [System.IO.File]::WriteAllText($path, ($document | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
    return $path
}

$temporaryFiles = @()

try {
    # Check registry access before doing any expensive work. The Radius control plane pulls Recipes
    # itself and cannot use the workload identity for it (bicepSettings supports only BasicAuth
    # today), so a registry that allows neither anonymous pull nor a token rejects those pulls with
    # 401 -- but only once a Recipe runs, several minutes into the deployment.
    if (-not $RegistryUsername -and $Registry -like '*.azurecr.io') {
        $acrName = $Registry.Split('.')[0]
        $anonymousPull = Invoke-Checked "az acr show $acrName" { az acr show --name $acrName --query anonymousPullEnabled --output tsv }
        if ($anonymousPull -eq 'false') {
            # A scoped, read-only, expiring token. ACR repository names are literal, so every Recipe
            # repository is listed individually. Refreshed on each run so it never silently expires.
            Write-Host "==> Minting a read-only Recipe pull token for $Registry ($RecipeTokenDays days)" -ForegroundColor Cyan
            $RegistryUsername = 'bcd-recipe-puller'
            $repositories = Get-LibraryRecipe -Platform azure | ForEach-Object { Get-LibraryRecipeRepository $_ }
            $scopeArguments = $repositories | ForEach-Object { '--repository', $_, 'content/read', 'metadata/read' }

            $scopeVerb = if (Invoke-OmsAzShow @('acr', 'scope-map', 'show', '--registry', $acrName, '--name', $RegistryUsername, '--only-show-errors')) { 'update' } else { 'create' }
            if ($scopeVerb -eq 'update') {
                $scopeArguments = $repositories | ForEach-Object { '--add-repository', $_, 'content/read', 'metadata/read' }
            }
            Invoke-Checked "az acr scope-map $scopeVerb" {
                az acr scope-map $scopeVerb --registry $acrName --name $RegistryUsername @scopeArguments --only-show-errors | Out-Null
            }
            if (-not (Invoke-OmsAzShow @('acr', 'token', 'show', '--registry', $acrName, '--name', $RegistryUsername, '--only-show-errors'))) {
                Invoke-Checked 'az acr token create' {
                    az acr token create --registry $acrName --name $RegistryUsername --scope-map $RegistryUsername --no-passwords --only-show-errors | Out-Null
                }
            }
            $tokenPassword = az acr token credential generate --registry $acrName --name $RegistryUsername `
                --password1 --expiration-in-days $RecipeTokenDays --query 'passwords[0].value' --output tsv --only-show-errors
            if ($LASTEXITCODE -ne 0 -or -not $tokenPassword) { throw 'Generating the Recipe pull token password failed.' }
            $RegistryPassword = ConvertTo-SecureString $tokenPassword -AsPlainText -Force
            $tokenPassword = $null
        }
    }

    # The Radius CLI's own context. See ensure-radius-context.ps1.
    $radiusContext = if ($UseEntraAuthentication) {
        ./scripts/lib/ensure-radius-context.ps1 -KubeContext $KubeContext
    }
    else { $KubeContext }

    # The workspace must be bound to the AKS cluster before any group is created, otherwise `rad`
    # targets whichever cluster the default workspace points at. --context is explicit for the same
    # reason. The group cannot be set on first creation because it does not exist yet, so the
    # workspace is created twice.
    Write-Host "==> Binding Radius workspace '$WorkspaceName' to context '$radiusContext'" -ForegroundColor Cyan
    Invoke-Checked 'rad workspace create' {
        rad workspace create kubernetes $WorkspaceName --context $radiusContext --force
    }
    Invoke-Checked 'rad group create' { rad group create $RadiusGroup --workspace $WorkspaceName }
    Invoke-Checked 'rad workspace bind group' {
        rad workspace create kubernetes $WorkspaceName --context $radiusContext --group $RadiusGroup --force
    }

    Write-Host "==> Registering the messageQueues Resource Type" -ForegroundColor Cyan
    Invoke-Checked 'rad resource-type create' {
        rad resource-type create messageQueues -f $QueueTypeFile --workspace $WorkspaceName
    }
    Invoke-Checked 'rad bicep publish-extension' {
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
            Invoke-Checked "$containerTool build $worker" {
                & $containerTool build -f "docker/Dockerfile.$worker" -t "$Registry/oms/${worker}:$ImageTag" .
            }
            Invoke-Checked "$containerTool push $worker" { & $containerTool push "$Registry/oms/${worker}:$ImageTag" }
        }
    }

    # Pinned by digest: with a bare tag the pod spec never changes, so a rebuild never rolls out.
    $imageDigests = @{}
    foreach ($worker in $images) {
        $imageDigests[$worker] = Invoke-OmsAzShow @('acr', 'manifest', 'show-metadata', "$Registry/oms/${worker}:$ImageTag", '--query', 'digest', '--output', 'tsv')
        if (-not $imageDigests[$worker]) { throw "No image oms/${worker}:$ImageTag in $Registry. Build it: run this again without -SkipImageBuild." }
    }

    # Each service's own managed identity, and the database administrator's.
    Write-Host "==> Reading the services' managed identities from '$ResourceGroup'" -ForegroundColor Cyan
    $identities = @{}
    foreach ($name in @($WorkloadNames) + 'db-admin') {
        $identity = Invoke-OmsAzShow @('identity', 'show', '--resource-group', $ResourceGroup, '--name', "$IdentityPrefix-$name", '--output', 'json')
        if (-not $identity) { throw "Managed identity '$IdentityPrefix-$name' not found in '$ResourceGroup'. Run scripts/infra/azure/provision-infra.ps1." }
        $identities[$name] = $identity | ConvertFrom-Json
    }
    $workloadClientIds = @{}
    foreach ($name in $WorkloadNames) { $workloadClientIds[$name] = $identities[$name].clientId }
    $applicationInsightsId = Invoke-Checked 'az resource list (Application Insights)' {
        az resource list --resource-group $ResourceGroup --resource-type Microsoft.Insights/components --query '[0].id' --output tsv
    }
    $applicationInsightsConnectionString = if ($applicationInsightsId) {
        Invoke-Checked 'az resource show (Application Insights)' {
            az resource show --ids $applicationInsightsId --query properties.ConnectionString --output tsv
        }
    }
    if (-not $applicationInsightsConnectionString) { Write-Warning "No Application Insights in '$ResourceGroup'; the services will send no telemetry." }
    $alertActionGroupId = Invoke-Checked 'az monitor action-group list' {
        az monitor action-group list --resource-group $ResourceGroup --query '[0].id' --output tsv
    }

    Write-Host "==> Publishing Azure Recipes" -ForegroundColor Cyan
    ./scripts/deploy/publish-recipes.ps1 -Registry $Registry -Platform azure -Tag $ImageTag

    # `rad deploy` always needs an environment to deploy into, including for the Recipe Pack that
    # the real environment depends on.
    Write-Host "==> Creating the bootstrap environment" -ForegroundColor Cyan
    Invoke-Checked 'rad env create bootstrap' {
        rad env create bootstrap --group $RadiusGroup --workspace $WorkspaceName
    }

    Write-Host "==> Deploying Recipe Pack" -ForegroundColor Cyan
    if (-not $SqlLocation) { $SqlLocation = $Location }
    if (-not $PostgresLocation) { $PostgresLocation = $Location }

    # Published through the managed ingress when scripts/infra/azure/provision-ingress.ps1 has set it up.
    $dnsLabel = Invoke-Checked 'reading the managed ingress Service' {
        kubectl get service nginx -n app-routing-system --context $KubeContext --ignore-not-found `
            -o 'jsonpath={.metadata.annotations.service\.beta\.kubernetes\.io/azure-dns-label-name}'
    }
    $ingressHost = if ($dnsLabel) { "$dnsLabel.$Location.cloudapp.azure.com" } else { '' }
    if ($ingressHost) { Write-Host "    publishing through the managed ingress at https://$ingressHost" -ForegroundColor DarkGray }
    # Which service gets which access is the app's knowledge, so it's decided here; the Recipe Pack
    # only applies it.
    $recipePackParameters = New-ParameterFile @{
        registry                            = $Registry
        tag                                 = $ImageTag
        workloadClientIds                   = $workloadClientIds
        queueSenderPrincipalIds             = @($identities['api'].principalId)
        queueReceiverPrincipalIds           = @($identities['processor'].principalId)
        storageContributorPrincipalIds      = @($identities['processor'].principalId)
        databaseAdministratorPrincipalId    = $identities['db-admin'].principalId
        databaseAdministratorName           = $identities['db-admin'].name
        applicationInsightsConnectionString = [string]$applicationInsightsConnectionString
        alertActionGroupId                  = [string]$alertActionGroupId
        location                            = $Location
        sqlLocation                         = $SqlLocation
        postgresLocation                    = $PostgresLocation
        # The app's route is always published through the managed ingress; with no DNS label it
        # answers on the ingress's address, without a certificate.
        ingressClassName                    = $IngressClassName
        ingressHost                         = $ingressHost
        ingressCertIssuer                   = $(if ($ingressHost) { $IngressCertIssuer } else { '' })
    }
    $temporaryFiles += $recipePackParameters
    Invoke-Checked 'rad deploy recipe pack' {
        rad deploy (Join-Path $LibraryRecipePackRoot 'azure.bicep') `
            --workspace $WorkspaceName `
            --group $RadiusGroup `
            --environment bootstrap `
            --parameters "@$recipePackParameters"
    }

    Write-Host "==> Deploying Environment" -ForegroundColor Cyan
    Invoke-Checked 'rad deploy environment' {
        rad deploy deploy/environments/azure.bicep `
            --workspace $WorkspaceName `
            --group $RadiusGroup `
            --environment bootstrap `
            --parameters subscriptionId=$SubscriptionId `
            --parameters resourceGroupName=$AppInfraResourceGroup
    }

    if ($RegistryUsername) {
        # The Radius control plane pulls Recipes itself and does not use the kubelet identity, so a
        # private registry needs explicit credentials. The secret requires an existing Environment,
        # which is why this runs after the Environment is created and the Environment is then
        # updated to reference the resulting settings.
        Write-Host "==> Configuring private registry authentication for Recipes" -ForegroundColor Cyan

        if (-not $RegistryPassword) {
            throw "-RegistryPassword is required when -RegistryUsername is supplied."
        }
        # Through a parameters file, so the password never appears on a command line.
        $registryAuthParameters = New-ParameterFile @{
            registryHost     = $Registry
            registryUsername = $RegistryUsername
            registryPassword = [System.Net.NetworkCredential]::new('', $RegistryPassword).Password
        }
        $temporaryFiles += $registryAuthParameters

        Invoke-Checked 'rad deploy registry auth' {
            rad deploy deploy/recipe-registry-credentials.bicep `
                --workspace $WorkspaceName `
                --group $RadiusGroup `
                --environment $EnvironmentName `
                --parameters "@$registryAuthParameters"
        }

        Write-Host "==> Pointing the Environment at the registry credentials" -ForegroundColor Cyan

        # Look the ID up rather than hand-constructing it, and pass it as a string. A conditional
        # `existing` reference inside the template fails before the resource exists.
        $bicepSettingsId = (Get-OmsRadiusResource -Type 'Radius.Core/bicepSettings' -Name 'oms-registry-auth' `
                -Workspace $WorkspaceName -Group $RadiusGroup).id

        Invoke-Checked 'rad deploy environment with registry auth' {
            rad deploy deploy/environments/azure.bicep `
                --workspace $WorkspaceName `
                --group $RadiusGroup `
                --environment bootstrap `
                --parameters subscriptionId=$SubscriptionId `
                --parameters resourceGroupName=$AppInfraResourceGroup `
                --parameters bicepSettingsId=$bicepSettingsId
        }
    }
    else {
        Write-Host "==> Skipping registry authentication; assuming anonymous pull is enabled" -ForegroundColor DarkGray
    }

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
    $tenantId = Invoke-Checked 'az account show' { az account show --query tenantId --output tsv }
    $apiAppId = Invoke-Checked "az ad app list $OrdersApiAppName" { az ad app list --display-name $OrdersApiAppName --query '[0].appId' --output tsv }
    $spaAppId = Invoke-Checked "az ad app list $OrdersSpaAppName" { az ad app list --display-name $OrdersSpaAppName --query '[0].appId' --output tsv }
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
    $inventoryAppId = Invoke-Checked "az ad app list $InventoryAppName" { az ad app list --display-name $InventoryAppName --query '[0].appId' --output tsv }
    if (-not $inventoryAppId) { throw "App registration '$InventoryAppName' not found. Run scripts/infra/azure/configure-app-identity.ps1." }
    $inventoryAuthentication = @{
        Authority = "https://login.microsoftonline.com/$tenantId/v2.0"
        Audience  = $inventoryAppId
    }

    # The same parameters as on Azure Local: everything platform-specific is in the Recipe Pack.
    $applicationParameters = New-ParameterFile @{
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
    $temporaryFiles += $applicationParameters

    Write-Host "==> Deploying application" -ForegroundColor Cyan
    Invoke-Checked 'rad deploy application' {
        rad deploy deploy/app.bicep `
            --workspace $WorkspaceName `
            --group $RadiusGroup `
            --environment $EnvironmentName `
            --parameters "@$applicationParameters"
    }
    $plainPassword = $null; $plainPostgresPassword = $null

    # As the database administrator (Entra), create the schemas and a database user for each
    # service's managed identity, with only the rights it needs.
    $sql = (Get-OmsRadiusResource -Type 'Radius.Data/sqlServerDatabases' -Name 'ordersdb' -Workspace $WorkspaceName -Group $RadiusGroup).properties
    $postgres = (Get-OmsRadiusResource -Type 'Radius.Data/postgreSqlDatabases' -Name 'inventorydb' -Workspace $WorkspaceName -Group $RadiusGroup).properties
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
        Invoke-Checked "restart $name" {
            kubectl rollout restart deployment $name --namespace $AppNamespace --context $KubeContext | Out-Null
        }
    }
    Invoke-Checked 'kubectl rollout status' {
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
    Write-Host "  kubectl logs -n $AppNamespace -l radapp.io/resource=processor -f --context $KubeContext"
}
finally {
    foreach ($file in $temporaryFiles) {
        Remove-Item $file -Force -ErrorAction SilentlyContinue
    }
    Pop-Location
}
