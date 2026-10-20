// Resource-group scoped platform resources for Azure Local. Deployed by infra/azurelocal/platform.bicep.

param location string
param registryName string
param customLocationId string
param vmSwitchName string
param logicalNetworkName string
param addressPrefix string
param gateway string
param dnsServers array
param ipPoolStart string
param ipPoolEnd string
param vlan int
param clusterName string
param controlPlaneIp string
param controlPlaneCount int
param controlPlaneVmSize string
param nodeCount int
param nodeVmSize string
param kubernetesVersion string
param sshPublicKey string
param adminGroupObjectIds array
param tags object

// Premium with a dedicated data endpoint: both are prerequisites of an ACR connected registry.
resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: registryName
  location: location
  tags: tags
  sku: {
    name: 'Premium'
  }
  properties: {
    adminUserEnabled: false
    dataEndpointEnabled: true
    publicNetworkAccess: 'Enabled'
  }
}

// Static addressing from a pool on the given virtual switch. The pool must leave room for the
// control plane address and the load balancer addresses the ingress uses.
resource logicalNetwork 'Microsoft.AzureStackHCI/logicalNetworks@2024-01-01' = {
  name: logicalNetworkName
  location: location
  tags: tags
  extendedLocation: {
    type: 'CustomLocation'
    name: customLocationId
  }
  properties: {
    vmSwitchName: vmSwitchName
    dhcpOptions: {
      dnsServers: dnsServers
    }
    subnets: [
      {
        name: logicalNetworkName
        properties: {
          addressPrefix: addressPrefix
          ipAllocationMethod: 'Static'
          vlan: vlan
          ipPools: [
            {
              start: ipPoolStart
              end: ipPoolEnd
            }
          ]
          routeTable: {
            properties: {
              routes: [
                {
                  properties: {
                    addressPrefix: '0.0.0.0/0'
                    nextHopIpAddress: gateway
                  }
                }
              ]
            }
          }
        }
      }
    ]
  }
}

// The Arc representation of the cluster. AKS Arc creates its own Arc agent certificate, so
// agentPublicKeyCertificate stays empty. Workload identity and the OIDC issuer stay off: workloads
// authenticate to an identity provider on site with the cluster's own ServiceAccount tokens, which
// needs no Azure round trip.
resource connectedCluster 'Microsoft.Kubernetes/connectedClusters@2024-12-01-preview' = {
  name: clusterName
  location: location
  tags: tags
  kind: 'ProvisionedCluster'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    agentPublicKeyCertificate: ''
    aadProfile: {
      enableAzureRBAC: false
      adminGroupObjectIDs: adminGroupObjectIds
    }
  }
}

// The AKS cluster itself, provisioned on the Azure Local instance through the Arc Resource Bridge.
resource provisionedCluster 'Microsoft.HybridContainerService/provisionedClusterInstances@2024-01-01' = {
  name: 'default'
  scope: connectedCluster
  extendedLocation: {
    type: 'CustomLocation'
    name: customLocationId
  }
  properties: {
    kubernetesVersion: kubernetesVersion
    linuxProfile: {
      ssh: {
        publicKeys: [
          {
            keyData: sshPublicKey
          }
        ]
      }
    }
    controlPlane: {
      count: controlPlaneCount
      vmSize: controlPlaneVmSize
      controlPlaneEndpoint: {
        hostIP: controlPlaneIp
      }
    }
    networkProfile: {
      networkPolicy: 'calico'
      podCidr: '10.244.0.0/16'
    }
    agentPoolProfiles: [
      {
        name: 'nodepool1'
        count: nodeCount
        vmSize: nodeVmSize
        osType: 'Linux'
        osSKU: 'CBLMariner'
      }
    ]
    cloudProviderProfile: {
      infraNetworkProfile: {
        vnetSubnetIds: [
          logicalNetwork.id
        ]
      }
    }
    licenseProfile: {
      azureHybridBenefit: 'False'
    }
    storageProfile: {
      nfsCsiDriver: {
        enabled: true
      }
      smbCsiDriver: {
        enabled: true
      }
    }
  }
}

output registryLoginServer string = registry.properties.loginServer
output registryName string = registry.name
output clusterName string = connectedCluster.name
output logicalNetworkId string = logicalNetwork.id
output provisioningState string = provisionedCluster.properties.provisioningState
