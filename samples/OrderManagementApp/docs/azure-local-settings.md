# Azure Local settings

`scripts/up.ps1 -Target AzureLocal` reads the `AzureLocal` section of `scripts/settings.json`. Copy
[settings.example.json](../scripts/settings.example.json) to `scripts/settings.json` and replace
every `<...>` placeholder. Leave the other values as they are. Git ignores `settings.json`.

For an existing platform, fill in only the inputs for the phases you intend to run rather than
the entire cluster network plan. See [the existing-platform walkthrough](../README.md#existing-azure-local-platform).

## Which phase owns each setting

| Section | Owner |
|---|---|
| `Common` | Shared resource names such as subscription and Kubernetes context |
| `Cluster`, `Images`, `Registry`, `KeyVault`, `Ingress`, `Keycloak`, `Observability` | Optional demo-platform provisioning |
| `Environment` | Radius installation, Recipe Pack settings, identity, registry trust and ingress binding |
| `Deploy` | Application image build and deployment, namespace and database initialization |
| `Rotation` | Explicit database password maintenance; normally empty |

Environment configuration and rotation also accept relevant existing `Deploy` settings for
compatibility. Their own sections take precedence. Old platform-only `Deploy` settings are ignored
by app deployment and applied only when environment configuration runs. Unknown phase-specific
settings still fail rather than being silently discarded.

Generated resources remain in Azure or Kubernetes: identities supply principal/client IDs;
the connected-registry step writes pull Secrets and the CA ConfigMap; ingress supplies its address;
Key Vault synchronization writes `oms-db-passwords`. Do not copy their secrets into `settings.json`.
Keep shared workspace, group and namespace names consistent between environment configuration,
application deployment and rotation.

On Azure, a group with multiple monitoring resources needs explicit
`Environment.ApplicationInsightsResourceId` and/or `Environment.AlertActionGroupId`; setup does
not select the first match. A group without monitoring resources can still deploy the app.

To use the platform's existing Radius installation, set `Environment.SkipRadiusInstall` to `true`.
`Environment.ImageTag` selects the Recipe tag; `Deploy.ImageTag` selects application image tags.
The application deployer reads the configured Recipe tag rather than changing it for each release.
To change its registry CA, run environment configuration with `Environment.ReinstallRadius`
explicitly enabled, then remove that override. For optional monitoring use `-Skip Observability`
on `up.ps1` or `setup-platform.ps1`.

## Azure

| Setting | What to put |
|---|---|
| `Common.SubscriptionId` | The subscription your Azure Local instance is registered in: `az account show --query id -o tsv` |
| `Common.RegistryName` | A new, globally unique name for the container registry the scripts create: 5–50 lowercase letters and digits |
| `Images.Registry` | The same name followed by `.azurecr.io` |
| `Cluster.Location` | Your Azure Local instance's region, for example `eastus`: `az resource list -g <its resource group> --resource-type Microsoft.AzureStackHCI/clusters --query [].location -o tsv` |

## Your Azure Local instance

Your Azure Local administrator can give you these. To look them up yourself:

| Setting | How to find it |
|---|---|
| `Cluster.AzureLocalResourceGroup` | The resource group of your Azure Local instance, on its Overview page in the Azure portal |
| `Cluster.CustomLocationName` | `az customlocation list -g <that resource group> --query [].name -o tsv` |
| `Cluster.VmSwitchName` | `az stack-hci-vm network lnet list -g <that resource group> --query [].properties.vmSwitchName -o tsv` |

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
| `Cluster.LoadBalancerAddresses` | A small range, for example five addresses, as `<first>-<last>`. The app gets the first one. |
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
