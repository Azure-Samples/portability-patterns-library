// Microsoft Entra app registrations of the orders app: the Entra counterpart of the Keycloak clients
// on Azure Local, producing the same names and claims.
//
//   API app  identifier URI api://<appId>, delegated scope access_as_user, user app roles Orders.Read,
//            Orders.Create and Inventory.Manage, v2 access tokens; only users or groups holding a role
//            get tokens
//   Inventory app  identifier URI api://<appId>, application roles Inventory.Read, Inventory.Reserve
//            and Inventory.Restock, v2 access tokens; only the managed identities granted a role get
//            tokens, so no user token reaches the inventory service
//   SPA app  public client (auth code + PKCE) with the given redirect origins, permission to the scope,
//            pre-authorized so users see no consent prompt
//   Role assignments for the given users and groups
//
// Security baseline on both: single tenant, no secrets or certificates, implicit grant and public
// client fallback off, the deployer as owner, and the app instance property lock so no other tenant
// can add credentials to the service principals.
//
// Apps created outside Bicep are adopted by setting their uniqueName once; see
// https://learn.microsoft.com/graph/templates/bicep/how-to-reference-existing-resources
// scripts/infra/azure/configure-app-identity.ps1 does that, keeps existing scope and role IDs, and deploys this.
//
//   az deployment sub create --location <region> --template-file infra/azure/app-identity.bicep `
//     --parameters spaOrigins='["https://<host>"]' ownerObjectIds='["<your object id>"]'

targetScope = 'subscription'

extension microsoftGraphV1

@description('Name of the API app registration. Also its uniqueName.')
param apiAppName string = 'oms-api'

@description('Name of the browser app registration. Also its uniqueName.')
param spaAppName string = 'oms-spa'

@description('Name of the delegated scope the browser app requests.')
param apiScopeName string = 'access_as_user'

@description('Origins the browser app is served from, for example https://orders.contoso.com. HTTPS, or http://localhost.')
param spaOrigins array

@description('Object IDs made owners of both registrations, typically the person deploying.')
param ownerObjectIds array = []

@description('App roles to grant: objects with principalId (a user or group object ID) and role (Orders.Read, Orders.Create or Inventory.Manage).')
param roleAssignments array = []

@description('Name of the inventory service\'s app registration. Also its uniqueName.')
param inventoryAppName string = 'oms-inventory'

@description('Services allowed to call the inventory service: objects with principalId (a managed identity\'s object ID) and role (Inventory.Read, Inventory.Reserve or Inventory.Restock).')
param inventoryRoleAssignments array = []

@description('Service record some tenants require new app registrations to reference.')
param serviceManagementReference string = ''

@description('Notes shown on both registrations.')
param notes string = 'Order Management sample: one app definition deployed to Azure and Azure Local. https://github.com/Azure-Samples/portability-patterns-library/tree/main/samples/OrderManagementApp'

// Entra refuses to change the ID of an enabled scope or role, so these must stay the same across
// deployments. The script passes the IDs of existing registrations.
@description('ID of the delegated scope.')
param scopeId string = guid(subscription().subscriptionId, apiAppName, 'scope', apiScopeName)

@description('ID of the Orders.Read app role.')
param readRoleId string = guid(subscription().subscriptionId, apiAppName, 'role', 'Orders.Read')

@description('ID of the Orders.Create app role.')
param createRoleId string = guid(subscription().subscriptionId, apiAppName, 'role', 'Orders.Create')

@description('ID of the Inventory.Manage app role.')
param manageRoleId string = guid(subscription().subscriptionId, apiAppName, 'role', 'Inventory.Manage')

@description('IDs of the inventory service\'s roles, by role value.')
param inventoryRoleIds object = {
  'Inventory.Read': guid(subscription().subscriptionId, inventoryAppName, 'role', 'Inventory.Read')
  'Inventory.Reserve': guid(subscription().subscriptionId, inventoryAppName, 'role', 'Inventory.Reserve')
  'Inventory.Restock': guid(subscription().subscriptionId, inventoryAppName, 'role', 'Inventory.Restock')
}

var appRoles = [
  {
    id: readRoleId
    value: 'Orders.Read'
    displayName: 'Read orders'
    description: 'View own orders'
    allowedMemberTypes: [
      'User'
    ]
    isEnabled: true
  }
  {
    id: createRoleId
    value: 'Orders.Create'
    displayName: 'Create orders'
    description: 'Place orders'
    allowedMemberTypes: [
      'User'
    ]
    isEnabled: true
  }
  {
    id: manageRoleId
    value: 'Inventory.Manage'
    displayName: 'Manage inventory'
    description: 'Restock products'
    allowedMemberTypes: [
      'User'
    ]
    isEnabled: true
  }
]

var roleIds = {
  'Orders.Read': readRoleId
  'Orders.Create': createRoleId
  'Inventory.Manage': manageRoleId
}

var inventoryRoleDescriptions = {
  'Inventory.Read': 'Read products and stock'
  'Inventory.Reserve': 'Reserve stock for orders'
  'Inventory.Restock': 'Add stock'
}

// Application roles only: services call the inventory service with their own identity.
var inventoryAppRoles = [for role in items(inventoryRoleIds): {
  id: role.value
  value: role.key
  displayName: role.key
  description: inventoryRoleDescriptions[role.key]
  allowedMemberTypes: [
    'Application'
  ]
  isEnabled: true
}]

var inventoryApi = {
  requestedAccessTokenVersion: 2
}

var scope = {
  id: scopeId
  value: apiScopeName
  type: 'User'
  isEnabled: true
  adminConsentDisplayName: 'Access the orders API'
  adminConsentDescription: 'Lets the app call the orders API as the signed-in user.'
  userConsentDisplayName: 'Access the orders API'
  userConsentDescription: 'Lets the app call the orders API on your behalf.'
}

var api = {
  requestedAccessTokenVersion: 2
  oauth2PermissionScopes: [
    scope
  ]
}

// redirect.html is MSAL's redirect bridge, which receives sign-in responses; the app's page itself
// is where sign-out returns.
var spaRedirectUris = flatten(map(spaOrigins, origin => ['${origin}/redirect.html', '${origin}/']))

module apiApp 'app-registration.bicep' = {
  name: 'oms-api-app'
  params: {
    uniqueName: apiAppName
    displayName: apiAppName
    notes: notes
    serviceManagementReference: serviceManagementReference
    ownerObjectIds: ownerObjectIds
    appRoles: appRoles
    api: api
  }
}

// Only users or groups holding an app role can get tokens for the API.
resource apiServicePrincipal 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: apiApp.outputs.appId
  appRoleAssignmentRequired: true
  notes: notes
}

module spaApp 'app-registration.bicep' = {
  name: 'oms-spa-app'
  params: {
    uniqueName: spaAppName
    displayName: spaAppName
    notes: notes
    serviceManagementReference: serviceManagementReference
    ownerObjectIds: ownerObjectIds
    spaRedirectUris: spaRedirectUris
    requiredResourceAccess: [
      {
        resourceAppId: apiApp.outputs.appId
        resourceAccess: [
          {
            id: scopeId
            type: 'Scope'
          }
        ]
      }
    ]
  }
}

resource spaServicePrincipal 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: spaApp.outputs.appId
  notes: notes
}

// An app can't refer to its own appId when it's created, so the identifier URI api://<appId> and the
// pre-authorization of the browser app are added in a second pass.
module apiAppLinks 'app-registration.bicep' = {
  name: 'oms-api-app-links'
  params: {
    uniqueName: apiAppName
    displayName: apiAppName
    notes: notes
    serviceManagementReference: serviceManagementReference
    ownerObjectIds: ownerObjectIds
    appRoles: appRoles
    identifierUris: [
      'api://${apiApp.outputs.appId}'
    ]
    api: union(api, {
      preAuthorizedApplications: [
        {
          appId: spaApp.outputs.appId
          delegatedPermissionIds: [
            scopeId
          ]
        }
      ]
    })
  }
  dependsOn: [
    spaServicePrincipal
  ]
}

resource assignments 'Microsoft.Graph/appRoleAssignedTo@v1.0' = [for assignment in roleAssignments: {
  resourceId: apiServicePrincipal.id
  principalId: assignment.principalId
  appRoleId: roleIds[assignment.role]
}]

module inventoryApp 'app-registration.bicep' = {
  name: 'oms-inventory-app'
  params: {
    uniqueName: inventoryAppName
    displayName: inventoryAppName
    notes: notes
    serviceManagementReference: serviceManagementReference
    ownerObjectIds: ownerObjectIds
    appRoles: inventoryAppRoles
    api: inventoryApi
  }
}

// Only the identities granted a role can get tokens for the inventory service.
resource inventoryServicePrincipal 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: inventoryApp.outputs.appId
  appRoleAssignmentRequired: true
  notes: notes
}

module inventoryAppLinks 'app-registration.bicep' = {
  name: 'oms-inventory-app-links'
  params: {
    uniqueName: inventoryAppName
    displayName: inventoryAppName
    notes: notes
    serviceManagementReference: serviceManagementReference
    ownerObjectIds: ownerObjectIds
    appRoles: inventoryAppRoles
    identifierUris: [
      'api://${inventoryApp.outputs.appId}'
    ]
    api: inventoryApi
  }
  dependsOn: [
    inventoryServicePrincipal
  ]
}

resource inventoryAssignments 'Microsoft.Graph/appRoleAssignedTo@v1.0' = [for assignment in inventoryRoleAssignments: {
  resourceId: inventoryServicePrincipal.id
  principalId: assignment.principalId
  appRoleId: inventoryRoleIds[assignment.role]
}]
output tenantId string = tenant().tenantId
output apiAppId string = apiApp.outputs.appId
output spaAppId string = spaApp.outputs.appId
output apiScope string = 'api://${apiApp.outputs.appId}/${apiScopeName}'
output inventoryAppId string = inventoryApp.outputs.appId
output inventoryScope string = 'api://${inventoryApp.outputs.appId}/.default'
