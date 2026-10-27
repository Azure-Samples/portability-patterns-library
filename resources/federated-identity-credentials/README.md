# Workload identity federation → Azure Local

On Azure, a federated identity credential on a managed identity lets a pod swap its Kubernetes service account token for a Microsoft Entra token, so the workload holds no secret. This guide shows how to keep that pattern on Azure Local with an identity provider on site, so workloads keep authenticating when the link to Azure is down.

| Target | Alternative | Portability class | Availability | Summary |
|---|---|---|---|---|
| Azure Local | [Keycloak](./alternatives/keycloak.md) | `adapter-required` | Sample available | Open-source identity provider you run on site. It trusts the cluster's tokens the way Entra does, but the client code and permission model change. |

## What carries over

- **The pattern:** the cluster signs a short-lived service account token, the identity provider trusts the cluster's issuer for one service account, and the pod exchanges the token for an access token. No secret is stored.
- **The Kubernetes side:** the service account, the projected token, and the subject `system:serviceaccount:<namespace>:<service account>`.
- **The standards:** OIDC discovery for the cluster's signing keys, and the OAuth 2.0 client credentials grant with a JWT client assertion.

## What you need to change

1. **Run an identity provider on site** that can validate Kubernetes service account tokens, and operate it: database, TLS, backups, high availability.
2. **Let it read the cluster's signing keys.** Its issuer URL must match the cluster's, and it needs access to the cluster's OIDC discovery endpoint and its CA.
3. **Recreate each federated identity credential** as a client in the identity provider, bound to the same service account subject.
4. **Project the token into pods yourself.** There's no Entra webhook: add a projected service account token volume whose audience is the identity provider, and run the pods as that service account.
5. **Replace the Azure SDK credential** with a small token client: read the token file, request an access token with it as the client assertion, and refresh before it expires.
6. **Replace Azure role assignments** with claims in the access token that each service checks.

How Entra concepts map to Keycloak, and how the sample does each step: [Keycloak as an alternative](./alternatives/keycloak.md).

## Observed limitations, by pattern

| Pattern (Microsoft Learn) | Limitation for this resource |
|---|---|
| [Workload identity](https://learn.microsoft.com/entra/workload-id/workload-identities-overview) | Only services that accept OAuth 2.0 tokens from your identity provider can use it. In the sample RabbitMQ does, but SQL Server signs in with Kerberos and the storage emulator with a key. |
| [Reliability](https://learn.microsoft.com/azure/well-architected/reliability/) | The identity provider becomes a critical dependency on site. If it's down, pods can't get new tokens once their current ones expire. |
| [Security](https://learn.microsoft.com/azure/well-architected/security/) | You protect the identity provider's administration, signing keys and certificates, which Entra handles for you on Azure. |

**Data:** identities and role assignments don't move. Recreate the clients and their permissions in the identity provider.

## Sample

The [Order Management sample](../../samples/OrderManagementApp/README.md) uses Entra workload identity on Azure and Keycloak on Azure Local, with the same container images. [Keycloak as an alternative](./alternatives/keycloak.md#how-the-order-management-sample-does-it) points to the code and configuration for each step above.
