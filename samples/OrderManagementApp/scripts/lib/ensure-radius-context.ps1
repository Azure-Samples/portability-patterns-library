#Requires -Version 7.3
<#
.SYNOPSIS
    Ensures a Kubernetes context the Radius CLI can use on AKS with Entra ID sign-in: it signs in as a
    ServiceAccount, with short-lived tokens kubectl mints when the CLI needs one.

.DESCRIPTION
    The Radius CLI reaches the control plane through the Kubernetes *aggregated API*
    (api.ucp.dev). When the API server proxies such a request it forwards the caller's identity as
    headers, including one X-Remote-Group header per group.

    An Entra ID user in many groups triggers a "groups overage" claim, AKS expands the full group
    list, and the resulting headers exceed the server limit:

        HTTP Error 431 - Request Header Field(s) Too Large

    kubectl is unaffected because it talks to the API server directly, with no aggregation proxy.

    So the CLI signs in as a Kubernetes ServiceAccount, which carries no Entra groups. The context's
    credential is an exec plugin: whenever the CLI needs a token, kubectl, signed in as you through
    -KubeContext, mints one for the ServiceAccount, valid for -TokenDuration. No token is written to
    kubeconfig or passed on a command line.

    The ServiceAccount may only do what deploying with rad needs:
      * everything in the Radius API (api.ucp.dev), which the CLI reaches through the aggregated API;
      * read Secrets in -Namespace, where Helm keeps its release records: 'rad workspace create'
        reads them to find the control plane.
    Installing Radius needs cluster-admin, so provision-infra.ps1 grants it only while
    'rad install' runs.

    Idempotent. provision-infra.ps1 and deploy/azure.ps1 call it.

.OUTPUTS
    The name of the kubeconfig context to use for Radius CLI commands.

.EXAMPLE
    $context = ./scripts/lib/ensure-radius-context.ps1 -KubeContext bcd-aks
#>
[CmdletBinding()]
param(
    # The cluster's own context, signed in as an Entra user who may create the ServiceAccount, its
    # roles and its tokens.
    [Parameter(Mandatory = $true)][string]$KubeContext,

    [string]$ServiceAccountName = 'radius-cli',
    [string]$Namespace = 'radius-system',
    [string]$TokenDuration = '1h',
    # Empty: '<KubeContext>-radius'.
    [string]$ContextName
)

$ErrorActionPreference = 'Stop'

if (-not $ContextName) { $ContextName = "$KubeContext-radius" }

Write-Host "==> Ensuring Radius CLI context '$ContextName'" -ForegroundColor Cyan

@"
apiVersion: v1
kind: Namespace
metadata:
  name: $Namespace
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $ServiceAccountName
  namespace: $Namespace
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: $ServiceAccountName
rules:
  - apiGroups: [api.ucp.dev]
    resources: ["*"]
    verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: $ServiceAccountName
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: $ServiceAccountName
subjects:
  - kind: ServiceAccount
    name: $ServiceAccountName
    namespace: $Namespace
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: $ServiceAccountName-helm-releases
  namespace: $Namespace
rules:
  - apiGroups: [""]
    resources: [secrets]
    verbs: [get, list]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: $ServiceAccountName-helm-releases
  namespace: $Namespace
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: $ServiceAccountName-helm-releases
subjects:
  - kind: ServiceAccount
    name: $ServiceAccountName
    namespace: $Namespace
"@ | kubectl apply --context $KubeContext -f - | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Could not create ServiceAccount '$ServiceAccountName' and its roles in '$Namespace'." }

$cluster = kubectl config view --output "jsonpath={.contexts[?(@.name=='$KubeContext')].context.cluster}"
if ($LASTEXITCODE -ne 0 -or -not $cluster) { throw "kubeconfig has no context '$KubeContext'." }

# kubectl prints the TokenRequest as the ExecCredential the client expects.
$execCredential = '{"apiVersion":"client.authentication.k8s.io/v1","kind":"ExecCredential","status":{"token":"{{.status.token}}","expirationTimestamp":"{{.status.expirationTimestamp}}"}}'
$execArguments = @(
    'create', 'token', $ServiceAccountName, "--namespace=$Namespace", "--context=$KubeContext",
    "--duration=$TokenDuration", '--output=go-template', "--template=$execCredential"
) | ForEach-Object {
    # kubectl reads each --exec-arg as comma-separated values, so each is quoted as one CSV field.
    '--exec-arg="{0}"' -f $_.Replace('"', '""')
}
# set-credentials merges into an existing entry, and a static token there would win over the exec
# plugin, so the entry is written from scratch.
kubectl config delete-user $ContextName 2>$null | Out-Null
kubectl config set-credentials $ContextName --exec-api-version=client.authentication.k8s.io/v1 `
    --exec-command=kubectl @execArguments --exec-interactive-mode=Never | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Could not write the credential of context '$ContextName'." }

kubectl config set-context $ContextName --cluster=$cluster --user=$ContextName | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Could not create kubeconfig context '$ContextName'." }

# The only value written to the pipeline, so callers can capture it.
Write-Output $ContextName
