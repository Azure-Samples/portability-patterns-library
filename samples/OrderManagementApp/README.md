# Order Management App

An app written for Azure that moves to **Azure Local** without code changes. The same app
definition and the same container images run on AKS with Azure PaaS services, and on AKS enabled by
Arc on Azure Local, where the app keeps running when the site loses its link to Azure.

Use it as a template for moving your own app: [Move your app in five steps](./docs/move-your-app.md).

## Architecture

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
| How the app authenticates to services | Entra Workload ID (no secrets) | Keycloak token for the queue; Recipe-issued credentials for SQL and storage |
| Images and Recipes | Azure Container Registry | ACR connected registry inside the cluster |
| HTTPS address | Managed NGINX ingress (app routing add-on) on a public IP, `<label>.<region>.cloudapp.azure.com`, certificate from Let's Encrypt | NGINX ingress on an address from the Arc load balancer on the site network, certificate from a CA the setup creates |

The Azure Local column runs nothing in Azure at runtime. That is what lets the app keep working when
the site is cut off from Azure.

## Prerequisites

All commands run from this folder, `samples/OrderManagementApp`.

**To run the app locally:**

- [.NET 9 SDK](https://dotnet.microsoft.com/download/dotnet/9.0)
- [Docker](https://docs.docker.com/get-docker/) or [Podman](https://podman.io/docs/installation)

**To deploy to Azure:**

- Owner on an Azure subscription (the template assigns roles), and the right to register apps in
  Microsoft Entra ID.
- [Azure Developer CLI](https://aka.ms/azd-install)
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), with `kubectl` and
  `kubelogin` (`az aks install-cli`)
- [Helm](https://helm.sh/docs/intro/install/)
- [Radius CLI 0.60](https://docs.radapp.io/installation/)
- [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)
- Docker or Podman

**To deploy to Azure Local:**

- An Azure Local instance, [deployed](https://learn.microsoft.com/azure/azure-local/deploy/deployment-introduction)
  and connected to Azure, with its custom location and a running Arc resource bridge. See the
  [system requirements](https://learn.microsoft.com/azure/azure-local/concepts/system-requirements-23h2).
- Free capacity on the instance for the AKS cluster: three VMs of 4 vCPUs and 8 GB each (one control
  plane, two nodes), plus about 50 GB of storage for the in-cluster registry and Keycloak's database.
- A management machine on the site network, not an Azure Local node, with the same tools as for
  Azure except azd. Microsoft recommends managing AKS on Azure Local from such a
  [client machine](https://learn.microsoft.com/azure/aks-hybrid-edge/local/aks-create-clusters-cli#install-the-azure-cli-extension)
  rather than from the nodes.
- Free addresses on the site network for the AKS cluster: its control plane, a pool for the nodes and a
  small range for the load balancer.
- The site's Active Directory, with the app's groups and a bind account for Keycloak. See
  [Connect your Active Directory](./docs/authentication.md#connect-your-active-directory).
- Contributor and User Access Administrator on the subscription, and the right to create groups in
  Entra ID.

## Run the app locally

The app runs with RabbitMQ, SQL Server, Azurite and Keycloak in containers: the same services as on
Azure Local, with no cluster and no Radius.

```powershell
dotnet dev-certs https --trust
dotnet dev-certs https --export-path local/certs/localhost.crt --format Pem --no-password
docker compose up --build
```

On Linux and macOS, also run `chmod 644 local/certs/localhost.*` before `docker compose up`, so the
Keycloak container can read the certificate.

Open http://localhost:8080 and sign in as `demo`, password `demo`.

The build downloads packages from nuget.org and images from mcr.microsoft.com, docker.io and quay.io.
If your network blocks them, ask for access, or point the build at your own NuGet feed with a
[NuGet.Config](https://learn.microsoft.com/nuget/reference/nuget-config-file) in this folder; the
build uses it when it's there, and Git ignores it.

## Deploy to Azure

```powershell
azd auth login
az login
azd up
```

azd and the Azure CLI keep separate sign-ins, and `azd up` uses both, so sign in to the same tenant
with each.

If your Entra tenant requires a service management reference on app registrations (the Microsoft
corporate tenant does), set it before `azd up`:

```powershell
azd env set SERVICE_MANAGEMENT_REFERENCE <service tree ID>
```

`azd up` creates AKS, a container registry and managed identities, installs Radius and an HTTPS
ingress, registers the app in Entra ID, then builds and deploys the app. It prints the app's
address. Your account gets both app roles, so you can sign in and place orders straight away.

Settings for your subscription, if you need them, are listed at the top of
[azure.yaml](./azure.yaml) (`azd env set ...`).

If `azd up` fails because a VM size or service isn't available in your region
([SkuNotAvailable](https://learn.microsoft.com/azure/azure-resource-manager/troubleshooting/error-sku-not-available)
or a capacity error), pick another size or region, then run `azd up` again:

```powershell
azd env set AKS_NODE_VM_SIZE <size>   # the cluster's nodes, Standard_D4s_v7 by default
azd env set SQL_LOCATION <region>     # Azure SQL only
```

To move everything to another region, start a new environment there: `azd env new <name> --location <region>`.
List the VM sizes a region offers with `az vm list-skus --location <region> --resource-type virtualMachines -o table`.

## Deploy to Azure Local

On the management machine, copy [scripts/settings.example.json](./scripts/settings.example.json) to
`scripts/settings.json` and fill in the `AzureLocal` section. [Azure Local settings](./docs/azure-local-settings.md)
says where to find each value. Then run:

```powershell
./scripts/up.ps1 -Target AzureLocal
```

It checks the site, creates the AKS cluster and everything the app needs on it, and deploys the app.
Open the address it prints and sign in with an AD account in one of the app's groups. The first
time, trust the site's CA certificates with the commands it printed.

To deploy a new version later, run `./scripts/deploy.ps1 -Target AzureLocal`.

## Clean up

**Locally:** `docker compose down`.

**Azure:** `azd down`. It deletes the resource group, including what the Recipes created in it, and
the app registrations.

**Azure Local:** delete the resource group the scripts created (`ResourceGroup` in the settings,
`bcd-azurelocal` by default), which holds the AKS cluster, the registry and the logical network:

```powershell
az group delete --name bcd-azurelocal
```

The AKS cluster's Entra admin group and the objects `ad-setup.ps1` added to Active Directory stay;
remove them by hand if you no longer need them.

## Understand how it works

| | |
|---|---|
| [Move your app in five steps](./docs/move-your-app.md) | resource types, connections, Recipes, Recipe Packs, environments |
| [How authentication works](./docs/authentication.md) | user sign-in, the app's access to its services, connecting Active Directory |
