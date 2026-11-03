# Azure Local settings

`scripts/up.ps1 -Target AzureLocal` reads the `AzureLocal` section of `scripts/settings.json`. Copy
[settings.example.json](../scripts/settings.example.json) to `scripts/settings.json` and replace
every `<...>` placeholder. Leave the other values as they are. Git ignores `settings.json`.

## Azure

| Setting | What to put |
|---|---|
| `Common.SubscriptionId` | The subscription your Azure Local instance is registered in: `az account show --query id -o tsv` |
| `Common.RegistryName` | A new, globally unique name for the container registry the scripts create: 5–50 lowercase letters and digits |
| `Common.ApplicationNamespace` | The Kubernetes namespace the app runs in. Every step uses this one value: leave `oms-azurelocal` or choose your own. |
| `Common.Availability` | `high` (the default): RabbitMQ, PostgreSQL, Keycloak's database and the object store are replicated across three workers, and the databases are backed up, with operators. `standard`: one copy of each, no operators, no backups; it needs fewer resources, but a service is down while its pod restarts and a lost volume loses its data. Pick it before the first deployment: changing it later doesn't move the data. |
| `Images.Registry` | The same name followed by `.azurecr.io` |
| `Cluster.Location` | Your Azure Local instance's region, for example `eastus`: `az resource list -g <its resource group> --resource-type Microsoft.AzureStackHCI/clusters --query [].location -o tsv` |

## Your Azure Local instance

Your Azure Local administrator can give you these. To look them up yourself:

| Setting | How to find it |
|---|---|
| `Cluster.AzureLocalResourceGroup` | The resource group of your Azure Local instance, on its Overview page in the Azure portal |
| `Cluster.CustomLocationName` | `az customlocation list -g <that resource group> --query [].name -o tsv` |
| `Cluster.VmSwitchName` | `az stack-hci-vm network lnet list -g <that resource group> --query [].properties.vmSwitchName -o tsv` |

The cluster gets three workers of `Standard_D4s_v3` (4 vCPUs, 16 GB), so the replicas of RabbitMQ and
the databases each run on their own. If your instance offers other sizes
(`az aksarc vmsize list --custom-location <custom location ID>`), set `Cluster.NodeVmSize`, and
`Cluster.NodeCount` for more workers.

## Network

Ask your network team for these, on the same subnet as the Azure Local nodes. All addresses must be
free, and the three ranges must not overlap.

| Setting | What to put |
|---|---|
| `Cluster.AddressPrefix` | The subnet, for example `10.0.1.0/24` |
| `Cluster.Gateway` | The subnet's default gateway |
| `Cluster.DnsServers` | Your Active Directory DNS servers, so the cluster can find the domain controller |
| `Cluster.IpPoolStart`, `Cluster.IpPoolEnd` | A range for the cluster's VMs: at least one address per node, plus one spare for upgrades |
| `Cluster.ControlPlaneIp` | One address outside that range, for the cluster's API |
| `Cluster.LoadBalancerAddresses` | A small range, for example five addresses, as `<first>-<last>`. The app gets the first one, Keycloak the next. To choose them, set `Ingress.IngressIp` and `Keycloak.KeycloakIp`. |
| `Registry.ServiceClusterIp` | An address inside the cluster for its registry, not on your network. `10.96.0.50` works unless your cluster uses a different service range. |

## Active Directory

| Setting | What to put |
|---|---|
| `Keycloak.AdServer` | Your domain controller's full name, for example `dc01.contoso.local`. It must match the name on its LDAPS certificate. |
| `Keycloak.AdDomain` | Your Active Directory domain, for example `contoso.local` |

## Check before you deploy

```powershell
./scripts/infra/azurelocal/preflight.ps1
```

It checks the values against Azure, your network plan and your domain controller without changing
anything. Fix anything marked FAIL, then run `up.ps1`.
