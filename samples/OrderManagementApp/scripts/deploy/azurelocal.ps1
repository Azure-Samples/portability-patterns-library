<#
.SYNOPSIS
    Deploys the Order Management sample to AKS enabled by Arc on a connected Azure Local
    instance.

.DESCRIPTION
    The Azure Local instance is connected, but the workload is built to keep running if that link
    drops. So the backing services are in-cluster containers (RabbitMQ, SQL Server, PostgreSQL,
    Azurite), identity is the in-cluster Keycloak bound to the site's Active Directory, and
    every image and Recipe is pulled from the ACR connected registry inside the cluster.

    Each service signs in to Keycloak as itself, with its Kubernetes service account token
    (Keycloak client workload-<service>), and to its database as its own least-privilege user. The
    database passwords come from Key Vault, synced into Secret oms-db-passwords by the Key Vault
    Secret Store extension (setup-platform.ps1, KeyVault step). This script sets them in the
    databases through the database setup job, then copies each service's password into
    <service>-db-credentials, which the Recipe Pack hands to that service only. So to change a
    password: set a new version in Key Vault, wait for the sync, and run this script again.

    Two registries are involved:

      * Push registry  - the Premium ACR in Azure (<acr-name>.azurecr.io). Images are built
                         and Recipes published here, from this machine.
      * Pull registry  - the connected registry's ClusterIP inside the cluster. Kubelet and the
                         Radius control plane pull from here. It syncs from the push registry while
                         the link is up and keeps serving what it has when it is not.

    Prerequisite: ./scripts/setup-platform.ps1 -Target AzureLocal (cluster, image mirror, connected
    registry, Key Vault sync, Keycloak, ingress and the orders app's sign-in registration). Usually
    run through ./scripts/deploy.ps1 -Target AzureLocal, which supplies the settings.

    Images are built with podman when it is available, otherwise docker. With neither, for example
    on Windows Server, the registry builds them itself with 'az acr build' (ACR Tasks).

.PARAMETER ReinstallRadius
    Reinstall the Radius control plane even when present. Needed whenever the registry CA or pull
    secret changes, since 'rad install kubernetes' otherwise leaves an existing installation alone.

.EXAMPLE
    ./scripts/deploy/azurelocal.ps1 -RegistryName <acr-name> -KubeContext bcd-aksarc

.EXAMPLE
    # Apply passwords changed in Key Vault, without rebuilding or reinstalling Radius.
    ./scripts/deploy/azurelocal.ps1 -RegistryName <acr-name> -SkipImageBuild -SkipRadiusInstall
#>
[CmdletBinding()]
param(
    [string]$RegistryName = '<acr-name>',
    [string]$RegistryResourceGroup = 'bcd-azurelocal',
    [string]$KubeContext = 'bcd-aksarc',

    # Connected registry address, its pull secret and CA, as written by connected-registry.ps1. An
    # empty address is read from the pull secret.
    [string]$PullRegistry,
    [string]$ImagePullSecretName = 'azurelocal-registry',
    [string]$RegistryCaConfigMapName = 'azurelocal-registry-ca',
    [int]$SyncTimeoutMinutes = 20,

    [switch]$ReinstallRadius,

    [string]$ResourceGroup = 'oms',
    [string]$WorkspaceName = 'oms-azurelocal',
    [string]$EnvironmentName = 'oms-azurelocal',
    [string]$Namespace = 'oms-azurelocal',
    [string]$RadiusVersion = '0.60',
    [string]$ImageTag = 'latest',

    # The application's services; each gets its own service account, Keycloak client and database user.
    [string[]]$Services = @('api', 'processor', 'inventory'),

    # Database passwords synced from Key Vault by scripts/infra/azurelocal/key-vault.ps1, and the
    # Secret that records the administrator passwords the databases currently have.
    [string]$PasswordsSecretName = 'oms-db-passwords',
    [string]$AppliedAdminSecretName = 'oms-db-admin',
    # SQL Server edition: Developer is not licensed for production; pass Standard, Enterprise or a product key.
    [string]$SqlServerEdition = 'Developer',
    # cert-manager ClusterIssuer from provision-ingress.ps1; PostgreSQL gets its TLS certificate from it.
    [string]$CertificateIssuer = 'site-ca',

    # On-site telemetry: the OpenTelemetry collector the services send to and the namespace that
    # scrapes the backing services' metrics. Not used when the collector isn't installed.
    [string]$MonitoringNamespace = 'observability',
    [string]$OtlpEndpoint = 'http://otel-collector.observability.svc.cluster.local:4317',

    # How long to wait for the application's Deployments to become available after 'rad deploy'.
    [int]$RolloutTimeoutSeconds = 900,

    [string]$IdentityNamespace = 'identity',
    [string]$KeycloakRelease = 'keycloak',
    [string]$KeycloakRealm = 'oms',
    [int]$KeycloakNodePort = 30443,
    # Keycloak clients the services authenticate as, from infra/azurelocal/keycloak/realm.json:
    # one per service, '{resource}' being the service's name. The inventory service accepts tokens
    # issued for its own client.
    [string]$WorkloadClientId = 'workload-{resource}',
    [string]$InventoryClientId = 'oms-inventory',
    [string]$IdentityCaSecretName = 'oms-identity-ca',
    [switch]$SkipOAuth,

    # Keycloak clients for user sign-in, defined in infra/azurelocal/keycloak/realm.json.
    [string]$OrdersApiClientId = 'oms-api',
    [string]$OrdersSpaClientId = 'oms-spa',
    [int]$UiLocalPort = 5090,

    # Ingress from scripts/infra/azurelocal/provision-ingress.ps1. Used when present; otherwise the app
    # is only reachable through kubectl port-forward.
    [string]$IngressNamespace = 'ingress-nginx',
    [string]$IngressClassName = 'nginx',
    [string]$IngressTlsSecretName = 'oms-app-tls',

    [switch]$SkipImageBuild,
    [switch]$SkipRadiusInstall
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repoRoot 'scripts/lib/recipes.ps1')
. (Join-Path $repoRoot 'scripts/lib/cluster.ps1')
. (Join-Path $repoRoot 'scripts/lib/database.ps1')
Push-Location $repoRoot

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

$temporaryFiles = @()
$portForward = $null

# `rad deploy --parameters key=value` only handles scalars, so anything else goes through a file.
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

    $path = Join-Path ([System.IO.Path]::GetTempPath()) "oms-azurelocal-params-$([guid]::NewGuid().ToString('N')).json"
    # The rad CLI rejects a UTF-8 BOM.
    [System.IO.File]::WriteAllText($path, ($document | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
    return $path
}

try {
    if ($PSVersionTable.PSEdition -ne 'Core') { throw 'Run this script under PowerShell 7 (pwsh).' }
    # The Recipe Pack and the app definition use the queue type, so Bicep needs its extension.
    Invoke-Checked 'rad bicep publish-extension' {
        rad bicep publish-extension -f $QueueTypeFile --target $QueueTypeExtension
    }

    Write-Host "==> Checking the cluster is reachable" -ForegroundColor Cyan
    Invoke-Checked 'kubectl cluster-info' { kubectl cluster-info --context $KubeContext --request-timeout=20s | Out-Null }

    kubectl create namespace $Namespace --context $KubeContext --dry-run=client -o yaml |
        kubectl apply --context $KubeContext -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Creating the application namespace failed.' }

    # ------------------------------------------------------------------------------------------
    # Connected registry credentials and CA, kept in the cluster by connected-registry.ps1.
    # ------------------------------------------------------------------------------------------
    if (-not $PullRegistry) { $PullRegistry = Get-OmsPullRegistry $KubeContext $Namespace $ImagePullSecretName }
    if (-not $PullRegistry) {
        throw "Pull secret '$ImagePullSecretName' is missing from '$Namespace'. Run scripts/infra/azurelocal/connected-registry.ps1 first."
    }
    $dockerConfigEncoded = kubectl get secret $ImagePullSecretName --context $KubeContext --namespace $Namespace `
        --ignore-not-found --output 'jsonpath={.data.\.dockerconfigjson}'
    if ([string]::IsNullOrWhiteSpace($dockerConfigEncoded)) {
        throw "Pull secret '$ImagePullSecretName' is missing from '$Namespace'. Run scripts/infra/azurelocal/connected-registry.ps1 first."
    }
    $pullAuth = ([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($dockerConfigEncoded)) | ConvertFrom-Json).auths.$PullRegistry
    if (-not $pullAuth -or -not $pullAuth.username -or -not $pullAuth.password) {
        throw "Pull secret '$ImagePullSecretName' holds no credentials for '$PullRegistry'."
    }

    $registryCaPem = (kubectl get configmap $RegistryCaConfigMapName --context $KubeContext --namespace $Namespace `
        --ignore-not-found --output 'jsonpath={.data.ca\.crt}') -join "`n"
    if ([string]::IsNullOrWhiteSpace($registryCaPem)) {
        throw "ConfigMap '$RegistryCaConfigMapName' is missing from '$Namespace'. Run scripts/infra/azurelocal/connected-registry.ps1 first."
    }
    $registryCaFile = Join-Path ([System.IO.Path]::GetTempPath()) "oms-azurelocal-ca-$([guid]::NewGuid().ToString('N')).crt"
    $temporaryFiles += $registryCaFile
    [System.IO.File]::WriteAllText($registryCaFile, $registryCaPem, [System.Text.UTF8Encoding]::new($false))

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
                Invoke-Checked "$containerTool build $component" {
                    & $containerTool build --build-arg "BASE_REGISTRY=$pushRegistry" -f "docker/Dockerfile.$component" -t $image .
                }
                Invoke-Checked "$containerTool push $component" { & $containerTool push $image }
            }
            else {
                # ACR builds the image itself, so this machine needs no container engine.
                Write-Host "==> Building $component in $RegistryName (az acr build)" -ForegroundColor Cyan
                Invoke-Checked "az acr build $component" {
                    az acr build --registry $RegistryName --resource-group $RegistryResourceGroup `
                        --image "oms/${component}:$ImageTag" --build-arg "BASE_REGISTRY=$pushRegistry" `
                        --file "docker/Dockerfile.$component" --platform linux/amd64 . --output none
                }
            }
        }
    }

    Write-Host "==> Publishing Recipes to $pushRegistry" -ForegroundColor Cyan
    ./scripts/deploy/publish-recipes.ps1 -Registry $pushRegistry -Platform azure-local -Tag $ImageTag

    # The cluster pulls latest-tagged images and Recipes by tag, so a stale digest would still
    # answer 200. Their digests in the cloud registry are what the sync check below waits for.
    $expectedDigests = @{}
    $published = @($components | ForEach-Object { "oms/$_" }) + (Get-LibraryRecipe -Platform azure-local | ForEach-Object { "recipes/$($_.BaseName)" })
    foreach ($repository in $published) {
        $expectedDigests["${repository}:$ImageTag"] = az acr manifest show-metadata "$pushRegistry/${repository}:$ImageTag" --query digest --output tsv 2>$null
        if (-not $expectedDigests["${repository}:$ImageTag"]) { throw "Could not read the digest of ${repository}:$ImageTag in $pushRegistry." }
    }

    # ------------------------------------------------------------------------------------------
    # Wait for the connected registry to hold everything this deployment pulls. It syncs
    # continuously, but a Recipe the control plane cannot find yet fails the deployment outright.
    # ------------------------------------------------------------------------------------------
    Write-Host "==> Waiting for the connected registry ($PullRegistry) to sync" -ForegroundColor Cyan
    $clusterServices = kubectl get services --all-namespaces --context $KubeContext -o json | ConvertFrom-Json
    $registryService = $clusterServices.items | Where-Object { $_.spec.clusterIP -eq $PullRegistry } | Select-Object -First 1
    if (-not $registryService) { throw "No Service with ClusterIP $PullRegistry. Run ./scripts/setup-platform.ps1 -Target AzureLocal (the Registry step)." }
    $servicePort = ($registryService.spec.ports | Select-Object -First 1).port
    $localPort = Get-Random -Minimum 20000 -Maximum 30000

    $portForward = Start-Process -FilePath kubectl -PassThru -WindowStyle Hidden -ArgumentList @(
        '--context', $KubeContext, '--namespace', $registryService.metadata.namespace,
        'port-forward', "service/$($registryService.metadata.name)", "${localPort}:$servicePort")
    Start-Sleep -Seconds 3

    $artifacts = @(
        "ucpd:$RadiusVersion", "controller:$RadiusVersion", "applications-rp:$RadiusVersion",
        "dynamic-rp:$RadiusVersion", "deployment-engine:$RadiusVersion", "bicep:$RadiusVersion"
    ) + @($expectedDigests.Keys | Where-Object { $_ -like 'oms/*' }) +
        (Get-LibraryRecipe -Platform azure-local | ForEach-Object { "recipes/$($_.BaseName):$ImageTag" }) +
        @('radius-project/kube-recipes/secrets:latest')

    $basicAuth = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("$($pullAuth.username):$($pullAuth.password)"))
    $accept = 'application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'

    # Like ACR, the connected registry rejects Basic auth on /v2 and expects a bearer token from its
    # token endpoint, scoped to the repository.
    function Get-ManifestDigest {
        param([string]$Repository, [string]$Tag)

        $tokenUri = "https://localhost:$localPort/acr/oauth2/token?service=localhost:$localPort&scope=repository:${Repository}:pull"
        $token = (Invoke-RestMethod -Uri $tokenUri -Headers @{ Authorization = "Basic $basicAuth" } `
                -SkipCertificateCheck -TimeoutSec 15).access_token
        $response = Invoke-WebRequest -Uri "https://localhost:$localPort/v2/$Repository/manifests/$Tag" -Method Head `
            -Headers @{ Authorization = "Bearer $token"; Accept = $accept } -SkipCertificateCheck -TimeoutSec 15
        return ($response.Headers['Docker-Content-Digest'] | Select-Object -First 1)
    }

    $deadline = (Get-Date).AddMinutes($SyncTimeoutMinutes)
    $pending = [System.Collections.Generic.List[string]]::new([string[]]$artifacts)
    while ($pending.Count -gt 0) {
        foreach ($artifact in @($pending)) {
            $repository, $tag = $artifact -split ':', 2
            try {
                # The connected registry's certificate names its ClusterIP, not localhost, and this
                # probe only checks presence over a local port-forward, so validation is skipped.
                $digest = Get-ManifestDigest -Repository $repository -Tag $tag
                $expected = $expectedDigests[$artifact]
                if (-not $expected -or $digest -eq $expected) {
                    [void]$pending.Remove($artifact)
                }
            }
            catch { }
        }
        if ($pending.Count -eq 0) { break }
        if ((Get-Date) -gt $deadline) {
            throw "Connected registry is still missing after $SyncTimeoutMinutes minutes: $($pending -join ', ')"
        }
        Write-Host "    waiting on $($pending.Count): $($pending -join ', ')" -ForegroundColor DarkGray
        Start-Sleep -Seconds 20
    }
    Write-Host "    all $($artifacts.Count) artifacts present" -ForegroundColor DarkGray
    Stop-Process -Id $portForward.Id -Force -ErrorAction SilentlyContinue
    $portForward = $null

    # ------------------------------------------------------------------------------------------
    # Radius control plane, pulled from the connected registry.
    # ------------------------------------------------------------------------------------------
    if (-not $SkipRadiusInstall) {
        Write-Host "==> Installing the Radius control plane from $PullRegistry" -ForegroundColor Cyan
        $installArgs = @(
            'install', 'kubernetes',
            '--kubecontext', $KubeContext,
            '--skip-contour-install',
            '--set', "global.imageRegistry=$PullRegistry",
            '--set', "global.imageTag=$RadiusVersion",
            '--set', "global.imagePullSecrets[0].name=$ImagePullSecretName",
            # The control plane fetches Recipes itself, with its own trust store.
            '--set-file', "global.rootCA.cert=$registryCaFile"
        )
        if ($ReinstallRadius) { $installArgs += '--reinstall' }
        Invoke-Checked 'rad install' { rad @installArgs }

        if ($ReinstallRadius) {
            # Go caches the system cert pool on first use, so a changed rootCA only applies after restart.
            Invoke-Checked 'restart Radius control plane' {
                kubectl rollout restart deployment --namespace radius-system --context $KubeContext | Out-Null
            }
            Invoke-Checked 'wait for Radius control plane' {
                kubectl rollout status deployment --namespace radius-system --context $KubeContext --timeout=600s | Out-Null
            }
        }
    }

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
        rad resource-type create messageQueues -f $QueueTypeFile --workspace $WorkspaceName
    }

    Write-Host "==> Creating the bootstrap environment" -ForegroundColor Cyan
    Invoke-Checked 'rad env create bootstrap' {
        rad env create bootstrap --group $ResourceGroup --workspace $WorkspaceName
    }

    # Keycloak is reached on the first node's address and NodePort.
    $oauthIssuer = ''
    if (-not $SkipOAuth) {
        $keycloakReady = kubectl --context $KubeContext -n $IdentityNamespace get deployment $KeycloakRelease `
            --ignore-not-found --output name 2>$null
        if ([string]::IsNullOrWhiteSpace($keycloakReady)) {
            Write-Host "==> No Keycloak found in namespace '$IdentityNamespace'; the queue will use broker credentials" -ForegroundColor Yellow
        }
        else {
            $nodeIp = kubectl --context $KubeContext get nodes `
                --output 'jsonpath={.items[0].status.addresses[?(@.type=="InternalIP")].address}'
            if ([string]::IsNullOrWhiteSpace($nodeIp)) { throw 'Could not resolve a node IP for the Keycloak issuer URL.' }

            $oauthIssuer = "https://${nodeIp}:$KeycloakNodePort/realms/$KeycloakRealm"

            $caPresent = kubectl --context $KubeContext -n $Namespace get secret $IdentityCaSecretName `
                --ignore-not-found --output name 2>$null
            if ([string]::IsNullOrWhiteSpace($caPresent)) {
                throw "Secret '$IdentityCaSecretName' is missing from namespace '$Namespace'. Re-run scripts/infra/azurelocal/keycloak.ps1 with -WorkloadNamespace $Namespace, or pass -SkipOAuth."
            }
            Write-Host "==> Queue authentication federated to $oauthIssuer" -ForegroundColor Cyan
        }
    }

    Write-Host "==> Deploying the Recipe Pack" -ForegroundColor Cyan
    $ingressAddress = kubectl get service ingress-nginx-controller -n $IngressNamespace --context $KubeContext `
        --ignore-not-found -o 'jsonpath={.status.loadBalancer.ingress[0].ip}' 2>$null
    $useIngress = -not [string]::IsNullOrWhiteSpace($ingressAddress)
    if ($useIngress) { Write-Host "    publishing through ingress '$IngressClassName' at https://$ingressAddress" -ForegroundColor DarkGray }
    $useCollector = $false
    if ($OtlpEndpoint) {
        $collectorService, $collectorNamespace = ([uri]$OtlpEndpoint).Host -split '\.'
        $useCollector = [bool](kubectl get service $collectorService -n $collectorNamespace --context $KubeContext --ignore-not-found -o name 2>$null)
        if (-not $useCollector) { Write-Host "    no OpenTelemetry collector at $OtlpEndpoint; the services send no telemetry" -ForegroundColor Yellow }
    }
    $recipePackParameters = New-ParameterFile @{
        registry                = $PullRegistry
        tag                     = $ImageTag
        imagePullSecretName     = $ImagePullSecretName
        oauthIssuer             = $oauthIssuer
        oauthCaSecretName       = $(if ($oauthIssuer) { $IdentityCaSecretName } else { '' })
        oauthClientId           = $(if ($oauthIssuer) { $WorkloadClientId } else { '' })
        # Each service runs as its own service account, named after it.
        serviceAccountName      = '{resource}'
        # Each service's database password, written by this script after the database setup job.
        containerEnvFromSecrets = @('{resource}-db-credentials')
        sqlServerEdition        = $SqlServerEdition
        certificateIssuer       = $CertificateIssuer
        otlpEndpoint            = $(if ($useCollector) { $OtlpEndpoint } else { '' })
        # The app's route is published through the site's ingress controller. Without one, the
        # Ingress is created but nothing serves it, and the app is reached through port-forward.
        ingressClassName        = $IngressClassName
        ingressTlsSecretName    = $(if ($useIngress) { $IngressTlsSecretName } else { '' })
    }
    $temporaryFiles += $recipePackParameters
    Invoke-Checked 'rad deploy recipe pack' {
        rad deploy (Join-Path $LibraryRecipePackRoot 'azure-local.bicep') `
            --workspace $WorkspaceName `
            --group $ResourceGroup `
            --environment bootstrap `
            --parameters "@$recipePackParameters"
    }

    # The connected registry always requires authentication, so Recipe pulls always need it. The
    # Environment must exist before the secret store that references it.
    Write-Host "==> Creating the Environment (first pass, no registry credentials)" -ForegroundColor Cyan
    # 'rad resource show' prints a plain-text error to stdout when the resource does not exist yet.
    $existingSettings = $null
    $settingsJson = rad resource show Radius.Core/bicepSettings oms-registry-auth `
        --workspace $WorkspaceName --group $ResourceGroup --output json 2>$null
    if ($LASTEXITCODE -eq 0 -and $settingsJson) {
        $existingSettings = ($settingsJson | Out-String) | ConvertFrom-Json
    }
    if (-not ($existingSettings -and $existingSettings.id)) {
        Invoke-Checked 'rad deploy environment' {
            rad deploy deploy/environments/azurelocal.bicep `
                --workspace $WorkspaceName --group $ResourceGroup --environment bootstrap `
                --parameters namespace=$Namespace
        }
    }

    Write-Host "==> Configuring registry authentication for Recipe pulls" -ForegroundColor Cyan
    $registryAuthParameters = New-ParameterFile @{
        registryHost     = $PullRegistry
        registryUsername = $pullAuth.username
        registryPassword = $pullAuth.password
    }
    $temporaryFiles += $registryAuthParameters
    Invoke-Checked 'rad deploy registry auth' {
        rad deploy deploy/recipe-registry-credentials.bicep `
            --workspace $WorkspaceName --group $ResourceGroup --environment $EnvironmentName `
            --parameters "@$registryAuthParameters"
    }

    $bicepSettingsId = rad resource show Radius.Core/bicepSettings oms-registry-auth `
        --workspace $WorkspaceName --group $ResourceGroup --output json 2>$null |
        ConvertFrom-Json | Select-Object -ExpandProperty id
    if ([string]::IsNullOrWhiteSpace($bicepSettingsId)) {
        throw 'Could not resolve the ID of the bicepSettings resource just deployed.'
    }

    Write-Host "==> Deploying the Environment" -ForegroundColor Cyan
    Invoke-Checked 'rad deploy environment' {
        rad deploy deploy/environments/azurelocal.bicep `
            --workspace $WorkspaceName `
            --group $ResourceGroup `
            --environment bootstrap `
            --parameters namespace=$Namespace `
            --parameters bicepSettingsId=$bicepSettingsId
    }

    # ------------------------------------------------------------------------------------------
    # Database passwords, from Key Vault through Secret $PasswordsSecretName. SQL Server and
    # PostgreSQL read their administrator password only when they first create their data, so a
    # changed one is set in the running server, signing in with the previous one, which
    # $AppliedAdminSecretName records. Passwords go over stdin, never on a command line.
    # ------------------------------------------------------------------------------------------
    $passwords = Get-OmsSecretData $KubeContext $Namespace $PasswordsSecretName
    $missingKeys = @('sql-admin-password', 'postgres-admin-password', 'sql-api-password', 'sql-processor-password', 'postgres-inventory-password') |
        Where-Object { -not $passwords[$_] }
    if ($missingKeys) {
        throw "Secret '$PasswordsSecretName' lacks $($missingKeys -join ', '). Run ./scripts/setup-platform.ps1 -Target AzureLocal (the KeyVault step)."
    }
    $applied = Get-OmsSecretData $KubeContext $Namespace $AppliedAdminSecretName

    function Get-RunningPod([string]$App) {
        @(kubectl get pods --context $KubeContext --namespace $Namespace --selector "app=$App" `
                --field-selector status.phase=Running --output jsonpath='{.items[*].metadata.name}' |
            ForEach-Object { $_ -split ' ' } | Where-Object { $_ })
    }

    # Passwords are case-sensitive, hence -cne.
    $previous = $applied['sql-admin-password']
    if ($previous -and $passwords['sql-admin-password'] -cne $previous) {
        $pods = Get-RunningPod 'mssql'
        if (-not $pods) { throw 'The SQL administrator password changed in Key Vault, but no SQL Server is running to change it in. Start SQL Server, then run this again.' }
        foreach ($pod in $pods) {
            Write-Host "==> Changing the SQL administrator password in $pod" -ForegroundColor Cyan
            "$previous`nALTER LOGIN sa WITH PASSWORD = N'$($passwords['sql-admin-password'].Replace("'", "''"))';`nGO" |
                kubectl exec --stdin $pod --container mssql --context $KubeContext --namespace $Namespace -- `
                    bash -c 'IFS= read -r P; export SQLCMDPASSWORD="${P%$''\r''}"; /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -b' |
                Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Changing the SQL administrator password in $pod failed." }
        }
    }
    $previous = $applied['postgres-admin-password']
    if ($previous -and $passwords['postgres-admin-password'] -cne $previous) {
        $pods = Get-RunningPod 'postgres'
        if (-not $pods) { throw 'The PostgreSQL administrator password changed in Key Vault, but no PostgreSQL is running to change it in. Start PostgreSQL, then run this again.' }
        foreach ($pod in $pods) {
            Write-Host "==> Changing the PostgreSQL administrator password in $pod" -ForegroundColor Cyan
            "$previous`nALTER ROLE CURRENT_USER PASSWORD '$($passwords['postgres-admin-password'].Replace("'", "''"))';" |
                kubectl exec --stdin $pod --container postgres --context $KubeContext --namespace $Namespace -- `
                    sh -c 'IFS= read -r P; export PGPASSWORD="${P%$(printf ''\r'')}"; psql -h /var/run/postgresql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -q' |
                Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Changing the PostgreSQL administrator password in $pod failed." }
        }
    }
    $previous = $null
    Set-OmsSecret $KubeContext $Namespace $AppliedAdminSecretName @{
        'sql-admin-password'      = $passwords['sql-admin-password']
        'postgres-admin-password' = $passwords['postgres-admin-password']
    }

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
    $applicationParameters = New-ParameterFile @{
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
    Invoke-Checked 'rad deploy application' {
        rad deploy deploy/app.bicep `
            --workspace $WorkspaceName `
            --group $ResourceGroup `
            --environment $EnvironmentName `
            --parameters "@$applicationParameters"
    }

    # 'rad deploy' returns once the resources are applied, not once the pods are serving.
    Write-Host "==> Waiting for the backing services (images come from $PullRegistry)" -ForegroundColor Cyan
    Invoke-Checked 'kubectl rollout status' {
        kubectl rollout status statefulset --namespace $Namespace --context $KubeContext `
            --timeout="${RolloutTimeoutSeconds}s" | Out-Null
    }

    $monitoringPresent = kubectl get namespace $MonitoringNamespace --context $KubeContext --ignore-not-found -o name 2>$null
    Set-OmsNetworkPolicy -KubeContext $KubeContext -Namespace $Namespace -IngressNamespace $IngressNamespace `
        -MonitoringNamespace $(if ($monitoringPresent) { $MonitoringNamespace } else { '' }) `
        -ManifestPath (Join-Path $repoRoot 'deploy/network-policies.yaml')

    # As the database administrators, create the schemas and each service's database user with
    # only the rights it needs, setting the passwords from Key Vault.
    $sql = Get-OmsRadiusResourceProperties -Type 'Radius.Data/sqlServerDatabases' -Name 'ordersdb' -Workspace $WorkspaceName -Group $ResourceGroup
    $postgres = Get-OmsRadiusResourceProperties -Type 'Radius.Data/postgreSqlDatabases' -Name 'inventorydb' -Workspace $WorkspaceName -Group $ResourceGroup
    $fromPasswords = { param($key) @{ Secret = $PasswordsSecretName; Key = $key } }
    Invoke-OmsDatabaseSetup -KubeContext $KubeContext -Namespace $Namespace `
        -Image "$PullRegistry/oms/dbsetup@$($expectedDigests["oms/dbsetup:$ImageTag"])" `
        -ImagePullSecretName $ImagePullSecretName `
        -Environment @{
            CONNECTION_SQL_HOST             = $sql.host
            CONNECTION_SQL_PORT             = $sql.port
            CONNECTION_SQL_DATABASE         = $sql.database
            # The SQL Server container's administrator login.
            SQL_ADMIN_USERNAME              = 'sa'
            CONNECTION_INVENTORYDB_HOST     = $postgres.host
            CONNECTION_INVENTORYDB_PORT     = $postgres.port
            CONNECTION_INVENTORYDB_DATABASE = $postgres.database
            CONNECTION_INVENTORYDB_TLS      = $postgres.tls
            POSTGRES_ADMIN_USERNAME         = 'pgadmin'
        } `
        -SecretEnvironment @{
            SQL_ADMIN_PASSWORD      = & $fromPasswords 'sql-admin-password'
            SQL_API_PASSWORD        = & $fromPasswords 'sql-api-password'
            SQL_PROCESSOR_PASSWORD  = & $fromPasswords 'sql-processor-password'
            POSTGRES_ADMIN_PASSWORD = & $fromPasswords 'postgres-admin-password'
            INVENTORY_DB_PASSWORD   = & $fromPasswords 'postgres-inventory-password'
        }

    # Each service gets only its own password, now that the database has it.
    $serviceCredentials = @{
        api       = @{ SQL_PASSWORD = $passwords['sql-api-password'] }
        processor = @{ SQL_PASSWORD = $passwords['sql-processor-password'] }
        inventory = @{ POSTGRES_PASSWORD = $passwords['postgres-inventory-password'] }
    }
    foreach ($service in $Services) {
        Set-OmsSecret $KubeContext $Namespace "$service-db-credentials" $serviceCredentials[$service]
    }
    $passwords = $null; $serviceCredentials = $null

    # Environment variables from a Secret are read when a container starts, so the services restart
    # to pick up their credentials.
    Write-Host "==> Waiting for the application to roll out" -ForegroundColor Cyan
    foreach ($service in $Services) {
        Invoke-Checked "restart $service" {
            kubectl rollout restart deployment $service --namespace $Namespace --context $KubeContext | Out-Null
        }
    }
    Invoke-Checked 'kubectl rollout status' {
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
    if ($portForward) { Stop-Process -Id $portForward.Id -Force -ErrorAction SilentlyContinue }
    foreach ($file in $temporaryFiles) {
        Remove-Item $file -Force -ErrorAction SilentlyContinue
    }
    Pop-Location
}
