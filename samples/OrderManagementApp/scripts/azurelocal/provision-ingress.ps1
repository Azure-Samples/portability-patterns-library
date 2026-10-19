<#
.SYNOPSIS
    Gives applications on the Azure Local cluster an HTTPS address on the site network: an Arc
    load balancer, an NGINX ingress controller and a TLS certificate from a site CA.

.DESCRIPTION
    Platform layer, like provision-infra.ps1. Applications then only declare ports; the Recipe Pack
    tells the containers Recipe to publish them through this ingress (see
    recipe-packs/azure-local.bicep at the repository root), so deploy/app.bicep is the same as in Azure.

      1. Registers Microsoft.KubernetesRuntime and enables the AKS Arc load balancer (MetalLB,
         ARP mode) with the address range -Addresses, outside the AKS logical network pool.
      2. Syncs the ingress-nginx images into the connected registry and installs the controller
         from there, on the fixed address -IngressIp, so it keeps serving if Azure is unreachable.
      3. Issues a TLS certificate for -IngressIp and -HostNames from a site CA kept in the
         cluster, into Secret -TlsSecretName in the application namespace. Browsers need HTTPS:
         MSAL.js only runs in a secure context.

    The site CA stands in for the organisation's PKI (AD CS on the domain controller in production,
    whose root domain-joined machines already trust). Machines outside the domain trust it once
    with the command printed at the end. Idempotent.

    Prerequisites: scripts/azurelocal/import-images.ps1 (ingress-nginx images in the cloud registry) and
    scripts/azurelocal/connected-registry.ps1.

.EXAMPLE
    ./scripts/azurelocal/provision-ingress.ps1
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup = 'bcd-azurelocal',
    # The Premium ACR the connected registry syncs from; usually set as Common.RegistryName in settings.json.
    [string]$RegistryName = '<acr-name>',
    [string]$ClusterName = 'bcd-aksarc',
    [string]$KubeContext = 'bcd-aksarc',
    [string]$LoadBalancerName = 'bcd-lb',
    [string]$Addresses = '192.168.44.200-192.168.44.210',
    [string]$IngressIp = '192.168.44.200',
    [string[]]$HostNames = @('orders.azurelocal.lab'),
    [string]$IngressNamespace = 'ingress-nginx',
    [string]$IngressClassName = 'nginx',
    [string]$ChartVersion = '4.15.1',
    [string]$ControllerTag = 'v1.15.1',
    [string]$WebhookCertgenTag = 'v1.6.9',
    [string]$PullRegistry = '10.96.0.50',
    [string]$PullSecretName = 'azurelocal-registry',
    [string]$ApplicationNamespace = 'oms-azurelocal',
    [string]$TlsSecretName = 'oms-app-tls',
    [string]$CaSecretName = 'bcd-site-ca',
    [string]$CaCommonName = 'BCD Azure Local Site CA',
    [string]$IdentityCaSecretName = 'oms-identity-ca',
    [int]$CertificateDays = 365
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Push-Location $repoRoot

function Invoke-Checked([string]$What, [scriptblock]$Command) {
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "$What failed with exit code $LASTEXITCODE." }
}

function Get-SecretData([string]$Namespace, [string]$Name, [string]$Key) {
    $escaped = $Key.Replace('.', '\.')
    $value = kubectl get secret $Name -n $Namespace --context $KubeContext --ignore-not-found -o "jsonpath={.data.$escaped}"
    if ($value) { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($value)) }
}

function Set-TlsSecret([string]$Namespace, [string]$Name, [string]$CertPem, [string]$KeyPem) {
    @"
apiVersion: v1
kind: Secret
type: kubernetes.io/tls
metadata:
  name: $Name
  namespace: $Namespace
data:
  tls.crt: $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($CertPem)))
  tls.key: $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($KeyPem)))
"@ | kubectl apply --context $KubeContext -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Writing Secret '$Namespace/$Name' failed." }
}

try {
    # ------------------------------------------------------------------------------------------
    # 1. Load balancer
    # ------------------------------------------------------------------------------------------
    Write-Host "==> Arc load balancer '$LoadBalancerName' ($Addresses, ARP)" -ForegroundColor Cyan
    $state = az provider show --namespace Microsoft.KubernetesRuntime --query registrationState -o tsv
    if ($state -ne 'Registered') {
        Invoke-Checked 'az provider register' { az provider register --namespace Microsoft.KubernetesRuntime --wait --only-show-errors }
    }
    $clusterId = az connectedk8s show -g $ResourceGroup -n $ClusterName --query id -o tsv
    if (-not $clusterId) { throw "Connected cluster '$ClusterName' not found in '$ResourceGroup'." }

    $existing = az k8s-runtime load-balancer list --resource-uri $clusterId --query "[?name=='$LoadBalancerName'].name" -o tsv 2>$null
    if (-not $existing) {
        Invoke-Checked 'az k8s-runtime load-balancer enable' {
            az k8s-runtime load-balancer enable --resource-uri $clusterId --only-show-errors -o none
        }
        Invoke-Checked 'az k8s-runtime load-balancer create' {
            az k8s-runtime load-balancer create --load-balancer-name $LoadBalancerName --resource-uri $clusterId `
                --addresses $Addresses --advertise-mode ARP --only-show-errors -o none
        }
    }

    # ------------------------------------------------------------------------------------------
    # 2. Ingress controller, pulled from the connected registry
    # ------------------------------------------------------------------------------------------
    Write-Host "==> Syncing ingress-nginx images to the connected registry" -ForegroundColor Cyan
    ./scripts/azurelocal/connected-registry.ps1 -KubeContext $KubeContext `
        -ResourceGroup $ResourceGroup -RegistryName $RegistryName `
        -Repositories @('ingress-nginx/controller', 'ingress-nginx/kube-webhook-certgen') |
        Where-Object { $_ -match '^==>' }

    Write-Host "==> Installing ingress-nginx $ChartVersion on $IngressIp" -ForegroundColor Cyan
    Invoke-Checked 'helm repo add' { helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update | Out-Null }
    $values = Join-Path ([IO.Path]::GetTempPath()) "ingress-nginx-$([guid]::NewGuid().ToString('N')).yaml"
    @"
imagePullSecrets:
  - name: $PullSecretName
controller:
  image:
    registry: $PullRegistry
    image: ingress-nginx/controller
    tag: $ControllerTag
    digest: ""
  ingressClassResource:
    name: $IngressClassName
    default: false
  # Browsers send no SNI for https://<ip>, so the catch-all server must present the site certificate.
  extraArgs:
    default-ssl-certificate: $ApplicationNamespace/$TlsSecretName
  service:
    type: LoadBalancer
    # MetalLB refuses a Service that also sets spec.loadBalancerIP, so the address goes here only.
    annotations:
      metallb.io/loadBalancerIPs: $IngressIp
  admissionWebhooks:
    patch:
      image:
        registry: $PullRegistry
        image: ingress-nginx/kube-webhook-certgen
        tag: $WebhookCertgenTag
        digest: ""
"@ | Set-Content -Path $values -Encoding utf8
    try {
        # Kubelet retries the pull until the connected registry has the images, hence the long wait.
        Invoke-Checked 'helm upgrade --install ingress-nginx' {
            helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx --version $ChartVersion `
                --namespace $IngressNamespace --create-namespace --kube-context $KubeContext `
                --values $values --wait --timeout 20m
        }
    }
    finally { Remove-Item $values -ErrorAction SilentlyContinue }

    $assigned = kubectl get service ingress-nginx-controller -n $IngressNamespace --context $KubeContext `
        -o 'jsonpath={.status.loadBalancer.ingress[0].ip}'
    if ($assigned -ne $IngressIp) { throw "The ingress controller got address '$assigned', expected $IngressIp." }

    # ------------------------------------------------------------------------------------------
    # 3. Site CA and the application's TLS certificate
    # ------------------------------------------------------------------------------------------
    Write-Host "==> TLS certificate for https://$IngressIp ($($HostNames -join ', '))" -ForegroundColor Cyan
    $caCertPem = Get-SecretData $IngressNamespace $CaSecretName 'tls.crt'
    $caKeyPem = Get-SecretData $IngressNamespace $CaSecretName 'tls.key'
    if ($caCertPem -and $caKeyPem) {
        $ca = [Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem($caCertPem, $caKeyPem)
    }
    else {
        $caKey = [Security.Cryptography.RSA]::Create(3072)
        $caRequest = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
            "CN=$CaCommonName", $caKey, [Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $caRequest.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true, $true, 0, $true))
        $caRequest.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
                [Security.Cryptography.X509Certificates.X509KeyUsageFlags]'KeyCertSign, CrlSign', $true))
        $caRequest.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509SubjectKeyIdentifierExtension]::new($caRequest.PublicKey, $false))
        $ca = $caRequest.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddYears(10))
        $caCertPem = $ca.ExportCertificatePem()
        Set-TlsSecret $IngressNamespace $CaSecretName $caCertPem $caKey.ExportPkcs8PrivateKeyPem()
        Write-Host "    created site CA '$CaCommonName'" -ForegroundColor DarkGray
    }

    $currentPem = Get-SecretData $ApplicationNamespace $TlsSecretName 'tls.crt'
    $current = if ($currentPem) { [Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem($currentPem) }
    $sanText = if ($current) { ($current.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' } | ForEach-Object { $_.Format($false) }) -join ' ' }
    $needsIssue = -not $current -or $current.NotAfter -lt (Get-Date).AddDays(30) -or $current.Issuer -ne $ca.Subject -or
        -not ($sanText -match [regex]::Escape($IngressIp)) -or @($HostNames | Where-Object { $sanText -notmatch [regex]::Escape($_) }).Count -gt 0

    if ($needsIssue) {
        $key = [Security.Cryptography.RSA]::Create(2048)
        $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
            "CN=$($HostNames[0])", $key, [Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $san = [Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
        $san.AddIpAddress([Net.IPAddress]::Parse($IngressIp))
        foreach ($name in $HostNames) { $san.AddDnsName($name) }
        $request.CertificateExtensions.Add($san.Build())
        $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false, $false, 0, $false))
        $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
                [Security.Cryptography.X509Certificates.X509KeyUsageFlags]'DigitalSignature, KeyEncipherment', $true))
        $eku = [Security.Cryptography.OidCollection]::new()
        $eku.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1')) | Out-Null
        $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($eku, $false))
        $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509AuthorityKeyIdentifierExtension]::CreateFromCertificate($ca, $true, $false))

        $serial = [byte[]]::new(16)
        [Security.Cryptography.RandomNumberGenerator]::Fill($serial)
        $serial[0] = $serial[0] -band 0x7F
        $leaf = $request.Create($ca, [DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays($CertificateDays), $serial)

        kubectl create namespace $ApplicationNamespace --context $KubeContext --dry-run=client -o yaml |
            kubectl apply --context $KubeContext -f - | Out-Null
        Set-TlsSecret $ApplicationNamespace $TlsSecretName ($leaf.ExportCertificatePem() + "`n" + $caCertPem) $key.ExportPkcs8PrivateKeyPem()
        Write-Host "    issued, valid until $($leaf.NotAfter.ToString('yyyy-MM-dd'))" -ForegroundColor DarkGray
    }
    else {
        Write-Host "    current certificate still valid until $($current.NotAfter.ToString('yyyy-MM-dd'))" -ForegroundColor DarkGray
    }

    $caFiles = @(Join-Path $repoRoot 'bcd-site-ca.crt')
    [IO.File]::WriteAllText($caFiles[0], $caCertPem)
    # Sign-in redirects the browser to Keycloak, whose certificate comes from the identity CA.
    $identityCaPem = Get-SecretData $ApplicationNamespace $IdentityCaSecretName 'ca.crt'
    if ($identityCaPem) {
        $caFiles += Join-Path $repoRoot 'oms-identity-ca.crt'
        [IO.File]::WriteAllText($caFiles[1], $identityCaPem)
    }

    Write-Host "`nIngress ready: https://$IngressIp  (class '$IngressClassName', TLS secret '$ApplicationNamespace/$TlsSecretName')" -ForegroundColor Green
    Write-Host "Trust the site CAs on a machine outside the domain (once, each shows a confirmation prompt):"
    foreach ($file in $caFiles) { Write-Host "  Import-Certificate -FilePath $file -CertStoreLocation Cert:\CurrentUser\Root" }
    Write-Host "Opening the .crt and leaving the store on 'automatic' files it under Intermediate CAs, which browsers do not trust." -ForegroundColor DarkGray
}
finally {
    Pop-Location
}
