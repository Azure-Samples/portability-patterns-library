# Order Management App

An app written for Azure that moves to **Azure Local** without code changes. The same app definition
and container images run on AKS with Azure PaaS services, and on AKS enabled by Arc on Azure Local,
where the app keeps running when the site loses its link to Azure.

Use it as a template for moving your own app: [Move your app in five steps](./docs/move-your-app.md).

## Architecture

For the design, its key decisions and what needs Azure, open
[architecture.html](./docs/architecture.html) in a browser.

Users place orders in a browser app. The **API** prices them from the **inventory** service and
publishes them to a **queue**. The **processor** reserves stock, archives each order to **object
storage** and records it in **SQL**.

```mermaid
flowchart LR
    user(["User in a browser"])
    idp["Identity provider<br/>Entra ID on Azure<br/>Keycloak + Active Directory on Azure Local"]
    api["API"]
    queue[["Queue"]]
    processor["Processor"]
    inventory["Inventory"]
    storage[("Object storage<br/>order JSON")]
    sql[("SQL<br/>orders")]
    pg[("PostgreSQL<br/>stock")]

    user -- "1. sign in" --> idp
    idp -- "2. access token" --> user
    user -- "3. place order" --> api
    api -- "4. publish" --> queue
    queue -- "5. deliver" --> processor
    processor -- "6. reserve stock" --> inventory
    processor -- "7. archive" --> storage
    processor -- "8. record" --> sql
    api -. "products, restock" .-> inventory
    api -. "my orders" .-> sql
    inventory --> pg
```

| Dependency | On Azure | On Azure Local |
|---|---|---|
| Queue | Azure Service Bus | RabbitMQ |
| Object storage | Azure Blob Storage | SeaweedFS (S3) |
| SQL (orders) | Azure SQL Database | SQL Server container |
| PostgreSQL (stock) | Azure Database for PostgreSQL | PostgreSQL (CloudNativePG) |
| User sign-in | Microsoft Entra ID | Keycloak, federated to Active Directory |
| Service identity | Entra Workload ID | Kubernetes service account tokens, exchanged with Keycloak |
| Monitoring | Application Insights | Prometheus, Grafana, Loki, Tempo |
| Images | Azure Container Registry | ACR connected registry in the cluster |

Each service runs as its own identity with least privilege. On Azure Local nothing runs in Azure at
run time, so the app keeps working offline.

## Prerequisites

All commands run from this folder.

**Locally:** [.NET 9 SDK](https://dotnet.microsoft.com/download/dotnet/9.0), and Docker or Podman.

**Azure:** Owner on a subscription and the right to register Entra apps;
[azd](https://aka.ms/azd-install), [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli)
with `kubectl` and `kubelogin` (`az aks install-cli`), [Helm](https://helm.sh/docs/intro/install/),
[Radius CLI 0.60](https://docs.radapp.io/installation/),
[PowerShell 7.3+](https://learn.microsoft.com/powershell/scripting/install/installing-powershell),
and Docker or Podman.

**Azure Local:**

- An [Azure Local](https://learn.microsoft.com/azure/azure-local/deploy/deployment-introduction)
  instance connected to Azure, with a custom location.
- Room for the AKS cluster: a 4 vCPU / 6 GB control plane and three 4 vCPU workers, 16 GB each
  (8 GB with `Availability` `standard`), and about 120 GB of storage (80 GB with `standard`).
- A management machine on the site network that can sign in to Azure, with the Azure tools above
  except azd.
- Free addresses on the site network, Active Directory with a bind account for Keycloak, and
  Contributor and User Access Administrator on the subscription. See
  [Azure Local settings](./docs/azure-local-settings.md).

## Run the app locally

```powershell
dotnet dev-certs https --trust
dotnet dev-certs https --export-path local/certs/localhost.crt --format Pem --no-password
$env:LOCAL_PASSWORD = '<at least 8 characters, upper and lower case and digits>'
docker compose up --build
```

On Linux and macOS, run `chmod 644 local/certs/localhost.*` first. Open http://localhost:8080 and sign
in as `demo` / `demo` to order, or `manager` / `manager` to restock. Run the tests with `dotnet test`.

## Deploy to Azure

```powershell
azd auth login
az login
azd up
```

`azd up` creates AKS, a registry, the Azure services and the app registrations, then deploys the app
and prints its address. Optional settings (alert email, VM size, regions) are listed at the top of
[azure.yaml](./azure.yaml). In the Microsoft tenant, first run
`azd env set SERVICE_MANAGEMENT_REFERENCE <service tree ID>`.

## Deploy to Azure Local

> **Scope.** This sample deploys the same app to Azure and to Azure Local; each deployment starts
> with its own data. Moving a running workload between them (copying orders, stock and archived
> orders, switching users between addresses, keeping order history across Entra ID and Keycloak)
> isn't covered yet and will follow in a later iteration.

Copy [scripts/settings.example.json](./scripts/settings.example.json) to `scripts/settings.json`,
fill in the `AzureLocal` section ([where to find each value](./docs/azure-local-settings.md)), then:

```powershell
./scripts/up.ps1 -Target AzureLocal
```

It creates the AKS cluster and everything the app needs, deploys the app and prints its address.
Sign in with an AD account in one of the app's groups. To deploy a new version later, run
`./scripts/deploy.ps1 -Target AzureLocal`.

By default (`Availability` `high`) RabbitMQ and PostgreSQL run replicated by operators and
PostgreSQL is backed up, so losing a worker loses nothing; `standard` runs one of each for fewer
resources. [Running on Azure Local](./docs/run-on-azure-local.md) covers offline operation,
credentials and what to add for production.

## Clean up

- **Locally:** `docker compose down`
- **Azure:** `azd down`
- **Azure Local:** `az group delete --name <ResourceGroup from the settings>`

## Learn more

| | |
|---|---|
| [Move your app in five steps](./docs/move-your-app.md) | resource types, Recipes, Recipe Packs, environments |
| [How authentication works](./docs/authentication.md) | sign-in, service identities, connecting Active Directory |
| [Running on Azure Local](./docs/run-on-azure-local.md) | offline operation, credentials, production checklist |
| [Operators on Azure Local](./infra/azurelocal/operators/README.md) | replication, failover and backups |
| [Monitoring on Azure Local](./infra/azurelocal/observability/README.md) | metrics, logs, traces and alerts |