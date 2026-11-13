# Microsoft Entra ID → Azure Local

On Azure, users sign in to web apps and APIs through Microsoft Entra ID: app registrations, delegated scopes and app roles. A workload on Azure Local that has to keep working while the site has no or limited connectivity to Azure needs an identity provider on site. This guide covers user sign-in and the roles apps check. It describes the alternatives this project explored, what stayed the same and what changed when this project's sample moved from Azure to Azure Local. The [Sample](#sample) section links the code. How services sign in without a secret is in the [Microsoft Entra Workload ID guide](../workload-identity/README.md).

> **About the alternatives:** the open-source alternatives in this guide are examples this project explored, not Microsoft recommendations, and other alternatives may exist. Evaluate any alternative against your own requirements.

| Target | Alternative | Portability class | Availability | Summary |
|---|---|---|---|---|
| Azure Local | [Keycloak with Active Directory](./alternatives/keycloak.md) | `protocol-compatible` | Sample available | Open-source identity provider you run on site, with users and groups read from Active Directory. Standard OpenID Connect and OAuth 2.0, so the Microsoft identity libraries keep working with different settings. |

## What stayed the same in the sample

- **The protocols:** OpenID Connect sign-in with the authorization code flow and PKCE in the browser, and OAuth 2.0 bearer tokens to the API.
- **The libraries:** MSAL.js in the browser and Microsoft.Identity.Web in the API, pointed at the on-site identity provider.
- **The authorization code:** role checks on the `roles` claim, and scope checks on `scp`, because Keycloak issues tokens with the same claims.
- **The people:** the sample reads users and groups from Active Directory on site. An organization whose Entra ID users already come from Active Directory, through [Microsoft Entra Connect](https://learn.microsoft.com/entra/identity/hybrid/connect/whatis-azure-ad-connect), would have the same accounts and groups on site.
- **Sign-in while offline:** with Keycloak and Active Directory both on site, users keep signing in when the link to Azure is down.

## What the sample needed to change

1. **An identity provider on site.** The sample runs Keycloak in the cluster, with its own database, and TLS certificates issued by the site's certificate authority (PKI), which the site has to run. Backups and high availability are left to whoever runs the site.
2. **Keycloak connected to Active Directory** over LDAPS, with a read-only account that sees only the users and groups the app needs. The app itself doesn't connect to Active Directory.
3. **Each app registration recreated as a client.** The browser app became a public client (no client secret, like an Entra single-page app) with PKCE and its redirect URIs. The API became a client that tokens are issued for, and its scope became a client scope.
4. **App roles recreated** in Keycloak, and granted to Active Directory groups.
5. **Tokens with the same claims as Entra:** `aud`, `scp`, `roles` and `oid`. The sample doesn't read claims only Entra issues, such as `tid`. An app that does would need to replace them or change its code.
6. **Sign-in settings per target,** set by the deployment, not the build. Microsoft.Identity.Web gets the authority and metadata address, and MSAL gets the identity provider's host in its known authorities.
7. **No Entra-only features.** The sample doesn't use Microsoft Graph, Conditional Access, guest users or admin consent. An app that does would need another way to provide them.

How Entra concepts map to Keycloak, and the sample's code and configuration for each step: [Keycloak with Active Directory](./alternatives/keycloak.md).

## Limitations observed in the sample

These are the limitations this project found while building the sample. It isn't a complete list.

| Pattern | Limitation for this resource |
|---|---|
| [Identity and access management](https://learn.microsoft.com/azure/well-architected/security/identity-access) | No Conditional Access, Identity Protection or Privileged Identity Management. Multifactor authentication is available in Keycloak (one-time passwords, WebAuthn) but set up separately. No Microsoft Graph: apps that read users or groups through it need another API. |
| [Reliability](https://learn.microsoft.com/azure/well-architected/reliability/) | Sign-in keeps working without Azure, but the identity provider and the domain controllers become critical on site. If either is down, users can't sign in. |
| [Security](https://learn.microsoft.com/azure/well-architected/security/) | The identity provider's administration, signing keys and certificates, and the account it reads Active Directory with, are protected on site. Browsers must trust the certificate it serves. |

**Data:** users and groups stay in Active Directory. App registrations and role assignments don't move. The sample recreated them as clients and group-to-role grants. Users sign in again after a switch, because sessions and tokens from Entra ID aren't valid on site.

## Sample

The [Order Management sample](../../samples/OrderManagementApp/README.md) signs users in with Entra ID on Azure and with Keycloak backed by Active Directory on Azure Local. The browser app and API code are the same; only their settings change. [Keycloak with Active Directory](./alternatives/keycloak.md#how-the-order-management-sample-does-it) links the code and configuration for each change above.
