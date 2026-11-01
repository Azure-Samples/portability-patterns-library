#Requires -Version 7.0
# Exercises lifecycle orchestration without a cloud account, Kubernetes cluster or container engine.
$ErrorActionPreference = 'Stop'
$scripts = Split-Path -Parent $PSScriptRoot
. "$scripts/lib/settings.ps1"
. "$scripts/lib/database.ps1"
. "$scripts/lib/database-passwords.ps1"
. "$scripts/lib/deployment.ps1"
. "$scripts/lib/registry.ps1"
$global:OmsTestState = @{
    Calls = [Collections.Generic.List[string]]::new()
    Secrets = @{}
    EnvironmentExists = $false
    IdentityExists = $true
    FailPostgresRotation = $false
    AzureEnabled = $false
    AnonymousPull = 'true'
    ManifestDigest = 'sha256:expected'
    RegistrySettingsExist = $false
    Parameters = [Collections.Generic.List[object]]::new()
    ConfigMaps = @{}
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $failure = $null
    try { & $Action }
    catch { $failure = $_.Exception.Message }
    Assert-True ($failure -like "*$Message*") "Expected failure containing '$Message'; got '$failure'."
}

function rad {
    $command = $args -join ' '
    $global:OmsTestState.Calls.Add("rad $command")
    $global:LASTEXITCODE = 0
    if ($command -like 'resource show Radius.Core/environments*' -or $command -like 'env show*') {
        if ($global:OmsTestState.EnvironmentExists) { '{"id":"environment"}' }
        else { $global:LASTEXITCODE = 1 }
    }
    elseif ($command -like 'resource show Radius.Core/bicepSettings*') {
        if ($global:OmsTestState.RegistrySettingsExist) { '{"id":"registry-settings"}' }
        else { $global:LASTEXITCODE = 1 }
    }
    elseif ($command -like 'resource show Radius.Core/recipePacks*') {
        '{"properties":{"recipes":{"Portability.Messaging/messageQueues":{"source":"10.96.0.50/recipes/rabbitmq-queue:stable"},"Radius.Compute/containers":{"parameters":{"oauthIssuer":""}}}}}'
    }
    elseif ($command -like 'resource show Radius.Data/sqlServerDatabases*') {
        '{"properties":{"host":"sql","port":1433,"database":"omsdb"}}'
    }
    elseif ($command -like 'resource show Radius.Data/postgreSqlDatabases*') {
        '{"properties":{"host":"postgres","port":5432,"database":"inventory","tls":"required"}}'
    }
    elseif ($command -like 'deploy*') {
        if ($command -like '*recipe-registry-credentials.bicep*') { $global:OmsTestState.RegistrySettingsExist = $true }
        $parameterFile = $args | Where-Object { $_ -is [string] -and $_.StartsWith('@') } | Select-Object -First 1
        if ($parameterFile) {
            $values = (Get-Content $parameterFile.Substring(1) -Raw | ConvertFrom-Json).parameters
            $global:OmsTestState.Parameters.Add(@{ Template = $args[1]; Values = $values })
        }
    }
}

function kubectl {
    $command = $args -join ' '
    $global:OmsTestState.Calls.Add("kubectl $command")
    $global:LASTEXITCODE = 0
    if ($command -like 'get secret *') {
        $name = $args[2]
        if ($name -eq 'azurelocal-registry') {
            $config = '{"auths":{"10.96.0.50":{"username":"sample","password":"test-only"}}}'
            [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($config))
        }
        elseif ($global:OmsTestState.Secrets.ContainsKey($name)) {
            $data = @{}
            foreach ($key in $global:OmsTestState.Secrets[$name].Keys) {
                $data[$key] = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($global:OmsTestState.Secrets[$name][$key]))
            }
            @{ data = $data } | ConvertTo-Json -Compress
        }
        elseif ($name -eq 'oms-identity-ca') { 'secret/oms-identity-ca' }
    }
    elseif ($command -like 'get configmap azurelocal-registry-ca*') { 'test-ca' }
    elseif ($command -like 'get configmap oms-db-setup*') { 'registry/oms/dbsetup@sha256:test' }
    elseif ($command -like 'get deployment keycloak*') {
        if ($global:OmsTestState.IdentityExists) { 'deployment/keycloak' }
    }
    elseif ($command -like 'get nodes*') { '10.0.0.10' }
    elseif ($command -like 'get service ingress-nginx-controller*') { '10.0.0.20' }
    elseif ($command -like 'get service nginx*') { 'sample-app' }
    elseif ($command -like 'get services --all-namespaces*') {
        '{"items":[{"metadata":{"name":"registry","namespace":"registry"},"spec":{"clusterIP":"10.96.0.50","ports":[{"port":443}]}}]}'
    }
    elseif ($command -like 'get pods*') { '{"items":[{"metadata":{"name":"database-0"}}]}' }
    elseif ($command -like 'get job*') { '{"status":{"succeeded":1}}' }
    elseif ($command -like 'create configmap*') {
        $image = ($args | Where-Object { $_ -like '--from-literal=image=*' } | Select-Object -First 1) -replace '^--from-literal=image=', ''
        @{ kind = 'ConfigMap'; metadata = @{ name = $args[2] }; data = @{ image = $image } } | ConvertTo-Json -Depth 5
    }
    elseif ($command -like 'exec*' -and $command -like '*--container postgres*' -and $global:OmsTestState.FailPostgresRotation) {
        $global:LASTEXITCODE = 1
    }
    elseif ($command -like 'apply*') {
        $document = ($input | Out-String).Trim()
        if ($document.StartsWith('{')) {
            $resource = $document | ConvertFrom-Json -AsHashtable
            if ($resource.kind -eq 'Secret') {
                $data = @{}
                foreach ($key in $resource.data.Keys) {
                    $data[$key] = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($resource.data[$key]))
                }
                $global:OmsTestState.Secrets[$resource.metadata.name] = $data
            }
            elseif ($resource.kind -eq 'ConfigMap') { $global:OmsTestState.ConfigMaps[$resource.metadata.name] = $resource.data }
        }
    }
}

function az {
    if (-not $global:OmsTestState.AzureEnabled) { throw 'Unexpected Azure command in the local lifecycle test.' }
    $command = $args -join ' '
    $global:OmsTestState.Calls.Add("az $command")
    $global:LASTEXITCODE = 0
    if ($command -like 'acr show*--query loginServer*') { 'sample.azurecr.io' }
    elseif ($command -like 'acr show*') { $global:OmsTestState.AnonymousPull }
    elseif ($command -like 'acr login*') { 'test-only-acr-token' }
    elseif ($command -like 'acr manifest show-metadata*') { 'sha256:expected' }
    elseif ($command -like 'acr token credential generate*') { 'test-only-recipe-token' }
    elseif ($command -like 'identity show*') { '{"name":"identity","clientId":"client-id","principalId":"principal-id"}' }
    elseif ($command -like 'resource list*') { '["/subscriptions/test/resourceGroups/test/providers/Microsoft.Insights/components/test"]' }
    elseif ($command -like 'resource show*') { 'InstrumentationKey=test-only' }
    elseif ($command -like 'monitor action-group list*') { '[]' }
}

function Start-Sleep { }
function Start-Process {
    $process = [pscustomobject]@{ Id = 12345; HasExited = $false }
    $process | Add-Member ScriptMethod Refresh { }
    $process
}
function Stop-Process { $global:OmsTestState.Calls.Add('stop port-forward') }
function Invoke-RestMethod { @{ access_token = 'test-only-registry-token' } }
function Invoke-WebRequest { @{ Headers = @{ 'Docker-Content-Digest' = $global:OmsTestState.ManifestDigest } } }
function podman {
    $global:OmsTestState.Calls.Add("podman $($args -join ' ')")
    $global:LASTEXITCODE = 0
}
function New-Item {
    if ($args | Where-Object { $_ -is [string] -and $_ -like '*.docker' }) { return }
    Microsoft.PowerShell.Management\New-Item @args
}

$localDeploy = Join-Path $scripts 'deploy/azurelocal.ps1'
$localEnvironment = Join-Path $scripts 'infra/azurelocal/configure-environment.ps1'
$rotation = Join-Path $scripts 'infra/azurelocal/rotate-database-passwords.ps1'
$settings = @{
    Common = @{ KubeContext = 'test-cluster' }
    Deploy = @{ Namespace = 'test-namespace'; SkipRadiusInstall = $true }
    Environment = @{ Namespace = 'environment-namespace'; SkipRadiusInstall = $true; OtlpEndpoint = '' }
}
$arguments = Get-OmsEnvironmentArguments $settings $localEnvironment
Assert-True ($arguments.Namespace -eq 'environment-namespace') 'Environment overrides must win over legacy Deploy settings.'
$deployArguments = Get-OmsStepArguments $settings 'Deploy' $localDeploy
Assert-True (-not $deployArguments.ContainsKey('SkipRadiusInstall')) 'Legacy platform settings must not enter application deployment.'
Assert-True ($deployArguments.Namespace -eq 'test-namespace') 'Application settings must be preserved.'
$settings.Environment.Typo = $true
Assert-Throws { Get-OmsEnvironmentArguments $settings $localEnvironment } "Unknown Environment setting 'Typo'"
$settings.Environment.Remove('Typo')

$parameterFile = New-OmsParameterFile @{ example = 'value' }
try {
    $bytes = [IO.File]::ReadAllBytes($parameterFile)
    Assert-True (-not ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) 'Parameter files must not have a UTF-8 BOM.'
    Assert-True ((Get-Content $parameterFile -Raw | ConvertFrom-Json).parameters.example.value -eq 'value') 'Parameter files must preserve values.'
    if (-not $IsWindows) {
        Assert-True ([IO.File]::GetUnixFileMode($parameterFile) -eq [IO.UnixFileMode]'UserRead, UserWrite') 'Parameter files must be owner-only.'
    }
}
finally { Remove-Item $parameterFile }

$registry = @{ Host = '10.96.0.50'; Auth = @{ username = 'test'; password = 'test-only' } }
Wait-OmsRegistrySync test-cluster $registry @('oms/api:latest') @{ 'oms/api:latest' = 'sha256:expected' }
$global:OmsTestState.ManifestDigest = 'sha256:stale'
Assert-Throws {
    Wait-OmsRegistrySync test-cluster $registry @('oms/api:latest') @{ 'oms/api:latest' = 'sha256:expected' } 0
} 'Connected registry is still missing'
Assert-True (@($global:OmsTestState.Calls | Where-Object { $_ -eq 'stop port-forward' }).Count -eq 2) 'Registry probes must clean up on success and failure.'
$global:OmsTestState.ManifestDigest = 'sha256:expected'
$global:OmsTestState.Calls.Clear()

Assert-Throws { & $localDeploy -RegistryName sample } 'configure-environment.ps1'
Assert-True (-not ($global:OmsTestState.Calls | Where-Object { $_ -like 'rad install*' -or $_ -like 'rad deploy*' })) 'A missing environment must not trigger platform provisioning.'
$global:OmsTestState.Calls.Clear()
& $localEnvironment -SkipRadiusInstall -PullRegistry 10.96.0.50 -OtlpEndpoint ''
Assert-True ([bool]($global:OmsTestState.Calls | Where-Object { $_ -like 'rad deploy *azure-local.bicep*' })) 'Environment setup must deploy the Recipe Pack.'
Assert-True (-not ($global:OmsTestState.Calls | Where-Object { $_ -like '*deploy/app.bicep*' -or $_ -like '*--container mssql*' })) 'Environment setup must not deploy the app or rotate databases.'
$settingsFile = Join-Path ([IO.Path]::GetTempPath()) "oms-test-settings-$([guid]::NewGuid().ToString('N')).json"
try {
    [IO.File]::WriteAllText($settingsFile, (@{ AzureLocal = $settings } | ConvertTo-Json -Depth 10))
    $global:OmsTestState.Calls.Clear()
    & (Join-Path $scripts 'setup-platform.ps1') -Target AzureLocal -SettingsPath $settingsFile -WhatIf
    Assert-True ($global:OmsTestState.Calls.Count -eq 0) 'Platform WhatIf must not run native commands.'
    & (Join-Path $scripts 'setup-platform.ps1') -Target AzureLocal -SettingsPath $settingsFile `
        -Skip Cluster,Images,Registry,KeyVault,Ingress,Keycloak,Observability
    Assert-True ([bool]($global:OmsTestState.Calls | Where-Object { $_ -like '*deploy/environments/azurelocal.bicep*' })) 'The platform wrapper must run environment configuration after setup.'
}
finally { Remove-Item $settingsFile }
$global:OmsTestState.IdentityExists = $false
Assert-Throws { & $localEnvironment -SkipRadiusInstall -PullRegistry 10.96.0.50 -OtlpEndpoint '' } 'local identity provider is missing'
$global:OmsTestState.IdentityExists = $true

$global:OmsTestState.AzureEnabled = $true
$azureEnvironment = Join-Path $scripts 'infra/azure/configure-environment.ps1'
$azureArguments = @{
    Registry = 'sample.azurecr.io'; SubscriptionId = 'test-subscription'
    AppInfraResourceGroup = 'test-resources'; UseEntraAuthentication = $false
    EnvironmentName = 'custom-environment'; AppNamespace = 'custom-namespace'
}
$global:OmsTestState.Calls.Clear()
& $azureEnvironment @azureArguments
Assert-True (-not ($global:OmsTestState.Calls | Where-Object { $_ -like 'az acr token credential generate*' })) 'Anonymous registry setup must not mint a credential.'
$global:OmsTestState.AnonymousPull = 'false'
$global:OmsTestState.Calls.Clear()
& $azureEnvironment @azureArguments
Assert-True ([bool]($global:OmsTestState.Calls | Where-Object { $_ -like 'az acr token credential generate*' })) 'Private registry credentials belong to explicit environment configuration.'
Assert-True ([bool]($global:OmsTestState.Calls | Where-Object { $_ -like 'rad deploy deploy/recipe-registry-credentials.bicep*' })) 'Private registry setup must bind credentials.'
$environments = @($global:OmsTestState.Parameters | Where-Object { $_.Template -like '*environments/azure.bicep' })
Assert-True ($environments[-1].Values.environmentName.value -eq 'custom-environment') 'Environment setup must preserve the selected environment name.'
Assert-True ($environments[-1].Values.namespace.value -eq 'custom-namespace') 'Environment setup must preserve the selected namespace.'
Assert-True (-not ($global:OmsTestState.Calls | Where-Object { $_ -like '*test-only-recipe-token*' })) 'Registry passwords must not be passed on the command line.'
$global:OmsTestState.Calls.Clear()
Assert-Throws {
    & (Join-Path $scripts 'deploy/azure.ps1') -Registry sample.azurecr.io -SubscriptionId test-subscription `
        -AppInfraResourceGroup test-resources -UseEntraAuthentication $false
} 'configure-environment.ps1'
Assert-True (-not ($global:OmsTestState.Calls | Where-Object { $_ -like 'az acr token*' -or $_ -like 'rad deploy*' })) 'Missing Azure environment must not mint credentials or deploy resources.'
$global:OmsTestState.AzureEnabled = $false

$passwords = @{
    'sql-admin-password' = 'new-sql'; 'postgres-admin-password' = 'new-postgres'
    'sql-api-password' = 'new-api'; 'sql-processor-password' = 'new-processor'; 'postgres-inventory-password' = 'new-inventory'
}
$global:OmsTestState.Secrets['oms-db-passwords'] = $passwords
$global:OmsTestState.Secrets['api-db-credentials'] = @{ SQL_PASSWORD = 'old-api' }
Assert-Throws { Assert-OmsDatabasePasswordsUnchanged test-cluster test-namespace $passwords @{} } 'rotate-database-passwords.ps1'
$global:OmsTestState.Secrets['api-db-credentials'] = @{ SQL_PASSWORD = 'new-api' }
Assert-OmsDatabasePasswordsUnchanged test-cluster test-namespace $passwords @{}
Assert-Throws { & $rotation } 'Deploy the application once'
$global:OmsTestState.Secrets['oms-db-admin'] = @{ 'sql-admin-password' = 'old-sql'; 'postgres-admin-password' = 'old-postgres' }
$global:OmsTestState.FailPostgresRotation = $true
Assert-Throws { & $rotation } 'Changing the postgres administrator password failed'
Assert-True ($global:OmsTestState.Secrets['oms-db-admin']['sql-admin-password'] -eq 'new-sql') 'A successful administrator change must survive a later failure.'
Assert-True ($global:OmsTestState.Secrets['oms-db-admin']['postgres-admin-password'] -eq 'old-postgres') 'A failed administrator change must not be recorded as applied.'
$global:OmsTestState.FailPostgresRotation = $false
$global:OmsTestState.Calls.Clear()
& $rotation
Assert-True (-not ($global:OmsTestState.Calls | Where-Object { $_ -like '*--container mssql*' })) 'Retry must not repeat a completed SQL administrator change.'
Assert-True ($global:OmsTestState.Secrets['inventory-db-credentials'].POSTGRES_PASSWORD -eq 'new-inventory') 'Rotation must update per-service credentials.'
Assert-True (-not ($global:OmsTestState.Calls | Where-Object { $_ -like 'rad install*' -or $_ -like 'rad deploy*' })) 'Rotation must not install Radius or redeploy application resources.'

$global:OmsTestState.EnvironmentExists = $true
$global:OmsTestState.AzureEnabled = $true
$global:OmsTestState.Calls.Clear()
& $localDeploy -RegistryName sample -PullRegistry 10.96.0.50 -SkipImageBuild -ImageTag release-1
Assert-True ([bool]($global:OmsTestState.Calls | Where-Object { $_ -like 'rad deploy deploy/app.bicep*' })) 'Normal application deployment must deploy app.bicep.'
Assert-True (-not ($global:OmsTestState.Calls | Where-Object { $_ -like 'rad install*' -or $_ -like 'rad env create*' -or $_ -like '*--container mssql*' })) 'Normal app deployment must not configure the platform or rotate administrator credentials.'
Assert-True ([bool]($global:OmsTestState.Calls | Where-Object { $_ -like 'rad bicep publish*recipes/rabbitmq-queue:stable*' })) 'Recipe publication must retain the configured platform tag.'
Assert-True ([bool]($global:OmsTestState.Calls | Where-Object { $_ -like 'az acr manifest show-metadata*oms/api:release-1*' })) 'Application image tags must remain independently selectable.'
Assert-True ($global:OmsTestState.ConfigMaps['oms-db-setup'].image -eq '10.96.0.50/oms/dbsetup@sha256:expected') 'Successful deployment must record the digest-pinned database setup image.'
$global:OmsTestState.AzureEnabled = $false

foreach ($target in 'azure', 'azurelocal') {
    $source = Get-Content (Join-Path $scripts "deploy/$target.ps1") -Raw
    Assert-True ($source -notmatch 'rad install|rad env create|rad resource-type create|rad deploy recipe-registry-credentials') 'Application deployment must not own platform configuration.'
    Assert-True ($source -match 'configure-environment.ps1') 'Missing-platform errors must identify the explicit setup command.'
}
Write-Host 'Deployment lifecycle checks passed.' -ForegroundColor Green
