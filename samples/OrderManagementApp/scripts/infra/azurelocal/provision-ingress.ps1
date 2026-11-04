<#
.SYNOPSIS
    Gives applications on the Azure Local cluster an HTTPS address on the site network: an Arc
    NGINX ingress controller on the Arc load balancer, and a TLS certificate from a site CA that
    cert-manager renews in the cluster.

.DESCRIPTION
    Platform layer, like provision-infra.ps1. Applications then only declare ports; the Recipe Pack
    tells the containers Recipe to publish them through this ingress (see
    recipe-packs/azure-local.bicep at the repository root), so deploy/app.bicep is the same as in Azure.

      1. The Arc load balancer (MetalLB, ARP mode) comes from infra/azurelocal/platform.bicep, with
         its address range outside the AKS logical network pool.
      2. Installs the ingress-nginx controller from the connected registry, so it keeps serving if
         Azure is unreachable. The load balancer gives it the first free address of its range and
         later runs keep that address; pass -IngressIp to choose one. The Helm values are in
         infra/azurelocal/ingress-nginx/values.yaml; this script sets only the site values.
      3. Creates a cert-manager ClusterIssuer, -IssuerName, that signs with a site CA kept in the
         cluster: cert-manager issues the CA itself, self-signed, the first time. cert-manager is
         the Certificate Management for Azure Arc extension, installed with the cluster; the
         connected registry gets its certificates from it too. keycloak.ps1 gets Keycloak's
         certificate from it too.
      4. Requests a TLS certificate for the ingress address and any -HostNames from that issuer, into
         Secret -TlsSecretName in the application namespace. cert-manager renews it 30 days before
         it expires, with no link to Azure, and the ingress serves the new one without a restart.
         Browsers need HTTPS: MSAL.js only runs in a secure context.

    The site CA stands in for the organisation's PKI. To use yours, put an intermediate CA it
    issued (certificate and key, as a kubernetes.io/tls Secret) in Secret -CaSecretName in
    -CertManagerNamespace before the first run; this script then uses it as it is, and
    domain-joined machines already trust what it signs. Otherwise machines trust the site CA once
    with the command printed at the end. Back up that Secret: a new CA has to be trusted again
    everywhere. Idempotent.

    Prerequisites: scripts/infra/azurelocal/provision-infra.ps1 (load balancer),
    scripts/infra/azurelocal/import-images.ps1 (ingress-nginx images in the cloud registry) and
    scripts/infra/azurelocal/connected-registry.ps1 (which syncs them into the cluster).

.EXAMPLE
    ./scripts/infra/azurelocal/provision-ingress.ps1 -KubeContext <context> -HostNames orders.contoso.local
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$KubeContext,
    # An address from the load balancer's range. Empty keeps the current one, or takes the first free.
    [string]$IngressIp,
    # DNS names the site gives the ingress address, if any. The certificate always covers the address.
    [string[]]$HostNames = @(),
    [string]$IngressNamespace = 'ingress-nginx',
    [string]$IngressClassName = 'nginx',
    [string]$ChartVersion = '4.15.1',
    [string]$ControllerTag = 'v1.15.1',
    [string]$WebhookCertgenTag = 'v1.6.9',
    # The connected registry's address. Empty reads it from the pull secret connected-registry.ps1 wrote.
    [string]$PullRegistry,
    [string]$PullSecretName = 'azurelocal-registry',
    [string]$ApplicationNamespace = 'oms-azurelocal',
    [string]$TlsSecretName = 'oms-app-tls',
    # Where cert-manager runs: the Certificate Management for Azure Arc extension's namespace.
    [string]$CertManagerNamespace = 'cert-manager',
    # ClusterIssuer that signs the app's and Keycloak's certificates with the site CA.
    [string]$IssuerName = 'site-ca',
    [string]$CaSecretName = 'site-ca',
    [string]$CaCommonName = 'BCD Azure Local Site CA',
    # Where the site CA's certificate is published in the application namespace.
    [string]$SiteCaSecretName = 'oms-site-ca',
    [int]$CertificateDays = 90
)



$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
. (Join-Path $repoRoot 'scripts/lib/cluster.ps1')
Push-Location $repoRoot

# Returns what the command printed.
function Invoke-Checked([string]$What, [scriptblock]$Command) {
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "$What failed with exit code $LASTEXITCODE." }
}

try {
    if (-not $PullRegistry) {
        $PullRegistry = Get-OmsPullRegistry $KubeContext $ApplicationNamespace $PullSecretName
        if (-not $PullRegistry) {
            throw "No pull secret '$PullSecretName' in '$ApplicationNamespace' to read the connected registry's address from. Run scripts/infra/azurelocal/connected-registry.ps1 first, or pass -PullRegistry."
        }
    }
    # Keep the address the app already has, so re-running never moves it.
    if (-not $IngressIp) { $IngressIp = Get-OmsIngressAddress $KubeContext $IngressNamespace }

    # ------------------------------------------------------------------------------------------
    # 1. Ingress controller, pulled from the connected registry
    # ------------------------------------------------------------------------------------------
    $where = if ($IngressIp) { "on $IngressIp" } else { 'on the first free load balancer address' }
    Write-Host "==> Installing ingress-nginx $ChartVersion $where" -ForegroundColor Cyan
    Invoke-Checked 'helm repo add' { helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update | Out-Null }
    # infra/azurelocal/ingress-nginx/values.yaml holds the settings; only the site values are set here.
    $values = Join-Path $repoRoot 'infra/azurelocal/ingress-nginx/values.yaml'
    $siteValues = @(
        '--set', "imagePullSecrets[0].name=$PullSecretName",
        '--set', "controller.image.registry=$PullRegistry",
        '--set', "controller.image.tag=$ControllerTag",
        '--set', "controller.ingressClassResource.name=$IngressClassName",
        '--set', "controller.extraArgs.default-ssl-certificate=$ApplicationNamespace/$TlsSecretName",
        '--set', "controller.admissionWebhooks.patch.image.registry=$PullRegistry",
        '--set', "controller.admissionWebhooks.patch.image.tag=$WebhookCertgenTag"
    )
    # MetalLB refuses a Service that also sets spec.loadBalancerIP, so a chosen address goes in its annotation.
    if ($IngressIp) { $siteValues += '--set', "controller.service.annotations.metallb\.io/loadBalancerIPs=$IngressIp" }
    # Kubelet retries the pull until the connected registry has the images, hence the long wait.
    # helm --wait also waits for the LoadBalancer Service to get its address.
    Invoke-Checked 'helm upgrade --install ingress-nginx' {
        helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx --version $ChartVersion `
            --namespace $IngressNamespace --create-namespace --kube-context $KubeContext `
            --values $values @siteValues --wait --timeout 20m
    }

    $assigned = Get-OmsIngressAddress $KubeContext $IngressNamespace
    if (-not $assigned) { throw 'The ingress controller got no address. Check that the cluster has a load balancer with free addresses.' }
    if ($IngressIp -and $assigned -ne $IngressIp) { throw "The ingress controller got address '$assigned', expected $IngressIp." }
    $IngressIp = $assigned

    # ------------------------------------------------------------------------------------------
    # 2. Site CA, and a cert-manager ClusterIssuer that signs with it. cert-manager (the Certificate
    #    Management extension) serves the whole cluster and keeps renewing while the site is cut
    #    off from Azure. A ClusterIssuer reads its CA from cert-manager's namespace.
    # ------------------------------------------------------------------------------------------
    Write-Host "==> ClusterIssuer '$IssuerName' (site CA)" -ForegroundColor Cyan
    if (-not (Test-OmsResource $KubeContext '' 'crd' 'clusterissuers.cert-manager.io')) {
        throw 'cert-manager is not installed. The cluster gets it, as the Certificate Management extension, from scripts/infra/azurelocal/provision-infra.ps1.'
    }
    # A CA Secret that cert-manager didn't issue is one you brought, and is used as it is.
    $issuedBy = Invoke-Checked "reading Secret '$CertManagerNamespace/$CaSecretName'" {
        kubectl get secret $CaSecretName --namespace $CertManagerNamespace --context $KubeContext --ignore-not-found `
            --output 'jsonpath={.metadata.annotations.cert-manager\.io/certificate-name}'
    }
    if ((Test-OmsResource $KubeContext $CertManagerNamespace 'secret' $CaSecretName) -and -not $issuedBy) {
        Write-Host "    using your CA in Secret '$CertManagerNamespace/$CaSecretName'" -ForegroundColor DarkGray
    }
    else {
        # Self-signed, for ten years. Renewal keeps the key, so what already trusts the CA still does.
        @"
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: $IssuerName-selfsigned
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: $CaSecretName
  namespace: $CertManagerNamespace
spec:
  isCA: true
  commonName: $CaCommonName
  secretName: $CaSecretName
  duration: 87600h
  privateKey:
    algorithm: RSA
    size: 3072
    rotationPolicy: Never
  issuerRef:
    kind: ClusterIssuer
    name: $IssuerName-selfsigned
"@ | kubectl apply --context $KubeContext -f - | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Requesting the site CA '$CertManagerNamespace/$CaSecretName' failed." }
        Wait-OmsCertificate $KubeContext $CertManagerNamespace $CaSecretName
    }
    @"
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: $IssuerName
spec:
  ca:
    secretName: $CaSecretName
"@ | kubectl apply --context $KubeContext -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Creating the ClusterIssuer '$IssuerName' failed." }
    Invoke-Checked "ClusterIssuer '$IssuerName'" {
        kubectl wait clusterissuer/$IssuerName --for=condition=Ready --timeout=120s --context $KubeContext | Out-Null
    }
    $caCertPem = Get-OmsSecretValue -KubeContext $KubeContext -Namespace $CertManagerNamespace -Name $CaSecretName -Key 'tls.crt'

    # ------------------------------------------------------------------------------------------
    # 3. The application's TLS certificate, renewed by cert-manager 30 days before it expires.
    #    The ingress controller picks up a renewed certificate without a restart.
    # ------------------------------------------------------------------------------------------
    Write-Host "==> TLS certificate for https://$IngressIp $(if ($HostNames) { "($($HostNames -join ', '))" })" -ForegroundColor Cyan
    Set-OmsNamespace $KubeContext $ApplicationNamespace
    $certificate = @{
        apiVersion = 'cert-manager.io/v1'
        kind       = 'Certificate'
        metadata   = @{ name = $TlsSecretName; namespace = $ApplicationNamespace }
        spec       = @{
            secretName  = $TlsSecretName
            ipAddresses = @($IngressIp)
            duration    = "$($CertificateDays * 24)h"
            renewBefore = '720h'
            privateKey  = @{ algorithm = 'RSA'; size = 2048; rotationPolicy = 'Always' }
            issuerRef   = @{ kind = 'ClusterIssuer'; name = $IssuerName }
        }
    }
    if ($HostNames) {
        $certificate.spec.commonName = $HostNames[0]
        $certificate.spec.dnsNames = @($HostNames)
    }
    $certificate | ConvertTo-Json -Depth 5 | kubectl apply --context $KubeContext -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Creating the Certificate '$ApplicationNamespace/$TlsSecretName' failed." }
    Wait-OmsCertificate $KubeContext $ApplicationNamespace $TlsSecretName

    # The site CA's certificate (public), for the app's pods and jobs to verify the servers it
    # signs, such as PostgreSQL.
    Set-OmsSecret -KubeContext $KubeContext -Namespace $ApplicationNamespace -Name $SiteCaSecretName -Data @{ 'ca.crt' = $caCertPem }

    $notAfter = Invoke-Checked "reading Certificate '$ApplicationNamespace/$TlsSecretName'" {
        kubectl get certificate $TlsSecretName --namespace $ApplicationNamespace --context $KubeContext --output 'jsonpath={.status.notAfter}'
    }
    Write-Host "    valid until $notAfter; renewed automatically" -ForegroundColor DarkGray

    $caFile = Join-Path $repoRoot 'bcd-site-ca.crt'
    [IO.File]::WriteAllText($caFile, $caCertPem)
    Write-Host "`nIngress ready: https://$IngressIp  (class '$IngressClassName', TLS secret '$ApplicationNamespace/$TlsSecretName', issuer '$IssuerName')" -ForegroundColor Green
    Write-Host "Trust the site CA on a machine outside the domain (once; it shows a confirmation prompt):"
    Write-Host "  Import-Certificate -FilePath $caFile -CertStoreLocation Cert:\CurrentUser\Root"
    Write-Host "Opening the .crt and leaving the store on 'automatic' files it under Intermediate CAs, which browsers do not trust." -ForegroundColor DarkGray
}
finally {
    Pop-Location
}