# Microsoft Entra Workload ID → Azure Local

On Azure, Microsoft Entra Workload ID lets a pod exchange its Kubernetes service account token for an Entra token, so the workload stores no secret. This guide shows how to keep that pattern on Azure Local, with an identity provider on site instead of Entra ID. Workloads then keep signing in when the link to Azure is down.

> **About the alternatives:** the open-source alternatives in this guide are examples this project explored, not Microsoft recommendations, and other alternatives may exist. Evaluate any alternative against your own requirements.

| Target | Alternative | Portability class | Availability | Summary |
|---|---|---|---|---|
| Azure Local | [Keycloak](./alternatives/keycloak.md) | `adapter-required` | Sample available | Open-source identity provider you run on site in place of Entra ID. Each federated identity credential becomes a Keycloak client that trusts the cluster's tokens; the client code and permission model change. |

## What carries over

- **The pattern:** the cluster issues a short-lived token to the pod. The identity provider trusts that token for one service account and exchanges it for an access token. No secret is stored.
- **The Kubernetes side:** the service account, the projected token, and the subject `system:serviceaccount:<namespace>:<service account>`.
- **The standards:** OIDC discovery for the cluster's signing keys, and the OAuth 2.0 client credentials grant with a JWT client assertion.
- **Calls between your own services:** the called service checks the token's audience and `roles` claim, with the same code on both targets. The roles themselves are defined like a user-facing app's; see the [Microsoft Entra ID guide](../entra-id/README.md).

## What you need to change

1. **Run an identity provider on site** that accepts Kubernetes service account tokens. You handle its database, TLS, backups and high availability.
2. **Let it check tokens without Azure.** It must fetch the cluster's signing keys from the cluster's API server. If the cluster also uses Entra workload identity, the token issuer is an Azure address; don't fetch keys from there.
3. **Recreate each federated identity credential as a client** in the identity provider, bound to the same service account. Keep one identity per service.
4. **Add the token to each pod yourself.** There's no webhook to do it. Mount a projected service account token for the identity provider, and run the pod as that service account.
5. **Replace the Azure SDK credential with an OAuth 2.0 client.** It sends the token file to the identity provider and gets an access token back. Cache that token and refresh it before it expires.
6. **Replace Azure role assignments** with claims in the access token, which each service checks.

How Entra concepts map to Keycloak, and how the sample does each step: [Keycloak as an alternative](./alternatives/keycloak.md).

## Observed limitations

| Pattern | Limitation for this resource |
|---|---|
| [Workload identity](https://learn.microsoft.com/entra/workload-id/workload-identities-overview) | It only works with services that accept OAuth 2.0 tokens from your identity provider. In the sample, RabbitMQ and the inventory service do. The databases and the object store use passwords and keys. |
| [Reliability](https://learn.microsoft.com/azure/well-architected/reliability/) | The identity provider becomes a critical dependency on site. If it's down, pods can't get new tokens once their current ones expire. |
| [Security](https://learn.microsoft.com/azure/well-architected/security/) | You protect the identity provider's administration, signing keys and certificates, which Entra handles for you on Azure. |

**Data:** identities and role assignments don't move. Recreate the clients and their permissions in the identity provider.

## Sample

The [Order Management sample](../../samples/OrderManagementApp/README.md) gives each service its own identity: Entra workload identity on Azure and Keycloak on Azure Local, with the same container images. [Keycloak as an alternative](./alternatives/keycloak.md#how-the-order-management-sample-does-it) points to the code and configuration for each step above.
