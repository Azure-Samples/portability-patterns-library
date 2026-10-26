// Platform infrastructure for the Order Management sample on Azure Local.
//
// Creates the Azure and Entra resources the application deployment assumes already exist:
//
//   * Azure Container Registry (Premium, dedicated data endpoint), the source an ACR connected
//     registry inside the cluster syncs from, so images and Recipes stay pullable offline.
//   * A logical network for the AKS nodes on the Azure Local instance.
//   * An AKS enabled by Arc cluster on that logical network, administered by an Entra group.
//   * The Arc load balancer (MetalLB, ARP mode) that gives the ingress an address on the site network.
//
// The ACR connected registry has its own template, connected-registry.bicep. Everything else the
// site needs runs inside the cluster or already exists (Keycloak, the ingress controller, Radius,
// Active Directory), so it is set up by scripts.
//
// The Azure Local instance and its custom location must already exist; they come from your Azure
// Local deployment. Based on Microsoft's AKS Arc Bicep templates:
// https://github.com/Azure/aksArc/tree/main/deploymentTemplates/aksarc-bicep-azlocal/Cluster
//
// Deployed at subscription scope so it can create its own resource group:
//   az deployment sub create --location <region> --template-file infra/azurelocal/platform.bicep `
//     --parameters <parameters file>
//
// scripts/infra/azurelocal/provision-infra.ps1 fills in the parameters and wraps this.

targetScope = 'subscription'

extension microsoftGraphV1

@description('Azure region of the resource group and resources. Must be a region the Azure Local instance is registered in.')
param location string

@description('Resource group for the resources this template creates. The Azure Local instance lives elsewhere.')
param resourceGroupName string = 'bcd-azurelocal'

@description('Globally unique Azure Container Registry name. Lowercase alphanumeric, 5-50 characters.')
@minLength(5)
@maxLength(50)
param registryName string

@description('Resource group holding the Azure Local instance and its custom location.')
param azureLocalResourceGroup string

@description('Name of the custom location created with the Azure Local instance.')
param customLocationName string

@description('''
Virtual switch on the Azure Local hosts that the AKS nodes attach to, for example
ConvergedSwitch(compute_management_storage). Leave empty to copy it from switchSourceLogicalNetworkName.
''')
param vmSwitchName string = ''

@description('Existing logical network in azureLocalResourceGroup whose virtual switch the AKS nodes use, when vmSwitchName is empty.')
param switchSourceLogicalNetworkName string = ''

@description('Name of the logical network for the AKS nodes.')
param logicalNetworkName string = 'bcd-aks-lnet'

@description('Address prefix of the node subnet on the site network, in CIDR notation.')
param addressPrefix string

@description('Default gateway of the node subnet.')
param gateway string

@description('DNS servers for the nodes. Use the Active Directory DNS servers so the cluster resolves the domain.')
param dnsServers array

@description('First address of the pool the nodes take their IPs from.')
param ipPoolStart string

@description('Last address of the pool the nodes take their IPs from.')
param ipPoolEnd string

@description('VLAN ID of the node subnet; 0 for none.')
param vlan int = 0

@description('Name of the AKS Arc cluster.')
param clusterName string = 'bcd-aksarc'

@description('API server address. Must be in the subnet and outside the IP pool.')
param controlPlaneIp string

@description('''
Address range for pods, used only inside the cluster. Defaults to the AKS enabled by Arc default;
change it only if it overlaps a network the pods must reach.
''')
param podCidr string = '10.244.0.0/16'

@description('Number of control plane nodes.')
@allowed([
  1
  3
  5
])
param controlPlaneCount int = 1

@description('VM size of the control plane nodes. List sizes with: az aksarc vmsize list --custom-location <id>')
param controlPlaneVmSize string = 'Standard_A4_v2'

@description('Number of worker nodes.')
@minValue(1)
param nodeCount int = 2

@description('VM size of the worker nodes.')
param nodeVmSize string = 'Standard_A4_v2'

@description('Kubernetes version. List versions with: az aksarc get-versions --custom-location <id>')
param kubernetesVersion string

@description('SSH public key for the nodes, used for troubleshooting and log collection.')
param sshPublicKey string

@description('Entra security group granted cluster-admin while the site is connected. Offline, use the admin kubeconfig instead.')
param adminGroupName string = 'azurelocal-aks-admins'

@description('Object IDs added to the admin group, typically the person deploying. Existing members are kept.')
param adminGroupMemberIds array = []

@description('Name of the Arc load balancer.')
param loadBalancerName string = 'bcd-lb'

@description('''
Address range the load balancer hands out on the site network, as <first>-<last>. Must be in the
subnet and outside the node IP pool. Empty skips the load balancer.
''')
param loadBalancerAddresses string = ''

@description('Tags applied to every Azure resource.')
param tags object = {
  application: 'order-management'
  managedBy: 'radius'
}

// Values that come from the existing Azure Local instance.
resource customLocation 'Microsoft.ExtendedLocation/customLocations@2021-08-15' existing = {
  name: customLocationName
  scope: resourceGroup(azureLocalResourceGroup)
}

resource switchSourceLogicalNetwork 'Microsoft.AzureStackHCI/logicalNetworks@2024-01-01' existing = if (empty(vmSwitchName)) {
  name: switchSourceLogicalNetworkName
  scope: resourceGroup(azureLocalResourceGroup)
}

#disable-next-line BCP318
var effectiveVmSwitchName = empty(vmSwitchName) ? switchSourceLogicalNetwork.properties.vmSwitchName : vmSwitchName

// Entra objects. A group created outside Bicep is adopted by setting its uniqueName once; see
// https://learn.microsoft.com/graph/templates/bicep/how-to-reference-existing-resources
resource adminGroup 'Microsoft.Graph/groups@v1.0' = {
  uniqueName: adminGroupName
  displayName: adminGroupName
  description: 'Cluster administrators of the AKS Arc cluster ${clusterName} while the site is connected.'
  mailEnabled: false
  mailNickname: adminGroupName
  securityEnabled: true
  members: {
    relationships: adminGroupMemberIds
    relationshipSemantics: 'append'
  }
}

// Microsoft's "Kubernetes Runtime RP" app. The Arc load balancer extension needs its object ID in
// this tenant to grant it access.
resource kubernetesRuntimeRp 'Microsoft.Graph/servicePrincipals@v1.0' existing = {
  appId: '087fca6e-4606-4d41-b3f6-5ebdf75b8b4c'
}

resource platformResourceGroup 'Microsoft.Resources/resourceGroups@2022-09-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module platform 'platform-resources.bicep' = {
  scope: platformResourceGroup
  name: 'oms-azurelocal-platform'
  params: {
    location: location
    registryName: registryName
    customLocationId: customLocation.id
    vmSwitchName: effectiveVmSwitchName
    logicalNetworkName: logicalNetworkName
    addressPrefix: addressPrefix
    gateway: gateway
    dnsServers: dnsServers
    ipPoolStart: ipPoolStart
    ipPoolEnd: ipPoolEnd
    vlan: vlan
    clusterName: clusterName
    controlPlaneIp: controlPlaneIp
    podCidr: podCidr
    controlPlaneCount: controlPlaneCount
    controlPlaneVmSize: controlPlaneVmSize
    nodeCount: nodeCount
    nodeVmSize: nodeVmSize
    kubernetesVersion: kubernetesVersion
    sshPublicKey: sshPublicKey
    adminGroupObjectIds: [
      adminGroup.id
    ]
    loadBalancerName: loadBalancerName
    loadBalancerAddresses: loadBalancerAddresses
    kubernetesRuntimeObjectId: kubernetesRuntimeRp.id
    tags: tags
  }
}

@description('Resource group holding the resources.')
output resourceGroupName string = platformResourceGroup.name

@description('Login server of the cloud registry the connected registry syncs from.')
output registryLoginServer string = platform.outputs.registryLoginServer

output registryName string = platform.outputs.registryName
output clusterName string = platform.outputs.clusterName
output logicalNetworkId string = platform.outputs.logicalNetworkId
output adminGroupId string = adminGroup.id