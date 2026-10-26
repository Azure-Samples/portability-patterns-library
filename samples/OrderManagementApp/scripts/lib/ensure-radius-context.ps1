<#
.SYNOPSIS
    Ensures a Kubernetes context the Radius CLI can use, backed by a short-lived ServiceAccount token.

.DESCRIPTION
    The Radius CLI reaches the control plane through the Kubernetes *aggregated API*
    (api.ucp.dev). When the API server proxies such a request it forwards the caller's identity as
    headers, including one X-Remote-Group header per group.

    An Entra ID user in many groups triggers a "groups overage" claim, AKS expands the full group
    list, and the resulting headers exceed the server limit:

        HTTP Error 431 - Request Header Field(s) Too Large

    kubectl is unaffected because it talks to the API server directly, with no aggregation proxy.

    The fix is to give the CLI an identity carrying no Entra groups: a Kubernetes ServiceAccount.
    Its token is short-lived, revocable by deleting the ServiceAccount, and never leaves the
    cluster's own auth system -- unlike the cluster-admin certificate that disabling local accounts
    removes.

    This script is idempotent. It creates the ServiceAccount and binding if absent, always mints a
    fresh token, and writes the context into kubeconfig. Both provision-infra.ps1 and deploy.ps1
    call it, so a deployment never depends on a token minted hours earlier.

.OUTPUTS
    The name of the kubeconfig context to use for Radius CLI commands.

.EXAMPLE
    $context = ./scripts/lib/ensure-radius-context.ps1 -ClusterName bcd-aks
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ClusterName,

    # Context used to create the ServiceAccount and mint the token. Defaults to the cluster's own
    # context, which normally authenticates as the signed-in Entra user.
    [string]$AdminContext,

    [string]$ServiceAccountName = 'radius-admin',
    [string]$Namespace = 'radius-system',
    [int]$TokenHours = 24,
    [string]$ContextName
)

$ErrorActionPreference = 'Stop'

if (-not $AdminContext) { $AdminContext = $ClusterName }
if (-not $ContextName) { $ContextName = "$ClusterName-radius" }

Write-Host "==> Ensuring Radius CLI context '$ContextName'" -ForegroundColor Cyan

# Creating through kubectl (rather than the ARM template) because these are Kubernetes objects.
kubectl create serviceaccount $ServiceAccountName --namespace $Namespace --context $AdminContext --dry-run=client -o yaml |
    kubectl apply --context $AdminContext -f - | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Could not create ServiceAccount '$ServiceAccountName' in namespace '$Namespace'." }

kubectl create clusterrolebinding $ServiceAccountName `
    --clusterrole=cluster-admin `
    --serviceaccount="${Namespace}:${ServiceAccountName}" `
    --context $AdminContext --dry-run=client -o yaml |
    kubectl apply --context $AdminContext -f - | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Could not bind ServiceAccount '$ServiceAccountName' to cluster-admin." }

# Always mint a fresh token: the previous one may be minutes from expiry, or already expired.
$token = kubectl create token $ServiceAccountName --namespace $Namespace --context $AdminContext --duration "${TokenHours}h"
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
    throw "Could not mint a token for ServiceAccount '$ServiceAccountName'."
}

kubectl config set-credentials $ContextName --token=$token | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Could not write credentials for context '$ContextName'." }

kubectl config set-context $ContextName --cluster=$ClusterName --user=$ContextName | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Could not create kubeconfig context '$ContextName'." }

Write-Host "    Token valid for $TokenHours hours" -ForegroundColor DarkGray

# The only value written to the pipeline, so callers can capture it.
Write-Output $ContextName
