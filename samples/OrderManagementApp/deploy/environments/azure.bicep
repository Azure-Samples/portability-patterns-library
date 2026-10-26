// Azure environment: AKS for compute, Azure PaaS for every backing service.
//
// The azure provider tells Radius which subscription and resource group the Recipes provision into.
// The credentials Radius uses are registered separately with `rad credential register azure`.

extension radius

@description('Azure subscription that Recipes provision infrastructure into.')
param subscriptionId string

@description('Azure resource group that Recipes provision infrastructure into.')
param resourceGroupName string

@description('Kubernetes namespace that application resources are deployed into.')
param namespace string = 'oms-azure'

@description('''
Resource ID of a `Radius.Core/bicepSettings` resource holding credentials for pulling Recipes from a
private registry. Leave empty when the registry allows anonymous pull.

Passed as a plain string rather than an `existing` resource reference on purpose: a conditional
`existing` resource is still resolved by the Radius deployment engine even when its condition is
false, which fails with "Unable to fetch resource reference from callback" before the settings
resource has been created. See deploy/recipe-registry-credentials.bicep for the deployment order.
''')
param bicepSettingsId string = ''

resource azureRecipes 'Radius.Core/recipePacks@2025-08-01-preview' existing = {
  name: 'azure-recipes'
}

// The Environment is declared twice under mutually exclusive conditions rather than building
// `properties` with union(). The Radius deployment engine requires `properties` to be a literal
// object: an ARM expression there (union, if, ...) is not evaluated, and the resource is created
// with empty properties, silently falling back to the default Recipe Pack and no providers.
resource azureEnvironment 'Radius.Core/environments@2025-08-01-preview' = if (empty(bicepSettingsId)) {
  name: 'oms-azure'
  properties: {
    recipePacks: [
      azureRecipes.id
    ]
    providers: {
      kubernetes: {
        namespace: namespace
      }
      azure: {
        subscriptionId: subscriptionId
        resourceGroupName: resourceGroupName
      }
    }
  }
}

resource azureEnvironmentWithRegistryAuth 'Radius.Core/environments@2025-08-01-preview' = if (!empty(bicepSettingsId)) {
  name: 'oms-azure'
  properties: {
    recipePacks: [
      azureRecipes.id
    ]
    bicepSettings: bicepSettingsId
    providers: {
      kubernetes: {
        namespace: namespace
      }
      azure: {
        subscriptionId: subscriptionId
        resourceGroupName: resourceGroupName
      }
    }
  }
}

#disable-next-line BCP318
output environmentId string = empty(bicepSettingsId) ? azureEnvironment.id : azureEnvironmentWithRegistryAuth.id
