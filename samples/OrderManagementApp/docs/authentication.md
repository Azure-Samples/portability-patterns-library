# How authentication works

There are two kinds of authentication: **users** signing in to the app, and the **app's own pods**
signing in to the queue, storage and SQL. Paths are relative to the sample folder,
[samples/OrderManagementApp](../).

## Users: sign-in and roles

```
1. Browser loads /config.json from the API        → which identity provider, client ID and scope to use
2. MSAL.js redirects the user to the provider     → Entra ID, or Keycloak (password checked against AD)
3. Provider returns an access token to the browser  (authorization code + PKCE)
4. Browser calls /api/... with  Authorization: Bearer <token>
5. API validates the token: issuer, signature, audience, scope 'access_as_user'
6. API checks the 'roles' claim: Orders.Read to list orders, Orders.Create to place one
```

The code is written once, for Entra, and doesn't know which provider it is talking to:

| Piece | File | What it does |
|---|---|---|
| Browser sign-in | [app.js](../src/OrderManagement.Api/wwwroot/js/app.js) | MSAL.js `PublicClientApplication`, built from `/config.json` |
| Browser settings | [SpaSettings.cs](../src/OrderManagement.Api/SpaSettings.cs) | serves `/config.json` from the `Spa` settings; allows the provider's origin in the Content Security Policy |
| Token validation | [Program.cs](../src/OrderManagement.Api/Program.cs) | `AddMicrosoftIdentityWebApi` from the `AzureAd` settings; `RequireScope("access_as_user")` on `/api` |
| Roles | [OrderAuthorization.cs](../src/OrderManagement.Api/OrderAuthorization.cs) | policies on `Orders.Read` / `Orders.Create`; the user's ID is the `oid` claim |

Only the settings differ. They are the `apiAuthentication` and `spaSettings` parameters of
[app.bicep](../deploy/app.bicep), which become `AzureAd__*` and `Spa__*` environment variables on the
API:

| Setting | Entra ID (Azure) | Keycloak (Azure Local) |
|---|---|---|
| `apiAuthentication` | `Instance: https://login.microsoftonline.com/`<br>`TenantId: <tenant>`<br>`ClientId: <API app ID>` | `Authority: https://<keycloak>/realms/oms`<br>`MetadataAddress: <Authority>/.well-known/openid-configuration`<br>`ClientId: oms-api`<br>`Audience: oms-api` |
| `spaSettings` | `Authority: https://login.microsoftonline.com/<tenant>`<br>`ClientId: <SPA app ID>`<br>`ProtocolMode: AAD`<br>`ApiScope: api://<API app ID>/access_as_user` | `Authority: https://<keycloak>/realms/oms`<br>`ClientId: oms-spa`<br>`ProtocolMode: OIDC`<br>`KnownAuthorities: <keycloak host>`<br>`ApiScope: api://oms-api/access_as_user` |

`MetadataAddress` is needed because Microsoft.Identity.Web otherwise adds Entra's `/v2.0` to the
authority. `KnownAuthorities` stops MSAL from checking the authority against Entra.

Both providers need the same registrations. On Entra they're in
[app-identity.bicep](../infra/azure/app-identity.bicep); on Keycloak they're in the realm,
[realm.json](../infra/azurelocal/keycloak/realm.json), with the claim mappers that make the token
match Entra's:

| Needed | Entra ID | Keycloak (realm `oms`) |
|---|---|---|
| The API | app registration exposing scope `access_as_user`, with app roles `Orders.Read`, `Orders.Create` | client `oms-api` with no flows, used only as the token audience; realm roles `Orders.Read`, `Orders.Create` |
| The browser app | SPA app registration, redirect URI = the app's URL | public client `oms-spa`, standard flow with PKCE (S256), redirect URI = the app's URL |
| The scope | `api://<API app ID>/access_as_user` | client scope `api://oms-api/access_as_user`, optional on `oms-spa` |
| Token claims | built in: `aud`, `scp`, `roles`, `oid` | mappers on that scope: `aud` = `oms-api`, `scp` = `access_as_user`, `roles` = realm roles as a flat list, `oid` = the user's ID |
| Who gets which role | app roles assigned to Entra groups | AD groups mapped to realm roles (see [Connect your Active Directory](#connect-your-active-directory)) |

## Workloads: the app's access to the queue, storage and SQL

The API and processor pick their credential from what their connection provides, so the code has
no platform switch:

| Service | Azure | Azure Local | Where the choice is made |
|---|---|---|---|
| Queue | Entra Workload ID: the pod's Kubernetes token is exchanged for an Entra token for Service Bus | the pod's Kubernetes token is exchanged at Keycloak for a token RabbitMQ accepts | [ServiceCollectionExtensions.cs](../src/OrderManagement.Shared/DependencyInjection/ServiceCollectionExtensions.cs): OAuth when the connection has `oauth*` values |
| Object storage | Entra Workload ID | Azurite connection string, issued by the Recipe | [ArchiveOptions.cs](../src/OrderManagement.Shared/Configuration/ArchiveOptions.cs): managed identity when there is no connection string |
| SQL | Entra Workload ID; the app's managed identity is the database admin | Kerberos as the app's AD account, from a keytab the platform mounts; the `sa` login only when no keytab is configured | [SqlOptions.cs](../src/OrderManagement.Shared/Configuration/SqlOptions.cs): Entra with a workload identity, else Kerberos with a keytab, else the SQL login |

- **Azure:** [AzureCredentialFactory.cs](../src/OrderManagement.Shared/Identity/AzureCredentialFactory.cs)
  uses `WorkloadIdentityCredential`. The Recipe Pack gives the pods the `oms-workload-identity`
  service account and the Workload ID label, and the managed identity has a federated credential
  that trusts that service account.
- **Azure Local:** [WorkloadTokenProvider.cs](../src/OrderManagement.Shared/Identity/WorkloadTokenProvider.cs)
  sends the pod's projected Kubernetes token to Keycloak as a client assertion
  (`client_credentials`, `jwt-bearer`) and uses the access token it gets back as the RabbitMQ
  password. Keycloak trusts the cluster's token issuer, the same way Entra trusts it through the
  federated credential. The Recipe Pack projects the token at `/var/run/secrets/identity/token`
  and mounts Keycloak's CA certificate.
- **Azure Local, SQL:** the Recipe Pack mounts a Kerberos client keytab for the app's AD account
  and `krb5.conf`, and sets `KRB5_CLIENT_KTNAME`. Kerberos gets tickets from the keytab on its
  own, so the app connects with `Integrated Security=true` and holds no SQL password. SQL Server
  accepts the ticket with its own keytab and maps it to the app's Windows login, which the SQL
  Recipe creates. See [Let the app sign in to SQL Server with Kerberos](#4-let-the-app-sign-in-to-sql-server-with-kerberos).

Every step runs inside the site, so this keeps working without Azure. The full walkthrough,
including decoded tokens and troubleshooting, is in [workload-identity.md](./workload-identity.md).

## Connect your Active Directory

On Azure, app roles are assigned to Entra groups. On Azure Local the same roles come from **Active
Directory groups**, read by Keycloak. Your directory needs a few objects, and Keycloak needs to
know where to find them.

### 1. Create the objects in AD

Run this as a domain administrator on any machine with the Active Directory PowerShell module
(RSAT), for example the domain controller:

```powershell
$domain = Get-ADDomain
$ou     = "OU=OMS,$($domain.DistinguishedName)"

# An OU for the app's users and groups. Keycloak reads only this OU and below.
New-ADOrganizationalUnit -Name OMS -Path $domain.DistinguishedName

# One group per app role
New-ADGroup -Name oms-app-readers -GroupScope Global -GroupCategory Security -Path $ou   # Orders.Read
New-ADGroup -Name oms-app-writers -GroupScope Global -GroupCategory Security -Path $ou   # Orders.Create

# A read-only bind account for Keycloak. Every authenticated account can read the directory,
# so it needs no privileged group.
New-ADUser -Name svc-keycloak -SamAccountName svc-keycloak -Path $ou `
    -UserPrincipalName "svc-keycloak@$($domain.DNSRoot)" `
    -AccountPassword (Read-Host -AsSecureString 'Bind password') -PasswordNeverExpires $true -Enabled $true

# Give people access by adding them to the groups
Add-ADGroupMember -Identity oms-app-readers -Members <user>
Add-ADGroupMember -Identity oms-app-writers -Members <user>
```

Users who sign in to the app must sit in the OU (or below it). To use an existing OU instead, set
`LDAP_USERS_DN` in [realm-settings.env](../infra/azurelocal/keycloak/realm-settings.env), or pass
its name to `keycloak.ps1 -AdOuName`.

Keycloak should reach the directory over **LDAPS (port 636)**, which needs the domain controller to
have a server certificate from a certificate authority, for example AD Certificate Services. Export
that CA's root certificate as `ca.crt` (Base-64 encoded).

### 2. Give Keycloak the bind account and the CA

```powershell
kubectl create namespace identity
kubectl -n identity create secret generic oms-ad-bind `
    --from-literal=bind-upn=svc-keycloak@<domain> --from-literal=bind-password=<bind password>
kubectl -n identity create secret generic oms-ad-ca --from-file=ca.crt=<path to ca.crt>
```

### 3. How Keycloak uses the directory

[realm.json](../infra/azurelocal/keycloak/realm.json) sets this up:

| Keycloak setting | Value | Effect |
|---|---|---|
| User federation | LDAP, vendor Active Directory, `ldaps://<dc>:636`, users DN = the OU | users sign in with their AD user name (`sAMAccountName`) and password; Keycloak checks the password against AD |
| Edit mode | read only | AD stays the source of truth; Keycloak never writes to it |
| Import | on sign-in | a user appears in Keycloak the first time they sign in; there is no scheduled sync |
| Account controls mapper | on | disabled or locked AD accounts cannot sign in |
| Group mapper | groups DN = the OU, membership from the `member` attribute | AD groups appear as Keycloak groups; membership is read from AD, so changes apply at the user's next sign-in |
| Group → role mapping | `oms-app-readers` → `Orders.Read`, `oms-app-writers` → `Orders.Create` | the roles land in the token's `roles` claim, the same claim Entra uses, so the API's checks are unchanged |

Day to day, granting or removing access is only AD group membership. Nothing changes in Keycloak.

To add a role, create the AD group in the OU, add the role to the API, and map the group to the
role in `realm.json` (or in the admin console: *Groups* → the group → *Role mapping*). On Azure,
the matching step is assigning the app role to an Entra group.

### 4. Let the app sign in to SQL Server with Kerberos

Optional. Without it, SQL falls back to the `sa` login.

SQL Server on Linux, including the container, accepts Active Directory logins through Kerberos
([Microsoft's guide](https://learn.microsoft.com/sql/linux/containers/tutorial-adutil)). The app then
signs in as its own AD account instead of with a SQL password. Kerberos needs only the domain
controller, which is on site, so this keeps working without Azure.

| In AD | Purpose |
|---|---|
| `svc-oms-sql` with SPNs `MSSQLSvc/ordersdb.oms-azurelocal.svc.cluster.local:1433` and `MSSQLSvc/ordersdb.oms-azurelocal.svc.cluster.local` | SQL Server's service account; clients request tickets for these names. The host is the SQL Recipe's Service, `<resource name>.<namespace>.svc.cluster.local` |
| `svc-oms-app` | the app's account; becomes the SQL login `<DOMAIN>\svc-oms-app` |
| AES encryption only on both (`Set-ADUser -KerberosEncryptionType AES128,AES256`) | the keytabs carry AES keys |
| A PTR record for every domain controller (reverse DNS) | SQL Server on Linux resolves each controller's address back to its name before it looks an account up; without it, logins fail with "untrusted domain" |

| In the app namespace | Keys | Used by |
|---|---|---|
| ConfigMap `oms-krb5` | `krb5.conf`: the realm and its domain controller, with `.svc.cluster.local` mapped to the realm; `kdc-address` and `kdc-hostnames`: the controller's IP and its names (FQDN, DNS domain, short domain name), which the SQL Recipe pins in the pod's hosts file because SQL Server on Linux resolves the short domain name as a host | SQL Server and the app |
| Secret `oms-sql-kerberos` | `mssql.keytab` (keys for `svc-oms-sql` and both SPNs), `account` | SQL Server |
| Secret `oms-app-kerberos` | `client.keytab` (keys for `svc-oms-app`), `login` | the app's pods |

When these exist, the Azure Local Recipe Pack passes them to the Recipes:
- **SQL Recipe:** configures SQL Server's keytab, then creates the Windows login and adds it to
  `dbcreator`, so the app can create its database.
- **Container Recipe:** gets the client keytab, `krb5.conf` and the Kerberos environment variables as
  plain volumes, mounts and environment variables from the pack, and adds them to every pod. The
  Recipe itself knows nothing about Kerberos.

### Or use the script

[ad-setup.ps1](../scripts/infra/azurelocal/ad-setup.ps1) does steps 1, 2 and 4 in one go, plus a test
user, when the domain controller is a Hyper-V VM on the machine you run it from (it uses PowerShell
Direct). To redo only step 4, run it with `-KerberosOnly`, then redeploy.
