// Order Management sample app
//
// This file is environment-agnostic. It declares *what* the application needs -- a queue, object
// storage, a SQL database, a PostgreSQL database, and three containers -- and never states *how*
// those are provisioned. The Recipe Pack bound to the target Environment decides whether the queue
// is RabbitMQ or Azure Service Bus, whether object storage is an S3 bucket or Azure Blob Storage, and
// whether the databases are containers or Azure SQL Database and Azure Database for PostgreSQL.
//
// Each service signs in to its databases as its own least-privilege user, never as administrator:
// with its managed identity on Azure, with a password the platform supplies on Azure Local. The
// administrator credentials below are only for the Recipes and the database setup job.
//
// Deployed by scripts/deploy/azure.ps1 (environment oms-azure) and scripts/deploy/azurelocal.ps1
// (environment oms-azurelocal) with the same parameters: image references, the app's sign-in
// settings, and the database administrator passwords.

extension radius
extension portability

@description('Radius Environment ID. Supplied by the rad CLI.')
param environment string

@description('Name of the Radius Application.')
param application string = 'oms'

@description('Container image for the API, which serves the orders API and the browser app.')
param apiImage string

@description('Container image for the order processor.')
param processorImage string

@description('Container image for the inventory service.')
param inventoryImage string

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

@description('''
How the inventory service validates the service tokens its callers present: `Authority`,
`MetadataAddress` (optional) and `Audience`. Entra ID: the inventory app registration. Keycloak:
the realm and the `oms-inventory` audience. Empty disables the check (local runs only).
''')
param inventoryAuthentication object = {}

@description('Scope the API and processor request a token for, to call the inventory service. Entra ID: `api://<client-id>/.default`. Empty where the token carries the audience by default (Keycloak).')
param inventoryScope string = ''

@description('Name of the queue that carries orders from the API to the processor.')
param queueName string = 'orders'

@description('Blob container / bucket that archived order JSON is written to.')
param archiveContainerName string = 'orders'

@description('Name of the application database.')
param databaseName string = 'omsdb'

@description('Name of the inventory database.')
param inventoryDatabaseName string = 'inventory'

@description('''
SQL administrator username required by the Resource Type. Where the Recipe uses another login (the
SQL Server container always uses `sa`) or none at all (Azure SQL with Entra-only authentication),
the Recipe reports or ignores it.
''')
param sqlAdminUsername string = 'omsadmin'

@description('SQL administrator password required by the Resource Type. Ignored where the Recipe uses Entra-only authentication.')
@secure()
param sqlAdminPassword string

@description('PostgreSQL administrator username required by the Resource Type. Ignored where the Recipe uses Entra-only authentication.')
param postgresAdminUsername string = 'pgadmin'

@description('PostgreSQL administrator password required by the Resource Type. Ignored where the Recipe uses Entra-only authentication.')
@secure()
param postgresAdminPassword string

// What every service tells its telemetry and how it reaches the inventory service. The token the
// API and processor present comes from their own identity; the scope says which API it is for.
func serviceEnv(serviceName string) object => {
  DOTNET_ENVIRONMENT: { value: 'Production' }
  OTEL_SERVICE_NAME: { value: serviceName }
}

var inventoryAuthenticationEnv = toObject(
  filter(items(inventoryAuthentication), entry => !empty(string(entry.value))),
  entry => 'InventoryAuth__${entry.key}',
  entry => { value: string(entry.value) }
)

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
resource queue 'Portability.Messaging/messageQueues@2025-08-01-preview' = {
  name: 'orders'
  properties: {
    environment: environment
    application: app.id
    queueName: queueName
    maxDeliveryCount: 10
  }
}

// Portable object storage: Azure Blob Storage on Azure, a bucket in the site's S3 store on Azure Local.
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

// Portable PostgreSQL: Azure Database for PostgreSQL on Azure, a PostgreSQL container on Azure Local.
// Holds the products and stock that only the inventory service reads and writes.
resource inventoryDatabase 'Radius.Data/postgreSqlDatabases@2025-08-01-preview' = {
  name: 'inventorydb'
  properties: {
    environment: environment
    application: app.id
    database: inventoryDatabaseName
    username: postgresAdminUsername
    password: postgresAdminPassword
  }
}

// Each connection injects the connected resource's values as CONNECTION_<NAME>_<PROPERTY>
// variables, plus any credentials its Recipe issued. Identity, image pull credentials and how the
// API is published are decided by the platform's container Recipe, not here.

// Inventory service: owns products and stock. Only the API and the processor call it, each with a
// token from its own identity; no user tokens reach it.
resource inventory 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'inventory'
  properties: {
    environment: environment
    application: app.id
    replicas: 1
    containers: {
      inventory: {
        image: inventoryImage
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
        env: union(serviceEnv('inventory'), {
          POSTGRES_USERNAME: { value: 'inventory' }
        }, inventoryAuthenticationEnv)
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
      inventorydb: {
        source: inventoryDatabase.id
      }
    }
  }
}

var inventoryClientEnv = {
  Inventory__BaseUrl: { value: 'http://${inventory.properties.hosts.inventory}:8080' }
  Inventory__Scope: { value: inventoryScope }
}

// Orders API and browser app: users sign in, place orders, and the API publishes each order to the
// queue. Products, stock and restocking go through the inventory service.
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
        env: union(serviceEnv('api'), {
          SQL_USERNAME: { value: 'api' }
        }, inventoryClientEnv, userIdentityEnv)
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

// The application's only public entry point: users reach the API and browser app. The inventory
// service and the processor have no route, so they stay cluster-internal. How the route is
// published (ingress, host name, certificate) is the platform's decision, in its Recipe Pack.
resource web 'Radius.Compute/routes@2025-08-01-preview' = {
  name: 'web'
  properties: {
    environment: environment
    application: app.id
    kind: 'HTTP'
    rules: [
      {
        matches: [
          {
            httpPath: '/'
          }
        ]
        destinationContainer: {
          resourceId: api.id
          containerName: 'api'
          containerPort: api.properties.containers.api.ports.http.containerPort
        }
      }
    ]
  }
}
// Order processor: consumes orders, reserves their stock, archives each as a JSON blob, and records
// the result in SQL.
resource processor 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'processor'
  properties: {
    environment: environment
    application: app.id
    replicas: 1
    containers: {
      processor: {
        image: processorImage
        env: union(serviceEnv('processor'), {
          SQL_USERNAME: { value: 'processor' }
        }, inventoryClientEnv)
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
output inventoryDatabaseId string = inventoryDatabase.id
output databaseId string = database.id