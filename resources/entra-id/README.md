# Microsoft Entra ID → Azure Local

On Azure, users sign in to web apps and APIs through Microsoft Entra ID: app registrations, delegated scopes and app roles. A workload on Azure Local that has to keep working while the site is cut off from Azure needs an identity provider on site. This guide covers user sign-in and the roles apps check. How services sign in without a secret is in the [Microsoft Entra Workload ID guide](../workload-identity/README.md).

| Target | Alternative | Portability class | Availability | Summary |
|---|---|---|---|---|
| Azure Local | [Keycloak with Active Directory](./alternatives/keycloak.md) | `protocol-compatible` | Sample available | Open-source identity provider you run on site, with users and groups read from Active Directory. Standard OpenID Connect and OAuth 2.0, so the Microsoft identity libraries keep working with different settings. |

## What carries over

- **The protocols:** OpenID Connect sign-in with the authorization code flow and PKCE in the browser, and OAuth 2.0 bearer tokens to the API.
- **The libraries:** MSAL.js in the browser and Microsoft.Identity.Web in the API, pointed at the on-site identity provider.
- **The authorization code:** role checks on the `roles` claim, and scope checks on `scp`, if the identity provider issues tokens with the same claims.
- **The people:** if Active Directory is already the source of users and groups for Entra ID, through [Microsoft Entra Connect](https://learn.microsoft.com/entra/identity/hybrid/connect/whatis-azure-ad-connect), the same accounts and groups exist on site.
- **Sign-in while offline:** with the identity provider and Active Directory both on site, users keep signing in when the link to Azure is down.

## What you need to change

1. **Run an identity provider on site** and operate it: database, TLS, backups, high availability.
2. **Connect it to Active Directory** over LDAPS, with a read-only account limited to the users and groups the app needs.
3. **Recreate each app registration as a client:** the browser app as a public client with PKCE and its redirect URIs, the API as a client that tokens are issued for, its delegated scope as a client scope.
4. **Recreate app roles as roles** in the identity provider, granted to Active Directory groups, in place of Entra app role assignments to users and groups.
5. **Shape the tokens like Entra's:** `aud`, `scp`, `roles` and `oid`. Claims the app reads that only Entra issues, such as `tid`, need a replacement or a code change.
6. **Configure the libraries per target:** the authority and metadata address for Microsoft.Identity.Web, and the known authorities for MSAL so it doesn't expect `login.microsoftonline.com`. Deliver them from the deployment, not the build.
7. **Replace the Entra features the app relies on**, such as Microsoft Graph, Conditional Access, guest users or admin consent. Check what the app uses before choosing.

How Entra concepts map to Keycloak, and how the sample does each step: [Keycloak with Active Directory](./alternatives/keycloak.md).

## Observed limitations

| Pattern | Limitation for this resource |
|---|---|
| [Identity and access management](https://learn.microsoft.com/azure/well-architected/security/identity-access) | No Conditional Access, Identity Protection or Privileged Identity Management. Multifactor authentication is available in Keycloak (one-time passwords, WebAuthn) but set up separately. No Microsoft Graph: apps that read users or groups through it need another API. |
| [Reliability](https://learn.microsoft.com/azure/well-architected/reliability/) | Sign-in keeps working without Azure, but the identity provider and the domain controllers become critical on site. If either is down, users can't sign in. |
| [Security](https://learn.microsoft.com/azure/well-architected/security/) | You protect the identity provider's administration, signing keys and certificates, and the account it reads Active Directory with. Browsers must trust the certificate it serves. |

**Data:** users and groups stay in Active Directory. App registrations and role assignments don't move; recreate them as clients and group-to-role grants. Users sign in again after a switch, because sessions and tokens from Entra ID aren't valid on site.

## Sample

The [Order Management sample](../../samples/OrderManagementApp/README.md) signs users in with Entra ID on Azure and with Keycloak backed by Active Directory on Azure Local. The browser app and API code are the same; only their settings change. [Keycloak with Active Directory](./alternatives/keycloak.md#how-the-order-management-sample-does-it) points to the code and configuration for each step above.
