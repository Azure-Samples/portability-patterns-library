// Recipe Pack for Azure: AKS with Azure PaaS services.
//
// The queue, object storage and SQL types that the Azure Local pack binds to containers are bound
// here to Azure Service Bus, Azure Blob Storage and Azure SQL Database. Every container runs with
// Entra Workload ID, so the platform needs a user-assigned managed identity with a federated
// credential that trusts the cluster's OIDC issuer for `serviceAccountName`.

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
param serviceAccountName string

@description('Azure region for provisioned infrastructure.')
param location string = 'eastus2'

@description('''
Azure region for the SQL logical server. Defaults to `location`. Override when the primary region
will not accept new SQL servers -- Azure gates this per subscription and region, failing with
`RegionDoesNotAllowProvisioning`. Azure SQL is reached over its public FQDN, so the database can sit
in a different region from the cluster at the cost of some latency and cross-region egress.
''')
param sqlLocation string = location

@description('Registry path holding the stock Radius Kubernetes Recipes, used for secrets.')
param radiusRecipeRegistry string = 'ghcr.io/radius-project/kube-recipes'

@description('Tag of the stock Radius Recipes.')
param radiusRecipeTag string = 'latest'

@description('Ingress class that publishes containers with ports. Empty keeps them cluster-internal.')
param ingressClassName string = ''

@description('Public host name the ingress answers on, for example <label>.<region>.cloudapp.azure.com.')
param ingressHost string = ''

@description('cert-manager ClusterIssuer that obtains the certificate for ingressHost.')
param ingressCertIssuer string = ''

@description('TLS Secret the ingress serves; cert-manager writes the certificate into it.')
param ingressTlsSecretName string = 'app-tls'

// Every container runs as the annotated service account with the Workload Identity label, so the
// webhook gives it AZURE_CLIENT_ID and a federated token. The application declares none of this.
var containerIdentityParameters = {
  serviceAccountName: serviceAccountName
  azureWorkloadIdentity: true
}

var containerIngressParameters = empty(ingressClassName) ? {} : {
  ingressClassName: ingressClassName
  ingressHost: ingressHost
  ingressTlsSecretName: ingressTlsSecretName
  ingressAnnotations: empty(ingressCertIssuer) ? {} : {
    'cert-manager.io/cluster-issuer': ingressCertIssuer
  }
}

resource azureRecipes 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'azure-recipes'
  properties: {
    recipes: {
      // Local build of the stock Kubernetes container Recipe that adds identity, registry and
      // ingress settings chosen by the platform (see recipes/kubernetes/kubernetes-containers.bicep).
      'Radius.Compute/containers': {
        kind: 'bicep'
        source: '${registry}/recipes/kubernetes-containers:${tag}'
        parameters: union(containerIdentityParameters, containerIngressParameters)
      }
      'Radius.Security/secrets': {
        kind: 'bicep'
        source: '${radiusRecipeRegistry}/secrets:${radiusRecipeTag}'
      }
      'Portability.Messaging/messageQueues': {
        kind: 'bicep'
        source: '${registry}/recipes/servicebus-queue:${tag}'
        parameters: {
          location: location
          workloadIdentityPrincipalId: workloadIdentityPrincipalId
          sku: 'Standard'
        }
      }
      'Radius.Storage/objectStorage': {
        kind: 'bicep'
        source: '${registry}/recipes/blob-objectstorage:${tag}'
        parameters: {
          location: location
          workloadIdentityPrincipalId: workloadIdentityPrincipalId
          sku: 'Standard_LRS'
        }
      }
      'Radius.Data/sqlServerDatabases': {
        kind: 'bicep'
        source: '${registry}/recipes/azuresql-database:${tag}'
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
