# Portability Patterns Library
The portability patterns library provides reusable application patterns, reference implementations, and guidance for building workloads that can operate consistently across Azure cloud, sovereign environments, and Azure Local. It supports business continuity by helping teams design adaptive applications that can be deployed, moved, or recovered across environments while minimizing dependencies on location-specific services.

Note: These resources are provided solely as reference and sample implementations and should not be used for production workloads.

## Getting started

Start with the [Order Management sample](./samples/OrderManagementApp/README.md) for
prerequisites, build instructions, deployment options, configuration, and known gaps.
The sample's file paths and commands are relative to
[`samples/OrderManagementApp`](./samples/OrderManagementApp).

## Contributing and support

- See [CONTRIBUTING.md](./CONTRIBUTING.md) for contribution instructions and the
  Contributor License Agreement requirement.
- Participation is governed by the [Microsoft Open Source Code of Conduct](./CODE_OF_CONDUCT.md).
- See [SUPPORT.md](./SUPPORT.md) for questions, bug reports, and feature requests.
- Report security vulnerabilities privately as described in [SECURITY.md](./SECURITY.md),
  not through public GitHub issues.

## License and third-party materials

This project is licensed under the [MIT License](./LICENSE.txt).
Third-party materials remain subject to their respective licenses and terms:

- The Order Management sample includes the Microsoft Authentication Library for
  JavaScript (MSAL.js) browser bundle under
  [`wwwroot/lib/msal-browser`](./samples/OrderManagementApp/src/Bcd.Publisher/wwwroot/lib/msal-browser).
  Its [MIT license](./samples/OrderManagementApp/src/Bcd.Publisher/wwwroot/lib/msal-browser/LICENSE)
  is included alongside the bundle.
- NuGet dependencies, including Azure SDK libraries, Microsoft.Identity.Web,
  Dapper, Microsoft.Data.SqlClient, and RabbitMQ.Client, are referenced by the
  sample's project files and restored during the build. Refer to each package
  for its license and notices.
- Architecture diagrams include Microsoft and third-party product icons.
  Their sources and usage terms are described in the
  [diagram documentation](./samples/OrderManagementApp/docs/diagrams/README.md#icons).
- Deployment definitions use external tools and container images, including
  Radius, Kubernetes, RabbitMQ, Azurite, SQL Server, and Keycloak. These components
  have their own licenses and usage terms; this repository's license does not
  replace them.

## Trademarks

This project may contain trademarks or logos for projects, products, or services.
Authorized use of Microsoft trademarks or logos is subject to and must follow
[Microsoft's Trademark & Brand Guidelines](https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks/usage/general).
Use of Microsoft trademarks or logos in modified versions of this project must
not cause confusion or imply Microsoft sponsorship.
Any use of third-party trademarks or logos are subject to those third-party's policies.

# Business Continuity Demo App

A Radius sample showing one application definition and one set of container images deploying
unchanged to a local kind cluster, to AKS with Azure PaaS backing services, and to Azure Local
running air-gapped disconnected operations — with the platform, not the application, deciding what
backs each dependency.

## What it does

```
┌─────────────┐      JSON        ┌──────────┐                  ┌──────────────┐
│  Publisher  │ ───────────────► │  Queue   │ ───────────────► │   Consumer   │
│   worker    │  business event  │          │                  │    worker    │
└─────────────┘                  └──────────┘                  └───────┬──────┘
                                                                       │
                                         ┌─────────────────────────────┴────────────┐
                                         ▼                                          ▼
                                 ┌───────────────┐                        ┌──────────────────┐
                                 │ Object storage│                        │   SQL Server     │
                                 │  (JSON blob)  │                        │ (indexed record) │
                                 └───────────────┘                        └──────────────────┘
```

The publisher emits a random business continuity event every few seconds. The consumer archives the
JSON to object storage, then inserts an indexed row in SQL pointing at that blob. Blob first, so
every row references an archive that exists; the SQL write is a `MERGE`, so redelivery never
duplicates.

### Orders: users sign in and place orders

The publisher also serves an orders API and a browser app. A user signs in with **MSAL.js**, picks
products and places an order; the API publishes it to the same queue, and the consumer archives it
(`orders/<date>/<id>.json`) and records it in `dbo.Orders`. The page polls until the order shows as
*Processed*.

```
Browser (MSAL.js) ──sign in──► Entra ID  |  Keycloak + AD (Azure Local)
      │ Bearer token (aud, scp=access_as_user, roles)
      ▼
Publisher API (Microsoft.Identity.Web) ──OrderPlaced──► Queue ──► Consumer ──► blob + SQL
      ▲                                                                           │
      └──────────────── GET /api/orders (the user's own orders) ◄──────────────────┘
```

The code is written as an ordinary Entra app; nothing in it knows about Keycloak. On Azure Local the
platform makes Keycloak issue Entra-shaped tokens, so only configuration differs:

| Setting | Entra ID | Keycloak (Azure Local) |
|---|---|---|
| API `AzureAd` section | `Instance`, `TenantId`, `ClientId` | `Authority`, `MetadataAddress`, `ClientId`, `Audience` |
| SPA `ProtocolMode` | `AAD` | `OIDC` (plus `KnownAuthorities`) |
| `Orders.Read` / `Orders.Create` | app roles assigned to groups | realm roles mapped from AD groups `bcd-app-readers` / `bcd-app-writers` |
| Scope | `api://<api>/access_as_user` | `api://bcd-orders-api/access_as_user` |

| Endpoint | Requires |
|---|---|
| `GET /api/me`, `GET /api/products` | signed in, scope `access_as_user` |
| `GET /api/orders`, `GET /api/orders/{id}` | `Orders.Read` or `Orders.Create`; only the caller's own orders |
| `POST /api/orders` | `Orders.Create`; prices come from the server catalog, never the client |

The browser app is plain HTML/JS with the MSAL.js 4.30 browser bundle vendored under
`src/Bcd.Publisher/wwwroot/lib`, so building the image needs no Node.js and no internet. The random
event generator is off by default (`publishIntervalSeconds = 0`).

## Same app, different infrastructure

[`deploy/app.bicep`](./deploy/app.bicep) never names RabbitMQ, Service Bus, Azurite or Azure SQL. It
declares three abstract dependencies:

```bicep
resource queue    'BusinessContinuity.Messaging/messageQueues@2025-08-01-preview' = { ... }
resource archive  'Radius.Storage/objectStorage@2025-08-01-preview'               = { ... }
resource database 'Radius.Data/sqlServerDatabases@2025-08-01-preview'             = { ... }
```

A **Recipe** binds each Resource Type to real infrastructure, a **Recipe Pack** groups them, and an
**Environment** references a Recipe Pack. Changing environment changes the infrastructure without
touching application code or Bicep:

| Resource Type | `bcd-local` (kind) | `bcd-azure` (AKS) | `bcd-aldo` (disconnected) |
|---|---|---|---|
| `messageQueues` | RabbitMQ container | **Azure Service Bus** | RabbitMQ container, local registry |
| `objectStorage` | Azurite container | **Azure Blob Storage** | Azurite container, local registry |
| `sqlServerDatabases` | SQL Server container | **Azure SQL** (Entra-only) | SQL Server container, local registry |
| Worker auth | credentials from Recipes | **Entra Workload Identity** | credentials from Recipes |

The third column is not a lesser second: disconnected operations exposes no Service Bus, Azure SQL
or Blob Storage, and supports only *system-assigned* managed identity, so there is no federated
credential to build on. The Recipes absorb those platform facts — which is the point.

`BusinessContinuity.Messaging/messageQueues` is user-defined
([schema](./deploy/types/messageQueues.yaml)) because the built-in `Radius.Messaging/rabbitMQ` is
broker-specific and cannot represent Service Bus. Object storage and SQL use built-in portable types.

## How the application adapts

Radius injects `CONNECTION_<NAME>_<PROPERTY>` variables per connected resource.
[`BcdServiceCollectionExtensions`](./src/Bcd.Shared/DependencyInjection/BcdServiceCollectionExtensions.cs)
is the only place that branches on them:

```csharp
return options.Provider switch
{
    QueueProvider.ServiceBus => new ServiceBusMessageBroker(...),
    QueueProvider.RabbitMq   => new RabbitMqMessageBroker(...),
};
```

The workers only ever see `IMessagePublisher` / `IMessageSubscriber`. Storage follows the same rule:
a connection string means Azurite, an endpoint alone means managed identity.

On Azure no keys exist at all — the Recipes set `disableLocalAuth` and `allowSharedKeyAccess: false`
and grant data-plane roles to a user-assigned identity, which the workers reach through a federated
credential trusting the AKS OIDC issuer for one service account subject.

## Repository layout

```
├── src/
│   ├── Bcd.Shared/         Provider abstractions, CONNECTION_* binding, identity
│   ├── Bcd.Publisher/      Generates and publishes events
│   └── Bcd.Consumer/       Archives to blob, records in SQL
├── deploy/
│   ├── app.bicep           Environment-agnostic application definition
│   ├── registry-auth.bicep Private registry credentials for Recipe pulls
│   ├── infra/              Resource group, ACR, AKS, managed identity + FIC
│   ├── types/              User-defined Resource Type for the queue
│   ├── recipes/            local/ azure/ kubernetes/
│   ├── recipe-packs/       Bind Resource Types to Recipes per environment
│   └── environments/       bcd-local, bcd-azure, bcd-aldo, bcd-azurelocal
├── scripts/
│   ├── setup-platform.ps1  Once per site (platform team): cluster, ingress, sign-in, offline registry
│   ├── deploy.ps1          Every release (app team): images, Recipes, rad deploy
│   ├── settings.example.json  Per-target values; copy to settings.json (gitignored)
│   ├── azure/, azurelocal/ The steps the two commands run, one script per step
│   ├── lib/                Settings loader shared by the two commands
│   └── publish-recipes.ps1 Compile and push Recipes to an OCI registry
├── lab/                    NOT part of the sample: stands up what a customer already has
│   ├── aldo/               Domain controller VM, k3s VM, Azure Local disconnected operations path
│   └── local/              kind cluster for the developer inner loop
├── docker/                 Dockerfiles for both workers
└── docker-compose.yml      Run everything without Kubernetes
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
| .NET 9 SDK, Docker, kubectl | everything |
| [Radius CLI](https://docs.radapp.io/getting-started/) 0.60+ | everything |
| kind | local path |
| Azure CLI + [kubelogin](https://azure.github.io/kubelogin/install.html) | Azure path |

## Option 1 — No Kubernetes

```powershell
Copy-Item .env.example .env   # then set RABBITMQ_PASSWORD and MSSQL_SA_PASSWORD in .env
docker compose up --build
docker compose logs consumer --tail 20
docker compose down -v
```

## Option 2 — Local kind cluster (lab)

```powershell
$env:MSSQL_SA_PASSWORD = '<choose-a-strong-password>'
./lab/local/deploy.ps1
./lab/local/verify.ps1
kubectl logs -n bcd-local -l radapp.io/resource=consumer -f
```

The script creates the cluster and an in-cluster registry, installs Radius, binds a dedicated
workspace, registers the Resource Type, builds and loads images, publishes Recipes, then deploys the
Recipe Pack, Environment and application.

Two things that bite if you work outside the script: `rad` targets the *workspace's* cluster rather
than your current `kubectl` context, and the Radius control plane resolves cluster DNS while the
kubelet does not — so Recipes come from the in-cluster registry but images go onto the node with
`kind load`.

## Option 3 — AKS with Azure PaaS

Azure access is split across two identities, and conflating them causes most of the confusion:

| | Radius control plane → Azure | Workers → Azure |
|---|---|---|
| Who | `applications-rp`, `bicep-de`, `ucp`, `dynamic-rp` | `publisher`, `consumer` |
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
set `PrivateCa` where policy blocks inbound internet traffic, so Let's Encrypt cannot validate, as
in Microsoft-internal subscriptions, and then `IngressCertIssuer: bcd-private-ca` under `Deploy`.
*Identity* registers the API and browser app with Entra (in the Microsoft tenant set
`ServiceManagementReference`).

`deploy.ps1` mints a short-lived, read-only registry token for Recipe pulls itself, builds with
podman or docker, and publishes the orders app through the ingress when
`provision-ingress.ps1` has run (add `-IngressCertIssuer bcd-private-ca` with `-PrivateCa`). Use
`-SqlLocation` when the region refuses new SQL servers, and a distinct `-ResourceGroup` (Radius
group) when another deployment in the subscription already uses `bcd`, since Recipe resource names
derive from it (both under `Deploy` in the settings). Already have a cluster? Run
[bootstrap-identity.ps1](./scripts/azure/bootstrap-identity.ps1), then
`setup-platform.ps1 -Target Azure -Skip Cluster`.

Clean up with `az group delete --name bcd-infra --yes --no-wait`, then
`rad workspace delete bcd-azure --yes`.

Worth knowing: "resource group" means three different things here — the Azure platform group
(`-ResourceGroup`), the Azure group the Recipes provision into (`-AppInfraResourceGroup`), and the
Radius control-plane scope, which is not an Azure group at all despite the identical flag name.

## Option 4 — Azure Local, disconnected operations (lab)

[Disconnected operations](https://learn.microsoft.com/azure/azure-local/manage/disconnected-operations-overview)
offer ARM, RBAC, Azure Local VMs, Arc-enabled servers and Kubernetes, ACR, Key Vault and Policy —
and no PaaS data services. So this is the **local** path plus a **local registry**, air-gapped: every
backing service is an in-cluster container. There is no Entra to federate against either, so
workload identity is rebuilt on Active Directory and Keycloak — see
[Workload identity without Entra](#workload-identity-without-entra).

**Nothing may come from a public registry**, including Radius itself. Everything is listed in
[import-images.ps1](./scripts/azurelocal/import-images.ps1). Recipes are exempt — they are published
from source, so the air gap only ever carries container images.

```powershell
# 1. Platform: resource group, registry, AKS enabled by Arc
./lab/aldo/provision-infra.ps1 -SubscriptionId <sub-id> -RegistryName bcdaldoacr

# 2. Images. Copy = this machine reaches both sides; Mirror = the registry itself has egress;
#    Export/Import = genuinely air-gapped, two machines
./scripts/azurelocal/import-images.ps1 -Mode Copy -Registry mylocalacr.azurecr.local

# 3. Deploy
./lab/aldo/deploy.ps1 -Registry mylocalacr.azurecr.local -KubeContext aks-arc

# 4. Verify
./lab/local/verify.ps1 -KubeContext aks-arc -Namespace bcd-aldo -SqlPassword '<password>'
```

With an authenticated, privately signed registry, step 3 needs all of:

```powershell
./lab/aldo/deploy.ps1 `
    -Registry mylocalacr.azurecr.local -KubeContext aks-arc `
    -ImagePullSecretName local-registry `
    -RegistryUsername <user> -RegistryPassword (Read-Host -AsSecureString) `
    -RegistryCaCertFile D:\certs\registry-ca.crt -ReinstallRadius
```

`-ReinstallRadius` matters: `rad install kubernetes` leaves an existing installation untouched, so
new chart values would never reach the pods.

### If the appliance cannot provision clusters

```powershell
Get-ChildItem C:\azurelocal\PlatformExtensionPacks
```

An `arcenabledkubernetesagents` pack with nothing for `HybridContainerService` means the appliance
can **attach** a cluster but not **provision** one — there is no custom location for
`az aksarc create` to target. Bring your own instead with
[arc-k3s.ps1](./lab/aldo/arc-k3s.ps1), which builds a k3s VM on the appliance's own
Hyper-V switch and registers it as `Microsoft.Kubernetes/connectedClusters`:

```powershell
./lab/aldo/arc-k3s.ps1 -CreateVm -IsoPath C:\iso\ubuntu-24.04.5-live-server-amd64.iso
./lab/aldo/arc-k3s.ps1            # after installing Ubuntu and authorising the key
```

Then `provision-infra.ps1 -SkipClusterCreate` for the resource group and registry.

### One registry, four trust and auth boundaries

The sharpest edge in this environment. The same registry is reached by four consumers, each with its
own trust store and credentials; fixing one does nothing for the others.

| Consumer | Pulls | Trusts the CA via | Authenticates with |
|---|---|---|---|
| Docker on the workstation | pushes images and Recipes | Windows certificate store | `az acr login` |
| containerd on the node | worker and backing-service images | node OS trust store | `imagePullSecrets` |
| Radius control plane pods | Bicep Recipes | `global.rootCA.cert` Helm value | `Radius.Core/bicepSettings` |
| Backing-service Recipes | their own images | node OS trust store | `imagePullSecretName` parameter |

Mapping symptoms back:

- `x509: certificate signed by unknown authority` on a Recipe pull → control plane lacks the CA;
  pass `-RegistryCaCertFile` **and** `-ReinstallRadius`
- `401 unauthorized` on a Recipe pull → `bicepSettings` missing or wrong
- `ImagePullBackOff` with *failed to fetch anonymous token* → pod has no `imagePullSecrets`
- `no such host` from containerd → the **node** cannot resolve the registry; pods use CoreDNS, the
  kubelet uses the node's own `/etc/hosts`

There is no DNS server for the appliance zone — it writes host entries on the machine it was
deployed on, so anything else resolving those names needs them copied across, and a registry created
later is not in that file at all.

Identity-based registry auth is unavailable: disconnected operations issues no token for the
`containerregistry.azure.net` audience, and the edge registry implements no `scopeMaps`, ruling out
managed identity, workload identity and scoped ACR tokens alike. That leaves the admin user or
anonymous pull.

### Workload identity without Entra

On AKS a pod presents its ServiceAccount token to Entra and gets back a credential for a federated
managed identity. Every hop of that is outside the site, so it fails exactly when business
continuity matters most. The same shape is rebuilt from components that stay in the site:

```
k3s signs a ServiceAccount token  ->  Keycloak verifies it against the cluster JWKS and
                                      exchanges it for an access token
                                  ->  the workload presents that token to a backing service
```

Active Directory stays the source of users and groups; Keycloak federates it over LDAPS and is the
only thing that issues tokens. Arc still registers the cluster, but nothing on this path depends on
it, so workloads keep authenticating while the link is down.

| Azure | Here |
|---|---|
| Entra tenant | Active Directory Domain Services on its own VM |
| Federated identity credential | Keycloak `kubernetes` identity provider |
| Managed identity | Keycloak client plus directory group |
| AKS OIDC issuer | k3s `service-account-issuer`, repointed at a reachable address |

```powershell
# 1. Domain controller. Separate VM, because Azure Local requires AD DS off the cluster nodes
./lab/aldo/addc-vm.ps1 -CreateVm -IsoPath C:\iso\windows-server-2022.iso
./lab/aldo/addc-vm.ps1 -LocalAdminCredential (Get-Credential Administrator)

# 2. Let the cluster resolve the domain
./lab/aldo/arc-k3s.ps1 -SkipK3sInstall -SkipArcConnect -AdDomain bcd.lab -AdDnsServer 10.0.60.60

# 3. Keycloak, federated to the directory and trusting the cluster issuer
./scripts/azurelocal/keycloak.ps1 -AdServer <controller-fqdn> -AdDomain bcd.lab -Registry <registry>
```

Generated passwords are written to Kubernetes Secrets, never to the console.
[arc-k3s.ps1](./lab/aldo/arc-k3s.ps1) must run before Keycloak: a default k3s cluster signs
tokens as `https://kubernetes.default.svc.cluster.local`, which no external verifier can resolve.

The controller also installs an enterprise certificate authority, so it auto-enrols a certificate
and Keycloak binds over LDAPS on `636`. Pass `-AdServer` the controller's FQDN rather than its
address; LDAPS validates the host name against the certificate. Without a CA a domain controller
accepts connections on `636` and then drops them, having no certificate to present.

One thing is deliberately unfinished: the backing services still use their own credentials.
Moving them onto these tokens means MinIO in place of Azurite and RabbitMQ's OAuth2 backend,
which changes application code.

## Option 5 — Azure Local (connected) with AKS enabled by Arc

A connected Azure Local instance *could* reach Azure PaaS, but the workload is built to keep running
if the link drops. So it takes the ALDO shape: in-cluster RabbitMQ, SQL Server and Azurite, and
identity from Keycloak bound to the site's existing Active Directory (`DC01`). Everything the demo
creates lives in the `bcd-azurelocal` resource group, apart from the Azure Local instance itself.

The difference from ALDO is the registry. Images and Recipes are pushed to a Premium ACR in Azure,
and an **ACR connected registry** (Arc extension, ReadOnly) inside the cluster syncs them and serves
every pull on a fixed ClusterIP (`10.96.0.50`). A pod restarted while Azure is unreachable still
finds its image, and Radius still finds its Recipes.

| Concern | Here |
|---|---|
| Cluster | AKS Arc `bcd-aksarc`, 1 control plane + 2 `Standard_A4_v2`, lnet `bcd-aks-lnet` |
| Registry | push `<acr-name>.azurecr.io`, pull `10.96.0.50` (connected registry) |
| Cluster access | `--admin` kubeconfig (client certificate, works offline); Entra group `azurelocal-aks-admins` when connected |
| Token issuer | the cluster's default in-cluster issuer; Keycloak runs in the same cluster, so it resolves |
| Directory | existing `DC01` (`azurelocal.lab`): AD CS + LDAPS, OU `BCD`, bind and demo accounts added |

```powershell
# Lab only: directory objects on the existing DC01 (OU BCD, bcd-app-* groups, demo user) and the
# Keycloak bind account Secret. A customer's AD already has users and groups; it needs only a bind
# account. Elevated; prompts for AZURELOCAL\Administrator; leaves DC01's network settings alone.
./lab/aldo/addc-vm.ps1 -ExistingDomainController -VmName DC01 -DomainName azurelocal.lab `
    -NetbiosName AZURELOCAL -IpAddress 192.168.44.10 -KubeContext bcd-aksarc

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
of `bcd-app-readers` can view, members of `bcd-app-writers` can also place orders. The Recipe Pack,
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

To prove it, cut the site's link to Azure. The script shows, from inside the cluster, that Azure is
blocked while the site's own services stay reachable; then sign in and place an order:

```powershell
./lab/azurelocal/wan.ps1 -State Down      # lab only: removes the host NAT, like cutting the WAN line
./lab/azurelocal/wan.ps1 -State Up
```

## Adding another environment

1. Write a Recipe per Resource Type.
2. `./scripts/publish-recipes.ps1 -Registry <registry> -Set <set>`
3. Create a Recipe Pack referencing those Recipes, and an Environment referencing the pack.
4. `rad deploy deploy/app.bicep -e <new-environment>`

## Configuration reference

Both workers read these, whether injected by Radius, docker-compose or `appsettings.json`:

| Variable | Consumed by | Notes |
|---|---|---|
| `CONNECTION_QUEUE_PROVIDER` | both | `rabbitmq` or `servicebus` |
| `CONNECTION_QUEUE_QUEUENAME` | both | Queue / entity name |
| `CONNECTION_QUEUE_HOST` / `_PORT` | both | RabbitMQ only |
| `CONNECTION_QUEUE_USERNAME` / `_PASSWORD` | both | RabbitMQ only, secret-backed |
| `CONNECTION_QUEUE_NAMESPACEFQDN` | both | Service Bus only |
| `CONNECTION_ARCHIVE_ENDPOINT` | consumer | Blob endpoint; triggers managed identity |
| `CONNECTION_ARCHIVE_CONNECTIONSTRING` | consumer | Local only; takes precedence |
| `CONNECTION_ARCHIVE_CONTAINERNAME` | consumer | Blob container |
| `CONNECTION_SQL_HOST` / `_PORT` / `_DATABASE` | consumer | |
| `CONNECTION_SQL_USERNAME` / `_PASSWORD` | consumer | Omit password to force Entra ID |
| `Bcd__Sql__UseEntraId` | consumer | Forces Entra ID even when a password exists |
| `Bcd__Publisher__IntervalSeconds` | publisher | Defaults to 5 |

## Known gaps

- **Workload Identity on AKS is not verified end to end.** `app.bicep` passes `serviceAccountName`
  through `platformOptions.kubernetes`, but the stock container Recipe ignores it and does not set
  the `azure.workload.identity/use` pod label. Patch the deployment after deploying, or extend the
  Recipe.
- The Azure SQL Recipe opens `AllowAllWindowsAzureIps`. Use a Private Endpoint for anything real.
- `InvariantGlobalization` must stay `false` — `Microsoft.Data.SqlClient` requires ICU.
- The local cluster has no metrics-server, so the stock Recipe's HorizontalPodAutoscaler logs
  harmless `FailedGetResourceMetric` warnings.
