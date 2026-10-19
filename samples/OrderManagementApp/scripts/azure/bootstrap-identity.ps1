<#
.SYNOPSIS
    Creates the Microsoft Entra Workload Identity used by the Order Management sample on AKS.

.DESCRIPTION
    USE THIS ONLY WITH A PRE-EXISTING CLUSTER. If you are provisioning from scratch, run
    ./scripts/azure/provision-infra.ps1 instead -- it creates the cluster, registry, managed
    identity and federated credential declaratively through Bicep, and this script is unnecessary.

    This is the bring-your-own-cluster path that establishes passwordless access from an existing
    AKS cluster to Azure. It creates:

      1. A user-assigned managed identity (UAMI).
      2. A federated identity credential (FIC) on that UAMI which trusts the AKS cluster's OIDC
         issuer for one specific Kubernetes service account. This is what removes the need for any
         client secret: the kubelet projects a service account token into the pod, and Entra ID
         exchanges it for an access token because the FIC says that subject is trusted.
      3. The Kubernetes service account itself, annotated with the UAMI client ID so the Azure
         Workload Identity webhook injects AZURE_CLIENT_ID, AZURE_TENANT_ID and
         AZURE_FEDERATED_TOKEN_FILE into every pod that uses it.

    The role assignments granting this identity access to Service Bus, Blob Storage and Azure SQL
    are made by the Recipes, which receive the identity IDs printed at the end of this script.

.PARAMETER ClusterName
    Name of the AKS cluster. It must already have OIDC issuer and workload identity enabled:
      az aks update -g <rg> -n <cluster> --enable-oidc-issuer --enable-workload-identity

.EXAMPLE
    ./scripts/azure/bootstrap-identity.ps1 -ResourceGroup bcd-rg -ClusterName bcd-aks
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $true)]
    [string]$ClusterName,

    [string]$IdentityName = 'bcd-workload-identity',

    [string]$Namespace = 'oms-azure',

    [string]$ServiceAccountName = 'oms-workload-identity',

    [string]$Location = 'eastus'
)

$ErrorActionPreference = 'Stop'

Write-Host "==> Ensuring resource group '$ResourceGroup'" -ForegroundColor Cyan
az group create --name $ResourceGroup --location $Location --output none

Write-Host "==> Creating user-assigned managed identity '$IdentityName'" -ForegroundColor Cyan
az identity create --name $IdentityName --resource-group $ResourceGroup --location $Location --output none

$clientId = az identity show --name $IdentityName --resource-group $ResourceGroup --query clientId --output tsv
$principalId = az identity show --name $IdentityName --resource-group $ResourceGroup --query principalId --output tsv
$tenantId = az account show --query tenantId --output tsv
$subscriptionId = az account show --query id --output tsv

Write-Host "==> Reading the cluster OIDC issuer URL" -ForegroundColor Cyan
$issuer = az aks show --name $ClusterName --resource-group $ResourceGroup --query oidcIssuerProfile.issuerUrl --output tsv
if ([string]::IsNullOrWhiteSpace($issuer)) {
    throw "Cluster '$ClusterName' has no OIDC issuer. Run: az aks update -g $ResourceGroup -n $ClusterName --enable-oidc-issuer --enable-workload-identity"
}
Write-Host "    $issuer" -ForegroundColor DarkGray

# The subject must match exactly how Kubernetes names the service account token subject.
$subject = "system:serviceaccount:${Namespace}:${ServiceAccountName}"

Write-Host "==> Creating federated identity credential for $subject" -ForegroundColor Cyan
az identity federated-credential create `
    --name "$IdentityName-fic" `
    --identity-name $IdentityName `
    --resource-group $ResourceGroup `
    --issuer $issuer `
    --subject $subject `
    --audience api://AzureADTokenExchange `
    --output none

Write-Host "==> Creating the annotated Kubernetes service account" -ForegroundColor Cyan
kubectl create namespace $Namespace --dry-run=client -o yaml | kubectl apply -f -

$serviceAccountManifest = @"
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $ServiceAccountName
  namespace: $Namespace
  annotations:
    azure.workload.identity/client-id: $clientId
    azure.workload.identity/tenant-id: $tenantId
  labels:
    azure.workload.identity/use: "true"
"@

$serviceAccountManifest | kubectl apply -f -

Write-Host "`n================ Workload Identity ready ================" -ForegroundColor Green
Write-Host "Client ID      : $clientId"
Write-Host "Principal ID   : $principalId"
Write-Host "Identity name  : $IdentityName"
Write-Host "Tenant ID      : $tenantId"
Write-Host "Subscription   : $subscriptionId"
Write-Host "Namespace      : $Namespace"
Write-Host "ServiceAccount : $ServiceAccountName"
Write-Host ""
Write-Host "Pass these to the Azure Recipe Pack:" -ForegroundColor Yellow
Write-Host "  rad deploy ../../recipe-packs/azure.bicep \"
Write-Host "    --parameters registry=<your-registry> \"
Write-Host "    --parameters serviceAccountName=$ServiceAccountName \"
Write-Host "    --parameters workloadIdentityPrincipalId=$principalId \"
Write-Host "    --parameters workloadIdentityName=$IdentityName"
