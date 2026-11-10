// Layer 0 -- platform infrastructure for the Order Management sample on Azure.
//
// Creates everything the application deployment assumes already exists:
//
//   * Azure Container Registry, holding both the application images and the Bicep Recipes.
//   * A virtual network with a node subnet, and the AKS cluster's nodes joined to it. The subnet
//     has a network security group and a NAT gateway for outbound traffic. Optionally, a subnet and
//     private DNS zones for private endpoints, and peering with a hub virtual network.
//   * AKS cluster with the OIDC issuer and workload identity both enabled.
//   * AcrPull for the cluster's kubelet identity, the declarative equivalent of
//     `az aks update --attach-acr`, so the kubelet can pull the application images.
//   * A user-assigned managed identity per service, each with a federated identity credential (FIC)
//     trusting the cluster's OIDC issuer for that service's Kubernetes service account. This is what
//     lets each service reach exactly the Azure services it needs without any secret. A further
//     identity is the database administrator, used only by the database setup job.
//   * Log Analytics and Application Insights, with local authentication off, and alert rules.
//
// This is deliberately separate from the application deployment: it changes rarely, and it needs
// far higher privileges (role assignments require Owner or User Access Administrator).
//
// Deployed at subscription scope so it can create its own resource group:
//   az deployment sub create --location <region> --template-file infra/azure/platform.bicep
//
// scripts/infra/azure/provision-infra.ps1 wraps this and performs the imperative follow-up steps.

targetScope = 'subscription'

@description('Azure region for the resource group and all resources in it.')
param location string

@description('Resource group that the platform infrastructure is created in.')
param resourceGroupName string = 'bcd-infra'

@description('Name of the AKS cluster. Also used as the DNS prefix.')
param clusterName string = 'bcd-aks'

@description('Globally unique Azure Container Registry name. Lowercase alphanumeric, 5-50 characters.')
@minLength(5)
@maxLength(50)
param registryName string = 'omsacr${uniqueString(subscription().id, resourceGroupName)}'

@description('Prefix of the user-assigned managed identities: one per service and one for the database setup job.')
param identityPrefix string = 'id-oms'

@description('Services that get their own identity. Each runs as a service account of the same name, as the Azure Recipe Pack sets.')
param workloadNames array = [
  'api'
  'processor'
  'inventory'
]

@description('Service account the database setup job runs as.')
param databaseAdminServiceAccountName string = 'dbsetup'

@description('Email address that receives alerts. Empty creates the action group without receivers.')
param alertEmail string = ''

@description('''
Name of the user-assigned managed identity the Radius control plane federates with. This is a
different identity from the one the application uses: it lets Radius provision Azure resources without a
client secret, replacing `rad credential register azure sp`.
''')
param radiusIdentityName string = 'bcd-radius-identity'

@description('Kubernetes namespace the application is deployed into. Must match the Radius Environment namespace.')
param appNamespace string = 'oms-azure'

@description('Number of nodes in the system pool.')
@minValue(1)
param nodeCount int = 2

@description('''
VM size for the system pool. Availability is both region-specific and subscription-specific: a
policy-constrained subscription may permit only a subset of sizes, and that subset differs per
region. If preflight fails with "The VM size ... is not allowed in your subscription", the error
lists the sizes that are permitted in that region -- pick one of those, or try another region.
''')
param nodeVmSize string = 'Standard_D4s_v7'

@description('Kubernetes version. Leave empty to let AKS pick the default.')
param kubernetesVersion string = ''

@description('ACR SKU. Basic is enough for this sample; Premium adds private endpoints and geo-replication.')
@allowed([
  'Basic'
  'Standard'
  'Premium'
])
param registrySku string = 'Standard'

@description('''
Entra ID object IDs granted cluster administrator access: users, groups (preferred) or service
principals. Required because local accounts are disabled: without at least one entry nobody can
reach the API server. `provision-infra.ps1` passes the signed-in user by default.
''')
param clusterAdminObjectIds array = []

@description('''
Disable AKS local (certificate) accounts and authenticate to the API server with Entra ID plus
Azure RBAC. Recommended, and required by many organisations' policy. Turning this off falls back to
certificate-based cluster-admin credentials.
''')
param useEntraAuthentication bool = true

@description('Tags applied to every resource.')
param tags object = {
  application: 'order-management'
  managedBy: 'radius'
}

@description('Day of the weekly window in which AKS applies new node images, which carry the nodes\' OS security patches.')
@allowed([
  'Monday'
  'Tuesday'
  'Wednesday'
  'Thursday'
  'Friday'
  'Saturday'
  'Sunday'
])
param nodeOsUpgradeDay string = 'Sunday'

@description('Start of that window, HH:mm in UTC. It lasts four hours.')
param nodeOsUpgradeStartTime string = '02:00'

@description('''
Address space of the virtual network the AKS nodes join. Fixed for the life of the cluster. Must
not overlap podCidr, serviceCidr, or any network you later peer or connect over VPN.
''')
param virtualNetworkAddressPrefix string = '10.224.0.0/16'

@description('Address prefix of the node subnet, inside the virtual network. Leave room for scaling and upgrades.')
param nodeSubnetAddressPrefix string = '10.224.0.0/24'

@description('Pod address range for Azure CNI Overlay. Not routable outside the cluster.')
param podCidr string = '10.244.0.0/16'

@description('Kubernetes service address range.')
param serviceCidr string = '10.0.0.0/16'

@description('Address of the cluster DNS service, inside serviceCidr.')
param dnsServiceIP string = '10.0.0.10'

@description('''
Reach Blob Storage, Azure SQL and PostgreSQL through private endpoints in the virtual network, with
their public access turned off. Creates a subnet and private DNS zones here; the Recipes create the
endpoints. Service Bus and the registry stay public: their private endpoints need the Premium tier.
''')
param usePrivateEndpoints bool = false

@description('Address prefix of the private endpoint subnet, inside the virtual network.')
param privateEndpointSubnetAddressPrefix string = '10.224.1.0/24'

@description('''
Resource ID of a hub virtual network in the same subscription to peer with, both ways. Empty peers
with nothing. Its address space must not overlap this virtual network's.
''')
param hubVirtualNetworkId string = ''

resource platformResourceGroup 'Microsoft.Resources/resourceGroups@2022-09-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module platform 'platform-resources.bicep' = {
  scope: platformResourceGroup
  name: 'bcd-platform'
  params: {
    location: location
    clusterName: clusterName
    registryName: registryName
    identityPrefix: identityPrefix
    workloadNames: workloadNames
    databaseAdminServiceAccountName: databaseAdminServiceAccountName
    alertEmail: alertEmail
    radiusIdentityName: radiusIdentityName
    appNamespace: appNamespace
    nodeCount: nodeCount
    nodeVmSize: nodeVmSize
    kubernetesVersion: kubernetesVersion
    registrySku: registrySku
    clusterAdminObjectIds: clusterAdminObjectIds
    useEntraAuthentication: useEntraAuthentication
    tags: tags
    nodeOsUpgradeDay: nodeOsUpgradeDay
    nodeOsUpgradeStartTime: nodeOsUpgradeStartTime
    virtualNetworkAddressPrefix: virtualNetworkAddressPrefix
    nodeSubnetAddressPrefix: nodeSubnetAddressPrefix
    podCidr: podCidr
    serviceCidr: serviceCidr
    dnsServiceIP: dnsServiceIP
    usePrivateEndpoints: usePrivateEndpoints
    privateEndpointSubnetAddressPrefix: privateEndpointSubnetAddressPrefix
    hubVirtualNetworkId: hubVirtualNetworkId
  }
}

@description('Resource group holding the platform infrastructure.')
output resourceGroupName string = platformResourceGroup.name

@description('Login server of the container registry, for example bcdacr.azurecr.io.')
output registryLoginServer string = platform.outputs.registryLoginServer

output registryName string = platform.outputs.registryName
output clusterName string = platform.outputs.clusterName

@description('OIDC issuer URL of the cluster, which the federated identity credential trusts.')
output oidcIssuerUrl string = platform.outputs.oidcIssuerUrl

@description('Each service\'s identity: name, clientId and principalId. The Azure Recipe Pack takes them by service name.')
output workloadIdentities array = platform.outputs.workloadIdentities

@description('The database-administrator identity, the Entra administrator of the SQL and PostgreSQL servers.')
output databaseAdminClientId string = platform.outputs.databaseAdminClientId
output databaseAdminPrincipalId string = platform.outputs.databaseAdminPrincipalId
output databaseAdminName string = platform.outputs.databaseAdminName
output databaseAdminServiceAccountName string = databaseAdminServiceAccountName

output applicationInsightsConnectionString string = platform.outputs.applicationInsightsConnectionString
output alertActionGroupId string = platform.outputs.alertActionGroupId

@description('Client ID of the Radius control-plane identity. Pass to `rad credential register azure wi`.')
output radiusIdentityClientId string = platform.outputs.radiusIdentityClientId

@description('Principal (object) ID of the Radius control-plane identity.')
output radiusIdentityPrincipalId string = platform.outputs.radiusIdentityPrincipalId

output appNamespace string = appNamespace

@description('Virtual network the AKS nodes join. Peer or connect other networks to it.')
output virtualNetworkId string = platform.outputs.virtualNetworkId

@description('Subnet the AKS nodes take their addresses from.')
output nodeSubnetId string = platform.outputs.nodeSubnetId

@description('Address the nodes and pods reach the internet from. Allow it on external firewalls.')
output natPublicIpAddress string = platform.outputs.natPublicIpAddress

@description('Subnet the Recipes put private endpoints in. Empty without private endpoints.')
output privateEndpointSubnetId string = platform.outputs.privateEndpointSubnetId

@description('Private DNS zone IDs by service (blob, sql, postgres). Empty without private endpoints.')
output privateDnsZoneIds object = platform.outputs.privateDnsZoneIds
