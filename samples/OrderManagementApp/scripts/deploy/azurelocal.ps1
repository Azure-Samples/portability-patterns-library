#Requires -Version 7.0
<#
.SYNOPSIS
    Builds and deploys the same Order Management application to an existing Azure Local environment.
.DESCRIPTION
    Run configure-environment.ps1 once after platform setup. This script builds and publishes
    images and Recipes, waits for registry synchronization, deploys app.bicep, initializes database
    users and checks readiness. It does not install Radius or change platform configuration.
    Changed database passwords require the explicit rotate-database-passwords.ps1 operation.
.EXAMPLE
    ./scripts/deploy.ps1 -Target AzureLocal
.EXAMPLE
    ./scripts/deploy.ps1 -Target AzureLocal -SkipImageBuild
#>
[CmdletBinding()]
param(
    [string]$RegistryName = '<acr-name>',
    [string]$RegistryResourceGroup = 'bcd-azurelocal',
    [string]$KubeContext = 'bcd-aksarc',
    [string]$PullRegistry,
    [string]$ImagePullSecretName = 'azurelocal-registry',
    [string]$RegistryCaConfigMapName = 'azurelocal-registry-ca',
    [int]$SyncTimeoutMinutes = 20,
    [string]$ResourceGroup = 'oms',
    [string]$WorkspaceName = 'oms-azurelocal',
    [string]$EnvironmentName = 'oms-azurelocal',
    [string]$Namespace = 'oms-azurelocal',
    [string]$ImageTag = 'latest',
    [string[]]$Services = @('api', 'processor', 'inventory'),
    [string]$PasswordsSecretName = 'oms-db-passwords',
    [string]$AppliedAdminSecretName = 'oms-db-admin',
    [string]$DatabaseSetupConfigMapName = 'oms-db-setup',
    [string]$MonitoringNamespace = 'observability',
    [int]$RolloutTimeoutSeconds = 900,
    [string]$InventoryClientId = 'oms-inventory',
    [string]$OrdersApiClientId = 'oms-api',
    [string]$OrdersSpaClientId = 'oms-spa',
    [int]$UiLocalPort = 5090,
    [string]$IngressNamespace = 'ingress-nginx',
    [switch]$SkipImageBuild
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repoRoot 'scripts/lib/recipes.ps1')
. (Join-Path $repoRoot 'scripts/lib/cluster.ps1')
. (Join-Path $repoRoot 'scripts/lib/database.ps1')
. (Join-Path $repoRoot 'scripts/lib/database-passwords.ps1')
. (Join-Path $repoRoot 'scripts/lib/registry.ps1')
. (Join-Path $repoRoot 'scripts/lib/deployment.ps1')
Push-Location $repoRoot
$temporaryFiles = @()

try {
    if ($PSVersionTable.PSEdition -ne 'Core') { throw 'Run this script under PowerShell 7 (pwsh).' }
    # The Recipe Pack and the app definition use the queue type, so Bicep needs its extension.
    Invoke-OmsChecked 'rad bicep publish-extension' {
        rad bicep publish-extension -f $QueueTypeFile --target $QueueTypeExtension
    }

    Write-Host "==> Checking the cluster is reachable" -ForegroundColor Cyan
    Invoke-OmsChecked 'kubectl cluster-info' { kubectl cluster-info --context $KubeContext --request-timeout=20s | Out-Null }

    $environmentJson = rad resource show Radius.Core/environments $EnvironmentName `
        --workspace $WorkspaceName --group $ResourceGroup --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $environmentJson) {
        throw "Radius environment '$EnvironmentName' is missing. Run ./scripts/configure-environment.ps1 -Target AzureLocal first."
    }
    $packJson = rad resource show Radius.Core/recipePacks azure-local-recipes `
        --workspace $WorkspaceName --group $ResourceGroup --output json
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the configured Azure Local Recipe Pack.' }
    $pack = $packJson | ConvertFrom-Json
    $oauthIssuer = $pack.properties.recipes.'Radius.Compute/containers'.parameters.oauthIssuer
    $recipeSource = $pack.properties.recipes.'Portability.Messaging/messageQueues'.source
    if ($recipeSource -notmatch ':(?<tag>[^/:]+)$') { throw 'The configured queue Recipe has no tag. Reconfigure the sample Recipe Pack.' }
    $recipeTag = $Matches.tag
    $registry = Get-OmsConnectedRegistry $KubeContext $Namespace $PullRegistry $ImagePullSecretName $RegistryCaConfigMapName
    $PullRegistry = $registry.Host
    $passwords = Get-OmsDatabasePasswords $KubeContext $Namespace $PasswordsSecretName
    $applied = Get-OmsSecretData $KubeContext $Namespace $AppliedAdminSecretName
    Assert-OmsDatabasePasswordsUnchanged $KubeContext $Namespace $passwords $applied
    $ingressAddress = kubectl get service ingress-nginx-controller -n $IngressNamespace --context $KubeContext `
        --ignore-not-found -o 'jsonpath={.status.loadBalancer.ingress[0].ip}'
    if ($LASTEXITCODE -ne 0) { throw 'Could not read ingress configuration.' }
    $useIngress = -not [string]::IsNullOrWhiteSpace($ingressAddress)

    $pushRegistry = az acr show --name $RegistryName --resource-group $RegistryResourceGroup --query loginServer --output tsv
    if ($LASTEXITCODE -ne 0 -or -not $pushRegistry) { throw "Registry '$RegistryName' not found." }

    # ------------------------------------------------------------------------------------------
    # Build, push and publish to the cloud registry.
    # ------------------------------------------------------------------------------------------
    # An ACR access token lasts three hours, plenty for one run. It is written to the Docker-
    # compatible config as well, because that is where 'rad bicep publish' looks for credentials.
    Write-Host "==> Signing in to $pushRegistry" -ForegroundColor Cyan
    $acrToken = az acr login --name $RegistryName --expose-token --query accessToken --output tsv
    if ($LASTEXITCODE -ne 0 -or -not $acrToken) { throw 'az acr login --expose-token failed.' }

    $containerTool = if (Get-Command podman -ErrorAction SilentlyContinue) { 'podman' }
    elseif (Get-Command docker -ErrorAction SilentlyContinue) { 'docker' }
    else { $null }

    $dockerConfigFile = Join-Path $HOME '.docker/config.json'
    New-Item -ItemType Directory -Force -Path (Split-Path $dockerConfigFile) | Out-Null
    $acrUser = '00000000-0000-0000-0000-000000000000'
    if ($containerTool -eq 'podman') {
        $acrToken | podman login $pushRegistry --username $acrUser --password-stdin | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'podman login failed.' }
        $acrToken | podman login $pushRegistry --username $acrUser --password-stdin --compat-auth-file $dockerConfigFile | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'podman login (Docker-compatible config) failed.' }
    }
    elseif ($containerTool -eq 'docker') {
        $acrToken | docker login $pushRegistry --username $acrUser --password-stdin | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'docker login failed.' }
    }
    else {
        # No container engine, for example on Windows Server. 'rad bicep publish' still needs the
        # registry credential in the Docker-compatible config, so it is written there directly.
        $dockerConfig = if (Test-Path $dockerConfigFile) { Get-Content $dockerConfigFile -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
        if (-not $dockerConfig.auths) { $dockerConfig.auths = @{} }
        $dockerConfig.auths[$pushRegistry] = @{ auth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${acrUser}:$acrToken")) }
        [System.IO.File]::WriteAllText($dockerConfigFile, ($dockerConfig | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))
    }
    $acrToken = $null

    $components = @('api', 'processor', 'inventory', 'dbsetup')
    if (-not $SkipImageBuild) {
        foreach ($component in $components) {
            $image = "$pushRegistry/oms/${component}:$ImageTag"
            if ($containerTool) {
                Write-Host "==> Building $component with $containerTool against base images in $pushRegistry" -ForegroundColor Cyan
                Invoke-OmsChecked "$containerTool build $component" {
                    & $containerTool build --build-arg "BASE_REGISTRY=$pushRegistry" -f "docker/Dockerfile.$component" -t $image .
                }
                Invoke-OmsChecked "$containerTool push $component" { & $containerTool push $image }
            }
            else {
                # ACR builds the image itself, so this machine needs no container engine.
                Write-Host "==> Building $component in $RegistryName (az acr build)" -ForegroundColor Cyan
                Invoke-OmsChecked "az acr build $component" {
                    az acr build --registry $RegistryName --resource-group $RegistryResourceGroup `
                        --image "oms/${component}:$ImageTag" --build-arg "BASE_REGISTRY=$pushRegistry" `
                        --file "docker/Dockerfile.$component" --platform linux/amd64 . --output none
                }
            }
        }
    }

    Write-Host "==> Publishing Recipes to $pushRegistry" -ForegroundColor Cyan
    ./scripts/deploy/publish-recipes.ps1 -Registry $pushRegistry -Platform azure-local -Tag $recipeTag

    # The cluster pulls latest-tagged images and Recipes by tag, so a stale digest would still
    # answer 200. Their digests in the cloud registry are what the sync check below waits for.
    $expectedDigests = @{}
    # Application image releases need not change the Recipe tag selected by platform setup.
    $published = @($components | ForEach-Object { "oms/${_}:$ImageTag" }) +
        (Get-LibraryRecipe -Platform azure-local | ForEach-Object { "recipes/$($_.BaseName):$recipeTag" })
    foreach ($artifact in $published) {
        $expectedDigests[$artifact] = az acr manifest show-metadata "$pushRegistry/$artifact" --query digest --output tsv 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $expectedDigests[$artifact]) { throw "Could not read the digest of $artifact in $pushRegistry." }
    }

    $artifacts = @($expectedDigests.Keys) + @('radius-project/kube-recipes/secrets:latest')
    Wait-OmsRegistrySync -KubeContext $KubeContext -Registry $registry -Artifacts $artifacts `
        -ExpectedDigests $expectedDigests -TimeoutMinutes $SyncTimeoutMinutes

    # User sign-in for the orders API and browser app goes through the same Keycloak realm. Only
    # these values differ from an Entra deployment; the application code is identical.
    $apiAuthentication = @{}
    $spaSettings = @{}
    if ($oauthIssuer) {
        $apiAuthentication = @{
            Authority       = $oauthIssuer
            # Microsoft.Identity.Web appends '/v2.0' to an authority (an Entra convention).
            MetadataAddress = "$oauthIssuer/.well-known/openid-configuration"
            ClientId        = $OrdersApiClientId
            Audience        = $OrdersApiClientId
        }
        $spaSettings = @{
            Authority        = $oauthIssuer
            ClientId         = $OrdersSpaClientId
            ProtocolMode     = 'OIDC'
            # Keeps MSAL from validating the authority against login.microsoftonline.com.
            KnownAuthorities = ([uri]$oauthIssuer).Authority
            ApiScope         = "api://$OrdersApiClientId/access_as_user"
            IdentityProvider = 'Keycloak (Active Directory)'
            Environment      = 'Azure Local'
        }
    }

    # The inventory service accepts tokens Keycloak issued for its own client; the callers' tokens
    # carry that audience, so they need no scope.
    $inventoryAuthentication = @{}
    if ($oauthIssuer) {
        $inventoryAuthentication = @{
            Authority       = $oauthIssuer
            MetadataAddress = "$oauthIssuer/.well-known/openid-configuration"
            Audience        = $InventoryClientId
        }
    }

    # The same parameters as on Azure: everything platform-specific is in the Recipe Pack.
    # Images are pinned by digest: with a bare ':latest' the pod spec never changes, so a rebuild
    # never rolls out.
    $applicationParameters = New-OmsParameterFile @{
        apiImage                = "$PullRegistry/oms/api@$($expectedDigests["oms/api:$ImageTag"])"
        processorImage          = "$PullRegistry/oms/processor@$($expectedDigests["oms/processor:$ImageTag"])"
        inventoryImage          = "$PullRegistry/oms/inventory@$($expectedDigests["oms/inventory:$ImageTag"])"
        apiAuthentication       = $apiAuthentication
        spaSettings             = $spaSettings
        inventoryAuthentication = $inventoryAuthentication
        sqlAdminPassword        = $passwords['sql-admin-password']
        postgresAdminPassword   = $passwords['postgres-admin-password']
    }
    $temporaryFiles += $applicationParameters

    Write-Host "==> Deploying the application" -ForegroundColor Cyan
    Invoke-OmsChecked 'rad deploy application' {
        rad deploy deploy/app.bicep `
            --workspace $WorkspaceName `
            --group $ResourceGroup `
            --environment $EnvironmentName `
            --parameters "@$applicationParameters"
    }

    # 'rad deploy' returns once the resources are applied, not once the pods are serving.
    Write-Host "==> Waiting for the backing services (images come from $PullRegistry)" -ForegroundColor Cyan
    Invoke-OmsChecked 'kubectl rollout status' {
        kubectl rollout status statefulset --namespace $Namespace --context $KubeContext `
            --timeout="${RolloutTimeoutSeconds}s" | Out-Null
    }

    $monitoringPresent = kubectl get namespace $MonitoringNamespace --context $KubeContext --ignore-not-found -o name 2>$null
    Set-OmsNetworkPolicy -KubeContext $KubeContext -Namespace $Namespace -IngressNamespace $IngressNamespace `
        -MonitoringNamespace $(if ($monitoringPresent) { $MonitoringNamespace } else { '' }) `
        -ManifestPath (Join-Path $repoRoot 'deploy/network-policies.yaml')

    # As the database administrators, create the schemas and each service's database user with
    # only the rights it needs, setting the passwords from Key Vault.
    $databaseSetupImage = "$PullRegistry/oms/dbsetup@$($expectedDigests["oms/dbsetup:$ImageTag"])"
    Invoke-OmsLocalDatabaseSetup -KubeContext $KubeContext -Namespace $Namespace -WorkspaceName $WorkspaceName `
        -ResourceGroup $ResourceGroup -Image $databaseSetupImage -ImagePullSecretName $ImagePullSecretName `
        -PasswordsSecretName $PasswordsSecretName
    Set-OmsSecret $KubeContext $Namespace $AppliedAdminSecretName @{
        'sql-admin-password' = $passwords['sql-admin-password']
        'postgres-admin-password' = $passwords['postgres-admin-password']
    }
    Set-OmsServiceDatabasePasswords $KubeContext $Namespace $passwords
    kubectl create configmap $DatabaseSetupConfigMapName -n $Namespace --context $KubeContext `
        --from-literal="image=$databaseSetupImage" --dry-run=client -o yaml |
        kubectl apply --context $KubeContext -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Recording the database setup image for password rotation failed.' }
    $passwords = $null

    # Environment variables from a Secret are read when a container starts, so the services restart
    # to pick up their credentials.
    Write-Host "==> Waiting for the application to roll out" -ForegroundColor Cyan
    foreach ($service in $Services) {
        Invoke-OmsChecked "restart $service" {
            kubectl rollout restart deployment $service --namespace $Namespace --context $KubeContext | Out-Null
        }
    }
    Invoke-OmsChecked 'kubectl rollout status' {
        kubectl rollout status deployment --namespace $Namespace --context $KubeContext `
            --timeout="${RolloutTimeoutSeconds}s" | Out-Null
    }
    Write-Host "`nDeployed to Azure Local (AKS Arc)." -ForegroundColor Green
    if ($useIngress) {
        Write-Host "Open the orders app: https://$ingressAddress"
    }
    else {
        Write-Host "Open the orders app (MSAL needs a secure context, so it is served on localhost):"
        Write-Host "  kubectl port-forward -n $Namespace service/api-api ${UiLocalPort}:8080 --context $KubeContext"
        Write-Host "  http://localhost:$UiLocalPort"
    }
    Write-Host "Watch the order processor with:"
    Write-Host "  kubectl logs -n $Namespace -l radapp.io/resource=processor --context $KubeContext -f"
}
finally {
    foreach ($file in $temporaryFiles) {
        Remove-Item $file -Force -ErrorAction SilentlyContinue
    }
    Pop-Location
}
