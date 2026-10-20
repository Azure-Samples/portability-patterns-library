// Platform infrastructure for the Order Management sample on Azure Local.
//
// Creates the Azure resources the application deployment assumes already exist:
//
//   * Azure Container Registry (Premium, dedicated data endpoint), the source an ACR connected
//     registry inside the cluster syncs from, so images and Recipes stay pullable offline.
//   * A logical network for the AKS nodes on the Azure Local instance.
//   * An AKS enabled by Arc cluster on that logical network.
//
// Everything else the site needs runs inside the cluster or already exists (the connected registry,
// Keycloak, ingress, Radius, Active Directory), so it is set up by scripts, not by this template.
//
// The Azure Local instance and its custom location must already exist; they come from your Azure
// Local deployment. Based on Microsoft's AKS Arc Bicep templates:
// https://github.com/Azure/aksArc/tree/main/deploymentTemplates/aksarc-bicep-azlocal/Cluster
//
// Deployed at subscription scope so it can create its own resource group:
//   az deployment sub create --location <region> --template-file infra/azurelocal/platform.bicep `
//     --parameters <parameters file>
//
// scripts/azurelocal/provision-infra.ps1 fills in the parameters and wraps this.

targetScope = 'subscription'

@description('Azure region of the resource group and resources. Must be a region the Azure Local instance is registered in.')
param location string

@description('Resource group for the resources this template creates. The Azure Local instance lives elsewhere.')
param resourceGroupName string = 'bcd-azurelocal'

@description('Globally unique Azure Container Registry name. Lowercase alphanumeric, 5-50 characters.')
@minLength(5)
@maxLength(50)
param registryName string

@description('Resource ID of the custom location created with the Azure Local instance.')
param customLocationId string

@description('Virtual switch on the Azure Local hosts that the AKS nodes attach to, for example ConvergedSwitch(compute_management_storage).')
param vmSwitchName string

@description('Name of the logical network for the AKS nodes.')
param logicalNetworkName string = 'bcd-aks-lnet'

@description('Address prefix of the node subnet, for example 192.168.44.0/24.')
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

@description('Entra group object IDs granted cluster-admin while the site is connected. Offline, use the admin kubeconfig instead.')
param adminGroupObjectIds array = []

@description('Tags applied to every resource.')
param tags object = {
  application: 'order-management'
  managedBy: 'radius'
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
    customLocationId: customLocationId
    vmSwitchName: vmSwitchName
    logicalNetworkName: logicalNetworkName
    addressPrefix: addressPrefix
    gateway: gateway
    dnsServers: dnsServers
    ipPoolStart: ipPoolStart
    ipPoolEnd: ipPoolEnd
    vlan: vlan
    clusterName: clusterName
    controlPlaneIp: controlPlaneIp
    controlPlaneCount: controlPlaneCount
    controlPlaneVmSize: controlPlaneVmSize
    nodeCount: nodeCount
    nodeVmSize: nodeVmSize
    kubernetesVersion: kubernetesVersion
    sshPublicKey: sshPublicKey
    adminGroupObjectIds: adminGroupObjectIds
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
