// The hub's half of the peering with the cluster's virtual network. Deployed into the hub's
// resource group by platform-resources.bicep.

@description('Name of the hub virtual network, in this resource group.')
param hubVirtualNetworkName string

@description('Name of the peering on the hub.')
param peeringName string

@description('Resource ID of the cluster\'s virtual network.')
param remoteVirtualNetworkId string

resource hubVirtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: hubVirtualNetworkName
}

resource peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: hubVirtualNetwork
  name: peeringName
  properties: {
    remoteVirtualNetwork: {
      id: remoteVirtualNetworkId
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
  }
}
