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
// Identity: an identity provider on site (Keycloak in the samples), a required part of the platform,
// trusts the cluster's own ServiceAccount issuer, so token exchange never leaves the site. Each
// service runs as its own service account and authenticates as its own client: {resource} in
// serviceAccountName and oauthClientId is the container resource name. The queue accepts only those
// tokens from workloads; its administrator, from an existing Secret, serves the operators and the
// management interface.
//
// Credentials that can't come from that identity, such as each service's database password, are
// generated on site and reach the service through containerEnvFromSecrets.
//
// Images and Recipes are pinned to exact versions, so a restarted pod or a redeployment never picks
// up a different one. The tags here must match what infra/azurelocal/images.txt mirrors.
//
// Availability picks how the queue and PostgreSQL run. Both settings return the same connection
// values, so the application is the same either way:
//
//   * 'high'     - operators the platform installs run them (provision-operators.ps1): three
//     RabbitMQ nodes (rabbitmq-cluster-operator), and a PostgreSQL primary with replicas and
//     continuous backups to the object store (cloudnative-pg). A node can fail without losing a
//     message or a committed transaction.
//   * 'standard' - one container each, from the official images, with no operators and no backups
//     (rabbitmq, postgres). Fewer resources, for sites that accept downtime while a pod restarts
//     and data lost with a volume.
//
// SQL Server, object storage, the containers and routes use the same Recipes in both.

extension radius

@description('''
How the queue and PostgreSQL run: 'high' (operator-run, replicated, backed up) or 'standard' (one
container each). The platform must match: setup-platform.ps1 with the same Availability.
''')
@allowed([ 'high', 'standard' ])
param availability string = 'high'

@description('''
Address of the in-cluster connected registry: the ClusterIP of its Service. Holds both the Recipes and
every container image, synced from the cloud ACR while the link is up.
''')
param registry string

@description('Version (tag) of the Recipes published from this repository, for example 1.4.0. The same tag publish-recipes.ps1 published them under.')
param tag string

@description('''
Registry path holding Radius's stock Kubernetes Recipes, used for secrets. On Azure Local they are
mirrored from ghcr.io into the cloud ACR and synced into the cluster like every other artifact.
''')
param radiusRecipeRegistry string = '${registry}/radius-project/kube-recipes'

@description('Release of the stock Radius Recipes.')
param radiusRecipeTag string = '0.61.0'

@description('Set true only for a registry that does not serve HTTPS.')
param plainHttp bool = false

@description('Tag of the RabbitMQ image mirrored into the registry.')
param rabbitMqTag string = '4.3.7-management-alpine'

@description('RabbitMQ nodes when availability is \'high\'. Three keeps the queues available, with no message lost, when one node fails.')
param rabbitMqReplicas int = 3

@description('''
Existing Secret in the application namespace with the RabbitMQ administrator's credentials, keys
`username`, `password` and `default_user.conf` ("default_user = <username>" and
"default_pass = <password>" lines). The administrator serves the management interface and the
operators only; workloads authenticate with their identity provider token.
''')
param rabbitMqAdminCredentialsSecretName string

@description('Tag of the SQL Server image mirrored into the registry: a specific cumulative update.')
param sqlServerTag string = '2022-CU27-GDR1-ubuntu-22.04'

@description('Tag of the CloudNativePG PostgreSQL image mirrored into the registry, used when availability is \'high\'. The same PostgreSQL version as postgresTag.')
param cloudNativePgTag string = '17.11-202611020810-standard-trixie'

@description('Tag of the official PostgreSQL image mirrored into the registry, used when availability is \'standard\'. The same PostgreSQL version as cloudNativePgTag.')
param postgresTag string = '17.11-alpine3.24'

@description('PostgreSQL instances per database when availability is \'high\': one primary, the rest replicas that take over if it fails.')
param postgresInstances int = 3

@description('HTTPS endpoint of the S3-compatible store that PostgreSQL backups go to (scripts/infra/azurelocal/provision-object-store.ps1) when availability is \'high\'. Empty takes no backups.')
param backupEndpoint string = ''

@description('Bucket on that endpoint for the application namespace\'s backups.')
param backupBucket string = ''

@description('Secret in the application namespace with that bucket\'s credentials, keys ACCESS_KEY_ID and ACCESS_SECRET_KEY, and the store\'s CA, key ca.crt.')
param backupCredentialsSecretName string = ''

@description('How long PostgreSQL backups are kept: the window a database can be restored to any point in.')
param backupRetention string = '30d'

@description('HTTPS endpoint of the site\'s S3 object store (scripts/infra/azurelocal/provision-object-store.ps1), which holds the application\'s object storage buckets.')
param objectStoreEndpoint string = ''

@description('Secret in the application namespace with that namespace\'s keys to the store, ACCESSKEYID and SECRETACCESSKEY. Only containers connected to object storage get them.')
param objectStoreCredentialsSecretName string = ''

@description('''
SQL Server edition, or a product key. Required: the licence is the site's choice. Express is free for
production use within its limits (4 cores, 1410 MB of buffer pool, 10 GB per database); Standard and
Enterprise need licences for sqlServerCpuLimit cores; Developer is free but not licensed for
production use.
''')
param sqlServerEdition string

@description('CPU cores SQL Server may use. Per-core editions (Standard, Enterprise) are licensed for the cores a container can use, so this also sets how many to license.')
param sqlServerCpuLimit string = '2'

@description('cert-manager ClusterIssuer, a CA issuer, that issues certificates for in-cluster services: the queue, SQL Server, PostgreSQL and the app\'s own services that declare an `https` port. Empty serves them without TLS.')
param certificateIssuer string = ''

@description('Existing Secret in the application namespace with that issuer\'s CA certificate under `ca.crt`. Every container gets it, so clients verify those services.')
param siteCaSecretName string = ''

@description('''
Kubernetes Secrets, by name, whose keys become environment variables of every container, such as
per-service database passwords. {resource} is the container resource name.
''')
param containerEnvFromSecrets array = []

@description('OpenTelemetry Collector endpoint given to every container as OTEL_EXPORTER_OTLP_ENDPOINT. Empty sends no telemetry.')
param otlpEndpoint string = ''

@description('Existing image pull secret in the application namespace for the connected registry.')
param imagePullSecretName string = ''

@description('''
Issuer URL of the on-site identity provider, for example a Keycloak realm. Required: every pod gets a
token for it, and the queue accepts only that token from workloads.
''')
param oauthIssuer string

@description('Token endpoint of that identity provider, published to pods as IDENTITY_TOKEN_ENDPOINT. Empty uses the Keycloak path under oauthIssuer.')
param oauthTokenEndpoint string = ''

@description('Existing Secret in the application namespace holding the identity provider CA under `ca.crt`.')
param oauthCaSecretName string = ''

@description('Client at the identity provider each workload authenticates as, published to pods as IDENTITY_CLIENT_ID. May contain {resource}.')
param oauthClientId string

@description('Kubernetes service account each workload runs as; the identity provider trusts it for that client. May contain {resource}.')
param serviceAccountName string = '{resource}'

@description('Ingress class that publishes the application\'s routes on the site network.')
param ingressClassName string = 'nginx'

@description('TLS Secret in the application namespace that the routes serve.')
param ingressTlsSecretName string = ''

// Each platform scenario below is expressed as plain Kubernetes volumes, mounts and environment
// variables for the generic container Recipe. Identity is always on; a site that doesn't use one of
// the other scenarios leaves its parameters empty, and the containers get nothing extra.

// Identity provider (for example Keycloak): every container runs as the trusted service account,
// gets a ServiceAccount token minted for the issuer, and trusts the issuer's CA. The IDENTITY_*
// variables tell the application where to exchange that token, the way Entra Workload ID's
// AZURE_* variables do on Azure. Identity belongs to the pod, so the queue and any other service
// that accepts the issuer's tokens use the same one.
var identityTokenPath = '/var/run/secrets/identity/token'
var identityTokenEndpoint = empty(oauthTokenEndpoint) ? '${oauthIssuer}/protocol/openid-connect/token' : oauthTokenEndpoint
var identityProviderVolumes = concat([
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
var identityProviderMounts = concat([
  { name: 'identity-token', mountPath: '/var/run/secrets/identity', readOnly: true }
], empty(oauthCaSecretName) ? [] : [
  { name: 'identity-ca', mountPath: '/etc/identity-ca', readOnly: true }
])
var identityProviderEnv = [
  { name: 'IDENTITY_TOKEN_FILE', value: identityTokenPath }
  { name: 'IDENTITY_CLIENT_ID', value: oauthClientId }
  { name: 'IDENTITY_TOKEN_ENDPOINT', value: identityTokenEndpoint }
]

var telemetryEnv = empty(otlpEndpoint) ? [] : [
  { name: 'OTEL_EXPORTER_OTLP_ENDPOINT', value: otlpEndpoint }
]

// Which store backs the app's object storage (the site's S3 store), so the app picks its client.
var objectStorageEnv = [
  { name: 'Archive__Provider', value: 'S3' }
]

// Site CA: every container trusts the CA that signs the in-cluster services' certificates: the
// queue, the object store, SQL Server, PostgreSQL and the identity provider. .NET and most runtimes
// read SSL_CERT_FILE as the CAs they trust, so clients verify those services with no code; PostgreSQL
// clients (Npgsql, libpq) read PGSSLROOTCERT instead. Without a site CA, the identity provider's CA
// is the one trusted.
var useSiteCa = !empty(siteCaSecretName)
var siteCaVolumes = !useSiteCa ? [] : [
  {
    name: 'site-ca'
    secret: { secretName: siteCaSecretName }
  }
]
var siteCaMounts = !useSiteCa ? [] : [
  { name: 'site-ca', mountPath: '/etc/site-ca', readOnly: true }
]
var siteCaEnv = useSiteCa ? [
  { name: 'SSL_CERT_FILE', value: '/etc/site-ca/ca.crt' }
  { name: 'PGSSLROOTCERT', value: '/etc/site-ca/ca.crt' }
] : (!empty(oauthCaSecretName) ? [
  { name: 'SSL_CERT_FILE', value: '/etc/identity-ca/ca.crt' }
] : [])

// Object storage: the platform, not the Recipe, holds the keys to the shared store, and gives them
// only to containers connected to an objectStorage resource. Their pods get a label the store's
// network policy lets in.
var objectStorageType = 'Radius.Storage/objectStorage'
var connectionParameters = empty(objectStoreCredentialsSecretName) ? {} : {
  connectionSecretNames: { '${objectStorageType}': objectStoreCredentialsSecretName }
  connectionPodLabels: { '${objectStorageType}': { 'object-store/client': 'true' } }
}

var containerPlatformParameters = union(
  connectionParameters,
  {
    serviceAccountName: serviceAccountName
    serviceCertificateIssuer: certificateIssuer
    platformPodVolumes: concat(identityProviderVolumes, siteCaVolumes)
    containerVolumeMounts: concat(identityProviderMounts, siteCaMounts)
    containerEnv: concat(identityProviderEnv, telemetryEnv, siteCaEnv, objectStorageEnv)
    containerEnvFromSecrets: containerEnvFromSecrets
  }
)

// The queue and PostgreSQL Recipes for the availability, each given only the parameters it declares.
var highAvailability = availability == 'high'

// The broker only needs to know which issuer to trust; workloads get their identity from the pod.
var queueRecipe = highAvailability ? 'rabbitmq-cluster-operator/rabbitmq-queue' : 'rabbitmq/rabbitmq-queue'
var queueParameters = union({
  imageRegistry: registry
  imageRepository: 'rabbitmq'
  tag: rabbitMqTag
  imagePullSecretName: imagePullSecretName
  certificateIssuer: certificateIssuer
  oauthIssuer: oauthIssuer
  oauthCaSecretName: oauthCaSecretName
  adminCredentialsSecretName: rabbitMqAdminCredentialsSecretName
}, highAvailability ? { replicas: rabbitMqReplicas } : {})

var postgresRecipe = highAvailability ? 'cloudnative-pg/postgres-database' : 'postgres/postgres-database'
var postgresParameters = highAvailability ? {
  imageRegistry: registry
  imageRepository: 'cloudnative-pg/postgresql'
  tag: cloudNativePgTag
  instances: postgresInstances
  imagePullSecretName: imagePullSecretName
  certificateIssuer: certificateIssuer
  backupEndpoint: backupEndpoint
  backupBucket: backupBucket
  backupCredentialsSecretName: backupCredentialsSecretName
  backupRetention: backupRetention
} : {
  imageRegistry: registry
  imageRepository: 'postgres'
  tag: postgresTag
  imagePullSecretName: imagePullSecretName
  certificateIssuer: certificateIssuer
}

resource azureLocalRecipes 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'azure-local-recipes'
  properties: {
    recipes: {
      'Portability.Messaging/messageQueues': {
        kind: 'bicep'
        source: '${registry}/recipes/${queueRecipe}:${tag}'
        plainHttp: plainHttp
        parameters: queueParameters
      }
      'Radius.Storage/objectStorage': {
        kind: 'bicep'
        source: '${registry}/recipes/seaweedfs/seaweedfs-objectstorage:${tag}'
        plainHttp: plainHttp
        parameters: {
          endpoint: objectStoreEndpoint
        }
      }
      'Radius.Data/sqlServerDatabases': {
        kind: 'bicep'
        source: '${registry}/recipes/sql-server/mssql-database:${tag}'
        plainHttp: plainHttp
        parameters: {
          imageRegistry: registry
          imageRepository: 'mssql/server'
          tag: sqlServerTag
          edition: sqlServerEdition
          cpuLimit: sqlServerCpuLimit
          imagePullSecretName: imagePullSecretName
          certificateIssuer: certificateIssuer
        }
      }
      'Radius.Data/postgreSqlDatabases': {
        kind: 'bicep'
        source: '${registry}/recipes/${postgresRecipe}:${tag}'
        plainHttp: plainHttp
        parameters: postgresParameters
      }
      'Radius.Compute/containers': {
        kind: 'bicep'
        source: '${registry}/recipes/kubernetes/kubernetes-containers:${tag}'
        plainHttp: plainHttp
        parameters: union({
          imagePullSecretName: imagePullSecretName
        }, containerPlatformParameters)
      }
      // What the application publishes is a route it declares; the site's ingress and certificate
      // are the platform's.
      'Radius.Compute/routes': {
        kind: 'bicep'
        source: '${registry}/recipes/kubernetes/kubernetes-routes:${tag}'
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
