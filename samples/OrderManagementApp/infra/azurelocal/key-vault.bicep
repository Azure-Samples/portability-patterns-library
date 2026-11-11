// Azure Key Vault for secrets and certificates that already live in Azure and must reach the Azure
// Local site, for example an existing certificate or a partner's API key. The Key Vault Secret Store
// extension copies them into Kubernetes Secrets while the site is connected, and the copies keep
// working while it is cut off. The sample's own credentials don't go through it: they are generated
// on site (see the README's production list).
//
//   * Key Vault, RBAC authorization, soft delete and purge protection.
//   * A user-assigned managed identity that the extension uses to read the vault, with a federated
//     credential trusting the cluster's OIDC issuer for one service account. Requires the cluster
//     to have been created with workload identity (infra/azurelocal/platform.bicep).
//   * The Secret Store extension.
//
// Deployed by scripts/infra/azurelocal/key-vault.ps1 into the platform resource group.

@description('Azure region for the Key Vault and the identity.')
param location string = resourceGroup().location

@description('Globally unique Key Vault name, 3-24 characters.')
param keyVaultName string

@description('Name of the AKS Arc cluster (its connected cluster resource) in this resource group.')
param clusterName string

@description('Name of the managed identity the Secret Store extension reads the vault with.')
param identityName string = 'id-oms-secret-sync'

@description('Namespace the secrets are synced into.')
param syncNamespace string

@description('Service account the Secret Store extension authenticates as, in that namespace.')
param syncServiceAccountName string = 'secret-sync'

@description('Object IDs allowed to set and change the secrets: the operators, and whoever runs key-vault.ps1.')
param secretsOfficerObjectIds array = []

@description('How often, in seconds, the extension checks Key Vault for new versions.')
param rotationPollIntervalInSeconds int = 3600

@description('Tags applied to every resource.')
param tags object = {
  application: 'order-management'
}

// Built-in roles.
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'
var keyVaultSecretsOfficerRoleId = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'

resource connectedCluster 'Microsoft.Kubernetes/connectedClusters@2024-12-01-preview' existing = {
  name: clusterName
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: true
    publicNetworkAccess: 'Enabled'
  }
}

resource syncIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
  tags: tags
}

resource federatedCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: syncIdentity
  name: 'aksarc-${syncServiceAccountName}'
  properties: {
    issuer: connectedCluster.properties.oidcIssuerProfile.issuerUrl
    subject: 'system:serviceaccount:${syncNamespace}:${syncServiceAccountName}'
    audiences: [
      'api://AzureADTokenExchange'
    ]
  }
}

resource syncReadsSecrets 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, syncIdentity.id, keyVaultSecretsUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalId: syncIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource officers 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for objectId in secretsOfficerObjectIds: {
  scope: keyVault
  name: guid(keyVault.id, objectId, keyVaultSecretsOfficerRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsOfficerRoleId)
    principalId: objectId
  }
}]

// Needs the Certificate Management extension, which the cluster gets when it's created
// (platform-resources.bicep).
resource secretStore 'Microsoft.KubernetesConfiguration/extensions@2023-05-01' = {
  scope: connectedCluster
  name: 'azure-secret-store'
  properties: {
    extensionType: 'microsoft.azure.secretstore'
    autoUpgradeMinorVersion: true
    releaseTrain: 'stable'
    scope: {
      cluster: {}
    }
    configurationSettings: {
      rotationPollIntervalInSeconds: string(rotationPollIntervalInSeconds)
    }
  }
}

output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
output syncClientId string = syncIdentity.properties.clientId
output tenantId string = subscription().tenantId
