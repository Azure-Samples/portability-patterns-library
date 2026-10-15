// Environment for Azure Local with disconnected operations (ALDO).
//
// No cloud provider is configured. Disconnected operations expose no Service Bus, Azure SQL or Blob
// Storage, so there is nothing for Radius Recipes to provision through an Azure provider: every
// backing service is an in-cluster container. That makes this Environment shaped like the local
// one rather than the Azure one.
//
// The Kubernetes namespace must already exist: Radius.Core/environments does not create it.

extension radius

@description('Kubernetes namespace that application resources are deployed into.')
param namespace string = 'bcd-aldo'

@description('''
Resource ID of a `Radius.Core/bicepSettings` resource holding credentials for pulling Recipes from
the local registry. Leave empty when the registry allows anonymous pull.

Passed as a plain string rather than an `existing` resource reference: a conditional `existing`
resource is still resolved by the Radius deployment engine even when its condition is false.
''')
param bicepSettingsId string = ''

resource aldoRecipes 'Radius.Core/recipePacks@2025-08-01-preview' existing = {
  name: 'bcd-aldo-recipes'
}

// Declared twice under mutually exclusive conditions rather than building `properties` with
// union(): the Radius deployment engine requires `properties` to be a literal object, and an ARM
// expression there is silently not evaluated, leaving the Environment with empty properties.
resource aldoEnvironment 'Radius.Core/environments@2025-08-01-preview' = if (empty(bicepSettingsId)) {
  name: 'bcd-aldo'
  properties: {
    recipePacks: [
      aldoRecipes.id
    ]
    providers: {
      kubernetes: {
        namespace: namespace
      }
    }
  }
}

resource aldoEnvironmentWithRegistryAuth 'Radius.Core/environments@2025-08-01-preview' = if (!empty(bicepSettingsId)) {
  name: 'bcd-aldo'
  properties: {
    recipePacks: [
      aldoRecipes.id
    ]
    bicepSettings: bicepSettingsId
    providers: {
      kubernetes: {
        namespace: namespace
      }
    }
  }
}

#disable-next-line BCP318
output environmentId string = empty(bicepSettingsId) ? aldoEnvironment.id : aldoEnvironmentWithRegistryAuth.id
