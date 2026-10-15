// Recipe Pack for local / self-hosted environments (kind, k3d, Azure Local).
//
// Every backing service runs as a container inside the cluster, so the environment needs no cloud
// provider credentials and no Azure subscription.
//
// Two kinds of Recipe are referenced:
//
//   * The application's own Recipes (queue, object storage, SQL), published to a local registry by
//     scripts/publish-recipes.ps1 and pulled over plain HTTP from the in-cluster registry.
//   * The stock Radius Kubernetes Recipes for `Radius.Compute/containers` and
//     `Radius.Security/secrets`, pulled from ghcr.io over HTTPS. Containers need a Recipe like any
//     other Resource Type, and `Radius.Security/secrets` is required because the queue and object
//     storage Recipes emit secret outputs that Radius materializes as secret resources.

extension radius

@description('OCI registry holding the Recipes published from this repository.')
param registry string = 'localhost:5000'

@description('Tag applied to the Recipes published from this repository.')
param tag string = 'latest'

@description('Set true when the local registry does not serve HTTPS, such as the in-cluster kind registry.')
param plainHttp bool = true

@description('Registry holding the stock Radius Kubernetes Recipes.')
param radiusRecipeRegistry string = 'ghcr.io/radius-project/kube-recipes'

resource localRecipes 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'bcd-local-recipes'
  properties: {
    recipes: {
      // ---- Recipes published from this repository --------------------------------------------
      'BusinessContinuity.Messaging/messageQueues': {
        kind: 'bicep'
        source: '${registry}/bcd/recipes/rabbitmq-queue:${tag}'
        plainHttp: plainHttp
      }
      'Radius.Storage/objectStorage': {
        kind: 'bicep'
        source: '${registry}/bcd/recipes/azurite-objectstorage:${tag}'
        plainHttp: plainHttp
      }
      'Radius.Data/sqlServerDatabases': {
        kind: 'bicep'
        source: '${registry}/bcd/recipes/mssql-database:${tag}'
        plainHttp: plainHttp
      }

      // ---- Kubernetes Recipes --------------------------------------------------------------
      // Local build of the stock container Recipe, adding `platformOptions` support for
      // `serviceAccountName` and pod labels. Used in every environment so local and Azure exercise
      // the same Recipe. See deploy/recipes/kubernetes/containers.bicep.
      'Radius.Compute/containers': {
        kind: 'bicep'
        source: '${registry}/bcd/recipes/containers:${tag}'
        plainHttp: plainHttp
      }
      'Radius.Security/secrets': {
        kind: 'bicep'
        source: '${radiusRecipeRegistry}/secrets:latest'
      }
    }
  }
}

output recipePackId string = localRecipes.id
