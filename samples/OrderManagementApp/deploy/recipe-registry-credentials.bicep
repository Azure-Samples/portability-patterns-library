// Authentication for a private OCI registry hosting the Bicep Recipes.
//
// WHY THIS EXISTS
// There are two independent pulls in an Azure deployment:
//
//   1. The application container images, pulled by the kubelet on the nodes. On Azure AcrPull on the
//      kubelet identity covers them; on Azure Local an image pull secret does.
//   2. The Bicep Recipe artifacts, pulled by the Radius control plane pods in `radius-system`.
//      Those do NOT use the kubelet identity, so `--attach-acr` does nothing for them. Without the
//      settings below, a private ACR returns 401 when Radius tries to fetch a Recipe.
//
// As of Radius 0.60 only `BasicAuth` is implemented; `AzureWI` and `AwsIrsa` are declared in the
// schema but not yet supported. Use a scoped ACR token rather than enabling the ACR admin user:
//
//   az acr token create --registry <acr> --name recipe-puller \
//       --repository recipes/kubernetes-containers content/read --output json
//
// (one --repository per Recipe under recipes/ at the repository root)
//
// DEPLOYMENT ORDER
// The Environment references these settings, so the two cannot be created in a single pass.
// Deploy in this order:
//
//   1. rad deploy deploy/environments/azure.bicep                          (Environment, no auth)
//   2. rad deploy deploy/recipe-registry-credentials.bicep -e oms-azure                  (this file)
//   3. rad deploy deploy/environments/azure.bicep -p bicepSettingsId=<output of step 2>
//
// scripts/azure/deploy.ps1 and scripts/azurelocal/deploy.ps1 perform all three automatically.

extension radius

@description('Registry hostname the Recipes are pulled from, for example mycr.azurecr.io. Must match the host in the Recipe Pack source exactly.')
param registryHost string

@description('Registry username. For an ACR token this is the token name.')
param registryUsername string

@description('Registry password. For an ACR token this is a generated token password.')
@secure()
param registryPassword string

resource registrySecret 'Applications.Core/secretStores@2023-10-01-preview' = {
  name: 'oms-registry-credentials'
  properties: {
    // Deliberately NOT Radius.Security/secrets. That Resource Type is provisioned by a Recipe, and
    // its Recipe lives in the very registry these credentials unlock (always the case on Azure Local),
    // so creating it fails with 401 before the credentials exist. Applications.Core/secretStores is
    // built into the control plane and needs no Recipe, which breaks the cycle.
    resource: 'radius-system/oms-registry-credentials'
    type: 'basicAuthentication'
    data: {
      username: {
        #disable-next-line use-secure-value-for-secure-inputs
        value: registryUsername
      }
      password: {
        #disable-next-line use-secure-value-for-secure-inputs
        value: registryPassword
      }
    }
  }
}

resource bicepRegistry 'Radius.Core/bicepSettings@2025-08-01-preview' = {
  name: 'oms-registry-auth'
  properties: {
    // Keyed by hostname. Radius matches this against the host in each Recipe's source.
    registryAuthentications: {
      '${registryHost}': {
        authenticationMethod: 'BasicAuth'
        basicAuthSecretId: registrySecret.id
      }
    }
  }
}

output bicepSettingsId string = bicepRegistry.id
output secretId string = registrySecret.id
