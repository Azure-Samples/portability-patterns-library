// Recipe Pack for Azure Local with disconnected operations (ALDO).
//
// Disconnected operations support a deliberately small set of services: ARM, RBAC, Azure Local VMs,
// Arc-enabled servers, Arc-enabled Kubernetes and AKS enabled by Arc, Azure Container Registry,
// Azure Key Vault, and Azure Policy. There is no Service Bus, no Azure SQL Database and no Azure
// Blob Storage, so every backing service runs as a container inside the cluster exactly as it does
// in the local environment.
//
// Two differences from the local Recipe Pack:
//
//   * Every image comes from the local Azure Container Registry. Public registries are unreachable,
//     so the images must be imported first with scripts/azurelocal/import-images.ps1.
//   * Every Recipe is pulled from that same registry, including the stock Radius Kubernetes
//     Recipes, which normally come from ghcr.io.
//
// Identity note: disconnected operations support only *system-assigned* managed identity. There is
// no user-assigned identity and therefore no federated identity credential, so the Microsoft Entra
// Workload Identity design used on AKS does not apply here. Keycloak, federated to the cluster's
// ServiceAccount issuer, takes its place: a workload presents its projected token and receives an
// access token, so the queue needs no password. SQL and object storage have no OIDC path and still
// take credentials issued by their Recipes.

extension radius

@description('''
Login server of the local Azure Container Registry, for example `mylocalacr.azurecr.local`. Holds
both the Recipes and every container image, since public registries are unreachable.
''')
param registry string

@description('Tag applied to the Recipes published from this repository.')
param tag string = 'latest'

@description('''
Set true when the local registry does not serve HTTPS with a certificate the Radius control plane
trusts. Prefer leaving this false and trusting the registry certificate instead.
''')
param plainHttp bool = false

@description('Tag of the RabbitMQ image imported into the local registry.')
param rabbitMqTag string = '4-management-alpine'

@description('Tag of the SQL Server image imported into the local registry.')
param sqlServerTag string = '2022-latest'

@description('Tag of the Azurite image imported into the local registry.')
param azuriteTag string = '3.35.0'

@description('''
Name of an existing Kubernetes image pull secret in the application namespace. Needed when the
local registry requires authentication, because kubelet pulls the backing-service images and does
not use the Radius control plane's registry credentials.
''')
param imagePullSecretName string = ''

@description('''
Issuer URL of the in-cluster Keycloak realm, for example `https://10.0.60.50:30443/realms/bcd`.
Setting this makes the queue Recipe accept access tokens instead of its generated password.
''')
param oauthIssuer string = ''

@description('Existing Secret in the application namespace holding the Keycloak CA under `ca.crt`.')
param oauthCaSecretName string = ''

@description('Keycloak client the workloads authenticate as.')
param oauthClientId string = 'bcd-workloads'

var queueOAuthParameters = empty(oauthIssuer) ? {} : {
  oauthIssuer: oauthIssuer
  oauthCaSecretName: oauthCaSecretName
  oauthClientId: oauthClientId
}

resource aldoRecipes 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'bcd-aldo-recipes'
  properties: {
    recipes: {
      // ---- Backing services, all in-cluster containers from the local registry ---------------
      'BusinessContinuity.Messaging/messageQueues': {
        kind: 'bicep'
        source: '${registry}/bcd/recipes/rabbitmq-queue:${tag}'
        plainHttp: plainHttp
        parameters: union({
          imageRegistry: registry
          imageRepository: 'rabbitmq'
          tag: rabbitMqTag
          imagePullSecretName: imagePullSecretName
        }, queueOAuthParameters)
      }
      'Radius.Storage/objectStorage': {
        kind: 'bicep'
        source: '${registry}/bcd/recipes/azurite-objectstorage:${tag}'
        plainHttp: plainHttp
        parameters: {
          imageRegistry: registry
          imageRepository: 'azure-storage/azurite'
          tag: azuriteTag
          imagePullSecretName: imagePullSecretName
        }
      }
      'Radius.Data/sqlServerDatabases': {
        kind: 'bicep'
        source: '${registry}/bcd/recipes/mssql-database:${tag}'
        plainHttp: plainHttp
        parameters: {
          imageRegistry: registry
          imageRepository: 'mssql/server'
          tag: sqlServerTag
          imagePullSecretName: imagePullSecretName
        }
      }

      // ---- Kubernetes Recipes, published from this repository -------------------------------
      // Both are published from source by scripts/publish-recipes.ps1, so the air gap only ever
      // has to carry container images, never OCI Recipe artifacts. The container Recipe is this
      // repository's build adding platformOptions passthrough; the secrets Recipe is the stock
      // Radius one, vendored unmodified.
      'Radius.Compute/containers': {
        kind: 'bicep'
        source: '${registry}/bcd/recipes/containers:${tag}'
        plainHttp: plainHttp
      }
      'Radius.Security/secrets': {
        kind: 'bicep'
        source: '${registry}/bcd/recipes/secrets:${tag}'
        plainHttp: plainHttp
      }
    }
  }
}

output recipePackId string = aldoRecipes.id
