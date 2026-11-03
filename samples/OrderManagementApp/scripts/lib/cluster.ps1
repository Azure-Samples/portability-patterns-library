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

# The address the Arc load balancer gave the ingress controller, once it has one.
function Get-OmsIngressAddress([string]$KubeContext, [string]$Namespace = 'ingress-nginx', [string]$ServiceName = 'ingress-nginx-controller') {
    $address = kubectl get service $ServiceName --namespace $Namespace --context $KubeContext --ignore-not-found `
        --output 'jsonpath={.status.loadBalancer.ingress[0].ip}' 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($address)) { $address.Trim() }
}

# Keycloak's realm URL, the token issuer every site component trusts: https on the address the Arc
# load balancer gave Keycloak's Service (keycloak.ps1), so it doesn't depend on any one node.
function Get-OmsKeycloakIssuer([string]$KubeContext, [string]$Realm = 'oms', [string]$Namespace = 'identity', [string]$ServiceName = 'keycloak') {
    $address = Get-OmsIngressAddress $KubeContext $Namespace $ServiceName
    if ($address) { "https://$address/realms/$Realm" }
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

    kubectl create namespace $Namespace --context $KubeContext --dry-run=client -o yaml |
        kubectl apply --context $KubeContext -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Creating namespace '$Namespace' failed." }
    if (kubectl get secret $SecretName --namespace $Namespace --context $KubeContext --ignore-not-found -o name) { return }

    $dockerConfig = kubectl get secret $SecretName --namespace $SourceNamespace --context $KubeContext --ignore-not-found `
        -o 'jsonpath={.data.\.dockerconfigjson}'
    if ($LASTEXITCODE -ne 0 -or -not $dockerConfig) {
        throw "No pull secret '$SecretName' in '$SourceNamespace' to copy into '$Namespace'. Run scripts/infra/azurelocal/connected-registry.ps1 first."
    }
    @{
        apiVersion = 'v1'
        kind       = 'Secret'
        type       = 'kubernetes.io/dockerconfigjson'
        metadata   = @{ name = $SecretName; namespace = $Namespace }
        data       = @{ '.dockerconfigjson' = $dockerConfig }
    } | ConvertTo-Json -Depth 5 | kubectl apply --context $KubeContext -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Copying the pull secret into '$Namespace' failed." }
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
    kubectl create namespace $Namespace --context $KubeContext --dry-run=client -o yaml |
        kubectl apply --context $KubeContext -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Creating namespace '$Namespace' failed." }
    Set-OmsSecret -KubeContext $KubeContext -Namespace $Namespace -Name $SecretName -Data @{ 'ca.crt' = $ca }
}

# Waits until cert-manager has issued a Certificate for its current spec. 'kubectl wait
# --for=condition=Ready' would accept the condition left from before a change, such as a new
# issuer, and so return before the Secret holds the new certificate.
function Wait-OmsCertificate([string]$KubeContext, [string]$Namespace, [string]$Name, [int]$TimeoutSeconds = 180) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        $certificate = kubectl get certificate $Name --namespace $Namespace --context $KubeContext --output json | ConvertFrom-Json
        $ready = $certificate.status.conditions | Where-Object { $_.type -eq 'Ready' }
        if ($ready.status -eq 'True' -and $ready.observedGeneration -eq $certificate.metadata.generation) { return }
        if ((Get-Date) -gt $deadline) {
            throw "Certificate $Namespace/$Name was not issued within $TimeoutSeconds seconds: $($ready.message)"
        }
        Start-Sleep -Seconds 5
    }
}