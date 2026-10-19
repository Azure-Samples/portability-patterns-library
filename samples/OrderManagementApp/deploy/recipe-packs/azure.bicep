// Recipe Pack for Azure environments (AKS + Azure PaaS).
//
// The same three Resource Types the local pack binds to containers are bound here to Azure Service
// Bus, Azure Storage, and Azure SQL Database. The identity parameters come from
// scripts/azure/provision-infra.ps1, which creates the user-assigned managed identity and the
// federated identity credential that trusts the cluster's OIDC issuer for one service account.

extension radius

@description('OCI registry holding the published Recipe modules, for example myregistry.azurecr.io.')
param registry string

@description('Tag applied to the published Recipe modules.')
param tag string = 'latest'

@description('Principal (object) ID of that managed identity, used for role assignments.')
param workloadIdentityPrincipalId string

@description('Resource name of that managed identity, used as the Azure SQL Entra administrator login.')
param workloadIdentityName string

@description('Kubernetes service account annotated for that identity. Its name must match the federated credential subject.')
param serviceAccountName string = 'oms-workload-identity'

@description('Azure region for provisioned infrastructure.')
param location string = 'eastus2'

@description('''
Azure region for the SQL logical server. Defaults to `location`. Override when the primary region
will not accept new SQL servers -- Azure gates this per subscription and region, failing with
`RegionDoesNotAllowProvisioning`. Azure SQL is reached over its public FQDN, so the database can sit
in a different region from the cluster at the cost of some latency and cross-region egress.
''')
param sqlLocation string = location

@description('Registry holding the stock Radius Kubernetes Recipes that this pack does not override.')
param radiusRecipeRegistry string = 'ghcr.io/radius-project/kube-recipes'

@description('Ingress class that publishes containers with ports, from scripts/azure/provision-ingress.ps1. Empty keeps them cluster-internal.')
param ingressClassName string = ''

@description('Public host name the ingress answers on, for example <label>.<region>.cloudapp.azure.com.')
param ingressHost string = ''

@description('cert-manager ClusterIssuer that obtains the certificate for ingressHost.')
param ingressCertIssuer string = ''

// Every container runs as the annotated service account with the Workload Identity label, so the
// webhook gives it AZURE_CLIENT_ID and a federated token. The application declares none of this.
var containerIdentityParameters = {
  serviceAccountName: serviceAccountName
  azureWorkloadIdentity: true
}

var containerIngressParameters = empty(ingressClassName) ? {} : {
  ingressClassName: ingressClassName
  ingressHost: ingressHost
  ingressTlsSecretName: 'oms-app-tls'
  ingressAnnotations: empty(ingressCertIssuer) ? {} : {
    'cert-manager.io/cluster-issuer': ingressCertIssuer
  }
}

resource azureRecipes 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'oms-azure-recipes'
  properties: {
    recipes: {
      // Local build of the stock Kubernetes container Recipe that adds identity, registry and
      // ingress settings chosen by the platform (see deploy/recipes/kubernetes/containers.bicep).
      'Radius.Compute/containers': {
        kind: 'bicep'
        source: '${registry}/oms/recipes/containers:${tag}'
        parameters: union(containerIdentityParameters, containerIngressParameters)
      }
      'Radius.Security/secrets': {
        kind: 'bicep'
        source: '${radiusRecipeRegistry}/secrets:latest'
      }
      'OrderManagement.Messaging/messageQueues': {
        kind: 'bicep'
        source: '${registry}/oms/recipes/servicebus-queue:${tag}'
        parameters: {
          location: location
          workloadIdentityPrincipalId: workloadIdentityPrincipalId
          sku: 'Standard'
        }
      }
      'Radius.Storage/objectStorage': {
        kind: 'bicep'
        source: '${registry}/oms/recipes/blob-objectstorage:${tag}'
        parameters: {
          location: location
          workloadIdentityPrincipalId: workloadIdentityPrincipalId
          sku: 'Standard_LRS'
        }
      }
      'Radius.Data/sqlServerDatabases': {
        kind: 'bicep'
        source: '${registry}/oms/recipes/azuresql-database:${tag}'
        parameters: {
          location: sqlLocation
          workloadIdentityPrincipalId: workloadIdentityPrincipalId
          workloadIdentityName: workloadIdentityName
          skuName: 'S0'
        }
      }
    }
  }
}

output recipePackId string = azureRecipes.id
