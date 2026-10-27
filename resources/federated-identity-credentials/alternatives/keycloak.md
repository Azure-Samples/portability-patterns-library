# Keycloak as an alternative to workload identity federation

[Keycloak](https://www.keycloak.org/documentation) is an open-source identity provider you run yourself, here in the Azure Local cluster. With its Kubernetes service account feature, it validates a pod's service account token and issues an access token, as Entra ID does for a federated identity credential. Applications request the token with standard OAuth 2.0 rather than the Azure SDK.

## Entra concepts in Keycloak

| Entra ID (Azure) | Keycloak (Azure Local) | Notes |
|---|---|---|
| User-assigned managed identity | Confidential client with a service account | One client per workload identity. |
| Federated identity credential: issuer | Kubernetes identity provider in the realm, set to the cluster's issuer | Requires the `kubernetes-service-accounts` feature. |
| Federated identity credential: subject | The client's federated JWT authenticator, matching `system:serviceaccount:<namespace>:<service account>` | |
| Federated identity credential: audience `api://AzureADTokenExchange` | The realm's issuer URL, used as the token's audience | Set on the projected token in the pod. |
| AKS OIDC issuer | The cluster API server's issuer and signing keys | Keycloak needs the `system:service-account-issuer-discovery` role and the cluster CA to read them. |
| Workload identity webhook | A projected service account token volume in the pod spec | Nothing injects it for you. |
| `WorkloadIdentityCredential` in the Azure SDK | Your own token client | `client_credentials` grant, with the service account token as a JWT bearer client assertion. |
| Azure role assignment | Claims in the access token | For example an audience and a scopes claim that RabbitMQ checks. |

AKS on Azure Local also offers Entra workload identity itself, [in preview](https://learn.microsoft.com/azure/aks-hybrid-edge/local/hyperconverged/workload-identity). It depends on reaching Entra ID, so the sample uses Keycloak to keep working without the Azure link.

## How the Order Management sample does it

```text
Pod  ──(service account token)──►  Keycloak  ──(access token)──►  RabbitMQ
 ▲                                     │
 └── projected by the Recipe Pack      └── trusts the cluster's issuer for one service account
```

| Step | In the sample |
|---|---|
| Keycloak on site, with the Kubernetes feature and access to the cluster's signing keys | [keycloak.yaml](../../../samples/OrderManagementApp/infra/azurelocal/keycloak/keycloak.yaml); [Keycloak README](../../../samples/OrderManagementApp/infra/azurelocal/keycloak/README.md) for setup |
| The trust: Kubernetes identity provider, and client `oms-workloads` bound to the app's service account | [realm.json](../../../samples/OrderManagementApp/infra/azurelocal/keycloak/realm.json); the Azure counterpart is the federated credential in [platform-resources.bicep](../../../samples/OrderManagementApp/infra/azure/platform-resources.bicep) |
| Permissions as claims: audience `rabbitmq` and a `rabbitmq_scopes` claim | [realm.json](../../../samples/OrderManagementApp/infra/azurelocal/keycloak/realm.json) |
| Token and Keycloak's CA mounted into every pod | [azure-local.bicep](../../../recipe-packs/azure-local.bicep), through the container Recipe |
| Token client: exchange, cache, refresh before expiry | [WorkloadTokenProvider.cs](../../../samples/OrderManagementApp/src/OrderManagement.Shared/Identity/WorkloadTokenProvider.cs) |
| A service that accepts the token | [rabbitmq-queue.bicep](../../../recipes/message-queue/azure-local/rabbitmq/rabbitmq-queue.bicep) turns on RabbitMQ's OAuth 2.0 backend for the Keycloak issuer |
| Troubleshooting | [authentication.md](../../../samples/OrderManagementApp/docs/authentication.md#workloads) |

## Not covered by the sample

The sample's Keycloak setup is sample code. Before production, add:

- more than one Keycloak replica, and a highly available, backed-up database;
- certificates from your organization's CA, rather than the CA the setup script generates;
- an externally reachable service account issuer for the cluster if Keycloak runs outside it (the sample runs Keycloak in the same cluster);
- protection for the Keycloak administrator account and a plan for rotating signing keys.

## References

- [Workload identity federation](https://learn.microsoft.com/entra/workload-id/workload-identity-federation)
- [Keycloak documentation](https://www.keycloak.org/documentation)
- [Kubernetes service account token volume projection](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/#serviceaccount-token-volume-projection)
- [OAuth 2.0 JWT client assertion (RFC 7523)](https://www.rfc-editor.org/rfc/rfc7523)
