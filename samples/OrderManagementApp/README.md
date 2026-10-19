# Order Management sample

An application written for Azure that moves to **Azure Local** without code changes: the same
application definition and the same container images run on AKS with Azure PaaS services, and on
AKS enabled by Arc on Azure Local, where the app keeps running when the site loses its link to Azure.

Use it as the **template for moving your own app**. The pattern is five steps; this sample is a
worked example of each one.

## What the app does

Users sign in to a browser app and place orders. The **API** publishes each order to a **queue**;
the **processor** archives the order as JSON in **object storage** and records it in **SQL**.

```
Browser ──sign in──► Entra ID (Azure) | Keycloak + Active Directory (Azure Local)
   │
   ▼
 API ──order──► queue ──► processor ──► object storage (order JSON)
   ▲                           └──────► SQL (orders table)
   └──────── "my orders" ◄──────────────┘
```

| Dependency | On Azure | On Azure Local |
|---|---|---|
| Queue | Azure Service Bus | RabbitMQ container |
| Object storage | Azure Blob Storage | Azurite container |
| SQL | Azure SQL Database | SQL Server container |
| User sign-in | Microsoft Entra ID | Keycloak, federated to the site's Active Directory |
| How the app authenticates to services | Entra Workload ID (no secrets) | Keycloak token for the queue; Recipe-issued credentials for storage and SQL |
| Images and Recipes | Azure Container Registry | ACR connected registry inside the cluster |

The Azure Local column runs nothing in Azure at runtime. That is what lets the app keep working when
the site is cut off from Azure.

## Move your app in five steps

### 1. Declare what the app needs, not which Azure service

Replace Azure resource types in your app's Bicep with portable [Radius](https://docs.radapp.io)
resource types, and connect your containers to them.

```bicep
// Before: tied to Azure
resource bus     'Microsoft.ServiceBus/namespaces@2022-10-01-preview' = { ... }
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = { ... }
resource server  'Microsoft.Sql/servers@2023-08-01-preview' = { ... }

// After: portable (deploy/app.bicep)
resource queue    'OrderManagement.Messaging/messageQueues@2025-08-01-preview' = { ... }
resource archive  'Radius.Storage/objectStorage@2025-08-01-preview'               = { ... }
resource database 'Radius.Data/sqlServerDatabases@2025-08-01-preview'             = { ... }

resource processor 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'processor'
  properties: {
    containers: { processor: { image: processorImage } }
    connections: {
      queue:   { source: queue.id }
      archive: { source: archive.id }
      sql:     { source: database.id }
    }
  }
}
```

Object storage and SQL use Radius's built-in types. Radius has no queue type that covers both
Service Bus and RabbitMQ, so the sample defines one in
[deploy/types/messageQueues.yaml](./deploy/types/messageQueues.yaml).

Result: [deploy/app.bicep](./deploy/app.bicep) is identical on both platforms. Its only parameters
are the image references, the sign-in settings and a SQL password.

### 2. Let the code read its connections

Each connection injects the connected resource's values as environment variables named
`CONNECTION_<connection>_<property>`, for example `CONNECTION_QUEUE_PROVIDER` and
`CONNECTION_QUEUE_ENDPOINT`. The code reads those instead of hard-coding a service, and picks its
client in one place,
[ServiceCollectionExtensions.cs](./src/OrderManagement.Shared/DependencyInjection/ServiceCollectionExtensions.cs):

```csharp
return options.Provider switch
{
    QueueProvider.ServiceBus => new ServiceBusMessageBroker(...),
    QueueProvider.RabbitMq   => new RabbitMqMessageBroker(...),
};
```

Everything else in the app sees only `IMessagePublisher` / `IMessageSubscriber`. Storage and SQL
follow the same rule: a connection string or password means the on-site container, none means
managed identity.

Sign-in stays an ordinary Entra app: MSAL.js in the browser and Microsoft.Identity.Web in the API.
On Azure Local, Keycloak is configured to issue Entra-shaped tokens, so only settings differ:

| Setting | Entra ID | Keycloak |
|---|---|---|
| API `AzureAd` section | `Instance`, `TenantId`, `ClientId` | `Authority`, `MetadataAddress`, `ClientId`, `Audience` |
| Browser `ProtocolMode` | `AAD` | `OIDC` (plus `KnownAuthorities`) |
| Roles `Orders.Read` / `Orders.Create` | app roles assigned to groups | realm roles mapped from AD groups |

### 3. Write one Recipe per resource for each platform

A Recipe is a Bicep template Radius runs to create a resource. It returns the values that become
the `CONNECTION_*` variables, so both Recipes for a resource must return the same names.

| Resource | Azure Recipe | Azure Local Recipe |
|---|---|---|
| Queue | [servicebus-queue.bicep](./deploy/recipes/azure/servicebus-queue.bicep) | [rabbitmq-queue.bicep](./deploy/recipes/azurelocal/rabbitmq-queue.bicep) |
| Object storage | [blob-objectstorage.bicep](./deploy/recipes/azure/blob-objectstorage.bicep) | [azurite-objectstorage.bicep](./deploy/recipes/azurelocal/azurite-objectstorage.bicep) |
| SQL | [azuresql-database.bicep](./deploy/recipes/azure/azuresql-database.bicep) | [mssql-database.bicep](./deploy/recipes/azurelocal/mssql-database.bicep) |
| Containers | [containers.bicep](./deploy/recipes/kubernetes/containers.bicep) (shared) | same |

### 4. Bind them per platform with a Recipe Pack and an Environment

A **Recipe Pack** says which Recipe serves each resource type, and carries every setting that
differs between platforms. An **Environment** is a deployment target that points at one pack.

| | [Azure pack](./deploy/recipe-packs/azure.bicep) | [Azure Local pack](./deploy/recipe-packs/azurelocal.bicep) |
|---|---|---|
| Recipes from | your ACR | the connected registry in the cluster |
| Pod identity | service account + Entra Workload ID label | service account + Keycloak token and CA |
| Image pulls | AcrPull on the cluster | image pull secret |
| Environment | [azure.bicep](./deploy/environments/azure.bicep): also names the subscription and resource group for PaaS resources | [azurelocal.bicep](./deploy/environments/azurelocal.bicep): no Azure settings |

### 5. Deploy the same app to either environment

```powershell
rad deploy deploy/app.bicep -e oms-azure      -p apiImage=... -p processorImage=... -p sqlAdminPassword=...
rad deploy deploy/app.bicep -e oms-azurelocal -p apiImage=... -p processorImage=... -p sqlAdminPassword=...
```

Same file, same parameters. The environment decides what gets created. Also pass `apiAuthentication`
and `spaSettings`, the sign-in settings from step 2 for that platform's identity provider.

## What Azure Local has to provide

These are platform prerequisites, set up once per site, not part of your app.

| Need | Why | In this sample |
|---|---|---|
| AKS enabled by Arc, with Radius installed | runs the app and the Recipes | `az aksarc create`; Radius installed from the local registry |
| A registry the cluster can pull from without Azure | pods restarted during an outage must find their images, and Radius its Recipes | ACR (Premium) + **ACR connected registry** inside the cluster |
| An identity provider on site | sign-in and service tokens without Entra | **Keycloak**, federated to Active Directory over LDAPS and trusting the cluster's token issuer |
| Active Directory | users and groups | the domain the Azure Local instance already uses; Keycloak needs a read-only bind account |
| Ingress | users reach the app over HTTPS | Arc load balancer + NGINX ingress |

On Azure the equivalents are AKS with workload identity, ACR, a managed identity with a federated
credential, and Entra app registrations; [deploy/infra/main.bicep](./deploy/infra/main.bicep) creates
most of them.

**When the site loses its link to Azure:** running pods, pod restarts, token exchange, directory
lookups and `kubectl` with the admin kubeconfig keep working. Pushing new images, Azure management of
the cluster and Entra sign-in to the cluster do not.

[docs/workload-identity.md](./docs/workload-identity.md) explains how the app authenticates without
secrets on each platform.

## Deploy it by hand

With the prerequisites in place, deploying is only Radius commands. For Azure Local:

```powershell
# One-time: workspace, resource group, the queue resource type
rad workspace create kubernetes oms-azurelocal --context <kube-context> --group oms
rad resource-type create messageQueues -f deploy/types/messageQueues.yaml
rad bicep publish-extension -f deploy/types/messageQueues.yaml --target deploy/types/orderManagement.tgz
rad env create bootstrap --group oms      # scratch environment to deploy the pack and environment from

# Publish the Recipes, then bind them for this platform
./scripts/publish-recipes.ps1 -Registry <acr>.azurecr.io -Set azurelocal
rad deploy deploy/recipe-packs/azurelocal.bicep -e bootstrap -p registry=<in-cluster registry> ...
rad deploy deploy/environments/azurelocal.bicep -e bootstrap

# The app
rad deploy deploy/app.bicep -e oms-azurelocal -p apiImage=... -p processorImage=... -p sqlAdminPassword=...
```

For Azure, use `recipe-packs/azure.bicep` and `environments/azure.bicep` instead. When Recipes come
from a private registry (always on Azure Local), Radius also needs pull credentials: see
[deploy/registry-auth.bicep](./deploy/registry-auth.bicep).

## Optional: the automation we used

The [scripts/](./scripts) folder is how we built and deployed our own Azure and Azure Local test
sites from nothing. You do not need it to follow the pattern above; use it if you want the same
end-to-end setup.

| Command | When | What it runs |
|---|---|---|
| `./scripts/setup-platform.ps1 -Target Azure` or `AzureLocal` | once per site | the prerequisite steps in `scripts/azure/` or `scripts/azurelocal/` |
| `./scripts/deploy.ps1 -Target Azure` or `AzureLocal` | every release | build and push images, publish Recipes, the `rad` steps above |

Both read site values from `scripts/settings.json`; copy it from
[settings.example.json](./scripts/settings.example.json). Each script documents itself:
`Get-Help ./scripts/<path>.ps1 -Full`. `./scripts/azurelocal/diagnose.ps1` checks an Azure Local
deployment layer by layer.

[lab/azurelocal/ad-setup.ps1](./lab/azurelocal/ad-setup.ps1) prepares a lab domain controller
(demo OU, groups, bind account and demo user). A real site already has these; Keycloak only needs a
bind account in the Secret `oms-ad-bind` (`bind-upn`, `bind-password`) and the directory's CA in
`oms-ad-ca` (`ca.crt`).

## Repository layout

```
├── src/                         application code (.NET)
│   ├── OrderManagement.Api/        orders API and browser app
│   ├── OrderManagement.Processor/  order processor
│   └── OrderManagement.Shared/     connections, identity, queue/storage/SQL clients
├── deploy/                      what to deploy (Bicep)
│   ├── app.bicep                   the application, same on both platforms
│   ├── types/                      the portable queue type
│   ├── recipes/                    azure/, azurelocal/, kubernetes/ (shared)
│   ├── recipe-packs/               one per platform
│   ├── environments/               one per platform
│   ├── registry-auth.bicep         Radius credentials for a private Recipe registry
│   └── infra/                      Azure platform (AKS, ACR, identities)
├── docker/                      Dockerfiles for the API and processor
├── docs/                        workload identity explained
├── scripts/                     optional automation (see above)
└── lab/                         lab-only domain controller setup
```

## Configuration reference

Radius injects these into the API and the processor from their connections. The same names work in
`appsettings.json` as `OrderManagement:<connection>:<property>`.

| Variable | Used by | Notes |
|---|---|---|
| `CONNECTION_QUEUE_PROVIDER` | both | `servicebus` or `rabbitmq` |
| `CONNECTION_QUEUE_QUEUENAME` | both | queue name |
| `CONNECTION_QUEUE_ENDPOINT` | both | Service Bus namespace host name, or `host:port` for RabbitMQ |
| `CONNECTION_QUEUE_OAUTH*` | both | Azure Local: Keycloak token endpoint, client and token file |
| `CONNECTION_QUEUE_USERNAME` / `_PASSWORD` | both | only when the queue Recipe issues credentials |
| `CONNECTION_ARCHIVE_ENDPOINT` / `_CONTAINERNAME` | processor | blob endpoint and container |
| `CONNECTION_ARCHIVE_CONNECTIONSTRING` | processor | Azure Local (Azurite) only |
| `CONNECTION_SQL_HOST` / `_PORT` / `_DATABASE` | both | |
| `CONNECTION_SQL_USERNAME` / `_PASSWORD` | both | ignored when the pod has an Entra workload identity |

## Known gaps

- The sample ships its own build of the stock Kubernetes container Recipe
  ([containers.bicep](./deploy/recipes/kubernetes/containers.bicep)) so the platform can set service
  accounts, pull secrets, identity tokens and ingress. Upstream support is tracked in
  radius-project/resource-types-contrib#143.
- The Azure SQL Recipe allows access from all Azure services. Use a private endpoint for production.
- Radius 0.60 cannot delete the role assignments the Azure Recipes create, so deleting the app on
  Azure leaves Radius retrying. Delete the Azure resource group directly.
- `InvariantGlobalization` must stay `false`: `Microsoft.Data.SqlClient` requires ICU.
