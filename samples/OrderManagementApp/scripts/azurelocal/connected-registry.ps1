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

    This script:
      1. Creates a client scope map and token with read access to the synced repositories.
      2. Creates the connected registry (or adds missing repositories to an existing one).
      3. Installs the Arc extension, which brings cert-manager and distributes the registry's CA
         to every node so kubelet trusts it.
      4. Stores the client token as image pull secret '<PullSecretName>' in every namespace that
         pulls from the registry, and the registry CA as ConfigMap '<CaConfigMapName>' in the
         application namespace for deploy.ps1 to hand to the Radius control plane.

    Idempotent. Token passwords and the sync connection string are only regenerated when they are
    not already in place, since regenerating them breaks whatever is using the old value.

.EXAMPLE
    ./scripts/azurelocal/connected-registry.ps1 -RegistryName <acr-name> -KubeContext bcd-aksarc
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
        'recipes/containers', 'radius-project/kube-recipes/secrets'
    )
)

$ErrorActionPreference = 'Stop'

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

    # ------------------------------------------------------------------------------------------
    # Client token: what kubelet and Radius authenticate to the connected registry with.
    # ------------------------------------------------------------------------------------------
    Write-Host "==> Ensuring client scope map and token '$ClientTokenName'" -ForegroundColor Cyan
    $repositoryArgs = @()
    foreach ($repository in $Repositories) {
        $repositoryArgs += @('--repository', $repository, 'content/read', 'metadata/read')
    }

    $existingScopeMap = Invoke-AzProbe @('acr', 'scope-map', 'show', '--name', $ClientTokenName, '--registry', $RegistryName, '--query', 'actions', '--output', 'json')
    if (-not $existingScopeMap) {
        Invoke-Checked 'az acr scope-map create' {
            az acr scope-map create --name $ClientTokenName --registry $RegistryName @repositoryArgs `
                --description 'Read access for in-cluster pulls from the Azure Local connected registry' --output none
        }
    }
    else {
        $actions = @($existingScopeMap | ConvertFrom-Json)
        $missing = @($Repositories | Where-Object { $actions -notcontains "repositories/$_/content/read" })
        if ($missing.Count -gt 0) {
            $addArgs = @()
            foreach ($repository in $missing) { $addArgs += @('--add-repository', $repository, 'content/read', 'metadata/read') }
            Write-Host "    adding $($missing.Count) repositories to the scope map" -ForegroundColor DarkGray
            Invoke-Checked 'az acr scope-map update' {
                az acr scope-map update --name $ClientTokenName --registry $RegistryName @addArgs --output none
            }
        }
    }

    $existingToken = Invoke-AzProbe @('acr', 'token', 'show', '--name', $ClientTokenName, '--registry', $RegistryName, '--query', 'name', '--output', 'tsv')
    if (-not $existingToken) {
        # --no-passwords: a password is generated below only if the cluster does not already hold one.
        Invoke-Checked 'az acr token create' {
            az acr token create --name $ClientTokenName --registry $RegistryName --scope-map $ClientTokenName --no-passwords --output none
        }
    }

    # ------------------------------------------------------------------------------------------
    # Connected registry resource in Azure.
    # ------------------------------------------------------------------------------------------
    Write-Host "==> Ensuring connected registry '$ConnectedRegistryName' (ReadOnly)" -ForegroundColor Cyan
    $connectedRegistry = Invoke-AzProbe @('acr', 'connected-registry', 'show', '--name', $ConnectedRegistryName, '--registry', $RegistryName, '--output', 'json')
    if (-not $connectedRegistry) {
        # No --sync-schedule: the connected registry then syncs continuously while connected.
        Invoke-Checked 'az acr connected-registry create' {
            az acr connected-registry create --name $ConnectedRegistryName --registry $RegistryName `
                --mode ReadOnly --repository @Repositories --client-tokens $ClientTokenName --yes --output none
        }
    }
    else {
        $connectedRegistryObject = $connectedRegistry | ConvertFrom-Json
        # 'az acr token/scope-map show' accept no --ids, so the names come from the resource IDs.
        $syncTokenName = ($connectedRegistryObject.parent.syncProperties.tokenId -split '/')[-1]
        $syncScopeMapId = az acr token show --name $syncTokenName --registry $RegistryName --query scopeMapId --output tsv
        $syncActions = @(az acr scope-map show --name ($syncScopeMapId -split '/')[-1] --registry $RegistryName --query actions --output json | ConvertFrom-Json)
        $missing = @($Repositories | Where-Object { $syncActions -notcontains "repositories/$_/content/read" })
        if ($missing.Count -gt 0) {
            Write-Host "    adding $($missing.Count) repositories to the sync scope" -ForegroundColor DarkGray
            Invoke-Checked 'az acr connected-registry repo' {
                az acr connected-registry repo --name $ConnectedRegistryName --registry $RegistryName --add @missing --output none
            }
        }

        $clientTokenIds = @($connectedRegistryObject.clientTokenIds)
        if (-not ($clientTokenIds | Where-Object { $_ -like "*/tokens/$ClientTokenName" })) {
            Invoke-Checked 'az acr connected-registry update --add-client-tokens' {
                az acr connected-registry update --name $ConnectedRegistryName --registry $RegistryName `
                    --add-client-tokens $ClientTokenName --output none
            }
        }
    }

    # ------------------------------------------------------------------------------------------
    # Arc extension. The sync token password is only regenerated on first install: doing it again
    # would disconnect a running instance until the extension is updated with the new value.
    # ------------------------------------------------------------------------------------------
    Write-Host "==> Ensuring Arc extension '$ExtensionName' on '$ClusterName'" -ForegroundColor Cyan
    $extensionState = Invoke-AzProbe @('k8s-extension', 'show', '--name', $ExtensionName, '--cluster-name', $ClusterName,
        '--resource-group', $ResourceGroup, '--cluster-type', 'connectedClusters', '--query', 'provisioningState', '--output', 'tsv')

    if ($extensionState -ne 'Succeeded') {
        if ($extensionState) {
            Write-Host "    existing extension is '$extensionState'; reinstalling" -ForegroundColor Yellow
            Invoke-Checked 'az k8s-extension delete' {
                az k8s-extension delete --name $ExtensionName --cluster-name $ClusterName --resource-group $ResourceGroup `
                    --cluster-type connectedClusters --yes --output none
            }
        }

        $connectionString = az acr connected-registry get-settings --name $ConnectedRegistryName --registry $RegistryName `
            --parent-protocol https --generate-password 1 --query ACR_REGISTRY_CONNECTION_STRING --output tsv --yes
        if ($LASTEXITCODE -ne 0 -or -not $connectionString) { throw 'Could not generate the connected registry connection string.' }

        $protectedFile = Join-Path ([System.IO.Path]::GetTempPath()) "bcd-cr-protected-$([guid]::NewGuid().ToString('N')).json"
        $temporaryFiles += $protectedFile
        [System.IO.File]::WriteAllText($protectedFile, (@{ connectionString = $connectionString.Trim() } | ConvertTo-Json),
            [System.Text.UTF8Encoding]::new($false))
        $connectionString = $null

        # Use the cluster's default StorageClass rather than guessing its name.
        $storageClass = kubectl get storageclass --context $KubeContext -o json | ConvertFrom-Json |
            Select-Object -ExpandProperty items |
            Where-Object { $_.metadata.annotations.'storageclass.kubernetes.io/is-default-class' -eq 'true' } |
            Select-Object -First 1 -ExpandProperty metadata | Select-Object -ExpandProperty name
        if (-not $storageClass) { throw 'The cluster has no default StorageClass for the connected registry volume.' }
        Write-Host "    storage class: $storageClass, ClusterIP: $ServiceClusterIp" -ForegroundColor DarkGray

        Invoke-Checked 'az k8s-extension create' {
            az k8s-extension create --name $ExtensionName --cluster-name $ClusterName --resource-group $ResourceGroup `
                --cluster-type connectedClusters --extension-type Microsoft.ContainerRegistry.ConnectedRegistry `
                --config "service.clusterIP=$ServiceClusterIp" `
                --config "pvc.storageClassName=$storageClass" `
                --config "pvc.storageRequest=$StorageRequest" `
                --config-protected-file $protectedFile `
                --auto-upgrade-minor-version true --output none
        }
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
