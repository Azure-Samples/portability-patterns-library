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
// ServiceAccount issuer, so token exchange never leaves the site.

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

@description('Existing image pull secret in the application namespace for the connected registry.')
param imagePullSecretName string = ''

@description('Issuer URL of the on-site identity provider, for example a Keycloak realm. Setting this switches the queue to token authentication.')
param oauthIssuer string = ''

@description('Token endpoint of that identity provider. Empty uses the Keycloak path under oauthIssuer.')
param oauthTokenEndpoint string = ''

@description('Existing Secret in the application namespace holding the identity provider CA under `ca.crt`.')
param oauthCaSecretName string = ''

@description('Client at the identity provider that the workloads authenticate as.')
param oauthClientId string = ''

@description('Kubernetes service account the identity provider trusts for that client; must match its federated subject.')
param serviceAccountName string = ''

@description('''
Existing ConfigMap in the application namespace holding `krb5.conf` for the site's Active Directory.
Together with the two keytab Secrets below it switches SQL to Kerberos (integrated) authentication.
''')
param kerberosConfigMapName string = ''

@description('Existing Secret holding the application account keytab under `client.keytab`, mounted into every container.')
param kerberosClientKeytabSecretName string = ''

@description('Existing Secret holding the SQL Server service account keytab under `mssql.keytab`.')
param sqlKerberosKeytabSecretName string = ''

@description('AD account (sAMAccountName) SQL Server uses for Kerberos.')
param sqlKerberosAccount string = ''

@description('Comma-separated Windows logins (DOMAIN\\name) SQL Server creates for the application.')
param sqlWindowsLogins string = ''

@description('Domain controller address SQL Server pins in its hosts file, so it can resolve the domain short name.')
param kerberosDirectoryAddress string = ''

@description('Comma-separated names for kerberosDirectoryAddress: controller FQDN, DNS domain, short domain name.')
param kerberosDirectoryHostNames string = ''

@description('Ingress class that publishes containers with ports on the site network. Empty keeps them cluster-internal.')
param ingressClassName string = ''

@description('TLS Secret in the application namespace that the ingress serves.')
param ingressTlsSecretName string = ''

// Each platform scenario below is expressed as plain Kubernetes volumes, mounts and environment
// variables for the generic container Recipe. A site that doesn't use a scenario leaves its
// parameters empty, and the containers get nothing extra.

// Identity provider (for example Keycloak): every container runs as the trusted service account,
// gets a ServiceAccount token minted for the issuer, and trusts the issuer's CA. That is all the
// queue needs to authenticate without a password.
var useIdentityProvider = !empty(oauthIssuer)
var identityTokenPath = '/var/run/secrets/identity/token'
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
var identityProviderEnv = !useIdentityProvider || empty(oauthCaSecretName) ? [] : [
  { name: 'SSL_CERT_FILE', value: '/etc/identity-ca/ca.crt' }
]

// Active Directory (Kerberos): every container gets krb5.conf and the application account's keytab.
// MIT Kerberos acquires tickets from the keytab on its own, so the application signs in to SQL
// Server with integrated authentication and holds no password.
var useKerberos = !empty(kerberosConfigMapName) && !empty(kerberosClientKeytabSecretName) && !empty(sqlKerberosKeytabSecretName)
var kerberosVolumes = !useKerberos ? [] : [
  {
    name: 'krb5-config'
    configMap: { name: kerberosConfigMapName }
  }
  {
    name: 'krb5-keytab'
    secret: { secretName: kerberosClientKeytabSecretName }
  }
]
var kerberosMounts = !useKerberos ? [] : [
  { name: 'krb5-config', mountPath: '/etc/krb5', readOnly: true }
  { name: 'krb5-keytab', mountPath: '/etc/krb5-keytab', readOnly: true }
]
// The ticket cache stays in memory so nothing is written to the container file system.
var kerberosEnv = !useKerberos ? [] : [
  { name: 'KRB5_CONFIG', value: '/etc/krb5/krb5.conf' }
  { name: 'KRB5_CLIENT_KTNAME', value: 'FILE:/etc/krb5-keytab/client.keytab' }
  { name: 'KRB5CCNAME', value: 'MEMORY:' }
]

var containerPlatformParameters = union(
  useIdentityProvider ? { serviceAccountName: serviceAccountName } : {},
  {
    platformPodVolumes: concat(identityProviderVolumes, kerberosVolumes)
    containerVolumeMounts: concat(identityProviderMounts, kerberosMounts)
    containerEnv: concat(identityProviderEnv, kerberosEnv)
  }
)

var sqlKerberosParameters = !useKerberos ? {} : {
  kerberosConfigMapName: kerberosConfigMapName
  kerberosKeytabSecretName: sqlKerberosKeytabSecretName
  kerberosAccount: sqlKerberosAccount
  windowsLogins: sqlWindowsLogins
  directoryHostAddress: kerberosDirectoryAddress
  directoryHostNames: kerberosDirectoryHostNames
}
var queueOAuthParameters = empty(oauthIssuer) ? {} : {
  oauthIssuer: oauthIssuer
  oauthTokenEndpoint: oauthTokenEndpoint
  oauthCaSecretName: oauthCaSecretName
  oauthClientId: oauthClientId
  oauthAssertionFile: identityTokenPath
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
        parameters: union({
          imageRegistry: registry
          imageRepository: 'mssql/server'
          tag: sqlServerTag
          imagePullSecretName: imagePullSecretName
        }, sqlKerberosParameters)
      }
      'Radius.Compute/containers': {
        kind: 'bicep'
        source: '${registry}/recipes/kubernetes-containers:${tag}'
        plainHttp: plainHttp
        parameters: union({
          imagePullSecretName: imagePullSecretName
          ingressClassName: ingressClassName
          ingressTlsSecretName: ingressTlsSecretName
        }, containerPlatformParameters)
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
