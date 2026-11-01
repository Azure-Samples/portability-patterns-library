#Requires -Version 7.0
<#
.SYNOPSIS
    Installs Radius and configures the Azure Local Recipe Pack and Environment.
.DESCRIPTION
    Uses the connected registry, local identity provider and ingress prepared by platform setup.
    Run this separately when platform settings or registry trust change. It does not build or
    deploy the application, initialize databases, or rotate passwords.
.EXAMPLE
    ./scripts/configure-environment.ps1 -Target AzureLocal
#>
[CmdletBinding()]
param(
    [string]$KubeContext = 'bcd-aksarc',
    [string]$PullRegistry,
    [string]$ImagePullSecretName = 'azurelocal-registry',
    [string]$RegistryCaConfigMapName = 'azurelocal-registry-ca',
    [int]$SyncTimeoutMinutes = 20,
    [switch]$ReinstallRadius,
    [switch]$SkipRadiusInstall,
    [string]$ResourceGroup = 'oms',
    [string]$WorkspaceName = 'oms-azurelocal',
    [string]$EnvironmentName = 'oms-azurelocal',
    [string]$Namespace = 'oms-azurelocal',
    [string]$RadiusVersion = '0.60',
    [string]$ImageTag = 'latest',
    [string]$SqlServerEdition = 'Developer',
    [string]$CertificateIssuer = 'site-ca',
    [string]$OtlpEndpoint = 'http://otel-collector.observability.svc.cluster.local:4317',
    [string]$IdentityNamespace = 'identity',
    [string]$KeycloakRelease = 'keycloak',
    [string]$KeycloakRealm = 'oms',
    [int]$KeycloakNodePort = 30443,
    [string]$WorkloadClientId = 'workload-{resource}',
    [string]$IdentityCaSecretName = 'oms-identity-ca',
    [switch]$SkipOAuth,
    [string]$IngressNamespace = 'ingress-nginx',
    [string]$IngressClassName = 'nginx',
    [string]$IngressTlsSecretName = 'oms-app-tls'
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
. "$repoRoot/scripts/lib/recipes.ps1"
. "$repoRoot/scripts/lib/cluster.ps1"
. "$repoRoot/scripts/lib/registry.ps1"
. "$repoRoot/scripts/lib/settings.ps1"
. "$repoRoot/scripts/lib/deployment.ps1"
$temporaryFiles = @()
Push-Location $repoRoot
try {
    $registry = Get-OmsConnectedRegistry $KubeContext $Namespace $PullRegistry $ImagePullSecretName $RegistryCaConfigMapName
    if (-not $SkipRadiusInstall) {
        $artifacts = @('ucpd', 'controller', 'applications-rp', 'dynamic-rp', 'deployment-engine', 'bicep') |
            ForEach-Object { "${_}:$RadiusVersion" }
        Wait-OmsRegistrySync -KubeContext $KubeContext -Registry $registry -Artifacts $artifacts -TimeoutMinutes $SyncTimeoutMinutes
        $caFile = Join-Path ([IO.Path]::GetTempPath()) "oms-registry-ca-$([guid]::NewGuid().ToString('N')).crt"
        $temporaryFiles += $caFile
        [IO.File]::WriteAllText($caFile, $registry.Ca, [Text.UTF8Encoding]::new($false))
        $installArgs = @('install', 'kubernetes', '--kubecontext', $KubeContext, '--skip-contour-install',
            '--set', "global.imageRegistry=$($registry.Host)", '--set', "global.imageTag=$RadiusVersion",
            '--set', "global.imagePullSecrets[0].name=$ImagePullSecretName",
            '--set-file', "global.rootCA.cert=$caFile")
        if ($ReinstallRadius) { $installArgs += '--reinstall' }
        Invoke-OmsChecked 'rad install' { rad @installArgs }
        if ($ReinstallRadius) {
            Invoke-OmsChecked 'restart Radius' { kubectl rollout restart deployment -n radius-system --context $KubeContext | Out-Null }
            Invoke-OmsChecked 'wait for Radius' { kubectl rollout status deployment -n radius-system --context $KubeContext --timeout=600s | Out-Null }
        }
    }
    Invoke-OmsChecked 'bind workspace' { rad workspace create kubernetes $WorkspaceName --context $KubeContext --force }
    Invoke-OmsChecked 'create Radius group' { rad group create $ResourceGroup --workspace $WorkspaceName }
    Invoke-OmsChecked 'bind group' { rad workspace create kubernetes $WorkspaceName --context $KubeContext --group $ResourceGroup --force }
    Invoke-OmsChecked 'register queue type' { rad resource-type create messageQueues -f $QueueTypeFile --workspace $WorkspaceName }
    Invoke-OmsChecked 'publish queue extension' { rad bicep publish-extension -f $QueueTypeFile --target $QueueTypeExtension }
    Invoke-OmsChecked 'create bootstrap environment' { rad env create bootstrap --group $ResourceGroup --workspace $WorkspaceName }

    $oauthIssuer = ''
    if (-not $SkipOAuth) {
        $identity = kubectl get deployment $KeycloakRelease -n $IdentityNamespace --context $KubeContext --ignore-not-found -o name
        if ($LASTEXITCODE -ne 0 -or -not $identity) {
            throw 'The local identity provider is missing. Run the Keycloak setup step, or explicitly select -SkipOAuth for a broker-only demonstration.'
        }
        $nodeIp = kubectl get nodes --context $KubeContext --output 'jsonpath={.items[0].status.addresses[?(@.type=="InternalIP")].address}'
        if ($LASTEXITCODE -ne 0 -or -not $nodeIp) { throw 'Could not resolve a node IP for the Keycloak issuer.' }
        $oauthIssuer = "https://${nodeIp}:$KeycloakNodePort/realms/$KeycloakRealm"
        $ca = kubectl get secret $IdentityCaSecretName -n $Namespace --context $KubeContext --ignore-not-found -o name
        if ($LASTEXITCODE -ne 0 -or -not $ca) { throw "Identity CA Secret '$Namespace/$IdentityCaSecretName' is missing." }
    }
    $ingressAddress = kubectl get service ingress-nginx-controller -n $IngressNamespace --context $KubeContext `
        --ignore-not-found -o 'jsonpath={.status.loadBalancer.ingress[0].ip}'
    if ($LASTEXITCODE -ne 0) { throw 'Could not read ingress configuration.' }
    $useCollector = $false
    if ($OtlpEndpoint) {
        $collectorService, $collectorNamespace = ([uri]$OtlpEndpoint).Host -split '\.'
        $useCollector = [bool](kubectl get service $collectorService -n $collectorNamespace --context $KubeContext --ignore-not-found -o name)
        if ($LASTEXITCODE -ne 0) { throw 'Could not read OpenTelemetry Collector configuration.' }
        if (-not $useCollector) { Write-Warning "No collector at $OtlpEndpoint; telemetry export is disabled." }
    }
    $packFile = New-OmsParameterFile @{
        registry = $registry.Host
        tag = $ImageTag
        imagePullSecretName = $ImagePullSecretName
        oauthIssuer = $oauthIssuer
        oauthCaSecretName = $(if ($oauthIssuer) { $IdentityCaSecretName } else { '' })
        oauthClientId = $(if ($oauthIssuer) { $WorkloadClientId } else { '' })
        serviceAccountName = '{resource}'
        containerEnvFromSecrets = @('{resource}-db-credentials')
        sqlServerEdition = $SqlServerEdition
        certificateIssuer = $CertificateIssuer
        otlpEndpoint = $(if ($useCollector) { $OtlpEndpoint } else { '' })
        ingressClassName = $IngressClassName
        ingressTlsSecretName = $(if ($ingressAddress) { $IngressTlsSecretName } else { '' })
    }
    $temporaryFiles += $packFile
    Invoke-OmsChecked 'deploy Recipe Pack' {
        rad deploy (Join-Path $LibraryRecipePackRoot 'azure-local.bicep') --workspace $WorkspaceName `
            --group $ResourceGroup --environment bootstrap --parameters "@$packFile"
    }
    $environmentJson = rad resource show Radius.Core/environments $EnvironmentName `
        --workspace $WorkspaceName --group $ResourceGroup --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $environmentJson -or $environmentJson -eq 'null') {
        Invoke-OmsChecked 'create environment' {
            rad deploy deploy/environments/azurelocal.bicep --workspace $WorkspaceName --group $ResourceGroup `
                --environment bootstrap --parameters namespace=$Namespace --parameters environmentName=$EnvironmentName
        }
    }
    $authFile = New-OmsParameterFile @{
        registryHost = $registry.Host; registryUsername = $registry.Auth.username; registryPassword = $registry.Auth.password
    }
    $temporaryFiles += $authFile
    Invoke-OmsChecked 'configure registry authentication' {
        rad deploy deploy/recipe-registry-credentials.bicep --workspace $WorkspaceName --group $ResourceGroup `
            --environment $EnvironmentName --parameters "@$authFile"
    }
    $settingsJson = rad resource show Radius.Core/bicepSettings oms-registry-auth --workspace $WorkspaceName --group $ResourceGroup --output json
    if ($LASTEXITCODE -ne 0) { throw 'Could not read registry authentication settings.' }
    $settingsId = ($settingsJson | ConvertFrom-Json).id
    if (-not $settingsId) { throw 'Registry authentication settings have no resource ID.' }
    Invoke-OmsChecked 'configure environment' {
        rad deploy deploy/environments/azurelocal.bicep --workspace $WorkspaceName --group $ResourceGroup `
            --environment bootstrap --parameters namespace=$Namespace --parameters environmentName=$EnvironmentName `
            --parameters bicepSettingsId=$settingsId
    }
    Write-Host 'Radius environment ready. Run ./scripts/deploy.ps1 -Target AzureLocal.' -ForegroundColor Green
}
finally {
    foreach ($file in $temporaryFiles) { Remove-Item $file -Force -ErrorAction SilentlyContinue }
    Pop-Location
}
