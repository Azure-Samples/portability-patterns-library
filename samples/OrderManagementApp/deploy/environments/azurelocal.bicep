// Environment for connected Azure Local (AKS enabled by Arc).
//
// No cloud provider is configured: every backing service is an in-cluster container so the
// workload survives losing the Azure link. Shaped like the ALDO Environment for the same reason.
//
// The Kubernetes namespace must already exist: Radius.Core/environments does not create it.

extension radius

@description('Kubernetes namespace that application resources are deployed into.')
param namespace string = 'bcd-azurelocal'

@description('''
Resource ID of a `Radius.Core/bicepSettings` resource holding credentials for pulling Recipes from
the connected registry. Passed as a string: a conditional `existing` reference is still resolved.
''')
param bicepSettingsId string = ''

resource azureLocalRecipes 'Radius.Core/recipePacks@2025-08-01-preview' existing = {
  name: 'bcd-azurelocal-recipes'
}

// Two mutually exclusive declarations: the deployment engine does not evaluate expressions that
// build `properties`, so union() there silently produces an empty Environment.
resource azureLocalEnvironment 'Radius.Core/environments@2025-08-01-preview' = if (empty(bicepSettingsId)) {
  name: 'bcd-azurelocal'
  properties: {
    recipePacks: [
      azureLocalRecipes.id
    ]
    providers: {
      kubernetes: {
        namespace: namespace
      }
    }
  }
}

resource azureLocalEnvironmentWithRegistryAuth 'Radius.Core/environments@2025-08-01-preview' = if (!empty(bicepSettingsId)) {
  name: 'bcd-azurelocal'
  properties: {
    recipePacks: [
      azureLocalRecipes.id
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
output environmentId string = empty(bicepSettingsId) ? azureLocalEnvironment.id : azureLocalEnvironmentWithRegistryAuth.id
