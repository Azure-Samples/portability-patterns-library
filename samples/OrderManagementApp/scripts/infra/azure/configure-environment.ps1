#Requires -Version 7.0
<#
.SYNOPSIS
    Configures the Azure Radius environment before application deployment.

.DESCRIPTION
    Run after provision-infra.ps1, provision-ingress.ps1 and configure-app-identity.ps1.
    Binds the workspace, registers the queue Resource Type, deploys the Recipe Pack and Environment,
    and configures private Recipe registry access. Reads existing managed identities and telemetry
    resources; it does not provision Azure infrastructure or build application images.

    Re-run when platform settings change or the expiring Recipe pull token needs renewal.
    Ordinary application deployment never rotates that token or changes environment settings.

.EXAMPLE
    ./scripts/infra/azure/configure-environment.ps1 `
        -Registry mycr.azurecr.io -SubscriptionId <sub-id> -AppInfraResourceGroup bcd-infra
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Registry,
    [Parameter(Mandatory = $true)][string]$SubscriptionId,
    # Azure resource group into which Recipes provision application infrastructure; must exist.
    [Parameter(Mandatory = $true)][string]$AppInfraResourceGroup,
    [string]$PlatformResourceGroup,
    [string]$IdentityPrefix = 'id-oms',
    [string[]]$WorkloadNames = @('api', 'processor', 'inventory'),
    [string]$DatabaseAdminServiceAccountName = 'dbsetup',
    # Radius resource group, not an Azure resource group.
    [string]$ResourceGroup = 'oms',
    [string]$WorkspaceName = 'oms-azure',
    [string]$KubeContext = 'bcd-aks-radius',
    [string]$ClusterName = 'bcd-aks',
    [bool]$UseEntraAuthentication = $true,
    [int]$RadiusCliTokenHours = 24,
    [string]$EnvironmentName = 'oms-azure',
    [string]$AppNamespace = 'oms-azure',
    [string]$Location = 'eastus2',
    [string]$SqlLocation,
    [string]$PostgresLocation,
    [string]$IngressClassName = 'webapprouting.kubernetes.azure.com',
    [string]$IngressCertIssuer = 'letsencrypt',
    [string]$IngressNamespace = 'app-routing-system',
    [string]$ApplicationInsightsResourceId,
    [string]$AlertActionGroupId,
    # Radius pulls Recipes itself; the kubelet's AcrPull role does not cover these pulls.
    [string]$RegistryUsername,
    [securestring]$RegistryPassword,
    [ValidateRange(1, 365)][int]$RecipeTokenDays = 7
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
. (Join-Path $repoRoot 'scripts/lib/recipes.ps1')
. (Join-Path $repoRoot 'scripts/lib/deployment.ps1')
if (-not $PlatformResourceGroup) { $PlatformResourceGroup = $AppInfraResourceGroup }
if (-not $SqlLocation) { $SqlLocation = $Location }
if (-not $PostgresLocation) { $PostgresLocation = $Location }
if ($RegistryUsername -and -not $RegistryPassword) {
    throw '-RegistryPassword is required when -RegistryUsername is supplied.'
}
if ($RegistryPassword -and -not $RegistryUsername) {
    throw '-RegistryUsername is required when -RegistryPassword is supplied.'
}

$temporaryFiles = @()
Push-Location $repoRoot
try {
    Invoke-OmsChecked 'az account set' { az account set --subscription $SubscriptionId }
    if ($UseEntraAuthentication) {
        $KubeContext = ./scripts/lib/ensure-radius-context.ps1 `
            -ClusterName $ClusterName -TokenHours $RadiusCliTokenHours -ContextName $KubeContext
    }

    Write-Host "==> Binding Radius workspace '$WorkspaceName' to context '$KubeContext'" -ForegroundColor Cyan
    Invoke-OmsChecked 'rad workspace create' {
        rad workspace create kubernetes $WorkspaceName --context $KubeContext --force
    }
    Invoke-OmsChecked 'rad group create' { rad group create $ResourceGroup --workspace $WorkspaceName }
    Invoke-OmsChecked 'rad workspace bind group' {
        rad workspace create kubernetes $WorkspaceName --context $KubeContext --group $ResourceGroup --force
    }
    Write-Host '==> Registering the messageQueues Resource Type' -ForegroundColor Cyan
    Invoke-OmsChecked 'rad resource-type create' {
        rad resource-type create messageQueues -f $QueueTypeFile --workspace $WorkspaceName
    }

    # Repository-scoped, read-only BasicAuth is the authentication Radius supports for Recipe pulls.
    # Only explicit environment configuration creates or rotates this expiring credential.
    if (-not $RegistryUsername -and $Registry -like '*.azurecr.io') {
        $acrName = $Registry.Split('.')[0]
        $anonymousPull = az acr show --name $acrName --query anonymousPullEnabled --output tsv --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw "Could not check anonymous Recipe pull access for '$Registry'." }
        if ($anonymousPull -ne 'true') {
            Write-Host "==> Minting a read-only Recipe pull token for $Registry ($RecipeTokenDays days)" -ForegroundColor Cyan
            $RegistryUsername = 'bcd-recipe-puller'
            $repositories = @(Get-LibraryRecipe -Platform azure | ForEach-Object { "recipes/$($_.BaseName)" })
            if (-not $repositories.Count) { throw 'No Azure Recipes found for the registry scope map.' }
            $scopeArguments = $repositories | ForEach-Object { '--repository', $_, 'content/read', 'metadata/read' }
            az acr scope-map show --registry $acrName --name $RegistryUsername --only-show-errors 2>$null | Out-Null
            $scopeVerb = if ($LASTEXITCODE -eq 0) { 'update' } else { 'create' }
            if ($scopeVerb -eq 'update') {
                $scopeArguments = $repositories | ForEach-Object { '--add-repository', $_, 'content/read', 'metadata/read' }
            }
            Invoke-OmsChecked "az acr scope-map $scopeVerb" {
                az acr scope-map $scopeVerb --registry $acrName --name $RegistryUsername @scopeArguments --only-show-errors | Out-Null
            }
            az acr token show --registry $acrName --name $RegistryUsername --only-show-errors 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Invoke-OmsChecked 'az acr token create' {
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

    Write-Host "==> Reading the services' managed identities from '$PlatformResourceGroup'" -ForegroundColor Cyan
    $identities = @{}
    foreach ($name in @($WorkloadNames) + 'db-admin') {
        $identityJson = az identity show --resource-group $PlatformResourceGroup --name "$IdentityPrefix-$name" --output json
        if ($LASTEXITCODE -ne 0 -or -not $identityJson) {
            throw "Managed identity '$IdentityPrefix-$name' not found in '$PlatformResourceGroup'. Run scripts/infra/azure/provision-infra.ps1."
        }
        $identity = $identityJson | ConvertFrom-Json
        if (-not $identity.clientId -or -not $identity.principalId) { throw "Managed identity '$IdentityPrefix-$name' is incomplete." }
        $identities[$name] = $identity
    }
    $workloadClientIds = @{}
    foreach ($name in $WorkloadNames) { $workloadClientIds[$name] = $identities[$name].clientId }
    if (-not $ApplicationInsightsResourceId) {
        $componentIds = az resource list --resource-group $PlatformResourceGroup `
            --resource-type Microsoft.Insights/components --query '[].id' --output json
        if ($LASTEXITCODE -ne 0) { throw 'Could not discover Application Insights.' }
        $componentIds = @($componentIds | ConvertFrom-Json)
        if ($componentIds.Count -gt 1) { throw 'Several Application Insights resources exist. Set Environment.ApplicationInsightsResourceId explicitly.' }
        if ($componentIds.Count -eq 1) { $ApplicationInsightsResourceId = $componentIds[0] }
    }
    $applicationInsightsConnectionString = ''
    if ($ApplicationInsightsResourceId) {
        $applicationInsightsConnectionString = az resource show --ids $ApplicationInsightsResourceId --query properties.ConnectionString --output tsv
        if ($LASTEXITCODE -ne 0 -or -not $applicationInsightsConnectionString) { throw 'Could not read the selected Application Insights connection string.' }
    }
    if (-not $applicationInsightsConnectionString) {
        Write-Warning "No Application Insights in '$PlatformResourceGroup'; the services will send no telemetry."
    }
    if (-not $AlertActionGroupId) {
        $actionGroupIds = az monitor action-group list --resource-group $PlatformResourceGroup --query '[].id' --output json
        if ($LASTEXITCODE -ne 0) { throw 'Could not discover the alert action group.' }
        $actionGroupIds = @($actionGroupIds | ConvertFrom-Json)
        if ($actionGroupIds.Count -gt 1) { throw 'Several alert action groups exist. Set Environment.AlertActionGroupId explicitly.' }
        if ($actionGroupIds.Count -eq 1) { $AlertActionGroupId = $actionGroupIds[0] }
    }
    $dnsLabel = kubectl get service nginx -n $IngressNamespace --context $KubeContext --ignore-not-found `
        -o 'jsonpath={.metadata.annotations.service\.beta\.kubernetes\.io/azure-dns-label-name}'
    if ($LASTEXITCODE -ne 0) { throw 'Could not discover the managed ingress host.' }
    $ingressHost = if ($dnsLabel) { "$dnsLabel.$Location.cloudapp.azure.com" } else { '' }

    # The bootstrap Environment breaks the dependency between rad deploy and the real Recipe Pack.
    Invoke-OmsChecked 'rad env create bootstrap' {
        rad env create bootstrap --group $ResourceGroup --workspace $WorkspaceName
    }
    $recipePackParameters = New-OmsParameterFile @{
        registry                            = $Registry
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
        ingressClassName                    = $IngressClassName
        ingressHost                         = $ingressHost
        ingressCertIssuer                   = $(if ($ingressHost) { $IngressCertIssuer } else { '' })
    }
    $temporaryFiles += $recipePackParameters
    Write-Host '==> Deploying Recipe Pack' -ForegroundColor Cyan
    Invoke-OmsChecked 'rad deploy recipe pack' {
        rad deploy (Join-Path $LibraryRecipePackRoot 'azure.bicep') `
            --workspace $WorkspaceName --group $ResourceGroup --environment bootstrap `
            --parameters "@$recipePackParameters"
    }
    $environmentValues = @{
        subscriptionId    = $SubscriptionId
        resourceGroupName = $AppInfraResourceGroup
        environmentName   = $EnvironmentName
        namespace         = $AppNamespace
    }
    $environmentParameters = New-OmsParameterFile $environmentValues
    $temporaryFiles += $environmentParameters
    Write-Host "==> Deploying Environment '$EnvironmentName'" -ForegroundColor Cyan
    Invoke-OmsChecked 'rad deploy environment' {
        rad deploy deploy/environments/azure.bicep --workspace $WorkspaceName --group $ResourceGroup `
            --environment bootstrap --parameters "@$environmentParameters"
    }
    if ($RegistryUsername) {
        Write-Host '==> Configuring private registry authentication for Recipes' -ForegroundColor Cyan
        $registryParameters = New-OmsParameterFile @{
            registryHost     = $Registry
            registryUsername = $RegistryUsername
            registryPassword = [System.Net.NetworkCredential]::new('', $RegistryPassword).Password
        }
        $temporaryFiles += $registryParameters
        Invoke-OmsChecked 'rad deploy registry auth' {
            rad deploy deploy/recipe-registry-credentials.bicep --workspace $WorkspaceName --group $ResourceGroup `
                --environment $EnvironmentName --parameters "@$registryParameters"
        }
        # Resolve the deployed ID rather than hand-constructing it.
        $settingsJson = rad resource show Radius.Core/bicepSettings oms-registry-auth `
            --workspace $WorkspaceName --group $ResourceGroup --output json
        if ($LASTEXITCODE -ne 0) { throw 'Could not read the deployed bicepSettings resource.' }
        $bicepSettingsId = ($settingsJson | ConvertFrom-Json).id
        if ([string]::IsNullOrWhiteSpace($bicepSettingsId)) { throw 'Could not resolve the bicepSettings resource ID.' }
        $environmentValues.bicepSettingsId = $bicepSettingsId
        $authenticatedEnvironmentParameters = New-OmsParameterFile $environmentValues
        $temporaryFiles += $authenticatedEnvironmentParameters
        Invoke-OmsChecked 'rad deploy environment with registry auth' {
            rad deploy deploy/environments/azure.bicep --workspace $WorkspaceName --group $ResourceGroup `
                --environment bootstrap --parameters "@$authenticatedEnvironmentParameters"
        }
        Write-Host "Re-run environment configuration before the Recipe pull credential expires ($RecipeTokenDays days for generated tokens)." -ForegroundColor Yellow
    }
    else {
        Write-Host '==> Skipping registry authentication; assuming anonymous pull is enabled' -ForegroundColor DarkGray
    }
    Write-Host "`nAzure Radius environment '$EnvironmentName' configured. Next:" -ForegroundColor Green
    Write-Host "  ./scripts/deploy/azure.ps1 ``"
    Write-Host "    -Registry $Registry -SubscriptionId $SubscriptionId ``"
    Write-Host "    -AppInfraResourceGroup $AppInfraResourceGroup -PlatformResourceGroup $PlatformResourceGroup ``"
    Write-Host "    -ClusterName $ClusterName -KubeContext $KubeContext -WorkspaceName $WorkspaceName ``"
    Write-Host "    -ResourceGroup $ResourceGroup -EnvironmentName $EnvironmentName -AppNamespace $AppNamespace ``"
    Write-Host "    -IdentityPrefix $IdentityPrefix -DatabaseAdminServiceAccountName $DatabaseAdminServiceAccountName ``"
    Write-Host "    -Location $Location -UseEntraAuthentication `$$UseEntraAuthentication"
}
finally {
    $tokenPassword = $null
    foreach ($file in $temporaryFiles) { Remove-Item $file -Force -ErrorAction SilentlyContinue }
    Pop-Location
}
