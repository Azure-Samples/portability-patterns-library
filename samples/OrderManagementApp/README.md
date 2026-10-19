# Order Management sample

A Radius sample showing one application definition and one set of container images deploying
unchanged to AKS with Azure PaaS backing services and to Azure Local (AKS enabled by Arc), where the
app keeps running when the site loses its link to Azure — with the platform, not the application,
deciding what backs each dependency.

## What it does

Users sign in to a browser app, pick products and place orders. The API publishes each order to a
queue; the processor archives the order JSON to object storage, then records it in SQL Server.

```
Browser (MSAL.js) ──sign in──► Entra ID  |  Keycloak + AD (Azure Local)
      │ access token (aud, scp=access_as_user, roles)
      ▼
┌──────────────┐  OrderPlaced  ┌──────────┐               ┌─────────────┐
│ Orders API + │ ────────────► │  Queue   │ ────────────► │  Processor  │
│ browser app  │               │          │               │             │
└──────────────┘               └──────────┘               └──────┬──────┘
      ▲                                                          │
      │                                ┌─────────────────────────┴─────────┐
      │                                ▼                                   ▼
      │                        ┌───────────────┐                 ┌──────────────────┐
      │                        │ Object storage│                 │   SQL Server     │
      │                        │  (JSON blob)  │                 │   (dbo.Orders)   │
      │                        └───────────────┘                 └────────┬─────────┘
      └──────────── GET /api/orders (the user's own orders) ◄─────────────┘
```

The processor writes the blob (`<date>/<id>.json`) first, so every row references an archive that
exists; the SQL write is a `MERGE`, so redelivery never duplicates. The page polls until the order
shows as *Processed*.

The code is written as an ordinary Entra app; nothing in it knows about Keycloak. On Azure Local the
platform makes Keycloak issue Entra-shaped tokens, so only configuration differs:

| Setting | Entra ID | Keycloak (Azure Local) |
|---|---|---|
| API `AzureAd` section | `Instance`, `TenantId`, `ClientId` | `Authority`, `MetadataAddress`, `ClientId`, `Audience` |
| SPA `ProtocolMode` | `AAD` | `OIDC` (plus `KnownAuthorities`) |
| `Orders.Read` / `Orders.Create` | app roles assigned to groups | realm roles mapped from AD groups `oms-app-readers` / `oms-app-writers` |
| Scope | `api://<api>/access_as_user` | `api://oms-api/access_as_user` |

| Endpoint | Requires |
|---|---|
| `GET /api/me`, `GET /api/products` | signed in, scope `access_as_user` |
| `GET /api/orders`, `GET /api/orders/{id}` | `Orders.Read` or `Orders.Create`; only the caller's own orders |
| `POST /api/orders` | `Orders.Create`; prices come from the server catalog, never the client |

The browser app is plain HTML/JS with the MSAL.js 4.30 browser bundle vendored under
`src/OrderManagement.Api/wwwroot/lib`, so building the image needs no Node.js and no internet.

## Same app, different infrastructure

[`deploy/app.bicep`](./deploy/app.bicep) never names RabbitMQ, Service Bus, Azurite or Azure SQL. It
declares three abstract dependencies:

```bicep
resource queue    'OrderManagement.Messaging/messageQueues@2025-08-01-preview' = { ... }
resource archive  'Radius.Storage/objectStorage@2025-08-01-preview'               = { ... }
resource database 'Radius.Data/sqlServerDatabases@2025-08-01-preview'             = { ... }
```

A **Recipe** binds each Resource Type to real infrastructure, a **Recipe Pack** groups them, and an
**Environment** references a Recipe Pack. Changing environment changes the infrastructure without
touching application code or Bicep:

| Resource Type | `oms-azure` (AKS) | `oms-azurelocal` (AKS enabled by Arc) |
|---|---|---|
| `messageQueues` | **Azure Service Bus** | RabbitMQ container |
| `objectStorage` | **Azure Blob Storage** | Azurite container |
| `sqlServerDatabases` | **Azure SQL** (Entra-only) | SQL Server container |
| Workload identity | **Entra Workload ID** | Keycloak federated to the cluster's token issuer (queue) |
| Images and Recipes | ACR | ACR connected registry inside the cluster |

The Azure Local column is not a lesser second. That site has to keep running when its link to Azure
drops, so nothing the app needs at runtime may live in Azure: no PaaS data service, no Entra, no
cloud registry. The Recipes absorb that platform fact — which is the point.

`OrderManagement.Messaging/messageQueues` is user-defined
([schema](./deploy/types/messageQueues.yaml)) because the built-in `Radius.Messaging/rabbitMQ` is
broker-specific and cannot represent Service Bus. Object storage and SQL use built-in portable types.

## How the application adapts

Radius injects `CONNECTION_<NAME>_<PROPERTY>` variables per connected resource.
[`ServiceCollectionExtensions`](./src/OrderManagement.Shared/DependencyInjection/ServiceCollectionExtensions.cs)
is the only place that branches on them:

```csharp
return options.Provider switch
{
    QueueProvider.ServiceBus => new ServiceBusMessageBroker(...),
    QueueProvider.RabbitMq   => new RabbitMqMessageBroker(...),
};
```

The API and the processor only ever see `IMessagePublisher` / `IMessageSubscriber`. Storage follows the same rule:
a connection string means Azurite, an endpoint alone means managed identity.

On Azure no keys exist at all — the Recipes set `disableLocalAuth` and `allowSharedKeyAccess: false`
and grant data-plane roles to a user-assigned identity, which the API and processor reach through a federated
credential trusting the AKS OIDC issuer for one service account subject.

## Repository layout

```
├── src/
│   ├── OrderManagement.Shared/     Provider abstractions, CONNECTION_* binding, identity
│   ├── OrderManagement.Api/        Orders API and browser app; publishes orders
│   └── OrderManagement.Processor/  Archives orders to blob, records them in SQL
├── deploy/
│   ├── app.bicep           Environment-agnostic application definition
│   ├── registry-auth.bicep Private registry credentials for Recipe pulls
│   ├── infra/              Resource group, ACR, AKS, managed identity + FIC
│   ├── types/              User-defined Resource Type for the queue
│   ├── recipes/            azure/ azurelocal/ kubernetes/
│   ├── recipe-packs/       Bind Resource Types to Recipes per environment
│   └── environments/       oms-azure, oms-azurelocal
├── scripts/
│   ├── setup-platform.ps1  Once per site (platform team): cluster, ingress, sign-in, offline registry
│   ├── deploy.ps1          Every release (app team): images, Recipes, rad deploy
│   ├── settings.example.json  Per-target values; copy to settings.json (gitignored)
│   ├── azure/, azurelocal/ The steps the two commands run, one script per step
│   ├── lib/                Settings loader shared by the two commands
│   └── publish-recipes.ps1 Compile and push Recipes to an OCI registry
├── lab/                    NOT part of the sample: stands up what a customer already has
│   └── azurelocal/         ad-setup.ps1: demo OU, groups and accounts on the site's existing DC
└── docker/                 Dockerfiles for the API and the processor
```

Every script carries its own `.SYNOPSIS`/`.DESCRIPTION` with the environment-specific detail; run
`Get-Help ./scripts/<path>.ps1 -Full` rather than looking for it here.

## Two commands, two roles

| Who | Command | When |
|---|---|---|
| Platform team | `./scripts/setup-platform.ps1 -Target Azure` or `AzureLocal` | once per site |
| Application team | `./scripts/deploy.ps1 -Target Azure` or `AzureLocal` | every release |

The application is the same for both targets: same `deploy/app.bicep`, same images. Only the
platform setup differs, and on Azure Local that setup is also what keeps the app running when the
link to Azure drops. Site-specific values (subscription, registry, addresses) live in
`scripts/settings.json`; start from [settings.example.json](./scripts/settings.example.json).
`setup-platform.ps1 -WhatIf` shows each step and the arguments it would get.

---

# Deploying

| Tool | Needed for |
|---|---|
| .NET 9 SDK, podman or Docker, kubectl | everything |
| [Radius CLI](https://docs.radapp.io/getting-started/) 0.60+ | everything |
| Azure CLI + [kubelogin](https://azure.github.io/kubelogin/install.html) | Azure |
| Azure CLI with the `aksarc`, `connectedk8s` and `k8s-extension` extensions | Azure Local |

## Option 1 — Azure (AKS with Azure PaaS)

Azure access is split across two identities, and conflating them causes most of the confusion:

| | Radius control plane → Azure | App → Azure |
|---|---|---|
| Who | `applications-rp`, `bicep-de`, `ucp`, `dynamic-rp` | `api`, `processor` |
| Does | *provisions* Service Bus, Storage, SQL | *calls* them at runtime |
| Identity | `bcd-radius-identity`, 4 federated credentials | `bcd-workload-identity`, 1 |

Neither uses a client secret. Both are created by
[provision-infra.ps1](./scripts/azure/provision-infra.ps1), which also disables local cluster
accounts in favour of Entra ID + Azure RBAC.

```powershell
az login
Copy-Item scripts/settings.example.json scripts/settings.json   # then fill in the Azure section

./scripts/setup-platform.ps1 -Target Azure   # cluster, ingress, Entra app registrations
./scripts/deploy.ps1 -Target Azure
```

`setup-platform.ps1` runs three steps. *Cluster* creates the platform and prints the workload
identity IDs that `Deploy` needs in the settings. *Ingress* gives the app a public HTTPS address;
set `PrivateCa` where policy blocks inbound internet traffic, so Let's Encrypt cannot validate, and
then `IngressCertIssuer: bcd-private-ca` under `Deploy`. *Identity* registers the API and browser
app with Entra; set `ServiceManagementReference` if your tenant's policy requires one on new app
registrations.

`deploy.ps1` mints a short-lived, read-only registry token for Recipe pulls itself, builds with
podman or docker, and publishes the orders app through the ingress when
`provision-ingress.ps1` has run (add `-IngressCertIssuer bcd-private-ca` with `-PrivateCa`). Use
`-SqlLocation` when the region refuses new SQL servers, and a distinct `-ResourceGroup` (Radius
group) when another deployment in the subscription already uses `oms`, since Recipe resource names
derive from it (both under `Deploy` in the settings). Already have a cluster? Run
[bootstrap-identity.ps1](./scripts/azure/bootstrap-identity.ps1), then
`setup-platform.ps1 -Target Azure -Skip Cluster`.

Clean up with `az group delete --name bcd-infra --yes --no-wait`, then
`rad workspace delete oms-azure --yes`.

Worth knowing: "resource group" means three different things here — the Azure platform group
(`-ResourceGroup`), the Azure group the Recipes provision into (`-AppInfraResourceGroup`), and the
Radius control-plane scope, which is not an Azure group at all despite the identical flag name.

## Option 2 — Azure Local (AKS enabled by Arc)

A connected Azure Local instance *could* reach Azure PaaS, but the workload is built to keep running
if the link drops. So the backing services are in-cluster RabbitMQ, SQL Server and Azurite, and
identity comes from Keycloak bound to the site's existing Active Directory (`DC01`). Everything
the demo creates lives in the `bcd-azurelocal` resource group, apart from the Azure Local instance.

Images and Recipes are pushed to a Premium ACR in Azure, and an **ACR connected registry** (Arc extension, ReadOnly) inside the cluster syncs them and serves
every pull on a fixed ClusterIP (`10.96.0.50`). A pod restarted while Azure is unreachable still
finds its image, and Radius still finds its Recipes.

| Concern | Here |
|---|---|
| Cluster | AKS Arc `bcd-aksarc`, 1 control plane + 2 `Standard_A4_v2`, lnet `bcd-aks-lnet` |
| Registry | push `<acr-name>.azurecr.io`, pull `10.96.0.50` (connected registry) |
| Cluster access | `--admin` kubeconfig (client certificate, works offline); Entra group `azurelocal-aks-admins` when connected |
| Token issuer | the cluster's default in-cluster issuer; Keycloak runs in the same cluster, so it resolves |
| Directory | existing `DC01` (`azurelocal.lab`): AD CS + LDAPS, OU `OMS`, bind and demo accounts added |

Without Entra, the API and processor still hold no secret for the queue: each presents its projected
ServiceAccount token to Keycloak, which trusts the cluster's issuer and returns a short-lived token
RabbitMQ accepts. [docs/workload-identity.md](./docs/workload-identity.md) walks through both
environments side by side.

```powershell
# Lab only: directory objects on the existing DC01 (OU OMS, oms-app-* groups, demo user) and the
# Keycloak bind account Secret. A customer's AD already has users and groups; it needs only a bind
# account. Elevated; prompts for AZURELOCAL\Administrator; leaves DC01's network settings alone.
./lab/azurelocal/ad-setup.ps1 -VmName DC01 -DomainName azurelocal.lab -NetbiosName AZURELOCAL `
    -KubeContext bcd-aksarc

./scripts/setup-platform.ps1 -Target AzureLocal
./scripts/deploy.ps1 -Target AzureLocal
```

`setup-platform.ps1 -Target AzureLocal` runs, in order:

| Step | What it gives the site |
|---|---|
| Cluster | resource group, Premium ACR, Entra admin group, AKS lnet and AKS Arc cluster |
| Images | Radius, backing-service, Keycloak, ingress and .NET base images mirrored into the ACR |
| Registry | connected registry in the cluster, pull secrets and registry CA: pulls keep working offline |
| Keycloak | token issuer on site, federated to DC01 over LDAPS, trusting the in-cluster issuer |
| Ingress | Arc load balancer (MetalLB, .200-.210), ingress-nginx from the connected registry, site CA certificate for https://192.168.44.200 |
| Identity | orders app registered with Keycloak: API audience, browser client, scope, AD group -> role mapping |

`deploy.ps1` builds with podman or docker, publishes images and Recipes, waits for the connected
registry to sync, installs Radius and deploys.

Open the orders app at <https://192.168.44.200>. Machines outside the domain trust the site CA and
the Keycloak issuing CA once, with the `Import-Certificate` commands the Ingress step prints.
Sign in as an AD user: members
of `oms-app-readers` can view, members of `oms-app-writers` can also place orders. The Recipe Pack,
not `app.bicep`, decides that containers with ports are published through the ingress.

When something is slow or failing, `./scripts/azurelocal/diagnose.ps1` checks each layer read-only:
cluster and nodes, connected registry sync, the CA Radius trusts, Keycloak and the app pods. Add
`-IncludeNodeBootstrap` while the cluster is still creating to see each node VM's first-boot
progress over SSH. To replace a leaked SQL password, run
`./scripts/deploy.ps1 -Target AzureLocal -SkipImageBuild -SkipRadiusInstall -RotateSqlPassword`.

What survives losing the Azure link: running pods, pod restarts and rescheduling (connected
registry), token exchange (Keycloak and the cluster issuer), directory lookups (DC01), and `kubectl`
with the admin kubeconfig. What does not: pushing new images or Recipes, Arc/ARM management of the
cluster, and Entra sign-in to the cluster.

To prove it, block the site's outbound route to Azure (for example at its firewall), then sign in and
place an order.

## Adding another environment

1. Write a Recipe per Resource Type.
2. `./scripts/publish-recipes.ps1 -Registry <registry> -Set <set>`
3. Create a Recipe Pack referencing those Recipes, and an Environment referencing the pack.
4. `rad deploy deploy/app.bicep -e <new-environment>`

## Configuration reference

The API and the processor read these, whether injected by Radius or set in `appsettings.json`:

| Variable | Consumed by | Notes |
|---|---|---|
| `CONNECTION_QUEUE_PROVIDER` | both | `rabbitmq` or `servicebus` |
| `CONNECTION_QUEUE_QUEUENAME` | both | Queue / entity name |
| `CONNECTION_QUEUE_HOST` / `_PORT` | both | RabbitMQ only |
| `CONNECTION_QUEUE_USERNAME` / `_PASSWORD` | both | RabbitMQ only, secret-backed |
| `CONNECTION_QUEUE_NAMESPACEFQDN` | both | Service Bus only |
| `CONNECTION_ARCHIVE_ENDPOINT` | processor | Blob endpoint; triggers managed identity |
| `CONNECTION_ARCHIVE_CONNECTIONSTRING` | processor | Azure Local only (Azurite); takes precedence |
| `CONNECTION_ARCHIVE_CONTAINERNAME` | processor | Blob container |
| `CONNECTION_SQL_HOST` / `_PORT` / `_DATABASE` | both | |
| `CONNECTION_SQL_USERNAME` / `_PASSWORD` | both | Omit password to force Entra ID |
| `OrderManagement__Sql__UseEntraId` | both | Forces Entra ID even when a password exists |

## Known gaps

- **Workload Identity on AKS is not verified end to end.** `app.bicep` passes `serviceAccountName`
  through `platformOptions.kubernetes`, but the stock container Recipe ignores it and does not set
  the `azure.workload.identity/use` pod label. Patch the deployment after deploying, or extend the
  Recipe.
- The Azure SQL Recipe opens `AllowAllWindowsAzureIps`. Use a Private Endpoint for anything real.
- `InvariantGlobalization` must stay `false` — `Microsoft.Data.SqlClient` requires ICU.
- The Azure Local cluster has no metrics-server, so the stock Recipe's HorizontalPodAutoscaler logs
  harmless `FailedGetResourceMetric` warnings.
