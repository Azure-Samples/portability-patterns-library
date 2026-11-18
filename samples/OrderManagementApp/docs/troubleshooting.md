# Azure deployment troubleshooting

Normal setup remains `azd up`; see the [README](../README.md). These are optional recovery steps,
not a second deployment procedure. Run examples from `samples\OrderManagementApp` and replace
placeholders with the affected environment's values. For Azure Local, see
[Running on Azure Local](./run-on-azure-local.md).

## Find the underlying error

Read the innermost error and its resource target. `DeploymentFailed`, `RecipeDeploymentFailed`
and a hook exception usually wrap the actual cause.

| Symptom | Recovery |
|---|---|
| Cannot resolve subscription access | Check the subscription ID, tenant and account access. `SERVICE_MANAGEMENT_REFERENCE` is a service tree ID, not a subscription ID. |
| azd login disabled in delegated mode | Use the Azure CLI session; do not change authentication mode or force another login if cached access works. |
| `AADSTS53003` | Conditional Access blocked authentication. Use an approved account/device or contact the tenant administrator; another login flow does not bypass policy. |
| SQL `RegionDoesNotAllowProvisioning` | Choose an allowed region or request [SQL region access](https://learn.microsoft.com/azure/azure-sql/database/quota-increase-request#enable-subscription-access-to-a-region). Repeating the same request does not remove a restriction. |
| PostgreSQL allowed versions `[]` | Check subscription access to that region. An empty list does not prove that the requested version is wrong. |
| AKS size unavailable or quota exceeded | Choose an allowed VM size or request quota. Check both regional and VM-family limits; a capability listing does not reserve capacity. |
| `InvalidDeploymentLocation` for an app-registration deployment | A deployment name is already recorded in another region. Nested deployment names in the [identity template](../infra/azure/app-identity.bicep) must be unique to the environment and region; resource-group deletion does not clear subscription-level history. |
| Database setup or rollout fails | Inspect the job or workload error; see [Application checks](#application-checks). Do not recreate working databases or add static administrator passwords as a workaround. |

After correcting settings, retry the same environment through the existing workflow:

```powershell
azd up --environment <environment-name>
```

Supported settings are listed in [azure.yaml](../azure.yaml). `SQL_LOCATION` and
`POSTGRES_LOCATION` move only their respective databases, potentially adding latency and egress
charges. To move the whole deployment, create a new environment rather than changing the location
of an existing one. Availability and capacity vary by subscription and region.

## HTTPS and certificate issuance

A successful deployment or ready pod does not guarantee a ready HTTPS certificate. Use the printed
hostname, not the public IP. Check certificate and challenge status:

```powershell
kubectl get certificate app-tls --namespace oms-azure --context <cluster-context>
kubectl get challenges.acme.cert-manager.io --namespace oms-azure --context <cluster-context> `
    --output 'custom-columns=NAME:.metadata.name,STATE:.status.state,REASON:.status.reason'
```

**Let's Encrypt HTTP-01 timeout:** external validation servers must reach port 80. Access from your
own network, or an allow rule in the node NSG, does not prove the entire external path is open.
Check the challenge reason with the network owner; do not add unapproved firewall exceptions.

If external validation cannot reach the cluster, use the supported private CA:

```powershell
azd env set PRIVATE_CA true --environment <environment-name>
azd up --environment <environment-name>
```

The workflow exports `bcd-azure-ca.crt` to the sample folder and prints optional client-trust
instructions. Later private-CA deployments overwrite this file; use the correct environment's
certificate. Deployment does not change your trust store.

Only trust a CA you control and intend to trust. Alternatively, verify with a client that accepts
an explicit CA file. Keep certificate-chain and hostname validation enabled. Private CA use does
not open the network or change app authentication.

## Application checks

If database setup fails, use the job name printed by deployment:

```powershell
kubectl get deployments,pods,jobs --namespace oms-azure --context <cluster-context>
kubectl logs job/<dbsetup-job-name> --namespace oms-azure --context <cluster-context>
```

For rollout failures, inspect the affected deployment's logs. Correct the reported connectivity,
TLS or identity issue, then retry `azd up`; the workflow handles database setup and restarts.

Before calling deployment complete:

- All desired replicas of `api`, `processor` and `inventory` are ready.
- `app-tls` is ready, and the printed HTTPS address loads without certificate errors.
- `/healthz/ready` returns HTTP 200 with `Healthy`. This checks the queue and orders database,
  not inventory.
- Sign-in, product loading, placing an order and confirming processing work.

## Cleanup and support

A failed deployment is not a rollback: already-created resources can remain billable. Decide
whether to remove the old environment before a regional move or retain it until the new one works.

```powershell
azd down --environment <environment-name>
```

Verify the target subscription and resource group before confirming. Cleanup deletes data,
the deployment's resource group, AKS managed node group and environment-specific app registrations.
Confirm those are gone; do not delete unrelated resources. Deployment-history records can remain.

For support, provide the failing phase, innermost error, resource type/region, UTC timestamp and
deployment/operation or correlation IDs. Remove tokens, passwords, private keys and environment-file
contents before sharing logs.
