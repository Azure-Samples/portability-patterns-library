// Recipe Pack for connected Azure Local (AKS enabled by Arc on an Azure Local instance).
//
// The instance is connected today, but the workload has to keep running when that link drops:
// management and redeployment may stop, the application must not. That rules out every PaaS
// dependency, so the backing services run as in-cluster containers.
//
//   * `registry` is the ACR connected registry running inside the cluster (an Arc extension that
//     syncs from a Premium ACR in Azure). Kubelet and the Radius control plane both pull from it,
//     so a lost Azure link does not stop a restarted pod from finding its image or Recipe.
//   * The connected registry always serves HTTPS with a private CA. Give that CA to the Radius
//     control plane and leave plainHttp false.
//
// Identity: an identity provider on site (Keycloak in the samples) trusts the cluster's own
// ServiceAccount issuer, so token exchange never leaves the site. Each service runs as its own
// service account and authenticates as its own client: {resource} in serviceAccountName and
// oauthClientId is the container resource name.
//
// Credentials that can't come from that identity, such as each service's database password, are
// synced into the cluster from Azure Key Vault and reach the service through containerEnvFromSecrets.

extension radius

@description('''
Address of the in-cluster connected registry: the ClusterIP of its Service. Holds both the Recipes and
every container image, synced from the cloud ACR while the link is up.
''')
param registry string

@description('Tag applied to the Recipes published from this repository.')
param tag string = 'latest'

@description('''
Registry path holding Radius's stock Kubernetes Recipes, used for secrets. On Azure Local they are
mirrored from ghcr.io into the cloud ACR and synced into the cluster like every other artifact.
''')
param radiusRecipeRegistry string = '${registry}/radius-project/kube-recipes'

@description('Tag of the stock Radius Recipes.')
param radiusRecipeTag string = 'latest'

@description('Set true only for a registry that does not serve HTTPS.')
param plainHttp bool = false

@description('Tag of the RabbitMQ image mirrored into the registry.')
param rabbitMqTag string = '4-management-alpine'

@description('Tag of the SQL Server image mirrored into the registry.')
param sqlServerTag string = '2022-latest'

@description('Tag of the Azurite image mirrored into the registry.')
param azuriteTag string = '3.35.0'

@description('Tag of the PostgreSQL image mirrored into the registry.')
param postgresTag string = '17-alpine'

@description('SQL Server edition, or a product key. Developer is free but not licensed for production use.')
param sqlServerEdition string = 'Developer'

@description('cert-manager ClusterIssuer that issues certificates for in-cluster services, such as PostgreSQL. Empty serves them without TLS.')
param certificateIssuer string = ''

@description('''
Kubernetes Secrets, by name, whose keys become environment variables of every container, such as
per-service database passwords synced from Key Vault. {resource} is the container resource name.
''')
param containerEnvFromSecrets array = []

@description('OpenTelemetry Collector endpoint given to every container as OTEL_EXPORTER_OTLP_ENDPOINT. Empty sends no telemetry.')
param otlpEndpoint string = ''

@description('Existing image pull secret in the application namespace for the connected registry.')
param imagePullSecretName string = ''

@description('Issuer URL of the on-site identity provider, for example a Keycloak realm. Setting this gives every pod a token for it and switches the queue to token authentication.')
param oauthIssuer string = ''

@description('Token endpoint of that identity provider, published to pods as IDENTITY_TOKEN_ENDPOINT. Empty uses the Keycloak path under oauthIssuer.')
param oauthTokenEndpoint string = ''

@description('Existing Secret in the application namespace holding the identity provider CA under `ca.crt`.')
param oauthCaSecretName string = ''

@description('Client at the identity provider each workload authenticates as, published to pods as IDENTITY_CLIENT_ID. May contain {resource}.')
param oauthClientId string = ''

@description('Kubernetes service account each workload runs as; the identity provider trusts it for that client. May contain {resource}.')
param serviceAccountName string = ''

@description('Ingress class that publishes the application\'s routes on the site network.')
param ingressClassName string = 'nginx'

@description('TLS Secret in the application namespace that the routes serve.')
param ingressTlsSecretName string = ''

// Each platform scenario below is expressed as plain Kubernetes volumes, mounts and environment
// variables for the generic container Recipe. A site that doesn't use a scenario leaves its
// parameters empty, and the containers get nothing extra.

// Identity provider (for example Keycloak): every container runs as the trusted service account,
// gets a ServiceAccount token minted for the issuer, and trusts the issuer's CA. The IDENTITY_*
// variables tell the application where to exchange that token, the way Entra Workload ID's
// AZURE_* variables do on Azure. Identity belongs to the pod, so the queue and any other service
// that accepts the issuer's tokens use the same one.
var useIdentityProvider = !empty(oauthIssuer)
var identityTokenPath = '/var/run/secrets/identity/token'
var identityTokenEndpoint = empty(oauthTokenEndpoint) ? '${oauthIssuer}/protocol/openid-connect/token' : oauthTokenEndpoint
var identityProviderVolumes = !useIdentityProvider ? [] : concat([
  {
    name: 'identity-token'
    projected: {
      sources: [
        {
          serviceAccountToken: {
            audience: oauthIssuer
            expirationSeconds: 600
            path: 'token'
          }
        }
      ]
    }
  }
], empty(oauthCaSecretName) ? [] : [
  {
    name: 'identity-ca'
    secret: { secretName: oauthCaSecretName }
  }
])
var identityProviderMounts = !useIdentityProvider ? [] : concat([
  { name: 'identity-token', mountPath: '/var/run/secrets/identity', readOnly: true }
], empty(oauthCaSecretName) ? [] : [
  { name: 'identity-ca', mountPath: '/etc/identity-ca', readOnly: true }
])
// .NET and most runtimes read SSL_CERT_FILE, so the application trusts the issuer with no code.
var identityProviderEnv = !useIdentityProvider ? [] : concat([
  { name: 'IDENTITY_TOKEN_FILE', value: identityTokenPath }
  { name: 'IDENTITY_CLIENT_ID', value: oauthClientId }
  { name: 'IDENTITY_TOKEN_ENDPOINT', value: identityTokenEndpoint }
], empty(oauthCaSecretName) ? [] : [
  { name: 'SSL_CERT_FILE', value: '/etc/identity-ca/ca.crt' }
])

var telemetryEnv = empty(otlpEndpoint) ? [] : [
  { name: 'OTEL_EXPORTER_OTLP_ENDPOINT', value: otlpEndpoint }
]

var containerPlatformParameters = union(
  useIdentityProvider ? { serviceAccountName: serviceAccountName } : {},
  {
    platformPodVolumes: identityProviderVolumes
    containerVolumeMounts: identityProviderMounts
    containerEnv: concat(identityProviderEnv, telemetryEnv)
    containerEnvFromSecrets: containerEnvFromSecrets
  }
)

// The broker only needs to know which issuer to trust; workloads get their identity from the pod.
var queueOAuthParameters = empty(oauthIssuer) ? {} : {
  oauthIssuer: oauthIssuer
  oauthCaSecretName: oauthCaSecretName
}

resource azureLocalRecipes 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'azure-local-recipes'
  properties: {
    recipes: {
      'Portability.Messaging/messageQueues': {
        kind: 'bicep'
        source: '${registry}/recipes/rabbitmq-queue:${tag}'
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
        source: '${registry}/recipes/azurite-objectstorage:${tag}'
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
        source: '${registry}/recipes/mssql-database:${tag}'
        plainHttp: plainHttp
        parameters: {
          imageRegistry: registry
          imageRepository: 'mssql/server'
          tag: sqlServerTag
          edition: sqlServerEdition
          imagePullSecretName: imagePullSecretName
        }
      }
      'Radius.Data/postgreSqlDatabases': {
        kind: 'bicep'
        source: '${registry}/recipes/postgres-database:${tag}'
        plainHttp: plainHttp
        parameters: {
          imageRegistry: registry
          imageRepository: 'postgres'
          tag: postgresTag
          imagePullSecretName: imagePullSecretName
          certificateIssuer: certificateIssuer
        }
      }
      'Radius.Compute/containers': {
        kind: 'bicep'
        source: '${registry}/recipes/kubernetes-containers:${tag}'
        plainHttp: plainHttp
        parameters: union({
          imagePullSecretName: imagePullSecretName
        }, containerPlatformParameters)
      }
      // What the application publishes is a route it declares; the site's ingress and certificate
      // are the platform's.
      'Radius.Compute/routes': {
        kind: 'bicep'
        source: '${registry}/recipes/kubernetes-routes:${tag}'
        plainHttp: plainHttp
        parameters: {
          ingressClassName: ingressClassName
          ingressTlsSecretName: ingressTlsSecretName
        }
      }
      'Radius.Security/secrets': {
        kind: 'bicep'
        source: '${radiusRecipeRegistry}/secrets:${radiusRecipeTag}'
        plainHttp: plainHttp
      }
    }
  }
}

output recipePackId string = azureLocalRecipes.id
