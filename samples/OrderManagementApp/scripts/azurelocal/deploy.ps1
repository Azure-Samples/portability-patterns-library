<#
.SYNOPSIS
    Deploys the Order Management sample to AKS enabled by Arc on a connected Azure Local
    instance.

.DESCRIPTION
    The Azure Local instance is connected, but the workload is built to keep running if that link
    drops. So the backing services are in-cluster containers (RabbitMQ, SQL Server, Azurite),
    identity is the in-cluster Keycloak bound to the site's Active Directory, and
    every image and Recipe is pulled from the ACR connected registry inside the cluster.

    Two registries are involved:

      * Push registry  - the Premium ACR in Azure (<acr-name>.azurecr.io). Images are built
                         and Recipes published here, from this machine.
      * Pull registry  - the connected registry ClusterIP (10.96.0.50). Kubelet and the Radius
                         control plane pull from here. It syncs from the push registry while the
                         link is up and keeps serving what it has when it is not.

    Prerequisite: ./scripts/setup-platform.ps1 -Target AzureLocal (cluster, image mirror, connected
    registry, Keycloak, ingress and the orders app's sign-in registration). Usually run through
    ./scripts/deploy.ps1 -Target AzureLocal, which supplies the settings.

    Images are built with podman when it is available, otherwise docker.

.PARAMETER ReinstallRadius
    Reinstall the Radius control plane even when present. Needed whenever the registry CA or pull
    secret changes, since 'rad install kubernetes' otherwise leaves an existing installation alone.

.PARAMETER RotateSqlPassword
    Generate a new SQL administrator password instead of reusing the one in 'oms-sql-admin'. The
    SQL container keeps no volume, so rotating restarts it empty; use it when the password leaked.

.EXAMPLE
    ./scripts/azurelocal/deploy.ps1

.EXAMPLE
    # Rotate the SQL password without rebuilding images or reinstalling Radius.
    ./scripts/azurelocal/deploy.ps1 -SkipImageBuild -SkipRadiusInstall -RotateSqlPassword
#>
[CmdletBinding()]
param(
    [string]$RegistryName = '<acr-name>',
    [string]$RegistryResourceGroup = 'bcd-azurelocal',
    [string]$KubeContext = 'bcd-aksarc',

    # Connected registry address, its pull secret and CA, as written by connected-registry.ps1.
    [string]$PullRegistry = '10.96.0.50',
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

    [securestring]$SqlAdminPassword,
    [switch]$RotateSqlPassword,

    # How long to wait for the application's Deployments to become available after 'rad deploy'.
    [int]$RolloutTimeoutSeconds = 900,

    [string]$IdentityNamespace = 'identity',
    [string]$KeycloakRelease = 'keycloak',
    [string]$KeycloakRealm = 'oms',
    [int]$KeycloakNodePort = 30443,
    # Keycloak client and service account the workloads authenticate as, from scripts/azurelocal/keycloak.ps1.
    [string]$WorkloadClientId = 'oms-workloads',
    [string]$WorkloadServiceAccount = 'oms-workload',
    [string]$IdentityCaSecretName = 'oms-identity-ca',
    [switch]$SkipOAuth,

    # SQL Kerberos material written by scripts/azurelocal/ad-setup.ps1. When all three exist in the
    # application namespace, the application signs in to SQL Server as its AD account.
    [string]$KerberosConfigMapName = 'oms-krb5',
    [string]$AppKeytabSecretName = 'oms-app-kerberos',
    [string]$SqlKeytabSecretName = 'oms-sql-kerberos',
    [switch]$SkipKerberos,

    # Keycloak clients for user sign-in, as registered by scripts/azurelocal/configure-app-identity.ps1.
    [string]$OrdersApiClientId = 'oms-api',
    [string]$OrdersSpaClientId = 'oms-spa',
    [int]$UiLocalPort = 5090,

    # Ingress from scripts/azurelocal/provision-ingress.ps1. Used when present; otherwise the app
    # is only reachable through kubectl port-forward.
    [string]$IngressNamespace = 'ingress-nginx',
    [string]$IngressClassName = 'nginx',
    [string]$IngressTlsSecretName = 'oms-app-tls',

    [switch]$SkipImageBuild,
    [switch]$SkipRadiusInstall
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'scripts/lib/recipes.ps1')
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

    Write-Host "==> Checking the cluster is reachable" -ForegroundColor Cyan
    Invoke-Checked 'kubectl cluster-info' { kubectl cluster-info --context $KubeContext --request-timeout=20s | Out-Null }

    kubectl create namespace $Namespace --context $KubeContext --dry-run=client -o yaml |
        kubectl apply --context $KubeContext -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Creating the application namespace failed.' }

    # ------------------------------------------------------------------------------------------
    # Connected registry credentials and CA, kept in the cluster by connected-registry.ps1.
    # ------------------------------------------------------------------------------------------
    $dockerConfigEncoded = kubectl get secret $ImagePullSecretName --context $KubeContext --namespace $Namespace `
        --ignore-not-found --output 'jsonpath={.data.\.dockerconfigjson}'
    if ([string]::IsNullOrWhiteSpace($dockerConfigEncoded)) {
        throw "Pull secret '$ImagePullSecretName' is missing from '$Namespace'. Run scripts/azurelocal/connected-registry.ps1 first."
    }
    $pullAuth = ([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($dockerConfigEncoded)) | ConvertFrom-Json).auths.$PullRegistry
    if (-not $pullAuth -or -not $pullAuth.username -or -not $pullAuth.password) {
        throw "Pull secret '$ImagePullSecretName' holds no credentials for '$PullRegistry'."
    }

    $registryCaPem = (kubectl get configmap $RegistryCaConfigMapName --context $KubeContext --namespace $Namespace `
        --ignore-not-found --output 'jsonpath={.data.ca\.crt}') -join "`n"
    if ([string]::IsNullOrWhiteSpace($registryCaPem)) {
        throw "ConfigMap '$RegistryCaConfigMapName' is missing from '$Namespace'. Run scripts/azurelocal/connected-registry.ps1 first."
    }
    $registryCaFile = Join-Path ([System.IO.Path]::GetTempPath()) "oms-azurelocal-ca-$([guid]::NewGuid().ToString('N')).crt"
    $temporaryFiles += $registryCaFile
    [System.IO.File]::WriteAllText($registryCaFile, $registryCaPem, [System.Text.UTF8Encoding]::new($false))

    $pushRegistry = az acr show --name $RegistryName --resource-group $RegistryResourceGroup --query loginServer --output tsv
    if ($LASTEXITCODE -ne 0 -or -not $pushRegistry) { throw "Registry '$RegistryName' not found." }

    # ------------------------------------------------------------------------------------------
    # Build, push and publish to the cloud registry.
    # ------------------------------------------------------------------------------------------
    Invoke-Checked 'rad bicep publish-extension' {
        rad bicep publish-extension -f $QueueTypeFile --target $QueueTypeExtension
    }

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
    elseif (-not $SkipImageBuild) {
        throw 'Neither podman nor docker is on PATH. Install one, or pass -SkipImageBuild.'
    }
    $acrToken = $null

    if (-not $SkipImageBuild) {
        Write-Host "==> Building application images with $containerTool against base images in $pushRegistry" -ForegroundColor Cyan
        foreach ($component in @('api', 'processor')) {
            $image = "$pushRegistry/oms/${component}:$ImageTag"
            Invoke-Checked "$containerTool build $component" {
                & $containerTool build --build-arg "BASE_REGISTRY=$pushRegistry" -f "docker/Dockerfile.$component" -t $image .
            }
            Invoke-Checked "$containerTool push $component" { & $containerTool push $image }
        }
    }

    Write-Host "==> Publishing Recipes to $pushRegistry" -ForegroundColor Cyan
    ./scripts/publish-recipes.ps1 -Registry $pushRegistry -Platform azure-local -Tag $ImageTag

    # ------------------------------------------------------------------------------------------
    # Wait for the connected registry to hold everything this deployment pulls. It syncs
    # continuously, but a Recipe the control plane cannot find yet fails the deployment outright.
    # ------------------------------------------------------------------------------------------
    Write-Host "==> Waiting for the connected registry ($PullRegistry) to sync" -ForegroundColor Cyan
    $services = kubectl get services --all-namespaces --context $KubeContext -o json | ConvertFrom-Json
    $registryService = $services.items | Where-Object { $_.spec.clusterIP -eq $PullRegistry } | Select-Object -First 1
    if (-not $registryService) { throw "No Service with ClusterIP $PullRegistry. Run scripts/azurelocal/connected-registry.ps1." }
    $servicePort = ($registryService.spec.ports | Select-Object -First 1).port
    $localPort = Get-Random -Minimum 20000 -Maximum 30000

    $portForward = Start-Process -FilePath kubectl -PassThru -WindowStyle Hidden -ArgumentList @(
        '--context', $KubeContext, '--namespace', $registryService.metadata.namespace,
        'port-forward', "service/$($registryService.metadata.name)", "${localPort}:$servicePort")
    Start-Sleep -Seconds 3

    $artifacts = @(
        "ucpd:$RadiusVersion", "controller:$RadiusVersion", "applications-rp:$RadiusVersion",
        "dynamic-rp:$RadiusVersion", "deployment-engine:$RadiusVersion", "bicep:$RadiusVersion",
        "oms/api:$ImageTag", "oms/processor:$ImageTag"
    ) + (Get-LibraryRecipe -Platform azure-local | ForEach-Object { "recipes/$($_.BaseName):$ImageTag" }) +
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

    # The cluster pulls latest-tagged images by tag, so a stale digest would still answer 200. The
    # digest in the cloud registry is compared for the images rebuilt by this run.
    $expectedDigests = @{}
    foreach ($worker in @('api', 'processor')) {
        $expectedDigests["oms/${worker}:$ImageTag"] = az acr manifest show-metadata "$pushRegistry/oms/${worker}:$ImageTag" --query digest --output tsv 2>$null
        if (-not $expectedDigests["oms/${worker}:$ImageTag"]) { throw "Could not read the digest of oms/${worker}:$ImageTag in $pushRegistry." }
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
                throw "Secret '$IdentityCaSecretName' is missing from namespace '$Namespace'. Re-run scripts/azurelocal/keycloak.ps1 with -WorkloadNamespace $Namespace, or pass -SkipOAuth."
            }
            Write-Host "==> Queue authentication federated to $oauthIssuer" -ForegroundColor Cyan
        }
    }

    $kerberosConfig = ''
    $sqlKerberosAccount = ''
    $directoryAddress = ''
    $directoryHostNames = ''
    $sqlWindowsLogin = ''
    if (-not $SkipKerberos) {
        $krb5Config = kubectl --context $KubeContext -n $Namespace get configmap $KerberosConfigMapName `
            --ignore-not-found --output json 2>$null | ConvertFrom-Json
        $appKeytab = kubectl --context $KubeContext -n $Namespace get secret $AppKeytabSecretName `
            --ignore-not-found --output json 2>$null | ConvertFrom-Json
        $sqlKeytab = kubectl --context $KubeContext -n $Namespace get secret $SqlKeytabSecretName `
            --ignore-not-found --output json 2>$null | ConvertFrom-Json
        if ($krb5Config -and $appKeytab -and $sqlKeytab) {
            $kerberosConfig = $KerberosConfigMapName
            $directoryAddress = $krb5Config.data.'kdc-address'
            $directoryHostNames = $krb5Config.data.'kdc-hostnames'
            $sqlKerberosAccount = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($sqlKeytab.data.account))
            $sqlWindowsLogin = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($appKeytab.data.login))
            Write-Host "==> SQL authentication: Kerberos as $sqlWindowsLogin" -ForegroundColor Cyan
        }
        else {
            Write-Host "==> No Kerberos keytabs in '$Namespace'; SQL uses a SQL login (run scripts/azurelocal/ad-setup.ps1 -KerberosOnly)" -ForegroundColor Yellow
        }
    }

    Write-Host "==> Deploying the Recipe Pack" -ForegroundColor Cyan
    $ingressAddress = kubectl get service ingress-nginx-controller -n $IngressNamespace --context $KubeContext `
        --ignore-not-found -o 'jsonpath={.status.loadBalancer.ingress[0].ip}' 2>$null
    $useIngress = -not [string]::IsNullOrWhiteSpace($ingressAddress)
    if ($useIngress) { Write-Host "    publishing through ingress '$IngressClassName' at https://$ingressAddress" -ForegroundColor DarkGray }
    Invoke-Checked 'rad deploy recipe pack' {
        rad deploy (Join-Path $LibraryRecipePackRoot 'azure-local.bicep') `
            --workspace $WorkspaceName `
            --group $ResourceGroup `
            --environment bootstrap `
            --parameters registry=$PullRegistry `
            --parameters tag=$ImageTag `
            --parameters imagePullSecretName=$ImagePullSecretName `
            --parameters oauthIssuer=$oauthIssuer `
            --parameters oauthCaSecretName=$(if ($oauthIssuer) { $IdentityCaSecretName } else { '' }) `
            --parameters oauthClientId=$(if ($oauthIssuer) { $WorkloadClientId } else { '' }) `
            --parameters serviceAccountName=$WorkloadServiceAccount `
            --parameters ingressClassName=$(if ($useIngress) { $IngressClassName } else { '' }) `
            --parameters ingressTlsSecretName=$(if ($useIngress) { $IngressTlsSecretName } else { '' }) `
            --parameters kerberosConfigMapName=$kerberosConfig `
            --parameters kerberosClientKeytabSecretName=$(if ($kerberosConfig) { $AppKeytabSecretName } else { '' }) `
            --parameters sqlKerberosKeytabSecretName=$(if ($kerberosConfig) { $SqlKeytabSecretName } else { '' }) `
            --parameters sqlKerberosAccount=$sqlKerberosAccount `
            --parameters sqlWindowsLogins=$sqlWindowsLogin `
            --parameters kerberosDirectoryAddress=$directoryAddress `
            --parameters kerberosDirectoryHostNames=$directoryHostNames
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
        rad deploy deploy/registry-auth.bicep `
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

    # The SQL container authenticates with this password, so it must survive redeployment. Kept in
    # a Kubernetes Secret, generated on first use.
    $sqlSecretName = 'oms-sql-admin'
    if ($SqlAdminPassword -and $RotateSqlPassword) {
        throw 'Pass either -SqlAdminPassword or -RotateSqlPassword, not both.'
    }
    if ($SqlAdminPassword) {
        $plainSqlPassword = [System.Net.NetworkCredential]::new('', $SqlAdminPassword).Password
    }
    else {
        $storedSqlPassword = kubectl get secret $sqlSecretName --context $KubeContext --namespace $Namespace `
            --ignore-not-found --output jsonpath='{.data.password}'
        if (-not $RotateSqlPassword -and -not [string]::IsNullOrWhiteSpace($storedSqlPassword)) {
            $plainSqlPassword = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($storedSqlPassword))
            Write-Host "==> Reusing the SQL administrator password from secret '$sqlSecretName'" -ForegroundColor DarkGray
        }
        else {
            # Base64 of random bytes satisfies SQL Server complexity rules and contains no ';'.
            $randomBytes = [byte[]]::new(24)
            [System.Security.Cryptography.RandomNumberGenerator]::Fill($randomBytes)
            $plainSqlPassword = 'Oms1!' + [Convert]::ToBase64String($randomBytes)
            $verb = if ($RotateSqlPassword) { 'Rotated' } else { 'Generated' }
            Write-Host "==> $verb the SQL administrator password and stored it in secret '$sqlSecretName'" -ForegroundColor DarkGray
        }
    }

    kubectl create secret generic $sqlSecretName --context $KubeContext --namespace $Namespace `
        --from-literal=password=$plainSqlPassword --dry-run=client --output yaml |
        kubectl apply --context $KubeContext --filename - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Storing the SQL administrator password in '$sqlSecretName' failed." }

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

    # The same parameters as on Azure: everything platform-specific is in the Recipe Pack.
    $applicationParameters = New-ParameterFile @{
        # Pinned by digest: with a bare ':latest' the pod spec never changes, so a rebuild never rolls out.
        apiImage          = "$PullRegistry/oms/api@$($expectedDigests["oms/api:$ImageTag"])"
        processorImage    = "$PullRegistry/oms/processor@$($expectedDigests["oms/processor:$ImageTag"])"
        apiAuthentication = $apiAuthentication
        spaSettings       = $spaSettings
        sqlAdminPassword  = $plainSqlPassword
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
    $plainSqlPassword = $null

    # 'rad deploy' returns once the resources are applied, not once the pods are serving.
    Write-Host "==> Waiting for the application to roll out (images come from $PullRegistry)" -ForegroundColor Cyan
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
