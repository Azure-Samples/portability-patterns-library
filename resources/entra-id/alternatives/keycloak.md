# Keycloak with Active Directory as an alternative to Microsoft Entra ID

[Keycloak](https://www.keycloak.org/documentation) is an open-source identity provider (Apache-2.0) you run yourself, here in the Azure Local cluster. It reads users and groups from Active Directory over LDAPS and signs users in with OpenID Connect. With the right claims in its tokens, apps written for Entra ID with MSAL.js and Microsoft.Identity.Web work against it with different settings only.

> **Scope:** this page covers user sign-in and the roles apps check. In the sample, the same Keycloak also gives services their identity; see [Keycloak for workload identity](../../workload-identity/alternatives/keycloak.md).

## Entra concepts in Keycloak

| Entra ID (Azure) | Keycloak (Azure Local) | Notes |
|---|---|---|
| Tenant | Realm | |
| Users and groups, synced from Active Directory | [LDAP user federation](https://www.keycloak.org/docs/latest/server_admin/index.html#_ldap), read-only, limited to one OU | Users are imported on first sign-in and kept in step with the directory; nothing is written back. |
| App registration for a browser app | Public client, standard flow with PKCE, redirect URIs | |
| App registration for an API, identifier URI and delegated scope | Confidential client for the API, and a client scope named like the Entra scope | The scope adds the API to `aud` and puts the scope name in `scp`. |
| App roles for users, assigned to users or groups | Realm roles, granted to the groups imported from Active Directory | A protocol mapper puts them in `roles`. |
| App roles for applications | Client roles, assigned to service accounts | See the [Microsoft Entra Workload ID guide](../../workload-identity/alternatives/keycloak.md). |
| v2 access token claims (`aud`, `scp`, `roles`, `oid`) | Protocol mappers that issue the same claim names | Entra-only claims such as `tid` aren't issued. |
| Authority `https://login.microsoftonline.com/<tenant>/v2.0` | Realm URL `https://<keycloak>/realms/<realm>` | Microsoft.Identity.Web appends `/v2.0` to an authority, so give it the metadata address explicitly. MSAL needs the Keycloak host in `knownAuthorities`. |
| Conditional Access, multifactor authentication | Authentication flows with one-time passwords or WebAuthn | No policies based on device, location or risk. |
| Microsoft Graph | Keycloak Admin REST API | A different API; apps calling Graph need changes. |
| Sign-in logs | Keycloak events | Turned on per realm; the sample doesn't turn them on. |

## How the Order Management sample does it

```text
Browser (MSAL.js)  ──sign in──►  Keycloak  ──LDAPS──►  Active Directory (users, groups)
       │                            │
       │ access token (aud, scp, roles, oid)
       ▼
API (Microsoft.Identity.Web) checks scope access_as_user and the roles claim
```

| Step | In the sample |
|---|---|
| Same app code on both targets | [app.js](../../../samples/OrderManagementApp/src/OrderManagement.Api/wwwroot/js/app.js) reads the identity provider, client and scope from `/config.json`; [Program.cs](../../../samples/OrderManagementApp/src/OrderManagement.Api/Program.cs) calls `AddMicrosoftIdentityWebApi` as for any Entra API |
| Roles the API checks | [OrderAuthorization.cs](../../../samples/OrderManagementApp/src/OrderManagement.Api/OrderAuthorization.cs): `Orders.Read`, `Orders.Create`, `Inventory.Manage` |
| Entra registrations | [app-identity.bicep](../../../samples/OrderManagementApp/infra/azure/app-identity.bicep): browser app, API with scope `access_as_user` and app roles, role assignments |
| Keycloak counterparts | [realm.json](../../../samples/OrderManagementApp/infra/azurelocal/keycloak/realm.json): clients `oms-spa` and `oms-api`, client scope `api://oms-api/access_as_user` with mappers for `aud`, `scp`, `roles` and `oid`, realm roles granted to groups |
| Active Directory | [ad-setup.ps1](../../../samples/OrderManagementApp/scripts/infra/azurelocal/ad-setup.ps1): OU `OMS`, groups `oms-app-readers`, `oms-app-writers` and `oms-inventory-admins` for the app, `oms-operators` for Grafana and `oms-identity-admins`, a restricted read-only bind account, LDAPS. See [Connect your Active Directory](../../../samples/OrderManagementApp/docs/authentication.md#connect-your-active-directory). |
| Keycloak on site | [keycloak.ps1](../../../samples/OrderManagementApp/scripts/infra/azurelocal/keycloak.ps1) and the [Keycloak folder](../../../samples/OrderManagementApp/infra/azurelocal/keycloak/README.md): two replicas on separate nodes, an address on the site network from the Arc load balancer, a certificate from the site CA, brute-force protection, and a network policy. The realm is applied with site values by keycloak-config-cli on every deployment, so a changed `realm.json` or site value takes effect by deploying again. Its database is a CloudNativePG cluster with backups, or one PostgreSQL server with availability `standard`, reached over verified TLS. |
| Settings per target | [azurelocal.ps1](../../../samples/OrderManagementApp/scripts/deploy/azurelocal.ps1) sets the authority, metadata address and known authorities for the API and browser app |
| Other apps on the same sign-in | Grafana signs in through Keycloak too. Only the realm role `Operations.Monitor`, from directory group `oms-operators`, gets in. |

## Not covered by the sample

The sample's setup is for demonstration. Depending on your workload's requirements, a production deployment might also need:

- a copy of its database backups off the cluster;
- multifactor authentication;
- certificates from your organization's CA, rather than the CA the setup script generates;
- protection for the Keycloak administrator account and a plan for rotating signing keys;
- event logging, and its retention.

## References

- [Keycloak server administration](https://www.keycloak.org/docs/latest/server_admin/index.html)
- [Microsoft identity platform](https://learn.microsoft.com/entra/identity-platform/v2-overview)
- [Access token claims](https://learn.microsoft.com/entra/identity-platform/access-token-claims-reference)
- [App roles](https://learn.microsoft.com/entra/identity-platform/howto-add-app-roles-in-apps)
- [MSAL.js configuration](https://github.com/AzureAD/microsoft-authentication-library-for-js/blob/dev/lib/msal-browser/docs/configuration.md)
- [Microsoft.Identity.Web](https://learn.microsoft.com/entra/msal/dotnet/microsoft-identity-web/)
- [Conditional Access](https://learn.microsoft.com/entra/identity/conditional-access/overview)
