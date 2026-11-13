# Azure Virtual Network → Azure Local

Azure Virtual Network isn't available on Azure Local. A logical network gives VMs and Kubernetes nodes addresses on the site's physical network. It covers basic connectivity, but not peering, Private Link or Azure's managed network services. This guide describes the alternatives this project explored, what stayed the same and what changed when this project's sample moved from Azure to Azure Local. The [Sample](#sample) section links the code.

> **About the alternatives:** the alternatives in this guide are options this project explored, not Microsoft recommendations, and other options may exist. Evaluate any alternative against your own requirements.

| Target | Alternative | Portability class | Availability | Summary |
|---|---|---|---|---|
| Azure Local | [Logical network](./alternatives/logical-network.md) | `protocol-compatible` | Sample available | Addresses, DNS servers, gateway and VLAN on the site network, for Azure Local VMs and AKS nodes. No peering or Private Link. Routing between networks and firewalls come from the site. |
| Azure Local | [SDN managed by on-premises tools](https://learn.microsoft.com/azure/azure-local/concepts/software-defined-networking-23h2) | — | Documentation available | Not evaluated by this project. Virtual networks, load balancer and gateways for Hyper-V VMs managed on site. Not supported for AKS on Azure Local. See the linked documentation. |

## What stayed the same in the sample

- **Pod-to-pod rules:** the same Kubernetes NetworkPolicies work on both targets, enforced by Cilium on Azure and Calico on Azure Local.
- **Application code and images:** nothing in them depends on the network, so they didn't change.
- **IPv4 addressing:** subnets in CIDR notation, static addresses from a pool, custom DNS servers and a default gateway.

**From documentation:** Azure Local NSGs filter inbound and outbound traffic on address, port, protocol and direction, as on Azure, for standalone Azure Local VMs. The sample doesn't run standalone VMs.

## What the sample needed to change

1. **A network from the site.** The sample takes the address range, VLAN, gateway and DNS servers as parameters, which come from the site's network team. The logical network describes them. It doesn't create the router, the DNS server or the VLAN on the switch.
2. **Addresses planned up front.** The range leaves room for nodes, upgrades, the control plane and load balancer addresses. The address space, IP pools, gateway, VLAN and switch can't be changed after creation.
3. **A different network definition.** The sample creates a `Microsoft.AzureStackHCI/logicalNetworks` resource instead of `Microsoft.Network/virtualNetworks`, and attaches the AKS cluster to it.
4. **Site connectivity instead of peering.** On Azure, the sample can peer with a hub. Logical networks don't provide peering. VMs on the same VLAN and subnet communicate directly. Communication between subnets needs site routing. Isolation depends on the site's VLANs, firewalls and other network controls.
5. **Services on site instead of private endpoints.** On Azure, the sample can reach Blob Storage, Azure SQL and PostgreSQL through private endpoints. On Azure Local, those services run on site and are reached by their private address, with TLS and their own sign-in. An Azure private endpoint still works over VPN or ExpressRoute, but only while the site has connectivity to Azure.
6. **NetworkPolicies to filter AKS traffic.** Azure Local NSGs can't be attached to the logical network used by AKS or to AKS node NICs. The sample filters pod traffic with NetworkPolicies, and the site's firewall filters the rest.

How Virtual Network features map to logical networks, and what to watch on Azure Local: [Logical networks as an alternative](./alternatives/logical-network.md).

## Limitations observed in the sample

These are the limitations this project found while building the sample. It isn't a complete list.

| Pattern | Limitation for this resource |
|---|---|
| [Networking](https://learn.microsoft.com/azure/virtual-network/virtual-networks-overview) | One address prefix per logical network, IPv4 only. No peering, Private Link, service endpoints, NAT gateway, Azure Firewall or VPN gateway. |
| [Network isolation](https://learn.microsoft.com/azure/azure-local/concepts/sdn-overview) | NSGs need SDN enabled by Arc (Azure Local 2506 or later with OS build 26100.xxxx or later) and apply to Azure Local VMs and their logical networks, not to the logical network or node NICs AKS uses. |
| [Reliability](https://learn.microsoft.com/azure/well-architected/reliability/) | The site runs the switches, routers, firewalls and DNS that Azure manages for you. They must keep working when the site has no or limited connectivity to Azure. |

**Data:** a network holds no data, but addresses and DNS names change. Update connection strings, firewall rules and certificates that name them.

## Sample

The [Order Management sample](../../samples/OrderManagementApp/README.md) runs on AKS on Azure, with its nodes in a virtual network the deployment declares, and on AKS on Azure Local, attached to a logical network that the deployment creates. [Logical networks as an alternative](./alternatives/logical-network.md#how-the-order-management-sample-does-it) points to the code. On Azure, the sample can also use private endpoints for Blob Storage, Azure SQL and PostgreSQL, and peer with a hub. Neither has an equivalent on Azure Local.
