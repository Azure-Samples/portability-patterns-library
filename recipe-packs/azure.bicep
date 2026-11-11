// Recipe Pack for Azure: AKS with Azure PaaS services.
//
// The queue, object storage, SQL and PostgreSQL types that the Azure Local pack binds to containers
// are bound here to Azure Service Bus, Azure Blob Storage, Azure SQL Database and Azure Database for
// PostgreSQL. Every service runs with its own Entra Workload ID: the platform creates a
// user-assigned managed identity per service, with a federated credential that trusts the
// cluster's OIDC issuer for that service's service account, `{resource}` in serviceAccountName.
// Each Recipe grants only the identities listed for it.

extension radius

@description('OCI registry holding the published Recipe modules, for example myregistry.azurecr.io.')
param registry string

@description('Version (tag) of the Recipes published from this repository, for example 1.4.0. The same tag publish-recipes.ps1 published them under.')
param tag string

@description('Service account each container runs as; {resource} is the container resource name. Must match the federated credential subjects.')
param serviceAccountName string = '{resource}'

@description('Client ID of each service\'s managed identity, by container resource name.')
param workloadClientIds object

@description('Principal IDs of the identities allowed to send to queues.')
param queueSenderPrincipalIds array = []

@description('Principal IDs of the identities allowed to receive from queues.')
param queueReceiverPrincipalIds array = []

@description('Principal IDs of the identities allowed to read and write object storage.')
param storageContributorPrincipalIds array = []

@description('Object ID of the database-administrator identity, the Entra administrator of PostgreSQL servers.')
param databaseAdministratorPrincipalId string

@description('Client ID of the same identity, which Azure SQL uses to identify its Entra administrator.')
param databaseAdministratorClientId string

@description('Name of that identity.')
param databaseAdministratorName string

@description('Application Insights connection string given to every container. Ingestion uses each service\'s identity.')
param applicationInsightsConnectionString string = ''

@description('Action group the Recipes\' alerts notify, such as a dead-lettered message. Empty creates no alerts.')
param alertActionGroupId string = ''
@description('Azure region for provisioned infrastructure.')
param location string = 'eastus2'

@description('''
Azure region for the SQL logical server. Defaults to `location`. Override when the primary region
will not accept new SQL servers -- Azure gates this per subscription and region, failing with
`RegionDoesNotAllowProvisioning`. Azure SQL is reached over its public FQDN, so the database can sit
in a different region from the cluster at the cost of some latency and cross-region egress.
''')
param sqlLocation string = location

@description('''
Azure region for the PostgreSQL flexible server. Defaults to `location`. Override when the primary
region offers no PostgreSQL versions to the subscription, which fails with `ParameterOutOfRange`
("The value of the 'Version' should be in: []"). Reached over its public FQDN, like Azure SQL.
''')
param postgresLocation string = location

@description('Registry path holding the stock Radius Kubernetes Recipes, used for secrets.')
param radiusRecipeRegistry string = 'ghcr.io/radius-project/kube-recipes'

@description('Release of the stock Radius Recipes.')
param radiusRecipeTag string = '0.61.0'

@description('Ingress class that publishes the application\'s routes.')
param ingressClassName string = 'webapprouting.kubernetes.azure.com'

@description('Public host name the routes answer on, for example <label>.<region>.cloudapp.azure.com. Empty answers on any host.')
param ingressHost string = ''

@description('cert-manager ClusterIssuer that obtains the certificate for ingressHost.')
param ingressCertIssuer string = ''

@description('TLS Secret the ingress serves; cert-manager writes the certificate into it.')
param ingressTlsSecretName string = 'app-tls'

@description('cert-manager ClusterIssuer, a CA kept in the cluster, that issues certificates for the app\'s services that declare an `https` port. Empty issues none.')
param serviceCertificateIssuer string = ''

@description('Existing Secret in the application namespace with that issuer\'s CA certificate under `ca.crt`. Every container trusts it as well as the public CAs.')
param serviceCaSecretName string = ''

// In-cluster CA: .NET and OpenSSL trust every certificate in the SSL_CERT_DIR directories, so callers
// verify the app's own services; the system directory stays listed, so Azure's public endpoints verify too.
var useServiceCa = !empty(serviceCaSecretName)

// Every container runs as its own service account with the Workload Identity label, so the
// webhook gives it its own AZURE_CLIENT_ID and federated token. The application declares none of this.
var containerIdentityParameters = {
  serviceAccountName: serviceAccountName
  azureWorkloadIdentity: true
  workloadClientIds: workloadClientIds
  serviceCertificateIssuer: serviceCertificateIssuer
  platformPodVolumes: useServiceCa ? [
    { name: 'service-ca', secret: { secretName: serviceCaSecretName } }
  ] : []
  containerVolumeMounts: useServiceCa ? [
    { name: 'service-ca', mountPath: '/etc/service-ca', readOnly: true }
  ] : []
  containerEnv: concat([
    // Which store backs the app's object storage, so the app picks its client.
    { name: 'Archive__Provider', value: 'AzureBlob' }
    // Where telemetry goes: Application Insights, or nowhere when there is none.
    { name: 'Telemetry__Exporter', value: empty(applicationInsightsConnectionString) ? 'None' : 'AzureMonitor' }
  ], empty(applicationInsightsConnectionString) ? [] : [
    { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: applicationInsightsConnectionString }
  ], useServiceCa ? [
    { name: 'SSL_CERT_DIR', value: '/etc/ssl/certs:/etc/service-ca' }
  ] : [])
}

var routeIngressParameters = {
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
      // Local build of the stock Kubernetes container Recipe that adds identity and registry
      // settings chosen by the platform (see recipes/kubernetes/kubernetes-containers.bicep).
      'Radius.Compute/containers': {
        kind: 'bicep'
        source: '${registry}/recipes/kubernetes/kubernetes-containers:${tag}'
        parameters: containerIdentityParameters
      }
      // What the application publishes is a route it declares; the managed ingress, host name and
      // certificate are the platform's.
      'Radius.Compute/routes': {
        kind: 'bicep'
        source: '${registry}/recipes/kubernetes/kubernetes-routes:${tag}'
        parameters: routeIngressParameters
      }
      'Radius.Security/secrets': {
        kind: 'bicep'
        source: '${radiusRecipeRegistry}/secrets:${radiusRecipeTag}'
      }
      'Portability.Messaging/messageQueues': {
        kind: 'bicep'
        source: '${registry}/recipes/service-bus/servicebus-queue:${tag}'
        parameters: {
          location: location
          senderPrincipalIds: queueSenderPrincipalIds
          receiverPrincipalIds: queueReceiverPrincipalIds
          alertActionGroupId: alertActionGroupId
          sku: 'Standard'
        }
      }
      'Radius.Storage/objectStorage': {
        kind: 'bicep'
        source: '${registry}/recipes/blob-storage/blob-objectstorage:${tag}'
        parameters: {
          location: location
          contributorPrincipalIds: storageContributorPrincipalIds
          sku: 'Standard_LRS'
        }
      }
      'Radius.Data/sqlServerDatabases': {
        kind: 'bicep'
        source: '${registry}/recipes/azure-sql/azuresql-database:${tag}'
        parameters: {
          location: sqlLocation
          administratorClientId: databaseAdministratorClientId
          administratorName: databaseAdministratorName
          skuName: 'S0'
        }
      }
      'Radius.Data/postgreSqlDatabases': {
        kind: 'bicep'
        source: '${registry}/recipes/flexible-server/postgres-flexible-database:${tag}'
        parameters: {
          location: postgresLocation
          administratorPrincipalId: databaseAdministratorPrincipalId
          administratorName: databaseAdministratorName
        }
      }
    }
  }
}

output recipePackId string = azureRecipes.id
