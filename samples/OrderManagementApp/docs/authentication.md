# How authentication works

There are two kinds of authentication: **users** signing in to the app, and the **app's own
services** signing in to the queue, storage, the databases and each other. Paths are relative to
the sample folder, [samples/OrderManagementApp](../).

## Users

The app is written once, for Microsoft Entra ID: MSAL.js in the browser
([app.js](../src/OrderManagement.Api/wwwroot/js/app.js)) and Microsoft.Identity.Web in the API
([Program.cs](../src/OrderManagement.Api/Program.cs)). On Azure Local, Keycloak issues tokens shaped
like Entra's, so the code doesn't change.

1. The browser loads `/config.json` from the API: which identity provider, client ID and scope to use.
2. MSAL.js sends the user to Entra ID, or to Keycloak, which checks the password against Active
   Directory.
3. The browser calls `/api/...` with the access token.
4. The API checks the token (issuer, audience, scope `access_as_user`), then its `roles` claim:
   `Orders.Read` to list orders, `Orders.Create` to place one, `Inventory.Manage` to restock
   ([OrderAuthorization.cs](../src/OrderManagement.Api/OrderAuthorization.cs)).
5. To restock, the API calls the inventory service with its own token, not the user's (see
   [Calls between services](#calls-between-services)).

Only settings differ: the `apiAuthentication` and `spaSettings` parameters of
[app.bicep](../deploy/app.bicep). The registrations behind them are in
[app-identity.bicep](../infra/azure/app-identity.bicep) for Entra and
[realm.json](../infra/azurelocal/keycloak/realm.json) for Keycloak.

## Workloads

Each service (`api`, `processor`, `inventory`) runs as its own identity: its own Kubernetes service
account, named after it, and behind it its own managed identity on Azure or its own Keycloak client
on Azure Local. Each identity gets only what that service needs:

| | api | processor | inventory |
|---|---|---|---|
| Queue | send | receive | none |
| Object storage | none | write | none |
| SQL (orders) | read | read, write | none |
| PostgreSQL (stock) | none | none | its own schema |
| Inventory service | `Inventory.Read`, `Inventory.Restock` | `Inventory.Reserve` | n/a |

The pods hold no secrets where the platform can give them an identity. The code picks its
credential from what the platform provides, with no platform switch:

| Service | Azure | Azure Local | Where the choice is made |
|---|---|---|---|
| Queue | [Entra Workload ID](https://learn.microsoft.com/azure/aks/workload-identity-overview) | the pod's Kubernetes token, exchanged at Keycloak for a token RabbitMQ accepts | [ServiceCollectionExtensions.cs](../src/OrderManagement.Shared/DependencyInjection/ServiceCollectionExtensions.cs) |
| Object storage | Entra Workload ID | S3 keys the platform issues to the namespace, limited to its own buckets, given only to the services connected to object storage | [ArchiveOptions.cs](../src/OrderManagement.Shared/Configuration/ArchiveOptions.cs) |
| SQL, PostgreSQL | Entra Workload ID: a database user for the service's managed identity | the service's own database login, password from Key Vault | [DatabaseLogin.cs](../src/OrderManagement.Shared/Identity/DatabaseLogin.cs) |
| Inventory service | Entra Workload ID: a token for the `oms-inventory` app | the same Keycloak token as for the queue, which also names `oms-inventory` | [ServiceCollectionExtensions.cs](../src/OrderManagement.Shared/DependencyInjection/ServiceCollectionExtensions.cs) |

On Azure Local, Keycloak plays Entra's part: it trusts the cluster's token issuer, the way Entra
trusts it through a federated credential, so the exchange works the same way. It checks the tokens
with signing keys it fetches from the cluster's API server, not from the issuer's address, so the
exchange needs nothing in Azure. With Arc workload identity on, that address is a public Azure URL;
Keycloak only compares it to the token's `iss` claim.

| | Azure | Azure Local |
|---|---|---|
| Trusts the pod's token | Entra, through a federated identity credential on the service's managed identity | the service's Keycloak client, `workload-<service>` (`federated-jwt`) |
| Puts the token in the pod | Workload ID webhook | the Recipe Pack, through the container Recipe |
| Tells the app where to use it | `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_FEDERATED_TOKEN_FILE` | `IDENTITY_CLIENT_ID`, `IDENTITY_TOKEN_ENDPOINT`, `IDENTITY_TOKEN_FILE`, set by the Recipe Pack |
| Checks permissions | Azure RBAC, scoped to the queue and the container | the `rabbitmq_scopes` claim in the token |

### Databases

No service is a database administrator. A one-off setup job,
[OrderManagement.DbSetup](../src/OrderManagement.DbSetup/Program.cs), runs at each deployment as
the administrator: it applies the schema's migrations and creates a database user for each service,
with only the rights in the table above. A migration is a numbered `.sql` file in
[Migrations](../src/OrderManagement.DbSetup/Migrations), applied once by
[DbUp](https://dbup.readthedocs.io) and recorded in the database's `SchemaVersions` table; to change
the schema, add the next file rather than editing one already applied.

- **Azure:** Azure SQL and PostgreSQL accept Entra sign-in only, with no passwords. Their
  administrator is a dedicated managed identity, `id-oms-db-admin`, used by the setup job alone. The
  services' users are their managed identities.
- **Azure Local:** each service has a database login of its own (`api`, `processor`, `inventory`).
  The passwords, and the administrators', are in Azure Key Vault, which the Secret Store extension
  syncs into the cluster while the link to Azure is up. The deploy script sets them in the
  databases, then gives each service only its own password, in Secret `<service>-db-credentials`.
  See the [README](../README.md#deploy-to-azure-local) to change one.

### Calls between services

The API and the processor call the inventory service with their own tokens. The inventory service
accepts only tokens issued for it (audience `oms-inventory`) and checks their roles
([InventoryAuthentication.cs](../src/OrderManagement.Inventory/InventoryAuthentication.cs)): reading
products, reserving stock and restocking are separate roles, granted to the identity that needs
each. A user's token never reaches it; the API checks the user's `Inventory.Manage` role before
restocking on their behalf.

- **Azure:** `oms-inventory` is an app registration with application roles, assigned to the API's
  and processor's managed identities ([app-identity.bicep](../infra/azure/app-identity.bicep)).
- **Azure Local:** `oms-inventory` is a Keycloak client with the same roles, assigned to the
  service accounts of `workload-api` and `workload-processor`
  ([realm.json](../infra/azurelocal/keycloak/realm.json)).

If RabbitMQ refuses the token, check these first:

| Symptom | Cause |
|---|---|
| Keycloak reports a signature validation failure | Keycloak can't read the cluster's signing keys; it needs the `system:service-account-issuer-discovery` role. |
| `client_not_found` from Keycloak | The realm's client authentication flow lacks `federated-jwt` (realms migrated from before Keycloak 26.8). |
| `Bad Certificate - selfsigned_peer` in the RabbitMQ log | Keycloak's certificate must come from a CA, not be self-signed. |

## Connect your Active Directory

On Azure Local, users and their roles come from Active Directory through Keycloak. The directory
needs:

- An OU for the app, `OMS`. Keycloak reads users and groups only from it.
- These groups in it. Granting access is adding people to them:

  | Group | Gets |
  |---|---|
  | `oms-app-readers` | `Orders.Read` |
  | `oms-app-writers` | `Orders.Create` |
  | `oms-inventory-admins` | `Inventory.Manage` and `Orders.Read` |
  | `oms-operators` | `Operations.Monitor`: the site's Grafana (dashboards, logs, traces) |
  | `oms-identity-admins` | Administration of the app's Keycloak realm, `oms`, and nothing else |
- A bind account for Keycloak, `svc-keycloak`, limited to what Keycloak does: sign in to a domain
  controller over LDAP and read the users and groups in the OU. It's in no group, can sign in only
  at the domain controllers, can't be delegated, and is denied listing every container outside the
  OU. Keycloak's connection is read-only too, so it never writes to the directory.
- LDAPS on the domain controller, which needs a server certificate from a certificate authority.

[ad-setup.ps1](../scripts/infra/azurelocal/ad-setup.ps1) creates all of this and hands the bind
account and the CA certificate to the cluster. Run it from the management machine as a
domain administrator, once the cluster exists:

```powershell
./scripts/infra/azurelocal/ad-setup.ps1 -ComputerName <domain controller> -DomainName <domain> `
    -KubeContext <cluster context>
```

If your directory already has these, you don't need it: put the bind account in
`Keycloak.AdBindUpn` and the CA's certificate file in `Keycloak.AdCaCertificatePath`
([settings](./azure-local-settings.md#active-directory)). The first `up.ps1` run asks for the bind
account's password and keeps it, with the certificate, in the cluster.

The listing limits cover the containers and domain controllers that exist when the script runs, so
run it again after adding either; that leaves the existing passwords alone. To change the bind
password, run it with `-ResetBindPassword`, then `keycloak.ps1` (the `Keycloak` setup step), which
gives Keycloak the new one.
Some things stay readable, as they are for every account in the domain: the names of the containers
directly under the domain root (Keycloak has to find the OU there), the sub-containers of Group
Policy objects, the forest's configuration, schema and DNS partitions, and the domain controllers'
SYSVOL share.

To create the objects yourself instead, give the bind account the same limits, and set
`Keycloak.AdBindUpn` and `Keycloak.AdCaCertificatePath` as above.

To use an OU other than `OMS`, pass its name to `keycloak.ps1 -AdOuName`.
