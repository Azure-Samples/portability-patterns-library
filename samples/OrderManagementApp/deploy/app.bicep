// Business Continuity Demo App
//
// This file is environment-agnostic. It declares *what* the application needs -- a queue, object
// storage, a SQL database, and two workers -- and never states *how* those are provisioned. The
// Recipe Pack bound to the target Environment decides whether the queue is RabbitMQ or Azure
// Service Bus, whether object storage is Azurite or Azure Blob Storage, and whether SQL is a
// container or Azure SQL Database.
//
// Deploy with:
//   rad deploy ./deploy/app.bicep -e bcd-local -p @deploy/params.local.json
//   rad deploy ./deploy/app.bicep -e bcd-azure -p @deploy/params.azure.json

extension radius
extension businessContinuity

@description('Radius Environment ID. Supplied by the rad CLI.')
param environment string

@description('Name of the Radius Application.')
param application string = 'bcd'

@description('Container image for the publisher, which serves the orders API and the browser app.')
param publisherImage string

@description('Container image for the consumer worker.')
param consumerImage string

@description('Seconds between generated business events. 0 turns the generator off; orders arrive through the API.')
param publishIntervalSeconds int = 0

@description('''
How the orders API validates user access tokens, passed unchanged to Microsoft.Identity.Web as its
`AzureAd` section. Entra ID: `Instance`, `TenantId`, `ClientId`. Any other OIDC provider (Keycloak on
Azure Local): `Authority`, `MetadataAddress`, `ClientId`, `Audience`. Empty disables sign-in.
''')
param apiAuthentication object = {}

@description('''
MSAL.js settings for the browser app, served to it as /config.json: `Authority`, `ClientId`,
`ProtocolMode` (`AAD` or `OIDC`), `KnownAuthorities`, `ApiScope`, `IdentityProvider`, `Environment`.
''')
param spaSettings object = {}

@description('Name of the queue that carries business continuity events.')
param queueName string = 'business-events'

@description('Blob container / bucket that archived event JSON is written to.')
param archiveContainerName string = 'business-events'

@description('Name of the application database.')
param databaseName string = 'bcddb'

@description('SQL administrator username.')
param sqlAdminUsername string = 'bcdadmin'

@description('SQL administrator password.')
@secure()
param sqlAdminPassword string

@description('Force Entra ID authentication to SQL through Workload Identity. Set true in Azure.')
param sqlUseEntraId bool = false

@description('''
True when the queue Recipe issues broker credentials (RabbitMQ). False for Azure Service Bus, which
uses managed identity and issues none.
''')
param queueUsesBasicAuth bool = true

@description('''
True when the object storage Recipe issues a connection string (Azurite). False for Azure Blob
Storage, where shared-key access is disabled and managed identity is the only option.
''')
param archiveUsesConnectionString bool = true

@description('''
Kubernetes service account annotated for Workload Identity. Empty for local and Azure Local
environments, which have no Entra identity to federate with.
''')
param serviceAccountName string = ''

@description('''
Name of a Kubernetes image pull secret for a private registry. Required in air-gapped environments
such as Azure Local disconnected operations, where the kubelet must authenticate to the local
registry. Empty where the registry allows anonymous pull or the nodes already hold credentials.
''')
param imagePullSecretName string = ''

@description('''
Audience to mint the projected ServiceAccount token for, normally the OIDC issuer URL of the
in-cluster identity provider. Setting this projects a token the workers exchange for an access
token, which is how they reach the queue without a password where Entra is unavailable. Empty in
environments that use Entra Workload Identity or Recipe-issued credentials.
''')
param workloadTokenAudience string = ''

@description('Existing Secret holding the identity provider certificate authority under `ca.crt`.')
param identityCaSecretName string = ''

// A token scoped to one audience and rotated in place by the kubelet, plus the CA needed to trust
// the issuer over HTTPS. Both are pod-level, so the two workers declare the same mounts.
var identityVolumes = union(
  empty(workloadTokenAudience) ? {} : {
    identitytoken: {
      serviceAccountToken: {
        audience: workloadTokenAudience
        expirationSeconds: 600
        path: 'keycloak'
      }
    }
  },
  empty(identityCaSecretName) ? {} : {
    identityca: {
      secretName: identityCaSecretName
    }
  }
)

var identityMounts = concat(
  empty(workloadTokenAudience) ? [] : [
    {
      volumeName: 'identitytoken'
      mountPath: '/var/run/secrets/tokens'
    }
  ],
  empty(identityCaSecretName) ? [] : [
    {
      volumeName: 'identityca'
      mountPath: '/etc/bcd/identity-ca'
    }
  ]
)

var identityMountOption = empty(identityMounts) ? {} : {
  volumeMounts: identityMounts
}

var identityVolumeOption = empty(identityVolumes) ? {} : {
  volumes: identityVolumes
}

// Binds the workers to a named Kubernetes service account, which fixes the `sub` claim of the
// token Kubernetes projects into the pod. That claim is what an issuer matches the workload on,
// whether the issuer is Entra or an in-cluster one.
//
// The label is Entra-specific: it triggers the Azure Workload Identity webhook to inject
// AZURE_CLIENT_ID, AZURE_TENANT_ID and AZURE_FEDERATED_TOKEN_FILE. Where the token is projected
// for a different audience that webhook is not installed, so the label is omitted.
//
// Delivered through `platformOptions`, which the Resource Type documents as "Kubernetes Deployment
// and Pod override properties". Flat keys match the convention the Azure ACI Recipe already uses.
var workloadIdentityOptions = empty(serviceAccountName) ? {} : union(
  {
    serviceAccountName: serviceAccountName
  },
  empty(workloadTokenAudience) ? {
    podLabels: {
      'azure.workload.identity/use': 'true'
    }
  } : {}
)

var imagePullOptions = empty(imagePullSecretName) ? {} : {
  imagePullSecrets: [
    {
      name: imagePullSecretName
    }
  ]
}

var platformOptions = union(workloadIdentityOptions, imagePullOptions)

// Radius never injects Recipe secrets as plain environment variables. It writes them into a managed
// Kubernetes Secret and publishes only its name on `<resource>.properties.secrets.name`, so each
// secret is bound explicitly below with `secretKeyRef`. Where a Recipe issues no secrets (the Azure
// path, which uses managed identity) these blocks are omitted entirely.
var queueSecretEnv = queueUsesBasicAuth ? {
  CONNECTION_QUEUE_USERNAME: {
    valueFrom: {
      secretKeyRef: {
        secretName: queue.properties.secrets.name
        key: 'username'
      }
    }
  }
  CONNECTION_QUEUE_PASSWORD: {
    valueFrom: {
      secretKeyRef: {
        secretName: queue.properties.secrets.name
        key: 'password'
      }
    }
  }
} : {}

var archiveSecretEnv = archiveUsesConnectionString ? {
  CONNECTION_ARCHIVE_CONNECTIONSTRING: {
    valueFrom: {
      secretKeyRef: {
        secretName: archive.properties.secrets.name
        key: 'connectionString'
      }
    }
  }
} : {}

// The SQL administrator password is a developer-supplied input rather than a Recipe output, so it
// is passed straight through. On Azure the workers authenticate with Entra ID instead and no
// password is injected.
var sqlSecretEnv = sqlUseEntraId ? {} : {
  CONNECTION_SQL_PASSWORD: {
    #disable-next-line use-secure-value-for-secure-inputs
    value: sqlAdminPassword
  }
}

// Configuration sections become `Section__Key` variables, the ASP.NET Core convention. Only the
// values differ between Entra ID and Keycloak; the code is the same.
var userIdentityEnv = toObject(
  concat(
    map(filter(items(apiAuthentication), entry => !empty(string(entry.value))), entry => {
      name: 'AzureAd__${entry.key}'
      value: string(entry.value)
    }),
    map(filter(items(spaSettings), entry => !empty(string(entry.value))), entry => {
      name: 'Spa__${entry.key}'
      value: string(entry.value)
    })
  ),
  entry => entry.name,
  entry => { value: entry.value })

// Token validation calls the identity provider over HTTPS. Where its certificate is from a private
// CA (Keycloak on Azure Local) the platform supplies that CA; the API itself has no trust code.
var userIdentityCaEnv = empty(identityCaSecretName) ? {} : {
  SSL_CERT_FILE: {
    value: '/etc/bcd/identity-ca/ca.crt'
  }
}

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: application
  properties: {
    environment: environment
  }
}

// Portable queue. Backed by RabbitMQ locally and Azure Service Bus in Azure.
resource queue 'BusinessContinuity.Messaging/messageQueues@2025-08-01-preview' = {
  name: 'events'
  properties: {
    environment: environment
    application: app.id
    queueName: queueName
    maxDeliveryCount: 10
  }
}

// Portable object storage. Backed by Azurite locally and Azure Blob Storage in Azure.
resource archive 'Radius.Storage/objectStorage@2025-08-01-preview' = {
  name: 'archive'
  properties: {
    environment: environment
    application: app.id
    containerName: archiveContainerName
  }
}

// Portable relational database. Backed by a SQL Server container locally and Azure SQL in Azure.
resource database 'Radius.Data/sqlServerDatabases@2025-08-01-preview' = {
  name: 'eventsdb'
  properties: {
    environment: environment
    application: app.id
    database: databaseName
    username: sqlAdminUsername
    password: sqlAdminPassword
  }
}

// Orders API and browser app: users sign in, place orders, and the API publishes each order to the
// queue. Can also generate random business events on a timer (off by default).
resource publisher 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'publisher'
  properties: union({
    environment: environment
    application: app.id
    replicas: 1
    containers: {
      publisher: union({
        image: publisherImage
        ports: {
          http: {
            containerPort: 8080
          }
        }
        readinessProbe: {
          httpGet: {
            port: 8080
            path: '/healthz'
          }
          periodSeconds: 10
        }
        livenessProbe: {
          httpGet: {
            port: 8080
            path: '/healthz'
          }
          initialDelaySeconds: 15
          periodSeconds: 20
        }
        env: union({
          DOTNET_ENVIRONMENT: {
            value: 'Production'
          }
          Bcd__Publisher__IntervalSeconds: {
            value: '${publishIntervalSeconds}'
          }
          Bcd__Sql__UseEntraId: {
            value: '${sqlUseEntraId}'
          }
        }, queueSecretEnv, sqlSecretEnv, userIdentityEnv, userIdentityCaEnv)
        resources: {
          requests: {
            cpu: '0.05'
            memoryInMib: 160
          }
          limits: {
            cpu: '0.5'
            memoryInMib: 384
          }
        }
      }, identityMountOption)
    }
    connections: {
      // Injects CONNECTION_QUEUE_PROVIDER, _QUEUENAME, _HOST, _PORT, _NAMESPACEFQDN,
      // _WORKLOADIDENTITYCLIENTID, _USERNAME and _PASSWORD.
      queue: {
        source: queue.id
      }
      // Read side of the orders the consumer records.
      sql: {
        source: database.id
      }
    }
    platformOptions: platformOptions
  }, identityVolumeOption)
}

// Worker 2: consumes events, archives each as a JSON blob, and records a row in SQL Server.
resource consumer 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'consumer'
  properties: union({
    environment: environment
    application: app.id
    replicas: 1
    containers: {
      consumer: union({
        image: consumerImage
        env: union({
          DOTNET_ENVIRONMENT: {
            value: 'Production'
          }
          Bcd__Sql__UseEntraId: {
            value: '${sqlUseEntraId}'
          }
        }, queueSecretEnv, archiveSecretEnv, sqlSecretEnv)
        resources: {
          requests: {
            cpu: '0.1'
            memoryInMib: 192
          }
          limits: {
            cpu: '1.0'
            memoryInMib: 512
          }
        }
      }, identityMountOption)
    }
    connections: {
      queue: {
        source: queue.id
      }
      // Injects CONNECTION_ARCHIVE_ENDPOINT, _ACCOUNTNAME, _CONTAINERNAME and, where the Recipe
      // emits them, the secret-backed _CONNECTIONSTRING and _ACCOUNTKEY.
      archive: {
        source: archive.id
      }
      // Injects CONNECTION_SQL_HOST, _PORT, _DATABASE, _USERNAME and _PASSWORD.
      sql: {
        source: database.id
      }
    }
    platformOptions: platformOptions
  }, identityVolumeOption)
}

output applicationId string = app.id
output queueId string = queue.id
output archiveId string = archive.id
output databaseId string = database.id
