# Order Management sample

An app written for Azure that moves to **Azure Local** without code changes. The same app
definition and the same container images run on AKS with Azure PaaS services, and on AKS enabled by
Arc on Azure Local, where the app keeps running when the site loses its link to Azure.

Use it as a template for moving your own app: [Move your app in five steps](./docs/move-your-app.md).

## What the app does

Users sign in to a browser app and place orders. The **API** publishes each order to a **queue**;
the **processor** archives the order as JSON in **object storage** and records it in **SQL**.

```mermaid
flowchart LR
    user(["User in a browser"])
    idp["Identity provider<br/>Entra ID on Azure<br/>Keycloak + Active Directory on Azure Local"]
    api["API"]
    queue[["Queue"]]
    processor["Processor"]
    storage[("Object storage<br/>order JSON")]
    sql[("SQL<br/>orders table")]

    user -- "1. sign in" --> idp
    idp -- "2. access token" --> user
    user -- "3. place order" --> api
    api -- "4. publish" --> queue
    queue -- "5. deliver" --> processor
    processor -- "6. archive" --> storage
    processor -- "7. record" --> sql
    api -- "my orders" --> sql
```

| Dependency | On Azure | On Azure Local |
|---|---|---|
| Queue | Azure Service Bus | RabbitMQ container |
| Object storage | Azure Blob Storage | Azurite container |
| SQL | Azure SQL Database | SQL Server container |
| User sign-in | Microsoft Entra ID | Keycloak, federated to the site's Active Directory |
| How the app authenticates to services | Entra Workload ID (no secrets) | Keycloak token for the queue; Kerberos (Active Directory) for SQL; Recipe-issued credentials for storage |
| Images and Recipes | Azure Container Registry | ACR connected registry inside the cluster |

The Azure Local column runs nothing in Azure at runtime. That is what lets the app keep working when
the site is cut off from Azure.

## Run it

All commands run from this folder, `samples/OrderManagementApp`.

| Where | What you need | How long |
|---|---|---|
| [Your machine](#on-your-machine) | Docker or Podman, .NET 9 SDK | 10 minutes |
| [Azure](#on-azure) | an Azure subscription | 20 minutes |
| [Azure Local](#on-azure-local) | an Azure Local instance and its Active Directory | an afternoon, the first time |

### On your machine

The app with RabbitMQ, SQL Server, Azurite and Keycloak in containers: the same services as on
Azure Local, with no cluster and no Radius.

```powershell
dotnet dev-certs https --trust
dotnet dev-certs https --export-path local/certs/localhost.crt --format Pem --no-password
docker compose up --build
```

Open http://localhost:8080 and sign in as `demo`, password `demo`. Stop it with `docker compose down`.

### On Azure

**You need:** Owner on an Azure subscription (the template assigns roles), the right to register
apps in Microsoft Entra ID, and these tools: [Azure Developer CLI](https://aka.ms/azd-install),
[Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) with `kubectl` and `kubelogin`
(`az aks install-cli`), [Helm](https://helm.sh/docs/intro/install/),
[Radius CLI 0.60](https://docs.radapp.io/installation/), PowerShell 7, and Docker or Podman.

```powershell
azd auth login
azd up
```

`azd up` creates AKS, a container registry and managed identities, installs Radius and an HTTPS
ingress, registers the app in Entra ID, then builds and deploys the app. It prints the app's
address. Your account gets both app roles, so you can sign in and place orders straight away.

Settings for your subscription, if you need them, are listed at the top of
[azure.yaml](./azure.yaml) (`azd env set ...`). Remove everything with `azd down`.

### On Azure Local

**Before you start**, check that you have:

- [ ] An Azure Local instance **connected to Azure**, with its custom location and a running Arc
      resource bridge.
- [ ] Free addresses on its infrastructure network: one for the cluster's control plane, a pool for
      the nodes, and a small range for the load balancer.
- [ ] The site's **Active Directory**, with the app's groups and a bind account for Keycloak. See
      [Connect your Active Directory](./docs/authentication.md#connect-your-active-directory).
- [ ] Contributor and User Access Administrator on the Azure subscription, and the right to create
      groups in Entra ID.
- [ ] The tools for Azure above, except azd.

Then:

1. Copy [scripts/settings.example.json](./scripts/settings.example.json) to `scripts/settings.json`
   and fill in the `AzureLocal` section.
2. Check the site: `./scripts/infra/azurelocal/preflight.ps1`. Fix anything marked FAIL.
3. Set up the platform: `./scripts/setup-platform.ps1 -Target AzureLocal`. This creates the
   cluster, the registry that keeps serving images offline, Keycloak and the ingress.
4. Deploy the app: `./scripts/deploy.ps1 -Target AzureLocal`.

Open the address it prints and sign in with an AD account in one of the app's groups. The first
time, trust the site's CA certificates with the commands step 3 printed.

To see or run each piece yourself, without the scripts, see [Set up by hand](./docs/setup-by-hand.md).

## Portability patterns in this sample

How the sample applies each portability pattern on each platform. **Portable contract** is what the
app and its definitions rely on, which stays the same while the platform underneath changes.

<table>
<thead><tr><th>Pattern</th><th>Aspect</th><th>Azure</th><th>Azure Local</th><th>Portable contract</th></tr></thead>
<tbody>
<tr><td rowspan="2"><b>Separate application intent from environment</b></td><td>Deployment</td><td><a href="../../recipe-packs/azure.bicep">azure.bicep</a> Recipe Pack maps each type to an Azure service</td><td><a href="../../recipe-packs/azure-local.bicep">azure-local.bicep</a> Recipe Pack maps each type to a container</td><td><a href="./deploy/app.bicep">app.bicep</a>: one app definition</td></tr>
<tr><td>Code</td><td>Service Bus and Blob Storage SDK clients</td><td>RabbitMQ client; Blob Storage SDK against Azurite</td><td><code>IMessagePublisher</code>, <code>IArchiveStore</code>, <code>IOrderStore</code>; the implementation is picked at startup (<a href="./src/OrderManagement.Shared/DependencyInjection/ServiceCollectionExtensions.cs">ServiceCollectionExtensions.cs</a>)</td></tr>
<tr><td rowspan="4"><b>Standardized container platform</b></td><td>Cluster</td><td>AKS</td><td>AKS enabled by Arc, on a logical network of the Azure Local instance</td><td>container images; manifests from the shared <a href="../../recipes/kubernetes/kubernetes-containers.bicep">container Recipe</a></td></tr>
<tr><td>Registry</td><td>Azure Container Registry</td><td>ACR connected registry inside the cluster, synced while connected (<a href="./infra/azurelocal/connected-registry.bicep">connected-registry.bicep</a>)</td><td>images and Recipes pushed to one ACR</td></tr>
<tr><td>Load balancer and ingress</td><td>Azure Load Balancer; managed NGINX (app routing)</td><td>Arc load balancer (MetalLB); NGINX ingress</td><td>Service of type LoadBalancer; Ingress</td></tr>
<tr><td>Cluster access</td><td>Entra ID with Azure RBAC</td><td>Entra while connected; admin kubeconfig (certificate) when offline</td><td>the standard Kubernetes API; operators use the same tools on both</td></tr>
<tr><td rowspan="2"><b>Portable database engine</b></td><td>Engine</td><td>Azure SQL Database</td><td>SQL Server 2022 container</td><td><code>Radius.Data/sqlServerDatabases</code> type; T-SQL; <code>Microsoft.Data.SqlClient</code></td></tr>
<tr><td>Sign-in</td><td>Entra (Workload ID); the app's managed identity is the admin</td><td>Windows (Kerberos) against the site's Active Directory</td><td>no password in the app: it uses whichever identity the platform mounts, a workload identity token or a Kerberos keytab</td></tr>
<tr><td rowspan="2"><b>Portable messaging</b></td><td>Broker</td><td>Azure Service Bus queue</td><td>RabbitMQ container</td><td><code>Portability.Messaging/messageQueues</code> type; idempotent consumer (<code>MERGE</code>)</td></tr>
<tr><td>Sign-in</td><td>Entra (Workload ID)</td><td>Kubernetes service account token exchanged at Keycloak (OAuth 2.0)</td><td>no password in the app: the pod's token from the platform, exchanged for an access token by the issuer the connection names</td></tr>
<tr><td><b>Classified, abstracted object storage</b></td><td>Store</td><td>Azure Blob Storage, with Workload ID</td><td>Azurite (development emulator)</td><td>flat-file use, one JSON per order, behind <code>IArchiveStore</code>; endpoint and credentials injected</td></tr>
<tr><td rowspan="2"><b>Portable workload and user identities</b></td><td>Users</td><td>Microsoft Entra ID</td><td>Keycloak, federated to Active Directory</td><td>OpenID Connect with MSAL.js and Microsoft.Identity.Web; <code>roles</code>, <code>scp</code> and <code>oid</code> claims</td></tr>
<tr><td>Workloads</td><td>Entra Workload ID (federated credential)</td><td>Kubernetes service account token projection</td><td>the platform mounts a short-lived token into the pod; the app definition holds no credentials</td></tr>
<tr><td><b>Identity estate as code</b></td><td>Definitions</td><td>Entra app registrations, roles and assignments in <a href="./infra/azure/app-identity.bicep">app-identity.bicep</a></td><td>Keycloak realm, clients and role mappings in <a href="./infra/azurelocal/keycloak/realm.json">realm.json</a>, imported when Keycloak starts</td><td>app roles <code>Orders.Read</code>, <code>Orders.Create</code>; scope <code>access_as_user</code></td></tr>
<tr><td><b>Platform as code</b></td><td>Templates</td><td><a href="./infra/azure/">infra/azure/</a>: AKS, ACR, managed identity</td><td><a href="./infra/azurelocal/">infra/azurelocal/</a>: AKS Arc, logical network, ACR, load balancer, connected registry; Keycloak and ingress manifests</td><td>Bicep, deployed with <code>azd up</code> or <code>az deployment sub create</code></td></tr>
<tr><td><b>Observability</b></td><td>Telemetry</td><td>not covered</td><td>not covered</td><td>not covered; would be OpenTelemetry to a configurable backend</td></tr>
</tbody>
</table>

### Not covered yet

- **Continuous portability assessment** with Azure Policy: no parity or SKU checks against the target
  platform.
- **Observability:** the app logs to the console only. There's no OpenTelemetry instrumentation,
  collector or alternative backend.
- **Data paths:** SQL Server, RabbitMQ and Azurite run without persistent volumes, so their data
  doesn't survive a pod restart, and there's no backup, replication or seeding from Azure. The
  pattern expects a tested data path with a measured recovery point.
- **Messaging protocol:** the app uses each broker's own SDK (Service Bus, and RabbitMQ's AMQP 0-9-1
  client) behind one interface, rather than AMQP 1.0 for both. There's no dead-letter handling on
  RabbitMQ: a message that keeps failing is requeued with a back-off, indefinitely.
- **Object storage target:** Azurite is a development emulator, not a production store. Use a file
  share for this flat-file case, or an object store you operate (for example Azure Container
  Storage enabled by Azure Arc, or an S3-compatible store behind `IArchiveStore`).
- **Identity sync and MFA:** Entra users aren't synchronized to Active Directory; each platform has
  its own users. Keycloak doesn't enforce a second factor.

## Learn more

| | |
|---|---|
| [Move your app in five steps](./docs/move-your-app.md) | resource types, connections, Recipes, Recipe Packs, environments |
| [How authentication works](./docs/authentication.md) | user sign-in, workload identity, Active Directory and Kerberos |
| [Workload identity in depth](./docs/workload-identity.md) | decoded tokens and troubleshooting |
| [Set up by hand](./docs/setup-by-hand.md) | every prerequisite as a file and a command, for both platforms |

## Repository layout

The sample uses the library's shared [recipes/](../../recipes/) and
[recipe-packs/](../../recipe-packs/) at the repository root. The sample folder holds:

```
├── src/                 the app (.NET): API and browser app, processor, shared code
├── deploy/              what `rad deploy` uses every release: app.bicep, one environment per platform
├── infra/
│   ├── azure/              platform.bicep (AKS, ACR, identities), app-identity.bicep (Entra apps)
│   └── azurelocal/         platform.bicep (AKS Arc, ACR, load balancer), connected-registry.bicep,
│                           keycloak/, ingress-nginx/, images.txt
├── docker/              Dockerfiles for the API and processor
├── compose.yaml         the app on your machine; local/ holds its test user
├── azure.yaml           azd up for Azure
├── scripts/             optional automation over the files above
└── docs/
```

## Keeping it working

Everything that has to fit together lives in this repository and changes in the same pull
request: the app, its Radius definitions, the Recipes and Recipe Packs, and the platform files. The
Radius version is pinned once per tool: `bicepconfig.json` for the types, and
[images.txt](./infra/azurelocal/images.txt) for the control plane images.

Every pull request runs [order-management.yml](../../.github/workflows/order-management.yml): it
compiles every Bicep template against the Radius types, builds the app, starts it with
`docker compose` and checks it answers, renders the Keycloak and ingress files, and lints the
scripts.

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
| `CONNECTION_SQL_USERNAME` / `_PASSWORD` | both | ignored when the pod has an Entra workload identity or a Kerberos keytab |

## Known gaps

- The sample ships its own build of the stock Kubernetes container Recipe
  ([kubernetes-containers.bicep](../../recipes/kubernetes/kubernetes-containers.bicep)) so the platform can set service
  accounts, pull secrets, ingress, and extra volumes, mounts and environment variables. Each
  platform scenario (identity provider token and CA, Kerberos keytab) is defined in the Recipe Pack
  with those generic inputs, so the Recipe never changes for a new scenario. Upstream support is tracked in
  radius-project/resource-types-contrib#143.
- The Azure SQL Recipe allows access from all Azure services. Use a private endpoint for production.
- Radius 0.60 cannot delete the role assignments the Azure Recipes create, so deleting the app on
  Azure leaves Radius retrying. Delete the Azure resource group directly.
- `InvariantGlobalization` must stay `false`: `Microsoft.Data.SqlClient` requires ICU.
