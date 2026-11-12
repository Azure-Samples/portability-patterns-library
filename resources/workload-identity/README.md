# Microsoft Entra Workload ID → Azure Local

On Azure, Microsoft Entra Workload ID lets a pod exchange its Kubernetes service account token for an Entra token, so the workload stores no secret. This guide describes how this project's sample kept that pattern on Azure Local, with an identity provider on site instead of Entra ID, so workloads keep signing in when the link to Azure is down. It describes the alternatives this project explored, what stayed the same and what changed when the sample moved from Azure to Azure Local. The [Sample](#sample) section links the code.

> **About the alternatives:** the open-source alternatives in this guide are examples this project explored, not Microsoft recommendations, and other alternatives may exist. Evaluate any alternative against your own requirements.

| Target | Alternative | Portability class | Availability | Summary |
|---|---|---|---|---|
| Azure Local | [Keycloak](./alternatives/keycloak.md) | `adapter-required` | Sample available | Open-source identity provider you run on site in place of Entra ID. Each federated identity credential becomes a Keycloak client that trusts the cluster's tokens; the client code and permission model change. |

## What stayed the same in the sample

- **The pattern:** the cluster issues a short-lived token to the pod. The identity provider trusts that token for one service account and exchanges it for an access token. No secret is stored.
- **The Kubernetes side:** the service account, the projected token, and the subject `system:serviceaccount:<namespace>:<service account>`.
- **The standards:** OIDC discovery for the cluster's signing keys, and the OAuth 2.0 client credentials grant with a JWT client assertion.
- **Calls between the sample's services:** the inventory service checks the token's audience and `roles` claim, with the same code on both targets. The roles themselves are defined like a user-facing app's; see the [Microsoft Entra ID guide](../entra-id/README.md).

## What the sample needed to change

1. **An identity provider on site** that accepts Kubernetes service account tokens. The sample runs Keycloak in the cluster, with its own database and TLS. Backups and high availability are left to whoever runs the site.
2. **Token checks without Azure.** Keycloak fetches the cluster's signing keys from the cluster's API server. The sample's cluster also uses Entra workload identity, so its token issuer is an Azure address, and Keycloak doesn't fetch keys from there.
3. **Each federated identity credential recreated as a client** in Keycloak, bound to the same service account. Each service keeps its own identity.
4. **The token added to each pod by the platform.** There's no webhook as on AKS. The sample's Recipe Pack mounts a projected service account token for Keycloak and runs the pod as that service account.
5. **An OAuth 2.0 client instead of the Azure SDK credential.** It sends the token file to Keycloak, gets an access token back, caches it and refreshes it before it expires. The credential is chosen at startup.
6. **Claims instead of Azure role assignments.** Each service checks the claims in the access token.

How Entra concepts map to Keycloak, and the sample's code and configuration for each step: [Keycloak as an alternative](./alternatives/keycloak.md).

## Limitations observed in the sample

These are the limitations this project found while building the sample. It isn't a complete list.

| Pattern | Limitation for this resource |
|---|---|
| [Workload identity](https://learn.microsoft.com/entra/workload-id/workload-identities-overview) | It only works with services that accept OAuth 2.0 tokens from the identity provider on site. In the sample, RabbitMQ and the inventory service do. The databases and the object store use passwords and keys. |
| [Reliability](https://learn.microsoft.com/azure/well-architected/reliability/) | The identity provider becomes a critical dependency on site. If it's down, pods can't get new tokens once their current ones expire. |
| [Security](https://learn.microsoft.com/azure/well-architected/security/) | The identity provider's administration, signing keys and certificates are protected on site. Entra handles these on Azure. |

**Data:** identities and role assignments don't move. The sample recreated the clients and their permissions in Keycloak.

## Sample

The [Order Management sample](../../samples/OrderManagementApp/README.md) gives each service its own identity: Entra workload identity on Azure and Keycloak on Azure Local, with the same container images. [Keycloak as an alternative](./alternatives/keycloak.md#how-the-order-management-sample-does-it) links the code and configuration for each change above.
