// One Microsoft Entra app registration with the sample's security baseline: single tenant, no
// secrets or certificates, implicit grant and public client fallback off, and the app instance
// property lock so no other tenant can add credentials to its service principal.
// Used by app-identity.bicep for both registrations.

targetScope = 'subscription'

extension microsoftGraphV1

param uniqueName string
param displayName string
param notes string
param serviceManagementReference string
param ownerObjectIds array
param identifierUris array = []
param appRoles array = []
param api object = {}
param spaRedirectUris array = []
param requiredResourceAccess array = []

resource application 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: uniqueName
  displayName: displayName
  signInAudience: 'AzureADMyOrg'
  notes: notes
  serviceManagementReference: empty(serviceManagementReference) ? null : serviceManagementReference
  isFallbackPublicClient: false
  web: {
    implicitGrantSettings: {
      enableAccessTokenIssuance: false
      enableIdTokenIssuance: false
    }
  }
  servicePrincipalLockConfiguration: {
    isEnabled: true
    allProperties: true
  }
  identifierUris: identifierUris
  appRoles: appRoles
  api: api
  spa: {
    redirectUris: spaRedirectUris
  }
  requiredResourceAccess: requiredResourceAccess
  owners: {
    relationships: ownerObjectIds
    relationshipSemantics: 'append'
  }
}

output appId string = application.appId
output objectId string = application.id