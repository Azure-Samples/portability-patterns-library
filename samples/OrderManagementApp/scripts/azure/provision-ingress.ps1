<#
.SYNOPSIS
    Gives applications on AKS a public HTTPS address: the managed NGINX ingress (app routing add-on,
    enabled by deploy/infra/platform.bicep) with an Azure DNS name and a Let's Encrypt certificate.

.DESCRIPTION
    Platform layer, the Azure counterpart of scripts/azurelocal/provision-ingress.ps1. Applications
    only declare ports; the Recipe Pack tells the containers Recipe to publish them through this
    ingress (see recipe-packs/azure.bicep at the repository root), so deploy/app.bicep is the same as on Azure Local.

      1. Gives the managed ingress's public IP the DNS name <DnsLabel>.<region>.cloudapp.azure.com.
      2. Installs cert-manager and a ClusterIssuer: Let's Encrypt with HTTP-01 challenges answered
         through the same ingress, or with -PrivateCa a CA kept in the cluster. Use -PrivateCa where
         policy blocks inbound internet traffic (Let's Encrypt cannot reach the challenge); trust the
         CA printed at the end on the machines that open the app.

    Idempotent. Run after scripts/azure/provision-infra.ps1.

.EXAMPLE
    ./scripts/azure/provision-ingress.ps1 -DnsLabel bcd-orders-demo

.EXAMPLE
    ./scripts/azure/provision-ingress.ps1 -DnsLabel bcd-orders-demo -PrivateCa
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z][a-z0-9-]{1,61}[a-z0-9]$')]
    [string]$DnsLabel,

    [string]$KubeContext = 'bcd-aks-demo',
    [string]$IngressClassName = 'webapprouting.kubernetes.azure.com',
    [string]$CertManagerVersion = 'v1.21.2',
    [string]$IssuerName = 'letsencrypt',
    [string]$AcmeServer = 'https://acme-v02.api.letsencrypt.org/directory',
    [switch]$PrivateCa,
    [string]$PrivateIssuerName = 'bcd-private-ca',
    [string]$PrivateCaCommonName = 'BCD Azure Demo CA'
)

$ErrorActionPreference = 'Stop'

function Invoke-Checked([string]$What, [scriptblock]$Command) {
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "$What failed with exit code $LASTEXITCODE." }
}

Write-Host "==> Public DNS name '$DnsLabel' for the managed ingress" -ForegroundColor Cyan
# The add-on owns its controller through this resource; annotations here reach its Service.
@"
apiVersion: approuting.kubernetes.azure.com/v1alpha1
kind: NginxIngressController
metadata:
  name: default
spec:
  ingressClassName: $IngressClassName
  controllerNamePrefix: nginx
  loadBalancerAnnotations:
    service.beta.kubernetes.io/azure-dns-label-name: $DnsLabel
"@ | kubectl apply --context $KubeContext -f - | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Configuring the managed ingress controller failed.' }

$deadline = (Get-Date).AddMinutes(10)
do {
    Start-Sleep -Seconds 10
    $ip = kubectl get service nginx -n app-routing-system --context $KubeContext -o 'jsonpath={.status.loadBalancer.ingress[0].ip}' 2>$null
} while (-not $ip -and (Get-Date) -lt $deadline)
if (-not $ip) { throw 'The managed ingress has no public IP yet.' }

$location = (kubectl get nodes --context $KubeContext -o 'jsonpath={.items[0].metadata.labels.topology\.kubernetes\.io/region}')
$fqdn = "$DnsLabel.$location.cloudapp.azure.com"
Write-Host "    $fqdn -> $ip" -ForegroundColor DarkGray

Write-Host "==> cert-manager $CertManagerVersion" -ForegroundColor Cyan
# AKS's admissions enforcer edits the webhook after install, so re-applying the same release
# conflicts; an installed release at this version is left alone.
$installed = helm list -n cert-manager --kube-context $KubeContext --filter '^cert-manager$' -o json 2>$null | ConvertFrom-Json
if ($installed -and $installed[0].chart -eq "cert-manager-$CertManagerVersion" -and $installed[0].status -eq 'deployed') {
    Write-Host '    already installed' -ForegroundColor DarkGray
}
else {
    Invoke-Checked 'helm repo add jetstack' { helm repo add jetstack https://charts.jetstack.io --force-update | Out-Null }
    # --force-conflicts: AKS's admissions enforcer co-owns the webhook's namespaceSelector.
    Invoke-Checked 'helm upgrade --install cert-manager' {
        helm upgrade --install cert-manager jetstack/cert-manager --version $CertManagerVersion `
            --namespace cert-manager --create-namespace --kube-context $KubeContext `
            --set crds.enabled=true --force-conflicts --wait --timeout 10m
    }
}

Write-Host "==> ClusterIssuer '$IssuerName' (Let's Encrypt, HTTP-01 via $IngressClassName)" -ForegroundColor Cyan
@"
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: $IssuerName
spec:
  acme:
    server: $AcmeServer
    privateKeySecretRef:
      name: $IssuerName-account
    solvers:
      - http01:
          ingress:
            ingressClassName: $IngressClassName
"@ | kubectl apply --context $KubeContext -f - | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Creating the ClusterIssuer failed.' }

if ($PrivateCa) {
    Write-Host "==> ClusterIssuer '$PrivateIssuerName' (CA '$PrivateCaCommonName' kept in the cluster)" -ForegroundColor Cyan
    @"
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: $PrivateIssuerName-bootstrap
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: $PrivateIssuerName
  namespace: cert-manager
spec:
  isCA: true
  commonName: $PrivateCaCommonName
  secretName: $PrivateIssuerName
  duration: 87600h
  privateKey:
    algorithm: RSA
    size: 3072
  issuerRef:
    name: $PrivateIssuerName-bootstrap
    kind: ClusterIssuer
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: $PrivateIssuerName
spec:
  ca:
    secretName: $PrivateIssuerName
"@ | kubectl apply --context $KubeContext -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Creating the private CA failed.' }
    Invoke-Checked 'wait for the private CA' {
        kubectl wait certificate/$PrivateIssuerName -n cert-manager --for=condition=Ready --timeout=120s --context $KubeContext | Out-Null
    }
    $caPem = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(
            (kubectl get secret $PrivateIssuerName -n cert-manager --context $KubeContext -o 'jsonpath={.data.ca\.crt}')))
    $caFile = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'bcd-azure-ca.crt'
    [IO.File]::WriteAllText($caFile, $caPem)
    $IssuerName = $PrivateIssuerName
}

Write-Host "`nIngress ready: https://$fqdn  (class '$IngressClassName', issuer '$IssuerName')" -ForegroundColor Green
if ($PrivateCa) {
    Write-Host "Deploy with: ./scripts/azure/deploy.ps1 ... -IngressCertIssuer $IssuerName"
    Write-Host "Trust the CA on client machines (once, shows a confirmation prompt):"
    Write-Host "  Import-Certificate -FilePath $caFile -CertStoreLocation Cert:\CurrentUser\Root"
}
