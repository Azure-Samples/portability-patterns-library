<#
.SYNOPSIS
    Runs an ACR connected registry inside the AKS Arc cluster so images and Recipes stay pullable
    when Azure Local loses its link to Azure.

.DESCRIPTION
    The cloud registry (Premium, created by provision-infra.ps1) stays the place images and Recipes
    are pushed to. A ReadOnly connected registry, deployed as the
    Microsoft.ContainerRegistry.ConnectedRegistry Arc extension, continuously syncs the listed
    repositories into the cluster and serves them on a fixed ClusterIP. Kubelet and the Radius
    control plane pull from that address, so a pod restarted while Azure is unreachable still finds
    its image.

    The Azure resources are declared in infra/azurelocal/connected-registry.bicep: the client and sync
    scope maps and tokens, the connected registry and its Arc extension. This script:
      1. Deploys the template. Tokens are only created when missing: redeploying one would delete
         its passwords.
      2. On first install, generates the sync password and deploys the template again with the
         connection string, which installs the Arc extension. The extension brings cert-manager and
         distributes the registry's CA to every node so kubelet trusts it.
      3. Stores the client token as image pull secret '<PullSecretName>' in every namespace that
         pulls from the registry, and the registry CA as ConfigMap '<CaConfigMapName>' in the
         application namespace for deploy.ps1 to hand to the Radius control plane.

    -Repositories is the complete list the connected registry syncs: repositories left out are
    removed from its scope.
    Idempotent. Token passwords and the sync connection string are only generated when they are not
    already in place, since regenerating them breaks whatever is using the old value.

.EXAMPLE
    ./scripts/infra/azurelocal/connected-registry.ps1 -RegistryName <acr-name> -KubeContext bcd-aksarc
#>
[CmdletBinding()]
param(
    [string]$RegistryName = '<acr-name>',
    [string]$ResourceGroup = 'bcd-azurelocal',
    [string]$ClusterName = 'bcd-aksarc',
    [string]$KubeContext = 'bcd-aksarc',

    [ValidatePattern('^[a-zA-Z][a-zA-Z0-9]{4,39}$')]
    [string]$ConnectedRegistryName = 'bcdazlocalcr',
    [string]$ExtensionName = 'bcd-connected-registry',

    # Must fall inside the cluster's service CIDR and be unused.
    [string]$ServiceClusterIp = '10.96.0.50',
    [string]$StorageRequest = '40Gi',

    [string]$ClientTokenName = 'bcd-azurelocal-pull',
    [string]$PullSecretName = 'azurelocal-registry',
    [string]$CaConfigMapName = 'azurelocal-registry-ca',
    [string[]]$PullSecretNamespaces = @('oms-azurelocal', 'identity', 'radius-system', 'ingress-nginx'),
    [string]$ApplicationNamespace = 'oms-azurelocal',

    [string]$RadiusVersion = '0.60',

    # Repositories synced into the cluster. Base build images (dotnet/*) are deliberately absent:
    # builds run against the cloud registry, only runtime images are needed on site.
    [string[]]$Repositories = @(
        'ucpd', 'controller', 'applications-rp', 'dynamic-rp', 'deployment-engine', 'dashboard', 'bicep', 'pre-upgrade',
        'rabbitmq', 'mssql/server', 'azure-storage/azurite',
        'keycloak/keycloak', 'postgres',
        'ingress-nginx/controller', 'ingress-nginx/kube-webhook-certgen',
        'oms/api', 'oms/processor',
        'recipes/rabbitmq-queue', 'recipes/azurite-objectstorage', 'recipes/mssql-database',
        'recipes/kubernetes-containers', 'radius-project/kube-recipes/secrets'
    )
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path

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

function Invoke-AzProbe {
    param([Parameter(Mandatory = $true)][string[]]$AzArgs)

    $ErrorActionPreference = 'Continue'

    $output = az @AzArgs 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }

    $text = ($output | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text
}

function Get-KubeSecretValue {
    param([string]$Namespace, [string]$Name, [string]$Key)

    $ErrorActionPreference = 'Continue'
    $escapedKey = $Key.Replace('.', '\.')
    $value = kubectl get secret $Name --namespace $Namespace --context $KubeContext `
        --ignore-not-found --output "jsonpath={.data.$escapedKey}" 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) { return $null }
    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($value))
}

$temporaryFiles = @()

try {
    Write-Host "==> Checking the cluster is reachable" -ForegroundColor Cyan
    Invoke-Checked 'kubectl cluster-info' { kubectl cluster-info --context $KubeContext --request-timeout=20s | Out-Null }

    # A ClusterIP outside the service CIDR is rejected by the API server, but only once the
    # extension's Helm release is already half installed, so check the obvious case up front.
    $kubernetesServiceIp = kubectl get service kubernetes --namespace default --context $KubeContext -o jsonpath='{.spec.clusterIP}'
    $servicePrefix = ($kubernetesServiceIp -split '\.')[0..1] -join '.'
    if (-not $ServiceClusterIp.StartsWith("$servicePrefix.")) {
        throw "-ServiceClusterIp $ServiceClusterIp does not look like it is in the service CIDR (the 'kubernetes' service is $kubernetesServiceIp)."
    }

    $registryLoginServer = az acr show --name $RegistryName --resource-group $ResourceGroup --query loginServer --output tsv
    if ($LASTEXITCODE -ne 0 -or -not $registryLoginServer) { throw "Registry '$RegistryName' not found in '$ResourceGroup'." }

    # Use the cluster's default StorageClass for the connected registry volume.
    $storageClass = kubectl get storageclass --context $KubeContext -o json | ConvertFrom-Json |
        Select-Object -ExpandProperty items |
        Where-Object { $_.metadata.annotations.'storageclass.kubernetes.io/is-default-class' -eq 'true' } |
        Select-Object -First 1 -ExpandProperty metadata | Select-Object -ExpandProperty name
    if (-not $storageClass) { throw 'The cluster has no default StorageClass for the connected registry volume.' }

    $template = Join-Path $repoRoot 'infra/azurelocal/connected-registry.bicep'
    $tokenExists = { param($name) [bool](Invoke-AzProbe @('acr', 'token', 'show', '--name', $name, '--registry', $RegistryName, '--query', 'name', '--output', 'tsv')) }

    # Parameters go through a file: it carries the repository list and, on first install, the
    # connection string, which must not appear on a command line.
    function Deploy-ConnectedRegistry([string]$ConnectionString) {
        $parameters = [ordered]@{
            registryName          = $RegistryName
            connectedRegistryName = $ConnectedRegistryName
            clusterName           = $ClusterName
            repositories          = @($Repositories)
            clientTokenName       = $ClientTokenName
            createClientToken     = -not (& $tokenExists $ClientTokenName)
            createSyncToken       = -not (& $tokenExists $ConnectedRegistryName)
            syncConnectionString  = $ConnectionString
            extensionName         = $ExtensionName
            serviceClusterIp      = $ServiceClusterIp
            storageClassName      = $storageClass
            storageRequest        = $StorageRequest
        }
        $document = [ordered]@{
            '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
            contentVersion = '1.0.0.0'
            parameters     = [ordered]@{}
        }
        foreach ($key in $parameters.Keys) { $document.parameters[$key] = @{ value = $parameters[$key] } }
        $file = Join-Path ([System.IO.Path]::GetTempPath()) "oms-connected-registry-$([guid]::NewGuid().ToString('N')).json"
        try {
            [System.IO.File]::WriteAllText($file, ($document | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
            Invoke-Checked 'az deployment group create' {
                az deployment group create --resource-group $ResourceGroup --name 'oms-connected-registry' `
                    --template-file $template --parameters "@$file" --output none
            }
        }
        finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
    }

    Write-Host "==> Deploying the connected registry '$ConnectedRegistryName' ($($Repositories.Count) repositories)" -ForegroundColor Cyan
    Deploy-ConnectedRegistry ''

    # ------------------------------------------------------------------------------------------
    # Arc extension. The sync password is only generated on first install: doing it again would
    # disconnect a running instance until the extension is updated with the new value.
    # ------------------------------------------------------------------------------------------
    Write-Host "==> Ensuring Arc extension '$ExtensionName' on '$ClusterName'" -ForegroundColor Cyan
    $clusterId = "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$ResourceGroup/providers/Microsoft.Kubernetes/connectedClusters/$ClusterName"
    $extensionUrl = "https://management.azure.com$clusterId/providers/Microsoft.KubernetesConfiguration/extensions/${ExtensionName}?api-version=2023-05-01"
    $extensionState = Invoke-AzProbe @('rest', '--method', 'get', '--url', $extensionUrl, '--query', 'properties.provisioningState', '--output', 'tsv')

    if ($extensionState -ne 'Succeeded') {
        if ($extensionState) {
            Write-Host "    existing extension is '$extensionState'; reinstalling" -ForegroundColor Yellow
            Invoke-Checked 'delete Arc extension' { az rest --method delete --url $extensionUrl --output none }
            do { Start-Sleep -Seconds 15 } while (Invoke-AzProbe @('rest', '--method', 'get', '--url', $extensionUrl, '--query', 'name', '--output', 'tsv'))
        }

        $connectionString = az acr connected-registry get-settings --name $ConnectedRegistryName --registry $RegistryName `
            --parent-protocol https --generate-password 1 --query ACR_REGISTRY_CONNECTION_STRING --output tsv --yes
        if ($LASTEXITCODE -ne 0 -or -not $connectionString) { throw 'Could not generate the connected registry connection string.' }
        Write-Host "    installing (storage class $storageClass, ClusterIP $ServiceClusterIp)" -ForegroundColor DarkGray
        Deploy-ConnectedRegistry $connectionString.Trim()
        $connectionString = $null
    }
    else {
        Write-Host "    already installed" -ForegroundColor DarkGray
    }
    Write-Host "==> Waiting for the connected registry to come online" -ForegroundColor Cyan
    $deadline = (Get-Date).AddMinutes(15)
    do {
        $state = Invoke-AzProbe @('acr', 'connected-registry', 'show', '--name', $ConnectedRegistryName, '--registry', $RegistryName, '--query', 'connectionState', '--output', 'tsv')
        Write-Host "    $state" -ForegroundColor DarkGray
        if ($state -eq 'Online') { break }
        Start-Sleep -Seconds 20
    } while ((Get-Date) -lt $deadline)
    if ($state -ne 'Online') { throw "Connected registry is '$state' after 15 minutes. Check the pods of the extension." }

    # ------------------------------------------------------------------------------------------
    # Pull secrets. The client token password lives only in the cluster, never in the repository.
    # ------------------------------------------------------------------------------------------
    Write-Host "==> Ensuring image pull secret '$PullSecretName'" -ForegroundColor Cyan
    foreach ($namespace in $PullSecretNamespaces) {
        kubectl create namespace $namespace --context $KubeContext --dry-run=client -o yaml |
            kubectl apply --context $KubeContext -f - | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Creating namespace '$namespace' failed." }
    }

    $dockerConfig = Get-KubeSecretValue -Namespace $ApplicationNamespace -Name $PullSecretName -Key '.dockerconfigjson'
    $clientPassword = $null
    if ($dockerConfig) {
        $auth = ($dockerConfig | ConvertFrom-Json).auths.$ServiceClusterIp
        if ($auth -and $auth.username -eq $ClientTokenName) { $clientPassword = $auth.password }
    }
    if (-not $clientPassword) {
        Write-Host "    generating a client token password" -ForegroundColor DarkGray
        $clientPassword = az acr token credential generate --name $ClientTokenName --registry $RegistryName `
            --password1 --query 'passwords[0].value' --output tsv
        if ($LASTEXITCODE -ne 0 -or -not $clientPassword) { throw 'Generating the client token password failed.' }
    }

    foreach ($namespace in $PullSecretNamespaces) {
        kubectl create secret docker-registry $PullSecretName --context $KubeContext --namespace $namespace `
            --docker-server=$ServiceClusterIp --docker-username=$ClientTokenName --docker-password=$clientPassword `
            --dry-run=client -o yaml | kubectl apply --context $KubeContext -f - | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Writing pull secret to '$namespace' failed." }
        Write-Host "    $namespace/$PullSecretName" -ForegroundColor DarkGray
    }
    $clientPassword = $null

    # ------------------------------------------------------------------------------------------
    # Registry CA. Nodes get it from the extension's trust distribution, but the Radius control
    # plane pulls Recipes itself and needs it explicitly.
    # ------------------------------------------------------------------------------------------
    Write-Host "==> Exporting the connected registry CA" -ForegroundColor Cyan
    $secrets = kubectl get secrets --all-namespaces --context $KubeContext -o json | ConvertFrom-Json
    $caCandidates = @($secrets.items | Where-Object {
            $_.data.'ca.crt' -and $_.metadata.namespace -notin @('kube-system', 'kube-public', 'default') -and
            ($_.metadata.namespace -like '*connected-registry*' -or $_.metadata.name -like '*connected-registry*' -or $_.metadata.name -like '*connectedregistry*')
        })
    if ($caCandidates.Count -eq 0) {
        throw "Could not find the connected registry CA secret. List candidates with: kubectl get secrets -A --context $KubeContext | Select-String connected"
    }
    $caSecret = $caCandidates[0]
    $caPem = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($caSecret.data.'ca.crt'))
    Write-Host "    from $($caSecret.metadata.namespace)/$($caSecret.metadata.name)" -ForegroundColor DarkGray

    $caFile = Join-Path ([System.IO.Path]::GetTempPath()) "bcd-cr-ca-$([guid]::NewGuid().ToString('N')).crt"
    $temporaryFiles += $caFile
    [System.IO.File]::WriteAllText($caFile, $caPem, [System.Text.UTF8Encoding]::new($false))
    kubectl create configmap $CaConfigMapName --context $KubeContext --namespace $ApplicationNamespace `
        --from-file=ca.crt=$caFile --dry-run=client -o yaml | kubectl apply --context $KubeContext -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Writing ConfigMap '$CaConfigMapName' failed." }

    Write-Host "`n================ Connected registry ready ================" -ForegroundColor Green
    Write-Host "Cloud registry   : $registryLoginServer (push here)"
    Write-Host "In-cluster pulls : $ServiceClusterIp (secret '$PullSecretName', CA ConfigMap '$ApplicationNamespace/$CaConfigMapName')"
    Write-Host "Synced repos     : $($Repositories.Count)"
}
finally {
    foreach ($file in $temporaryFiles) {
        Remove-Item $file -Force -ErrorAction SilentlyContinue
    }
}
