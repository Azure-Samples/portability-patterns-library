# Shared by the Azure Local scripts that run against the cluster: addresses the cluster already
# knows, read from it instead of configured.

. (Join-Path $PSScriptRoot 'secrets.ps1')

# The registry the cluster pulls from: the server in the image pull secret that
# connected-registry.ps1 writes into each namespace.
function Get-OmsPullRegistry([string]$KubeContext, [string]$Namespace, [string]$SecretName = 'azurelocal-registry') {
    $dockerConfig = Get-OmsSecretValue -KubeContext $KubeContext -Namespace $Namespace -Name $SecretName -Key '.dockerconfigjson'
    if (-not $dockerConfig) { return }
    @(($dockerConfig | ConvertFrom-Json).auths.PSObject.Properties.Name) | Select-Object -First 1
}

# The address the Arc load balancer gave a Service, by default the ingress controller's. Nothing when
# the Service doesn't exist or has no address yet; throws when the cluster can't be read.
function Get-OmsIngressAddress([string]$KubeContext, [string]$Namespace = 'ingress-nginx', [string]$ServiceName = 'ingress-nginx-controller') {
    $address = kubectl get service $ServiceName --namespace $Namespace --context $KubeContext --ignore-not-found `
        --output 'jsonpath={.status.loadBalancer.ingress[0].ip}'
    if ($LASTEXITCODE -ne 0) { throw "Reading Service '$Namespace/$ServiceName' failed." }
    if (-not [string]::IsNullOrWhiteSpace($address)) { $address.Trim() }
}

# Keycloak's realm URL, the token issuer every site component trusts: https on the address the Arc
# load balancer gave Keycloak's Service (keycloak.ps1), so it doesn't depend on any one node.
function Get-OmsKeycloakIssuer([string]$KubeContext, [string]$Realm = 'oms', [string]$Namespace = 'identity', [string]$ServiceName = 'keycloak') {
    $address = Get-OmsIngressAddress $KubeContext $Namespace $ServiceName
    if ($address) { "https://$address/realms/$Realm" }
}

# Whether a namespaced object exists. Throws when the cluster can't be read, so a failed read is
# never taken for a missing object.
function Test-OmsResource([string]$KubeContext, [string]$Namespace, [string]$Kind, [string]$Name) {
    $namespaceArguments = if ($Namespace) { @('--namespace', $Namespace) } else { @() }
    $found = kubectl get $Kind $Name @namespaceArguments --context $KubeContext --ignore-not-found --output name
    if ($LASTEXITCODE -ne 0) { throw "Reading $Kind '$Name' failed." }
    [bool]$found
}

# Creates a namespace if needed and sets the given labels on it. The labels are set with kubectl
# label, not in the applied object, so a later apply of the namespace without them keeps them.
function Set-OmsNamespace([string]$KubeContext, [string]$Namespace, [hashtable]$Labels = @{}) {
    @{
        apiVersion = 'v1'
        kind       = 'Namespace'
        metadata   = @{ name = $Namespace }
    } | ConvertTo-Json -Depth 5 | kubectl apply --context $KubeContext -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Creating namespace '$Namespace' failed." }
    if ($Labels.Count -eq 0) { return }
    $pairs = @($Labels.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })
    kubectl label namespace $Namespace @pairs --overwrite --context $KubeContext | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Labelling namespace '$Namespace' failed." }
}

# Creates a namespace if needed and copies the connected registry's pull secret into it, unless one
# is there already (connected-registry.ps1 writes it into the namespaces it knows about).
function Copy-OmsPullSecret {
    param(
        [Parameter(Mandatory = $true)][string]$KubeContext,
        [Parameter(Mandatory = $true)][string]$Namespace,
        [Parameter(Mandatory = $true)][string]$SourceNamespace,
        [string]$SecretName = 'azurelocal-registry'
    )

    Set-OmsNamespace $KubeContext $Namespace
    if (Test-OmsResource $KubeContext $Namespace 'secret' $SecretName) { return }

    $dockerConfig = Get-OmsSecretValue -KubeContext $KubeContext -Namespace $SourceNamespace -Name $SecretName -Key '.dockerconfigjson'
    if (-not $dockerConfig) {
        throw "No pull secret '$SecretName' in '$SourceNamespace' to copy into '$Namespace'. Run scripts/infra/azurelocal/connected-registry.ps1 first."
    }
    Set-OmsSecret -KubeContext $KubeContext -Namespace $Namespace -Name $SecretName -Type 'kubernetes.io/dockerconfigjson' `
        -Data @{ '.dockerconfigjson' = $dockerConfig }
    Write-Host "    copied pull secret $SourceNamespace/$SecretName into $Namespace" -ForegroundColor DarkGray
}

# Copies the site CA's certificate (public, key ca.crt), which provision-ingress.ps1 publishes in the
# application namespace, into another namespace, so what runs there can verify the in-cluster
# services the site CA signs.
function Copy-OmsSiteCa {
    param(
        [Parameter(Mandatory = $true)][string]$KubeContext,
        [Parameter(Mandatory = $true)][string]$Namespace,
        [Parameter(Mandatory = $true)][string]$SourceNamespace,
        [string]$SecretName = 'oms-site-ca'
    )

    $ca = Get-OmsSecretValue -KubeContext $KubeContext -Namespace $SourceNamespace -Name $SecretName -Key 'ca.crt'
    if (-not $ca) {
        throw "No site CA in Secret '$SourceNamespace/$SecretName'. Run scripts/infra/azurelocal/provision-ingress.ps1 first."
    }
    Set-OmsNamespace $KubeContext $Namespace
    Set-OmsSecret -KubeContext $KubeContext -Namespace $Namespace -Name $SecretName -Data @{ 'ca.crt' = $ca }
}

# Waits until cert-manager has issued a Certificate for its current spec. kubectl wait ignores a
# Ready condition left from an earlier generation of the spec.
function Wait-OmsCertificate([string]$KubeContext, [string]$Namespace, [string]$Name, [int]$TimeoutSeconds = 180) {
    kubectl wait "certificate/$Name" --namespace $Namespace --context $KubeContext --for=condition=Ready `
        --timeout="${TimeoutSeconds}s" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Certificate $Namespace/$Name was not issued within $TimeoutSeconds seconds. See: kubectl describe certificate $Name --namespace $Namespace --context $KubeContext"
    }
}
