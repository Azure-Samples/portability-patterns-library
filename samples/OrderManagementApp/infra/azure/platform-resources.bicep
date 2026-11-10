// Resource-group scoped platform resources. Deployed by infra/azure/platform.bicep.

@description('Azure region for all resources.')
param location string

@description('Name of the AKS cluster.')
param clusterName string

@description('Globally unique container registry name.')
param registryName string

@description('Prefix of the user-assigned managed identities: one per service, and one for the database setup job.')
param identityPrefix string

@description('Services that get their own identity. Each runs as a service account of the same name.')
param workloadNames array

@description('Service account the database setup job runs as.')
param databaseAdminServiceAccountName string

@description('Email address that receives alerts. Empty creates the action group without receivers.')
param alertEmail string

@description('Name of the user-assigned managed identity the Radius control plane federates with.')
param radiusIdentityName string

@description('Kubernetes namespace the application is deployed into.')
param appNamespace string

@description('Number of nodes in the system pool.')
param nodeCount int

@description('VM size for the system pool.')
param nodeVmSize string

@description('Kubernetes version. Empty means the AKS default.')
param kubernetesVersion string

@description('ACR SKU.')
param registrySku string

@description('Entra ID object IDs granted cluster administrator access: users, groups or service principals. Prefer a group.')
param clusterAdminObjectIds array

@description('Disable local accounts and authenticate with Entra ID plus Azure RBAC.')
param useEntraAuthentication bool

@description('Tags applied to every resource.')
param tags object

@description('Day of the weekly window in which AKS applies new node images.')
param nodeOsUpgradeDay string

@description('Start of that window, HH:mm in UTC. It lasts four hours.')
param nodeOsUpgradeStartTime string

@description('Address space of the virtual network the nodes join.')
param virtualNetworkAddressPrefix string

@description('Address prefix of the node subnet. Only nodes take addresses from it; pods use podCidr.')
param nodeSubnetAddressPrefix string

@description('Pod address range. Must not overlap the virtual network or any network the pods call.')
param podCidr string

@description('Kubernetes service address range. Must not overlap the virtual network or podCidr.')
param serviceCidr string

@description('Address of the cluster DNS service, inside serviceCidr.')
param dnsServiceIP string

@description('Create a subnet and private DNS zones for private endpoints to Blob Storage, Azure SQL and PostgreSQL.')
param usePrivateEndpoints bool

@description('Address prefix of the private endpoint subnet, inside the virtual network.')
param privateEndpointSubnetAddressPrefix string

@description('Resource ID of a hub virtual network to peer with, in the same subscription. Empty peers with nothing.')
param hubVirtualNetworkId string

// Built-in role definition ID for AcrPull.
var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

// Built-in AKS roles used when Entra authentication is enabled.
// - Cluster User grants the right to call `az aks get-credentials` at all.
// - RBAC Cluster Admin grants cluster-admin inside the cluster through Azure RBAC, replacing the
//   certificate-based admin that local accounts would otherwise provide.
var aksClusterUserRoleId = '4abbcc35-e782-43d8-92c5-2d3f1bd2253f'
var aksRbacClusterAdminRoleId = 'b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b'

// Built-in role definition ID for Owner. The Radius control plane needs it on the target resource
// group because its Recipes create both resources and role assignments; Contributor alone cannot
// grant the data-plane roles that Service Bus and Storage require.
var ownerRoleId = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'

// Built-in role definition ID for Network Contributor. The cluster identity needs it on the node
// subnet to join nodes to it and to manage load balancers there.
var networkContributorRoleId = '4d97b98b-1d4f-4787-a291-c67834d212e7'

// The Radius control plane services that authenticate to Azure. Each needs a federated credential
// bound to its Kubernetes service account in the radius-system namespace.
var radiusServiceAccounts = [
  'applications-rp'
  'bicep-de'
  'ucp'
  'dynamic-rp'
]

resource registry 'Microsoft.ContainerRegistry/registries@2025-04-01' = {
  name: registryName
  location: location
  tags: tags
  sku: {
    name: registrySku
  }
  properties: {
    // Prefer Entra ID tokens and scoped ACR tokens over the shared admin account.
    adminUserEnabled: false
    anonymousPullEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}

// Inbound to the nodes: the ingress's ports from the internet. Azure's default rules already allow
// traffic within the virtual network and from the load balancer's health probes, and deny the rest.
resource nodeSecurityGroup 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${clusterName}-nodes'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'allow-ingress-http-https'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: [
            '80'
            '443'
          ]
        }
      }
    ]
  }
}

// Outbound from the nodes and pods leaves through one static address, which external firewalls can
// allow, instead of the load balancer's.
resource natPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-${clusterName}-nat'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource natGateway 'Microsoft.Network/natGateways@2024-05-01' = {
  name: 'ng-${clusterName}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [
      {
        id: natPublicIp.id
      }
    ]
  }
}

// The cluster's network. Declared here, rather than left to AKS, so it can be planned, peered and
// secured like any other network. With Azure CNI Overlay only the nodes take addresses from the
// subnet; pods get theirs from podCidr.
resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-${clusterName}'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        virtualNetworkAddressPrefix
      ]
    }
    subnets: concat([
      {
        name: 'aks-nodes'
        properties: {
          addressPrefix: nodeSubnetAddressPrefix
          networkSecurityGroup: {
            id: nodeSecurityGroup.id
          }
          natGateway: {
            id: natGateway.id
          }
        }
      }
    ], usePrivateEndpoints ? [
      {
        name: 'private-endpoints'
        properties: {
          addressPrefix: privateEndpointSubnetAddressPrefix
        }
      }
    ] : [])
  }
}

resource nodeSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: virtualNetwork
  name: 'aks-nodes'
}

// Zones the Recipes' private endpoints register in. Linked to the virtual network, so pods resolve
// the services' usual host names to private addresses through Azure DNS.
var privateDnsZoneNames = {
  blob: 'privatelink.blob.${environment().suffixes.storage}'
  sql: 'privatelink${environment().suffixes.sqlServerHostname}'
  postgres: 'privatelink.postgres.database.azure.com'
}

resource privateDnsZones 'Microsoft.Network/privateDnsZones@2024-06-01' = [for zone in items(privateDnsZoneNames): if (usePrivateEndpoints) {
  name: zone.value
  location: 'global'
  tags: tags
}]

resource privateDnsZoneLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for (zone, i) in items(privateDnsZoneNames): if (usePrivateEndpoints) {
  parent: privateDnsZones[i]
  name: virtualNetwork.name
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetwork.id
    }
  }
}]

// Peering both ways with a hub in the same subscription. The deployer needs Network Contributor on
// the hub's virtual network too. Address spaces must not overlap.
resource hubPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = if (!empty(hubVirtualNetworkId)) {
  parent: virtualNetwork
  name: 'to-hub'
  properties: {
    remoteVirtualNetwork: {
      id: hubVirtualNetworkId
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
  }
}

module hubPeeringBack 'hub-peering.bicep' = if (!empty(hubVirtualNetworkId)) {
  name: 'hub-peering-${clusterName}'
  scope: resourceGroup(split(hubVirtualNetworkId, '/')[2], split(hubVirtualNetworkId, '/')[4])
  params: {
    hubVirtualNetworkName: last(split(hubVirtualNetworkId, '/'))
    peeringName: 'to-${virtualNetwork.name}'
    remoteVirtualNetworkId: virtualNetwork.id
  }
}

// The cluster's control-plane identity. User-assigned so it can be granted Network Contributor on
// the subnet before the cluster exists; a system-assigned identity only exists after the cluster.
resource clusterIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${identityPrefix}-aks'
  location: location
  tags: tags
}

resource clusterSubnetAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: nodeSubnet
  name: guid(nodeSubnet.id, clusterIdentity.id, networkContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', networkContributorRoleId)
    principalId: clusterIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource cluster 'Microsoft.ContainerService/managedClusters@2025-04-01' = {
  name: clusterName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${clusterIdentity.id}': {}
    }
  }
  dependsOn: [
    clusterSubnetAssignment
  ]
  properties: {
    dnsPrefix: clusterName
    kubernetesVersion: empty(kubernetesVersion) ? null : kubernetesVersion
    enableRBAC: true
    // With local accounts disabled, the only way in is an Entra ID token authorised by Azure RBAC.
    // This removes the certificate-based cluster-admin credential that `az aks get-credentials`
    // would otherwise hand out, and is required by many organisations' security policy.
    disableLocalAccounts: useEntraAuthentication
    aadProfile: useEntraAuthentication ? {
      managed: true
      enableAzureRBAC: true
      tenantID: subscription().tenantId
    } : null
    agentPoolProfiles: [
      {
        name: 'system'
        mode: 'System'
        osType: 'Linux'
        type: 'VirtualMachineScaleSets'
        count: nodeCount
        vmSize: nodeVmSize
        osDiskSizeGB: 128
        // Fixed once the pool exists: moving nodes to another subnet means a new pool or cluster.
        vnetSubnetID: nodeSubnet.id
      }
    ]
    // The two settings that make Workload Identity possible. The OIDC issuer publishes the
    // discovery document that Entra ID validates the projected service account token against, and
    // the workload identity add-on runs the webhook that injects AZURE_CLIENT_ID,
    // AZURE_TENANT_ID and AZURE_FEDERATED_TOKEN_FILE into annotated pods.
    oidcIssuerProfile: {
      enabled: true
    }
    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
    }
    // Azure CNI Overlay with Cilium enforces Kubernetes network policies, which limit which pods may
    // reach each service. The pod and service ranges are set explicitly so they can't overlap the
    // virtual network.
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      networkDataplane: 'cilium'
      networkPolicy: 'cilium'
      podCidr: podCidr
      serviceCidr: serviceCidr
      dnsServiceIP: dnsServiceIP
      // Outbound through the NAT gateway on the node subnet, not the load balancer.
      outboundType: 'userAssignedNATGateway'
    }
    // Managed NGINX ingress (app routing add-on): how applications are published to users.
    ingressProfile: {
      webAppRouting: {
        enabled: true
      }
    }
    // Security patches for the nodes' OS arrive as new node images, which AKS applies by itself in
    // the weekly window below. Kubernetes version upgrades stay manual.
    autoUpgradeProfile: {
      nodeOSUpgradeChannel: 'NodeImage'
    }
  }
}

// The weekly window for node image updates, so they land at a known time. AKS needs at least four
// hours. An urgent fix can still go in sooner: az aks nodepool upgrade --node-image-only.
resource nodeOsUpgradeSchedule 'Microsoft.ContainerService/managedClusters/maintenanceConfigurations@2025-04-01' = {
  parent: cluster
  name: 'aksManagedNodeOSUpgradeSchedule'
  properties: {
    maintenanceWindow: {
      schedule: {
        weekly: {
          dayOfWeek: nodeOsUpgradeDay
          intervalWeeks: 1
        }
      }
      durationHours: 4
      startTime: nodeOsUpgradeStartTime
      utcOffset: '+00:00'
    }
  }
}

// One identity per service, so each gets only the access it needs, plus one for the database setup
// job, which is the Entra administrator of the SQL and PostgreSQL servers and creates each service's
// least-privilege database user.
var identities = concat(
  map(workloadNames, name => { name: name, serviceAccount: name }),
  [ { name: 'db-admin', serviceAccount: databaseAdminServiceAccountName } ]
)

resource managedIdentities 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = [for identity in identities: {
  name: '${identityPrefix}-${identity.name}'
  location: location
  tags: tags
}]

// Each trusts the cluster's OIDC issuer for exactly one service account. The subject format is fixed
// by Kubernetes and must match the namespace and service account name exactly, or token exchange
// fails with AADSTS70021.
resource federatedCredentials 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = [for (identity, i) in identities: {
  parent: managedIdentities[i]
  name: 'aks-${identity.serviceAccount}'
  properties: {
    issuer: cluster.properties.oidcIssuerProfile.issuerURL
    subject: 'system:serviceaccount:${appNamespace}:${identity.serviceAccount}'
    audiences: [
      'api://AzureADTokenExchange'
    ]
  }
}]

// Telemetry. Local authentication is off, so only identities with Monitoring Metrics Publisher can
// send to Application Insights: each service, with its own identity.
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${clusterName}-logs'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${clusterName}-insights'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
    DisableLocalAuth: true
  }
}

var monitoringMetricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb'

resource telemetryPublishers 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (name, i) in workloadNames: {
  scope: applicationInsights
  name: guid(applicationInsights.id, name, monitoringMetricsPublisherRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisherRoleId)
    principalId: managedIdentities[i].properties.principalId
    principalType: 'ServicePrincipal'
  }
}]

resource alertActionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: '${clusterName}-alerts'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'oms-alerts'
    enabled: true
    emailReceivers: empty(alertEmail) ? [] : [
      {
        name: 'operations'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

// Alerts on what the services report. The dead-letter alert is created by the queue Recipe, next to
// the queue it watches.
var appAlerts = [
  {
    name: 'processor-stalled'
    description: 'Orders were placed in the last 15 minutes but none were completed.'
    severity: 2
    query: 'let placed = customMetrics | where name == "oms.orders.placed" | summarize n = sum(valueCount); let completed = customMetrics | where name == "oms.orders.completed" | summarize n = sum(valueCount); placed | extend completed = toscalar(completed | project n) | where n > 0 and coalesce(completed, 0) == 0'
  }
  {
    name: 'low-stock'
    description: 'At least one product is at or below its reorder level.'
    severity: 3
    query: 'customMetrics | where name == "oms.inventory.below_reorder" | summarize latest = arg_max(timestamp, value) | where value > 0'
  }
]

resource appAlertRules 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = [for alert in appAlerts: {
  name: '${clusterName}-${alert.name}'
  location: location
  tags: tags
  properties: {
    description: alert.description
    severity: alert.severity
    enabled: true
    scopes: [ applicationInsights.id ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    criteria: {
      allOf: [
        {
          query: alert.query
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [ alertActionGroup.id ]
    }
  }
}]
// Declarative equivalent of `az aks update --attach-acr`: lets the kubelet pull application images.
// This covers image pulls only. Recipe pulls are performed by the Radius control plane and are
// configured separately through deploy/recipe-registry-credentials.bicep.
resource acrPullAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: registry
  name: guid(registry.id, cluster.id, acrPullRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: cluster.properties.identityProfile.kubeletidentity.objectId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------------------------
// Radius control-plane identity.
//
// Separate from the application identity above, and solving a different problem: this is how the
// Radius control plane authenticates to Azure when its Recipes provision Service Bus, Storage and
// SQL. Without it the alternative is `rad credential register azure sp`, which stores a client
// secret in the cluster -- the very thing this application is built to avoid.
//
// Radius runs four services that talk to Azure, each with its own Kubernetes service account in
// the radius-system namespace, so each needs its own federated credential.
// ---------------------------------------------------------------------------------------------

resource radiusIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: radiusIdentityName
  location: location
  tags: tags
}

// Azure rejects concurrent federated identity credential writes against the same managed identity
// with ConcurrentFederatedIdentityCredentialsWritesForSingleManagedIdentity. Bicep deploys loop
// iterations in parallel by default, so this must be serialised.
@batchSize(1)
resource radiusFederatedCredentials 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = [
  for serviceAccount in radiusServiceAccounts: {
    parent: radiusIdentity
    name: 'radius-${serviceAccount}'
    properties: {
      issuer: cluster.properties.oidcIssuerProfile.issuerURL
      subject: 'system:serviceaccount:radius-system:${serviceAccount}'
      audiences: [
        'api://AzureADTokenExchange'
      ]
    }
  }
]

// Scoped to this resource group only. If Recipes provision into a different group, grant the same
// role there as well.
resource radiusOwnerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: resourceGroup()
  name: guid(resourceGroup().id, radiusIdentity.id, ownerRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', ownerRoleId)
    principalId: radiusIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Cluster access for administrators. Both roles are needed: Cluster User to fetch a kubeconfig at
// all, RBAC Cluster Admin to be authorised inside the cluster. Without these, disabling local
// accounts locks everyone out of the API server. No principalType: an ID may be a user, a group
// (preferred) or a service principal (azd's AZURE_PRINCIPAL_ID in CI), and Azure looks it up.
@batchSize(1)
resource clusterUserAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for adminObjectId in (useEntraAuthentication ? clusterAdminObjectIds : []): {
    scope: cluster
    name: guid(cluster.id, adminObjectId, aksClusterUserRoleId)
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', aksClusterUserRoleId)
      principalId: adminObjectId
    }
  }
]

@batchSize(1)
resource clusterAdminAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for adminObjectId in (useEntraAuthentication ? clusterAdminObjectIds : []): {
    scope: cluster
    name: guid(cluster.id, adminObjectId, aksRbacClusterAdminRoleId)
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', aksRbacClusterAdminRoleId)
      principalId: adminObjectId
    }
  }
]

output registryLoginServer string = registry.properties.loginServer
output registryName string = registry.name
output clusterName string = cluster.name
output oidcIssuerUrl string = cluster.properties.oidcIssuerProfile.issuerURL
output workloadIdentities array = [for (name, i) in workloadNames: {
  name: name
  clientId: managedIdentities[i].properties.clientId
  principalId: managedIdentities[i].properties.principalId
}]
output databaseAdminClientId string = managedIdentities[length(workloadNames)].properties.clientId
output databaseAdminPrincipalId string = managedIdentities[length(workloadNames)].properties.principalId
output databaseAdminName string = managedIdentities[length(workloadNames)].name
output applicationInsightsConnectionString string = applicationInsights.properties.ConnectionString
output alertActionGroupId string = alertActionGroup.id
output radiusIdentityClientId string = radiusIdentity.properties.clientId
output radiusIdentityPrincipalId string = radiusIdentity.properties.principalId
output radiusIdentityName string = radiusIdentity.name
output virtualNetworkId string = virtualNetwork.id
output nodeSubnetId string = nodeSubnet.id
output natPublicIpAddress string = natPublicIp.properties.ipAddress
output privateEndpointSubnetId string = usePrivateEndpoints ? '${virtualNetwork.id}/subnets/private-endpoints' : ''
output privateDnsZoneIds object = usePrivateEndpoints ? toObject(items(privateDnsZoneNames), zone => zone.key, zone => resourceId('Microsoft.Network/privateDnsZones', zone.value)) : {}
