# Move your app in five steps

The Order Management App is a worked example of each step. Paths are relative to the sample
folder, [samples/OrderManagementApp](../).

## 1. Declare what the app needs, not which Azure service

Replace Azure resource types in your app's Bicep with portable [Radius](https://docs.radapp.io)
resource types, and connect your containers to them.

```bicep
// Before: tied to Azure
resource bus     'Microsoft.ServiceBus/namespaces@2022-10-01-preview' = { ... }
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = { ... }
resource server  'Microsoft.Sql/servers@2023-08-01-preview' = { ... }

// After: portable (deploy/app.bicep)
resource queue    'Portability.Messaging/messageQueues@2025-08-01-preview' = { ... }
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
Service Bus and RabbitMQ, so the library defines one in
[recipes/message-queue/messageQueues.yaml](../../../recipes/message-queue/messageQueues.yaml).

Result: [deploy/app.bicep](../deploy/app.bicep) is identical on both platforms. Its only parameters
are the image references, the sign-in settings and a SQL password.

## 2. Let the code read its connections

Each connection injects the connected resource's values as environment variables named
`CONNECTION_<connection>_<property>`, for example `CONNECTION_QUEUE_PROVIDER` and
`CONNECTION_QUEUE_ENDPOINT`. The code reads those instead of hard-coding a service, and picks its
client in one place,
[ServiceCollectionExtensions.cs](../src/OrderManagement.Shared/DependencyInjection/ServiceCollectionExtensions.cs):

```csharp
return options.Provider switch
{
    QueueProvider.ServiceBus => new ServiceBusMessageBroker(...),
    QueueProvider.RabbitMq   => new RabbitMqMessageBroker(...),
};
```

Everything else in the app sees only `IMessageQueue`. Storage and SQL work
the same way; [How authentication works](./authentication.md#workloads) shows how each picks its
credential. [compose.yaml](../compose.yaml) sets the same variables to run the app locally.

Sign-in stays an ordinary Entra app: MSAL.js in the browser and Microsoft.Identity.Web in the API.
On Azure Local, Keycloak issues tokens shaped like Entra's, so only settings change.

## 3. Write one Recipe per resource for each platform

A Recipe is a Bicep template Radius runs to create a resource. It returns the values that become
the `CONNECTION_*` variables, so both Recipes for a resource must return the same names. The
Recipes are shared by the library, in [recipes/](../../../recipes/) at the repository root; this
sample uses them as they are.

| Resource | Azure Recipe | Azure Local Recipe |
|---|---|---|
| Queue | [servicebus-queue.bicep](../../../recipes/message-queue/azure/service-bus/servicebus-queue.bicep) | [rabbitmq-cluster-operator/rabbitmq-queue.bicep](../../../recipes/message-queue/azure-local/rabbitmq-cluster-operator/rabbitmq-queue.bicep), or [rabbitmq/rabbitmq-queue.bicep](../../../recipes/message-queue/azure-local/rabbitmq/rabbitmq-queue.bicep) |
| Object storage | [blob-objectstorage.bicep](../../../recipes/object-storage/azure/blob-storage/blob-objectstorage.bicep) | [seaweedfs-objectstorage.bicep](../../../recipes/object-storage/azure-local/seaweedfs/seaweedfs-objectstorage.bicep) |
| SQL | [azuresql-database.bicep](../../../recipes/sql-database/azure/azure-sql/azuresql-database.bicep) | [mssql-database.bicep](../../../recipes/sql-database/azure-local/sql-server/mssql-database.bicep) |
| PostgreSQL | [postgres-flexible-database.bicep](../../../recipes/postgresql-database/azure/flexible-server/postgres-flexible-database.bicep) | [cloudnative-pg/postgres-database.bicep](../../../recipes/postgresql-database/azure-local/cloudnative-pg/postgres-database.bicep), or [postgres/postgres-database.bicep](../../../recipes/postgresql-database/azure-local/postgres/postgres-database.bicep) |
| Containers | [kubernetes-containers.bicep](../../../recipes/kubernetes/kubernetes-containers.bicep) (shared) | same |
| Routes (what users reach) | [kubernetes-routes.bicep](../../../recipes/kubernetes/kubernetes-routes.bicep) (shared): an Ingress for the platform's ingress class | same |

A container is only reachable from outside the cluster through a route the app declares. In this
sample that's one route, `web`, from `/` to the API; the inventory service and the processor have
none. The Recipe Pack decides how routes are published: ingress class, host name, certificate.

On Azure a Recipe asks the cloud for a managed service, which keeps replicas, fails over and backs
up. On Azure Local the queue and PostgreSQL Recipes do the same with an operator the platform
installed once: they declare a RabbitMQ cluster or a CloudNativePG PostgreSQL cluster, and the
operator runs it. See [Operators on Azure Local](../infra/azurelocal/operators/README.md). A site
that doesn't need that sets `Availability` to `standard`, and the Azure Local pack picks the
[rabbitmq](../../../recipes/message-queue/azure-local/rabbitmq/) and
[postgres](../../../recipes/postgresql-database/azure-local/postgres/) Recipes instead: one container
each, from the official images, returning the same values. Two Recipes for one resource on one
platform is the same idea as one per platform, so the app doesn't change.

## 4. Bind them per platform with a Recipe Pack and an Environment

A **Recipe Pack** says which Recipe serves each resource type, and carries every setting that
differs between platforms. An **Environment** is a deployment target that points at one pack.

| | [Azure pack](../../../recipe-packs/azure.bicep) | [Azure Local pack](../../../recipe-packs/azure-local.bicep) |
|---|---|---|
| Recipes from | your ACR | the connected registry in the cluster |
| Pod identity | service account + Entra Workload ID label | service account + Keycloak token and CA |
| Image pulls | AcrPull on the cluster | image pull secret |
| Environment | [azure.bicep](../deploy/environments/azure.bicep): also names the subscription and resource group for PaaS resources | [azurelocal.bicep](../deploy/environments/azurelocal.bicep): no Azure settings |

## 5. Deploy the same app to either environment

```powershell
rad deploy deploy/app.bicep -e oms-azure      -p apiImage=... -p processorImage=... -p sqlAdminPassword=...
rad deploy deploy/app.bicep -e oms-azurelocal -p apiImage=... -p processorImage=... -p sqlAdminPassword=...
```

Same file, same parameters. The environment decides what gets created. Also pass `apiAuthentication`
and `spaSettings`, the sign-in settings for that platform's identity provider. The full sequence,
including the Recipe Pack, environment and registry credentials, is in
[scripts/deploy/azurelocal.ps1](../scripts/deploy/azurelocal.ps1) and
[scripts/deploy/azure.ps1](../scripts/deploy/azure.ps1).
