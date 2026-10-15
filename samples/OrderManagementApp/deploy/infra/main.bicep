// Layer 0 -- platform infrastructure for the Business Continuity Demo App on Azure.
//
// Creates everything the application deployment assumes already exists:
//
//   * Azure Container Registry, holding both the worker images and the Bicep Recipes.
//   * AKS cluster with the OIDC issuer and workload identity both enabled.
//   * AcrPull for the cluster's kubelet identity, the declarative equivalent of
//     `az aks update --attach-acr`, so the kubelet can pull the worker images.
//   * A user-assigned managed identity plus a federated identity credential (FIC) trusting the
//     cluster's OIDC issuer for one specific Kubernetes service account. This is what lets the
//     workers reach Service Bus, Blob Storage and Azure SQL without any secret.
//
// This is deliberately separate from the application deployment: it changes rarely, and it needs
// far higher privileges (role assignments require Owner or User Access Administrator).
//
// Deployed at subscription scope so it can create its own resource group:
//   az deployment sub create --location <region> --template-file deploy/infra/main.bicep
//
// scripts/azure/provision-infra.ps1 wraps this and performs the imperative follow-up steps.

targetScope = 'subscription'

@description('Azure region for the resource group and all resources in it.')
param location string

@description('Resource group that the platform infrastructure is created in.')
param resourceGroupName string = 'bcd-infra'

@description('Name of the AKS cluster. Also used as the DNS prefix.')
param clusterName string = 'bcd-aks'

@description('Globally unique Azure Container Registry name. Lowercase alphanumeric, 5-50 characters.')
@minLength(5)
@maxLength(50)
param registryName string

@description('Name of the user-assigned managed identity the workers federate with.')
param identityName string = 'bcd-workload-identity'

@description('''
Name of the user-assigned managed identity the Radius control plane federates with. This is a
different identity from the one the workers use: it lets Radius provision Azure resources without a
client secret, replacing `rad credential register azure sp`.
''')
param radiusIdentityName string = 'bcd-radius-identity'

@description('Kubernetes namespace the application is deployed into. Must match the Radius Environment namespace.')
param appNamespace string = 'bcd-azure'

@description('Kubernetes service account the workers run as. Must match what the Radius Environment injects.')
param serviceAccountName string = 'bcd-workload-identity'

@description('Number of nodes in the system pool.')
@minValue(1)
param nodeCount int = 2

@description('''
VM size for the system pool. Availability is both region-specific and subscription-specific: a
policy-constrained subscription may permit only a subset of sizes, and that subset differs per
region. If preflight fails with "The VM size ... is not allowed in your subscription", the error
lists the sizes that are permitted in that region -- pick one of those, or try another region.
''')
param nodeVmSize string = 'Standard_D4s_v7'

@description('Kubernetes version. Leave empty to let AKS pick the default.')
param kubernetesVersion string = ''

@description('ACR SKU. Basic is enough for a demo; Premium adds private endpoints and geo-replication.')
@allowed([
  'Basic'
  'Standard'
  'Premium'
])
param registrySku string = 'Standard'

@description('''
Entra ID object IDs granted cluster administrator access. Required because local accounts are
disabled: without at least one entry nobody can reach the API server. `provision-infra.ps1` passes
the signed-in user by default.
''')
param clusterAdminObjectIds array = []

@description('''
Disable AKS local (certificate) accounts and authenticate to the API server with Entra ID plus
Azure RBAC. Recommended, and required by many organisations' policy. Turning this off falls back to
certificate-based cluster-admin credentials.
''')
param useEntraAuthentication bool = true

@description('Tags applied to every resource.')
param tags object = {
  application: 'business-continuity-demo'
  managedBy: 'radius'
}

resource platformResourceGroup 'Microsoft.Resources/resourceGroups@2022-09-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module platform 'platform.bicep' = {
  scope: platformResourceGroup
  name: 'bcd-platform'
  params: {
    location: location
    clusterName: clusterName
    registryName: registryName
    identityName: identityName
    radiusIdentityName: radiusIdentityName
    appNamespace: appNamespace
    serviceAccountName: serviceAccountName
    nodeCount: nodeCount
    nodeVmSize: nodeVmSize
    kubernetesVersion: kubernetesVersion
    registrySku: registrySku
    clusterAdminObjectIds: clusterAdminObjectIds
    useEntraAuthentication: useEntraAuthentication
    tags: tags
  }
}

@description('Resource group holding the platform infrastructure.')
output resourceGroupName string = platformResourceGroup.name

@description('Login server of the container registry, for example bcdacr.azurecr.io.')
output registryLoginServer string = platform.outputs.registryLoginServer

output registryName string = platform.outputs.registryName
output clusterName string = platform.outputs.clusterName

@description('OIDC issuer URL of the cluster, which the federated identity credential trusts.')
output oidcIssuerUrl string = platform.outputs.oidcIssuerUrl

@description('Client ID of the workload identity. Pass to the Azure Recipe Pack.')
output workloadIdentityClientId string = platform.outputs.workloadIdentityClientId

@description('Principal (object) ID of the workload identity. Pass to the Azure Recipe Pack.')
output workloadIdentityPrincipalId string = platform.outputs.workloadIdentityPrincipalId

@description('Name of the workload identity, used as the Azure SQL Entra administrator login.')
output workloadIdentityName string = platform.outputs.workloadIdentityName

@description('Client ID of the Radius control-plane identity. Pass to `rad credential register azure wi`.')
output radiusIdentityClientId string = platform.outputs.radiusIdentityClientId

@description('Principal (object) ID of the Radius control-plane identity.')
output radiusIdentityPrincipalId string = platform.outputs.radiusIdentityPrincipalId

output appNamespace string = appNamespace
output serviceAccountName string = serviceAccountName
