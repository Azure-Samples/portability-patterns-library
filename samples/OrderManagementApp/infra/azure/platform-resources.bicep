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

resource cluster 'Microsoft.ContainerService/managedClusters@2025-04-01' = {
  name: clusterName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
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
    // reach each service.
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      networkDataplane: 'cilium'
      networkPolicy: 'cilium'
    }
    // Managed NGINX ingress (app routing add-on): how applications are published to users.
    ingressProfile: {
      webAppRouting: {
        enabled: true
      }
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
