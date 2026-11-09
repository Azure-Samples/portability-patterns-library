# Azure Virtual Network → Azure Local

Azure Virtual Network isn't available on Azure Local. A logical network gives VMs and Kubernetes nodes addresses on the site's physical network. It covers basic connectivity, but not peering, Private Link or Azure's managed network services. This guide shows what you can use instead, what stays the same, and what you change.

| Target | Alternative | Portability class | Availability | Summary |
|---|---|---|---|---|
| Azure Local | [Logical network](./alternatives/logical-network.md) | — | Documentation available | Addresses, DNS servers, gateway and VLAN on the site network, for Azure Local VMs and AKS nodes. No peering or Private Link; routing between networks and firewalls come from the site. |
| Azure Local | [SDN managed by on-premises tools](https://learn.microsoft.com/azure/azure-local/concepts/software-defined-networking-23h2) | — | Documentation available | Not evaluated by this project. Virtual networks, load balancer and gateways for Hyper-V VMs managed on site; not supported for AKS on Azure Local. See the linked documentation. |
## What carries over

- **Pod-to-pod rules:** the same Kubernetes NetworkPolicies work on both targets, enforced by Cilium on Azure and Calico on Azure Local.
- **The application code and images:** nothing in them depends on the network, so changing it doesn't change them.
- **IPv4 addressing:** subnets in CIDR notation, static addresses from a pool, custom DNS servers and a default gateway.
- **Inbound and outbound rules for VMs:** Azure Local NSGs filter on address, port, protocol and direction, as on Azure, for standalone Azure Local VMs.

## What you need to change

1. **Get the network from your network admin.** Reserve an address range, a VLAN, a gateway and DNS servers on the site network. The logical network describes them; it doesn't create the router, the DNS server or the VLAN on the switch.
2. **Plan addresses up front.** Leave room for nodes, upgrades, the control plane and load balancer addresses. The address space, IP pools, gateway, VLAN and switch can't be changed after creation.
3. **Replace the network definition.** Use `Microsoft.AzureStackHCI/logicalNetworks` instead of `Microsoft.Network/virtualNetworks`, and attach the cluster or VM to it.
4. **Replace peering with site connectivity.** Logical networks don't provide peering. VMs on the same VLAN and subnet can communicate directly; communication between subnets requires site routing. Isolation depends on the site's VLANs, firewalls and other network controls.
5. **Replace private endpoints.** Run the dependency on site and reach it by its private address, with TLS and its own sign-in. An Azure private endpoint still works over VPN or ExpressRoute, but only while the link to Azure is up.
6. **Filter AKS traffic with NetworkPolicies.** Azure Local NSGs can't be attached to the logical network used by AKS or to AKS node NICs.

How Virtual Network features map to logical networks, and what to watch on Azure Local: [Logical networks as an alternative](./alternatives/logical-network.md).

## Observed limitations

| Pattern | Limitation for this resource |
|---|---|
| [Networking](https://learn.microsoft.com/azure/virtual-network/virtual-networks-overview) | One address prefix per logical network, IPv4 only. No peering, Private Link, service endpoints, NAT gateway, Azure Firewall or VPN gateway. |
| [Network isolation](https://learn.microsoft.com/azure/azure-local/concepts/sdn-overview) | NSGs need SDN enabled by Arc (Azure Local 2506 or later with OS build 26100.xxxx or later) and apply to Azure Local VMs and their logical networks, not to the logical network or node NICs AKS uses. |
| [Reliability](https://learn.microsoft.com/azure/well-architected/reliability/) | The site runs the switches, routers, firewalls and DNS that Azure manages for you. They must keep working without the link to Azure. |

**Data:** a network holds no data, but addresses and DNS names change. Update connection strings, firewall rules and certificates that name them.

## Sample

The [Order Management sample](../../samples/OrderManagementApp/README.md) runs on AKS on Azure, which manages its own virtual network, and on AKS on Azure Local, attached to a logical network that the deployment creates. [Logical networks as an alternative](./alternatives/logical-network.md#how-the-order-management-sample-does-it) points to the code. The sample doesn't use peering or private endpoints.
