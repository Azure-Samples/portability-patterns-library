<#
.SYNOPSIS
    Deploys the Business Continuity Demo App to Azure Local with disconnected operations (ALDO).

.DESCRIPTION
    Disconnected operations expose ARM, RBAC, Azure Local VMs, Arc-enabled servers, Arc-enabled
    Kubernetes and AKS enabled by Arc, Azure Container Registry, Azure Key Vault and Azure Policy.
    There is no Service Bus, Azure SQL or Blob Storage, so every backing service runs as an
    in-cluster container exactly as it does locally.

    Two consequences shape this script:

      * Nothing may be pulled from a public registry. Every image, including the Radius control
        plane, comes from the local registry. Run scripts/azurelocal/import-images.ps1 first.

      * Only SYSTEM-ASSIGNED managed identity is supported, so there is no user-assigned identity
        and no federated identity credential. The Microsoft Entra Workload Identity design used on
        AKS does not apply: the workers authenticate to the in-cluster services with credentials
        issued by the Recipes, as they do locally.

.PARAMETER Registry
    Login server of the local registry holding the images and Recipes.

.PARAMETER KubeContext
    kubectl context of the AKS enabled by Arc cluster.

.PARAMETER ImagePullSecretName
    Existing Kubernetes image pull secret for the local registry. Supply when the registry requires
    authentication; the workers and the Radius control plane are both pointed at it.

.PARAMETER RegistryCaCertFile
    PEM file holding the root CA that signed the registry's certificate. Required when that CA is
    private, as it is on Azure Local: the node trusting it covers image pulls by kubelet, but the
    Radius control plane pods carry their own trust store and fetch Recipes themselves, so without
    this they fail with 'x509: certificate signed by unknown authority'.

.PARAMETER ReinstallRadius
    Reinstall the control plane even when it is already present. Needed whenever -RegistryCaCertFile
    or the pull secret changes, since 'rad install kubernetes' otherwise leaves an existing
    installation untouched.

.PARAMETER SqlAdminPassword
    Administrator password for the SQL Server container. Generated on first deployment and kept in
    the 'bcd-sql-admin' Kubernetes Secret, so it is stable across redeployments without living in
    the repository. Supply this only to set a specific value.

.EXAMPLE
    ./lab/aldo/deploy.ps1 -Registry mylocalacr.azurecr.local -KubeContext aks-arc

.EXAMPLE
    # Private local registry requiring authentication.
    ./lab/aldo/deploy.ps1 `
        -Registry mylocalacr.azurecr.local `
        -KubeContext aks-arc `
        -ImagePullSecretName local-registry
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Registry,
    [Parameter(Mandatory = $true)][string]$KubeContext,

    [string]$ImagePullSecretName = '',
    [string]$RegistryCaCertFile = '',
    [switch]$ReinstallRadius,

    [string]$ResourceGroup = 'bcd',
    [string]$WorkspaceName = 'bcd-aldo',
    [string]$EnvironmentName = 'bcd-aldo',
    [string]$Namespace = 'bcd-aldo',
    [string]$RadiusVersion = '0.60',

    # Recipe pulls. Supply when the local registry requires authentication for the Radius control
    # plane, which fetches Recipes itself and cannot use a Kubernetes image pull secret for it.
    [string]$RegistryUsername,
    [securestring]$RegistryPassword,

    [securestring]$SqlAdminPassword,

    # Identity. Leave these at their defaults after running keycloak.ps1: the issuer is discovered
    # from the cluster, and the workers then authenticate to the queue with a token instead of a
    # password. Pass -SkipOAuth to fall back to the Recipe-issued broker credentials.
    [string]$IdentityNamespace = 'identity',
    [string]$KeycloakRelease = 'keycloak',
    [string]$KeycloakRealm = 'bcd',
    [int]$KeycloakNodePort = 30443,
    [string]$WorkloadServiceAccount = 'bcd-workload',
    [string]$IdentityCaSecretName = 'bcd-identity-ca',
    [switch]$SkipOAuth,

    [switch]$SkipImageBuild,
    [switch]$SkipRadiusInstall
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

$temporaryFiles = @()

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

    $path = Join-Path ([System.IO.Path]::GetTempPath()) "bcd-aldo-params-$([guid]::NewGuid().ToString('N')).json"
    # Windows PowerShell's 'utf8' encoding emits a BOM, which the rad CLI rejects with
    # "invalid character 'ï' looking for beginning of value".
    [System.IO.File]::WriteAllText($path, ($document | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
    return $path
}

try {
    Write-Host "==> Checking the cluster is reachable" -ForegroundColor Cyan
    Invoke-Checked 'kubectl cluster-info' { kubectl cluster-info --context $KubeContext --request-timeout=20s | Out-Null }

    # Radius.Core/environments does not create its namespace.
    Write-Host "==> Ensuring namespace '$Namespace'" -ForegroundColor Cyan
    kubectl create namespace $Namespace --context $KubeContext --dry-run=client -o yaml |
        kubectl apply --context $KubeContext -f -
    if ($LASTEXITCODE -ne 0) { throw 'Creating the application namespace failed.' }

    if (-not $SkipRadiusInstall) {
        # Every control-plane image must come from the local registry. Contour is skipped because
        # this application exposes no gateways or routes, which keeps two images out of the air gap.
        Write-Host "==> Installing the Radius control plane from $Registry" -ForegroundColor Cyan

        $installArgs = @(
            'install', 'kubernetes',
            '--kubecontext', $KubeContext,
            '--skip-contour-install',
            '--set', "global.imageRegistry=$Registry",
            '--set', "global.imageTag=$RadiusVersion"
        )
        if ($ImagePullSecretName) {
            $installArgs += @('--set', "global.imagePullSecrets[0].name=$ImagePullSecretName")
        }
        if ($RegistryCaCertFile) {
            if (-not (Test-Path $RegistryCaCertFile)) {
                throw "No CA certificate at '$RegistryCaCertFile'."
            }
            $installArgs += @('--set-file', "global.rootCA.cert=$RegistryCaCertFile")
        }
        if ($ReinstallRadius) { $installArgs += '--reinstall' }

        Invoke-Checked 'rad install' { rad @installArgs }
    }

    # Radius CLI commands target the workspace's Kubernetes context, not the current kubectl
    # context. The group cannot be set on first creation because it does not exist yet.
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
        rad bicep publish-extension -f deploy/types/messageQueues.yaml --target deploy/types/businessContinuity.tgz
    }

    if (-not $SkipImageBuild) {
        # The .NET base images come from the local registry too: mcr.microsoft.com is unreachable.
        Write-Host "==> Building worker images against base images in $Registry" -ForegroundColor Cyan
        Invoke-Checked 'docker build publisher' {
            docker build --build-arg "BASE_REGISTRY=$Registry" -f docker/Dockerfile.publisher -t "$Registry/bcd/publisher:latest" .
        }
        Invoke-Checked 'docker build consumer' {
            docker build --build-arg "BASE_REGISTRY=$Registry" -f docker/Dockerfile.consumer -t "$Registry/bcd/consumer:latest" .
        }

        Write-Host "==> Pushing worker images" -ForegroundColor Cyan
        Invoke-Checked 'docker push publisher' { docker push "$Registry/bcd/publisher:latest" }
        Invoke-Checked 'docker push consumer' { docker push "$Registry/bcd/consumer:latest" }
    }

    # Publishes the in-cluster backing service Recipes plus the Kubernetes container and secrets
    # Recipes, all from source. No OCI artifact has to cross the air gap.
    Write-Host "==> Publishing Recipes to $Registry" -ForegroundColor Cyan
    ./scripts/publish-recipes.ps1 -Registry $Registry -Set aldo

    # `rad deploy` always needs an environment to deploy into, including for the Recipe Pack that
    # the real environment depends on.
    Write-Host "==> Creating the bootstrap environment" -ForegroundColor Cyan
    Invoke-Checked 'rad env create bootstrap' {
        rad env create bootstrap --group $ResourceGroup --workspace $WorkspaceName
    }

    # The queue trusts Keycloak only if Keycloak is actually there. Rather than make the caller
    # repeat the URL, it is derived the same way keycloak.ps1 printed it, and absence simply means
    # the deployment falls back to broker credentials.
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
                throw "Secret '$IdentityCaSecretName' is missing from namespace '$Namespace', so the workers cannot trust $oauthIssuer. Re-run scripts/azurelocal/keycloak.ps1, or pass -SkipOAuth."
            }

            Write-Host "==> Queue authentication federated to $oauthIssuer" -ForegroundColor Cyan
        }
    }

    Write-Host "==> Deploying the Recipe Pack" -ForegroundColor Cyan
    Invoke-Checked 'rad deploy recipe pack' {
        rad deploy deploy/recipe-packs/aldo.bicep `
            --workspace $WorkspaceName `
            --group $ResourceGroup `
            --environment bootstrap `
            --parameters registry=$Registry `
            --parameters imagePullSecretName=$ImagePullSecretName `
            --parameters oauthIssuer=$oauthIssuer `
            --parameters oauthCaSecretName=$(if ($oauthIssuer) { $IdentityCaSecretName } else { '' })
    }

    $bicepSettingsId = ''
    if ($RegistryUsername) {
        if (-not $RegistryPassword) { throw '-RegistryPassword is required when -RegistryUsername is supplied.' }

        # The Radius control plane pulls Recipes itself, so a Kubernetes image pull secret does not
        # cover it. The Environment must be created before the secret, which references it.
        Write-Host "==> Creating the Environment (first pass, no registry credentials)" -ForegroundColor Cyan
        Invoke-Checked 'rad deploy environment' {
            rad deploy deploy/environments/aldo.bicep `
                --workspace $WorkspaceName --group $ResourceGroup --environment bootstrap `
                --parameters namespace=$Namespace
        }

        Write-Host "==> Configuring registry authentication for Recipe pulls" -ForegroundColor Cyan
        $plainRegistryPassword = [System.Net.NetworkCredential]::new('', $RegistryPassword).Password
        Invoke-Checked 'rad deploy registry auth' {
            rad deploy deploy/registry-auth.bicep `
                --workspace $WorkspaceName --group $ResourceGroup --environment $EnvironmentName `
                --parameters registryHost=$Registry `
                --parameters registryUsername=$RegistryUsername `
                --parameters registryPassword=$plainRegistryPassword
        }

        $bicepSettingsId = rad resource show Radius.Core/bicepSettings bcd-registry-auth `
            --workspace $WorkspaceName --group $ResourceGroup --output json 2>$null |
            ConvertFrom-Json | Select-Object -ExpandProperty id
        if ([string]::IsNullOrWhiteSpace($bicepSettingsId)) {
            throw 'Could not resolve the ID of the bicepSettings resource just deployed.'
        }
    }
    else {
        # The Environment carries the reference to the registry credentials, so redeploying it
        # without one silently drops it and every later Recipe pull fails with 401. Credentials
        # already configured by an earlier run are therefore carried forward.
        $existingSettings = rad resource show Radius.Core/bicepSettings bcd-registry-auth `
            --workspace $WorkspaceName --group $ResourceGroup --output json 2>$null |
            ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($existingSettings -and $existingSettings.id) {
            $bicepSettingsId = $existingSettings.id
            Write-Host "==> Reusing the registry credentials configured by an earlier run" -ForegroundColor DarkGray
        }
    }

    Write-Host "==> Deploying the Environment" -ForegroundColor Cyan
    Invoke-Checked 'rad deploy environment' {
        rad deploy deploy/environments/aldo.bicep `
            --workspace $WorkspaceName `
            --group $ResourceGroup `
            --environment bootstrap `
            --parameters namespace=$Namespace `
            --parameters bicepSettingsId=$bicepSettingsId
    }

    # Unlike the Azure path, where Entra-only authentication discards it, the SQL container really
    # does authenticate with this password, so it has to survive redeployment. It is kept in a
    # Kubernetes Secret rather than in the repository, and generated on first use.
    $sqlSecretName = 'bcd-sql-admin'
    if ($SqlAdminPassword) {
        $plainSqlPassword = [System.Net.NetworkCredential]::new('', $SqlAdminPassword).Password
    }
    else {
        $storedSqlPassword = kubectl get secret $sqlSecretName --context $KubeContext --namespace $Namespace --output jsonpath='{.data.password}' 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($storedSqlPassword)) {
            $plainSqlPassword = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($storedSqlPassword))
            Write-Host "==> Reusing the SQL administrator password from secret '$sqlSecretName'" -ForegroundColor DarkGray
        }
        else {
            # Base64 of random bytes satisfies SQL Server complexity rules and contains no ';',
            # which would otherwise terminate a connection string.
            $randomBytes = [byte[]]::new(24)
            [System.Security.Cryptography.RandomNumberGenerator]::Fill($randomBytes)
            $plainSqlPassword = 'Bcd1!' + [Convert]::ToBase64String($randomBytes)
            Write-Host "==> Generated a SQL administrator password and stored it in secret '$sqlSecretName'" -ForegroundColor DarkGray
        }
    }

    kubectl create secret generic $sqlSecretName --context $KubeContext --namespace $Namespace `
        --from-literal=password=$plainSqlPassword --dry-run=client --output yaml |
        kubectl apply --context $KubeContext --filename - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Storing the SQL administrator password in '$sqlSecretName' failed." }

    # Where Keycloak is federated to the cluster, the queue needs no credentials at all: the pod
    # presents its ServiceAccount token and gets an access token back. SQL and object storage have
    # no such path and still take what their Recipes issue. serviceAccountName is set either way,
    # because it is the `sub` claim Keycloak matches the workload on.
    $applicationParameters = New-ParameterFile @{
        publisherImage              = "$Registry/bcd/publisher:latest"
        consumerImage               = "$Registry/bcd/consumer:latest"
        sqlAdminUsername            = 'sa'
        sqlAdminPassword            = $plainSqlPassword
        sqlUseEntraId               = $false
        queueUsesBasicAuth          = [string]::IsNullOrWhiteSpace($oauthIssuer)
        archiveUsesConnectionString = $true
        serviceAccountName          = $(if ($oauthIssuer) { $WorkloadServiceAccount } else { '' })
        workloadTokenAudience       = $oauthIssuer
        identityCaSecretName        = $(if ($oauthIssuer) { $IdentityCaSecretName } else { '' })
        imagePullSecretName         = $ImagePullSecretName
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

    Write-Host "`nDeployed to Azure Local." -ForegroundColor Green
    Write-Host "Watch the workers with:"
    Write-Host "  kubectl logs -n $Namespace -l radapp.io/resource=consumer --context $KubeContext -f"
    Write-Host "Check the records written to SQL Server with:"
    Write-Host "  ./lab/local/verify.ps1 -KubeContext $KubeContext -Namespace $Namespace -SqlPassword (kubectl get secret $sqlSecretName -n $Namespace -o jsonpath='{.data.password}' | ForEach-Object { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(`$_)) })"
}
finally {
    foreach ($file in $temporaryFiles) {
        Remove-Item $file -Force -ErrorAction SilentlyContinue
    }
    Pop-Location
}
