<#
.SYNOPSIS
    Deploys the Order Management sample to an AKS cluster backed by Azure PaaS.

.DESCRIPTION
    Assumes ./scripts/azure/provision-infra.ps1 (or bootstrap-identity.ps1 against an existing
    cluster) has already created the workload identity, and that `rad credential register azure`
    has been run.

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
    ./scripts/azure/deploy.ps1 `
        -Registry mycr.azurecr.io `
        -SubscriptionId 00000000-0000-0000-0000-000000000000 `
        -AppInfraResourceGroup bcd-infra `
        -WorkloadIdentityPrincipalId <principal-id>

.EXAMPLE
    # Private registry: supply a scoped ACR token so the Radius control plane can pull Recipes.
    #   az acr token create --registry mycr --name bcd-recipe-puller `
    #       --repository oms/recipes content/read --expiration-in-days 30
    ./scripts/azure/deploy.ps1 `
        -Registry mycr.azurecr.io `
        -SubscriptionId <sub-id> `
        -AppInfraResourceGroup bcd-infra `
        -WorkloadIdentityPrincipalId <principal-id> `
        -RegistryUsername bcd-recipe-puller `
        -RegistryPassword (Read-Host -AsSecureString)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Registry,
    [Parameter(Mandatory = $true)][string]$SubscriptionId,

    # The Azure resource group that Radius Recipes provision application infrastructure into
    # (Service Bus, Storage account, Azure SQL). It may be the same group that holds the platform
    # infrastructure created by provision-infra.ps1, or a separate one. Either way it must already
    # exist: Radius does not create it.
    [Parameter(Mandatory = $true)][string]$AppInfraResourceGroup,

    [Parameter(Mandatory = $true)][string]$WorkloadIdentityPrincipalId,

    # Optional. Azure SQL is created with Entra-only authentication, so no SQL login exists and this
    # value never reaches Azure. It is still required by the Radius Resource Type, so when omitted a
    # random value is generated to satisfy the schema. Supply one only if you set the SQL Recipe's
    # azureAdOnlyAuthentication parameter to false.
    [securestring]$SqlAdminPassword,

    # Supply these when the registry hosting the Recipes requires authentication. The Radius control
    # plane pulls Recipes itself, so `az aks update --attach-acr` does not cover it.
    [string]$RegistryUsername,
    [securestring]$RegistryPassword,

    [string]$WorkloadIdentityName = 'bcd-workload-identity',
    [string]$ServiceAccountName = 'oms-workload-identity',

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

    # Region for the Azure SQL logical server. Defaults to $Location. Override when the primary
    # region refuses new SQL servers (RegionDoesNotAllowProvisioning); Azure SQL is reached over its
    # public FQDN, so a different region works at the cost of latency and cross-region egress.
    [string]$SqlLocation,

    # Entra app registrations for user sign-in, as created by scripts/azure/configure-app-identity.ps1.
    [string]$OrdersApiAppName = 'oms-api',
    [string]$OrdersSpaAppName = 'oms-spa',
    [int]$UiLocalPort = 5090,

    # Managed ingress from scripts/azure/provision-ingress.ps1.
    [string]$IngressClassName = 'webapprouting.kubernetes.azure.com',
    [string]$IngressCertIssuer = 'letsencrypt',

    # Lifetime of the read-only registry token minted for Recipe pulls when no -RegistryUsername is given.
    [int]$RecipeTokenDays = 7,
    [switch]$SkipImageBuild
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

    $path = Join-Path ([System.IO.Path]::GetTempPath()) "oms-params-$([guid]::NewGuid().ToString('N')).json"
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
        $anonymousPull = az acr show --name $acrName --query anonymousPullEnabled --output tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and $anonymousPull -eq 'false') {
            # A scoped, read-only, expiring token. ACR repository names are literal, so every Recipe
            # repository is listed individually. Refreshed on each run so it never silently expires.
            Write-Host "==> Minting a read-only Recipe pull token for $Registry ($RecipeTokenDays days)" -ForegroundColor Cyan
            $RegistryUsername = 'bcd-recipe-puller'
            $repositories = Get-ChildItem deploy/recipes/azure, deploy/recipes/kubernetes -Filter *.bicep |
                ForEach-Object { "oms/recipes/$($_.BaseName)" }
            $scopeArguments = $repositories | ForEach-Object { '--repository', $_, 'content/read', 'metadata/read' }

            az acr scope-map show --registry $acrName --name $RegistryUsername --only-show-errors 2>$null | Out-Null
            $scopeVerb = if ($LASTEXITCODE -eq 0) { 'update' } else { 'create' }
            if ($scopeVerb -eq 'update') {
                $scopeArguments = $repositories | ForEach-Object { '--add-repository', $_, 'content/read', 'metadata/read' }
            }
            Invoke-Checked "az acr scope-map $scopeVerb" {
                az acr scope-map $scopeVerb --registry $acrName --name $RegistryUsername @scopeArguments --only-show-errors | Out-Null
            }
            az acr token show --registry $acrName --name $RegistryUsername --only-show-errors 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) {
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

    # Mint a fresh ServiceAccount token before anything else. Without this the deployment depends on
    # a token minted by provision-infra.ps1, which expires (24h by default) and does not exist at
    # all on a machine that never ran it, such as a CI agent. See ensure-radius-context.ps1.
    if ($UseEntraAuthentication) {
        $KubeContext = ./scripts/azure/ensure-radius-context.ps1 `
            -ClusterName $ClusterName `
            -TokenHours $RadiusCliTokenHours
    }

    # The workspace must be bound to the AKS cluster before any group is created, otherwise `rad`
    # targets whichever cluster the default workspace points at. --context is explicit for the same
    # reason. The group cannot be set on first creation because it does not exist yet, so the
    # workspace is created twice.
    Write-Host "==> Binding Radius workspace '$WorkspaceName' to context '$KubeContext'" -ForegroundColor Cyan
    Invoke-Checked 'rad workspace create' {
        rad workspace create kubernetes $WorkspaceName --context $KubeContext --force
    }
    Invoke-Checked 'rad group create' { rad group create $ResourceGroup --workspace $WorkspaceName }
    Invoke-Checked 'rad workspace bind group' {
        rad workspace create kubernetes $WorkspaceName --context $KubeContext --group $ResourceGroup --force
    }

    Write-Host "==> Registering the messageQueues Resource Type" -ForegroundColor Cyan
    Invoke-Checked 'rad resource-type create' {
        rad resource-type create messageQueues -f deploy/types/messageQueues.yaml --workspace $WorkspaceName
    }
    Invoke-Checked 'rad bicep publish-extension' {
        rad bicep publish-extension -f deploy/types/messageQueues.yaml --target deploy/types/orderManagement.tgz
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

    if (-not $SkipImageBuild) {
        if (-not $containerTool) { throw 'Neither podman nor docker is on PATH. Install one, or pass -SkipImageBuild.' }

        Write-Host "==> Building and pushing images to $Registry with $containerTool" -ForegroundColor Cyan
        foreach ($worker in @('api', 'processor')) {
            Invoke-Checked "$containerTool build $worker" {
                & $containerTool build -f "docker/Dockerfile.$worker" -t "$Registry/oms/${worker}:latest" .
            }
            Invoke-Checked "$containerTool push $worker" { & $containerTool push "$Registry/oms/${worker}:latest" }
        }
    }

    # Pinned by digest: with a bare ':latest' the pod spec never changes, so a rebuild never rolls out.
    $imageDigests = @{}
    foreach ($worker in @('api', 'processor')) {
        $imageDigests[$worker] = az acr manifest show-metadata "$Registry/oms/${worker}:latest" --query digest --output tsv 2>$null
        if (-not $imageDigests[$worker]) { throw "Could not read the digest of oms/${worker}:latest in $Registry." }
    }

    Write-Host "==> Publishing Azure Recipes" -ForegroundColor Cyan
    ./scripts/publish-recipes.ps1 -Registry $Registry -Set azure

    # `rad deploy` always needs an environment to deploy into, including for the Recipe Pack that
    # the real environment depends on.
    Write-Host "==> Creating the bootstrap environment" -ForegroundColor Cyan
    Invoke-Checked 'rad env create bootstrap' {
        rad env create bootstrap --group $ResourceGroup --workspace $WorkspaceName
    }

    Write-Host "==> Deploying Recipe Pack" -ForegroundColor Cyan
    if (-not $SqlLocation) { $SqlLocation = $Location }

    # Published through the managed ingress when scripts/azure/provision-ingress.ps1 has set it up.
    $dnsLabel = kubectl get service nginx -n app-routing-system --context $KubeContext --ignore-not-found `
        -o 'jsonpath={.metadata.annotations.service\.beta\.kubernetes\.io/azure-dns-label-name}' 2>$null
    $ingressHost = if ($dnsLabel) { "$dnsLabel.$Location.cloudapp.azure.com" } else { '' }
    if ($ingressHost) { Write-Host "    publishing through the managed ingress at https://$ingressHost" -ForegroundColor DarkGray }
    Invoke-Checked 'rad deploy recipe pack' {
        rad deploy deploy/recipe-packs/azure.bicep `
            --workspace $WorkspaceName `
            --group $ResourceGroup `
            --environment bootstrap `
            --parameters registry=$Registry `
            --parameters workloadIdentityPrincipalId=$WorkloadIdentityPrincipalId `
            --parameters workloadIdentityName=$WorkloadIdentityName `
            --parameters serviceAccountName=$ServiceAccountName `
            --parameters location=$Location `
            --parameters sqlLocation=$SqlLocation `
            --parameters ingressClassName=$(if ($ingressHost) { $IngressClassName } else { '' }) `
            --parameters ingressHost=$ingressHost `
            --parameters ingressCertIssuer=$(if ($ingressHost) { $IngressCertIssuer } else { '' })
    }

    Write-Host "==> Deploying Environment" -ForegroundColor Cyan
    Invoke-Checked 'rad deploy environment' {
        rad deploy deploy/environments/azure.bicep `
            --workspace $WorkspaceName `
            --group $ResourceGroup `
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
        $plainRegistryPassword = [System.Net.NetworkCredential]::new('', $RegistryPassword).Password

        Invoke-Checked 'rad deploy registry auth' {
            rad deploy deploy/registry-auth.bicep `
                --workspace $WorkspaceName `
                --group $ResourceGroup `
                --environment $EnvironmentName `
                --parameters registryHost=$Registry `
                --parameters registryUsername=$RegistryUsername `
                --parameters registryPassword=$plainRegistryPassword
        }

        Write-Host "==> Pointing the Environment at the registry credentials" -ForegroundColor Cyan

        # Look the ID up rather than hand-constructing it, and pass it as a string. A conditional
        # `existing` reference inside the template fails before the resource exists.
        $bicepSettingsId = rad resource show Radius.Core/bicepSettings oms-registry-auth `
            --workspace $WorkspaceName --group $ResourceGroup --output json 2>$null |
            ConvertFrom-Json | Select-Object -ExpandProperty id
        if ([string]::IsNullOrWhiteSpace($bicepSettingsId)) {
            throw 'Could not resolve the ID of the bicepSettings resource just deployed.'
        }

        Invoke-Checked 'rad deploy environment with registry auth' {
            rad deploy deploy/environments/azure.bicep `
                --workspace $WorkspaceName `
                --group $ResourceGroup `
                --environment bootstrap `
                --parameters subscriptionId=$SubscriptionId `
                --parameters resourceGroupName=$AppInfraResourceGroup `
                --parameters bicepSettingsId=$bicepSettingsId
        }
    }
    else {
        Write-Host "==> Skipping registry authentication; assuming anonymous pull is enabled" -ForegroundColor DarkGray
    }

    if ($SqlAdminPassword) {
        $plainPassword = [System.Net.NetworkCredential]::new('', $SqlAdminPassword).Password
    }
    else {
        # The Azure SQL Recipe creates the server with Entra-only authentication, so it never sends
        # a login or password to Azure. The Radius Resource Type still marks `password` as required,
        # so generate a value that satisfies the schema and is then discarded. Nothing can
        # authenticate with it: SQL authentication is disabled on the server.
        $randomBytes = [byte[]]::new(24)
        [System.Security.Cryptography.RandomNumberGenerator]::Fill($randomBytes)
        $plainPassword = 'Oms1!' + [Convert]::ToBase64String($randomBytes)
        Write-Host "==> No -SqlAdminPassword supplied; generated an unused value (Azure SQL uses Entra-only auth)" -ForegroundColor DarkGray
    }

    # User sign-in through Entra ID. Same app code as Azure Local; only these values differ.
    $tenantId = az account show --query tenantId --output tsv
    $apiAppId = az ad app list --display-name $OrdersApiAppName --query '[0].appId' --output tsv
    $spaAppId = az ad app list --display-name $OrdersSpaAppName --query '[0].appId' --output tsv
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
        Write-Warning "App registrations '$OrdersApiAppName'/'$OrdersSpaAppName' not found; the orders app will have no sign-in. Run scripts/azure/configure-app-identity.ps1."
    }

    # The same parameters as on Azure Local: everything platform-specific is in the Recipe Pack.
    $applicationParameters = New-ParameterFile @{
        apiImage          = "$Registry/oms/api@$($imageDigests['api'])"
        processorImage    = "$Registry/oms/processor@$($imageDigests['processor'])"
        apiAuthentication = $apiAuthentication
        spaSettings       = $spaSettings
        sqlAdminPassword  = $plainPassword
    }
    $temporaryFiles += $applicationParameters

    Write-Host "==> Deploying application" -ForegroundColor Cyan
    Invoke-Checked 'rad deploy application' {
        rad deploy deploy/app.bicep `
            --workspace $WorkspaceName `
            --group $ResourceGroup `
            --environment $EnvironmentName `
            --parameters "@$applicationParameters"
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
