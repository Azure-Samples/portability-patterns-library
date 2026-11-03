#Requires -Version 7.0
<#
.SYNOPSIS
    Installs the operators that run the Azure Local backing services: CloudNativePG (with its Barman
    Cloud backup plugin) for PostgreSQL, and the RabbitMQ Cluster and Messaging Topology Operators.

.DESCRIPTION
    Platform layer, like provision-ingress.ps1. On Azure the cloud runs the databases and the queue;
    on Azure Local these operators do the same job inside the cluster: replicas on separate nodes,
    failover, rolling upgrades and backups. The Recipes then only declare what they need (a
    CloudNativePG Cluster, a RabbitmqCluster with its queues), and the operators make it so.

    Everything is installed once per cluster, from the connected registry, so the operators keep
    running when the link to Azure is down:

      1. CloudNativePG, from its Helm chart, into cnpg-system. Values:
         infra/azurelocal/operators/cloudnative-pg/values.yaml.
      2. The Barman Cloud plugin, from its Helm chart, into cnpg-system. Values:
         infra/azurelocal/operators/plugin-barman-cloud/values.yaml.
      3. The cert-manager CSI driver, from its Helm chart, into cert-manager-csi-driver. It gives each
         RabbitMQ pod its own certificate from the site CA, for mutual TLS between the nodes.
         Values: infra/azurelocal/operators/cert-manager-csi-driver/values.yaml.
      4. The RabbitMQ Cluster Operator and then the Messaging Topology Operator, from the RabbitMQ
         team's release manifests, into rabbitmq-system: infra/azurelocal/operators/rabbitmq. The
         topology operator reaches the brokers over HTTPS, so it gets the site CA.

    The webhooks' certificates come from the cluster's cert-manager (the Certificate Management
    extension). This script sets only the registry address. Idempotent: re-run it to upgrade after
    changing a version here and in infra/azurelocal/images.txt.

    Prerequisites: scripts/infra/azurelocal/import-images.ps1 and connected-registry.ps1, which put
    the operators' images in the connected registry, and provision-ingress.ps1 (the site CA).

.EXAMPLE
    ./scripts/infra/azurelocal/provision-operators.ps1 -KubeContext bcd-aksarc
#>
[CmdletBinding()]
param(
    [string]$KubeContext = 'bcd-aksarc',
    # The connected registry's address. Empty reads it from the pull secret connected-registry.ps1 wrote.
    [string]$PullRegistry,
    [string]$PullSecretName = 'azurelocal-registry',
    [string]$ApplicationNamespace = 'oms-azurelocal',

    # Secret with the site CA, from provision-ingress.ps1.
    [string]$SiteCaSecretName = 'oms-site-ca',

    [string]$CloudNativePgChartVersion = '0.29.1',
    [string]$BarmanCloudChartVersion = '0.8.1',
    [string]$CsiDriverChartVersion = 'v0.16.1'
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
. (Join-Path $repoRoot 'scripts/lib/cluster.ps1')

# Names fixed by the files in infra/azurelocal/operators.
$CnpgNamespace = 'cnpg-system'
$RabbitMqNamespace = 'rabbitmq-system'
$CsiDriverNamespace = 'cert-manager-csi-driver'
$ChartRepository = 'https://cloudnative-pg.github.io/charts'
$operatorsDir = Join-Path $repoRoot 'infra/azurelocal/operators'

function Invoke-Checked([string]$What, [scriptblock]$Command) {
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "$What failed with exit code $LASTEXITCODE." }
}

# The release manifests name the public images; the site pulls the same images from its own registry.
# Server-side apply, because the operators' resource definitions are too large for the annotation a
# client-side apply records.
function Install-Kustomization([string]$Folder) {
    $rendered = kubectl kustomize (Join-Path $operatorsDir $Folder)
    if ($LASTEXITCODE -ne 0) { throw "Could not render infra/azurelocal/operators/$Folder." }
    $rendered = $rendered -replace 'image: ghcr\.io/', "image: $PullRegistry/"
    $rendered | kubectl apply --context $KubeContext --server-side --force-conflicts -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not apply infra/azurelocal/operators/$Folder." }
}

if (-not $PullRegistry) {
    $PullRegistry = Get-OmsPullRegistry $KubeContext $ApplicationNamespace $PullSecretName
    if (-not $PullRegistry) {
        throw "No pull secret '$PullSecretName' in '$ApplicationNamespace' to read the connected registry's address from. Run scripts/infra/azurelocal/connected-registry.ps1 first, or pass -PullRegistry."
    }
}
foreach ($namespace in $CnpgNamespace, $RabbitMqNamespace, $CsiDriverNamespace) {
    Copy-OmsPullSecret -KubeContext $KubeContext -Namespace $namespace -SourceNamespace $ApplicationNamespace -SecretName $PullSecretName
}
Copy-OmsSiteCa -KubeContext $KubeContext -Namespace $RabbitMqNamespace -SourceNamespace $ApplicationNamespace -SecretName $SiteCaSecretName
$common = @('--namespace', $CnpgNamespace, '--kube-context', $KubeContext, '--wait', '--timeout', '10m')

Write-Host "==> Installing CloudNativePG (chart $CloudNativePgChartVersion) from $PullRegistry" -ForegroundColor Cyan
Invoke-Checked 'helm upgrade --install cnpg' {
    helm upgrade --install cnpg cloudnative-pg --repo $ChartRepository --version $CloudNativePgChartVersion @common `
        --values (Join-Path $operatorsDir 'cloudnative-pg/values.yaml') `
        --set "image.repository=$PullRegistry/cloudnative-pg/cloudnative-pg"
}

Write-Host "==> Installing the Barman Cloud backup plugin (chart $BarmanCloudChartVersion)" -ForegroundColor Cyan
Invoke-Checked 'helm upgrade --install barman-cloud' {
    helm upgrade --install barman-cloud plugin-barman-cloud --repo $ChartRepository --version $BarmanCloudChartVersion @common `
        --values (Join-Path $operatorsDir 'plugin-barman-cloud/values.yaml') `
        --set "image.registry=$PullRegistry" --set "sidecarImage.registry=$PullRegistry"
}

Write-Host "==> Installing the cert-manager CSI driver (chart $CsiDriverChartVersion)" -ForegroundColor Cyan
Invoke-Checked 'helm upgrade --install cert-manager-csi-driver' {
    helm upgrade --install cert-manager-csi-driver cert-manager-csi-driver --repo https://charts.jetstack.io `
        --version $CsiDriverChartVersion --namespace $CsiDriverNamespace --kube-context $KubeContext --wait --timeout 10m `
        --values (Join-Path $operatorsDir 'cert-manager-csi-driver/values.yaml') --set "imageRegistry=$PullRegistry"
}

# The topology operator manages objects inside clusters the cluster operator runs, so it goes second.
foreach ($operator in @(
        @{ Folder = 'cluster-operator'; Deployment = 'rabbitmq-cluster-operator' },
        @{ Folder = 'messaging-topology-operator'; Deployment = 'messaging-topology-operator' })) {
    Write-Host "==> Installing the RabbitMQ $($operator.Folder)" -ForegroundColor Cyan
    Install-Kustomization "rabbitmq/$($operator.Folder)"
    Invoke-Checked "waiting for the RabbitMQ $($operator.Folder)" {
        kubectl rollout status deployment $operator.Deployment --namespace $RabbitMqNamespace --context $KubeContext --timeout=10m | Out-Null
    }
}

Write-Host "`nOperators ready: CloudNativePG and Barman Cloud in $CnpgNamespace, the CSI driver in $CsiDriverNamespace, RabbitMQ in $RabbitMqNamespace" -ForegroundColor Green
