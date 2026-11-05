# Keycloak as an alternative to Microsoft Entra ID for workload identity

[Keycloak](https://www.keycloak.org/documentation) is an open-source identity provider you run yourself, here in the Azure Local cluster. With [federated client authentication](https://www.keycloak.org/2026/01/federated-client-authentication), it validates a pod's Kubernetes service account token and issues an access token, as Entra ID does through a federated identity credential. Applications request the token with standard OAuth 2.0 rather than the Azure SDK.

## Entra concepts in Keycloak

| Entra ID (Azure) | Keycloak (Azure Local) | Notes |
|---|---|---|
| User-assigned managed identity | Confidential client with a service account | One client per service, as one managed identity per service on Azure. |
| Federated identity credential: issuer | Kubernetes identity provider in the realm: the cluster's issuer, and where to read its signing keys | Requires the `kubernetes-service-accounts` feature. Point `issuerDiscoveryUrl` at the API server, `https://kubernetes.default.svc`. |
| Federated identity credential: subject | The client's federated JWT authenticator, matching `system:serviceaccount:<namespace>:<service account>` | |
| Federated identity credential: audience `api://AzureADTokenExchange` | The realm's issuer URL, used as the token's audience | Set on the projected token in the pod. Keycloak recommends tokens valid for at most 10 minutes; the sample uses 600 seconds. |
| AKS OIDC issuer | The cluster API server's issuer and signing keys | Keycloak needs the `system:service-account-issuer-discovery` role and the cluster CA to read them. |
| Workload identity webhook | A projected service account token volume in the pod spec | Nothing injects it for you. |
| `WorkloadIdentityCredential` in the Azure SDK | An OAuth 2.0 client, such as Duende.AccessTokenManagement | `client_credentials` grant, with the service account token as a JWT bearer client assertion, read from the file on every request because the kubelet replaces it. |
| Azure role assignment | Claims in the access token | For example an audience and a scopes claim that RabbitMQ checks. |
| Application roles of another app registration, assigned to the managed identity | Client roles of the called service's client, assigned to the caller's service account and mapped into the `roles` claim | The called service checks `roles` the same way on both targets. |

AKS on Azure Local also offers Entra workload identity itself, [in preview](https://learn.microsoft.com/azure/aks-hybrid-edge/local/hyperconverged/workload-identity). It depends on reaching Entra ID, so the sample uses Keycloak to keep working without the Azure link. The sample's cluster does have it turned on, only for the [Key Vault Secret Store extension](../../key-vault/alternatives/secret-store-extension.md). That gives the cluster's tokens a public issuer URL hosted in Azure; Keycloak accepts that URL in the tokens but reads the signing keys from the API server, so the exchange still needs nothing in Azure.

## How the Order Management sample does it

```text
Pod  ──(service account token)──►  Keycloak  ──(access token)──►  RabbitMQ, inventory service
 ▲                                     │
 └── projected by the Recipe Pack      └── trusts the cluster's issuer for that service's account
```

| Step | In the sample |
|---|---|
| Keycloak on site, with the Kubernetes feature and access to the cluster's signing keys | [keycloak.yaml](../../../samples/OrderManagementApp/infra/azurelocal/keycloak/keycloak.yaml); [Keycloak README](../../../samples/OrderManagementApp/infra/azurelocal/keycloak/README.md) for setup |
| The trust: Kubernetes identity provider reading keys from the API server, and one client per service, `workload-<service>`, bound to that service's account | [realm.json](../../../samples/OrderManagementApp/infra/azurelocal/keycloak/realm.json); the Azure counterpart is the federated credential per service in [platform-resources.bicep](../../../samples/OrderManagementApp/infra/azure/platform-resources.bicep) |
| Permissions as claims: audience `rabbitmq` with a `rabbitmq_scopes` claim, and audience `oms-inventory` with the caller's roles | [realm.json](../../../samples/OrderManagementApp/infra/azurelocal/keycloak/realm.json) |
| A service account per service, and the token and Keycloak's CA mounted into each pod | [azure-local.bicep](../../../recipe-packs/azure-local.bicep), through the container Recipe |
| Choosing the credential at startup: Entra workload identity, a Keycloak client, or none | [WorkloadIdentity.cs](../../../samples/OrderManagementApp/src/OrderManagement.Shared/Identity/WorkloadIdentity.cs) reads the `AZURE_*` or `IDENTITY_*` variables the platform sets |
| Token client: exchange, cache, refresh before expiry | Duende.AccessTokenManagement, with [ServiceAccountTokenAssertion.cs](../../../samples/OrderManagementApp/src/OrderManagement.Shared/Identity/ServiceAccountTokenAssertion.cs) as the client assertion. [ServiceTokenHandlers.cs](../../../samples/OrderManagementApp/src/OrderManagement.Shared/Identity/ServiceTokenHandlers.cs) adds the token to calls to the inventory service; [KeycloakCredentialsProvider.cs](../../../samples/OrderManagementApp/src/OrderManagement.Shared/Messaging/KeycloakCredentialsProvider.cs) gives it to RabbitMQ and refreshes it on the open connection. |
| Services that accept the token | [rabbitmq-queue.bicep](../../../recipes/message-queue/azure-local/rabbitmq/rabbitmq-queue.bicep) turns on RabbitMQ's OAuth 2.0 backend; [InventoryAuthentication.cs](../../../samples/OrderManagementApp/src/OrderManagement.Inventory/InventoryAuthentication.cs) checks the audience and roles |
| Troubleshooting | [authentication.md](../../../samples/OrderManagementApp/docs/authentication.md#workloads) |

## Not covered by the sample

The sample's Keycloak setup is sample code. Before production, see [operating Keycloak](../../entra-id/alternatives/keycloak.md#not-covered-by-the-sample) in the Microsoft Entra ID guide; Keycloak serves both user sign-in and workloads.

**Where Keycloak runs:** the sample runs Keycloak in the same cluster as the app, so it can read the cluster's signing keys from the API server. Running it outside the cluster, for example on a VM, needs network access to the API server and a credential to read the keys. This project hasn't tested that.

## References

- [Workload identity federation](https://learn.microsoft.com/entra/workload-id/workload-identity-federation)
- [Keycloak federated client authentication](https://www.keycloak.org/2026/01/federated-client-authentication)
- [Keycloak documentation](https://www.keycloak.org/documentation)
- [Kubernetes service account token volume projection](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/#serviceaccount-token-volume-projection)
- [OAuth 2.0 JWT client assertion (RFC 7523)](https://www.rfc-editor.org/rfc/rfc7523)
