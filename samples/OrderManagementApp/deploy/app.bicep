// Order Management sample app
//
// This file is environment-agnostic. It declares *what* the application needs -- a queue, object
// storage, a SQL database, and two containers -- and never states *how* those are provisioned. The
// Recipe Pack bound to the target Environment decides whether the queue is RabbitMQ or Azure
// Service Bus, whether object storage is Azurite or Azure Blob Storage, and whether SQL is a
// container or Azure SQL Database.
//
// Deployed by scripts/azure/deploy.ps1 (environment oms-azure) and scripts/azurelocal/deploy.ps1
// (environment oms-azurelocal) with the same parameters: image references, the app's sign-in
// settings, and a SQL password.

extension radius
extension orderManagement

@description('Radius Environment ID. Supplied by the rad CLI.')
param environment string

@description('Name of the Radius Application.')
param application string = 'oms'

@description('Container image for the API, which serves the orders API and the browser app.')
param apiImage string

@description('Container image for the order processor.')
param processorImage string

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

@description('Name of the queue that carries orders from the API to the processor.')
param queueName string = 'orders'

@description('Blob container / bucket that archived order JSON is written to.')
param archiveContainerName string = 'orders'

@description('Name of the application database.')
param databaseName string = 'omsdb'

@description('''
SQL administrator username required by the Resource Type. Where the Recipe uses another login (the
SQL Server container always uses `sa`) or none at all (Azure SQL with Entra-only authentication),
the Recipe reports or ignores it.
''')
param sqlAdminUsername string = 'omsadmin'

@description('SQL administrator password required by the Resource Type. Ignored where the Recipe uses Entra-only authentication.')
@secure()
param sqlAdminPassword string

// The SQL password is a developer input rather than a Recipe output, so it is passed straight
// through. Where the platform gives the pod an Entra workload identity, the application uses that
// for SQL instead and ignores the password.
var sqlPasswordEnv = {
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
  entry => { value: entry.value }
)

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: application
  properties: {
    environment: environment
  }
}

// Portable queue: Azure Service Bus on Azure, a RabbitMQ container on Azure Local.
resource queue 'OrderManagement.Messaging/messageQueues@2025-08-01-preview' = {
  name: 'orders'
  properties: {
    environment: environment
    application: app.id
    queueName: queueName
    maxDeliveryCount: 10
  }
}

// Portable object storage: Azure Blob Storage on Azure, an Azurite container on Azure Local.
resource archive 'Radius.Storage/objectStorage@2025-08-01-preview' = {
  name: 'archive'
  properties: {
    environment: environment
    application: app.id
    containerName: archiveContainerName
  }
}

// Portable relational database: Azure SQL on Azure, a SQL Server container on Azure Local.
resource database 'Radius.Data/sqlServerDatabases@2025-08-01-preview' = {
  name: 'ordersdb'
  properties: {
    environment: environment
    application: app.id
    database: databaseName
    username: sqlAdminUsername
    password: sqlAdminPassword
  }
}

// Each connection injects the connected resource's values as CONNECTION_<NAME>_<PROPERTY>
// variables, plus any credentials its Recipe issued. Identity, image pull credentials and how the
// API is published are decided by the platform's container Recipe, not here.

// Orders API and browser app: users sign in, place orders, and the API publishes each order to the
// queue.
resource api 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'api'
  properties: {
    environment: environment
    application: app.id
    replicas: 1
    containers: {
      api: {
        image: apiImage
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
        }, sqlPasswordEnv, userIdentityEnv)
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
      }
    }
    connections: {
      queue: {
        source: queue.id
      }
      // Read side of the orders the processor records.
      sql: {
        source: database.id
      }
    }
  }
}

// Order processor: consumes orders, archives each as a JSON blob, and records it in SQL Server.
resource processor 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'processor'
  properties: {
    environment: environment
    application: app.id
    replicas: 1
    containers: {
      processor: {
        image: processorImage
        env: union({
          DOTNET_ENVIRONMENT: {
            value: 'Production'
          }
        }, sqlPasswordEnv)
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
      }
    }
    connections: {
      queue: {
        source: queue.id
      }
      archive: {
        source: archive.id
      }
      sql: {
        source: database.id
      }
    }
  }
}

output applicationId string = app.id
output queueId string = queue.id
output archiveId string = archive.id
output databaseId string = database.id