# Order Management App

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

On Linux and macOS, also run `chmod 644 local/certs/localhost.*` before `docker compose up`, so the
Keycloak container can read the certificate.

Open http://localhost:8080 and sign in as `demo`, password `demo`. Stop it with `docker compose down`.

### On Azure

**You need:** Owner on an Azure subscription (the template assigns roles), the right to register
apps in Microsoft Entra ID, and these tools: [Azure Developer CLI](https://aka.ms/azd-install),
[Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) with `kubectl` and `kubelogin`
(`az aks install-cli`), [Helm](https://helm.sh/docs/intro/install/),
[Radius CLI 0.60](https://docs.radapp.io/installation/), PowerShell 7, and Docker or Podman.

```powershell
azd auth login
az login
azd up
```

azd and the Azure CLI keep separate sign-ins, and `azd up` uses both, so sign in to the same tenant
with each.

`azd up` creates AKS, a container registry and managed identities, installs Radius and an HTTPS
ingress, registers the app in Entra ID, then builds and deploys the app. It prints the app's
address. Your account gets both app roles, so you can sign in and place orders straight away.

Settings for your subscription, if you need them, are listed at the top of
[azure.yaml](./azure.yaml) (`azd env set ...`). Remove everything with `azd down`.

### On Azure Local

**You need:**

- An Azure Local instance connected to Azure, with its custom location and a running Arc resource
  bridge.
- A management machine on the site network, not an Azure Local node, with PowerShell 7 and the
  tools for Azure above, except azd. Microsoft recommends managing AKS on Azure Local from such a
  [client machine](https://learn.microsoft.com/azure/aks-hybrid-edge/local/aks-create-clusters-cli#install-the-azure-cli-extension)
  rather than from the nodes.
- Free addresses on the site network for the cluster: its control plane, a pool for the nodes and a
  small range for the load balancer.
- The site's Active Directory, with the app's groups and a bind account for Keycloak. See
  [Connect your Active Directory](./docs/authentication.md#connect-your-active-directory).
- Contributor and User Access Administrator on the subscription, and the right to create groups in
  Entra ID.

On the management machine, copy [scripts/settings.example.json](./scripts/settings.example.json) to
`scripts/settings.json`, fill in the `AzureLocal` section, then run:

```powershell
./scripts/up.ps1 -Target AzureLocal
```

It checks the site, creates the cluster and everything the app needs on it, and deploys the app.
Open the address it prints and sign in with an AD account in one of the app's groups. The first
time, trust the site's CA certificates with the commands it printed.

To deploy a new version later, run `./scripts/deploy.ps1 -Target AzureLocal`.

## Learn more

| | |
|---|---|
| [Move your app in five steps](./docs/move-your-app.md) | resource types, connections, Recipes, Recipe Packs, environments |
| [How authentication works](./docs/authentication.md) | user sign-in, workload identity, Active Directory and Kerberos |
| [Workload identity in depth](./docs/workload-identity.md) | decoded tokens and troubleshooting |
| [Configuration](./docs/configuration.md) | the environment variables the app reads |
