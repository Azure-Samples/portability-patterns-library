// Recipe Pack for connected Azure Local (AKS enabled by Arc on an Azure Local instance).
//
// The instance is connected today, but the workload has to keep running when that link drops:
// management and redeployment may stop, the application must not. That rules out every PaaS
// dependency, so the backing services run as in-cluster containers exactly as they do on ALDO.
//
// Differences from the ALDO Recipe Pack:
//
//   * `registry` is the ACR connected registry running inside the cluster (an Arc extension that
//     syncs from a Premium ACR in Azure). Kubelet and the Radius control plane both pull from it,
//     so a lost Azure link does not stop a restarted pod from finding its image or Recipe.
//   * The connected registry always serves HTTPS with a private CA, which
//     scripts/azurelocal/deploy.ps1 hands to the Radius control plane, so plainHttp stays false.
//
// Identity is the same as ALDO: Keycloak in the cluster federates the cluster's own ServiceAccount
// issuer and binds Active Directory, so token exchange never leaves the site.

extension radius

@description('''
Address of the in-cluster connected registry, for example `10.96.0.50`. Holds both the Recipes and
every container image, synced from the cloud ACR while the link is up.
''')
param registry string

@description('Tag applied to the Recipes published from this repository.')
param tag string = 'latest'

@description('Set true only for a registry that does not serve HTTPS.')
param plainHttp bool = false

@description('Tag of the RabbitMQ image mirrored into the registry.')
param rabbitMqTag string = '4-management-alpine'

@description('Tag of the SQL Server image mirrored into the registry.')
param sqlServerTag string = '2022-latest'

@description('Tag of the Azurite image mirrored into the registry.')
param azuriteTag string = '3.35.0'

@description('Existing image pull secret in the application namespace for the connected registry.')
param imagePullSecretName string = ''

@description('Issuer URL of the in-cluster Keycloak realm. Setting this switches the queue to token authentication.')
param oauthIssuer string = ''

@description('Existing Secret in the application namespace holding the Keycloak CA under `ca.crt`.')
param oauthCaSecretName string = ''

@description('Keycloak client the workloads authenticate as.')
param oauthClientId string = 'bcd-workloads'

@description('Ingress class that publishes containers with ports on the site network, from scripts/azurelocal/provision-ingress.ps1. Empty keeps them cluster-internal.')
param ingressClassName string = ''

@description('TLS Secret in the application namespace that the ingress serves.')
param ingressTlsSecretName string = ''

var queueOAuthParameters = empty(oauthIssuer) ? {} : {
  oauthIssuer: oauthIssuer
  oauthCaSecretName: oauthCaSecretName
  oauthClientId: oauthClientId
}

resource azureLocalRecipes 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'bcd-azurelocal-recipes'
  properties: {
    recipes: {
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
      'Radius.Compute/containers': {
        kind: 'bicep'
        source: '${registry}/bcd/recipes/containers:${tag}'
        plainHttp: plainHttp
        parameters: {
          ingressClassName: ingressClassName
          ingressTlsSecretName: ingressTlsSecretName
        }
      }
      'Radius.Security/secrets': {
        kind: 'bicep'
        source: '${registry}/bcd/recipes/secrets:${tag}'
        plainHttp: plainHttp
      }
    }
  }
}

output recipePackId string = azureLocalRecipes.id
