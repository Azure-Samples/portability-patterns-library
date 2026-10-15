// Local environment: kind / k3d / any plain Kubernetes cluster.
//
// No cloud provider is configured, so every Recipe in the referenced Recipe Pack must provision
// in-cluster containers.

extension radius

@description('Kubernetes namespace that application resources are deployed into.')
param namespace string = 'bcd-local'

resource localRecipes 'Radius.Core/recipePacks@2025-08-01-preview' existing = {
  name: 'bcd-local-recipes'
}

resource localEnvironment 'Radius.Core/environments@2025-08-01-preview' = {
  name: 'bcd-local'
  properties: {
    recipePacks: [
      localRecipes.id
    ]
    providers: {
      kubernetes: {
        namespace: namespace
      }
    }
  }
}

output environmentId string = localEnvironment.id
