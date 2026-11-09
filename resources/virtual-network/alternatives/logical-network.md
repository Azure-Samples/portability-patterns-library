# Logical networks as an alternative to Azure Virtual Network

A [logical network](https://learn.microsoft.com/azure/azure-local/manage/create-logical-networks) describes how Azure Local VMs connect to the site's physical network: the address prefix, the IP pool, the DNS servers, the gateway and the VLAN. Azure Local VMs attach to it directly; AKS on Azure Local gives its node VMs addresses from it. Unlike a virtual network, it doesn't route, filter or resolve names itself: the site network does.

| Part | Role |
|---|---|
| External virtual switch | Connects the VMs to the host's physical network adapters. Created when Azure Local is deployed. |
| Logical network | Address prefix, IP pool, DNS servers, gateway and VLAN for the VMs attached to it |
| Site router, firewall and DNS | Route between networks, filter traffic and resolve names. Run by your network team. |
| SDN enabled by Arc (optional) | Adds network security groups for Azure Local VMs |

## Virtual Network features in logical networks

| Virtual Network | Logical network | Notes |
|---|---|---|
| Virtual network | Logical network | Different resource type: `Microsoft.AzureStackHCI/logicalNetworks`. |
| Several subnets in one network | One address prefix per logical network | Create one logical network per subnet. |
| IPv4 address space | IPv4 address prefix | |
| IPv6, dual stack | No equivalent | |
| Static and dynamic addresses | Static from an IP pool, or DHCP from the site | AKS needs a static logical network. |
| Custom DNS servers | DNS servers | The DNS servers run on site. |
| [Azure DNS private zones](https://learn.microsoft.com/azure/dns/private-dns-overview) | No equivalent | Use the site's DNS. |
| Route tables, user-defined routes | Default gateway | Other routes are set on the site's routers. |
| [Peering](https://learn.microsoft.com/azure/virtual-network/virtual-network-peering-overview), including global peering | No equivalent | Route between logical networks through the site's routers. |
| [Private endpoints](https://learn.microsoft.com/azure/private-link/private-endpoint-overview) | No equivalent | Run the dependency on site and reach it by its private address. |
| Service endpoints, service tags | No equivalent | |
| Network security groups | [Network security groups](https://learn.microsoft.com/azure/azure-local/manage/create-network-security-groups) | Needs SDN enabled by Arc. Attach to Azure Local VM NICs or logical networks, but not those AKS uses. |
| Application security groups | No equivalent | Rules use addresses and address ranges. |
| NAT gateway, Azure Firewall, VPN gateway | No equivalent | The site's firewall and routers. |
| Azure DDoS Protection | No equivalent | |
| Flow logs, Network Watcher | No equivalent | Use the site's network monitoring. |
| Changing address space, subnets | Address prefix, IP pools, gateway, VLAN and switch are fixed after creation | Create a new logical network to change them. |

## On Azure Local

- **Ask the network team first.** Reserve the address range, VLAN, gateway and DNS servers with them. Without a VLAN ID, the VMs send untagged traffic, which the physical switch must accept.
- **Size the address range.** For AKS, the node pool, upgrades, the control plane address and load balancer addresses all come from the logical network's prefix. Running out of addresses fails cluster deployment and upgrades. IP pools must not overlap on the same VLAN.
- **Pods use their own range.** AKS on Azure Local gives pods addresses from a separate pod CIDR, carried over VXLAN by Calico, not from the logical network. Keep it from overlapping site networks the pods call. See [IP address planning](https://learn.microsoft.com/azure/aks-hybrid-edge/local/hyperconverged/aks-hci-ip-address-planning).
- **Network security groups.** Available with [SDN enabled by Arc](https://learn.microsoft.com/azure/azure-local/concepts/sdn-overview), on Azure Local 2506 or later. They apply to Azure Local VMs created through Azure, not to the logical network AKS uses or to AKS node NICs. [SDN managed by on-premises tools](https://learn.microsoft.com/azure/azure-local/concepts/software-defined-networking-23h2) offers virtual networks, a load balancer and gateways, but only for VMs managed on site, and you can't mix the two methods. [AKS on Azure Local doesn't support software-defined virtual networks](https://learn.microsoft.com/azure/aks/aksarc/network-system-requirements).

## How the Order Management sample does it

| Step | In the sample |
|---|---|
| The network on Azure | [Azure platform resources](../../../samples/OrderManagementApp/infra/azure/platform-resources.bicep) don't declare a virtual network: AKS creates and manages one, with Azure CNI Overlay and Cilium. |
| The network on Azure Local | [Azure Local platform resources](../../../samples/OrderManagementApp/infra/azurelocal/platform-resources.bicep) create a static logical network: switch, address prefix, IP pool, VLAN, DNS servers and default route. It's created with the cluster, before Radius, not by a Recipe. |
| Attaching the cluster | The same file passes the logical network to AKS in `cloudProviderProfile.infraNetworkProfile.vnetSubnetIds`. The node VMs and the control plane address come from it. |
| Pod addresses | `podCidr` with Calico, separate from the logical network's prefix |
| Reaching the app from the site | The [Arc load balancer](../../../samples/OrderManagementApp/infra/azurelocal/platform-resources.bicep) (MetalLB) gives the ingress an address from the logical network's prefix, outside the IP pool. On Azure, the ingress gets an Azure load balancer address. |
| Traffic between pods | The same [network policies](../../../samples/OrderManagementApp/deploy/network-policies.yaml) on both targets default-deny ingress to pods in the application namespace, with explicit allowances. Kubelet health probes are unaffected; these policies don't cover other namespaces. |

## Not covered by the sample

The sample uses one network per target. Before production, add:

- separate logical networks for tiers that must be isolated, such as a database moved out of the cluster onto its own VM, with routes and firewall rules between them on the site network;
- network security groups on standalone Azure Local VMs, if you run any;
- egress rules: the sample's network policies restrict inbound traffic only;
- monitoring of the site network.

## References

- [What is Azure Virtual Network?](https://learn.microsoft.com/azure/virtual-network/virtual-networks-overview)
- [Create logical networks for Azure Local VMs](https://learn.microsoft.com/azure/azure-local/manage/create-logical-networks)
- [Create logical networks for AKS on Azure Local](https://learn.microsoft.com/azure/aks-hybrid-edge/local/hyperconverged/aks-networks)
- [IP address planning for AKS on Azure Local](https://learn.microsoft.com/azure/aks-hybrid-edge/local/hyperconverged/aks-hci-ip-address-planning)
- [SDN enabled by Azure Arc on Azure Local](https://learn.microsoft.com/azure/azure-local/concepts/sdn-overview)
- [Network security groups on Azure Local](https://learn.microsoft.com/azure/azure-local/manage/create-network-security-groups)
- [SDN managed by on-premises tools](https://learn.microsoft.com/azure/azure-local/concepts/software-defined-networking-23h2)
- [AKS on Azure Local network requirements](https://learn.microsoft.com/azure/aks/aksarc/network-system-requirements)
