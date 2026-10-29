# Shared by the Azure Local scripts that run against the cluster: addresses the cluster already
# knows, read from it instead of configured.

# The registry the cluster pulls from: the server in the image pull secret that
# connected-registry.ps1 writes into each namespace.
function Get-OmsPullRegistry([string]$KubeContext, [string]$Namespace, [string]$SecretName = 'azurelocal-registry') {
    $encoded = kubectl get secret $SecretName --namespace $Namespace --context $KubeContext --ignore-not-found `
        --output 'jsonpath={.data.\.dockerconfigjson}' 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($encoded)) { return }
    $auths = ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | ConvertFrom-Json).auths
    @($auths.PSObject.Properties.Name) | Select-Object -First 1
}

# The address the Arc load balancer gave the ingress controller, once it has one.
function Get-OmsIngressAddress([string]$KubeContext, [string]$Namespace = 'ingress-nginx', [string]$ServiceName = 'ingress-nginx-controller') {
    $address = kubectl get service $ServiceName --namespace $Namespace --context $KubeContext --ignore-not-found `
        --output 'jsonpath={.status.loadBalancer.ingress[0].ip}' 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($address)) { $address.Trim() }
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