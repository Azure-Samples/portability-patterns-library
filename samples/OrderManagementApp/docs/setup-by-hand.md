# Set up by hand

Everything the scripts in [scripts/](../scripts) do, as the files in this repository and the
commands that apply them. Use it to understand what a site needs, or to run each piece yourself.
Paths are relative to the sample folder, [samples/OrderManagementApp](../).

- [Azure](#azure)
- [Azure Local](#azure-local)
- [Deploy the app](#deploy-the-app) (both platforms)

## Azure

### What you need

| Need | In this sample |
|---|---|
| AKS with the OIDC issuer and workload identity | [infra/azure/platform.bicep](../infra/azure/platform.bicep) |
| Azure Container Registry for images and Recipes, with AcrPull for the cluster | same template |
| A user-assigned managed identity with a federated credential for the app's service account | same template |
| Radius on the cluster, with an Azure credential so Recipes can create Azure resources | `rad install kubernetes`, `rad credential register azure wi` |
| Entra app registrations for the API and the browser app, with app roles and assignments | [infra/azure/app-identity.bicep](../infra/azure/app-identity.bicep) (Microsoft Graph Bicep) |
| Ingress with a public HTTPS name | AKS app routing (managed NGINX) and cert-manager, see [provision-ingress.ps1](../scripts/infra/azure/provision-ingress.ps1) |

The platform template needs Owner or User Access Administrator on the subscription, because it
assigns roles. The app registrations need the right to register apps in Entra ID.

### Steps

```powershell
# 1. Platform: resource group, AKS, ACR, managed identities
az deployment sub create --location <region> --template-file infra/azure/platform.bicep `
    -p location=<region> clusterAdminObjectIds='["<your object id>"]'

# 2. Cluster credentials (local accounts are off, so kubectl signs in with Entra ID)
az aks get-credentials --resource-group bcd-infra --name bcd-aks
kubelogin convert-kubeconfig -l azurecli

# 3. The app's service account, annotated with the workload identity's client ID
kubectl create namespace oms-azure
kubectl -n oms-azure create serviceaccount oms-workload-identity
kubectl -n oms-azure annotate serviceaccount oms-workload-identity azure.workload.identity/client-id=<workloadIdentityClientId output>
kubectl -n oms-azure label serviceaccount oms-workload-identity azure.workload.identity/use=true

# 4. Radius, with an Azure credential that uses workload identity
rad install kubernetes --set global.azureWorkloadIdentity.enabled=true
rad workspace create kubernetes oms-azure --context bcd-aks
rad credential register azure wi --client-id <radiusIdentityClientId output> --tenant-id <tenant>

# 5. App registrations for sign-in
az deployment sub create --location <region> --template-file infra/azure/app-identity.bicep `
    -p spaOrigins='["https://<app host name>"]' ownerObjectIds='["<your object id>"]'
```

Then set up HTTPS ingress, and [deploy the app](#deploy-the-app).

## Azure Local

### What you need

| Need | Why | In this sample |
|---|---|---|
| An Azure Local instance connected to Azure, with a custom location and a running Arc resource bridge | creates the cluster | already there; [preflight.ps1](../scripts/infra/azurelocal/preflight.ps1) checks it |
| Free addresses on the infrastructure network: control plane, node pool, load balancer range | cluster networking | you choose them; they go in the platform template's parameters |
| AKS enabled by Arc, on a logical network of the instance, with an Entra admin group | runs the app and the Recipes | [infra/azurelocal/platform.bicep](../infra/azurelocal/platform.bicep) |
| A registry the cluster can pull from without Azure | pods restarted during an outage must find their images, and Radius its Recipes | ACR (Premium, same template) + **ACR connected registry** inside the cluster ([connected-registry.bicep](../infra/azurelocal/connected-registry.bicep)) |
| Active Directory | users and groups; Kerberos for SQL | the domain the Azure Local instance already uses |
| An identity provider on site | sign-in and service tokens without Entra | **Keycloak**, federated to AD, in [infra/azurelocal/keycloak](../infra/azurelocal/keycloak) |
| Ingress | users reach the app over HTTPS | Arc load balancer (platform template) + NGINX ingress ([values.yaml](../infra/azurelocal/ingress-nginx/values.yaml)) |
| Radius | deploys the app | installed from the connected registry, so it starts offline |

### Steps

**1. Platform.** Creates the ACR, logical network, cluster and its admin group, and the Arc load
balancer. It finds your instance's custom location and virtual switch by name.

```powershell
az deployment sub create --location <region> --template-file infra/azurelocal/platform.bicep `
    -p location=<region> registryName=<acr-name> azureLocalResourceGroup=<rg> customLocationName=<name> `
       vmSwitchName=<switch> addressPrefix=<cidr> gateway=<ip> dnsServers='["<ad-dns-ip>"]' `
       ipPoolStart=<ip> ipPoolEnd=<ip> controlPlaneIp=<ip> kubernetesVersion=<version> `
       sshPublicKey="<key>" loadBalancerAddresses=<first-ip>-<last-ip>
az aksarc get-credentials --resource-group bcd-azurelocal --name bcd-aksarc --admin
```

The `--admin` credentials use a client certificate, so `kubectl` keeps working without Azure.

**2. Images.** Copy every image and Recipe in [images.txt](../infra/azurelocal/images.txt) into the
ACR, one command per line:

```powershell
az acr import --name <acr-name> --source <source> --image <target>
```

**3. Connected registry.** Deploy [connected-registry.bicep](../infra/azurelocal/connected-registry.bicep)
with `serviceClusterIp` set to an unused address in the cluster's service range
(`kubectl get service kubernetes` shows where it starts); the registry's certificate is issued for
that address. It can't be done in one pass: the Arc extension needs a sync password, which only
exists once the connected registry does. Deploy it, generate the sync token's password
(`az acr token credential generate`), then deploy it again with the connection string.
[connected-registry.ps1](../scripts/infra/azurelocal/connected-registry.ps1) does this in its Azure
stage, and in its Site stage writes the `azurelocal-registry` pull secret into each namespace that
pulls images.

**4. Active Directory and Keycloak.** Follow
[Connect your Active Directory](./authentication.md#connect-your-active-directory), then
[infra/azurelocal/keycloak/README.md](../infra/azurelocal/keycloak/README.md).

**5. Ingress.** Install NGINX with [values.yaml](../infra/azurelocal/ingress-nginx/values.yaml) (the
command is at the top of the file), and give it a certificate for the app's address from your
site's CA:

```powershell
kubectl create namespace oms-azurelocal
kubectl -n oms-azurelocal create secret tls oms-app-tls --cert <app.crt> --key <app.key>
```

**6. Radius**, from the connected registry:

```powershell
rad install kubernetes --skip-contour-install `
    --set global.imageRegistry=<connected registry> --set global.imageTag=0.60 `
    --set global.imagePullSecrets[0].name=azurelocal-registry
rad workspace create kubernetes oms-azurelocal --context bcd-aksarc
```

**When the site loses its link to Azure:** running pods, pod restarts, token exchange, directory
lookups and `kubectl` with the admin kubeconfig keep working. Pushing new images, Azure management of
the cluster and Entra sign-in to the cluster do not.

## Deploy the app

With the platform in place, deploying is only Radius commands. For Azure Local:

```powershell
# One-time: resource group, the queue resource type, a scratch environment to deploy from
rad group create oms
rad workspace create kubernetes oms-azurelocal --context <kube-context> --group oms --force
rad resource-type create messageQueues -f ../../recipes/message-queue/messageQueues.yaml
rad bicep publish-extension -f ../../recipes/message-queue/messageQueues.yaml --target ../../recipes/message-queue/messageQueues.tgz
rad env create bootstrap --group oms

# Publish the Recipes, then bind them for this platform
./scripts/deploy/publish-recipes.ps1 -Registry <acr>.azurecr.io -Platform azure-local
rad deploy ../../recipe-packs/azure-local.bicep -e bootstrap -p registry=<connected registry> ...
rad deploy deploy/environments/azurelocal.bicep -e bootstrap

# The app
rad deploy deploy/app.bicep -e oms-azurelocal -p apiImage=... -p processorImage=... -p sqlAdminPassword=...
```

For Azure, use `recipe-packs/azure.bicep` and `deploy/environments/azure.bicep` instead. When Recipes
come from a private registry (always on Azure Local), Radius also needs pull credentials: see
[deploy/recipe-registry-credentials.bicep](../deploy/recipe-registry-credentials.bicep). The Recipe
Pack's parameters are documented in the pack itself.
